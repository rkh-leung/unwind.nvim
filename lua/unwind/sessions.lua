-- lua/unwind/sessions.lua
-- Persistent Session Store, Session Lifecycle Management & Mutation API

local events = require("unwind.events")
local persistence = require("unwind.persistence")

local M = {}

--- Counter for unique in-memory session IDs
local session_id_seq = 0

local function next_session_id()
  session_id_seq = session_id_seq + 1
  return string.format("sess_%d_%d", os.time(), session_id_seq)
end

--- Delegates storage path computation to persistence module (backwards-compatible)
function M.storage_path(root)
  return persistence.storage_path(root)
end

--- Delegates session serialization to persistence module (backwards-compatible)
function M.serialize_session(session)
  return persistence.serialize_session(session)
end

--- Delegates session loading to persistence module (backwards-compatible)
function M.load(root)
  return persistence.load(root)
end

--- Delegates atomic save to persistence module (backwards-compatible)
function M.save(root, sessions_list)
  return persistence.save(root, sessions_list)
end

--- Standardize a frame table into canonical UnwindFrame format
---@param frame table
---@return table
local function normalize_frame(frame)
  local path = frame.path or frame.resolved_path or frame.file or ""
  local file = frame.file or frame.path or ""
  local line = frame.line or 1
  local col = frame.col or frame.column or 1
  local method = frame.method or ""
  local origin = frame.origin or "stacktrace"
  local raw_line = frame.raw_line or ""
  local external = frame.external
  local source_kind = frame.source_kind
  local resolution = frame.resolution
  local note = frame.note
  if note ~= nil then
    note = vim.trim(tostring(note))
    if note == "" then
      note = nil
    end
  end

  return {
    path = path,
    file = file,
    line = line,
    col = col,
    column = col,
    method = method,
    origin = origin,
    raw_line = raw_line,
    resolved_path = frame.resolved_path,
    navigable = frame.navigable,
    external = external,
    source_kind = source_kind,
    resolution = resolution,
    note = note,
  }
end

--- Create a new session
--- Defaults to an unnamed transient session with empty frames
---@param opts? { id?: string, name?: string, transient?: boolean, root?: string, frames?: table[], filter_enabled?: boolean }
---@return table session
function M.create(opts)
  opts = opts or {}
  local root = opts.root or vim.fs.normalize(vim.fn.getcwd())
  local name = opts.name
  local transient = opts.transient
  if transient == nil then
    transient = (name == nil)
  end

  local raw_frames = {}
  if opts.frames then
    for _, f in ipairs(opts.frames) do
      table.insert(raw_frames, normalize_frame(f))
    end
  end

  local session = {
    id = opts.id or next_session_id(),
    name = name,
    transient = transient,
    saved = not transient and name ~= nil,
    root = vim.fs.normalize(root),
    created_at = os.time(),
    updated_at = os.time(),
    raw_frames = raw_frames,
    frames = {},
    files = {},
    active_index = #raw_frames > 0 and 1 or 0,
    active_file_index = 0,
    filter_enabled = opts.filter_enabled or false,
  }

  events.emit("session_created", session)
  return session
end

--- Backwards-compatible new_working
---@param root string
---@param raw_frames table[]
---@param filter_enabled? boolean
---@return table session
function M.new_working(root, raw_frames, filter_enabled)
  return M.create({
    root = root,
    frames = raw_frames,
    filter_enabled = filter_enabled,
    transient = true,
  })
end

--- Centralized mutation executor with fine-grained transactional persistence and events.
--- Uses operation-specific rollback rather than deepcopying entire session frame arrays (O(1) memory).
---@param session table
---@param apply fun(session: table): fun()? Apply returns an optional undo function
---@param session_list? table[] Saved sessions list for disk persistence
---@return boolean ok
---@return any err
local function mutate(session, apply, session_list)
  local old_updated_at = session.updated_at
  local old_active_index = session.active_index

  local undo = apply(session)
  session.updated_at = os.time()
  session._approx_size = nil
  session._project_frames = nil

  if session.name and session.saved and session_list then
    local ok = persistence.save(session.root, session_list)
    if not ok then
      if undo then
        undo()
      end
      session.updated_at = old_updated_at
      session.active_index = old_active_index
      return false, "Failed to persist mutation to disk"
    end
  end

  events.emit("session_changed", session)
  return true, nil
