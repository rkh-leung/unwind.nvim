-- lua/unwind/init.lua
-- Main setup, state management, frame cycling, public API

local parser = require("unwind.parser")
local collector = require("unwind.collector")
local decorator = require("unwind.decorator")
local ui = require("unwind.ui")

local M = {}

--- Internal state
M.state = {
  root = nil,
  raw_frames = {},
  frames = {},
  files = {},
  active_index = 0,
  active_file_index = 0,
  filter_enabled = false,
}

--- Default configuration
M.config = {
  filter_out_of_project = false,
  path_mappings = {},
  max_input_bytes = 2 * 1024 * 1024, -- 2MB max input
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
  -- Remove only mappings that Unwind previously installed and currently owns
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

  register_key(keymaps.menu, function() M.menu() end, "Unwind: Open stacktrace files menu")
  register_key(keymaps.clipboard, function() M.ingest_clipboard() end, "Unwind: Ingest stacktrace from clipboard")
  register_key(keymaps.next, function() M.next() end, "Unwind: Next stack frame")
  register_key(keymaps.prev, function() M.prev() end, "Unwind: Previous stack frame")
  register_key(keymaps.next_file, function() M.next_file() end, "Unwind: Next stacktrace file")
  register_key(keymaps.prev_file, function() M.prev_file() end, "Unwind: Previous stacktrace file")
end

--- Setup unwind plugin options
---@param opts? table
function M.setup(opts)
  -- Clone opts shallowly so we never mutate caller's options table
  local user_opts = opts and vim.tbl_extend("force", {}, opts) or {}
  if user_opts.ignore_patterns then
    M.config.ignore_patterns = user_opts.ignore_patterns
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

--- Clear active decorations and state
function M.clear()
  decorator.clear()
  ui.close()
  ui.close_input()
  M.state.root = nil
  M.state.raw_frames = {}
  M.state.frames = {}
  M.state.files = {}
  M.state.active_index = 0
  M.state.active_file_index = 0
  vim.notify("Unwind: Cleared stacktrace state and diagnostics.", vim.log.levels.INFO)
end

--- Jump to a specific frame by index
--- Opens the target file (vim.cmd.edit), moves cursor to target line and column,
--- and re-renders virt_lines extmark decoration on the active line.
--- Guards against nonexistent files to prevent creating empty buffers,
--- and only commits active_index once navigation has succeeded.
---@param idx number
---@return boolean success
function M.jump_to_frame(idx)
  if #M.state.frames == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return false
  end

  if idx < 1 then
    idx = 1
  elseif idx > #M.state.frames then
    idx = #M.state.frames
  end

  local frame = M.state.frames[idx]
  if parser.is_non_navigable_path(frame.file) then
    vim.notify("Unwind: Non-navigable frame: " .. tostring(frame.file), vim.log.levels.WARN)
    return false
  end

  -- Ensure we are navigating in a source window, never inside an Unwind float
  ui.ensure_source_window()

  -- Use resolved_path as immutable target if present, otherwise frame.file
  local target_path = frame.resolved_path or frame.file
  local root = M.state.root or vim.fn.getcwd()
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
      -- Check filesystem stat before edit to prevent creating empty persistent buffers
      local stat = (vim.uv or vim.loop).fs_stat(target_path)
      if not stat or stat.type ~= "file" then
        stat = (vim.uv or vim.loop).fs_stat(frame.file)
      end

      if not stat or stat.type ~= "file" then
        vim.notify("Unwind: File not found: " .. tostring(frame.file), vim.log.levels.WARN)
        return false
      end

      local edit_target = target_path
      local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(edit_target))
      if not ok then
        -- Try with frame.file fallback
        ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(frame.file))
      end

      if not ok then
        vim.notify("Unwind: Could not open file " .. tostring(frame.file) .. ": " .. tostring(err), vim.log.levels.ERROR)
        return false
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

  -- Navigation succeeded! Now commit active indices
  M.state.active_index = idx
  if frame.file_index and M.state.files[frame.file_index] then
    M.state.active_file_index = frame.file_index
  else
    for f_idx, f_entry in ipairs(M.state.files) do
      if (f_entry.resolved_path and f_entry.resolved_path == frame.resolved_path) or f_entry.file == frame.file then
        M.state.active_file_index = f_idx
        break
      end
    end
  end

  -- Re-render extmark decoration on the active line
  decorator.render(bufnr, target_line, idx, frame.method, frame.file, #M.state.frames)
  return true
end

--- Jump to a specific file by index (Harpoon-style file slot)
--- Opens the target file at its primary fault line.
--- Only commits active_file_index on successful jump_to_frame().
---@param file_idx number
---@return boolean success
function M.jump_to_file(file_idx)
  if #M.state.files == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return false
  end

  if file_idx < 1 then
    file_idx = 1
  elseif file_idx > #M.state.files then
    file_idx = #M.state.files
  end

  local file_entry = M.state.files[file_idx]
  if file_entry.primary_frame_index and M.state.frames[file_entry.primary_frame_index] then
    return M.jump_to_frame(file_entry.primary_frame_index)
  end

  -- Find the first frame corresponding to this file
  for idx, frame in ipairs(M.state.frames) do
    if (frame.resolved_path and frame.resolved_path == file_entry.resolved_path) or frame.file == file_entry.file then
      if frame.line == file_entry.primary_line then
        return M.jump_to_frame(idx)
      end
    end
  end

  -- Fallback if exact line frame was somehow not matched
  for idx, frame in ipairs(M.state.frames) do
    if (frame.resolved_path and frame.resolved_path == file_entry.resolved_path) or frame.file == file_entry.file then
      return M.jump_to_frame(idx)
    end
  end

  return false
end

--- Cycle sequentially to next unique file (skipping unresolvable files)
function M.next_file()
  local total = #M.state.files
  if total == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return
  end
  local start = M.state.active_file_index or 0
  for offset = 1, total do
    local candidate = ((start + offset - 1) % total) + 1
    if M.jump_to_file(candidate) then
      return
    end
  end
  vim.notify("Unwind: None of the stacktrace files could be opened.", vim.log.levels.WARN)
end

--- Cycle sequentially to previous unique file (skipping unresolvable files)
function M.prev_file()
  local total = #M.state.files
  if total == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return
  end
  local start = M.state.active_file_index or 1
  for offset = 1, total do
    local candidate = ((start - offset - 1) % total) + 1
    if candidate <= 0 then
      candidate = candidate + total
    end
    if M.jump_to_file(candidate) then
      return
    end
  end
  vim.notify("Unwind: None of the stacktrace files could be opened.", vim.log.levels.WARN)
end

--- Cycle sequentially to next stack frame (skipping unresolvable frames)
function M.next()
  local total = #M.state.frames
  if total == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return
  end
  local start = M.state.active_index or 0
  for offset = 1, total do
    local candidate = ((start + offset - 1) % total) + 1
    if M.jump_to_frame(candidate) then
      return
    end
  end
  vim.notify("Unwind: None of the stacktrace frames could be opened.", vim.log.levels.WARN)
end

--- Cycle sequentially to previous stack frame (skipping unresolvable frames)
function M.prev()
  local total = #M.state.frames
  if total == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return
  end
  local start = M.state.active_index or 1
  for offset = 1, total do
    local candidate = ((start - offset - 1) % total) + 1
    if candidate <= 0 then
      candidate = candidate + total
    end
    if M.jump_to_frame(candidate) then
      return
    end
  end
  vim.notify("Unwind: None of the stacktrace frames could be opened.", vim.log.levels.WARN)
end

--- Re-apply collection and update state with current filter setting,
--- preserving active navigation context when possible.
function M.reapply_filter()
  if not M.state.raw_frames or #M.state.raw_frames == 0 then
    return
  end

  local prev_frame = (M.state.active_index and M.state.active_index > 0) and M.state.frames[M.state.active_index] or nil
  local prev_idx = M.state.active_index or 0

  local collected = collector.collect(M.state.raw_frames, {
    filter_vendor = M.state.filter_enabled,
    ignore_patterns = M.config.ignore_patterns,
  })

  M.state.frames = collected.frames
  M.state.files = collected.files

  if #M.state.frames == 0 then
    M.state.active_index = 0
    M.state.active_file_index = 0
    return
  end

  local new_active_index = nil

  -- 1. Try to find the exact same frame object or identical frame identity in the new frames list
  if prev_frame then
    for idx, f in ipairs(M.state.frames) do
      if f == prev_frame or (f.resolved_path == prev_frame.resolved_path and f.line == prev_frame.line and f.col == prev_frame.col and f.method == prev_frame.method) then
        new_active_index = idx
        break
      end
    end
  end

  -- 2. If not found, fall back to the nearest surviving frame (closest to prev_idx)
  if not new_active_index then
    if prev_idx > 0 then
      new_active_index = math.max(1, math.min(prev_idx, #M.state.frames))
    else
      new_active_index = 1
    end
  end

  M.state.active_index = new_active_index
  local active_frame = M.state.frames[new_active_index]
  if active_frame and active_frame.file_index and M.state.files[active_frame.file_index] then
    M.state.active_file_index = active_frame.file_index
  else
    M.state.active_file_index = 1
  end
end

--- Toggle vendor / library filtering
function M.toggle_filter()
  if not M.state.raw_frames or #M.state.raw_frames == 0 then
    vim.notify("Unwind: No active stacktrace to filter.", vim.log.levels.WARN)
    return
  end

  M.state.filter_enabled = not M.state.filter_enabled
  M.reapply_filter()

  if #M.state.frames == 0 then
    vim.notify("Unwind: All frames were filtered out as vendor/external files.", vim.log.levels.WARN)
    decorator.clear()
    return
  end

  local status = M.state.filter_enabled and "enabled (hiding vendor/library files)" or "disabled (showing all files)"
  vim.notify(string.format("Unwind: Vendor filter %s (%d frames, %d files).", status, #M.state.frames, #M.state.files), vim.log.levels.INFO)

  local target = M.state.active_index > 0 and M.state.active_index or 1
  if not M.jump_to_frame(target) then
    M.next()
  end
end

--- Ingest a raw plain-text stacktrace string
--- Transactional:
---   1. Parse & resolve with current root
---   2. Collect & deduplicate
---   3. Commit new state
---   4. Clear prior presentations/decorations
---   5. Attempt initial navigation
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
  local collected = collector.collect(frames, {
    root = root,
    filter_vendor = filter_enabled,
    ignore_patterns = M.config.ignore_patterns,
  })

  -- Commit state transactionally
  M.state.root = root
  M.state.raw_frames = frames
  M.state.filter_enabled = filter_enabled
  M.state.frames = collected.frames
  M.state.files = collected.files
  M.state.active_index = 0
  M.state.active_file_index = 0

  -- Clear previous decorations now that state is updated
  decorator.clear()

  if #M.state.frames == 0 then
    vim.notify("Unwind: All recognized frames were filtered out as vendor/external files.", vim.log.levels.WARN)
    return
  end

  vim.notify(string.format("Unwind: Loaded %d frames across %d files.", #M.state.frames, #collected.files), vim.log.levels.INFO)

  -- Jump to the first navigable frame
  M.next()
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

--- Ingest stacktrace from a 1-indexed line range (e.g. from visual selection / user command)
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
  -- Exit visual mode to populate '< and '> marks
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
  if #M.state.frames == 0 then
    vim.notify("Unwind: No active frames to export.", vim.log.levels.WARN)
    return
  end

  local qf_items = {}
  for _, frame in ipairs(M.state.frames) do
    table.insert(qf_items, {
      filename = frame.file,
      lnum = frame.line,
      col = frame.col or 1,
      text = frame.method ~= "" and ("at " .. frame.method) or frame.raw_line,
    })
  end

  vim.fn.setqflist({}, "r", { items = qf_items, title = "Unwind Stacktrace" })
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

--- Unified command dispatcher:
--- If an argument is provided (file path), ingest that file.
--- Otherwise, open the interactive paste/input scratchpad.
---@param arg? string
function M.unwind(arg)
  if arg and vim.trim(arg) ~= "" then
    M.ingest_file(vim.trim(arg))
  else
    M.open_input()
  end
end

--- Toggle / Open Harpoon-style distinct files floating menu
function M.menu()
  if #M.state.files == 0 then
    vim.notify("Unwind: No active stacktrace files to display.", vim.log.levels.WARN)
    return
  end

  ui.open(M.state.files, function(_, idx)
    M.jump_to_file(idx)
  end)
end

return M
