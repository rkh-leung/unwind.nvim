-- lua/unwind/sessions.lua
-- Persistent Session Store, Session Lifecycle Management & Mutation API

local events = require("unwind.events")

local M = {}

--- Counter for unique in-memory session IDs
local session_id_seq = 0

local function next_session_id()
  session_id_seq = session_id_seq + 1
  return string.format("sess_%d_%d", os.time(), session_id_seq)
end

--- Compute canonical storage path for project root
--- Directory: stdpath("state")/unwind/
--- Filename: <sha256(normalized-project-root)>.json
---@param root string
---@return string filepath
---@return string dirpath
function M.storage_path(root)
  local norm_root = vim.fs.normalize(root)
  local hash = vim.fn.sha256(norm_root)
  local state_dir = vim.fs.normalize(vim.fn.stdpath("state")) .. "/unwind"
  return state_dir .. "/" .. hash .. ".json", state_dir
end

--- Serializes a session for disk persistence
--- Persists ONLY stable debugging facts:
---   id, name, filter_enabled, created_at, updated_at,
---   frames (path, file, line, col, method, origin, raw_line)
--- Does NOT persist:
---   resolved_path, navigable, file existence/availability,
---   file_index, primary_frame_index, active_index, active_file_index,
---   sidebar window/buf IDs, extmarks
---@param session table
---@return table
function M.serialize_session(session)
  local frames = {}
  for _, f in ipairs(session.raw_frames or {}) do
    table.insert(frames, {
      path = f.path or f.resolved_path or f.file,
      file = f.file,
      line = f.line,
      col = f.col or f.column or 1,
      method = f.method or "",
      origin = f.origin or "stacktrace",
      raw_line = f.raw_line or "",
    })
  end

  return {
    id = session.id,
    name = session.name or "Untitled",
    filter_enabled = session.filter_enabled or false,
    created_at = session.created_at or os.time(),
    updated_at = session.updated_at or os.time(),
    frames = frames,
  }
end

--- Load persisted sessions from disk for a given project root
--- Lazy-loaded on demand. Handles corrupt files gracefully with a single notification.
---@param root string
---@return table[] sessions List of session tables
function M.load(root)
  local norm_root = vim.fs.normalize(root)
  local filepath = M.storage_path(norm_root)

  local stat = (vim.uv or vim.loop).fs_stat(filepath)
  if not stat or stat.type ~= "file" then
    return {}
  end

  local f = io.open(filepath, "r")
  if not f then
    return {}
  end

  local content = f:read("*all")
  f:close()

  if not content or vim.trim(content) == "" then
    return {}
  end

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    vim.notify("Unwind: Could not parse persisted sessions file (corrupt JSON): " .. filepath, vim.log.levels.WARN)
    return {}
  end

  if data.root and data.root ~= norm_root then
    -- Mismatched root sanity check
    return {}
  end

  local sessions = {}
  local raw_list = data.sessions or {}
  for _, s_data in ipairs(raw_list) do
    if type(s_data) == "table" and s_data.name then
      local frames = {}
      for _, f in ipairs(s_data.frames or {}) do
        table.insert(frames, {
          path = f.path or f.file,
          file = f.file or f.path,
          line = f.line,
          col = f.col or f.column or 1,
          column = f.col or f.column or 1,
          method = f.method or "",
          origin = f.origin or "stacktrace",
          raw_line = f.raw_line or "",
        })
      end

      table.insert(sessions, {
        id = s_data.id or next_session_id(),
        name = s_data.name,
        transient = false,
        saved = true,
        root = norm_root,
        created_at = s_data.created_at or os.time(),
        updated_at = s_data.updated_at or os.time(),
        raw_frames = frames,
        frames = {},
        files = {},
        active_index = 0,
        active_file_index = 0,
        filter_enabled = s_data.filter_enabled or false,
      })
    end
  end

  return sessions
end

--- Atomically write saved sessions to disk for a project root
--- Writes to <filepath>.tmp first, then renames to <filepath>
---@param root string
---@param sessions table[]
---@return boolean success
function M.save(root, sessions)
  local norm_root = vim.fs.normalize(root)
  local filepath, state_dir = M.storage_path(norm_root)

  -- Ensure directory exists
  vim.fn.mkdir(state_dir, "p")

  local serialized_sessions = {}
  for _, s in ipairs(sessions or {}) do
    if s.saved and s.name then
      table.insert(serialized_sessions, M.serialize_session(s))
    end
  end

  local payload = {
    schema_version = 1,
    root = norm_root,
    sessions = serialized_sessions,
  }

  local ok_json, json_text = pcall(vim.json.encode, payload)
  if not ok_json or not json_text then
    vim.notify("Unwind: Failed to encode sessions JSON: " .. tostring(json_text), vim.log.levels.ERROR)
    return false
  end

  local tmp_path = filepath .. ".tmp." .. tostring((vim.uv or vim.loop).hrtime())
  local f = io.open(tmp_path, "w")
  if not f then
    vim.notify("Unwind: Could not open temporary state file for write: " .. tmp_path, vim.log.levels.ERROR)
    return false
  end

  local ok_write, write_err = f:write(json_text)
  local ok_flush, flush_err = f:flush()
  f:close()

  if not ok_write or not ok_flush then
    pcall(os.remove, tmp_path)
    local err_msg = tostring(write_err or flush_err or "write error")
    vim.notify("Unwind: Failed to write session state: " .. err_msg, vim.log.levels.ERROR)
    return false
  end

  local ok_rename, err = os.rename(tmp_path, filepath)
  if not ok_rename then
    pcall(os.remove, tmp_path)
    vim.notify("Unwind: Failed to atomically save session state: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  return true
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

--- Centralized mutation executor with transactional persistence and events
---@param session table
---@param fn fun(session: table)
---@param session_list? table[] Saved sessions list for disk persistence
---@return boolean ok
---@return any err
local function mutate(session, fn, session_list)
  local old_updated_at = session.updated_at
  local old_raw_frames = vim.deepcopy(session.raw_frames)
  local old_active_index = session.active_index

  fn(session)
  session.updated_at = os.time()

  if session.name and session.saved and session_list then
    local ok = M.save(session.root, session_list)
    if not ok then
      -- Rollback
      session.raw_frames = old_raw_frames
      session.updated_at = old_updated_at
      session.active_index = old_active_index
      return false, "Failed to persist mutation to disk"
    end
  end

  events.emit("session_changed", session)
  return true, nil
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
    if index and index >= 1 and index <= #s.raw_frames + 1 then
      table.insert(s.raw_frames, index, normalized)
    else
      table.insert(s.raw_frames, normalized)
    end
    if not s.active_index or s.active_index <= 0 then
      s.active_index = 1
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
  return mutate(session, function(s)
    for _, f in ipairs(frames) do
      table.insert(s.raw_frames, normalize_frame(f))
    end
    if (#s.raw_frames > 0) and (not s.active_index or s.active_index <= 0) then
      s.active_index = 1
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
    table.remove(s.raw_frames, index)
    if #s.raw_frames == 0 then
      s.active_index = 0
    elseif s.active_index and s.active_index > #s.raw_frames then
      s.active_index = #s.raw_frames
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
    s.raw_frames[index] = normalized
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
  session.saved = false
  session.transient = true

  local ok = M.save(root, sessions)
  if not ok then
    -- Rollback
    table.insert(sessions, target_idx, session)
    session.saved = old_saved
    session.transient = old_transient
    return false
  end

  events.emit("session_deleted", session)
  return true
end

return M
