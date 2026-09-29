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

-- Network framing state machine variables. Incoming bytes are kept as a
-- list of chunks with a head index instead of one concatenated string:
-- appending a chunk is O(1) and each payload is copied exactly once when
-- it is complete (a plain `rx_buffer = rx_buffer .. chunk` re-copies the
-- whole buffer per chunk, which is O(N^2) on large transfers).
local pending = {}
local pending_head = 1
local pending_tail = 0
local pending_len = 0
local head_offset = 0
local state = "LENGTH"
local expected_bytes = 4

local pending_responses = {}
local async_event_queue = {}
local last_stderr_check = 0

-- Cooperative sleep for bridge.connect's SSH-tunnel / resolve /
-- connect-retry loops. Yields to the main-loop scheduler when running inside
-- a coroutine (so the editor redraws and stays responsive during the
-- multi-second connect waits -- core.add_thread / core.add_background_thread
-- are both coroutines resumed by the main loop, NOT OS threads; system.sleep
-- is SDL_Delay and blocks the whole main thread, freezing the UI).
-- coroutine.yield(seconds) returns control to the scheduler, which redraws
-- between resumes. Falls back to system.sleep for synchronous callers.
-- NOT used by perform_sync_request / send_remote_command: those run from
-- synchronous callers (Doc:load, redraw intercepts) and from test
-- coroutines where yielding mid-request would interleave redraws with
-- incomplete state; their waits are also brief (loopback, sub-ms).
local function coop_sleep(seconds)
  if coroutine.isyieldable() then
    coroutine.yield(seconds)
  else
    system.sleep(seconds)
  end
end

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
  -- Guard against a hung ssh-agent (blocked agent, odd environments):
  -- without this the connect loop below would spin forever.
  local start_time = system.get_time()
  while proc:running() do
    if system.get_time() - start_time > 5.0 then
      stop_process(proc)
      return 2
    end
    coop_sleep(0.005)
  end
  local code = proc:returncode()
  return code or 2
end

