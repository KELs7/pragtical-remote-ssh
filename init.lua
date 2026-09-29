-- mod-version:3.11
-- ^ Strictly required. Do not place any blank lines or comments before it.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local Doc = require "core.doc"
local Project = require "core.project"
local DirWatch = require "core.dirwatch"
local style = require "core.style"

local parent_path = (... or "plugins.remote-ssh")
local bridge = require(parent_path .. ".bridge")

-- =====================================================================
-- WORKSPACE CONFIGURATION AND VARIABLES
-- =====================================================================

-- High-performance metadata caches
local file_info_cache = {}
local list_dir_cache = {}

-- Optimized TTL durations to eliminate synchronous bottlenecks during UI redraws
local FILE_INFO_TTL = 300.0 -- 5 Minutes: File metadata remains cached during active sessions
local LIST_DIR_TTL = 120.0  -- 2 Minutes: Directory structure remains cached during navigation

-- Cached project paths to avoid redundant CPU overhead on every file access
local project_paths_cache = {}

-- Standardizes path formats to guarantee cache key alignment
local function normalize_path(path)
  if type(path) ~= "string" then return path end
  local normalized = path:gsub("\\", "/"):gsub("//+", "/")
  if normalized:sub(-1) == "/" and #normalized > 1 then
    normalized = normalized:sub(1, -2)
  end
  return normalized
end

-- Lazily retrieves and caches normalized project paths
local function get_normalized_project_paths()
  if #project_paths_cache == 0 and bridge.is_connected() then
    for _, project in ipairs(core.projects) do
      table.insert(project_paths_cache, normalize_path(project.path))
    end
  end
  return project_paths_cache
end

-- Setup the disconnection hook to handle local workspace and editor UI resets
local clear_treeview_cache  -- forward declaration; defined below near refresh_remote
local clear_treeview_remote_state  -- forward declaration; defined below
bridge.on_disconnect = function()
  file_info_cache = {}
  list_dir_cache = {}
  project_paths_cache = {}

  -- Close any active remote document tabs (views)
  local views = core.root_view.root_node:get_children()
  local views_to_close = {}
  for _, view in ipairs(views) do
    if view.doc and view.doc.is_remote_file then
      table.insert(views_to_close, view)
    end
  end
  for _, view in ipairs(views_to_close) do
    local node = core.root_view.root_node:get_node_for_view(view)
    if node then
      -- remove_view walks the node tree via root.a/root.b, so it needs a
      -- Node (root_node), not the RootView object (passing the latter
      -- errors with 'attempt to index local root (a nil value)' when the
      -- doc is alone in its leaf node). pcall so one failing close cannot
      -- skip the cache resets and redraw below.
      pcall(node.close_view, node, core.root_view.root_node, view)
    end
  end

  -- Remove remote documents from the global document list
  for i = #core.docs, 1, -1 do
    if core.docs[i].is_remote_file then
      table.remove(core.docs, i)
    end
  end

  -- Safely close any active remote terminals before resetting workspace
  local terminal_plugin = package.loaded["plugins.terminal"]
  if terminal_plugin and terminal_plugin.class then
    local TerminalView = terminal_plugin.class
    local views = core.root_view.root_node:get_children()
    local to_close = {}
    
    for _, view in ipairs(views) do
      if view:is(TerminalView) and view.is_remote_terminal then
        table.insert(to_close, view)
      end
    end
    
    for _, view in ipairs(to_close) do
      pcall(view.close, view)
    end
  end
  
  -- Clear the TreeView sidebar cache and drop remote-path watch/expand
  -- state so stale remote directories are not re-watched or re-expanded
  -- locally after disconnecting.
  clear_treeview_remote_state()

  core.redraw = true
end

-- Helper to sanitize paths by stripping the local project root prefix
local function strip_local_path(str)
  if type(str) ~= "string" then return str end
  local projects = get_normalized_project_paths()
  for _, proj_path in ipairs(projects) do
    local escaped_path = proj_path:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    str = str:gsub(escaped_path .. "[/\\]", "")
    str = str:gsub(escaped_path, ".")
  end
  return str
end

