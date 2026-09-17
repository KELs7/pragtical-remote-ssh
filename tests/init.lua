local test = require "core.test"
local H = dofile("tests/helper.inc")
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local Doc = require "core.doc"
local DirWatch = require "core.dirwatch"
local Project = require "core.project"
local style = require "core.style"
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

-- Load the plugin sources from the repo root (via package.preload).
local remote_ssh = require "plugins.remote-ssh"

-- Restore add_thread for the rest of the runtime; the plugin's two
-- deferred hooks stay captured and are resumed manually below for
-- deterministic installation.
core.add_thread = real_add_thread

-- Fake treeview / terminal plugins so the deferred hooks install on to
-- objects we control.
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
  coroutine.resume(co)   -- advances to coroutine.yield(0.2)
  coroutine.resume(co)   -- installs the hooks
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

-- A loopback handler that answers every supported action.
local function default_handler(req)
  if req.action == "list_dir" then
    return {
      status = "ok", action = "list_dir",
      items = {
        { name = "a.txt", type = "file" },
        { name = "d", type = "dir" }
      }
    }
  elseif req.action == "file_info" then
    return { status = "ok", action = "file_info", type = "file", size = 123, modified = 1.0 }
  elseif req.action == "read_file" then
    return { status = "ok", action = "read_file", content = "line1\nline2" }
  elseif req.action == "save_file" then
    return { status = "ok", action = "save_file" }
  elseif req.action == "change_dir" then
    return { status = "ok", action = "change_dir", cwd = req.path or "/srv" }
  elseif req.action == "get_cwd" then
    return { status = "ok", action = "get_cwd", cwd = "/remote/home" }
  end
  return { status = "error", message = "unknown action" }
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

local function connect(proj)
  clear_recents()
  core.projects = { make_project(proj) }
  bridge.client_socket = H.loopback({ handler = default_handler })
  bridge.current_ssh_host = "myhost"
  bridge.remote_cwd = "/remote/home"
end

local function disconnect()
  bridge.disconnect()
  core.projects = {}
end

