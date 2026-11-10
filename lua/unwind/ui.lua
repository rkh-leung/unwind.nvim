-- lua/unwind/ui.lua
-- Session Manager Floating Menu & Input Prompts

local M = {}

local active_win = nil
local active_buf = nil
local menu_source_win = nil

local input_win = nil
local input_buf = nil
local input_source_win = nil
local input_session_id = 0

local prompt_win = nil
local prompt_buf = nil
local prompt_source_win = nil

--- Check if the specified or current window is a floating window
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
  if active_win and vim.api.nvim_win_is_valid(active_win) then
    M.close()
  end
  if input_win and vim.api.nvim_win_is_valid(input_win) then
    M.close_input()
  end
  if prompt_win and vim.api.nvim_win_is_valid(prompt_win) then
    M.close_prompt()
  end

  local cur_win = vim.api.nvim_get_current_win()
  if M.is_floating(cur_win) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and not M.is_floating(win) then
        pcall(vim.api.nvim_set_current_win, win)
        return
      end
    end
  end
end

--- Close the session manager floating menu if open
function M.close()
  local win = active_win
  local buf = active_buf
  local src_win = menu_source_win

  active_win = nil
  active_buf = nil
  menu_source_win = nil

  local cur_win = vim.api.nvim_get_current_win()
  local should_restore = (win and cur_win == win)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if should_restore and src_win and vim.api.nvim_win_is_valid(src_win) and not M.is_floating(src_win) then
    pcall(vim.api.nvim_set_current_win, src_win)
  end
end

--- Close the input floating window if open
function M.close_input()
  input_session_id = input_session_id + 1

  local win = input_win
  local buf = input_buf
  local src_win = input_source_win

  input_win = nil
  input_buf = nil
  input_source_win = nil

  local cur_win = vim.api.nvim_get_current_win()
  local should_restore = (win and cur_win == win)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if should_restore and src_win and vim.api.nvim_win_is_valid(src_win) and not M.is_floating(src_win) then
    pcall(vim.api.nvim_set_current_win, src_win)
  end
end

--- Close the single-line prompt floating window if open
function M.close_prompt()
  local win = prompt_win
  local buf = prompt_buf
  local src_win = prompt_source_win

  prompt_win = nil
  prompt_buf = nil
  prompt_source_win = nil

  local cur_win = vim.api.nvim_get_current_win()
  local should_restore = (win and cur_win == win)

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if should_restore and src_win and vim.api.nvim_win_is_valid(src_win) and not M.is_floating(src_win) then
    pcall(vim.api.nvim_set_current_win, src_win)
  end
end

--- Single-line prompt input modal for naming/renaming sessions
---@param title string
---@param default_val? string
---@param on_submit fun(text: string)
function M.prompt_input(title, default_val, on_submit)
  if prompt_win and vim.api.nvim_win_is_valid(prompt_win) then
    M.close_prompt()
  end

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  if editor_width < 10 or editor_height < 5 then
    vim.notify("Unwind: Terminal window is too small.", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  prompt_buf = buf

  vim.bo[buf].buftype = "prompt"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false

  local win_width = math.min(math.max(40, math.floor(editor_width * 0.4)), editor_width - 4)
  local win_height = 1
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
    title = " " .. title .. " ",
    title_pos = "center",
  }

  prompt_source_win = vim.api.nvim_get_current_win()
  local ok_win, win = pcall(vim.api.nvim_open_win, buf, true, win_opts)
  if not ok_win or not win or not vim.api.nvim_win_is_valid(win) then
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    prompt_buf = nil
    prompt_win = nil
    prompt_source_win = nil
    return
  end
  prompt_win = win

  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"

  local submitted = false
  local function submit_prompt(input_text)
    if submitted then return end
    submitted = true
    pcall(vim.cmd, "stopinsert")
    M.close_prompt()
    if on_submit then
      on_submit(input_text)
    end
  end

  vim.fn.prompt_setprompt(buf, "> ")
  vim.fn.prompt_setcallback(buf, submit_prompt)

  if default_val and default_val ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "> " .. default_val })
  end

  local key_opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set({ "n", "i" }, "<Esc>", function()
    M.close_prompt()
  end, key_opts)

  vim.cmd("startinsert!")

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if prompt_win == win then
        prompt_win = nil
      end
      if prompt_buf == buf then
        prompt_buf = nil
      end
    end,
  })
