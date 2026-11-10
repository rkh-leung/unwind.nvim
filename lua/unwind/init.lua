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

  local existing_buf = vim.fn.bufnr(target_path)
  if existing_buf == -1 and file_path then
    existing_buf = vim.fn.bufnr(file_path)
  end

  -- Only treat an existing buffer as available if it is loaded and not a newly-created empty unwritten buffer
  if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) and vim.api.nvim_buf_is_loaded(existing_buf) then
    local lines = vim.api.nvim_buf_get_lines(existing_buf, 0, -1, false)
    if #lines > 1 or (#lines == 1 and lines[1] ~= "") then
      return true, target_path
    end
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

  -- Revalidate availability on selection
  local file_entry = (frame.file_index and session.files) and session.files[frame.file_index] or nil
  local is_avail, resolved_path = M.check_file_availability(frame.resolved_path or frame.file, root)
  if file_entry then
    file_entry.available = is_avail
    file_entry.canonical_resolved = resolved_path
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
---@param session table
function M.activate_session(session)
  if not session then return end
  raw_state.active_session = session

  M.rebuild_derived(session)

  -- Open/reuse right sidebar
  sidebar.open(session, {
    on_select_frame = function(f_idx)
      M.jump_to_frame(f_idx)
    end,
    on_delete_frame = function(f_idx)
      M.delete_frame_from_session(session, f_idx)
    end,
    on_refresh = function()
      M.refresh_availability()
    end,
  })

  local target = (session.active_index and session.active_index > 0) and session.active_index or 1
  M.jump_to_frame(target)
end

--- Ingest a raw plain-text stacktrace string
--- Creates a new unsaved working session and leaves saved sessions untouched
---@param text string
function M.ingest(text)
  if not text or text == "" then
    vim.notify("Unwind: Ingested text is empty.", vim.log.levels.WARN)
    return
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
    return
  end

  local filter_enabled = M.config.filter_out_of_project or false
  local session = sessions.new_working(root, frames, filter_enabled)
  raw_state.active_session = session

  M.rebuild_derived(session)
  decorator.clear()

  if #session.frames == 0 then
    vim.notify("Unwind: All recognized frames were filtered out as vendor/external files.", vim.log.levels.WARN)
    return
  end

  vim.notify(string.format("Unwind: Loaded %d frames across %d files.", #session.frames, #session.files), vim.log.levels.INFO)

  -- Update sidebar if already open
  if sidebar.is_open() then
    sidebar.render(session)
  end

  -- Jump to first frame
  M.jump_to_frame(1)
end

--- Ingest stacktrace from clipboard register '+'
function M.ingest_clipboard()
  local text = vim.fn.getreg("+")
  if not text or text == "" then
    vim.notify("Unwind: Clipboard (+) is empty.", vim.log.levels.WARN)
    return
  end
  M.ingest(text)
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

--- Toggle / Open session manager
function M.menu()
  local root = raw_state.root or vim.fs.normalize(vim.fn.getcwd())
  M.ensure_sessions_loaded(root)

  local items = {}
  local session = raw_state.active_session

  -- If there is an unsaved working session, offer save action
  if session and not session.saved and session.raw_frames and #session.raw_frames > 0 then
    table.insert(items, { type = "save_action" })
  end

  for _, s in ipairs(raw_state.sessions) do
    table.insert(items, {
      type = "session",
      name = s.name,
      frame_count = s.raw_frames and #s.raw_frames or 0,
      session = s,
    })
  end

  if #items == 0 then
    vim.notify("Unwind: No active trace or saved sessions.", vim.log.levels.INFO)
    return
  end

  ui.open_session_manager(items, {
    on_save = function()
      ui.prompt_input("Session name", "", function(name)
        local ok, err = sessions.save_working(session, name, raw_state.sessions, root)
        if not ok then
          vim.notify("Unwind: " .. tostring(err), vim.log.levels.ERROR)
        else
          vim.notify("Unwind: Saved session '" .. session.name .. "'.", vim.log.levels.INFO)
          M.activate_session(session)
        end
      end)
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
      sessions.delete(target_session, raw_state.sessions, root)
      vim.notify("Unwind: Deleted session '" .. (target_session.name or "") .. "'.", vim.log.levels.INFO)
      if raw_state.active_session == target_session then
        decorator.clear()
        sidebar.hide()
        raw_state.active_session = nil
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

--- Remove a frame from a session
---@param session table
---@param frame_idx number
function M.delete_frame_from_session(session, frame_idx)
  if not session or not session.frames or not session.frames[frame_idx] then
    return
  end

  local target_frame = session.frames[frame_idx]
  for idx, f in ipairs(session.raw_frames) do
    if f == target_frame then
      table.remove(session.raw_frames, idx)
      break
    end
  end

  if session.saved then
    sessions.save(session.root, raw_state.sessions)
  end

  M.rebuild_derived(session)

  if #session.frames == 0 then
    session.active_index = 0
    session.active_file_index = 0
    decorator.clear()
  else
    session.active_index = math.max(1, math.min(frame_idx, #session.frames))
    local act_frame = session.frames[session.active_index]
    if act_frame and act_frame.file_index then
      session.active_file_index = act_frame.file_index
    end
  end

  sidebar.render(session)
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
