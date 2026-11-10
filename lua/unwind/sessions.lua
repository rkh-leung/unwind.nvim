-- lua/unwind/sessions.lua
-- Persistent Session Store and Session Lifecycle Management

local M = {}

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
---   name, filter_enabled, frames (file, line, col, method, raw_line)
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
      file = f.file,
      line = f.line,
      col = f.col or 1,
      method = f.method or "",
      raw_line = f.raw_line or "",
    })
  end

  return {
    name = session.name or "Untitled Session",
    filter_enabled = session.filter_enabled or false,
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
          file = f.file,
          line = f.line,
          col = f.col or 1,
          method = f.method or "",
          raw_line = f.raw_line or "",
        })
      end

      table.insert(sessions, {
        name = s_data.name,
        saved = true,
        root = norm_root,
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
    if s.saved then
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

  f:write(json_text)
  f:flush()
  f:close()

  local ok_rename, err = os.rename(tmp_path, filepath)
  if not ok_rename then
    pcall(os.remove, tmp_path)
    vim.notify("Unwind: Failed to atomically save session state: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  return true
end

--- Create a new transient working session
---@param root string
---@param raw_frames table[]
---@param filter_enabled? boolean
---@return table session
function M.new_working(root, raw_frames, filter_enabled)
  return {
    name = nil,
    saved = false,
    root = vim.fs.normalize(root),
    raw_frames = raw_frames or {},
    frames = {},
    files = {},
    active_index = 0,
    active_file_index = 0,
    filter_enabled = filter_enabled or false,
  }
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

  session.name = trimmed
  session.saved = true
  session.root = vim.fs.normalize(root)
  table.insert(sessions, session)

  local ok = M.save(root, sessions)
  if not ok then
    return false, "Failed to write session to disk."
  end

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

  session.name = trimmed
  local ok = M.save(root, sessions)
  if not ok then
    return false, "Failed to persist session rename."
  end

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
    if s == session then
      target_idx = idx
      break
    end
  end

  if target_idx then
    table.remove(sessions, target_idx)
  end

  session.saved = false
  return M.save(root, sessions)
end

return M
