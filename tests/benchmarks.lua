-- Benchmarks for bridge.lua efficiency work.
--
-- Run standalone from the plugin root (NOT as part of the full suite —
-- these take seconds on purpose):
--
--   mkdir -p /tmp/pragtical_test_user
--   PRAGTICAL_USERDIR=/tmp/pragtical_test_user pragtical test tests/benchmarks.lua
--
-- `system.get_time` is real time in the Pragtical runtime (SDL performance
-- counter), so wall-clock timings measured here include real sleeps.
--
-- What is measured (before/after the efficiency changes):
--   1. perform_sync_request streaming a 4 MB read_file in 4096-byte chunks
--      (counts reads, sleeps, get_status calls + wall time).
--   2. perform_sync_request over a 2 MB burst of 2000 framed messages in a
--      single chunk (process_socket_stream re-slicing cost).
--   3. Single-write (header..payload concat) vs split-write cost for 4 MB.
--   4. bridge.update() SSH stderr read frequency over 600 iterations.

local test = require "core.test"
local H = dofile("tests/helper.inc")
local core = require "core"
local bridge = require "plugins.remote-ssh.bridge"
local mp = H.mp

local function bench(label, fn)
  local t1 = system.get_time()
  local ret = fn()
  local dt = system.get_time() - t1
  print(string.format("[bench] %-46s %8.3f s", label, dt))
  return dt, ret
end

-- A counting socket: delivers queued chunks, counts read/get_status calls.
local function counting_socket(chunks)
  local sock = {}
  sock.reads = 0
  sock.status_checks = 0
  sock.written = ""
  function sock:write(data)
    self.written = self.written .. data
    return #data
  end
  function sock:read(_n)
    self.reads = self.reads + 1
    if #chunks == 0 then return "", nil end
    return table.remove(chunks, 1), nil
  end
  function sock:get_status()
    self.status_checks = self.status_checks + 1
    return "success"
  end
  function sock:close() end
  return sock
end

local function connect_socket(sock)
  bridge.client_socket = sock
  bridge.current_ssh_host = "bench"
  bridge.remote_cwd = "/bench"
end

local function with_sleep_counter(fn)
  local old_sleep = system.sleep
  local count = 0
  system.sleep = function(_n) count = count + 1 end
  local ok, ret = pcall(fn)
  system.sleep = old_sleep
  if not ok then error(ret, 0) end
  return count
end

test.describe("bridge benchmarks", function()
  test.after_each(function()
    bridge.disconnect()
  end)

  -- ---------------------------------------------------------------------
  test.it("1. streams a 4 MB file in 4096-byte chunks", function()
    local chunks = {}
    local sock = counting_socket(chunks)
    local fed = false
    function sock:read(_n)
      self.reads = self.reads + 1
      if not fed then
        fed = true
        -- parse the written request to copy its real id into the response,
        -- then deliver the framed reply in 4096-byte chunks
        local len = string.unpack(">I4", self.written:sub(1, 4))
        local ok, req = pcall(mp.unpack, self.written:sub(5, 4 + len))
        local rp = mp.pack({ id = (ok and req and req.id) or "0", status = "ok", action = "read_file", content = string.rep("x", 4 * 1024 * 1024) })
        local framed = string.pack(">I4", #rp) .. rp
        for i = 1, #framed, 4096 do
          table.insert(chunks, framed:sub(i, i + 4095))
        end
      end
      if #chunks == 0 then return "", nil end
      return table.remove(chunks, 1), nil
    end
    local nchunks = math.ceil(4 * 1024 * 1024 / 4096)
    local dt
    local sleeps
    dt, sleeps = bench("stream 4MB (~" .. nchunks .. " chunks)", function()
      connect_socket(sock)
      return with_sleep_counter(function()
        return bridge.perform_sync_request({ action = "read_file", path = "big.bin" })
      end)
    end)
    print(string.format("[bench]   sleeps during request: %d", sleeps or -1))
    test.not_nil(sleeps)
  end)

  -- ---------------------------------------------------------------------
  test.it("2. processes a 2 MB burst of 2000 framed messages in one chunk", function()
    -- Build the burst of filler frames first; the matching response (with
    -- the real request id) is appended by the socket on write.
    local fillers = {}
    local filler_payload = mp.pack({ status = "ok", action = "filler", data = string.rep("y", 1024) })
    local filler_frame = string.pack(">I4", #filler_payload) .. filler_payload
    for i = 1, 1999 do
      local p = mp.pack({ id = "fake" .. i, status = "ok", action = "filler", data = string.rep("y", 1024) })
      fillers[i] = string.pack(">I4", #p) .. p
    end
    local burst = table.concat(fillers)

    local sock = {
      reads = 0, status_checks = 0,
      write = function(self, data) return #data end,
      get_status = function(self) self.status_checks = self.status_checks + 1; return "success" end,
      close = function() end,
    }
    local fed = false
    function sock:read(_n)
      self.reads = self.reads + 1
      if not fed then
        fed = true
        -- capture the request id from the written frame, then feed the
        -- burst + the matching reply in ONE chunk
        local len = string.unpack(">I4", burst:sub(1, 4))
        -- find the request id: parse the request the bridge wrote
        local req_payload = (self.written or ""):sub(5, 4 + len)
        local ok, req = pcall(mp.unpack, req_payload)
        local reply
        if ok and req and req.id then
          local rp = mp.pack({ id = req.id, status = "ok", action = "bench" })
          reply = string.pack(">I4", #rp) .. rp
        else
          -- fallback: plain burst only
          reply = burst
        end
        return burst .. reply, nil
      end
      return "", nil
    end
    -- record writes for id extraction
    local real_write = sock.write
    sock.written = ""
    sock.write = function(self, data) self.written = self.written .. data; return real_write(self, data) end

    connect_socket(sock)
    bench("burst 2000 msgs / 2MB in one chunk", function()
      bridge.perform_sync_request({ action = "bench", path = "x" })
    end)
  end)

  -- ---------------------------------------------------------------------
  test.it("3. header concat vs split write for a 4 MB payload", function()
    local payload = string.rep("x", 4 * 1024 * 1024)
    local header = string.pack(">I4", #payload)

    local sock = counting_socket({})
    connect_socket(sock)

    local dt1 = bench("single write (header..payload)", function()
      sock:write(header .. payload)
    end)

    local dt2 = bench("split write (header, payload)", function()
      sock:write(header)
      sock:write(payload)
    end)

    print(string.format("[bench]   concat overhead: %.4f s (%.1f%% of single write)",
      dt1 - dt2, dt1 > 0 and (dt1 - dt2) / dt1 * 100 or 0))
  end)

  -- ---------------------------------------------------------------------
  test.it("4. counts SSH stderr reads over 600 update() iterations", function()
    local reads = 0
    bridge.ssh_proc = {
      read_stderr = function(_n) reads = reads + 1; return "" end
    }
    bridge.client_socket = counting_socket({})
    for _ = 1, 600 do
      bridge.update()
    end
    print(string.format("[bench]   stderr reads in 600 update() calls: %d (1 per frame today)", reads))
  end)
end)
