---@module "unwind"
--- Main facade: setup, keymaps, commands, and high-level orchestration

local parser = require("unwind.parser")
local collector = require("unwind.collector")
local decorator = require("unwind.decorator")
local ui = require("unwind.ui")
local sessions = require("unwind.sessions")
local sidebar = require("unwind.sidebar")
local events = require("unwind.events")
local state = require("unwind.state")
local navigation = require("unwind.navigation")
local session_actions = require("unwind.session_actions")
local ingest = require("unwind.ingest")
local export = require("unwind.export")
local text_util = require("unwind.text")
local keymaps_mod = require("unwind.keymaps")
local validator = require("unwind.config.validator")
local hooks = require("unwind.hooks")
local async_parser = require("unwind.async.parser")

local M = {}

--- Hooks extensibility API
M.hooks = hooks
M.register_resolver = hooks.register_resolver
M.unregister_resolver = hooks.unregister_resolver
M.register_ui_component = hooks.register_ui_component
M.unregister_ui_component = hooks.unregister_ui_component
M.register_exporter = hooks.register_exporter
M.unregister_exporter = hooks.unregister_exporter
M.register_picker = hooks.register_picker
M.unregister_picker = hooks.unregister_picker
M.get_picker = hooks.get_picker
M.on_event = hooks.on_event
M.off_event = hooks.off_event

--- Compatibility metatable delegating to state module
M.state = state.compat

--- Default configuration
M.config = {
  filter_out_of_project = false,
  path_mappings = {},
  max_input_bytes = 2 * 1024 * 1024,
  max_frames = 1000,
  ignore_patterns = {
    "shared/bundle/",
    "vendor/bundle/",
    "/gems/",
    "node_modules/",
    "^/usr/",
  },
  export = {
    fallback_context_lines = 10,
  },
  keymaps = {
    menu = "<leader>w",
    clipboard = "<leader>c",
    next = "]u",
    prev = "[u",
    next_file = "]f",
    prev_file = "[f",
  },
  add_position = "after_active",
  confirm_sync = true,
  picker = "auto",
}

--- Compatibility access to installed keymaps
M._installed_keymaps = keymaps_mod.installed_keymaps

--- Centralized keymap installer with ownership tracking
---@param keymaps table|boolean|nil Keymap table or false to disable
---@param force? boolean If true, overrides existing non-Unwind keymaps
function M.install_keymaps(keymaps, force)
  keymaps_mod.install_keymaps(keymaps, force, {
    menu = function() M.menu() end,
    clipboard = function() M.ingest_clipboard() end,
    next = function() M.next() end,
    prev = function() M.prev() end,
    next_file = function() M.next_file() end,
    prev_file = function() M.prev_file() end,
  })
  M._installed_keymaps = keymaps_mod.installed_keymaps
end

--- Parse raw stacktrace text asynchronously
---@param text string
---@param cb fun(frames: table[]?, err: string?)
---@return userdata? handle Active job handle for cancellation
function M.parse_async(text, cb)
  vim.notify("Unwind: Parsing...", vim.log.levels.INFO)
  return async_parser.parse_async(text, function(frames, err)
    if err then
      vim.notify("Unwind: Parsing failed: " .. tostring(err), vim.log.levels.ERROR)
    else
      vim.notify("Unwind: Parsing... done", vim.log.levels.INFO)
    end
    if cb then
      cb(frames, err)
    end
  end)
end

--- Cancel active async parsing job
---@param handle userdata
function M.cancel_parse_async(handle)
  async_parser.cancel(handle)
