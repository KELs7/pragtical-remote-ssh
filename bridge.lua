local core = require "core"
local process = require "process"
local parent_path = (... or ""):match("(.-)[%./\\][^%.%/\\]+$") or "plugins.remote-ssh"
local mp = require(parent_path .. ".messagepack")

local bridge = {
  client_socket = nil,
  ssh_proc = nil,
  current_ssh_host = nil,
  remote_cwd = nil,

  -- Callback to notify init.lua when the remote session ends
  on_disconnect = nil
}

-- Network framing state machine variables
local rx_buffer = ""
local state = "LENGTH"
local expected_bytes = 4

local pending_responses = {}
local async_event_queue = {}

-- Helper to safely terminate background processes
local function stop_process(proc)
  if not proc then return end
  if proc.terminate then
    pcall(proc.terminate, proc)
  elseif proc.kill then
    pcall(proc.kill, proc)
  end
end

-- Checks loaded SSH keys in ssh-agent asynchronously
local function check_ssh_agent()
  local proc, err = process.start({"ssh-add", "-l"})
  if not proc then return 2 end
  while proc:running() do
    system.sleep(0.005)
  end
  local code = proc:returncode()
  return code or 2
end

-- Parses chunk streams through the framing state machine
local function process_socket_stream(chunk)
  rx_buffer = rx_buffer .. chunk
  local processing = true

  while processing do
    if #rx_buffer >= expected_bytes then
      if state == "LENGTH" then
        local len = string.unpack(">I4", rx_buffer:sub(1, 4))
        rx_buffer = rx_buffer:sub(5)
        expected_bytes = len
        state = "PAYLOAD"
      elseif state == "PAYLOAD" then
        local payload = rx_buffer:sub(1, expected_bytes)
        rx_buffer = rx_buffer:sub(expected_bytes + 1)
        
        local ok, data = pcall(mp.unpack, payload)
        if ok and type(data) == "table" then
          if data.id then
            pending_responses[tostring(data.id)] = data
          else
            table.insert(async_event_queue, data)
          end
        else
          local err_msg = not ok and tostring(data) or "invalid MessagePack object received"
          core.error("[%s] MessagePack decode error: %s", bridge.current_ssh_host or "Remote", tostring(err_msg))
        end
        
        expected_bytes = 4
        state = "LENGTH"
      end
    else
      processing = false
    end
  end
end

-- Encodes and transmits a command with a 4-byte network byte-order header
local function send_remote_command(payload_table)
  if not bridge.client_socket then return false end
  local bin_data = mp.pack(payload_table)
  local length = #bin_data
  local header = string.pack(">I4", length)

  local written, err = bridge.client_socket:write(header .. bin_data)
  if not written then
    core.error("[%s] Socket write error: %s", bridge.current_ssh_host or "Remote", tostring(err))
    bridge.disconnect()
    return false
  end
  return true
end

-- Checks if connection is active
function bridge.is_connected()
  return bridge.client_socket ~= nil
end

-- Cleanly closes open socket, process, and triggers callback
function bridge.disconnect()
  if bridge.client_socket then
    bridge.client_socket:close()
    bridge.client_socket = nil
  end
  if bridge.ssh_proc then
    stop_process(bridge.ssh_proc)
    bridge.ssh_proc = nil
  end

  bridge.current_ssh_host = nil
  bridge.remote_cwd = nil

  -- Reset network parsing state
  rx_buffer = ""
  state = "LENGTH"
  expected_bytes = 4
  pending_responses = {}
  async_event_queue = {}

  -- Trigger user interface and local workspace resets
  if bridge.on_disconnect then
    bridge.on_disconnect()
  end
end

-- Perform a synchronous request over the multiplexed TCP connection safely with timeout
function bridge.perform_sync_request(request)
  if not bridge.client_socket then return nil end
  
  local request_id = tostring(math.random(1, 100000000))
  request.id = request_id
  core.log_quiet("[%s Sync] Sending command: %s | ID: %s", bridge.current_ssh_host or "Remote", request.action, request_id)
  
  if not send_remote_command(request) then return nil end
  
  local start_time = system.get_time()
  local timeout = 10.0
  
  while not pending_responses[request_id] do
    if bridge.client_socket:get_status() ~= "success" then
      core.error("[%s Sync] Socket disconnected.", bridge.current_ssh_host or "Remote")
      bridge.disconnect()
      break
    end

    local chunk, err = bridge.client_socket:read(4096)
    if err then
      core.log("[%s] Connection lost: %s", bridge.current_ssh_host or "Remote", tostring(err))
      bridge.disconnect()
      break
    end
    
    if chunk and chunk ~= "" then
      process_socket_stream(chunk)
    end
    
    if not pending_responses[request_id] then
      if system.get_time() - start_time > timeout then
        core.error("[%s Sync] Request timed out for action: %s", bridge.current_ssh_host or "Remote", tostring(request.action))
        break
      end
      system.sleep(0.001)
    end
  end
  
  local response = pending_responses[request_id]
  pending_responses[request_id] = nil
  return response
end

