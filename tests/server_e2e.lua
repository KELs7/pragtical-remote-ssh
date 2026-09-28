-- Real loopback TCP integration tests against the compiled headless server.
--
-- Each test launches the actual Nim binary on a scratch working dir, wires a
-- real net.tcp socket to it, and exercises bridge.perform_sync_request over
-- real TCP. This is the only seam that covers real framing-over-wire, real
-- Nagle/TCP_NODELAY behavior, real read-buffer semantics (the 64 KB read
-- path), real partial-write draining, real disconnect detection, and real
-- server-side error paths -- fake sockets cannot (LESSONS §35). The fake-
-- socket unit bench is blind to all of these.
--
-- Skipped automatically when the compiled binary is absent (non-Linux hosts)
-- per LESSONS §38. No SSH -- transport stays bypassed; the bridge's
-- framing/request layer is below transport.

local test = require "core.test"
local H = dofile("tests/helper.inc")
local core = require "core"

-- Preload the codec + bridge so require resolves the repo-root sources.
package.preload["plugins.remote-ssh.messagepack"] = function()
  return H.mp
end
package.preload["plugins.remote-ssh.bridge"] = function()
  return dofile("bridge.lua")
end
local bridge = require "plugins.remote-ssh.bridge"

-- Skip the whole file if the compiled binary is not present.
do
  local binary = system.getcwd() ..
    "/built-binaries/ubuntu-24/x86_64/headless-server"
  local f = io.open(binary, "r")
  if not f then
    test.skip("real-server e2e",
      "compiled headless-server binary unavailable (non-Linux host)")
    return
  end
  f:close()
end

-- Each test gets its own server (and its own socket); bridge.disconnect()
-- closes the socket, so a shared socket cannot survive across tests.
local server

local function wire()
  bridge.client_socket = server.sock
  bridge.current_ssh_host = "e2e"
  bridge.remote_cwd = "/srv"
end

test.describe("real-server e2e", function()
  test.before_each(function()
    server = H.real_server {}
    wire()
  end)
  test.after_each(function()
    if server then server.teardown() end
    server = nil
  end)

  test.it("round-trips get_cwd over real TCP", function()
    local res = bridge.perform_sync_request({ action = "get_cwd" })
    test.not_nil(res)
    test.equal(res.status, "ok")
    test.equal(type(res.cwd), "string")
  end)

  test.it("list_dir reflects the server's scratch working dir", function()
    -- The server CWD is the scratch workdir; create a file there so list_dir
    -- returns a known entry.
    local f = io.open(server.workdir .. "/marker.txt", "w")
    f:write("x"); f:close()
    local res = bridge.perform_sync_request({
      action = "list_dir", path = "." })
    test.not_nil(res)
    test.equal(res.status, "ok")
    local found = false
    for _, item in ipairs(res.items or {}) do
      if item.name == "marker.txt" then found = true end
    end
    test.equal(found, true)
  end)

  test.it("transfers a 4 MB file over real TCP (write drain + 64 KB reads)", function()
    local payload = string.rep("x", 4 * 1024 * 1024)
    local saved = bridge.perform_sync_request({
      action = "save_file", path = "big.bin", content = payload })
    test.not_nil(saved)
    test.equal(saved.status, "ok")
    local read = bridge.perform_sync_request({
      action = "read_file", path = "big.bin" })
    test.not_nil(read)
    test.equal(read.status, "ok")
    test.equal(#read.content, 4 * 1024 * 1024)
  end)

  test.it("surfaces a server-side write permission error", function()
    -- A read-only subdirectory under the server CWD makes writeFile raise,
    -- which the server reports as { status = "error", message = ... }.
    os.execute("mkdir -p " .. server.workdir .. "/locked")
    os.execute("chmod 000 " .. server.workdir .. "/locked")
    local res = bridge.perform_sync_request({
      action = "save_file", path = "locked/x.txt", content = "" })
    -- restore perms before assertions so teardown's rm -rf always works
    os.execute("chmod 700 " .. server.workdir .. "/locked")
    test.not_nil(res)
    test.equal(res.status, "error")
  end)

  test.it("detects server-side disconnect and fires on_disconnect", function()
    local fired = false
    local saved_on_disconnect = bridge.on_disconnect
    bridge.on_disconnect = function() fired = true end
    -- Kill the remote server process; the next read returns nil+err and the
    -- bridge disconnects (read-error path -- the explicit get_status check
    -- only runs in the no-data branch now).
    server.proc:terminate()
    local t0 = system.get_time()
    while server.proc:running() and system.get_time() - t0 < 2 do
      system.sleep(0.01)
    end
    local res = bridge.perform_sync_request({ action = "get_cwd" })
    -- restore before assertions so the plugin's real on_disconnect survives
    -- for later test files (the zz_disconnect_regression suite relies on it)
    bridge.on_disconnect = saved_on_disconnect
    test.is_nil(res)
    test.equal(bridge.is_connected(), false)
    test.equal(fired, true)
  end)
end)