end

--- Get the session size in bytes and whether it is an exact persisted size
---@param session table
---@return number bytes
---@return boolean is_exact
function M.get_size(session)
  if not session then
    return 0, false
  end
  if session.saved and session._persisted_size then
    return session._persisted_size, true
  end
  if session.saved then
    local serialized = persistence.serialize_session(session)
    local ok_enc, encoded = pcall(vim.json.encode, serialized)
    if ok_enc and encoded then
      session._persisted_size = #encoded
      return session._persisted_size, true
    end
  end
  if session._approx_size then
    return session._approx_size, false
  end
  local serialized = persistence.serialize_session(session)
  local ok_enc, encoded = pcall(vim.json.encode, serialized)
  if ok_enc and encoded then
    session._approx_size = #encoded
    return session._approx_size, false
  end
  return 0, false
end

--- Get the number of project/codebase frames in session
---@param session table
---@param root? string
---@param ignore_patterns? string[]
---@return number count
function M.get_project_frame_count(session, root, ignore_patterns)
  if not session or not session.raw_frames then
    return 0
  end
  if session._project_frames ~= nil then
    return session._project_frames
  end
  local collector = require("unwind.collector")
  root = root or session.root or vim.fs.normalize(vim.fn.getcwd())
  local count = 0
  for _, f in ipairs(session.raw_frames) do
    if f.external == false then
      count = count + 1
    elseif f.external == true then
      -- not project
    else
      local loc = f.resolved_path or f.file or f.path
      if not collector.is_vendor_or_ignored(loc, ignore_patterns, root) then
        count = count + 1
      end
    end
  end
  session._project_frames = count
  return count
end

