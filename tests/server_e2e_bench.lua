-- E2E benchmarks against the compiled headless server (no SSH).
--
-- Do NOT run directly: use bench-server.sh (repo root), which launches the
-- compiled server on a scratch working dir and points bridge.lua at it.
-- Requires PLUGIN_ROOT and PORT environment variables.
--
-- What is measured:
--   * 200 small request round-trips (get_cwd) -> per-request latency
--     (sensitive to TCP_NODELAY / Nagle).
--   * 4 MB save_file and read_file round-trips (sensitive to the JSON DOM
--     conversion and recvExactly allocation churn server-side).
--   * list_dir of 2000 entries (sensitive to per-entry JSON node building).

local plugin_root = os.getenv("PLUGIN_ROOT")
local test = require "core.test"
if not plugin_root then
  -- Not launched via bench-server.sh: nothing to benchmark against.
  -- (bench-server.sh sets PLUGIN_ROOT and PORT and starts the server.)
  test.skip("server e2e benchmarks", "run via bench-server.sh")
  return
end
local port = tonumber(os.getenv("PORT") or "8089")
local mp = dofile(plugin_root .. "/messagepack.lua")
-- bridge.lua requires the messagepack module via the plugins.<name> path;
-- preload it so the direct dofile works without an installed addon.
package.preload["plugins.remote-ssh.messagepack"] = function() return mp end
local bridge = dofile(plugin_root .. "/bridge.lua")

local function bench(label, fn)
  local t1 = system.get_time()
  local ret = fn()
  local dt = system.get_time() - t1
  print(string.format("[server-bench] %-40s %8.4f s", label, dt))
  return dt, ret
end

local net = rawget(_G, "net")
local addr = net.resolve_address("127.0.0.1")
addr:wait_until_resolved(1)
local sock
for i = 1, 50 do
  sock = net.open_tcp(addr, port)
  if sock then
    local ok = false
    for j = 1, 50 do
      if sock:wait_until_connected(0) == "success" then ok = true break end
    end
    if ok then break end
    sock:close()
  end
end
assert(sock, "failed to connect to headless server on port " .. port)
bridge.client_socket = sock
bridge.current_ssh_host = "bench"

local dt200 = bench("200 get_cwd round-trips", function()
  for _ = 1, 200 do
    local res = bridge.perform_sync_request({ action = "get_cwd" })
    assert(res and res.status == "ok", "get_cwd failed")
  end
end)
print(string.format("[server-bench]   per-request latency: %.3f ms", dt200 / 200 * 1000))

local payload = string.rep("x", 4 * 1024 * 1024)
bridge.perform_sync_request({ action = "save_file", path = "bench_big.bin", content = payload })
bench("4MB save_file round-trip", function()
  local res = bridge.perform_sync_request({ action = "save_file", path = "bench_big.bin", content = payload })
  assert(res and res.status == "ok", "save_file failed")
end)
bench("4MB read_file round-trip", function()
  local res = bridge.perform_sync_request({ action = "read_file", path = "bench_big.bin" })
  assert(res and res.content and #res.content == 4 * 1024 * 1024, "content length mismatch")
end)

bridge.perform_sync_request({ action = "make_dir", path = "bench_many" })
for i = 1, 2000 do
  local res = bridge.perform_sync_request({ action = "save_file", path = "bench_many/f" .. i, content = "" })
  assert(res and res.status == "ok", "setup save failed")
end
bench("list_dir of 2000 entries", function()
  local res = bridge.perform_sync_request({ action = "list_dir", path = "bench_many" })
  assert(res and res.items and #res.items == 2000, "item count mismatch")
end)

bridge.disconnect()
print("[server-bench] done")
