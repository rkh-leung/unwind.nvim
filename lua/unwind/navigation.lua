---@module "unwind.navigation"
--- Buffer navigation, cursor jumping, frame cycling, file cycling, and quickfix export.

local parser = require("unwind.parser")
local path_util = require("unwind.path")
local decorator = require("unwind.decorator")
local ui = require("unwind.ui")

local function get_sidebar()
  return require("unwind.sidebar")
end

local M = {}

--- Check availability of a file path against root
---@param file_path string
---@param root string
---@param path_mappings? table<string, string>
---@return boolean available
---@return string resolved_path
function M.check_file_availability(file_path, root, path_mappings)
  if not file_path or file_path == "" or parser.is_non_navigable_path(file_path) then
    return false, file_path
  end

  local norm_opts = {
    root = root,
    path_mappings = path_mappings,
  }
  local _, resolved, _ = parser.resolve_and_normalize_path(file_path, norm_opts)

  local target_path = resolved
  if not path_util.is_absolute(target_path) then
    target_path = root .. "/" .. target_path
  end
  target_path = vim.fs.normalize(target_path)

  if path_util.is_file(target_path) then
    return true, target_path
  end
  if path_util.is_file(file_path) then
    return true, file_path
  end

  return false, target_path
end

--- Jump to a specific frame by index in active session
---@param session table
---@param idx number
---@return boolean selected
---@return boolean opened
function M.jump_to_frame(session, idx)
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
  local root = session.root or vim.fs.normalize(vim.fn.getcwd())

  -- Fast-path availability check on selection
  local file_entry = (frame.file_index and session.files) and session.files[frame.file_index] or nil
  local target_candidate = (file_entry and file_entry.canonical_resolved)
    or frame.resolved_path
    or frame.file

  local is_avail = false
  local resolved_path = target_candidate
  if not parser.is_non_navigable_path(frame.file) and target_candidate and target_candidate ~= "" then
    local check_path = target_candidate
    if not path_util.is_absolute(check_path) then
      check_path = root .. "/" .. check_path
    end
    check_path = vim.fs.normalize(check_path)
    if path_util.is_file(check_path) then
      is_avail = true
      resolved_path = check_path
    elseif path_util.is_file(target_candidate) then
      is_avail = true
      resolved_path = target_candidate
    end
  end

  if file_entry then
    file_entry.available = is_avail
    if is_avail then
      file_entry.canonical_resolved = resolved_path
    end
  end

  if not is_avail or parser.is_non_navigable_path(frame.file) then
    session.active_index = idx
    if frame.file_index and session.files[frame.file_index] then
      session.active_file_index = frame.file_index
    else
      for f_idx, f_ent in ipairs(session.files or {}) do
        if (f_ent.resolved_path and f_ent.resolved_path == frame.resolved_path) or f_ent.file == frame.file then
          session.active_file_index = f_idx
          break
        end
      end
    end

    decorator.clear()
    get_sidebar().set_active(session, idx)
    vim.notify("Unwind: File not found: " .. tostring(frame.file), vim.log.levels.WARN)
    return true, false
  end

  ui.ensure_source_window()
  get_sidebar().ensure_source_window()

  local target_path = resolved_path or frame.resolved_path or frame.file
  if not path_util.is_absolute(target_path) then
    target_path = root .. "/" .. target_path
  end
  target_path = vim.fs.normalize(target_path)

  local current_path = vim.fs.normalize(vim.api.nvim_buf_get_name(0))

  if target_path ~= current_path then
    local existing_buf = vim.fn.bufnr(target_path)
    local already_loaded = existing_buf ~= -1
      and vim.api.nvim_buf_is_valid(existing_buf)
      and vim.api.nvim_buf_is_loaded(existing_buf)

    if already_loaded then
      vim.api.nvim_set_current_buf(existing_buf)
    else
      local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(target_path))
      if not ok then
        vim.notify("Unwind: Could not open file " .. tostring(frame.file) .. ": " .. tostring(err), vim.log.levels.ERROR)
        session.active_index = idx
        decorator.clear()
        get_sidebar().set_active(session, idx)
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
  if frame.file_index and session.files and session.files[frame.file_index] then
    session.active_file_index = frame.file_index
  else
    for f_idx, f_ent in ipairs(session.files or {}) do
      if (f_ent.resolved_path and f_ent.resolved_path == frame.resolved_path) or f_ent.file == frame.file then
        session.active_file_index = f_idx
        break
      end
    end
  end

  decorator.render(bufnr, target_line, idx, frame.method, frame.file, #session.frames, {
    origin = frame.origin,
    note = frame.note,
  })
  get_sidebar().set_active(session, idx)
  return true, true
