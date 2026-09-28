-- Shared test harness for the remote-ssh plugin.
-- Loaded via dofile("tests/helper.inc") from the plugin root directory
-- (pragtical's `test` command chdir's to core.init_working_dir).

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Resolve the plugin root so relative dofiles resolve even when the
-- caller's cwd is not the plugin root (e.g. bench-server.sh runs from a
-- scratch dir). debug.getinfo(1, "S").source is "@<path>" for dofile'd
-- files; helper.inc lives in <root>/tests.
local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
-- strip the trailing tests component (handles both "/path/tests" and the
-- cwd-relative "tests" the test runner produces)
local root = here:gsub("/tests$", ""):gsub("^tests$", ".")

local H = {}

-- Remap the plugin's internal require paths to dofile so the plugin sources
-- at the repo root are exercised directly without installing the addon.
package.preload["plugins.remote-ssh"] = function()
  return dofile("init.lua")
end
package.preload["plugins.remote-ssh.bridge"] = function()
  return dofile("bridge.lua")
end
package.preload["plugins.remote-ssh.messagepack"] = function()
  return dofile("messagepack.lua")
end

H.mp = dofile(root .. "/messagepack.lua")

-- Unique temp path helper (mirrors the assistant plugin convention).
local temp_counter = 0
function H.tmp(name)
  temp_counter = temp_counter + 1
  local path = os.tmpname()
  os.remove(path)
  return path .. "-" .. tostring(temp_counter) .. "-" .. name
end

