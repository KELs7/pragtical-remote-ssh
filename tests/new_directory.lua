-- Contract tests for the `remote:new-directory` command.
--
-- These tests define the expected behavior BEFORE the command is
-- implemented (TDD). They follow the same conventions as tests/init.lua:
--   * helper.inc preloads the repo-root plugin sources
--   * no real SSH: the bridge talks to a loopback fake socket
--   * all mocked async operations succeed/fail on the first iteration so
--     no test depends on a timeout elapsing (see LESSONS_LEARNED.md §5)
--
-- Expected contract (derived from remote:new-file and LESSONS_LEARNED §14):
--   1. Registered with the `bridge.is_connected` function predicate so the
--      command is listed in the palette whenever a remote session is
--      active, regardless of which view is focused.
--   2. Prompts with a command_view label mentioning a new remote directory.
--   3. On submit: maps the input to a remote path (get_remote_path of the
--      normalized project path) and sends a synchronous
--      { action = "make_dir", path = <remote path> } request to the bridge.
--   4. On status "ok": refreshes remote caches (list_dir/file_info/treeview)
--      so the new directory appears in the sidebar, and logs the creation.
--   5. On server error: surfaces the server message via core.error.
--   6. Suggests directories under the remote project (dir-only suggestions).

local test = require "core.test"
local H = dofile("tests/helper.inc")
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local bridge = require "plugins.remote-ssh.bridge"

-- -----------------------------------------------------------------------
-- Pre-require spies (must be in place before the plugin installs hooks)
-- -----------------------------------------------------------------------
local real_log = core.log
local real_logq = core.log_quiet

local function make_spy(real_fn)
  local s = { calls = {} }
  setmetatable(s, {
    __call = function(t, fmt, ...)
      local n = select("#", ...)
      table.insert(t.calls, { fmt = fmt, nargs = n, args = { ... } })
      return real_fn(fmt, ...)
    end
  })
  return s
end

local logspy = make_spy(real_log)
local logqspy = make_spy(real_logq)
core.log = logspy
core.log_quiet = logqspy

local captured_threads = {}
local real_add_thread = core.add_thread
core.add_thread = function(fn, ...)
  table.insert(captured_threads, fn)
end

local remote_ssh = require "plugins.remote-ssh"
core.add_thread = real_add_thread

-- Fake treeview / terminal plugins so the deferred hooks install on to
-- objects we control (same pattern as tests/init.lua).
local fake_treeview = {
  cache = { stale = true },
  get_item_text = function(self, item, active, hovered)
    return "orig", style.font, style.text
  end
}
local fake_terminal = {
  class = {
    spawn = function(self) end,
    get_name = function(self) return "term" end
  }
}
package.loaded["plugins.treeview"] = fake_treeview
package.loaded["plugins.terminal"] = fake_terminal

-- Resume the captured thread bodies past their `coroutine.yield(0.2)` so
-- the treeview and terminal overrides are installed immediately.
for _, fn in ipairs(captured_threads) do
  local co = coroutine.create(fn)
  coroutine.resume(co)
  coroutine.resume(co)
end

-- -----------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------
local function clear_spies()
  logspy.calls = {}
  logqspy.calls = {}
end

local function recents_file()
  return (USERDIR or os.getenv("HOME")) .. PATHSEP .. "remote_ssh_recents.txt"
end

local function clear_recents()
  os.remove(recents_file())
end

-- A loopback handler that answers the actions the command may touch.
local function make_handler(overrides)
  return function(req)
    if overrides and overrides[req.action] then
      return overrides[req.action](req)
    end
    if req.action == "list_dir" then
      return {
        status = "ok", action = "list_dir",
        items = {
          { name = "existing", type = "dir" },
          { name = "a.txt", type = "file" }
        }
      }
    elseif req.action == "make_dir" then
      return { status = "ok", action = "make_dir", path = req.path }
    elseif req.action == "file_info" then
      return { status = "ok", action = "file_info", type = "file", size = 1, modified = 1.0 }
    end
    return { status = "error", message = "unknown action: " .. tostring(req.action) }
  end
end

local function make_project(proj)
  return {
    path = proj,
    absolute_path = function(_, path)
      if common.is_absolute_path(path) then return path end
      return proj .. PATHSEP .. path
    end,
    path_belongs_to = function(_, filename)
      return common.path_belongs_to(filename, proj)
    end,
    get_file_info = function(_, path)
      return system.get_file_info(path)
    end,
    normalize_path = function(_, path)
      return path
    end
  }
end

local function connect(proj, overrides)
  clear_recents()
  core.projects = { make_project(proj) }
  bridge.client_socket = H.loopback({ handler = make_handler(overrides) })
  bridge.current_ssh_host = "myhost"
  bridge.remote_cwd = "/remote/home"
end

local function disconnect()
  bridge.disconnect()
  core.projects = {}
end

local function find_request(sock, action)
  for i = #sock.requests, 1, -1 do
    if sock.requests[i].action == action then
      return sock.requests[i]
    end
  end
  return nil
end