end

--- Jump to a specific file by index
---@param session table
---@param file_idx number
---@return boolean success
function M.jump_to_file(session, file_idx)
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
    local selected, _ = M.jump_to_frame(session, target_frame_idx)
    return selected
  end

  return false
end

--- Cycle sequentially to next unique file
---@param session table
function M.next_file(session)
  if not session or not session.files or #session.files == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return
  end
  local total = #session.files
  local start = session.active_file_index or 0
  local candidate = ((start) % total) + 1
  M.jump_to_file(session, candidate)
end

--- Cycle sequentially to previous unique file
---@param session table
function M.prev_file(session)
  if not session or not session.files or #session.files == 0 then
    vim.notify("Unwind: No active stacktrace files.", vim.log.levels.WARN)
    return
  end
  local total = #session.files
  local start = session.active_file_index or 1
  local candidate = ((start - 2) % total) + 1
  if candidate <= 0 then candidate = candidate + total end
  M.jump_to_file(session, candidate)
end

--- Cycle sequentially to next stack frame
---@param session table
function M.next(session)
  if not session or not session.frames or #session.frames == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return
  end
  local total = #session.frames
  local start = session.active_index or 0
  local candidate = ((start) % total) + 1
  M.jump_to_frame(session, candidate)
end

--- Cycle sequentially to previous stack frame
---@param session table
function M.prev(session)
  if not session or not session.frames or #session.frames == 0 then
    vim.notify("Unwind: No active stacktrace.", vim.log.levels.WARN)
    return
  end
  local total = #session.frames
  local start = session.active_index or 1
  local candidate = ((start - 2) % total) + 1
  if candidate <= 0 then candidate = candidate + total end
  M.jump_to_frame(session, candidate)
end

--- Export active stacktrace frames to Neovim's quickfix list
---@param session table
function M.quickfix(session)
  if not session or not session.frames or #session.frames == 0 then
    vim.notify("Unwind: No active frames to export.", vim.log.levels.WARN)
    return
  end

  local root = session.root or vim.fs.normalize(vim.fn.getcwd())
  local qf_items = {}

  for _, frame in ipairs(session.frames) do
    local file_entry = (frame.file_index and session.files) and session.files[frame.file_index] or nil
    local navigable_path = (file_entry and file_entry.canonical_resolved)
      or frame.resolved_path
      or frame.file

    local is_missing = (file_entry and file_entry.available == false) or (frame.navigable == false)

    local method_text = (frame.method and frame.method ~= "") and ("at " .. frame.method) or nil
    local raw_text = (frame.raw_line and frame.raw_line ~= "") and frame.raw_line or nil
    local item_text = method_text or raw_text or (frame.file or "")
    if is_missing then
      item_text = "[N/A] " .. item_text
    end

    local qf_item = {
      filename = navigable_path,
      lnum = frame.line or 1,
      col = frame.col or 1,
      text = item_text,
      valid = is_missing and 0 or 1,
    }
    table.insert(qf_items, qf_item)
  end

  vim.fn.setqflist({}, "r", { items = qf_items, title = session.name or "Unwind Stacktrace" })
  vim.cmd("copen")
end

return M