--- Add a single frame to a session
---@param session table
---@param frame table
---@param index? integer Optional insertion index (defaults to append)
---@param session_list? table[]
---@return boolean ok
function M.add_frame(session, frame, index, session_list)
  if not session then return false end
  local normalized = normalize_frame(frame)
  return mutate(session, function(s)
    local insert_at = (index and index >= 1 and index <= #s.raw_frames + 1) and index or (#s.raw_frames + 1)
    table.insert(s.raw_frames, insert_at, normalized)
    if not s.active_index or s.active_index <= 0 then
      s.active_index = 1
    end
    return function()
      table.remove(s.raw_frames, insert_at)
    end
  end, session_list)
end

--- Add multiple frames to a session
---@param session table
---@param frames table[]
---@param session_list? table[]
---@return boolean ok
function M.add_frames(session, frames, session_list)
  if not session or not frames then return false end
  local normalized_list = {}
  for _, f in ipairs(frames) do
    table.insert(normalized_list, normalize_frame(f))
  end
  return mutate(session, function(s)
    local start_len = #s.raw_frames
    for _, f in ipairs(normalized_list) do
      table.insert(s.raw_frames, f)
    end
    if (#s.raw_frames > 0) and (not s.active_index or s.active_index <= 0) then
      s.active_index = 1
    end
    return function()
      for _ = 1, #normalized_list do
        table.remove(s.raw_frames)
      end
    end
  end, session_list)
end

--- Remove a frame from a session by index
---@param session table
---@param index integer
---@param session_list? table[]
---@return boolean ok
function M.remove_frame(session, index, session_list)
  if not session or not session.raw_frames or not session.raw_frames[index] then
    return false
  end
  return mutate(session, function(s)
    local removed = table.remove(s.raw_frames, index)
    if #s.raw_frames == 0 then
      s.active_index = 0
    elseif s.active_index and s.active_index > #s.raw_frames then
      s.active_index = #s.raw_frames
    end
    return function()
      table.insert(s.raw_frames, index, removed)
    end
  end, session_list)
end

--- Update/replace a frame at index
---@param session table
---@param index integer
---@param new_frame table
---@param session_list? table[]
---@return boolean ok
function M.update_frame(session, index, new_frame, session_list)
  if not session or not session.raw_frames or not session.raw_frames[index] then
    return false
  end
  local normalized = normalize_frame(new_frame)
  return mutate(session, function(s)
    local previous = s.raw_frames[index]
    -- Update existing table in-place if previous is a table, preserving table reference identity
    if type(previous) == "table" and type(normalized) == "table" then
      local old_copy = {}
      for k, v in pairs(previous) do
        old_copy[k] = v
        previous[k] = nil
      end
      for k, v in pairs(normalized) do
        previous[k] = v
      end
      return function()
        for k in pairs(previous) do
          previous[k] = nil
        end
        for k, v in pairs(old_copy) do
          previous[k] = v
        end
      end
    else
      s.raw_frames[index] = normalized
      return function()
        s.raw_frames[index] = previous
      end
    end
  end, session_list)
end

--- Move a frame from one index to another (reordering)
---@param session table
---@param from_idx integer
---@param to_idx integer
---@param session_list? table[]
---@return boolean ok
function M.move_frame(session, from_idx, to_idx, session_list)
  if not session or not session.raw_frames then return false end
  local total = #session.raw_frames
  if from_idx < 1 or from_idx > total or to_idx < 1 or to_idx > total or from_idx == to_idx then
    return false
  end
  return mutate(session, function(s)
    local item = table.remove(s.raw_frames, from_idx)
    table.insert(s.raw_frames, to_idx, item)
    if s.active_index == from_idx then
      s.active_index = to_idx
    elseif from_idx < to_idx and s.active_index > from_idx and s.active_index <= to_idx then
      s.active_index = s.active_index - 1
    elseif from_idx > to_idx and s.active_index >= to_idx and s.active_index < from_idx then
      s.active_index = s.active_index + 1
    end
    return function()
      local moved = table.remove(s.raw_frames, to_idx)
      table.insert(s.raw_frames, from_idx, moved)
    end
  end, session_list)
end

--- Save and name a working session into persistent sessions list
---@param session table
---@param name string
---@param sessions table[]
---@param root string
---@return boolean success
---@return string? error_message
function M.save_working(session, name, sessions, root)
  local trimmed = vim.trim(name or "")
  if trimmed == "" then
    return false, "Session name cannot be empty."
  end

  for _, s in ipairs(sessions) do
    if s.saved and s.name == trimmed then
      return false, string.format("Session '%s' already exists.", trimmed)
    end
  end

  local old_name = session.name
  local old_saved = session.saved
  local old_transient = session.transient
  local old_root = session.root

  session.name = trimmed
  session.saved = true
  session.transient = false
  session.root = vim.fs.normalize(root)
  session.updated_at = os.time()
  table.insert(sessions, session)

  local ok = M.save(root, sessions)
  if not ok then
    -- Rollback
    for idx, s in ipairs(sessions) do
      if s == session then
        table.remove(sessions, idx)
        break
      end
    end
    session.name = old_name
    session.saved = old_saved
    session.transient = old_transient
    session.root = old_root
    return false, "Failed to write session to disk."
  end

  events.emit("session_changed", session)
  return true, nil
end

--- Rename a saved session
---@param session table
---@param new_name string
---@param sessions table[]
---@param root string
---@return boolean success
---@return string? error_message
function M.rename(session, new_name, sessions, root)
  local trimmed = vim.trim(new_name or "")
  if trimmed == "" then
    return false, "Session name cannot be empty."
  end

  for _, s in ipairs(sessions) do
    if s ~= session and s.saved and s.name == trimmed then
      return false, string.format("Session '%s' already exists.", trimmed)
    end
  end

  local old_name = session.name
  session.name = trimmed
  session.updated_at = os.time()
  local ok = M.save(root, sessions)
  if not ok then
    -- Rollback
    session.name = old_name
    return false, "Failed to persist session rename."
  end

  events.emit("session_changed", session)
  return true, nil
end

--- Delete a saved session from the persisted sessions list
---@param session table
---@param sessions table[]
---@param root string
---@return boolean success
function M.delete(session, sessions, root)
  local target_idx = nil
  for idx, s in ipairs(sessions) do
    if s == session or (session.id and s.id == session.id) then
      target_idx = idx
      break
    end
  end

  if not target_idx then
    return false
  end

  table.remove(sessions, target_idx)
  local old_saved = session.saved
  local old_transient = session.transient
  local old_persisted_size = session._persisted_size
  session.saved = false
  session.transient = true
  session._persisted_size = nil

  local ok = M.save(root, sessions)
  if not ok then
    -- Rollback
    table.insert(sessions, target_idx, session)
    session.saved = old_saved
    session.transient = old_transient
    session._persisted_size = old_persisted_size
    return false
  end

  events.emit("session_deleted", session)
  return true
end

return M
