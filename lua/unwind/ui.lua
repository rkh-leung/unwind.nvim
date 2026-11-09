-- lua/unwind/ui.lua
-- Harpoon-Style Distinct Files Floating Menu

local M = {}

local active_win = nil
local active_buf = nil
local input_win = nil
local input_buf = nil

--- Close the floating menu if open
function M.close()
  if active_win and vim.api.nvim_win_is_valid(active_win) then
    vim.api.nvim_win_close(active_win, true)
  end
  active_win = nil
  active_buf = nil
end

--- Close the input floating window if open
function M.close_input()
  if input_win and vim.api.nvim_win_is_valid(input_win) then
    vim.api.nvim_win_close(input_win, true)
  end
  input_win = nil
  input_buf = nil
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

  -- Calculate centered floating window dimensions first
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local max_file_len = 0
  for _, item in ipairs(files) do
    if #item.file > max_file_len then
      max_file_len = #item.file
    end
  end

  local target_width = math.max(60, max_file_len + 25)
  local win_width = math.min(math.max(target_width, 60), editor_width - 4)
  local win_height = math.min(math.max(#files, 1), editor_height - 4)
  local row = math.floor((editor_height - win_height) / 2)
  local col = math.floor((editor_width - win_width) / 2)

  -- Format lines: "1. src/services/checkout.lua                (2 frames)"
  -- Compute padding against win_width - 2 so suffix does not wrap onto a second line
  local lines = {}
  for idx, item in ipairs(files) do
    local prefix = string.format("%d. %s", idx, item.file)
    local frame_suffix = string.format("(%d frame%s)", item.total_frames, item.total_frames > 1 and "s" or "")
    if item.is_vendor then
      frame_suffix = frame_suffix .. " [vendor]"
    end
    local padding_len = math.max(2, (win_width - 2) - #prefix - #frame_suffix - 2)
    local line_str = prefix .. string.rep(" ", padding_len) .. frame_suffix
    table.insert(lines, line_str)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Apply syntax highlights per line in the menu buffer
  local ns_ui = vim.api.nvim_create_namespace("unwind_ui")
  vim.api.nvim_buf_clear_namespace(buf, ns_ui, 0, -1)

  for idx, item in ipairs(files) do
    local line_idx = idx - 1
    -- Highlight index number: e.g. "1." or "10."
    local prefix_len = tostring(idx):len() + 1
    vim.api.nvim_buf_add_highlight(buf, ns_ui, "Number", line_idx, 0, prefix_len)
    -- Highlight "[vendor]" tag
    if item.is_vendor then
      local line_content = lines[idx]
      local s, e = line_content:find("%[vendor%]")
      if s and e then
        vim.api.nvim_buf_add_highlight(buf, ns_ui, "Comment", line_idx, s - 1, e)
      end
    end
  end

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
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel"

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

--- Opens an interactive floating scratch buffer where the user can paste or type a stacktrace
---@param on_submit fun(text: string) Callback when the user submits the stacktrace
function M.open_input(on_submit)
  -- If already open, close it (toggle)
  if input_win and vim.api.nvim_win_is_valid(input_win) then
    M.close_input()
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  input_buf = buf

  pcall(vim.api.nvim_buf_set_name, buf, "unwind://input/" .. buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local win_width = math.min(math.max(math.floor(editor_width * 0.8), 70), editor_width - 4)
  local win_height = math.min(math.max(math.floor(editor_height * 0.6), 15), editor_height - 4)
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
    title = " Unwind: Paste Stacktrace (<C-s> / :w to submit, q / <Esc> in normal mode to cancel) ",
    title_pos = "center",
  }

  local win = vim.api.nvim_open_win(buf, true, win_opts)
  input_win = win

  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel"

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    M.close_input()
    if on_submit then
      on_submit(text)
    end
  end

  local keymap_opts = { noremap = true, silent = true, buffer = buf }

  -- Normal and Insert mode keymaps to submit
  vim.keymap.set("n", "<C-s>", submit, keymap_opts)
  vim.keymap.set("i", "<C-s>", submit, keymap_opts)

  -- Normal mode 'q' or '<Esc>' to cancel
  vim.keymap.set("n", "q", function()
    M.close_input()
  end, keymap_opts)
  vim.keymap.set("n", "<Esc>", function()
    M.close_input()
  end, keymap_opts)

  -- Intercept :w and :write to submit instead of failing with E32
  vim.api.nvim_buf_create_user_command(buf, "W", submit, { desc = "Submit stacktrace" })
  vim.api.nvim_buf_create_user_command(buf, "Write", submit, { desc = "Submit stacktrace" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      submit()
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if input_win == win then
        input_win = nil
      end
      if input_buf == buf then
        input_buf = nil
      end
    end,
  })
end

return M
