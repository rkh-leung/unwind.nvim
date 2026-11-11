-- lua/unwind/sidebar.lua
-- Persistent right-hand vertical split call-trace sidebar
-- Yazi-style persistent pane displaying the active debugging session

local M = {}

local text_util = require("unwind.text")

local sidebar_win = nil
local sidebar_buf = nil
local remembered_source_win = nil
local ns_sidebar = vim.api.nvim_create_namespace("unwind_sidebar")
local ns_active = vim.api.nvim_create_namespace("unwind_sidebar_active")

--- Set up highlight groups if not yet defined
local function setup_highlights()
  vim.api.nvim_set_hl(0, "UnwindSidebarActive", { default = true, link = "CursorLine" })
  vim.api.nvim_set_hl(0, "UnwindSidebarMissing", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "UnwindSidebarHeader", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "UnwindSidebarMuted", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "UnwindSidebarAnnotated", { default = true, link = "Special" })
end

--- Check if a window is the sidebar window
---@param win? number
---@return boolean
function M.is_sidebar_window(win)
  win = win or vim.api.nvim_get_current_win()
  return sidebar_win ~= nil and vim.api.nvim_win_is_valid(sidebar_win) and win == sidebar_win
end

--- Returns whether the sidebar is currently open
---@return boolean
function M.is_open()
  return sidebar_win ~= nil and vim.api.nvim_win_is_valid(sidebar_win)
end

--- Get remembered or valid source window
---@return number win
function M.get_source_window()
  if remembered_source_win and vim.api.nvim_win_is_valid(remembered_source_win) and not M.is_sidebar_window(remembered_source_win) then
    local conf = vim.api.nvim_win_get_config(remembered_source_win)
    if not conf.relative or conf.relative == "" then
      return remembered_source_win
    end
  end

  -- Search all windows for first non-sidebar, non-floating window
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and not M.is_sidebar_window(win) then
      local conf = vim.api.nvim_win_get_config(win)
      if not conf.relative or conf.relative == "" then
        return win
      end
    end
  end

  return vim.api.nvim_get_current_win()
end

--- Ensures execution is targeting a source window, switching away from sidebar if needed
--- Ensures execution is targeting a source window, switching away from sidebar if needed.
--- If no other normal window exists, opens a normal split window rather than operating in the sidebar.
function M.ensure_source_window()
  local cur_win = vim.api.nvim_get_current_win()
  if M.is_sidebar_window(cur_win) then
    local src_win = M.get_source_window()
    if src_win and src_win ~= cur_win and vim.api.nvim_win_is_valid(src_win) then
      pcall(vim.api.nvim_set_current_win, src_win)
      return
    end

    -- If sidebar is the only normal window, create a new split
    vim.cmd("leftabove vsplit")
    local new_win = vim.api.nvim_get_current_win()
    if new_win and new_win ~= cur_win then
      remembered_source_win = new_win
    end
  end
end

--- Close / Hide sidebar window
function M.hide()
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    pcall(vim.api.nvim_win_close, sidebar_win, true)
  end
  sidebar_win = nil
end