-- Build a single framed message: 4-byte big-endian length + msgpack payload.
function H.framed(t)
  local payload = H.mp.pack(t)
  return string.pack(">I4", #payload) .. payload
end

-- Split a string into a list of single-byte chunks (for framing reassembly
-- tests).
function H.bytes(s)
  local out = {}
  for i = 1, #s do
    out[i] = s:sub(i, i)
  end
  return out
end

-- A minimal TCP socket double that returns chunks from a queue. Used for
-- direct bridge.update() / framing tests.
function H.fakesocket(opts)
  opts = opts or {}
  local sock = {}
  local chunks = opts.read_chunks or {}
  sock.written = ""
  sock.write_calls = {}
  sock.closed = false
  function sock:write(data)
    table.insert(self.write_calls, data)
    self.written = self.written .. data
    if opts.write_fail then return nil, "fake write failure" end
    return #data
  end
  function sock:read(_n)
    if #chunks == 0 then return "", nil end
    return table.remove(chunks, 1), nil
  end
  function sock:get_status()
    return opts.status or "success"
  end
  function sock:close()
    self.closed = true
  end
  -- extras for connect() happy-path mocking
  function sock:wait_until_connected()
    return opts.connect_status or "success"
  end
  return sock
end

-- A loopback socket: on every write it parses the framed request, invokes
-- opts.handler(req) and feeds the response back into the read buffer so
-- bridge.perform_sync_request can complete synchronously.
--
-- handler(req) may return:
--   * a string        -> raw bytes fed verbatim (for malformed payload tests)
--   * a message table -> single framed response (id auto-copied if absent);
--     detected via presence of action/status/event/id fields
--   * a list of items  -> each item is either a string (raw) or a table
--     (framed message); used to emit async events before the reply
-- opts.chunk_size splits reads into fixed-size pieces to exercise framing.
function H.loopback(opts)
  opts = opts or {}
  local mp = H.mp
  local sock = {}
  sock.written = ""
  sock.requests = {}
  local read_buf = ""
  local write_acc = ""
  local function feed(data)
    read_buf = read_buf .. data
  end
  local function is_message(t)
    return type(t) == "table"
      and (t.id ~= nil or t.status ~= nil or t.action ~= nil or t.event ~= nil)
  end
  local function emit(item, req)
    if type(item) == "string" then
      feed(item)
    elseif type(item) == "table" then
      if not item.id and req.id then item.id = req.id end
      feed(H.framed(item))
    end
  end
  function sock:write(data)
    sock.written = sock.written .. data
    -- Accumulate writes: the bridge may send header and payload separately,
    -- so parse complete frames from the accumulated stream.
    write_acc = write_acc .. data
    while #write_acc >= 4 do
      local len = string.unpack(">I4", write_acc:sub(1, 4))
      if #write_acc < 4 + len then break end
      local payload = write_acc:sub(5, 4 + len)
      write_acc = write_acc:sub(4 + len + 1)
      local ok, req = pcall(mp.unpack, payload)
      if ok and req then
        table.insert(sock.requests, req)
        local resp = opts.handler(req)
        if type(resp) == "string" then
          feed(resp)
        elseif is_message(resp) then
          emit(resp, req)
        elseif type(resp) == "table" then
          for _, item in ipairs(resp) do emit(item, req) end
        end
      end
    end
    return #data
  end
  function sock:read(n)
    if read_buf == "" then return "", nil end
    local sz = opts.chunk_size or n
    if sz < 1 then sz = 1 end
    local piece = read_buf:sub(1, sz)
    read_buf = read_buf:sub(sz + 1)
    return piece, nil
  end
  function sock:get_status() return "success" end
  function sock:close() sock.closed = true end
  function sock:wait_until_connected() return "success" end
  return sock
end

-- Fake async process object (for bridge.connect / check_ssh_agent mocking).
function H.fakeproc(opts)
  opts = opts or {}
  local p = {}
  local stdout_chunks = opts.stdout or {}
  local stderr_chunks = opts.stderr or {}
  p._running = true
  p.terminated = false
  function p:running()
    if opts.running_fn then return opts.running_fn() end
    return p._running
  end
  function p:returncode()
    return opts.returncode or 0
  end
  function p:read_stdout(_n)
    if #stdout_chunks == 0 then return "" end
    return table.remove(stdout_chunks, 1)
  end
  function p:read_stderr(_n)
    if #stderr_chunks == 0 then return "" end
    return table.remove(stderr_chunks, 1)
  end
  function p:terminate()
    p.terminated = true
    p._running = false
  end
  p.kill = p.terminate
  return p
end

-- Fake net.resolve_address() return value.
function H.fakeaddress(status)
  local a = {}
  function a:wait_until_resolved() return status or "success" end
  return a
end

-- Replace core.error with a capturing delegate; returns restore() and the
-- collected messages.
function H.capture_errors()
  local core = require("core")
  local real = core.error
  local messages = {}
  core.error = function(fmt, ...)
    local msg
    if type(fmt) == "string" then
      msg = string.format(fmt, ...)
    else
      msg = tostring(fmt)
    end
    table.insert(messages, msg)
    return real(fmt, ...)
  end
  return {
    messages = messages,
    restore = function() core.error = real end
  }
end

-- Replace a table field and return a restore function.
function H.swap(t, k, v)
  local old = t[k]
  t[k] = v
  return function() t[k] = old end
end

-- Launch the compiled headless server on a free port over real loopback TCP
-- and wire a real net.tcp socket to it. Returns a table { sock, proc,
-- workdir, port, teardown } or nil + errmsg (binary missing, server didn't
-- start, connect failed). This is the only seam that exercises real framing,
-- Nagle, real read-buffer semantics, and real disconnect detection -- fake
-- sockets cannot (LESSONS §35). The server resolves relative paths against
-- its own CWD (= workdir), so we chdir into a scratch dir before launch
-- (LESSONS §19/§26). teardown closes the socket, terminates the proc, waits
-- for it to die, and removes the scratch dir.
local real_server_port_counter = 9089
function H.real_server(opts)
  opts = opts or {}
  local process = rawget(_G, "process")
  local net = rawget(_G, "net")
  if not (process and net) then
    return nil, "net or process module unavailable"
  end
  local repo = opts.repo or system.getcwd()
  local binary = opts.binary or
    (repo .. "/built-binaries/ubuntu-24/x86_64/headless-server")
  local f = io.open(binary, "r")
  if not f then return nil, "binary not found: " .. binary end
  f:close()

  real_server_port_counter = real_server_port_counter + 1
  local port = opts.port or real_server_port_counter
  local workdir = os.tmpname()
  os.remove(workdir)
  os.execute("mkdir -p " .. workdir)

  local cur = system.getcwd()
  local proc
  local ok_launch = pcall(function()
    system.chdir(workdir)
    proc = process.start({ binary, tostring(port) }, {
      stdin = process.REDIRECT_DISCARD,
      stdout = process.REDIRECT_PIPE,
      stderr = process.REDIRECT_PIPE,
    })
  end)
  system.chdir(cur)
  if not (ok_launch and proc) then
    os.execute("rm -rf " .. workdir)
    return nil, "failed to start server process"
  end

  -- Wait for the "running on port" banner on stdout.
  local buf, ready = "", false
  local t0 = system.get_time()
  while system.get_time() - t0 < 5 do
    if not proc:running() then break end
    local out = proc:read_stdout(4096)
    if out and out ~= "" then buf = buf .. out end
    if buf:find("running on port") then ready = true break end
    system.sleep(0.01)
  end
  if not ready then
    pcall(proc.terminate, proc)
    os.execute("rm -rf " .. workdir)
    return nil, "server did not signal ready: " .. (buf:gsub("%s", " "))
  end

  -- Blocking resolve (LESSONS §25: 0-timeout polls never resolve outside the
  -- main loop; the blocking form does).
  local addr = net.resolve_address("127.0.0.1")
  addr:wait_until_resolved(1)
  local sock
  for _ = 1, 100 do
    sock = net.open_tcp(addr, port)
    if sock then
      for _ = 1, 100 do
        if sock:wait_until_connected(0) == "success" then break end
      end
      if sock:get_status() == "success" then break end
      pcall(sock.close, sock)
      sock = nil
    end
    system.sleep(0.01)
  end
  if not sock then
    pcall(proc.terminate, proc)
    os.execute("rm -rf " .. workdir)
    return nil, "failed to connect to server on port " .. port
  end

  return {
    sock = sock,
    proc = proc,
    workdir = workdir,
    port = port,
    teardown = function()
      pcall(sock.close, sock)
      pcall(proc.terminate, proc)
      local t1 = system.get_time()
      while proc:running() and system.get_time() - t1 < 2 do
        system.sleep(0.01)
      end
      os.execute("rm -rf " .. workdir)
    end,
  }
end

return H
