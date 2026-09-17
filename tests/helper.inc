-- Shared test harness for the remote-ssh plugin.
-- Loaded via dofile("tests/helper.inc") from the plugin root directory
-- (pragtical's `test` command chdir's to core.init_working_dir).

package.path = "./?.lua;./?/init.lua;" .. package.path

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

H.mp = require("plugins.remote-ssh.messagepack")

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
    if #data >= 4 then
      local len = string.unpack(">I4", data:sub(1, 4))
      if #data >= 4 + len then
        local payload = data:sub(5, 4 + len)
        local ok, req = pcall(mp.unpack, payload)
        if ok then
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

return H
