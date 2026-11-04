-- lua/unwind/ui.lua
-- Harpoon-Style Distinct Files Floating Menu

local M = {}

local active_win = nil
local active_buf = nil

--- Close the floating menu if open
function M.close()
  if active_win and vim.api.nvim_win_is_valid(active_win) then
    vim.api.nvim_win_close(active_win, true)
  end
  active_win = nil
  active_buf = nil
end

--- Toggles or opens the floating menu displaying unique files
---@param files table[] List of unique file entries from collector
---@param on_select fun(file_entry: table, index: number) Callback when a file is selected
function M.open(files, on_select)
  -- Toggle behavior: if already open, close it
  if active_win and vim.api.nvim_win_is_valid(active_win) then
    M.close()
    return
  end

  if not files or #files == 0 then
    vim.notify("Unwind: No files in current stacktrace.", vim.log.levels.INFO)
    return
  end

  -- Create scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)
  active_buf = buf

  -- Configure scratch buffer options
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false

  -- Format lines: "1. src/services/checkout.lua                (2 frames)"
  local lines = {}
  local max_file_len = 0
  for _, item in ipairs(files) do
    if #item.file > max_file_len then
      max_file_len = #item.file
    end
  end

  local target_width = math.max(60, max_file_len + 25)

  for idx, item in ipairs(files) do
    local prefix = string.format("%d. %s", idx, item.file)
    local frame_suffix = string.format("(%d frame%s)", item.total_frames, item.total_frames > 1 and "s" or "")
    local padding_len = math.max(2, target_width - #prefix - #frame_suffix - 4)
    local line_str = prefix .. string.rep(" ", padding_len) .. frame_suffix
    table.insert(lines, line_str)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Calculate centered floating window dimensions
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local win_width = math.min(math.max(target_width, 60), editor_width - 4)
  local win_height = math.min(math.max(#lines, 1), editor_height - 4)
  local row = math.floor((editor_height - win_height) / 2)
  local col = math.floor((editor_width - win_width) / 2)

  local win_opts = {
    relative = "editor",
    width = win_width,
    height = win_height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Unwind: Stacktrace Files ",
    title_pos = "center",
  }

  local win = vim.api.nvim_open_win(buf, true, win_opts)
  active_win = win

  vim.wo[win].cursorline = true

  local function select_idx(idx)
    if files[idx] then
      local selected = files[idx]
      M.close()
      if on_select then
        on_select(selected, idx)
      end
    end
  end

  -- Keymap options
  local keymap_opts = { noremap = true, silent = true, buffer = buf }

  -- <CR>: Jump to current cursor line index
  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local line_idx = cursor[1]
    select_idx(line_idx)
  end, keymap_opts)

  -- 1 through 9: Instantly jump to slot index 1–9 and close float
  for i = 1, 9 do
    vim.keymap.set("n", tostring(i), function()
      select_idx(i)
    end, keymap_opts)
  end

  -- q / <Esc>: Dismiss and wipe the menu window
  vim.keymap.set("n", "q", function()
    M.close()
  end, keymap_opts)

  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, keymap_opts)

  -- j / k: Standard navigation (already standard in normal mode, but explicit mapping keeps it clean)
  vim.keymap.set("n", "j", "j", keymap_opts)
  vim.keymap.set("n", "k", "k", keymap_opts)

  -- Clean up active_win/active_buf on BufWipeout
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if active_win == win then
        active_win = nil
      end
      if active_buf == buf then
        active_buf = nil
      end
    end,
  })
end

return M
