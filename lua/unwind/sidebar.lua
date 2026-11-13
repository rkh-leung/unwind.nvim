---@module "unwind.sidebar"
--- Window-layout controller for the persistent right-hand vertical split call-trace sidebar.
--- Delegates buffer creation, rendering, and synchronization to unwind.buffer.

local buffer_mod = require("unwind.buffer")

local M = {}

local sidebar_win = nil
local remembered_source_win = nil

--- Check if a window is the sidebar window
--- Returns true if `win` is the tracked sidebar_win, or if the buffer displayed
--- in `win` has filetype == "unwind" (covers :UnwindBuffer windows too).
---@param win? number
---@return boolean
function M.is_sidebar_window(win)
  win = win or vim.api.nvim_get_current_win()
  if sidebar_win ~= nil and vim.api.nvim_win_is_valid(sidebar_win) and win == sidebar_win then
    return true
  end
  if vim.api.nvim_win_is_valid(win) then
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "unwind" then
      return true
    end
  end
  return false
end

--- Returns whether the sidebar is currently open
---@return boolean
function M.is_open()
  return sidebar_win ~= nil and vim.api.nvim_win_is_valid(sidebar_win)
end

--- Returns the tracked sidebar window handle (may be nil if not open)
---@return integer? win
function M.get_sidebar_win()
  if sidebar_win and vim.api.nvim_win_is_valid(sidebar_win) then
    return sidebar_win
  end
  return nil
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

--- Render active session frames into the sidebar buffer.
--- Delegates to buffer_mod.render() whenever the canonical unwind://sidebar buffer
--- is valid and visible in any window (not only when sidebar_win is open), so that
--- :UnwindBuffer windows also stay synchronized.
---@param session table
function M.render(session)
  if not session then
    return
  end
  local buf = buffer_mod.get()
  if not buf then
    return
  end
  local buf_winid = vim.fn.bufwinid(buf)
  if buf_winid ~= -1 then
    buffer_mod.render(session, buf, M.is_open() and sidebar_win or nil)
  elseif M.is_open() then
    buffer_mod.render(session, buf, sidebar_win)
  end
end

--- Update active row highlight and cursor without re-rendering all lines.
--- Delegates to buffer_mod.set_active() whenever the canonical unwind://sidebar
--- buffer is valid and visible in any window.
---@param session table
---@param index number
function M.set_active(session, index)
  if not session then
    return
  end
  local buf = buffer_mod.get()
  if not buf then
    return
  end
  local buf_winid = vim.fn.bufwinid(buf)
  if buf_winid ~= -1 then
    buffer_mod.set_active(session, index, buf, M.is_open() and sidebar_win or nil)
  elseif M.is_open() then
    buffer_mod.set_active(session, index, buf, sidebar_win)
  end
end

--- Open or reuse the right sidebar split
---@param session table
---@param opts? table
function M.open(session, opts)
  opts = opts or {}

  local cur_win = vim.api.nvim_get_current_win()
  if not M.is_sidebar_window(cur_win) then
    remembered_source_win = cur_win
  end

  local buf = buffer_mod.get_or_create()

  -- Only reuse sidebar_win; never adopt an arbitrary window that happens to show
  -- the unwind buffer (e.g. a main editor window opened via :UnwindBuffer).
  if not sidebar_win or not vim.api.nvim_win_is_valid(sidebar_win) then
    -- Create vertical right split
    local width = 36
    vim.cmd(string.format("botright vertical %d split", width))
    sidebar_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(sidebar_win, buf)
  end

  buffer_mod.configure_window(sidebar_win)
  vim.wo[sidebar_win].winfixwidth = true

  M.render(session)

  -- Return focus to source window after opening sidebar if desired
  if remembered_source_win and vim.api.nvim_win_is_valid(remembered_source_win) then
    pcall(vim.api.nvim_set_current_win, remembered_source_win)
  end
end

return M
