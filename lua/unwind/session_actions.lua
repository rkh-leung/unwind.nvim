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

--- Ensure all frames in session have their paths normalized and resolved against root
---@param session table
---@param config table
---@param root string
function M.ensure_frames_resolved(session, config, root)
  if not session or not session.raw_frames then
    return
  end

  local needs_resolution = false
  for _, f in ipairs(session.raw_frames) do
    if not f.resolved_path then
      needs_resolution = true
      break
    end
  end

  if not needs_resolution then
    return
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

  for _, f in ipairs(session.raw_frames) do
    if not f.resolved_path then
      local orig_path = f.path or f.file
      local display, resolved, navigable, metadata = parser.resolve_and_normalize_path(orig_path, norm_opts)
      f.file = display
      f.resolved_path = resolved
      f.navigable = navigable
      if metadata then
        f.external = metadata.external
        f.source_kind = metadata.source_kind
        f.resolution = metadata.resolution
      else
        f.external = nil
        f.source_kind = nil
        f.resolution = nil
      end
    end
  end
end

--- Rebuild runtime derived frames, files, and availability for a session
---@param session table
---@param config table
---@param root? string
function M.rebuild_derived(session, config, root)
  if not session or not session.raw_frames then
    return
  end

  root = root or session.root or vim.fs.normalize(vim.fn.getcwd())
  M.ensure_frames_resolved(session, config, root)

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

local function same_session(a, b)
  if a == b then
    return true
  end

  local a_id = a.id
  local b_id = b.id

  if a_id ~= nil and a_id ~= "" and b_id ~= nil and b_id ~= "" then
    return a_id == b_id
  end

  -- Legacy compatibility only when IDs are unavailable
  if (a_id == nil or a_id == "") and (b_id == nil or b_id == "") then
    return a.name ~= nil and a.name ~= "" and a.name == b.name
  end

  return false
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

  local old_filter = session.filter_enabled
  session.filter_enabled = not session.filter_enabled

  if session.saved and saved_sessions then
    -- Ensure session in saved_sessions list has updated filter_enabled if session table was a loaded copy
    for _, s in ipairs(saved_sessions) do
      if same_session(s, session) then
        s.filter_enabled = session.filter_enabled
      end
    end
    local ok = sessions.save(session.root, saved_sessions)
    if not ok then
      session.filter_enabled = old_filter
      for _, s in ipairs(saved_sessions) do
        if same_session(s, session) then
          s.filter_enabled = old_filter
        end
      end
      vim.notify("Unwind: Failed to persist filter toggle to disk.", vim.log.levels.ERROR)
      return
    end
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

