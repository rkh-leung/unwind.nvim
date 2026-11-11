-- lua/unwind/persistence.lua
-- Atomic state persistence and serialization for saved Unwind sessions
-- Disk format schema version 1.

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
    local serialized_f = {
      path = f.path or f.resolved_path or f.file,
      file = f.file,
      line = f.line,
      col = f.col or f.column or 1,
      method = f.method or "",
      origin = f.origin or "stacktrace",
      raw_line = f.raw_line or "",
    }
    if f.external ~= nil then
      serialized_f.external = f.external
    end
    if f.source_kind ~= nil then
      serialized_f.source_kind = f.source_kind
    end
    if f.resolution ~= nil then
      serialized_f.resolution = f.resolution
    end
    table.insert(frames, serialized_f)
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
    return {}
  end

  local sessions_list = {}
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
          external = f.external,
          source_kind = f.source_kind,
          resolution = f.resolution,
        })
      end

      table.insert(sessions_list, {
        id = s_data.id or ("sess_" .. os.time() .. "_" .. #sessions_list),
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

  return sessions_list
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

return M
