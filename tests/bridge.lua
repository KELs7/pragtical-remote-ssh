local test = require "core.test"
local H = dofile("tests/helper.inc")
local core = require "core"
local process = require "process"
local bridge = require "plugins.remote-ssh.bridge"

test.describe("bridge", function()
  test.before_each(function()
    bridge.disconnect()
    math.randomseed(12345)
  end)

  test.after_each(function()
    bridge.disconnect()
  end)

  test.describe("is_connected", function()
    test.it("returns false with no socket", function()
      test.equal(bridge.is_connected(), false)
    end)
    test.it("returns true when a client socket is set", function()
      bridge.client_socket = H.fakesocket()
      test.equal(bridge.is_connected(), true)
    end)
  end)

  test.describe("disconnect", function()
    test.it("closes the socket and clears connection state", function()
      local sock = H.fakesocket()
      local proc = H.fakeproc()
      bridge.client_socket = sock
      bridge.ssh_proc = proc
      bridge.current_ssh_host = "host"
      bridge.remote_cwd = "/remote"
      bridge.disconnect()
      test.equal(sock.closed, true)
      test.equal(proc.terminated, true)
      test.is_nil(bridge.client_socket)
      test.is_nil(bridge.ssh_proc)
      test.is_nil(bridge.current_ssh_host)
      test.is_nil(bridge.remote_cwd)
    end)
    test.it("invokes on_disconnect callback", function()
      local called = false
      bridge.on_disconnect = function() called = true end
      bridge.client_socket = H.fakesocket()
      bridge.disconnect()
      test.equal(called, true)
      bridge.on_disconnect = nil
    end)
    test.it("is safe when nothing is connected", function()
      test.no_error(function() bridge.disconnect() end)
      test.equal(bridge.is_connected(), false)
    end)
  end)

  test.describe("perform_sync_request", function()
    test.it("returns nil when not connected", function()
      test.is_nil(bridge.perform_sync_request({action = "x"}))
    end)
    test.it("roundtrips a request/response by id", function()
      local sock = H.loopback({
        handler = function(req)
          return {status = "ok", action = req.action, echoed = req.path}
        end
      })
      bridge.client_socket = sock
      bridge.current_ssh_host = "host"
      local res = bridge.perform_sync_request({action = "list_dir", path = "sub"})
      test.not_nil(res)
      test.equal(res.status, "ok")
      test.equal(res.action, "list_dir")
      test.equal(res.echoed, "sub")
      -- the request carried the generated id and was written to the socket
      test.equal(#sock.requests, 1)
      test.not_nil(sock.requests[1].id)
      test.equal(sock.requests[1].action, "list_dir")
    end)
    test.it("reassembles a frame split into single-byte reads", function()
      local sock = H.loopback({
        chunk_size = 1,
        handler = function(req)
          return {status = "ok", action = req.action, payload = "ok"}
        end
      })
      bridge.client_socket = sock
      local res = bridge.perform_sync_request({action = "file_info"})
      test.not_nil(res)
      test.equal(res.payload, "ok")
    end)
    test.it("ignores messages without id (async events) until the reply arrives", function()
      local sock = H.loopback({
        handler = function(req)
          return {
            {event = "agent_warning", message = "agent says hi"},
            {status = "ok", action = req.action}
          }
        end
      })
      bridge.client_socket = sock
      local res = bridge.perform_sync_request({action = "get_cwd"})
      test.not_nil(res)
      test.equal(res.status, "ok")
    end)
    test.it("reports and recovers from a malformed payload", function()
      -- A frame whose payload decodes to a non-table triggers core.error;
      -- the framing state machine must reset so the next valid frame works.
      local garbage_frame = string.pack(">I4", 1) .. string.char(0x01)
      local sock = H.loopback({
        handler = function(req)
          return { garbage_frame, {status = "ok", action = req.action} }
        end
      })
      bridge.client_socket = sock
      local cap = H.capture_errors()
      local res = bridge.perform_sync_request({action = "ping"})
      cap.restore()
      test.not_nil(res)
      test.equal(res.status, "ok")
      test.equal(#cap.messages >= 1, true)
      test.match(cap.messages[1], "MessagePack")
    end)
    test.it("disconnects and returns nil on socket read error", function()
      local sock = H.fakesocket({
        read_chunks = {},
        status = "success"
      })
      -- force read to return an error
      function sock:read() return nil, "connection reset" end
      bridge.client_socket = sock
      bridge.current_ssh_host = "host"
      local res = bridge.perform_sync_request({action = "x"})
      test.is_nil(res)
      test.is_nil(bridge.client_socket)
    end)
    test.it("disconnects when socket status is not success", function()
      local sock = H.fakesocket({status = "closed"})
      bridge.client_socket = sock
      bridge.current_ssh_host = "host"
      local res = bridge.perform_sync_request({action = "x"})
      test.is_nil(res)
      test.is_nil(bridge.client_socket)
    end)
  end)

  test.describe("update", function()
    test.it("is a no-op when not connected", function()
      test.no_error(function() bridge.update() end)
    end)
    test.it("processes queued agent_warning events into core.error", function()
      local event = H.framed({event = "agent_warning", message = "agent unreachable"})
      local sock = H.fakesocket({read_chunks = {event}})
      bridge.client_socket = sock
      bridge.current_ssh_host = "host"
      local cap = H.capture_errors()
      bridge.update() -- reads + queues the event
      bridge.update() -- drains the queue into core.error
      cap.restore()
      test.equal(#cap.messages >= 1, true)
      test.match(cap.messages[1], "agent unreachable")
    end)
    test.it("disconnects when socket status is not success", function()
      local sock = H.fakesocket({status = "closed"})
      bridge.client_socket = sock
      bridge.current_ssh_host = "host"
      bridge.update()
      test.is_nil(bridge.client_socket)
    end)
    test.it("disconnects on read error", function()
      local sock = H.fakesocket()
      function sock:read() return nil, "broken pipe" end
      bridge.client_socket = sock
      bridge.current_ssh_host = "host"
      bridge.update()
      test.is_nil(bridge.client_socket)
    end)
    test.it("reads and queues async events without a request", function()
      local event = H.framed({event = "process_output", id = "p1", data = "hello"})
      local sock = H.fakesocket({read_chunks = {event}})
      bridge.client_socket = sock
      bridge.current_ssh_host = "host"
      -- process_output is not agent_warning, so it is queued silently
      test.no_error(function() bridge.update() end)
      test.equal(bridge.is_connected(), true)
    end)
  end)

  test.describe("connect", function()
    test.it("returns true immediately when already connected", function()
      bridge.client_socket = H.fakesocket()
      local logs = {}
      local restore_log = H.swap(core, "log", function(fmt, ...) table.insert(logs, fmt) end)
      local ok = bridge.connect("host")
      restore_log()
      test.equal(ok, true)
      test.equal(logs[1] and logs[1]:find("already active", 1, true) ~= nil, true)
    end)
    test.it("returns false when the net module is unavailable", function()
      local old_net = rawget(_G, "net")
      rawset(_G, "net", nil)
      local cap = H.capture_errors()
      local ok = bridge.connect("host")
      cap.restore()
      rawset(_G, "net", old_net)
      test.equal(ok, false)
      test.equal(bridge.is_connected(), false)
      test.match(cap.messages[1], "net module")
    end)
    test.it("establishes a session against mocked ssh/net", function()
      local old_net = rawget(_G, "net")
      local old_start = process.start
      local connect_sock = H.loopback({
        handler = function(req)
          if req.action == "get_cwd" then
            return {status = "ok", action = "get_cwd", cwd = "/home/u"}
          elseif req.action == "change_dir" then
            return {status = "ok", action = "change_dir", cwd = "/srv"}
          end
          return {status = "error", message = "unknown"}
        end
      })
      rawset(_G, "net", {
        resolve_address = function(_ip) return H.fakeaddress("success") end,
        open_tcp = function(_addr, _port) return connect_sock end
      })
      process.start = function(args)
        if args[1] == "ssh-add" then
          return H.fakeproc({running_fn = function() return false end, returncode = 2})
        end
        return H.fakeproc({
          running_fn = function() return true end,
          stdout = {"READY\n"},
          returncode = 0
        })
      end
      local ok = bridge.connect("myhost", "/srv")
      process.start = old_start
      rawset(_G, "net", old_net)
      test.equal(ok, true)
      test.equal(bridge.is_connected(), true)
      test.equal(bridge.current_ssh_host, "myhost")
      test.equal(bridge.remote_cwd, "/srv")
      test.not_nil(bridge.ssh_proc)
    end)
    test.it("returns false when ssh process exits before READY", function()
      local old_net = rawget(_G, "net")
      local old_start = process.start
      rawset(_G, "net", {resolve_address = function() return H.fakeaddress() end})
      process.start = function(args)
        if args[1] == "ssh-add" then
          return H.fakeproc({running_fn = function() return false end, returncode = 2})
        end
        return H.fakeproc({
          running_fn = function() return false end,
          returncode = 1,
          stderr = {"Permission denied"}
        })
      end
      local cap = H.capture_errors()
      local ok = bridge.connect("badhost")
      cap.restore()
      process.start = old_start
      rawset(_G, "net", old_net)
      test.equal(ok, false)
      test.equal(bridge.is_connected(), false)
      test.match(cap.messages[1], "SSH process exited")
    end)
  end)
end)
