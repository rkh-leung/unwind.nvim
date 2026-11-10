-- lua/unwind/init.lua
-- Main setup, state management, frame cycling, public API, session orchestration

local parser = require("unwind.parser")
local collector = require("unwind.collector")
local decorator = require("unwind.decorator")
local ui = require("unwind.ui")
local sessions = require("unwind.sessions")
local sidebar = require("unwind.sidebar")

local M = {}

--- Internal state
--- Retains top-level fields for backwards compatibility with tests and callers
--- via metatable delegation to active_session.
local raw_state = {
  root = nil,
  sessions = {},
  sessions_loaded = false,
  active_session = nil,
}

M.state = setmetatable({}, {
  __index = function(_, k)
    if k == "root" then
      return raw_state.root or (raw_state.active_session and raw_state.active_session.root)
    elseif k == "sessions" then
      return raw_state.sessions
    elseif k == "sessions_loaded" then
      return raw_state.sessions_loaded
    elseif k == "active_session" then
      return raw_state.active_session
    elseif raw_state.active_session and raw_state.active_session[k] ~= nil then
      return raw_state.active_session[k]
    end
    return raw_state[k]
  end,
  __newindex = function(_, k, v)
    if k == "root" then
      raw_state.root = v
      if raw_state.active_session then
        raw_state.active_session.root = v
      end
    elseif k == "sessions" then
      raw_state.sessions = v
    elseif k == "sessions_loaded" then
      raw_state.sessions_loaded = v
    elseif k == "active_session" then
      raw_state.active_session = v
    else
      if not raw_state.active_session then
        raw_state.active_session = sessions.new_working(raw_state.root or vim.fs.normalize(vim.fn.getcwd()), {})
      end
      raw_state.active_session[k] = v
    end
  end,
})

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
  keymaps = {
    menu = "<leader>w",
    clipboard = "<leader>c",
    next = "]u",
    prev = "[u",
    next_file = "]f",
    prev_file = "[f",
  },
}

--- Track keymaps installed by Unwind so subsequent setup() calls clean up old ones
M._installed_keymaps = {}

--- Centralized keymap installer with ownership tracking
---@param keymaps table|boolean|nil Keymap table or false to disable
---@param force? boolean If true, overrides existing non-Unwind keymaps
function M.install_keymaps(keymaps, force)
  for _, lhs in ipairs(M._installed_keymaps) do
    local map = vim.fn.maparg(lhs, "n", false, true)
    if map and map.desc and map.desc:match("^Unwind:") then
      pcall(vim.keymap.del, "n", lhs)
    end
  end
  M._installed_keymaps = {}

  if not keymaps or keymaps == false then
    return
  end

  local function register_key(lhs, fn, desc)
    if lhs and lhs ~= "" then
      local existing = vim.fn.maparg(lhs, "n", false, true)
      local is_empty = not existing or existing.lhs == nil or existing.lhs == ""
      local is_unwind = existing and existing.desc and existing.desc:match("^Unwind:")

      if is_empty or is_unwind or force then
        vim.keymap.set("n", lhs, fn, { desc = desc, silent = true })
        table.insert(M._installed_keymaps, lhs)
      end
    end
  end

  register_key(keymaps.menu, function() M.menu() end, "Unwind: Open session manager")
  register_key(keymaps.clipboard, function() M.ingest_clipboard() end, "Unwind: Ingest stacktrace from clipboard")
  register_key(keymaps.next, function() M.next() end, "Unwind: Next stack frame")
  register_key(keymaps.prev, function() M.prev() end, "Unwind: Previous stack frame")
  register_key(keymaps.next_file, function() M.next_file() end, "Unwind: Next stacktrace file")
  register_key(keymaps.prev_file, function() M.prev_file() end, "Unwind: Previous stacktrace file")
end

--- Setup unwind plugin options
---@param opts? table
function M.setup(opts)
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
  root = root or raw_state.root or vim.fs.normalize(vim.fn.getcwd())
  if not raw_state.sessions_loaded then
    raw_state.sessions = sessions.load(root)
    raw_state.sessions_loaded = true
  end
