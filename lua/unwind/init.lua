-- lua/unwind/init.lua
-- Main setup, state management, frame cycling, public API

local parser = require("unwind.parser")
local collector = require("unwind.collector")
local decorator = require("unwind.decorator")
local ui = require("unwind.ui")

local M = {}

--- Internal state
M.state = {
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

--- Track keymaps installed by setup so repeated setup calls clean up old ones
M._installed_keymaps = {}

--- Setup unwind plugin options
---@param opts? table
function M.setup(opts)
  -- Clone opts shallowly so we never mutate caller's options table
  local user_opts = opts and vim.tbl_extend("force", {}, opts) or {}
  if user_opts.ignore_patterns then
    M.config.ignore_patterns = user_opts.ignore_patterns
    user_opts.ignore_patterns = nil
  end
  M.config = vim.tbl_deep_extend("force", M.config, user_opts)

  -- Clean up previously installed keymaps
  for _, lhs in ipairs(M._installed_keymaps) do
    pcall(vim.keymap.del, "n", lhs)
  end
  M._installed_keymaps = {}

  if M.config.keymaps then
    local function register_key(lhs, fn, desc)
      if lhs and lhs ~= "" then
        vim.keymap.set("n", lhs, fn, { desc = desc, silent = true })
        table.insert(M._installed_keymaps, lhs)
      end
    end

    register_key(M.config.keymaps.menu, function() M.menu() end, "Unwind: Open stacktrace files menu")
    register_key(M.config.keymaps.clipboard, function() M.ingest_clipboard() end, "Unwind: Ingest stacktrace from clipboard")
    register_key(M.config.keymaps.next, function() M.next() end, "Unwind: Next stack frame")
    register_key(M.config.keymaps.prev, function() M.prev() end, "Unwind: Previous stack frame")
    register_key(M.config.keymaps.next_file, function() M.next_file() end, "Unwind: Next stacktrace file")
    register_key(M.config.keymaps.prev_file, function() M.prev_file() end, "Unwind: Previous stacktrace file")
  end
end

--- Clear active decorations and state
function M.clear()
  decorator.clear()
  ui.close()
  ui.close_input()
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

  -- Open the target file or switch to existing loaded buffer
  local target_path = vim.fs.normalize(frame.file)
  local current_path = vim.fs.normalize(vim.api.nvim_buf_get_name(0))

  if target_path ~= current_path then
    local target_full = vim.fs.normalize(vim.fn.fnamemodify(frame.file, ":p"))
    local existing_buf = vim.fn.bufnr(target_path)
    if existing_buf == -1 then
      existing_buf = vim.fn.bufnr(target_full)
    end

    local already_loaded = existing_buf ~= -1
      and vim.api.nvim_buf_is_valid(existing_buf)
      and vim.api.nvim_buf_is_loaded(existing_buf)

    if already_loaded then
      vim.api.nvim_set_current_buf(existing_buf)
    else
      -- Check filesystem stat before edit to prevent creating empty persistent buffers
      local stat = (vim.uv or vim.loop).fs_stat(target_full)
      if not stat or stat.type ~= "file" then
        stat = (vim.uv or vim.loop).fs_stat(frame.file)
      end

      if not stat or stat.type ~= "file" then
        vim.notify("Unwind: File not found: " .. tostring(frame.file), vim.log.levels.WARN)
        return false
      end

      local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(frame.file))
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
  for f_idx, f_entry in ipairs(M.state.files) do
    if f_entry.file == frame.file then
      M.state.active_file_index = f_idx
      break
    end
  end

  -- Re-render extmark decoration on the active line
  decorator.render(bufnr, target_line, idx, frame.method, frame.file, #M.state.frames)
  return true
end

--- Jump to a specific file by index (Harpoon-style file slot)
--- Opens the target file at its primary fault line.
---@param file_idx number
function M.jump_to_file(file_idx)
  if #M.state.files == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return
  end

  if file_idx < 1 then
    file_idx = 1
  elseif file_idx > #M.state.files then
    file_idx = #M.state.files
  end

  local file_entry = M.state.files[file_idx]
  M.state.active_file_index = file_idx

  -- Find the first frame corresponding to this file
  for idx, frame in ipairs(M.state.frames) do
    if frame.file == file_entry.file and frame.line == file_entry.primary_line then
      M.jump_to_frame(idx)
      return
    end
  end

  -- Fallback if exact line frame was somehow not matched
  for idx, frame in ipairs(M.state.frames) do
    if frame.file == file_entry.file then
      M.jump_to_frame(idx)
      return
    end
  end
end

--- Cycle sequentially to next unique file
function M.next_file()
  if #M.state.files == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return
  end
  local next_fidx = (M.state.active_file_index or 0) + 1
  if next_fidx > #M.state.files then
    next_fidx = 1
  end
  M.jump_to_file(next_fidx)
end

--- Cycle sequentially to previous unique file
function M.prev_file()
  if #M.state.files == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return
  end
  local prev_fidx = (M.state.active_file_index or 0) - 1
  if prev_fidx < 1 then
    prev_fidx = #M.state.files
  end
  M.jump_to_file(prev_fidx)
end

--- Cycle sequentially to next stack frame
function M.next()
  if #M.state.frames == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return
  end
  local next_idx = M.state.active_index + 1
  if next_idx > #M.state.frames then
    next_idx = 1
  end
  M.jump_to_frame(next_idx)
end

--- Cycle sequentially to previous stack frame
function M.prev()
  if #M.state.frames == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return
  end
  local prev_idx = M.state.active_index - 1
  if prev_idx < 1 then
    prev_idx = #M.state.frames
  end
  M.jump_to_frame(prev_idx)
end

--- Re-apply collection and update state with current filter setting
function M.reapply_filter()
  if not M.state.raw_frames or #M.state.raw_frames == 0 then
    return
  end

  local collected = collector.collect(M.state.raw_frames, {
    filter_vendor = M.state.filter_enabled,
    ignore_patterns = M.config.ignore_patterns,
  })

  M.state.frames = collected.frames
  M.state.files = collected.files
  M.state.active_index = 0
  M.state.active_file_index = 0
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

  M.jump_to_frame(1)
end

--- Ingest a raw plain-text stacktrace string
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

  local frames = parser.parse(text, {
    path_mappings = M.config.path_mappings,
    max_frames = M.config.max_frames,
  })
  if #frames == 0 then
    vim.notify("Unwind: No stack frames recognized in input.", vim.log.levels.WARN)
    return
  end

  M.state.raw_frames = frames
  M.state.filter_enabled = M.config.filter_out_of_project or false

  local collected = collector.collect(frames, {
    filter_vendor = M.state.filter_enabled,
    ignore_patterns = M.config.ignore_patterns,
  })
  M.state.frames = collected.frames
  M.state.files = collected.files
  M.state.active_index = 0
  M.state.active_file_index = 0

  if #M.state.frames == 0 then
    vim.notify("Unwind: All recognized frames were filtered out as vendor/external files.", vim.log.levels.WARN)
    return
  end

  vim.notify(string.format("Unwind: Loaded %d frames across %d files.", #M.state.frames, #collected.files), vim.log.levels.INFO)

  -- Jump to the first frame immediately
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

  local ok, content = pcall(function()
    return f:read("*all")
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