-- Maps a local workspace absolute path to a relative remote server path
local function get_remote_path(norm_path)
  local projects = get_normalized_project_paths()
  for _, proj_path in ipairs(projects) do
    if norm_path == proj_path then
      return "."
    elseif norm_path:sub(1, #proj_path + 1) == proj_path .. "/" then
      return norm_path:sub(#proj_path + 2)
    end
  end
  return norm_path
end

-- Helper to determine if a given path belongs to the remote workspace project
local function is_path_remote(norm_path)
  if not bridge.is_connected() then return false end
  local projects = get_normalized_project_paths()
  for _, proj_path in ipairs(projects) do
    if norm_path == proj_path or norm_path:sub(1, #proj_path + 1) == proj_path .. "/" then
      return true
    end
  end
  return false
end

-- Clears cache for a given file and its parent folder to guarantee consistency on writes
local function invalidate_cache(path)
  local norm_path = normalize_path(path)
  file_info_cache[norm_path] = nil
  local parent = norm_path:match("^(.+)/.-$")
  if parent then
    list_dir_cache[parent] = nil
  end
end

-- Clears the TreeView sidebar cache so the next draw re-queries the
-- filesystem. The treeview module IS the view instance (treeview.lua
-- creates `local view = TreeView()` and returns it), so the cache lives
-- directly on package.loaded["plugins.treeview"]. Deliberately does NOT
-- touch view.expanded/watches: this runs on every refresh (new-file,
-- remote:refresh, terminal focus changes), and dropping expanded state
-- there would collapse every open directory (and nil-ing watches entries
-- while the treeview's own DirWatch thread iterates the same table is
-- undefined behavior).
function clear_treeview_cache()
  local tv = package.loaded["plugins.treeview"]
  if tv and tv.cache then tv.cache = {} end
end

-- Disconnect-time TreeView cleanup: in addition to the cache, drop the
-- DirWatch and expanded entries for remote workspace paths so stale remote
-- directories are not re-watched or re-expanded locally. Called once per
-- disconnect -- not from the periodic refresh paths.
function clear_treeview_remote_state()
  local tv = package.loaded["plugins.treeview"]
  if not tv then return end
  clear_treeview_cache()
  local remote_paths = get_normalized_project_paths()
  if next(remote_paths) == nil then return end
  if tv.watches then
    -- collect first, then remove: modifying a table during pairs()
    -- iteration is undefined behavior in Lua
    local to_remove = {}
    for project in pairs(tv.watches) do
      for _, proj_path in ipairs(remote_paths) do
        if project and project.path == proj_path then
          to_remove[project] = true
        end
      end
    end
    for project in pairs(to_remove) do
      tv.watches[project] = nil
    end
  end
  if tv.expanded then
    for path in pairs(tv.expanded) do
      for _, proj_path in ipairs(remote_paths) do
        if type(path) == "string" and path:sub(1, #proj_path) == proj_path then
          tv.expanded[path] = nil
        end
      end
    end
  end
end

-- Clears every remote filesystem cache and the TreeView sidebar cache so the
-- next access re-queries the remote host. Used after remote mutations (new
-- file creation) and by the `remote:refresh` command so the sidebar reflects
-- changes made outside of the editor (e.g. files created in the SSH terminal).
local function refresh_remote()
  list_dir_cache = {}
  file_info_cache = {}
  clear_treeview_cache()
  core.redraw = true
end

-- Parses user ~/.ssh/config purely for Host alias suggestions
local function get_ssh_hosts()
  local home = os.getenv("HOME") or os.getenv("USERPROFILE")
  if not home then return {} end
  
  local config_path = home .. "/.ssh/config"
  if PLATFORM == "windows" then
    config_path = config_path:gsub("/", "\\")
  end
  
  local f = io.open(config_path, "r")
  if not f then return {} end
  
  local hosts = {}
  for line in f:lines() do
    local host_line = line:match("^%s*[Hh][Oo][Ss][Host]%s+(.+)$")
    if not host_line then
      host_line = line:match("^%s*[Hh][Oo][Ss][Host]%s+(.+)$")
    end
    if host_line then
      for host in host_line:gmatch("%S+") do
        if host ~= "*" and not host:match("[?*]") then
          table.insert(hosts, host)
        end
      end
    end
  end
  f:close()
  return hosts
end

local function get_history_file()
  local dir = USERDIR or os.getenv("HOME") or os.getenv("USERPROFILE") or "."
  return dir .. "/remote_ssh_recents.txt"
end

local function load_recent_paths()
  local file = io.open(get_history_file(), "r")
  if not file then return {} end
  local recents = {}
  local seen = {}
  for line in file:lines() do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and not seen[line] then
      seen[line] = true
      table.insert(recents, line)
    end
  end
  file:close()
  return recents
end

local function save_recent_path(host, path)
  if not host or not path or path == "" then return end
  local norm = normalize_path(path)
  local entry = host .. ":" .. norm
  local recents = load_recent_paths()
  local new_recents = { entry }
  for _, item in ipairs(recents) do
    if item ~= entry then
      table.insert(new_recents, item)
    end
  end
  while #new_recents > 50 do
    table.remove(new_recents)
  end
  local file = io.open(get_history_file(), "w")
  if file then
    for _, item in ipairs(new_recents) do
      file:write(item .. "\n")
    end
    file:close()
  end
end

local function get_history_file()
  local dir = USERDIR or os.getenv("HOME") or os.getenv("USERPROFILE") or "."
  return dir .. "/remote_ssh_recents.txt"
end

local function load_recent_paths()
  local file = io.open(get_history_file(), "r")
  if not file then return {} end
  local recents = {}
  local seen = {}
  for line in file:lines() do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and not seen[line] then
      seen[line] = true
      table.insert(recents, line)
    end
  end
  file:close()
  return recents
end

local function save_recent_path(host, path)
  if not host or not path or path == "" then return end
  local norm = normalize_path(path)
  local entry = host .. ":" .. norm
  local recents = load_recent_paths()
  local new_recents = { entry }
  for _, item in ipairs(recents) do
    if item ~= entry then
      table.insert(new_recents, item)
    end
  end
  while #new_recents > 50 do
    table.remove(new_recents)
  end
  local file = io.open(get_history_file(), "w")
  if file then
    for _, item in ipairs(new_recents) do
      file:write(item .. "\n")
    end
    file:close()
  end
end


-- =====================================================================
-- WORKSPACE API INTERCEPTS & REDIRECTIONS (CACHE AWARE)
-- =====================================================================

local original_list_dir = system.list_dir
local original_get_file_info = system.get_file_info

-- Intercept folder list scans with attribute caching and metadata pre-seeding
function system.list_dir(path)
  local norm_path = normalize_path(path)
  if is_path_remote(norm_path) then
    local now = system.get_time()
    local cached = list_dir_cache[norm_path]
    if cached and (now - cached.time < LIST_DIR_TTL) then
      return cached.data
    end

    local remote_path = get_remote_path(norm_path)
    local res = bridge.perform_sync_request({
      action = "list_dir",
      path = remote_path
    })
    
    local data = nil
    if res and res.status == "ok" then
      data = {}
      for _, item in ipairs(res.items) do
        table.insert(data, item.name)

        -- Pre-seed file_info_cache with normalized path keys to eliminate subsequent O(N) network hits!
        local item_path = normalize_path(norm_path .. "/" .. item.name)
        file_info_cache[item_path] = {
          time = now,
          data = {
            type = item.type, -- "file" or "dir"
            size = 0,         -- Lazily resolved later if specifically requested
            modify = 0
          }
        }
      end
    end
    
    list_dir_cache[norm_path] = {
      time = now,
      data = data
    }
    return data
  else
    return original_list_dir(path)
  end
end

-- Intercept metadata check scans with attribute caching
function system.get_file_info(path)
  local norm_path = normalize_path(path)
  if is_path_remote(norm_path) then
    local now = system.get_time()
    local cached = file_info_cache[norm_path]
    if cached and (now - cached.time < FILE_INFO_TTL) then
      return cached.data
    end

    local remote_path = get_remote_path(norm_path)
    local res = bridge.perform_sync_request({
      action = "file_info",
      path = remote_path
    })
    
    local data = nil
    if res and res.status == "ok" then
      data = {
        type = res.type, -- "file" or "dir"
        size = res.size or 0,
        modify = res.modified or 0
      }
    end
    
    file_info_cache[norm_path] = {
      time = now,
      data = data
    }
    return data
  else
    return original_get_file_info(path)
  end
end

-- Intercept Document File loading
local original_doc_load = Doc.load
function Doc:load(filename)
  local norm_filename = normalize_path(filename)
  if is_path_remote(norm_filename) then
    self.filename = norm_filename
    self.abs_filename = norm_filename
    self.is_remote_file = true
    local remote_path = get_remote_path(norm_filename)
    
    local res = bridge.perform_sync_request({
      action = "read_file",
      path = remote_path
    })
    
    if res and res.status == "ok" then
      self.lines = {}
      local content = res.content or ""
      for line in (content .. "\n"):gmatch("(.-)\n") do
        table.insert(self.lines, line .. "\n")
      end
      if #self.lines == 0 then
        table.insert(self.lines, "\n")
      end
      self:reset_syntax()
      self:clean()
      
      -- Seed cache with a fresh file info structure
      invalidate_cache(norm_filename)
      return true
    end
  end
  return original_doc_load(self, filename)
end

-- Intercept Document File saving
local original_doc_save = Doc.save
function Doc:save(filename)
  local target_filename = normalize_path(filename or self.filename)
  local is_new_file = not self.filename
  
  -- Route to remote save if explicitly flagged remote, or if saving a brand-new file to a remote path
  if self.is_remote_file or (is_new_file and is_path_remote(target_filename)) then
    local remote_path = get_remote_path(target_filename)
    local content = self:get_text(1, 1, #self.lines, #self.lines[#self.lines])
    
    local res = bridge.perform_sync_request({
      action = "save_file",
      path = remote_path,
      content = content
    })
    
    if res then
      if res.status == "ok" then
        self.is_remote_file = true
        invalidate_cache(target_filename)
        self:clean()
        core.log("Saved remote file: [%s] %s", bridge.current_ssh_host or "Remote", remote_path)
        return true
      else
        return false, "Remote server error: " .. tostring(res.message)
      end
    else
      return false, "Remote save timed out or server disconnected"
    end
  end
  
  return original_doc_save(self, filename)
end

-- Intercept io.open so the TreeView "New File" command creates the file on the
-- remote host through the bridge instead of attempting a local disk write
-- (which would fail because the remote project path does not exist locally).
-- Only write/create modes (w, a, +, x) on remote paths are routed; read modes
-- fall back to the original io.open. A lightweight file handle whose close()
-- succeeds is returned, which is all treeview:new-file uses.
local original_io_open = io.open
io.open = function(filename, mode)
  local norm = normalize_path(filename)
  if bridge.is_connected() and is_path_remote(norm) then
    local m = mode or "r"
    if m:match("[wax]") then
      local remote_path = get_remote_path(norm)
      -- append modes must not truncate an existing file
      if m:match("a") then
        local info = bridge.perform_sync_request({ action = "file_info", path = remote_path })
        if not (info and info.status == "ok") then
          local res = bridge.perform_sync_request({ action = "save_file", path = remote_path, content = "" })
          if not (res and res.status == "ok") then
            return nil, "Remote file creation failed"
          end
        end
      else
        local res = bridge.perform_sync_request({ action = "save_file", path = remote_path, content = "" })
        if not (res and res.status == "ok") then
          return nil, "Remote file creation failed"
        end
      end
      refresh_remote()
      return { close = function() return true end }
    end
    return original_io_open(filename, mode)
  end
  return original_io_open(filename, mode)
end

-- When a terminal that was spawned with a LOCAL shell (toggled on before
-- connecting) is shown or focused after a remote session is active, inject an
-- SSH command so it becomes a remote terminal. Pragtical reuses a single
-- core.terminal_view across toggles, so TerminalView:spawn (and the override
-- above) only runs on first creation -- a pre-connect local terminal never
-- re-spawns, so without this promotion toggling it on post-connect just
-- re-shows the local shell. Uses `exec ssh` on non-Windows so the local
-- shell is replaced; when ssh later exits, TerminalView:update detects the
-- exited pty and auto-closes the view, so the next toggle spawns a fresh
-- terminal through the spawn override. Guarded by is_remote_terminal so it
-- fires at most once per view. Duck-typed (view.terminal + view.input) to
-- avoid needing the lazily-loaded TerminalView class reference here.
local function promote_terminal_to_remote(view)
  if not (view and view.terminal and view.input) then return end
  if view.is_remote_terminal then return end
  if not bridge.is_connected() or not bridge.current_ssh_host then return end
  view.is_remote_terminal = true
  local newline = (view.options and view.options.newline) or "\r"
  local remote_cmd = string.format("cd %q && exec ${SHELL:-sh} -l", bridge.remote_cwd or ".")
  local prefix = (PLATFORM:lower() == "windows") and "" or "exec "
  local ssh_cmd = string.format("%sssh -t %s %q%s", prefix, bridge.current_ssh_host, remote_cmd, newline)
  pcall(view.input, view, ssh_cmd)
end

-- Refresh the sidebar when focus leaves a remote terminal view. Files created
-- inside the SSH terminal (e.g. `touch new.txt`) would otherwise stay hidden
-- behind the list_dir TTL cache until it expires, since DirWatch polling is
-- suppressed on remote sessions. The remote terminals are tagged with
-- `is_remote_terminal` by the TerminalView:spawn override above.
local original_set_active_view = core.set_active_view
function core.set_active_view(view)
  local prev = core.active_view
  original_set_active_view(view)
  if bridge.is_connected() and prev and prev ~= view and prev.is_remote_terminal then
    refresh_remote()
  end
  promote_terminal_to_remote(view)
end

-- Extend Pragtical's update loop
local core_update = core.update
function core.update()
  core_update()
  bridge.update()
end


-- =====================================================================
-- PERFORMANCE & POLLING MITIGATIONS
-- =====================================================================

-- 1. Overwrite DirWatch background checks to suppress high-frequency polling
local original_dirwatch_check = DirWatch.check
function DirWatch:check(cb)
  if bridge.is_connected() then
    return
  end
  return original_dirwatch_check(self, cb)
end

-- 2. Overwrite Project background scans to prevent recursive network traffic
local original_project_files = Project.files
function Project:files()
  if bridge.is_connected() then
    return coroutine.wrap(function() end)
  end
  return original_project_files(self)
end


-- =====================================================================
-- TREEVIEW INTERFACE CUSTOMIZATIONS
-- =====================================================================

-- treeview loads lazily in some setups; poll until it is available,
-- then install the override once (idempotent guard) and stop polling.
local function install_treeview_override(treeview)
  treeview._remote_ssh_wrapped = true
  local original_get_item_text = treeview.get_item_text
  function treeview:get_item_text(item, active, hovered)
    if bridge.is_connected() and item.abs_filename == item.project.path then
      local font = style.font
      local color = (active or hovered) and style.accent or style.text
      return "[" .. (bridge.current_ssh_host or "Remote") .. "]", font, color
    end
    return original_get_item_text(self, item, active, hovered)
  end
end

core.add_thread(function()
  while true do
    coroutine.yield(0.2)
    local treeview = package.loaded["plugins.treeview"]
    if treeview and not treeview._remote_ssh_wrapped then
      install_treeview_override(treeview)
      return
    end
  end
end)

local original_doc_get_name = Doc.get_name
function Doc:get_name()
  if bridge.is_connected() and self.is_remote_file and self.abs_filename then
    local remote_path = get_remote_path(self.abs_filename)
    return "[" .. (bridge.current_ssh_host or "Remote") .. "] " .. remote_path
  end
  return original_doc_get_name(self)
end

-- Override the tab title so every remote tab shows just the basename, with no
-- host prefix. The default DocView:get_name() extracts the basename after the
-- last '/' from Doc:get_name(), which keeps the "[host]" prefix only when the
-- remote path has no slash (root files) and drops it for subdir files -- an
-- inconsistency. Returning the basename directly here makes all remote tabs
-- uniform.
local DocView = require "core.docview"
local original_docview_get_name = DocView.get_name
function DocView:get_name()
  if bridge.is_connected() and self.doc and self.doc.is_remote_file
    and self.doc.abs_filename then
    local post = self.doc:is_dirty() and "*" or ""
    local remote_path = get_remote_path(self.doc.abs_filename)
    return remote_path:match("[^/%\\]*$") .. post
  end
  return original_docview_get_name(self)
end

-- Intercept standard and quiet logging to scrub absolute local paths
local original_core_log = core.log
function core.log(fmt, ...)
  if bridge.is_connected() then
    if type(fmt) == "string" then
      fmt = strip_local_path(fmt)
    end
    local args = {...}
    for i, arg in ipairs(args) do
      if type(arg) == "string" then
        args[i] = strip_local_path(arg)
      end
    end
    return original_core_log(fmt, table.unpack(args))
  end
  return original_core_log(fmt, ...)
end

local original_core_log_quiet = core.log_quiet
function core.log_quiet(fmt, ...)
  if bridge.is_connected() then
    if type(fmt) == "string" then
      fmt = strip_local_path(fmt)
    end
    local args = {...}
    for i, arg in ipairs(args) do
      if type(arg) == "string" then
        args[i] = strip_local_path(arg)
      end
    end
    return original_core_log_quiet(fmt, table.unpack(args))
  end
  return original_core_log_quiet(fmt, ...)
end

local original_get_view_title = core.get_view_title
function core.get_view_title(view)
  if bridge.is_connected() then
    if bridge.remote_cwd then
      return "[" .. (bridge.current_ssh_host or "Remote") .. "] " .. bridge.remote_cwd
    else
      return "[" .. (bridge.current_ssh_host or "Remote") .. "]"
    end
  end
  return original_get_view_title(view)
end


-- =====================================================================
-- TERMINAL INTERFACE CUSTOMIZATIONS (SSH AUTO-ROUTING)
-- =====================================================================

-- The terminal plugin loads lazily (on first toggle), which may be long
-- after this plugin loads at startup. A one-shot 0.2 s deferred install
-- would miss it and leave TerminalView:spawn unwrapped, so toggling the
-- terminal on after connecting spawned a *local* shell instead of an SSH
-- session (the override was never installed). Poll until the terminal
-- plugin is loaded, then install the override once (idempotent guard) and
-- stop polling.
local sync_remote_terminals_cwd  -- forward declaration; defined below
local function install_terminal_override(TerminalView)
  TerminalView._remote_ssh_wrapped = true

  local original_spawn = TerminalView.spawn
  function TerminalView:spawn()
    if bridge.is_connected() and bridge.current_ssh_host then
      self.is_remote_terminal = true
      local is_windows = (PLATFORM:lower() == "windows")
      if is_windows then
        core.add_thread(function()
          for i = 1, 10 do
            if self.terminal then break end
            coroutine.yield(0.05)
          end
          if self.terminal then
            local newline = self.options.newline or "\r\n"
            local remote_cmd = string.format("cd %q && exec ${SHELL:-sh} -l", bridge.remote_cwd or ".")
            local ssh_cmd = string.format("ssh -t %s %q%s", bridge.current_ssh_host, remote_cmd, newline)
            self:input(ssh_cmd)
          end
        end)
      else
        self.options.shell = "ssh"
        self.options.arguments = {
          "-t",
          bridge.current_ssh_host,
          string.format("cd %q && exec ${SHELL:-sh} -l", bridge.remote_cwd or ".")
        }
      end
    end

    original_spawn(self)
  end

  local original_get_name = TerminalView.get_name
  function TerminalView:get_name()
    local name = original_get_name(self)
    if bridge.is_connected() and bridge.current_ssh_host then
      return "[" .. bridge.current_ssh_host .. "] " .. name
    end
    return name
  end
end

core.add_thread(function()
  while true do
    coroutine.yield(0.2)
    local terminal_plugin = package.loaded["plugins.terminal"]
    local TerminalView = terminal_plugin and terminal_plugin.class
    if TerminalView and not TerminalView._remote_ssh_wrapped then
      install_terminal_override(TerminalView)
      return
    end
  end
end)

-- Send `cd <cwd>` to every active remote terminal so its SSH shell follows
-- a remote:change-directory. New terminals pick up bridge.remote_cwd via the
-- spawn override above; this covers terminals already open. Quoting uses
-- Lua %q (same style as the spawn override) which is shell-compatible. pcall
-- guards against a terminal in a half-initialized state.
function sync_remote_terminals_cwd()
  if not bridge.is_connected() or not bridge.remote_cwd then return end
  local terminal_plugin = package.loaded["plugins.terminal"]
  local TerminalView = terminal_plugin and terminal_plugin.class
  if not TerminalView then return end
  local views = core.root_view.root_node:get_children()
  for _, v in ipairs(views) do
    if v.is_remote_terminal and v.terminal and v.input then
      local nl = (v.options and v.options.newline) or "\r"
      pcall(v.input, v, string.format("cd %q%s", bridge.remote_cwd, nl))
    end
  end
end


-- =====================================================================
-- COMMAND REGISTRATIONS
-- =====================================================================

command.add(nil, {
  -- Ctrl+Shift+P -> "Remote: Connect SSH"
["remote:connect-ssh"] = function()
    local hosts = get_ssh_hosts()
    local recents = load_recent_paths()
    core.command_view:enter("Connect to SSH Host (host or host:path)", {
      submit = function(input)
        if input and input ~= "" then
          local ssh_host, target_path = input:match("^([^:]+):%s*(.*)$")
          if not ssh_host then
            ssh_host = input
            target_path = nil
          elseif target_path == "" then
            target_path = nil
          end

          -- Run connect in a background coroutine so the editor stays
          -- responsive during the SSH handshake / resolve / connect-retry
          -- loops (bridge.connect's waits use coop_sleep, which yields to
          -- the scheduler instead of blocking on SDL_Delay). The command
          -- returns immediately; post-connect UI work runs after success.
          core.add_thread(function()
            local success = bridge.connect(ssh_host, target_path)
            if success then
              if bridge.remote_cwd then
                save_recent_path(ssh_host, bridge.remote_cwd)
              end
              clear_treeview_cache()
              core.redraw = true
            else
              core.error("Failed to connect to %s", tostring(ssh_host))
            end
          end)
        end
      end,
      suggest = function(text)
        local suggestions = {}
        local seen = {}
        local query = text:lower()

        -- Priority 1: Saved host:path entries
        for _, entry in ipairs(recents) do
          if entry:lower():find(query, 1, true) and not seen[entry] then
            seen[entry] = true
            table.insert(suggestions, entry)
          end
        end

        -- Priority 2: SSH config hosts
        for _, host in ipairs(hosts) do
          if host:lower():find(query, 1, true) and not seen[host] then
            seen[host] = true
            table.insert(suggestions, host)
          end
        end

        return suggestions
      end
    })
  end,

  ["remote:change-directory"] = function()
    if not bridge.is_connected() then
      core.error("Remote is not connected.")
      return
    end

    core.command_view:enter("Change Remote Directory", {
      submit = function(path)
        if not path or path == "" then return end

        local res = bridge.perform_sync_request({
          action = "change_dir",
          path = path
        })

        if res and res.status == "ok" then
          bridge.remote_cwd = res.cwd
          core.log("Changed remote directory to: " .. bridge.remote_cwd)
          save_recent_path(bridge.current_ssh_host, bridge.remote_cwd)

          list_dir_cache = {}
          file_info_cache = {}

          clear_treeview_cache()

          sync_remote_terminals_cwd()

          core.redraw = true
        else
          local msg = res and res.message or "Unknown error"
          core.error("Failed to change remote directory: " .. msg)
        end
      end,
      suggest = function(text)
        local parent_dir, partial = text:match("^(.-)([^/\\]*)$")
        
        local query_path
        local is_absolute = parent_dir:match("^/") or parent_dir:match("^%a:")

        if is_absolute then
          query_path = parent_dir
        else
          local project_path = core.projects[1] and core.projects[1].path or ""
          if parent_dir ~= "" then
            local clean_parent = parent_dir:gsub("[/\\]", PATHSEP)
            if clean_parent:sub(-1) == PATHSEP then
              clean_parent = clean_parent:sub(1, -2)
            end
            query_path = project_path .. PATHSEP .. clean_parent
          else
            query_path = project_path
          end
        end

        local items = system.list_dir(query_path) or {}
        local suggestions = {}
        for _, item in ipairs(items) do
          local full_local_path = query_path
          if query_path:sub(-1) ~= PATHSEP then
            full_local_path = full_local_path .. PATHSEP
          end
          full_local_path = full_local_path .. item

          local info = system.get_file_info(full_local_path)
          if info and info.type == "dir" then
            local rel_item_path = parent_dir .. item
            if rel_item_path:lower():find(text:lower(), 1, true) == 1 then
              table.insert(suggestions, rel_item_path .. PATHSEP)
            end
          end
        end
        return suggestions
      end
    })
  end,

  -- Ctrl+Shift+P -> "Remote: Disconnect"
  ["remote:disconnect"] = function()
    if bridge.is_connected() then
      core.log("Disconnecting remote bridge...")
      bridge.disconnect()
    else
      core.log("Remote Bridge is not connected.")
    end
  end,

  ["remote:refresh"] = function()
    if not bridge.is_connected() then
      core.error("Remote is not connected.")
      return
    end
    refresh_remote()
    core.log("Refreshed remote workspace.")
  end
})

-- Create a new file on the remote host. This command is always available
-- in the command palette while a remote session is active, unlike
-- treeview:new-file which only appears when a sidebar item is selected.
-- After saving the empty file it is opened for editing and the sidebar is
-- refreshed so the new entry shows up immediately.
command.add(bridge.is_connected, {
  ["remote:new-file"] = function()
    local project_path = core.projects[1] and core.projects[1].path or ""
    core.command_view:enter("New Remote File", {
      submit = function(filename)
        if not filename or filename == "" then return end
        local norm = normalize_path(project_path .. PATHSEP .. filename)
        local remote_path = get_remote_path(norm)
        local res = bridge.perform_sync_request({
          action = "save_file",
          path = remote_path,
          content = ""
        })
        if res and res.status == "ok" then
          refresh_remote()
          core.log("Created remote file: [%s] %s",
            bridge.current_ssh_host or "Remote", remote_path)
          local doc = core.open_doc(norm)
          if doc then
            pcall(core.root_view.open_doc, core.root_view, doc)
          end
        else
          core.error("Failed to create remote file: %s",
            res and res.message or "unknown error")
        end
      end,
      suggest = function(text)
        return common.path_suggest(text, project_path)
      end
    })
  end,

  -- Create a new directory on the remote host. Like remote:new-file this
  -- is registered with the connection predicate so it is listed in the
  -- palette whenever a remote session is active, regardless of focus.
  -- After creating the directory the caches are refreshed so the sidebar
  -- shows the new entry immediately.
  ["remote:new-directory"] = function()
    local project_path = core.projects[1] and core.projects[1].path or ""
    core.command_view:enter("New Remote Directory", {
      submit = function(dirname)
        if not dirname or dirname == "" then return end
        local norm = normalize_path(project_path .. PATHSEP .. dirname)
        local remote_path = get_remote_path(norm)
        local res = bridge.perform_sync_request({
          action = "make_dir",
          path = remote_path
        })
        if res and res.status == "ok" then
          refresh_remote()
          core.log("Created remote directory: [%s] %s",
            bridge.current_ssh_host or "Remote", remote_path)
        else
          core.error("Failed to create remote directory: %s",
            res and res.message or "unknown error")
        end
      end,
      suggest = function(text)
        -- Suggest directories relative to the project root (with a trailing
        -- separator) so a picked suggestion can be submitted as-is.
        local parent_dir, partial = text:match("^(.-)([^/\\]*)$")
        local is_absolute = parent_dir:match("^/") or parent_dir:match("^%a:")
        local query_path
        if is_absolute then
          query_path = parent_dir
        else
          local project = core.projects[1] and core.projects[1].path or ""
          if parent_dir ~= "" then
            local clean_parent = parent_dir:gsub("[/\\]", PATHSEP)
            if clean_parent:sub(-1) == PATHSEP then
              clean_parent = clean_parent:sub(1, -2)
            end
            query_path = project .. PATHSEP .. clean_parent
          else
            query_path = project
          end
        end
        local items = system.list_dir(query_path) or {}
        local suggestions = {}
        for _, item in ipairs(items) do
          local full_local_path = query_path
          if full_local_path:sub(-1) ~= PATHSEP then
            full_local_path = full_local_path .. PATHSEP
          end
          full_local_path = full_local_path .. item
          local info = system.get_file_info(full_local_path)
          if info and info.type == "dir" then
            local rel_item_path = parent_dir .. item
            if rel_item_path:lower():find(text:lower(), 1, true) == 1 then
              table.insert(suggestions, rel_item_path .. PATHSEP)
            end
          end
        end
        return suggestions
      end
    })
  end
})

-- Periodically refresh the sidebar while a remote terminal is the active view,
-- so files created in the SSH terminal (e.g. `touch new.txt`) appear in the
-- treeview without manually running remote:refresh or waiting for the
-- list_dir TTL cache to expire. The interval is a compromise between
-- responsiveness and remote network traffic; only runs while a remote
-- terminal is focused.
local REFRESH_INTERVAL = 3.0
core.add_thread(function()
  while true do
    coroutine.yield(REFRESH_INTERVAL)
    if bridge.is_connected()
      and core.active_view and core.active_view.is_remote_terminal then
      refresh_remote()
    end
  end
end)

-- Explicit module return: without this, require() falls back to `true`
-- (the chunk returns no value), so nothing outside can reach the helpers.
return {
  clear_treeview_cache = clear_treeview_cache,
  clear_treeview_remote_state = clear_treeview_remote_state,
  refresh_remote = refresh_remote,
}