-- Removes and returns exactly `n` bytes from the front of the chunk list.
-- Only the requested bytes are copied; the unconsumed remainder of a
-- partially-taken chunk is kept in place via `head_offset`, so a burst of
-- many messages inside one chunk costs one payload copy per message
-- instead of re-slicing the whole remainder (O(N^2)).
local function take_bytes(n)
  local parts = {}
  local need = n
  while need > 0 do
    local c = pending[pending_head]
    local avail_in_c = #c - head_offset
    if avail_in_c <= need then
      if head_offset == 0 then
        parts[#parts + 1] = c
      else
        parts[#parts + 1] = c:sub(head_offset + 1)
      end
      need = need - avail_in_c
      pending[pending_head] = nil
      pending_head = pending_head + 1
      head_offset = 0
    else
      parts[#parts + 1] = c:sub(head_offset + 1, head_offset + need)
      head_offset = head_offset + need
      need = 0
    end
  end
  pending_len = pending_len - n
  if #parts == 1 then return parts[1] end
  return table.concat(parts)
end

-- Parses chunk streams through the framing state machine. Each payload is
-- copied exactly once when complete, so a burst of N messages in one chunk
-- stays O(N) instead of degrading to O(N^2) byte copying.
local function process_socket_stream(chunk)
  pending_tail = pending_tail + 1
  pending[pending_tail] = chunk
  pending_len = pending_len + #chunk

  while pending_len >= expected_bytes do
    if state == "LENGTH" then
      local len = string.unpack(">I4", take_bytes(4))
      expected_bytes = len
      state = "PAYLOAD"
    elseif state == "PAYLOAD" then
      local payload = take_bytes(expected_bytes)

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
  end

  -- Periodically drop the consumed head slots so the chunk list does not
  -- grow unbounded across a session.
  if pending_head > 512 then
    local j = 1
    local first = pending[pending_head]
    if head_offset > 0 and head_offset < #first then
      pending[1] = first:sub(head_offset + 1)
      j = 2
    end
    pending[pending_head] = nil
    for i = pending_head + 1, pending_tail do
      pending[j] = pending[i]
      pending[i] = nil
      j = j + 1
    end
    pending_tail = j - 1
    pending_head = 1
    head_offset = 0
  end
end

-- Encodes and transmits a command with a 4-byte network byte-order header.
-- Header and payload are concatenated into one write: splitting them makes
-- the second write wait for the receiver's delayed ACK of the first
-- (Nagle on the client side), adding ~40 ms per request/response
-- round-trip. Benchmark-verified (see tests/server_e2e_bench.lua).
local function send_remote_command(payload_table)
  if not bridge.client_socket then return false end
  local bin_data = mp.pack(payload_table)
  local length = #bin_data
  local header = string.pack(">I4", length)

  -- Single concatenated write: splitting header and payload makes the
  -- second write wait for the receiver's delayed ACK of the first (Nagle
  -- on the client side), adding ~40 ms per request/response round-trip
  -- (benchmark-verified, LESSONS §35). Drain in a loop: net.tcp:write may
  -- deliver only part of the data, or return 0 when the send buffer is
  -- full; a single best-effort write would silently drop the remainder,
  -- truncating large save_file frames and hanging the server until the
  -- 10 s timeout. Note 0 (not ready) is truthy in Lua, so the old
  -- `if not written` guard treated it as success.
  local packet = header .. bin_data
  local sent = 0
  while sent < #packet do
    local n, err = bridge.client_socket:write(packet:sub(sent + 1))
    if not n then
      core.error("[%s] Socket write error: %s", bridge.current_ssh_host or "Remote", tostring(err))
      bridge.disconnect()
      return false
    end
    if n == 0 then
      system.sleep(0.001)
    else
      sent = sent + n
    end
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
  pending = {}
  pending_head = 1
  pending_tail = 0
  pending_len = 0
  head_offset = 0
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
    local chunk, err = bridge.client_socket:read(65536)
    if err then
      core.log("[%s] Connection lost: %s", bridge.current_ssh_host or "Remote", tostring(err))
      bridge.disconnect()
      break
    end

    if chunk and chunk ~= "" then
      process_socket_stream(chunk)
    else
      -- No data this poll: check liveness here rather than every
      -- iteration, so a large multi-chunk response isn't charged a
      -- get_status call per chunk. read() returning nil+err already
      -- catches a disconnect, so this status check is belt-and-suspenders.
      if bridge.client_socket:get_status() ~= "success" then
        core.error("[%s Sync] Socket disconnected.", bridge.current_ssh_host or "Remote")
        bridge.disconnect()
        break
      end
      -- Only sleep when no data arrived; sleeping while chunks are still
      -- streaming adds ~1 ms per read (over a second on a multi-MB file).
      -- system.sleep (not coop_sleep): perform_sync_request runs from
      -- synchronous callers (Doc:load, redraw intercepts) where yielding
      -- is not possible, and from test coroutines where yielding mid-request
      -- would interleave redraws with incomplete state. The connect-time
      -- round-trips are brief (loopback, sub-ms), so blocking is negligible.
      system.sleep(0.001)
    end

    if not pending_responses[request_id]
      and system.get_time() - start_time > timeout then
      core.error("[%s Sync] Request timed out for action: %s", bridge.current_ssh_host or "Remote", tostring(request.action))
      break
    end
  end
  
  local response = pending_responses[request_id]
  pending_responses[request_id] = nil
  return response
end

-- Initiates our native connection pipeline directly within Lua
function bridge.connect(ssh_host, target_dir)
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
    coop_sleep(0.01)
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
    coop_sleep(0.01)
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
        coop_sleep(0.01)
      end
    end

    if not connected then
      if sock then sock:close() end
      coop_sleep(0.25)
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

  -- Switch to requested target directory if provided
  if target_dir and target_dir ~= "" then
    local cd_res = bridge.perform_sync_request({
      action = "change_dir",
      path = target_dir
    })
    if cd_res and cd_res.status == "ok" then
      bridge.remote_cwd = cd_res.cwd
      core.log("Remote Workspace: Changed working directory to " .. tostring(bridge.remote_cwd))
    else
      local msg = cd_res and cd_res.message or "Unknown error"
      core.error("Failed to switch remote directory to %s: %s", tostring(target_dir), tostring(msg))
    end
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

  -- Handle SSH channel errors. Throttled to at most one pipe read per
  -- second: update() runs at frame rate for the whole session, and reading
  -- a near-idle stderr stream every frame is millions of wasted syscalls.
  if bridge.ssh_proc then
    local now = system.get_time()
    if now - last_stderr_check > 1.0 then
      last_stderr_check = now
      local err_output = bridge.ssh_proc:read_stderr(4096)
      if err_output and err_output ~= "" then
        core.error("[Bridge Error] %s", err_output:gsub("[\r\n]+", " "))
      end
    end
  end

  -- Standard socket read. Larger buffer (64 KB) cuts syscall count on
  -- bursts of async events; returns only what is available, so idle frames
  -- cost the same as the old 4 KB read.
  local chunk, err = bridge.client_socket:read(65536)
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
