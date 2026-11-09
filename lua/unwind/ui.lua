-- lua/unwind/ui.lua
-- Harpoon-Style Distinct Files Floating Menu

local M = {}

local active_win = nil
local active_buf = nil
local menu_source_win = nil

local input_win = nil
local input_buf = nil
local input_source_win = nil
local input_session_id = 0

--- Close the floating menu if open
--- Return whether the specified or current window is a floating window
---@param win? number
---@return boolean
function M.is_floating(win)
  win = win or vim.api.nvim_get_current_win()
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local config = vim.api.nvim_win_get_config(win)
  return config.relative ~= nil and config.relative ~= ""
end

--- Ensures navigation runs inside a proper source window, closing or switching out of any active float
function M.ensure_source_window()
  local cur_win = vim.api.nvim_get_current_win()
  if active_win and vim.api.nvim_win_is_valid(active_win) then
    M.close()
  end
  if input_win and vim.api.nvim_win_is_valid(input_win) then
    M.close_input()
  end

  cur_win = vim.api.nvim_get_current_win()
  if M.is_floating(cur_win) then
    -- Find a valid non-floating window
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and not M.is_floating(win) then
        pcall(vim.api.nvim_set_current_win, win)
        return
      end
    end
  end
end

--- Close the floating menu if open
function M.close()
  local win = active_win
  local buf = active_buf
  local src_win = menu_source_win

  active_win = nil
  active_buf = nil
  menu_source_win = nil

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if src_win and vim.api.nvim_win_is_valid(src_win) and not M.is_floating(src_win) then
    pcall(vim.api.nvim_set_current_win, src_win)
  end
end

--- Close the input floating window if open
function M.close_input()
  -- Invalidate any pending scheduled submit callback from this session
  input_session_id = input_session_id + 1

  local win = input_win
  local buf = input_buf
  local src_win = input_source_win

  input_win = nil
  input_buf = nil
  input_source_win = nil

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if src_win and vim.api.nvim_win_is_valid(src_win) and not M.is_floating(src_win) then
    pcall(vim.api.nvim_set_current_win, src_win)
  end
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

  -- Calculate centered floating window dimensions first before creating buffer
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  if editor_width < 10 or editor_height < 5 then
    vim.notify("Unwind: Terminal window is too small to display menu.", vim.log.levels.WARN)
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

  local max_file_len = 0
  for _, item in ipairs(files) do
    if #item.file > max_file_len then
      max_file_len = #item.file
    end
  end

  local target_width = math.max(60, max_file_len + 25)
  local max_w = math.max(1, editor_width - 4)
  local max_h = math.max(1, editor_height - 4)
  local win_width = math.max(1, math.min(math.max(target_width, 60), max_w))
  local win_height = math.max(1, math.min(math.max(#files, 1), max_h))
  local row = math.max(0, math.floor((editor_height - win_height) / 2))
  local col = math.max(0, math.floor((editor_width - win_width) / 2))

  -- Format lines: "1. src/services/checkout.lua                (2 frames)"
  -- Compute padding against win_width - 2 so suffix does not wrap onto a second line
  local lines = {}
  for idx, item in ipairs(files) do
    local prefix = string.format("%d. %s", idx, item.file)
    local frame_suffix = string.format("(%d frame%s)", item.total_frames, item.total_frames > 1 and "s" or "")
    if item.is_vendor then
      frame_suffix = frame_suffix .. " [vendor]"
    end

    local max_prefix = (win_width - 2) - #frame_suffix - 3
    if #prefix > max_prefix and max_prefix > 8 then
      prefix = prefix:sub(1, max_prefix - 3) .. "..."
    end

    local padding_len = math.max(2, (win_width - 2) - #prefix - #frame_suffix)
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

  -- Capture the originating source window before opening float
  menu_source_win = vim.api.nvim_get_current_win()

  local ok_win, win = pcall(vim.api.nvim_open_win, buf, true, win_opts)
  if not ok_win or not win or not vim.api.nvim_win_is_valid(win) then
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    active_buf = nil
    active_win = nil
    menu_source_win = nil
    vim.notify("Unwind: Could not open floating window.", vim.log.levels.WARN)
    return
  end
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

  input_session_id = input_session_id + 1
  local current_session = input_session_id

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  if editor_width < 10 or editor_height < 5 then
    vim.notify("Unwind: Terminal window is too small to display input window.", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  input_buf = buf

  pcall(vim.api.nvim_buf_set_name, buf, "unwind://input/" .. buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false

  local max_w = math.max(1, editor_width - 4)
  local max_h = math.max(1, editor_height - 4)
  local win_width = math.max(1, math.min(math.max(math.floor(editor_width * 0.8), 70), max_w))
  local win_height = math.max(1, math.min(math.max(math.floor(editor_height * 0.6), 15), max_h))
  local row = math.max(0, math.floor((editor_height - win_height) / 2))
  local col = math.max(0, math.floor((editor_width - win_width) / 2))

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

  input_source_win = vim.api.nvim_get_current_win()

  local ok_win, win = pcall(vim.api.nvim_open_win, buf, true, win_opts)
  if not ok_win or not win or not vim.api.nvim_win_is_valid(win) then
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    input_buf = nil
    input_win = nil
    input_source_win = nil
    vim.notify("Unwind: Could not open floating input window.", vim.log.levels.WARN)
    return
  end
  input_win = win

  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel"

  local submitted = false
  local function submit()
    if submitted then
      return
    end
    submitted = true

    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    vim.bo[buf].modified = false
    pcall(vim.cmd, "stopinsert")

    vim.schedule(function()
      -- If user opened a newer input session in between, ignore this stale scheduled callback
      if input_session_id ~= current_session then
        return
      end
      M.close_input()
      if on_submit then
        on_submit(text)
      end
    end)
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