--- Render active session frames into the sidebar buffer
---@param session table
function M.render(session)
  if not M.is_open() or not session then
    return
  end

  setup_highlights()
  local buf = sidebar_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns_sidebar, 0, -1)

  local win_width = 36
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    win_width = vim.api.nvim_win_get_width(sidebar_win)
  end

  local strwidth = vim.api.nvim_strwidth or function(s) return #s end

  -- Header line
  local title = session.name or "Untitled"
  if session.filter_enabled then
    title = title .. " [filtered]"
  end
  local header = " " .. title
  local lines = { header, "" }

  local frames = session.frames or {}
  if #frames == 0 then
    table.insert(lines, "  No locations yet")
    table.insert(lines, "")
    table.insert(lines, "  Add a source location (:UnwindAdd)")
  else
    for idx, f in ipairs(frames) do
      local file_entry = (f.file_index and session.files) and session.files[f.file_index] or nil
      local is_avail = true
      if file_entry and file_entry.available ~= nil then
        is_avail = file_entry.available
      end

      -- Compact row formatting:
      --   idx  method/NA   file:line
      -- If frame has note, show small indicator (●) beside idx
      local has_note = f.note ~= nil and f.note ~= ""
      local num_str = string.format("%2d", idx)
      local marker = has_note and "●" or " "
      local loc_str = string.format("%s:%d", vim.fs.basename(f.file or f.path or ""), f.line or 1)
      local status_str
      if not is_avail then
        status_str = "N/A"
      elseif f.method and f.method ~= "" then
        status_str = f.method
      else
        status_str = loc_str
        loc_str = ""
      end

      -- Compute fit
      local row_content
      if loc_str ~= "" then
        local base_w = strwidth(string.format(" %s%s   %s", marker, num_str, loc_str))
        if base_w + strwidth(status_str) > win_width and win_width > 12 then
          local max_status_w = math.max(4, win_width - strwidth(num_str) - strwidth(loc_str) - 8)
          status_str = text_util.truncate_display(status_str, max_status_w)
        end
        row_content = string.format(" %s%s %s  %s", marker, num_str, status_str, loc_str)
      else
        row_content = string.format(" %s%s %s", marker, num_str, status_str)
      end

      table.insert(lines, row_content)
    end
  end

  -- Footer: Always reserve a footer row so set_active() can reliably update it
  table.insert(lines, "")
  if session.active_index and session.active_index > 0 and session.frames and session.frames[session.active_index] then
    local act_frame = session.frames[session.active_index]
    local footer_text = string.format(" %d/%d %s:%d", session.active_index, #session.frames, act_frame.file or act_frame.path or "", act_frame.line or 1)
    table.insert(lines, footer_text)
  else
    table.insert(lines, "")
  end

  table.insert(lines, "")
  table.insert(lines, " enter open   d delete")
  table.insert(lines, " J/K move     e replace")
  table.insert(lines, " a note       s save")
  table.insert(lines, " q close")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Add syntax highlights
  -- Line 0: Header
  vim.api.nvim_buf_add_highlight(buf, ns_sidebar, "UnwindSidebarHeader", 0, 0, -1)

  for idx, f in ipairs(frames) do
    local buf_line = idx + 1 -- header is 0, blank is 1, frame 1 is 2
    local file_entry = (f.file_index and session.files) and session.files[f.file_index] or nil
    local is_avail = true
    if file_entry and file_entry.available ~= nil then
      is_avail = file_entry.available
    end

    if f.note ~= nil and f.note ~= "" then
      vim.api.nvim_buf_add_highlight(buf, ns_sidebar, "UnwindSidebarAnnotated", buf_line, 1, 4) -- Highlight ● indicator
    end

    if not is_avail then
      vim.api.nvim_buf_add_highlight(buf, ns_sidebar, "UnwindSidebarMissing", buf_line, 0, -1)
    else
      -- Muted file location
      vim.api.nvim_buf_add_highlight(buf, ns_sidebar, "UnwindSidebarMuted", buf_line, 0, -1)
    end
  end

  -- Update active highlight and cursor
  M.set_active(session, session.active_index or 1)
end

--- Update active row highlight and sidebar cursor without re-rendering all lines
---@param session table
---@param index number
function M.set_active(session, index)
  if not M.is_open() or not session then
    return
  end

  local buf = sidebar_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local frames = session.frames or {}
  if #frames == 0 then
    return
  end

  index = math.max(1, math.min(index or 1, #frames))
  local target_buf_line = index + 1 -- 0-indexed line in buffer (row 2 is frame 1)

  -- Move cursor in sidebar window if it exists
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    local max_line = vim.api.nvim_buf_line_count(buf)
    local cur_target = math.min(target_buf_line + 1, max_line) -- 1-indexed for set_cursor
    pcall(vim.api.nvim_win_set_cursor, sidebar_win, { cur_target, 0 })
  end

  -- Apply active highlight line
  vim.api.nvim_buf_clear_namespace(buf, ns_active, 0, -1)

  local file_entry = (frames[index].file_index and session.files) and session.files[frames[index].file_index] or nil
  local is_avail = true
  if file_entry then
    is_avail = file_entry.available ~= false
  end

  vim.api.nvim_buf_add_highlight(buf, ns_active, "UnwindSidebarActive", target_buf_line, 0, -1)
  if not is_avail then
    vim.api.nvim_buf_add_highlight(buf, ns_active, "UnwindSidebarMissing", target_buf_line, 0, -1)
  end

  -- Update footer if present
  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count >= #frames + 4 then
    -- Line index for footer_text: lines before help block
    -- lines: header(1), blank(2), frames(#frames), blank(#frames+3), footer_text(#frames+4), blank(#frames+5), help(3 lines)
    local footer_line = #frames + 3 -- 0-based index
    if footer_line < line_count then
      local act_frame = frames[index]
      local footer_text = string.format(" %d/%d %s:%d", index, #frames, act_frame.file or act_frame.path or "", act_frame.line or 1)
      vim.bo[buf].modifiable = true
      pcall(vim.api.nvim_buf_set_lines, buf, footer_line, footer_line + 1, false, { footer_text })
      vim.bo[buf].modifiable = false
    end
  end
end

--- Open or reuse the right sidebar split
---@param session table
---@param opts? { on_select_frame?: fun(idx: number), on_delete_frame?: fun(idx: number), on_move_frame?: fun(from: number, to: number), on_replace_frame?: fun(idx: number), on_save?: fun(), on_refresh?: fun() }
function M.open(session, opts)
  opts = opts or {}
  setup_highlights()

  local cur_win = vim.api.nvim_get_current_win()
  if not M.is_sidebar_window(cur_win) then
    remembered_source_win = cur_win
  end

  -- Create buffer if not exists or invalid
  if not sidebar_buf or not vim.api.nvim_buf_is_valid(sidebar_buf) then
    sidebar_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[sidebar_buf].buftype = "nofile"
    vim.bo[sidebar_buf].bufhidden = "hide"
    vim.bo[sidebar_buf].swapfile = false
    vim.bo[sidebar_buf].buflisted = false
    pcall(vim.api.nvim_buf_set_name, sidebar_buf, "unwind://sidebar")
  end

  local buf = sidebar_buf

  -- If window already open, reuse it
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then
    -- Find if sidebar_buf is displayed anywhere
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
        sidebar_win = w
        break
      end
    end
  end

  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then
    -- Create vertical right split
    local width = 36
    vim.cmd(string.format("botright vertical %d split", width))
    sidebar_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(sidebar_win, buf)

    vim.wo[sidebar_win].number = false
    vim.wo[sidebar_win].relativenumber = false
    vim.wo[sidebar_win].signcolumn = "no"
    vim.wo[sidebar_win].wrap = false
    vim.wo[sidebar_win].winfixwidth = true
    vim.wo[sidebar_win].cursorline = false
  end

  -- Set buffer local keymaps
  local key_opts = { noremap = true, silent = true, buffer = buf }

  local function get_active_session()
    local ok_state, state_mod = pcall(require, "unwind.state")
    if ok_state and state_mod and state_mod.current then
      return state_mod.current() or session
    end
    return session
  end

  vim.keymap.set("n", "<CR>", function()
    local cur_sess = get_active_session()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_idx = cursor[1] -- 1-indexed line in buffer
    local frame_idx = line_idx - 2 -- frame 1 is line 3 (index 2 in 0-based)
    if opts.on_select_frame and frame_idx >= 1 and frame_idx <= #(cur_sess.frames or {}) then
      opts.on_select_frame(frame_idx)
    end
  end, key_opts)

  vim.keymap.set("n", "d", function()
    local cur_sess = get_active_session()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_idx = cursor[1]
    local frame_idx = line_idx - 2
    if opts.on_delete_frame and frame_idx >= 1 and frame_idx <= #(cur_sess.frames or {}) then
      opts.on_delete_frame(frame_idx)
    end
  end, key_opts)

  -- J: Move selected frame down
  vim.keymap.set("n", "J", function()
    local cur_sess = get_active_session()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local frame_idx = cursor[1] - 2
    local total = #(cur_sess.frames or {})
    if opts.on_move_frame and frame_idx >= 1 and frame_idx < total then
      opts.on_move_frame(frame_idx, frame_idx + 1)
    end
  end, key_opts)

  -- K: Move selected frame up
  vim.keymap.set("n", "K", function()
    local cur_sess = get_active_session()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local frame_idx = cursor[1] - 2
    local total = #(cur_sess.frames or {})
    if opts.on_move_frame and frame_idx > 1 and frame_idx <= total then
      opts.on_move_frame(frame_idx, frame_idx - 1)
    end
  end, key_opts)

  -- a: Annotate selected frame
  vim.keymap.set("n", "a", function()
    local cur_sess = get_active_session()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local frame_idx = cursor[1] - 2
    if opts.on_annotate_frame and frame_idx >= 1 and frame_idx <= #(cur_sess.frames or {}) then
      opts.on_annotate_frame(frame_idx)
    end
  end, key_opts)

  -- e: Replace selected frame with current source location
  vim.keymap.set("n", "e", function()
    local cur_sess = get_active_session()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local frame_idx = cursor[1] - 2
    if opts.on_replace_frame and frame_idx >= 1 and frame_idx <= #(cur_sess.frames or {}) then
      opts.on_replace_frame(frame_idx)
    end
  end, key_opts)

  -- s: Save current session
  vim.keymap.set("n", "s", function()
    if opts.on_save then
      opts.on_save()
    end
  end, key_opts)

  vim.keymap.set("n", "r", function()
    if opts.on_refresh then
      opts.on_refresh()
    end
  end, key_opts)

  vim.keymap.set("n", "q", function()
    M.hide()
    local src = M.get_source_window()
    if src and vim.api.nvim_win_is_valid(src) then
      pcall(vim.api.nvim_set_current_win, src)
    end
  end, key_opts)

  M.render(session)

  -- Return focus to source window after opening sidebar if desired
  if remembered_source_win and vim.api.nvim_win_is_valid(remembered_source_win) then
    pcall(vim.api.nvim_set_current_win, remembered_source_win)
  end
end

return M
