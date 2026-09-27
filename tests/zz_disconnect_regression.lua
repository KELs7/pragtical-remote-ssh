-- Regression tests for the remote:disconnect crash + stale treeview.
--
-- Bug: on_disconnect passed `core.root_view` (a RootView object) to
-- node:close_view, but remove_view/get_parent_node need a Node
-- (core.root_view.root_node). When a remote doc was alone in its leaf node,
-- get_parent_node indexed root.a on the RootView (nil) and errored:
--   node.lua:292: attempt to index local 'root' (a nil value)
-- The exception aborted on_disconnect midway, so the treeview cache clear
-- at the end never ran -- leaving stale remote listings (zeearm/, data/,
-- gzz/) rendered under the local project root after disconnecting.
--
-- Contract:
--   1. on_disconnect passes core.root_view.root_node (the Node) to
--      close_view, matching core's own pattern (commands/doc.lua:692).
--   2. A failing close_view cannot abort on_disconnect: the treeview cache
--      clear and core.redraw always run (pcall around each close).

local test = require "core.test"
local H = dofile("tests/helper.inc")
local core = require "core"
local bridge = require "plugins.remote-ssh.bridge"

-- Load the plugin (installs hooks + on_disconnect).
local captured_threads = {}
local real_add_thread = core.add_thread
core.add_thread = function(fn, ...) table.insert(captured_threads, fn) end
local remote_ssh = require "plugins.remote-ssh"
core.add_thread = real_add_thread

-- Fake treeview/terminal plugins for the deferred hooks.
local fake_treeview = { cache = {}, get_item_text = function() return "orig", nil, nil end }
local fake_terminal = { class = { spawn = function() end, get_name = function() return "t" end } }
package.loaded["plugins.treeview"] = fake_treeview
package.loaded["plugins.terminal"] = fake_terminal

for _, fn in ipairs(captured_threads) do
  local co = coroutine.create(fn)
  coroutine.resume(co)
  coroutine.resume(co)
end

-- A fake remote doc view: try_close records the callback instead of
-- prompting (matching a non-dirty doc, so close proceeds synchronously).
local function fake_remote_view()
  return {
    doc = { is_remote_file = true },
    try_close = function(self, do_close) self.do_close_cb = do_close end,
    close = function() end,
    is = function() return false end
  }
end

-- Swap the root node's view lookup to return a fake node we control.
local function install_fake_node(node_fn)
  local root_node = core.root_view.root_node
  local old_children = root_node.get_children
  local old_lookup = root_node.get_node_for_view
  root_node.get_children = function() return { node_fn.view } end
  root_node.get_node_for_view = function(_self, _view) return node_fn.node end
  return function()
    root_node.get_children = old_children
    root_node.get_node_for_view = old_lookup
  end
end

test.describe("disconnect regression", function()
  test.before_each(function()
    bridge.disconnect()
    bridge.on_disconnect = rawget(bridge, "on_disconnect")
    fake_treeview.cache = {}
  end)

  test.it("passes the root node (not root_view) to close_view", function()
    local view = fake_remote_view()
    local captured
    local restore = install_fake_node({
      view = view,
      node = {
        close_view = function(_self, root, v)
          captured = { root = root, view = v }
        end
      }
    })
    bridge.on_disconnect()
    restore()
    test.not_nil(captured)
    test.equal(captured.root, core.root_view.root_node)
    test.equal(captured.view, view)
  end)

  test.it("does not error when a remote doc is alone in its node", function()
    local view = fake_remote_view()
    -- a node whose close_view raises, like the real remove_view did when
    -- handed a RootView instead of a Node
    local restore = install_fake_node({
      view = view,
      node = {
        close_view = function() error("node.lua:292: attempt to index local 'root' (a nil value)") end
      }
    })
    test.no_error(function() bridge.on_disconnect() end)
    restore()
  end)

  test.it("clears the treeview cache even when closing a view fails", function()
    local view = fake_remote_view()
    fake_treeview.cache = { ["/remote/zeearm"] = { name = "zeearm" } }
    local restore = install_fake_node({
      view = view,
      node = {
        close_view = function() error("simulated node failure") end
      }
    })
    bridge.on_disconnect()
    restore()
    -- the cache reset must have run despite the failed close
    test.equal(next(fake_treeview.cache), nil)
    test.equal(core.redraw, true)
  end)

  test.it("removes remote docs from core.docs even when closing fails", function()
    local view = fake_remote_view()
    local doc = { is_remote_file = true }
    table.insert(core.docs, doc)
    local restore = install_fake_node({
      view = view,
      node = {
        close_view = function() error("simulated node failure") end
      }
    })
    bridge.on_disconnect()
    restore()
    local still = false
    for _, d in ipairs(core.docs) do
      if d == doc then still = true end
    end
    test.equal(still, false)
  end)

  -- Collapse regression: the expanded state must only be dropped at
  -- DISCONNECT time, never by the periodic refresh paths (refresh_remote),
  -- or every open directory collapses on each refresh tick.
  test.it("clear_treeview_cache keeps expanded state", function()
    fake_treeview.cache = { stale = true }
    fake_treeview.expanded = { ["/remote/zeearm"] = true }
    remote_ssh.clear_treeview_cache()
    test.equal(next(fake_treeview.cache), nil)       -- cache cleared
    test.equal(fake_treeview.expanded["/remote/zeearm"], true)  -- expansion kept
  end)

  test.it("clear_treeview_remote_state drops remote-path expanded state", function()
    fake_treeview.cache = { stale = true }
    fake_treeview.expanded = {
      ["/remote/zeearm"] = true,
      ["/remote/zeearm/data"] = true,
      ["/local/other"] = true
    }
    -- seed the project paths cache so the remote roots are known
    bridge.client_socket = H.loopback({ handler = function() return { status = "ok" } end })
    bridge.current_ssh_host = "h"
    core.projects = { { path = "/remote/zeearm" } }
    remote_ssh.clear_treeview_remote_state()
    test.equal(fake_treeview.expanded["/remote/zeearm"], nil)
    test.equal(fake_treeview.expanded["/remote/zeearm/data"], nil)
    test.equal(fake_treeview.expanded["/local/other"], true)  -- local kept
    bridge.disconnect()
    core.projects = {}
  end)

  test.it("clear_treeview_remote_state removes watches safely", function()
    local proj = { path = "/remote/zeearm" }
    fake_treeview.watches = { [proj] = true }
    bridge.client_socket = H.loopback({ handler = function() return { status = "ok" } end })
    bridge.current_ssh_host = "h"
    core.projects = { proj }
    test.no_error(function() remote_ssh.clear_treeview_remote_state() end)
    test.equal(fake_treeview.watches[proj], nil)
    bridge.disconnect()
    core.projects = {}
  end)
end)