end

--- Opens the Session Manager floating menu
--- Displays:
---   > + Save current trace... (if working session is unsaved)
---   Saved session rows: <name> <X frames>
--- Keymaps:
---   <CR>   open session or save current trace
---   r      rename selected saved session
---   d      delete selected saved session
---   q/Esc  close menu
---@param items table[] List of manager row descriptors:
---               { type = "save_action" }
---               or { type = "session", session = s, name = s.name, frame_count = n }
---@param callbacks { on_save: fun(), on_select: fun(session: table), on_rename: fun(session: table), on_delete: fun(session: table) }
function M.open_session_manager(items, callbacks)
  if active_win and vim.api.nvim_win_is_valid(active_win) then
    M.close()
    return
  end

  if not items or #items == 0 then
    vim.notify("Unwind: No sessions available.", vim.log.levels.INFO)
    return
  end

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  if editor_width < 10 or editor_height < 5 then
    vim.notify("Unwind: Terminal window is too small to display menu.", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  active_buf = buf

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false

  local strwidth = vim.api.nvim_strwidth or function(s) return #s end

  local max_text_len = 0
  for _, it in ipairs(items) do
    local text = it.type == "save_action" and "+ Save current trace..." or (it.name or "")
    local w = strwidth(text)
    if w > max_text_len then
      max_text_len = w
    end
  end

  local target_width = math.max(48, max_text_len + 20)
  local max_w = math.max(1, editor_width - 4)
  local max_h = math.max(1, editor_height - 4)
  local win_width = math.max(1, math.min(target_width, max_w))
  local win_height = math.max(1, math.min(#items + 2, max_h))
  local row = math.max(0, math.floor((editor_height - win_height) / 2))
  local col = math.max(0, math.floor((editor_width - win_width) / 2))

  local lines = {}
  for _, it in ipairs(items) do
    if it.type == "save_action" then
      table.insert(lines, "  + Save current trace...")
    else
      local name = it.name or "Untitled"
      local count = it.frame_count or 0
      local suffix = string.format("%d frame%s", count, count == 1 and "" or "s")
      local suffix_w = strwidth(suffix)
      local max_name_w = (win_width - 2) - suffix_w - 4
      local name_w = strwidth(name)
      if name_w > max_name_w and max_name_w > 5 then
        local trunc = name
        while strwidth(trunc .. "...") > max_name_w and #trunc > 0 do
          trunc = trunc:sub(1, -2)
        end
        name = trunc .. "..."
        name_w = strwidth(name)
      end
      local pad = math.max(2, (win_width - 2) - name_w - suffix_w - 2)
      table.insert(lines, "  " .. name .. string.rep(" ", pad) .. suffix)
    end
  end

  table.insert(lines, "")
  table.insert(lines, " Enter open   r rename   d delete ")

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Add highlights
  local ns_ui = vim.api.nvim_create_namespace("unwind_ui")
  vim.api.nvim_buf_clear_namespace(buf, ns_ui, 0, -1)

  for idx, it in ipairs(items) do
    local line_idx = idx - 1
    if it.type == "save_action" then
      vim.api.nvim_buf_add_highlight(buf, ns_ui, "Title", line_idx, 0, -1)
    else
      vim.api.nvim_buf_add_highlight(buf, ns_ui, "Normal", line_idx, 0, -1)
      local line_content = lines[idx]
      local s, e = line_content:find("%d+%s+frames?")
      if s and e then
        vim.api.nvim_buf_add_highlight(buf, ns_ui, "Comment", line_idx, s - 1, e)
      end
    end
  end

  -- Help line highlight
  vim.api.nvim_buf_add_highlight(buf, ns_ui, "Comment", #lines - 1, 0, -1)

  local win_opts = {
    relative = "editor",
    width = win_width,
    height = win_height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Unwind Sessions ",
    title_pos = "center",
  }

  menu_source_win = vim.api.nvim_get_current_win()
  local ok_win, win = pcall(vim.api.nvim_open_win, buf, true, win_opts)
  if not ok_win or not win or not vim.api.nvim_win_is_valid(win) then
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    active_buf = nil
    active_win = nil
    menu_source_win = nil
    return
  end
  active_win = win

  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel"

  local keymap_opts = { noremap = true, silent = true, buffer = buf }

  local function get_current_item()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local line_idx = cursor[1]
    return items[line_idx]
  end

  -- <CR> selection
  vim.keymap.set("n", "<CR>", function()
    local it = get_current_item()
    if not it then return end
    if it.type == "save_action" then
      M.close()
      if callbacks.on_save then
        callbacks.on_save()
      end
    elseif it.type == "session" then
      M.close()
      if callbacks.on_select then
        callbacks.on_select(it.session)
      end
    end
  end, keymap_opts)

  -- r: rename
  vim.keymap.set("n", "r", function()
    local it = get_current_item()
    if it and it.type == "session" then
      M.close()
      if callbacks.on_rename then
        callbacks.on_rename(it.session)
      end
    end
  end, keymap_opts)

  -- d: delete
  vim.keymap.set("n", "d", function()
    local it = get_current_item()
    if it and it.type == "session" then
      M.close()
      if callbacks.on_delete then
        callbacks.on_delete(it.session)
      end
    end
  end, keymap_opts)

  -- 1 through 9 quick jump
  for i = 1, 9 do
    vim.keymap.set("n", tostring(i), function()
      local it = items[i]
      if it then
        if it.type == "save_action" then
          M.close()
          if callbacks.on_save then callbacks.on_save() end
        elseif it.type == "session" then
          M.close()
          if callbacks.on_select then callbacks.on_select(it.session) end
        end
      end
    end, keymap_opts)
  end

  vim.keymap.set("n", "q", function() M.close() end, keymap_opts)
  vim.keymap.set("n", "<Esc>", function() M.close() end, keymap_opts)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if active_win == win then active_win = nil end
      if active_buf == buf then active_buf = nil end
    end,
  })
end

--- Opens an interactive floating scratch buffer where the user can paste or type a stacktrace
---@param on_submit fun(text: string) Callback when the user submits the stacktrace
function M.open_input(on_submit)
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
    if submitted then return end
    submitted = true

    if not vim.api.nvim_buf_is_valid(buf) then return end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    vim.bo[buf].modified = false
    pcall(vim.cmd, "stopinsert")

    vim.schedule(function()
      if input_session_id ~= current_session then return end
      M.close_input()
      if on_submit then
        on_submit(text)
      end
    end)
  end

  local keymap_opts = { noremap = true, silent = true, buffer = buf }

  vim.keymap.set("n", "<C-s>", submit, keymap_opts)
  vim.keymap.set("i", "<C-s>", submit, keymap_opts)

  vim.keymap.set("n", "q", function() M.close_input() end, keymap_opts)
  vim.keymap.set("n", "<Esc>", function() M.close_input() end, keymap_opts)

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
      if input_win == win then input_win = nil end
      if input_buf == buf then input_buf = nil end
    end,
  })
end

--- Backward-compatible shim for tests directly calling ui.open(files, on_select)
function M.open(files, on_select)
  local items = {}
  for idx, f in ipairs(files or {}) do
    table.insert(items, {
      type = "session",
      name = f.file,
      frame_count = f.total_frames or 1,
      session = f,
    })
  end
  M.open_session_manager(items, {
    on_select = function(s)
      for idx, f in ipairs(files or {}) do
        if f == s then
          on_select(s, idx)
          break
        end
      end
    end,
  })
end

return M