-- -----------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------
test.describe("remote:new-directory", function()
  local proj

  test.before_each(function()
    bridge.disconnect()
    clear_spies()
    clear_recents()
    proj = H.tmp("proj")
    common.mkdirp(proj)
    connect(proj)
  end)

  test.after_each(function()
    bridge.disconnect()
    common.rm(proj, true)
    clear_recents()
  end)

  test.describe("registration", function()
    test.it("command exists in the command map", function()
      test.not_nil(command.map["remote:new-directory"])
    end)

    test.it("is valid when connected (function predicate)", function()
      test.equal(command.is_valid("remote:new-directory"), true)
    end)

    test.it("is invalid when disconnected", function()
      bridge.disconnect()
      test.equal(command.is_valid("remote:new-directory"), false)
    end)
  end)

  test.describe("prompt", function()
    local captured
    test.before_each(function()
      captured = nil
      core.command_view.enter = function(_self, label, opts)
        captured = { label = label, submit = opts.submit, suggest = opts.suggest }
      end
    end)

    test.it("prompts for a new remote directory", function()
      command.perform("remote:new-directory")
      test.not_nil(captured)
      test.match(captured.label, "[Dd]irectory")
    end)

    test.it("provides a suggest function", function()
      command.perform("remote:new-directory")
      test.equal(type(captured.suggest), "function")
    end)
  end)

  test.describe("submit", function()
    local captured
    test.before_each(function()
      bridge.disconnect()
      clear_recents()
      connect(proj)
      captured = nil
      core.command_view.enter = function(_self, label, opts)
        captured = { label = label, submit = opts.submit, suggest = opts.suggest }
      end
    end)

    test.it("sends a make_dir request with the remote path", function()
      command.perform("remote:new-directory")
      local sock = bridge.client_socket
      local before = #sock.requests
      -- root_view:open_doc is unavailable in headless test mode; the
      -- command must not depend on it. No-op it defensively like
      -- tests/init.lua does for remote:new-file.
      local restore_opendoc = H.swap(core.root_view, "open_doc", function() end)
      captured.submit("sub/newdir")
      restore_opendoc()
      local req = find_request(sock, "make_dir")
      test.not_nil(req)
      test.equal(req.path, "sub/newdir")
      test.equal(#sock.requests, before + 1)
    end)

    test.it("does not send a request for empty input", function()
      command.perform("remote:new-directory")
      local sock = bridge.client_socket
      local before = #sock.requests
      captured.submit("")
      captured.submit(nil)
      test.equal(#sock.requests, before)
    end)

    test.it("refreshes remote caches on success", function()
      command.perform("remote:new-directory")
      local sock = bridge.client_socket
      -- populate the list_dir cache first
      system.list_dir(proj .. "/sub")
      local before = #sock.requests
      local restore_opendoc = H.swap(core.root_view, "open_doc", function() end)
      captured.submit("sub/newdir")
      restore_opendoc()
      local mk = find_request(sock, "make_dir")
      test.equal(find_request(sock, "make_dir") ~= nil, true)
      -- refresh: cache cleared so the next listing re-hits the bridge
      test.equal(next(fake_treeview.cache), nil)
      system.list_dir(proj .. "/sub")
      test.equal(#sock.requests > before, true)
    end)

    test.it("logs the created directory", function()
      command.perform("remote:new-directory")
      clear_spies()
      local restore_opendoc = H.swap(core.root_view, "open_doc", function() end)
      captured.submit("sub/newdir")
      restore_opendoc()
      local last = logspy.calls[#logspy.calls]
      test.not_nil(last)
      test.match(last.fmt, "[Dd]irectory")
    end)

    test.it("surfaces the server error message on failure", function()
      command.perform("remote:new-directory")
      bridge.client_socket = H.loopback({
        handler = function(req)
          if req.action == "make_dir" then
            return { status = "error", message = "permission denied" }
          end
          return make_handler()(req)
        end
      })
      local errors = {}
      local restore_error = H.swap(core, "error", function(fmt, ...)
        table.insert(errors, string.format(fmt, ...))
      end)
      local restore_opendoc = H.swap(core.root_view, "open_doc", function() end)
      captured.submit("sub/newdir")
      restore_opendoc()
      restore_error()
      test.equal(#errors >= 1, true)
      test.match(errors[1], "permission denied")
    end)

    test.it("surfaces an error when the server is unreachable", function()
      command.perform("remote:new-directory")
      local sock = H.fakesocket()
      function sock:read() return nil, "pipe broken" end
      bridge.client_socket = sock
      local errors = {}
      local restore_error = H.swap(core, "error", function(fmt, ...)
        table.insert(errors, string.format(fmt, ...))
      end)
      local restore_opendoc = H.swap(core.root_view, "open_doc", function() end)
      captured.submit("sub/newdir")
      restore_opendoc()
      restore_error()
      -- perform_sync_request disconnects on read error; the command must
      -- fail gracefully without hanging (iteration-one break, no timeout).
      test.equal(#errors >= 1, true)
      test.equal(bridge.is_connected(), false)
    end)
  end)

  test.describe("suggest", function()
    local captured
    test.before_each(function()
      captured = nil
      core.command_view.enter = function(_self, label, opts)
        captured = { label = label, submit = opts.submit, suggest = opts.suggest }
      end
    end)

    test.it("suggests directories under the remote project", function()
      command.perform("remote:new-directory")
      local sugg = captured.suggest("")
      test.equal(type(sugg), "table")
      test.equal(#sugg > 0, true)
      -- dir-only: files must not be suggested
      for _, s in ipairs(sugg) do
        test.equal(s:find("a%.txt"), nil)
      end
    end)

    test.it("filters suggestions by the typed prefix", function()
      command.perform("remote:new-directory")
      local sugg = captured.suggest("exi")
      test.equal(type(sugg), "table")
      local found = false
      for _, s in ipairs(sugg) do
        if s == "existing" .. PATHSEP then found = true end
      end
      test.equal(found, true)
    end)
  end)
end)