--- Synchronize active presentation (sidebar selection, footer, and virtual-line extmarks)
--- without changing the focused source window.
--- If the active frame's file is loaded in a buffer, refreshes virtual lines to match current depth/total.
--- If missing or invalid, clears virtual lines without creating dummy buffers.
---@param session table
function M.refresh_active_presentation(session)
  if not session or not session.frames or #session.frames == 0 then
    decorator.clear()
    sidebar.render(session)
    return
  end

  local idx = session.active_index
  if not idx or idx < 1 or idx > #session.frames then
    idx = math.max(1, math.min(idx or 1, #session.frames))
    session.active_index = idx
  end

  sidebar.render(session)
  sidebar.set_active(session, idx)

  local frame = session.frames[idx]
  if not frame then
    decorator.clear()
    return
  end

  -- Sync active_file_index
  if frame.file_index and session.files and session.files[frame.file_index] then
    session.active_file_index = frame.file_index
  end

  local file_entry = (frame.file_index and session.files) and session.files[frame.file_index] or nil
  local is_avail = (file_entry and file_entry.available ~= false) and (frame.navigable ~= false)
  if not is_avail then
    decorator.clear()
    return
  end

  local root = session.root or vim.fs.normalize(vim.fn.getcwd())
  local target_path = (file_entry and file_entry.canonical_resolved) or frame.resolved_path or frame.file
  if not require("unwind.path").is_absolute(target_path) then
    target_path = root .. "/" .. target_path
  end
  target_path = vim.fs.normalize(target_path)

  local bufnr = vim.fn.bufnr(target_path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    decorator.render(bufnr, frame.line or 1, idx, frame.method, frame.file, #session.frames, {
      origin = frame.origin,
      note = frame.note,
    })
  else
    decorator.clear()
  end
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

  local active_frame = (session.active_index and session.active_index > 0) and session.frames[session.active_index] or nil

  local target_frame = session.frames[from_idx]
  local raw_from_idx = target_frame.raw_index

  local dest_frame = session.frames[to_idx]
  local raw_to_idx = dest_frame.raw_index

  if raw_from_idx and raw_to_idx then
    local ok = sessions.move_frame(session, raw_from_idx, raw_to_idx, saved_sessions)
    if ok then
      M.rebuild_derived(session, config)
      -- If the moved frame was active, it moved to to_idx.
      -- If another frame was moved, find where active_frame landed in session.frames
      if active_frame == target_frame then
        session.active_index = to_idx
      elseif active_frame then
        for i, f in ipairs(session.frames) do
          if f == active_frame or f.raw_index == active_frame.raw_index then
            session.active_index = i
            break
          end
        end
      end
      M.refresh_active_presentation(session)
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

  if target_frame and target_frame.note ~= nil and frame_data.note == nil then
    frame_data.note = target_frame.note
  end

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

--- Annotate a frame in session
---@param session table
---@param frame_idx_or_target number|table Frame index in session.frames or the frame object itself
---@param note_text? string
---@param saved_sessions table[]
---@param config table
---@return boolean ok
function M.annotate_frame_in_session(session, frame_idx_or_target, note_text, saved_sessions, config)
  if not session then
    return false
  end

  local target_frame = nil
  local frame_idx = nil

  if type(frame_idx_or_target) == "table" then
    target_frame = frame_idx_or_target
    for idx, f in ipairs(session.frames or {}) do
      if f == target_frame or f.raw_index == target_frame.raw_index then
        frame_idx = idx
        break
      end
    end
  elseif type(frame_idx_or_target) == "number" then
    frame_idx = frame_idx_or_target
    target_frame = session.frames and session.frames[frame_idx]
  end

  if not target_frame then
    return false
  end

  -- Locate raw_idx stably by exact object identity
  local raw_idx = nil
  for idx, rf in ipairs(session.raw_frames or {}) do
    if rf == target_frame then
      raw_idx = idx
      break
    end
  end

  -- If target was passed as a numeric index, allow using target_frame.raw_index if still pointing to target_frame
  if not raw_idx and type(frame_idx_or_target) == "number" and target_frame.raw_index then
    if session.raw_frames and session.raw_frames[target_frame.raw_index] == target_frame then
      raw_idx = target_frame.raw_index
    end
  end

  if not raw_idx or not session.raw_frames or not session.raw_frames[raw_idx] then
    return false
  end

  local existing_raw = session.raw_frames[raw_idx]
  local clean_note = nil
  if note_text ~= nil then
    local trimmed = vim.trim(tostring(note_text))
    if trimmed ~= "" then
      clean_note = trimmed
    end
  end

  local updated_frame = {
    path = existing_raw.path,
    file = existing_raw.file,
    line = existing_raw.line,
    col = existing_raw.col,
    column = existing_raw.column,
    method = existing_raw.method,
    origin = existing_raw.origin,
    raw_line = existing_raw.raw_line,
    resolved_path = existing_raw.resolved_path,
    navigable = existing_raw.navigable,
    external = existing_raw.external,
    source_kind = existing_raw.source_kind,
    resolution = existing_raw.resolution,
    note = clean_note,
  }

  local ok, err = sessions.update_frame(session, raw_idx, updated_frame, saved_sessions)
  if not ok then
    vim.notify("Unwind: Failed to persist annotation: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  M.rebuild_derived(session, config)
  sidebar.render(session)

  -- Find where the frame is in derived frames now
  local updated_visible_idx = nil
  for idx, f in ipairs(session.frames or {}) do
    if f.raw_index == raw_idx then
      updated_visible_idx = idx
      break
    end
  end

  if updated_visible_idx and session.active_index == updated_visible_idx then
    navigation.jump_to_frame(session, updated_visible_idx)
  end

  return true
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
    else
      f.external = nil
      f.source_kind = nil
      f.resolution = nil
    end
  end

  M.rebuild_derived(session, config)
  M.refresh_active_presentation(session)
  vim.notify("Unwind: Refreshed file availability.", vim.log.levels.INFO)
end

return M
