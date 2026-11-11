-- lua/unwind/session_actions.lua
-- Session modifications, frame mutations, filter reapplication, and availability refresh

local collector = require("unwind.collector")
local decorator = require("unwind.decorator")
local sessions = require("unwind.sessions")
local sidebar = require("unwind.sidebar")
local ui = require("unwind.ui")
local parser = require("unwind.parser")
local navigation = require("unwind.navigation")

local M = {}

--- Rebuild runtime derived frames, files, and availability for a session
---@param session table
---@param config table
---@param root? string
function M.rebuild_derived(session, config, root)
  if not session or not session.raw_frames then
    return
  end

  root = root or session.root or vim.fs.normalize(vim.fn.getcwd())
  local collected = collector.collect(session.raw_frames, {
    root = root,
    filter_vendor = session.filter_enabled,
    ignore_patterns = config.ignore_patterns,
  })

  session.frames = collected.frames
  session.files = collected.files

  for _, f_entry in ipairs(session.files) do
    local is_avail, resolved = navigation.check_file_availability(
      f_entry.resolved_path or f_entry.file,
      root,
      config.path_mappings
    )
    f_entry.available = is_avail
    f_entry.canonical_resolved = resolved
  end
end

--- Re-apply collection and update active session with current filter setting
---@param session table
---@param config table
function M.reapply_filter(session, config)
  if not session or not session.raw_frames or #session.raw_frames == 0 then
    return
  end

  local prev_frame = (session.active_index and session.active_index > 0) and session.frames[session.active_index] or nil
  local prev_idx = session.active_index or 0

  M.rebuild_derived(session, config)

  if #session.frames == 0 then
    session.active_index = 0
    session.active_file_index = 0
    sidebar.render(session)
    return
  end

  local new_active_index = nil
  if prev_frame then
    for idx, f in ipairs(session.frames) do
      if f == prev_frame or (f.resolved_path == prev_frame.resolved_path and f.line == prev_frame.line and f.col == prev_frame.col and f.method == prev_frame.method) then
        new_active_index = idx
        break
      end
    end
  end

  if not new_active_index then
    if prev_idx > 0 then
      new_active_index = math.max(1, math.min(prev_idx, #session.frames))
    else
      new_active_index = 1
    end
  end

  session.active_index = new_active_index
  local active_frame = session.frames[new_active_index]
  if active_frame and active_frame.file_index and session.files[active_frame.file_index] then
    session.active_file_index = active_frame.file_index
  else
    session.active_file_index = 1
  end

  sidebar.render(session)
end

--- Toggle vendor / library filtering for active session
---@param session table
---@param saved_sessions table[]
---@param config table
function M.toggle_filter(session, saved_sessions, config)
  if not session or not session.raw_frames or #session.raw_frames == 0 then
    vim.notify("Unwind: No active stacktrace to filter.", vim.log.levels.WARN)
    return
  end

  session.filter_enabled = not session.filter_enabled
  if session.saved then
    sessions.save(session.root, saved_sessions)
  end

  M.reapply_filter(session, config)

  if #session.frames == 0 then
    vim.notify("Unwind: All frames were filtered out as vendor/external files.", vim.log.levels.WARN)
    decorator.clear()
    return
  end

  local status = session.filter_enabled and "enabled (hiding vendor/library files)" or "disabled (showing all files)"
  vim.notify(string.format("Unwind: Vendor filter %s (%d frames, %d files).", status, #session.frames, #session.files), vim.log.levels.INFO)

  local target = session.active_index > 0 and session.active_index or 1
  navigation.jump_to_frame(session, target)
end

--- Move a frame in session (reorder up/down)
---@param session table
---@param from_idx number
---@param to_idx number
---@param saved_sessions table[]
---@param config table
function M.move_frame_in_session(session, from_idx, to_idx, saved_sessions, config)
  if not session or not session.frames or not session.frames[from_idx] or not session.frames[to_idx] then
    return
  end
  local target_frame = session.frames[from_idx]
  local raw_from_idx = target_frame.raw_index

  local dest_frame = session.frames[to_idx]
  local raw_to_idx = dest_frame.raw_index

  if raw_from_idx and raw_to_idx then
    local ok = sessions.move_frame(session, raw_from_idx, raw_to_idx, saved_sessions)
    if ok then
      M.rebuild_derived(session, config)
      session.active_index = to_idx
      sidebar.render(session)
      sidebar.set_active(session, to_idx)
    end
  end
end

--- Replace a frame in session with current source location
---@param session table
---@param frame_idx number
---@param saved_sessions table[]
---@param config table
function M.replace_frame_in_session(session, frame_idx, saved_sessions, config)
  if not session or not session.frames or not session.frames[frame_idx] then
    return
  end

  ui.ensure_source_window()
  sidebar.ensure_source_window()

  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if not bufname or bufname == "" or vim.bo[bufnr].buftype ~= "" then
    vim.notify("Unwind: Cannot replace frame from unnamed or non-file buffer.", vim.log.levels.WARN)
    return
  end

  local root = session.root or vim.fs.normalize(vim.fn.getcwd())
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2] + 1

  local ok_loc, location = pcall(require, "unwind.location")
  local frame_data = nil
  if ok_loc and location and location.from_cursor then
    frame_data = location.from_cursor({
      bufnr = bufnr,
      row = row,
      col = col,
      root = root,
    })
  end

  if not frame_data then
    local rel_path = bufname
    if vim.startswith(bufname, root .. "/") then
      rel_path = bufname:sub(#root + 2)
    end
    frame_data = {
      path = bufname,
      file = rel_path,
      line = row,
      col = col,
      column = col,
      method = nil,
      origin = "manual",
      raw_line = string.format("%s:%d:%d", rel_path, row, col),
    }
  end

  local target_frame = session.frames[frame_idx]
  local raw_idx = target_frame.raw_index

  if raw_idx then
    local ok = sessions.update_frame(session, raw_idx, frame_data, saved_sessions)
    if ok then
      M.rebuild_derived(session, config)
      session.active_index = frame_idx
      sidebar.render(session)
      navigation.jump_to_frame(session, frame_idx)
      vim.notify(string.format("Unwind: Replaced frame %d with %s:%d.", frame_idx, frame_data.file, frame_data.line), vim.log.levels.INFO)
    end
  end
end

--- Remove a frame from a session
---@param session table
---@param frame_idx number
---@param saved_sessions table[]
---@param config table
function M.delete_frame_from_session(session, frame_idx, saved_sessions, config)
  if not session or not session.frames or not session.frames[frame_idx] then
    return
  end

  local previous_active_frame = (session.active_index and session.active_index > 0)
    and session.frames[session.active_index]
    or nil
  local target_frame = session.frames[frame_idx]
  local removed_raw_idx = target_frame.raw_index

  if removed_raw_idx then
    local ok = sessions.remove_frame(session, removed_raw_idx, saved_sessions)
    if not ok then
      vim.notify("Unwind: Failed to persist frame deletion.", vim.log.levels.ERROR)
      return
    end
  end

  M.rebuild_derived(session, config)

  if #session.frames == 0 then
    session.active_index = 0
    session.active_file_index = 0
    decorator.clear()
    sidebar.render(session)
  else
    local new_index = nil
    if previous_active_frame and previous_active_frame ~= target_frame then
      for idx, f in ipairs(session.frames) do
        if f == previous_active_frame then
          new_index = idx
          break
        end
      end
    end

    if not new_index then
      new_index = math.max(1, math.min(frame_idx, #session.frames))
    end

    sidebar.render(session)
    navigation.jump_to_frame(session, new_index)
  end
end

--- Re-check availability of all unique files in active session, rerunning source resolution
---@param session table
---@param config table
function M.refresh_availability(session, config)
  if not session then return end
  local root = session.root or vim.fs.normalize(vim.fn.getcwd())

  local ok_ruby, ruby_resolver = pcall(require, "unwind.resolvers.ruby")
  if ok_ruby and ruby_resolver and ruby_resolver.invalidate then
    ruby_resolver.invalidate(root)
  end

  local stat_cache = {}
  local path_cache = {}
  local compiled_mappings = config.path_mappings and parser.compile_path_mappings(config.path_mappings) or nil
  local norm_opts = {
    root = root,
    compiled_mappings = compiled_mappings,
    cache = path_cache,
    stat_cache = stat_cache,
  }

  for _, f in ipairs(session.raw_frames or {}) do
    local orig_path = f.path or f.file
    local display, resolved, navigable, metadata = parser.resolve_and_normalize_path(orig_path, norm_opts)
    f.file = display
    f.resolved_path = resolved
    f.navigable = navigable
    if metadata then
      f.external = metadata.external
      f.source_kind = metadata.source_kind
      f.resolution = metadata.resolution
    end
  end

  M.rebuild_derived(session, config)
  sidebar.render(session)
  vim.notify("Unwind: Refreshed file availability.", vim.log.levels.INFO)
end

return M