end
---@param opts? table
function M.setup(opts)
  if opts then
    local valid, err = validator.validate(opts)
    if not valid then
      vim.notify("Unwind: Configuration error: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
  end

  local user_opts = opts and vim.tbl_extend("force", {}, opts) or {}
  if user_opts.ignore_patterns then
    local valid_patterns = {}
    for _, pat in ipairs(user_opts.ignore_patterns) do
      if type(pat) == "string" then
        local ok, _ = pcall(string.find, "", pat)
        if ok then
          table.insert(valid_patterns, pat)
        else
          vim.notify("Unwind: Invalid ignore pattern discarded: " .. tostring(pat), vim.log.levels.WARN)
        end
      end
    end
    M.config.ignore_patterns = valid_patterns
    user_opts.ignore_patterns = nil
  end
  if user_opts.keymaps == false then
    M.config.keymaps = false
    user_opts.keymaps = nil
  end
  local force = user_opts.force_keymaps or false
  user_opts.force_keymaps = nil

  M.config = vim.tbl_deep_extend("force", M.config, user_opts)
  M.install_keymaps(M.config.keymaps, force)
end

--- Ensure persisted sessions are loaded for project root
---@param root? string
function M.ensure_sessions_loaded(root)
  state.ensure_sessions_loaded(root)
end

--- Check availability of a file path against root
---@param file_path string
---@param root string
---@return boolean available
---@return string resolved_path
function M.check_file_availability(file_path, root)
  return navigation.check_file_availability(file_path, root, M.config.path_mappings)
end

--- Rebuild runtime derived frames, files, and availability for a session
---@param session table
function M.rebuild_derived(session)
  local root = session and session.root or state.get_root()
  session_actions.rebuild_derived(session, M.config, root)
end

--- Clear active session presentation and state
function M.clear()
  decorator.clear()
  ui.close()
  ui.close_input()
  ui.close_prompt()
  sidebar.hide()

  state.set_current(nil)
  vim.notify("Unwind: Cleared stacktrace state and diagnostics.", vim.log.levels.INFO)
end

--- Wire default callbacks for a session to sidebar
---@param session table
---@return table callbacks
local function get_sidebar_callbacks(session)
  return {
    on_select_frame = function(f_idx)
      M.jump_to_frame(f_idx)
    end,
    on_delete_frame = function(f_idx)
      local cur_sess = state.current() or session
      M.delete_frame_from_session(cur_sess, f_idx)
    end,
    on_move_frame = function(from_idx, to_idx)
      local cur_sess = state.current() or session
      M.move_frame_in_session(cur_sess, from_idx, to_idx)
    end,
    on_annotate_frame = function(f_idx)
      local cur_sess = state.current() or session
      M.annotate(f_idx, cur_sess)
    end,
    on_replace_frame = function(f_idx)
      local cur_sess = state.current() or session
      M.replace_frame_in_session(cur_sess, f_idx)
    end,
    on_save = function()
      local cur_sess = state.current() or session
      M.prompt_save_session(cur_sess)
    end,
    on_refresh = function()
      M.refresh_availability()
    end,
    on_export = function()
      local cur_sess = state.current() or session
      M.export(cur_sess)
    end,
  }
end

--- Jump to a specific frame by index
---@param idx number
---@return boolean selected
---@return boolean opened
function M.jump_to_frame(idx)
  return navigation.jump_to_frame(state.current(), idx)
end

--- Jump to a specific file by index
---@param file_idx number
---@return boolean success
function M.jump_to_file(file_idx)
  return navigation.jump_to_file(state.current(), file_idx)
end

--- Cycle sequentially to next unique file
function M.next_file()
  navigation.next_file(state.current())
end

--- Cycle sequentially to previous unique file
function M.prev_file()
  navigation.prev_file(state.current())
end

--- Cycle sequentially to next stack frame
function M.next()
  navigation.next(state.current())
end

--- Cycle sequentially to previous stack frame
function M.prev()
  navigation.prev(state.current())
end

--- Re-apply collection and update active session with current filter setting
function M.reapply_filter()
  session_actions.reapply_filter(state.current(), M.config)
end

--- Toggle vendor / library filtering for active session
function M.toggle_filter()
  local current_session = state.current()
  local root = current_session and current_session.root or state.get_root()
  local saved_sessions = state.ensure_sessions_loaded(root)
  session_actions.toggle_filter(current_session, saved_sessions, M.config)
end

--- Activate a specific session
---@param session table
function M.activate_session(session)
  if not session then return end
  state.set_current(session)
  if session.root then
    state.ensure_sessions_loaded(session.root)
  end

  M.rebuild_derived(session)
  sidebar.open(session, get_sidebar_callbacks(session))
  events.emit("session_activated", session)

  if session.frames and #session.frames > 0 then
    local target = (session.active_index and session.active_index > 0) and session.active_index or 1
    M.jump_to_frame(target)
  else
    session.active_index = 0
    session.active_file_index = 0
    decorator.clear()
    sidebar.render(session)
  end
end

--- Ingest a raw plain-text stacktrace string
--- Direct string ingestion updates active session and derived frames without opening sidebar
--- unless the sidebar was already open, preserving existing view layout for programmatic callers.
--- Interactive ingestion entry points (clipboard, scratchpad, file) open the sidebar via activate_session.
--- In all cases, a new transient session is created and active state is updated.
---@param text string
---@return table|nil session
function M.ingest(text)
  local was_sidebar_open = sidebar.is_open()
  return ingest.from_text(text, M.config, state, function(sess)
    state.set_current(sess)
    M.rebuild_derived(sess)
    if was_sidebar_open then
      sidebar.open(sess, get_sidebar_callbacks(sess))
    end
    events.emit("session_activated", sess)

    if sess.frames and #sess.frames > 0 then
      local target = (sess.active_index and sess.active_index > 0) and sess.active_index or 1
      M.jump_to_frame(target)
    else
      sess.active_index = 0
      sess.active_file_index = 0
      decorator.clear()
      if was_sidebar_open then
        sidebar.render(sess)
      end
    end
  end)
end

--- Ingest stacktrace from clipboard register '+'
---@return table|nil session
function M.ingest_clipboard()
  return ingest.from_clipboard(M.config, state, function(sess)
    M.activate_session(sess)
  end)
end

--- Ingest stacktrace from a 1-indexed line range
---@param line1 number
---@param line2 number
function M.ingest_range(line1, line2)
  return ingest.from_range(line1, line2, M.config, state, function(sess)
    M.activate_session(sess)
  end)
end

--- Ingest stacktrace from visual selection range
function M.ingest_selection()
  return ingest.from_selection(M.config, state, function(sess)
    M.activate_session(sess)
  end)
end

--- Export active stacktrace frames to Neovim's quickfix list
function M.quickfix()
  navigation.quickfix(state.current())
end

--- Export active debugging session to a Markdown scratch buffer
---@param session? table Defaults to state.current()
---@param opts? table Export configuration overrides
---@return integer bufnr Created buffer handle
function M.export(session, opts)
  session = session or state.current()
  local export_opts = vim.tbl_deep_extend("force", {}, M.config.export or {}, opts or {})
  return export.export_to_buffer(session, export_opts)
end

--- Ingest stacktrace from a file path
---@param filepath string
function M.ingest_file(filepath)
  return ingest.from_file(filepath, M.config, state, function(sess)
    M.activate_session(sess)
  end)
end

--- Open an interactive floating scratchpad to paste/type a stacktrace
function M.open_input()
  ui.open_input(function(text)
    M.ingest(text)
  end)
end

--- Unified command dispatcher
---@param arg? string
function M.unwind(arg)
  if arg and vim.trim(arg) ~= "" then
    M.ingest_file(vim.trim(arg))
  else
    M.open_input()
  end
end

--- Create a new empty untitled session and open sidebar
---@return table session
function M.new_session()
  local root = state.get_root()
  local session = sessions.create({
    root = root,
    name = nil,
    transient = true,
  })
  M.activate_session(session)
  return session
end

--- Annotate a frame in the active session (prompts user for annotation note)
---@param frame_idx? number Frame index (defaults to active_index)
---@param session? table Target session (defaults to state.current())
function M.annotate(frame_idx, session)
  session = session or state.current()
  if not session or not session.frames or #session.frames == 0 then
    vim.notify("Unwind: No active frames to annotate.", vim.log.levels.WARN)
    return
  end

  local target_idx = frame_idx or session.active_index
  if not target_idx or target_idx < 1 or target_idx > #session.frames then
    target_idx = (session.active_index and session.active_index > 0) and session.active_index or 1
  end

  local target_frame = session.frames[target_idx]
  if not target_frame then
    vim.notify("Unwind: Frame not found.", vim.log.levels.WARN)
    return
  end

  local current_note = target_frame.note or ""

  ui.prompt_input("Annotate frame", current_note, function(input_text)
    -- Finding 3: Abort if target session is no longer active
    if state.current() ~= session then
      return
    end

    -- Finding 2 & 4: Route update through transactional annotate_frame_in_session using target_frame identity
    local root = session.root or state.get_root()
    local saved_sessions = state.ensure_sessions_loaded(root)
    session_actions.annotate_frame_in_session(session, target_frame, input_text, saved_sessions, M.config)
  end)
end

--- Prompt for session name and save working session
---@param session table
function M.prompt_save_session(session)
  local root = session and session.root or state.get_root()
  local saved_sessions = state.ensure_sessions_loaded(root)
  ui.prompt_input("Save session as", session.name or "Session 1", function(name)
    local ok, err = sessions.save_working(session, name, saved_sessions, root)
    if not ok then
      vim.notify("Unwind: " .. tostring(err), vim.log.levels.ERROR)
    else
      vim.notify("Unwind: Saved session '" .. session.name .. "'.", vim.log.levels.INFO)
      sidebar.render(session)
    end
  end)
end

--- Add current source location to active session
---@param opts? { position?: "after_active"|"before_active"|"end", index?: number }
function M.add_current_location(opts)
  opts = opts or {}
  ui.ensure_source_window()
  sidebar.ensure_source_window()

  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)

  if not bufname or bufname == "" or vim.bo[bufnr].buftype ~= "" then
    vim.notify("Unwind: Cannot add frame from unnamed or non-file buffer.", vim.log.levels.WARN)
    return
  end

  local root = state.get_root()
  state.set_root(root)
  state.ensure_sessions_loaded(root)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2] + 1

  local ok_loc, location = pcall(require, "unwind.location")
  local frame_data = nil
  if ok_loc and location and location.from_cursor then
    frame_data = location.from_cursor({
      bufnr = bufnr,
      row = row,
      col = col,
      root = root,
    })
  end

  if not frame_data then
    local rel_path = bufname
    if vim.startswith(bufname, root .. "/") then
      rel_path = bufname:sub(#root + 2)
    end
    frame_data = {
      path = bufname,
      file = rel_path,
      line = row,
      col = col,
      column = col,
      method = nil,
      origin = "manual",
      raw_line = string.format("%s:%d:%d", rel_path, row, col),
    }
  end

  local session = state.current()
  if not session then
    session = sessions.create({
      root = root,
      name = nil,
      transient = true,
      filter_enabled = M.config.filter_out_of_project or false,
    })
    state.set_current(session)
  end

  local raw_frames = session.raw_frames or {}
  local insert_idx = nil
  if type(opts.index) == "number" and opts.index >= 1 and opts.index <= #raw_frames + 1 then
    insert_idx = math.floor(opts.index)
  else
    local pos = opts.position or M.config.add_position or "after_active"
    local active_idx = session.active_index or 0
    local active_frame = (active_idx > 0 and session.frames) and session.frames[active_idx] or nil
    if pos == "after_active" then
      if active_frame then
        local raw_idx = active_frame.raw_index or active_idx
        insert_idx = raw_idx + 1
      else
        insert_idx = #raw_frames + 1
      end
    elseif pos == "before_active" then
      if active_frame then
        local raw_idx = active_frame.raw_index or active_idx
        insert_idx = raw_idx
      else
        insert_idx = 1
      end
    elseif pos == "end" then
      insert_idx = #raw_frames + 1
    else
      insert_idx = #raw_frames + 1
    end
  end

  if insert_idx < 1 then insert_idx = 1 end
  if insert_idx > #raw_frames + 1 then insert_idx = #raw_frames + 1 end

  local ok, err = sessions.add_frame(session, frame_data, insert_idx, state.raw.sessions)
  if not ok then
    vim.notify("Unwind: Failed to add location: " .. tostring(err or "persistence error"), vim.log.levels.ERROR)
    return
  end

  local inserted_raw_frame = session.raw_frames[insert_idx]

  M.rebuild_derived(session)

  local buffer_mod = require("unwind.buffer")

  if not sidebar.is_open() then
    -- Only open sidebar if the unwind buffer is not already visible in any window
    local unwind_buf = buffer_mod.get_or_create()
    local buf_winid = vim.fn.bufwinid(unwind_buf)
    if buf_winid == -1 then
      sidebar.open(session, get_sidebar_callbacks(session))
    else
      buffer_mod.render(session, unwind_buf)
    end
  else
    sidebar.render(session)
  end

  local new_derived_idx = nil
  for d_idx, f in ipairs(session.frames or {}) do
    if f == inserted_raw_frame or f.raw_index == insert_idx or (inserted_raw_frame and f.uid == inserted_raw_frame.uid) then
      new_derived_idx = d_idx
      break
    end
  end

  if not new_derived_idx then
    new_derived_idx = #session.frames
  end

  session.active_index = new_derived_idx
  M.jump_to_frame(new_derived_idx)
  vim.notify(string.format("Unwind: Added location %s:%d to session.", frame_data.file or frame_data.path, frame_data.line), vim.log.levels.INFO)
end

--- Open persistent session manager menu
function M.menu()
  local root = state.get_root()
  state.ensure_sessions_loaded(root)

  local items = {}
  table.insert(items, { type = "new_session" })
  table.insert(items, { type = "import_clipboard" })
  table.insert(items, { type = "blank" })

  local session = state.current()
  if session then
    local total_count = session.raw_frames and #session.raw_frames or 0
    local project_count = sessions.get_project_frame_count(session, root, M.config.ignore_patterns)
    local sz, is_exact = sessions.get_size(session)
    local sz_str
    if is_exact then
      sz_str = text_util.format_bytes(sz)
    else
      sz_str = "approx. " .. text_util.format_bytes(sz)
    end
    table.insert(items, {
      type = "current_status",
      name = session.name or "Untitled",
      frame_count = total_count,
      total_frames = total_count,
      project_frames = project_count,
      size_bytes = sz,
      size_str = sz_str,
      is_exact = is_exact,
    })
    if not session.saved then
      table.insert(items, { type = "save_action" })
    end
    table.insert(items, { type = "blank" })
  end

  if #state.raw.sessions > 0 then
    table.insert(items, { type = "separator", text = "Saved Sessions" })
    for _, s in ipairs(state.raw.sessions) do
      local total_count = s.raw_frames and #s.raw_frames or 0
      local project_count = sessions.get_project_frame_count(s, root, M.config.ignore_patterns)
      local sz, is_exact = sessions.get_size(s)
      local sz_str
      if is_exact then
        sz_str = text_util.format_bytes(sz)
      else
        sz_str = "approx. " .. text_util.format_bytes(sz)
      end
      table.insert(items, {
        type = "session",
        name = s.name,
        frame_count = total_count,
        total_frames = total_count,
        project_frames = project_count,
        size_bytes = sz,
        size_str = sz_str,
        is_exact = is_exact,
        session = s,
      })
    end
  end

  ui.open_session_manager(items, {
    on_new = function()
      M.new_session()
    end,
    on_import_clipboard = function()
      M.ingest_clipboard()
    end,
    on_save = function()
      if session then
        M.prompt_save_session(session)
      end
    end,
    on_select = function(selected_session)
      M.activate_session(selected_session)
    end,
    on_rename = function(target_session)
      ui.prompt_input("Rename session", target_session.name, function(new_name)
        local ok, err = sessions.rename(target_session, new_name, state.raw.sessions, root)
        if not ok then
          vim.notify("Unwind: " .. tostring(err), vim.log.levels.ERROR)
        else
          vim.notify("Unwind: Renamed session to '" .. target_session.name .. "'.", vim.log.levels.INFO)
          if state.current() == target_session and sidebar.is_open() then
            sidebar.render(target_session)
          end
        end
      end)
    end,
    on_delete = function(target_session)
      local ok = sessions.delete(target_session, state.raw.sessions, root)
      if not ok then
        vim.notify("Unwind: Failed to delete session '" .. (target_session.name or "") .. "'.", vim.log.levels.ERROR)
      else
        vim.notify("Unwind: Deleted session '" .. (target_session.name or "") .. "'.", vim.log.levels.INFO)
        if state.current() == target_session then
          decorator.clear()
          sidebar.hide()
          state.set_current(nil)
        end
      end
    end,
  })
end

--- Open right vertical split sidebar
function M.open_sidebar()
  local session = state.current()
  if session then
    sidebar.open(session, get_sidebar_callbacks(session))
  else
    vim.notify("Unwind: No active session to display in sidebar.", vim.log.levels.WARN)
  end
end

--- Open unwind call-trace buffer in current window
function M.open_buffer()
  local session = state.current()
  if not session then
    session = sessions.create({
      root = state.get_root(),
      name = nil,
      transient = true,
      filter_enabled = M.config.filter_out_of_project or false,
    })
    state.set_current(session)
  end

  local buffer_mod = require("unwind.buffer")
  local buf = buffer_mod.get_or_create()
  local cur_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_buf(buf)
  buffer_mod.configure_window(cur_win)
  buffer_mod.render(session, buf, cur_win)
end

--- Toggle right sidebar
function M.toggle_sidebar()
  if sidebar.is_open() then
    sidebar.hide()
  else
    M.open_sidebar()
  end
end

--- Move a frame in session
function M.move_frame_in_session(session, from_idx, to_idx)
  local root = session and session.root or state.get_root()
  local saved_sessions = state.ensure_sessions_loaded(root)
  session_actions.move_frame_in_session(session, from_idx, to_idx, saved_sessions, M.config)
end

--- Replace a frame in session
function M.replace_frame_in_session(session, frame_idx)
  local root = session and session.root or state.get_root()
  local saved_sessions = state.ensure_sessions_loaded(root)
  session_actions.replace_frame_in_session(session, frame_idx, saved_sessions, M.config)
end

--- Remove a frame from a session
function M.delete_frame_from_session(session, frame_idx)
  local root = session and session.root or state.get_root()
  local saved_sessions = state.ensure_sessions_loaded(root)
  session_actions.delete_frame_from_session(session, frame_idx, saved_sessions, M.config)
end

--- Refresh file availability
function M.refresh_availability()
  local session = state.current()
  session_actions.refresh_availability(session, M.config)
end

--- Get normalized frame items for active or given session
---@param opts? { all?: boolean, session?: table }
---@return table[] items
function M.get_frames(opts)
  opts = opts or {}
  local session = opts.session or state.current()
  local picker = require("unwind.picker")
  return picker.get_items(session, opts)
end

--- Fuzzy search / picker for call trace frames
---@param opts? { picker?: string|function, all?: boolean }
function M.search(opts)
  local picker = require("unwind.picker")
  picker.search(opts)
end

--- Show Ruby environment diagnostic info
function M.ruby_info()
  local root = state.get_root()
  local ok_ruby, ruby = pcall(require, "unwind.resolvers.ruby")
  if not ok_ruby or not ruby then
    vim.notify("Unwind: Ruby resolver not available.", vim.log.levels.ERROR)
    return
  end

  local env = ruby.info(root)
  if not env then
    local lines = {
      "Unwind Ruby environment",
      "",
      "Project: " .. root,
      "Status: No Ruby environment detected or probe failed.",
    }
    vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
    return
  end

  local lines = {
    "Unwind Ruby environment",
    "",
    "Project:",
    "  " .. tostring(env.root),
    "",
    "Manager:",
    "  " .. tostring(env.manager),
    "",
    "Ruby version:",
    "  " .. tostring(env.ruby_version) .. (env.discovered_version and (" (declared: " .. env.discovered_version .. " in " .. tostring(env.version_source) .. ")") or ""),
    "",
    "Ruby executable:",
    "  " .. tostring(env.ruby_bin),
    "",
    "Ruby API:",
    "  " .. tostring(env.ruby_api_version),
    "",
    "Gem home:",
    "  " .. tostring(env.gem_dir),
    "",
    "Gem roots:",
  }
  for _, gp in ipairs(env.gem_paths or {}) do
    table.insert(lines, "  " .. tostring(gp))
  end
  table.insert(lines, "")
  table.insert(lines, "Stdlib:")
  table.insert(lines, "  " .. tostring(env.rubylibdir))

  local text = table.concat(lines, "\n")
  print(text)
  vim.notify(text, vim.log.levels.INFO)
end

return M
