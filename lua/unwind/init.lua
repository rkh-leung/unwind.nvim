-- lua/unwind/init.lua
-- Main setup, state management, frame cycling, public API

local parser = require("unwind.parser")
local collector = require("unwind.collector")
local decorator = require("unwind.decorator")
local ui = require("unwind.ui")

local M = {}

--- Internal state
M.state = {
  frames = {},
  files = {},
  active_index = 0,
}

--- Default configuration
M.config = {
  keymaps = {
    menu = "<leader>w",
    clipboard = "<leader>c",
    next = "]u",
    prev = "[u",
  },
}

--- Setup unwind plugin options
---@param opts? table
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  if M.config.keymaps then
    if M.config.keymaps.menu then
      vim.keymap.set("n", M.config.keymaps.menu, function()
        M.menu()
      end, { desc = "Unwind: Open stacktrace files menu", silent = true })
    end
    if M.config.keymaps.clipboard then
      vim.keymap.set("n", M.config.keymaps.clipboard, function()
        M.ingest_clipboard()
      end, { desc = "Unwind: Ingest stacktrace from clipboard", silent = true })
    end
    if M.config.keymaps.next then
      vim.keymap.set("n", M.config.keymaps.next, function()
        M.next()
      end, { desc = "Unwind: Next stack frame", silent = true })
    end
    if M.config.keymaps.prev then
      vim.keymap.set("n", M.config.keymaps.prev, function()
        M.prev()
      end, { desc = "Unwind: Previous stack frame", silent = true })
    end
  end
end

--- Clear active decorations and state
function M.clear()
  decorator.clear()
  ui.close()
  M.state.frames = {}
  M.state.files = {}
  M.state.active_index = 0
  vim.notify("Unwind: Cleared stacktrace state and diagnostics.", vim.log.levels.INFO)
end

--- Jump to a specific frame by index
--- Opens the target file (vim.cmd.edit), moves cursor to target line and column,
--- and re-renders virt_lines extmark decoration on the active line.
---@param idx number
function M.jump_to_frame(idx)
  if #M.state.frames == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return
  end

  if idx < 1 then
    idx = 1
  elseif idx > #M.state.frames then
    idx = #M.state.frames
  end

  M.state.active_index = idx
  local frame = M.state.frames[idx]

  -- Open the target file
  local ok, err = pcall(function()
    vim.cmd.edit(vim.fn.fnameescape(frame.file))
  end)

  if not ok then
    vim.notify("Unwind: Could not open file " .. tostring(frame.file) .. ": " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local target_line = math.max(1, math.min(frame.line or 1, line_count))
  local target_col = math.max(0, (frame.col or 1) - 1)

  -- Move cursor to target line and column
  pcall(vim.api.nvim_win_set_cursor, 0, { target_line, target_col })

  -- Re-render extmark decoration on the active line
  decorator.render(bufnr, target_line, idx, frame.method, frame.file)
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

--- Ingest a raw plain-text stacktrace string
---@param text string
function M.ingest(text)
  if not text or text == "" then
    vim.notify("Unwind: Ingested text is empty.", vim.log.levels.WARN)
    return
  end

  local frames = parser.parse(text)
  if #frames == 0 then
    vim.notify("Unwind: No stack frames recognized in input.", vim.log.levels.WARN)
    return
  end

  local collected = collector.collect(frames)
  M.state.frames = collected.frames
  M.state.files = collected.files
  M.state.active_index = 0

  vim.notify(string.format("Unwind: Loaded %d frames across %d files.", #frames, #collected.files), vim.log.levels.INFO)

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

--- Ingest stacktrace from visual selection range
function M.ingest_selection()
  -- Get visual selection range
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  local s_row, s_col = start_pos[2], start_pos[3]
  local e_row, e_col = end_pos[2], end_pos[3]

  if s_row == 0 or e_row == 0 then
    vim.notify("Unwind: No visual selection found.", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, s_row - 1, e_row, false)
  if #lines == 0 then
    return
  end

  -- Truncate first and last lines based on column positions
  if #lines == 1 then
    lines[1] = string.sub(lines[1], s_col, e_col)
  else
    lines[1] = string.sub(lines[1], s_col)
    lines[#lines] = string.sub(lines[#lines], 1, e_col)
  end

  local text = table.concat(lines, "\n")
  M.ingest(text)
end

--- Toggle / Open Harpoon-style distinct files floating menu
function M.menu()
  if #M.state.files == 0 then
    vim.notify("Unwind: No active stacktrace files to display.", vim.log.levels.WARN)
    return
  end

  ui.open(M.state.files, function(file_entry)
    -- Find the first frame corresponding to this file
    for idx, frame in ipairs(M.state.frames) do
      if frame.file == file_entry.file and frame.line == file_entry.primary_line then
        M.jump_to_frame(idx)
        return
      end
    end

    -- Fallback to opening file directly at primary line
    pcall(function()
      vim.cmd.edit(vim.fn.fnameescape(file_entry.file))
      local bufnr = vim.api.nvim_get_current_buf()
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local target_line = math.max(1, math.min(file_entry.primary_line or 1, line_count))
      vim.api.nvim_win_set_cursor(0, { target_line, (file_entry.primary_col or 1) - 1 })
      decorator.render(bufnr, target_line, 1, file_entry.primary_method, file_entry.file)
    end)
  end)
end

return M