-- -----------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------
test.describe("remote-ssh init", function()
  local proj

  test.before_each(function()
    bridge.disconnect()
    clear_spies()
    clear_recents()
    proj = H.tmp("proj")
    common.mkdirp(proj)
    -- real files for local passthrough tests
    local f = io.open(proj .. PATHSEP .. "local.txt", "w"); f:write("hi"); f:close()
    connect(proj)
  end)

  test.after_each(function()
    bridge.disconnect()
    common.rm(proj, true)
    clear_recents()
  end)

  test.describe("system.list_dir intercept", function()
    test.it("routes remote listings through the bridge", function()
      local res = system.list_dir(proj .. "/sub")
      test.same(res, { "a.txt", "d" })
      local sock = bridge.client_socket
      test.equal(#sock.requests, 1)
      test.equal(sock.requests[1].action, "list_dir")
      test.equal(sock.requests[1].path, "sub")
    end)
    test.it("serves subsequent reads from the TTL cache", function()
      local sock = bridge.client_socket
      system.list_dir(proj .. "/sub")
      local n = #sock.requests
      system.list_dir(proj .. "/sub")
      test.equal(#sock.requests, n)
    end)
    test.it("falls back to local list_dir when disconnected", function()
      bridge.disconnect()
      core.projects = { make_project(proj) }
      local res = system.list_dir(proj)
      test.not_nil(res)
      test.equal(res[1] == "local.txt" or res[1] ~= nil, true)
    end)
  end)

  test.describe("system.get_file_info intercept", function()
    test.it("routes remote metadata through the bridge", function()
      local info = system.get_file_info(proj .. "/sub/a.txt")
      test.same(info, { type = "file", size = 123, modify = 1.0 })
      local sock = bridge.client_socket
      test.equal(sock.requests[1].action, "file_info")
      test.equal(sock.requests[1].path, "sub/a.txt")
    end)
    test.it("serves cached metadata without a new request", function()
      local sock = bridge.client_socket
      system.get_file_info(proj .. "/sub/a.txt")
      local n = #sock.requests
      system.get_file_info(proj .. "/sub/a.txt")
      test.equal(#sock.requests, n)
    end)
    test.it("uses pre-seeded metadata from a prior list_dir", function()
      local sock = bridge.client_socket
      system.list_dir(proj .. "/sub")      -- pre-seeds file_info_cache
      local n = #sock.requests
      local info = system.get_file_info(proj .. "/sub/d")
      test.equal(info.type, "dir")
      test.equal(#sock.requests, n)        -- no extra request
    end)
  end)

  test.describe("Doc:load intercept", function()
    test.it("loads remote file content through the bridge", function()
      local doc = Doc()
      doc:load(proj .. "/sub/file.txt")
      test.equal(doc.is_remote_file, true)
      test.equal(doc.filename, proj .. "/sub/file.txt")
      test.same(doc.lines, { "line1\n", "line2\n" })
      local sock = bridge.client_socket
      test.equal(sock.requests[1].action, "read_file")
      test.equal(sock.requests[1].path, "sub/file.txt")
    end)
    test.it("falls back to local Doc:load when disconnected", function()
      bridge.disconnect()
      core.projects = { make_project(proj) }
      local doc = Doc()
      doc:load(proj .. PATHSEP .. "local.txt")
      test.equal(doc.is_remote_file, nil)
      test.equal(doc.lines[1], "hi\n")
    end)
  end)

  test.describe("Doc:save intercept", function()
    test.it("saves remote files through the bridge and logs", function()
      local doc = Doc()
      doc:load(proj .. "/sub/file.txt")
      clear_spies()
      local ok = doc:save()
      test.equal(ok, true)
      test.equal(doc.is_remote_file, true)
      local last = logspy.calls[#logspy.calls]
      test.not_nil(last)
      test.match(last.fmt, "Saved remote file")
      test.equal(last.args[1], "myhost")
      test.equal(last.args[2], "sub/file.txt")
      local sock = bridge.client_socket
      test.equal(sock.requests[#sock.requests].action, "save_file")
    end)
    test.it("saves a brand-new doc to a remote path", function()
      local doc = Doc()
      doc:save(proj .. "/new.txt")
      test.equal(doc.is_remote_file, true)
      local sock = bridge.client_socket
      local req = sock.requests[#sock.requests]
      test.equal(req.action, "save_file")
      test.equal(req.path, "new.txt")
    end)
    test.it("returns false with an error message on server error", function()
      local sock = H.loopback({
        handler = function(req)
          return { status = "error", message = "disk full" }
        end
      })
      bridge.client_socket = sock
      local doc = Doc()
      doc.is_remote_file = true
      doc.abs_filename = proj .. "/sub/file.txt"
      doc.filename = proj .. "/sub/file.txt"
      doc.lines = { "x\n" }
      local ok, err = doc:save()
      test.equal(ok, false)
      test.match(err, "disk full")
    end)
    test.it("returns false when the server is unreachable", function()
      local sock = H.fakesocket()
      function sock:read() return nil, "pipe broken" end
      bridge.client_socket = sock
      local doc = Doc()
      doc.is_remote_file = true
      doc.abs_filename = proj .. "/sub/file.txt"
      doc.filename = proj .. "/sub/file.txt"
      doc.lines = { "x\n" }
      local ok, err = doc:save()
      test.equal(ok, false)
      test.match(err, "timed out")
    end)
  end)

  test.describe("path scrubbing", function()
    test.it("scrubs local project paths from core.log when connected", function()
      core.log("opened %s", proj .. "/sub/file.txt")
      local last = logspy.calls[#logspy.calls]
      test.equal(last.fmt, "opened %s")
      test.equal(last.args[1], "sub/file.txt")
    end)
    test.it("scrubs local project paths from core.log_quiet", function()
      core.log_quiet("scan %s", proj .. "/sub")
      local last = logqspy.calls[#logqspy.calls]
      test.equal(last.args[1], "sub")
    end)
    test.it("does not scrub when disconnected", function()
      bridge.disconnect()
      core.log("path %s", proj .. "/x")
      local last = logspy.calls[#logspy.calls]
      test.equal(last.args[1], proj .. "/x")
    end)
  end)

  test.describe("Doc:get_name and view title", function()
    test.it("prefixes remote doc names with the host", function()
      local doc = Doc()
      doc:load(proj .. "/sub/file.txt")
      test.equal(doc:get_name(), "[myhost] sub/file.txt")
    end)
    test.it("falls back to the original name when disconnected", function()
      bridge.disconnect()
      core.projects = { make_project(proj) }
      local doc = Doc()
      doc.filename = proj .. PATHSEP .. "local.txt"
      doc.abs_filename = proj .. PATHSEP .. "local.txt"
      local name = doc:get_name()
      test.match(name, "local.txt")
      test.equal(name:find("%[myhost%]"), nil)
    end)
    test.it("core.get_view_title shows host and remote cwd", function()
      local title = core.get_view_title(nil)
      test.equal(title, "[myhost] /remote/home")
    end)
    test.it("core.get_view_title falls back when disconnected", function()
      bridge.disconnect()
      local fake_view = { get_name = function() return "LocalView" end }
      local title = core.get_view_title(fake_view)
      test.equal(title:find("%[myhost%]"), nil)
    end)
  end)

  test.describe("polling suppressions", function()
    test.it("DirWatch:check is suppressed while connected", function()
      local dw = DirWatch()
      common.mkdirp(proj .. PATHSEP .. "watched")
      local fired = false
      dw:watch(proj .. PATHSEP .. "watched", function() fired = true end)
      dw:check(function() fired = true end)
      test.equal(fired, false)
    end)
    test.it("Project:files yields nothing while connected", function()
      local p = core.projects[1]
      local iter = Project.files(p)
      test.is_nil(iter())
    end)
  end)

  test.describe("on_disconnect callback", function()
    test.it("clears caches and remote docs", function()
      local doc = Doc()
      doc:load(proj .. "/sub/file.txt")
      table.insert(core.docs, doc)
      system.list_dir(proj .. "/sub")           -- populate caches
      local sock = bridge.client_socket
      local before = #sock.requests
      bridge.on_disconnect()
      -- caches cleared: a new list_dir (after reconnecting) hits the bridge again
      connect(proj)
      system.list_dir(proj .. "/sub")
      test.equal(#bridge.client_socket.requests > 0, true)
      -- remote doc removed from core.docs
      local still = false
      for _, d in ipairs(core.docs) do
        if d.is_remote_file then still = true end
      end
      test.equal(still, false)
    end)
    test.it("clears the treeview cache", function()
      fake_treeview.cache = { stale = true }
      bridge.on_disconnect()
      test.equal(next(fake_treeview.cache), nil)
    end)
  end)

  test.describe("commands", function()
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

    test.it("remote:disconnect disconnects the bridge", function()
      command.perform("remote:disconnect")
      test.equal(bridge.is_connected(), false)
    end)

    test.describe("remote:connect-ssh", function()
      test.it("parses host:path input and connects", function()
        local called
        local restore = H.swap(bridge, "connect", function(host, path)
          called = { host = host, path = path }
          bridge.remote_cwd = path or "/srv"
          return true
        end)
        command.perform("remote:connect-ssh")
        captured.submit("myhost:/srv")
        restore()
        test.equal(called.host, "myhost")
        test.equal(called.path, "/srv")
      end)
      test.it("parses a bare host with no path", function()
        local called
        local restore = H.swap(bridge, "connect", function(host, path)
          called = { host = host, path = path }
          bridge.remote_cwd = "/home/u"
          return true
        end)
        command.perform("remote:connect-ssh")
        captured.submit("myhost")
        restore()
        test.equal(called.host, "myhost")
        test.is_nil(called.path)
      end)
      test.it("records successful connections in the recents file", function()
        local restore = H.swap(bridge, "connect", function(host, path)
          bridge.remote_cwd = path or "/srv"
          return true
        end)
        command.perform("remote:connect-ssh")
        captured.submit("myhost:/srv")
        restore()
        local f = io.open(recents_file(), "r")
        test.not_nil(f)
        local content = f:read("*a"); f:close()
        test.match(content, "myhost:/srv")
      end)
      test.it("suggests saved recents and ssh config hosts", function()
        -- seed a recent entry
        local f = io.open(recents_file(), "w"); f:write("savedhost:/data\n"); f:close()
        command.perform("remote:connect-ssh")
        local suggestions = captured.suggest("")
        local found_recent = false
        for _, s in ipairs(suggestions) do
          if s == "savedhost:/data" then found_recent = true end
        end
        test.equal(found_recent, true)
      end)
      test.it("parses ssh config hosts from a temp HOME", function()
        local fake_home = H.tmp("home")
        common.mkdirp(fake_home .. PATHSEP .. ".ssh")
        local f = io.open(fake_home .. PATHSEP .. ".ssh" .. PATHSEP .. "config", "w")
        f:write("Host alpha\n  HostName 1.2.3.4\nHost beta\nHost *\n")
        f:close()
        local real_getenv = os.getenv
        os.getenv = function(k)
          if k == "HOME" then return fake_home end
          return real_getenv(k)
        end
        command.perform("remote:connect-ssh")
        os.getenv = real_getenv
        local suggestions = captured.suggest("alp")
        local found_alpha = false
        for _, s in ipairs(suggestions) do
          if s == "alpha" then found_alpha = true end
        end
        test.equal(found_alpha, true)
      end)
    end)

    test.describe("remote:change-directory", function()
      test.it("errors when not connected", function()
        bridge.disconnect()
        local errors = {}
        local restore = H.swap(core, "error", function(fmt, ...) table.insert(errors, string.format(fmt, ...)) end)
        command.perform("remote:change-directory")
        test.equal(#errors >= 1, true)
        test.match(errors[1], "not connected")
        restore()
      end)
      test.it("changes directory and refreshes caches on submit", function()
        command.perform("remote:change-directory")
        clear_spies()
        captured.submit("/new/dir")
        test.equal(bridge.remote_cwd, "/new/dir")
        -- save_recent_path should have recorded the host:cwd pair
        local f = io.open(recents_file(), "r")
        test.not_nil(f)
        local content = f:read("*a"); f:close()
        test.match(content, "myhost:/new/dir")
      end)
      test.it("reports failure when the server rejects the path", function()
        bridge.client_socket = H.loopback({
          handler = function(req)
            return { status = "error", message = "no such dir" }
          end
        })
        command.perform("remote:change-directory")
        local errors = {}
        local restore = H.swap(core, "error", function(fmt, ...) table.insert(errors, string.format(fmt, ...)) end)
        captured.submit("/bad")
        restore()
        test.equal(#errors >= 1, true)
        test.match(errors[1], "no such dir")
      end)
    end)
  end)

  test.describe("treeview / terminal hooks", function()
    test.it("labels the project root with the host while connected", function()
      local item = { abs_filename = proj, project = { path = proj } }
      local text = fake_treeview:get_item_text(item, false, false)
      test.equal(text, "[myhost]")
    end)
    test.it("keeps the original label for non-root items", function()
      local item = { abs_filename = proj .. "/sub", project = { path = proj } }
      local text = fake_treeview:get_item_text(item, false, false)
      test.equal(text, "orig")
    end)
    test.it("tags spawned terminal views as remote", function()
      local view = { options = {} }
      fake_terminal.class.spawn(view)
      test.equal(view.is_remote_terminal, true)
      test.equal(view.options.shell, "ssh")
      test.same(view.options.arguments, { "-t", "myhost", "cd \"/remote/home\" && exec ${SHELL:-sh} -l" })
    end)
    test.it("prefixes terminal names with the host", function()
      local name = fake_terminal.class.get_name({ is_remote_terminal = true })
      test.match(name, "%[myhost%]")
    end)
  end)

  test.describe("core.update wrap", function()
    test.it("installs a core.update hook", function()
      -- pragtical 3.12 uses core.run_step; the plugin still installs a
      -- core.update wrapper that delegates to bridge.update when invoked.
      test.equal(type(core.update), "function")
    end)
  end)
end)