end

--- Check availability of a file path against root
---@param file_path string
---@param root string
---@return boolean available
---@return string resolved_path
function M.check_file_availability(file_path, root)
  if not file_path or file_path == "" or parser.is_non_navigable_path(file_path) then
    return false, file_path
  end

  local norm_opts = {
    root = root,
    path_mappings = M.config.path_mappings,
  }
  local _, resolved, _ = parser.resolve_and_normalize_path(file_path, norm_opts)

  local target_path = resolved
  if target_path:sub(1, 1) ~= "/" and not target_path:match("^%a:[/\\]") then
    target_path = root .. "/" .. target_path
  end
  target_path = vim.fs.normalize(target_path)

  local stat = (vim.uv or vim.loop).fs_stat(target_path)
  if not stat or stat.type ~= "file" then
    stat = (vim.uv or vim.loop).fs_stat(file_path)
  end

  if stat and stat.type == "file" then
    return true, target_path
  end

  return false, target_path
end

--- Rebuild runtime derived frames, files, and availability for a session
---@param session table
function M.rebuild_derived(session)
  if not session or not session.raw_frames then
    return
  end

  local root = session.root or raw_state.root or vim.fs.normalize(vim.fn.getcwd())
  local collected = collector.collect(session.raw_frames, {
    root = root,
    filter_vendor = session.filter_enabled,
    ignore_patterns = M.config.ignore_patterns,
  })

  session.frames = collected.frames
  session.files = collected.files

  -- Refresh availability once per unique file
  for _, f_entry in ipairs(session.files) do
    local is_avail, resolved = M.check_file_availability(f_entry.resolved_path or f_entry.file, root)
    f_entry.available = is_avail
    f_entry.canonical_resolved = resolved
  end
end

--- Clear active session presentation and state
--- Non-destructive to saved sessions: only discards unsaved working session
function M.clear()
  decorator.clear()
  ui.close()
  ui.close_input()
  ui.close_prompt()
  sidebar.hide()

  if raw_state.active_session and not raw_state.active_session.saved then
    raw_state.active_session = nil
  elseif raw_state.active_session and raw_state.active_session.saved then
    -- Deactivate saved session but keep in sessions list
    raw_state.active_session = nil
  end

  vim.notify("Unwind: Cleared stacktrace state and diagnostics.", vim.log.levels.INFO)
end