-- Initiates our native connection pipeline directly within Lua
function bridge.connect(ssh_host)
  if bridge.client_socket then
    core.log("Remote is already active.")
    return true
  end

  local net = rawget(_G, "net")
  if not net then
    core.error("TCP connection requires the Pragtical net module.")
    return false
  end

  if ssh_host then
    core.log("Connecting to remote SSH host: " .. ssh_host .. "...")
  else
    core.log("Connecting to remote headless workspace...")
  end
  
  local server_ip = "127.0.0.1"
  local server_port = 8080
  
  local agent_status = check_ssh_agent() 
  if agent_status == 1 then
    core.log("[Remote SSH] Warning: ssh-agent is active but has no loaded identities.")
  elseif agent_status == 2 then
    core.log("[Remote SSH] Warning: ssh-agent is not accessible.")
  end

  local remote_cmd = string.format(
    "lsof -t -i:%d | xargs kill 2>/dev/null; sleep 0.1; echo \"READY\"; mkdir -p $HOME/.pragtical && $HOME/.pragtical/bin/headless-server %d > $HOME/.pragtical/headless-server.log 2>&1",
    server_port,
    server_port
  )

  local cmd_args = {
    "ssh",
    "-q",
    "-L", string.format("%d:127.0.0.1:%d", server_port, server_port),
    "-o", "ExitOnForwardFailure=yes",
    ssh_host,
    remote_cmd
  }

  local proc, err_msg = process.start(cmd_args, {
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE
  })

  if not proc then
    core.error("Failed to start SSH tunnel: " .. tostring(err_msg))
    return false
  end

  bridge.ssh_proc = proc

  -- Wait up to 10 seconds for remote to setup and signal synchronization token
  core.log("[%s] Syncing with remote environment...", ssh_host or "Remote")
  local ssh_buffer = ""
  local start_time = system.get_time()
  local ready = false

  while system.get_time() - start_time < 10.0 do
    if not bridge.ssh_proc:running() then
      local code = bridge.ssh_proc:returncode()
      local err_out = bridge.ssh_proc:read_stderr(4096) or ""
      core.error(string.format("SSH process exited with code %s: %s", tostring(code), err_out))
      bridge.disconnect()
      return false
    end

    local out = bridge.ssh_proc:read_stdout(4096)
    if out and out ~= "" then
      ssh_buffer = ssh_buffer .. out
      if ssh_buffer:find("READY") then
        ready = true
        break
      end
    end
    system.sleep(0.01)
  end

  if not ready then
    core.error("Failed to receive READY token from remote host.")
    bridge.disconnect()
    return false
  end

  -- Resolve address
  local address, resolve_err = net.resolve_address(server_ip)
  if not address then
    core.error("Failed to resolve server: " .. tostring(resolve_err))
    bridge.disconnect()
    return false
  end

  local resolved = false
  local resolve_start = system.get_time()
  while system.get_time() - resolve_start < 2.0 do
    local status = address:wait_until_resolved(0)
    if status == "success" then
      resolved = true
      break
    elseif status == "failure" then
      break
    end
    system.sleep(0.01)
  end

  if not resolved then
    core.error("Address resolution failed.")
    bridge.disconnect()
    return false
  end

  -- Connect loop
  local connected = false
  local connect_start = system.get_time()

  while not connected and (system.get_time() - connect_start < 8.0) do
    if bridge.ssh_proc and not bridge.ssh_proc:running() then
      core.error("SSH process terminated during connect step.")
      break
    end

    local sock = net.open_tcp(address, server_port)
    if sock then
      local wait_start = system.get_time()
      while system.get_time() - wait_start < 1.0 do
        local status = sock:wait_until_connected(0)
        if status == "success" then
          bridge.client_socket = sock
          connected = true
          break
        elseif status == "failure" then
          break
        end
        system.sleep(0.01)
      end
    end

    if not connected then
      if sock then sock:close() end
      system.sleep(0.25)
    end
  end

  if not connected then
    core.error("Connection attempt timed out.")
    bridge.disconnect()
    return false
  end

  bridge.current_ssh_host = ssh_host
  core.log("Natively connected to Remote Workspace.")

  -- Get working directory immediately
  local res = bridge.perform_sync_request({ action = "get_cwd" })
  if res and res.status == "ok" then
    bridge.remote_cwd = res.cwd
    core.log("Remote Workspace: Working directory is " .. tostring(bridge.remote_cwd))
  else
    core.error("Failed to verify remote working directory.")
    bridge.disconnect()
    return false
  end

  return true
end

-- Processes incoming events non-blockingly
function bridge.update()
  if not bridge.client_socket then return end

  if bridge.client_socket:get_status() ~= "success" then
    core.error("Remote connection closed.")
    bridge.disconnect()
    return
  end

  -- Process queued background events
  while #async_event_queue > 0 do
    local data = table.remove(async_event_queue, 1)
    if data.event == "agent_warning" then
      core.error("[Remote SSH] Warning: %s", data.message)
    end
  end

  -- Handle SSH channel errors
  if bridge.ssh_proc then
    local err_output = bridge.ssh_proc:read_stderr(4096)
    if err_output and err_output ~= "" then
      core.error("[Bridge Error] %s", err_output:gsub("[\r\n]+", " "))
    end
  end

  -- Standard socket read
  local chunk, err = bridge.client_socket:read(4096)
  if err then
    core.error("Read error: " .. tostring(err))
    bridge.disconnect()
    return
  end

  if chunk and chunk ~= "" then
    process_socket_stream(chunk)
  end
end

return bridge