--- Jump to a specific frame by index
--- Missing files are first-class stale trace entries:
--- If source is unavailable, frame IS selected (active_index committed, sidebar highlight updated),
--- but source window is not touched and decorator is cleared.
--- Returns:
---   selected: boolean (whether index is valid)
---   opened: boolean (whether source buffer was opened)
---@param idx number
---@return boolean selected
---@return boolean opened
function M.jump_to_frame(idx)
  local session = raw_state.active_session
  if not session or not session.frames or #session.frames == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return false, false
  end

  if idx < 1 then
    idx = 1
  elseif idx > #session.frames then
    idx = #session.frames
  end

  local frame = session.frames[idx]
  local root = session.root or raw_state.root or vim.fs.normalize(vim.fn.getcwd())

  -- Fast-path availability check on selection:
  -- Session activation and 'r' refresh perform full resolution once per unique file.
  -- Navigation checks the cached resolved path with a single fs_stat.
  local file_entry = (frame.file_index and session.files) and session.files[frame.file_index] or nil
  local target_candidate = (file_entry and file_entry.canonical_resolved)
    or frame.resolved_path
    or frame.file

  local is_avail = false
  local resolved_path = target_candidate
  if not parser.is_non_navigable_path(frame.file) and target_candidate and target_candidate ~= "" then
    local check_path = target_candidate
    if check_path:sub(1, 1) ~= "/" and not check_path:match("^%a:[/\\]") then
      check_path = root .. "/" .. check_path
    end
    check_path = vim.fs.normalize(check_path)
    local stat = (vim.uv or vim.loop).fs_stat(check_path)
    if not stat or stat.type ~= "file" then
      stat = (vim.uv or vim.loop).fs_stat(target_candidate)
    end
    if stat and stat.type == "file" then
      is_avail = true
      resolved_path = check_path
    end
  end

  if file_entry then
    file_entry.available = is_avail
    if is_avail then
      file_entry.canonical_resolved = resolved_path
    end
  end

  if not is_avail or parser.is_non_navigable_path(frame.file) then
    -- Missing frame selection semantics:
    -- Frame IS selected, sidebar moves to it, decorator cleared, no empty buffer created
    session.active_index = idx
    if frame.file_index and session.files[frame.file_index] then
      session.active_file_index = frame.file_index
    else
      for f_idx, f_ent in ipairs(session.files) do
        if (f_ent.resolved_path and f_ent.resolved_path == frame.resolved_path) or f_ent.file == frame.file then
          session.active_file_index = f_idx
          break
        end
      end
    end

    decorator.clear()
    sidebar.set_active(session, idx)
    vim.notify("Unwind: File not found: " .. tostring(frame.file), vim.log.levels.WARN)
    return true, false
  end

  -- Ensure we are navigating in a source window, never inside an Unwind float or sidebar split
  ui.ensure_source_window()
  sidebar.ensure_source_window()

  local target_path = resolved_path or frame.resolved_path or frame.file
  if target_path:sub(1, 1) ~= "/" and not target_path:match("^%a:[/\\]") then
    target_path = root .. "/" .. target_path
  end
  target_path = vim.fs.normalize(target_path)

  local current_path = vim.fs.normalize(vim.api.nvim_buf_get_name(0))

  if target_path ~= current_path then
    local existing_buf = vim.fn.bufnr(target_path)
    if existing_buf == -1 and frame.file then
      existing_buf = vim.fn.bufnr(frame.file)
    end

    local already_loaded = existing_buf ~= -1
      and vim.api.nvim_buf_is_valid(existing_buf)
      and vim.api.nvim_buf_is_loaded(existing_buf)

    if already_loaded then
      vim.api.nvim_set_current_buf(existing_buf)
    else
      local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target_path))
      if not ok then
        ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(frame.file))
      end

      if not ok then
        vim.notify("Unwind: Could not open file " .. tostring(frame.file) .. ": " .. tostring(err), vim.log.levels.ERROR)
        session.active_index = idx
        decorator.clear()
        sidebar.set_active(session, idx)
        return true, false
      end
    end
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local target_line = math.max(1, math.min(frame.line or 1, line_count))
  local target_col = math.max(0, (frame.col or 1) - 1)

  local line_str = vim.api.nvim_buf_get_lines(bufnr, target_line - 1, target_line, false)[1] or ""
  local max_col = math.max(0, #line_str - 1)
  local clamped_col = math.min(target_col, max_col)
  if not pcall(vim.api.nvim_win_set_cursor, 0, { target_line, clamped_col }) then
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
  end

  session.active_index = idx
  if frame.file_index and session.files[frame.file_index] then
    session.active_file_index = frame.file_index
  else
    for f_idx, f_ent in ipairs(session.files) do
      if (f_ent.resolved_path and f_ent.resolved_path == frame.resolved_path) or f_ent.file == frame.file then
        session.active_file_index = f_idx
        break
      end
    end
  end

  decorator.render(bufnr, target_line, idx, frame.method, frame.file, #session.frames)
  sidebar.set_active(session, idx)
  return true, true
end

--- Jump to a specific file by index
--- If file is missing, selects primary frame and shows N/A without opening buffer
---@param file_idx number
---@return boolean success
function M.jump_to_file(file_idx)
  local session = raw_state.active_session
  if not session or not session.files or #session.files == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return false
  end

  if file_idx < 1 then
    file_idx = 1
  elseif file_idx > #session.files then
    file_idx = #session.files
  end

  local file_entry = session.files[file_idx]
  local target_frame_idx = file_entry.primary_frame_index
  if not target_frame_idx or not session.frames[target_frame_idx] then
    for idx, frame in ipairs(session.frames) do
      if (frame.resolved_path and frame.resolved_path == file_entry.resolved_path) or frame.file == file_entry.file then
        target_frame_idx = idx
        break
      end
    end
  end

  if target_frame_idx then
    local selected, opened = M.jump_to_frame(target_frame_idx)
    return selected
  end

  return false
end

--- Cycle sequentially to next unique file
function M.next_file()
  local session = raw_state.active_session
  if not session or not session.files or #session.files == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return
  end
  local total = #session.files
  local start = session.active_file_index or 0
  local candidate = ((start) % total) + 1
  M.jump_to_file(candidate)
end

--- Cycle sequentially to previous unique file
function M.prev_file()
  local session = raw_state.active_session
  if not session or not session.files or #session.files == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return
  end
  local total = #session.files
  local start = session.active_file_index or 1
  local candidate = ((start - 2) % total) + 1
  if candidate <= 0 then candidate = candidate + total end
  M.jump_to_file(candidate)
end

--- Cycle sequentially to next stack frame
--- In persistent sessions, missing frames are selected rather than skipped
function M.next()
  local session = raw_state.active_session
  if not session or not session.frames or #session.frames == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return
  end
  local total = #session.frames
  local start = session.active_index or 0
  local candidate = ((start) % total) + 1
  M.jump_to_frame(candidate)
end

--- Cycle sequentially to previous stack frame
function M.prev()
  local session = raw_state.active_session
  if not session or not session.frames or #session.frames == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return
  end
  local total = #session.frames
  local start = session.active_index or 1
  local candidate = ((start - 2) % total) + 1
  if candidate <= 0 then candidate = candidate + total end
  M.jump_to_frame(candidate)
end

--- Re-apply collection and update active session with current filter setting
function M.reapply_filter()
  local session = raw_state.active_session
  if not session or not session.raw_frames or #session.raw_frames == 0 then
    return
  end

  local prev_frame = (session.active_index and session.active_index > 0) and session.frames[session.active_index] or nil
  local prev_idx = session.active_index or 0

  M.rebuild_derived(session)

  if #session.frames == 0 then
    session.active_index = 0
    session.active_file_index = 0
    sidebar.render(session)
    return
  end

  local new_active_index = nil
  if prev_frame then
    for idx, f in ipairs(session.frames) do
      if f == prev_frame or (f.resolved_path == prev_frame.resolved_path and f.line == prev_frame.line and f.col == prev_frame.col and f.method == prev_frame.method) then
        new_active_index = idx
        break
      end
    end
  end

  if not new_active_index then
    if prev_idx > 0 then
      new_active_index = math.max(1, math.min(prev_idx, #session.frames))
    else
      new_active_index = 1
    end
  end

  session.active_index = new_active_index
  local active_frame = session.frames[new_active_index]
  if active_frame and active_frame.file_index and session.files[active_frame.file_index] then
    session.active_file_index = active_frame.file_index
  else
    session.active_file_index = 1
  end

  sidebar.render(session)
end

--- Toggle vendor / library filtering for active session
function M.toggle_filter()
  local session = raw_state.active_session
  if not session or not session.raw_frames or #session.raw_frames == 0 then
    vim.notify("Unwind: No active stacktrace to filter.", vim.log.levels.WARN)
    return
  end

  session.filter_enabled = not session.filter_enabled
  if session.saved then
    sessions.save(session.root, raw_state.sessions)
  end

  M.reapply_filter()

  if #session.frames == 0 then
    vim.notify("Unwind: All frames were filtered out as vendor/external files.", vim.log.levels.WARN)
    decorator.clear()
    return
  end

  local status = session.filter_enabled and "enabled (hiding vendor/library files)" or "disabled (showing all files)"
  vim.notify(string.format("Unwind: Vendor filter %s (%d frames, %d files).", status, #session.frames, #session.files), vim.log.levels.INFO)

  local target = session.active_index > 0 and session.active_index or 1
  M.jump_to_frame(target)
end

--- Activate a specific session
--- Wire default callbacks for a session to sidebar
---@param session table
---@return table callbacks
local function get_sidebar_callbacks(session)
  return {
    on_select_frame = function(f_idx)
      M.jump_to_frame(f_idx)
    end,
    on_delete_frame = function(f_idx)
      M.delete_frame_from_session(session, f_idx)
    end,
    on_move_frame = function(from_idx, to_idx)
      M.move_frame_in_session(session, from_idx, to_idx)
    end,
    on_replace_frame = function(f_idx)
      M.replace_frame_in_session(session, f_idx)
    end,
    on_save = function()
      M.prompt_save_session(session)
    end,
    on_refresh = function()
      M.refresh_availability()
    end,
  }
end

--- Activate a specific session
---@param session table
function M.activate_session(session)
  if not session then return end
  raw_state.active_session = session

  M.rebuild_derived(session)

  -- Open/reuse right sidebar
  sidebar.open(session, get_sidebar_callbacks(session))

  local events = require("unwind.events")
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
--- Creates a new unsaved working session and leaves saved sessions untouched
---@param text string
---@return table|nil session
function M.ingest(text)
  if not text or text == "" then
    vim.notify("Unwind: Ingested text is empty.", vim.log.levels.WARN)
    return nil
  end

  local max_bytes = M.config.max_input_bytes or (2 * 1024 * 1024)
  if #text > max_bytes then
    vim.notify(string.format("Unwind: Ingested text exceeds maximum limit (%d bytes), truncating.", max_bytes), vim.log.levels.WARN)
    text = text:sub(1, max_bytes)
  end

  local root = vim.fs.normalize(vim.fn.getcwd())
  raw_state.root = root

  local frames = parser.parse(text, {
    root = root,
    path_mappings = M.config.path_mappings,
    max_frames = M.config.max_frames,
  })
  if #frames == 0 then
    vim.notify("Unwind: No stack frames recognized in input.", vim.log.levels.WARN)
    return nil
  end

  local filter_enabled = M.config.filter_out_of_project or false
  local session = sessions.create({
    root = root,
    frames = frames,
    filter_enabled = filter_enabled,
    transient = true,
    name = nil,
  })
  raw_state.active_session = session

  M.rebuild_derived(session)
  decorator.clear()

  if #session.frames == 0 then
    vim.notify("Unwind: All recognized frames were filtered out as vendor/external files.", vim.log.levels.WARN)
    return session
  end

  vim.notify(string.format("Unwind: Loaded %d frames across %d files.", #session.frames, #session.files), vim.log.levels.INFO)

  -- Update sidebar if already open
  if sidebar.is_open() then
    sidebar.render(session)
  end

  -- Jump to first frame
  M.jump_to_frame(1)
  return session
end

--- Ingest stacktrace from clipboard register '+'
--- Always creates a NEW unnamed transient session rather than mutating active session.
---@return table|nil session
function M.ingest_clipboard()
  local text = vim.fn.getreg("+")
  if not text or text == "" then
    vim.notify("Unwind: Clipboard (+) is empty.", vim.log.levels.WARN)
    return nil
  end

  local max_bytes = M.config.max_input_bytes or (2 * 1024 * 1024)
  if #text > max_bytes then
    vim.notify(string.format("Unwind: Ingested text exceeds maximum limit (%d bytes), truncating.", max_bytes), vim.log.levels.WARN)
    text = text:sub(1, max_bytes)
  end

  local root = vim.fs.normalize(vim.fn.getcwd())
  raw_state.root = root

  local frames = parser.parse(text, {
    root = root,
    path_mappings = M.config.path_mappings,
    max_frames = M.config.max_frames,
  })
  if #frames == 0 then
    vim.notify("Unwind: No stack frames recognized in clipboard.", vim.log.levels.WARN)
    return nil
  end

  -- Create a brand new unnamed transient session
  local session = sessions.create({
    root = root,
    name = nil,
    transient = true,
    filter_enabled = M.config.filter_out_of_project or false,
  })
  sessions.add_frames(session, frames)

  -- Activate session and open sidebar
  M.activate_session(session)
  sidebar.open(session, get_sidebar_callbacks(session))

  if #session.frames > 0 then
    M.jump_to_frame(1)
  end

  return session
end

--- Ingest stacktrace from a 1-indexed line range
---@param line1 number
---@param line2 number
function M.ingest_range(line1, line2)
  line1, line2 = math.min(line1, line2), math.max(line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
  M.ingest(table.concat(lines, "\n"))
end

--- Ingest stacktrace from visual selection range
function M.ingest_selection()
  local mode = vim.fn.mode()
  if mode:find("[vV\22]") then
    vim.cmd([[execute "normal! \<ESC>"]])
  end

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local s_buf, s_row = start_pos[1], start_pos[2]
  local e_buf, e_row = end_pos[1], end_pos[2]

  local cur_buf = vim.api.nvim_get_current_buf()
  if s_row == 0 or e_row == 0 or (s_buf ~= 0 and s_buf ~= cur_buf) then
    vim.notify("Unwind: No visual selection found.", vim.log.levels.WARN)
    return
  end

  if s_row > e_row then
    s_row, e_row = e_row, s_row
  end

  M.ingest_range(s_row, e_row)
end

--- Export active stacktrace frames to Neovim's quickfix list
function M.quickfix()
  local session = raw_state.active_session
  if not session or not session.frames or #session.frames == 0 then
    vim.notify("Unwind: No active frames to export.", vim.log.levels.WARN)
    return
  end

  local qf_items = {}
  for _, frame in ipairs(session.frames) do
    table.insert(qf_items, {
      filename = frame.file,
      lnum = frame.line,
      col = frame.col or 1,
      text = frame.method ~= "" and ("at " .. frame.method) or frame.raw_line,
    })
  end

  vim.fn.setqflist({}, "r", { items = qf_items, title = session.name or "Unwind Stacktrace" })
  vim.cmd("copen")
end

--- Ingest stacktrace from a file path
---@param filepath string
function M.ingest_file(filepath)
  if not filepath or filepath == "" then
    vim.notify("Unwind: File path must be specified.", vim.log.levels.ERROR)
    return
  end

  local expanded_path = vim.fn.expand(filepath)
  local f = io.open(expanded_path, "r")
  if not f then
    vim.notify("Unwind: Could not open file: " .. tostring(expanded_path), vim.log.levels.ERROR)
    return
  end

  local limit = M.config.max_input_bytes or (2 * 1024 * 1024)
  local ok, content = pcall(function()
    return f:read(limit + 1)
  end)
  f:close()

  if not ok then
    vim.notify("Unwind: Error reading file " .. tostring(expanded_path) .. ": " .. tostring(content), vim.log.levels.ERROR)
    return
  end

  if not content or content == "" then
    vim.notify("Unwind: File is empty: " .. tostring(expanded_path), vim.log.levels.WARN)
    return
  end

  if #content > limit then
    vim.notify(string.format("Unwind: Ingested file exceeds maximum limit (%d bytes), truncating.", limit), vim.log.levels.WARN)
    content = content:sub(1, limit)
  end

  M.ingest(content)
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
  local root = raw_state.root or vim.fs.normalize(vim.fn.getcwd())
  local session = sessions.create({
    root = root,
    name = nil,
    transient = true,
  })
  M.activate_session(session)
  return session
end

--- Add the current source location to the active debugging session.
--- If no active session exists, creates an unnamed transient session.
function M.add_current_location()
  -- If currently inside sidebar or floating window, switch to source window first
  ui.ensure_source_window()
  sidebar.ensure_source_window()

  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)

  if not bufname or bufname == "" or vim.bo[bufnr].buftype ~= "" then
    vim.notify("Unwind: Cannot add frame from unnamed or non-file buffer.", vim.log.levels.WARN)
    return
  end

  local root = raw_state.root or vim.fs.normalize(vim.fn.getcwd())
  raw_state.root = root

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2] + 1 -- 1-indexed column

  -- Check if location resolver is available (Tree-sitter)
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

  local session = raw_state.active_session
  if not session then
    session = sessions.create({
      root = root,
      name = nil,
      transient = true,
      filter_enabled = M.config.filter_out_of_project or false,
    })
    raw_state.active_session = session
  end

  sessions.add_frame(session, frame_data, nil, raw_state.sessions)
  M.rebuild_derived(session)

  if not sidebar.is_open() then
    sidebar.open(session, get_sidebar_callbacks(session))
  else
    sidebar.render(session)
  end

  session.active_index = #session.frames
  M.jump_to_frame(#session.frames)
  vim.notify(string.format("Unwind: Added location %s:%d to session.", frame_data.file or frame_data.path, frame_data.line), vim.log.levels.INFO)
end

--- Toggle / Open session manager
function M.menu()
  local root = raw_state.root or vim.fs.normalize(vim.fn.getcwd())
  M.ensure_sessions_loaded(root)

  local items = {}
  table.insert(items, { type = "new_session" })
  table.insert(items, { type = "import_clipboard" })
  table.insert(items, { type = "blank" })

  local session = raw_state.active_session
  if session then
    local count = session.raw_frames and #session.raw_frames or 0
    table.insert(items, {
      type = "current_status",
      name = session.name or "Untitled",
      frame_count = count,
    })
    if not session.saved then
      table.insert(items, { type = "save_action" })
    end
    table.insert(items, { type = "blank" })
  end

  if #raw_state.sessions > 0 then
    table.insert(items, { type = "separator", text = "Saved Sessions" })
    for _, s in ipairs(raw_state.sessions) do
      table.insert(items, {
        type = "session",
        name = s.name,
        frame_count = s.raw_frames and #s.raw_frames or 0,
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
        local ok, err = sessions.rename(target_session, new_name, raw_state.sessions, root)
        if not ok then
          vim.notify("Unwind: " .. tostring(err), vim.log.levels.ERROR)
        else
          vim.notify("Unwind: Renamed session to '" .. target_session.name .. "'.", vim.log.levels.INFO)
          if raw_state.active_session == target_session and sidebar.is_open() then
            sidebar.render(target_session)
          end
        end
      end)
    end,
    on_delete = function(target_session)
      local ok = sessions.delete(target_session, raw_state.sessions, root)
      if not ok then
        vim.notify("Unwind: Failed to delete session '" .. (target_session.name or "") .. "'.", vim.log.levels.ERROR)
      else
        vim.notify("Unwind: Deleted session '" .. (target_session.name or "") .. "'.", vim.log.levels.INFO)
        if raw_state.active_session == target_session then
          decorator.clear()
          sidebar.hide()
          raw_state.active_session = nil
        end
      end
    end,
  })
end

--- Toggle right sidebar
function M.toggle_sidebar()
  if sidebar.is_open() then
    sidebar.hide()
  else
    if raw_state.active_session then
      sidebar.open(raw_state.active_session, {
        on_select_frame = function(f_idx)
          M.jump_to_frame(f_idx)
        end,
        on_delete_frame = function(f_idx)
          M.delete_frame_from_session(raw_state.active_session, f_idx)
        end,
        on_refresh = function()
          M.refresh_availability()
        end,
      })
    else
      vim.notify("Unwind: No active session to display in sidebar.", vim.log.levels.WARN)
    end
  end
end

--- Move a frame in session (reorder up/down)
---@param session table
---@param from_idx number
---@param to_idx number
function M.move_frame_in_session(session, from_idx, to_idx)
  if not session or not session.frames or not session.frames[from_idx] or not session.frames[to_idx] then
    return
  end
  local target_frame = session.frames[from_idx]
  local raw_from_idx = nil
  for idx, f in ipairs(session.raw_frames) do
    if f == target_frame then
      raw_from_idx = idx
      break
    end
  end

  local dest_frame = session.frames[to_idx]
  local raw_to_idx = nil
  for idx, f in ipairs(session.raw_frames) do
    if f == dest_frame then
      raw_to_idx = idx
      break
    end
  end

  if raw_from_idx and raw_to_idx then
    local ok = sessions.move_frame(session, raw_from_idx, raw_to_idx, raw_state.sessions)
    if ok then
      M.rebuild_derived(session)
      session.active_index = to_idx
      sidebar.render(session)
      sidebar.set_active(session, to_idx)
    end
  end
end

--- Replace a frame in session with current source location
---@param session table
---@param frame_idx number
function M.replace_frame_in_session(session, frame_idx)
  if not session or not session.frames or not session.frames[frame_idx] then
    return
  end

  ui.ensure_source_window()
  sidebar.ensure_source_window()

  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if not bufname or bufname == "" or vim.bo[bufnr].buftype ~= "" then
    vim.notify("Unwind: Cannot replace frame from unnamed or non-file buffer.", vim.log.levels.WARN)
    return
  end

  local root = session.root or raw_state.root or vim.fs.normalize(vim.fn.getcwd())
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

  local target_frame = session.frames[frame_idx]
  local raw_idx = nil
  for idx, f in ipairs(session.raw_frames) do
    if f == target_frame then
      raw_idx = idx
      break
    end
  end

  if raw_idx then
    local ok = sessions.update_frame(session, raw_idx, frame_data, raw_state.sessions)
    if ok then
      M.rebuild_derived(session)
      session.active_index = frame_idx
      sidebar.render(session)
      M.jump_to_frame(frame_idx)
      vim.notify(string.format("Unwind: Replaced frame %d with %s:%d.", frame_idx, frame_data.file, frame_data.line), vim.log.levels.INFO)
    end
  end
end

--- Remove a frame from a session
---@param session table
---@param frame_idx number
function M.delete_frame_from_session(session, frame_idx)
  if not session or not session.frames or not session.frames[frame_idx] then
    return
  end

  local target_frame = session.frames[frame_idx]
  local removed_raw_idx = nil
  for idx, f in ipairs(session.raw_frames) do
    if f == target_frame then
      removed_raw_idx = idx
      break
    end
  end

  if removed_raw_idx then
    local ok = sessions.remove_frame(session, removed_raw_idx, raw_state.sessions)
    if not ok then
      vim.notify("Unwind: Failed to persist frame deletion.", vim.log.levels.ERROR)
      return
    end
  end

  M.rebuild_derived(session)

  local prev_active_frame = (session.active_index and session.active_index > 0) and session.frames[session.active_index] or nil
  local is_active_frame_deleted = (target_frame == prev_active_frame)

  if #session.frames == 0 then
    session.active_index = 0
    session.active_file_index = 0
    decorator.clear()
    sidebar.render(session)
  else
    local new_index = nil
    if not is_active_frame_deleted and prev_active_frame then
      -- Find surviving index of previous active frame
      for idx, f in ipairs(session.frames) do
        if f == prev_active_frame then
          new_index = idx
          break
        end
      end
    end

    if not new_index then
      -- Target frame was active or could not be found: select nearest surviving frame
      new_index = math.max(1, math.min(frame_idx, #session.frames))
    end

    sidebar.render(session)
    M.jump_to_frame(new_index)
  end
end

--- Re-check availability of all unique files in active session
function M.refresh_availability()
  local session = raw_state.active_session
  if not session then return end
  local root = session.root or raw_state.root or vim.fs.normalize(vim.fn.getcwd())
  for _, f_entry in ipairs(session.files or {}) do
    local is_avail, resolved = M.check_file_availability(f_entry.resolved_path or f_entry.file, root)
    f_entry.available = is_avail
    f_entry.canonical_resolved = resolved
  end
  sidebar.render(session)
  vim.notify("Unwind: Refreshed file availability.", vim.log.levels.INFO)
end

return M
