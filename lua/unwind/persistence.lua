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
    if f.note ~= nil and f.note ~= "" then
      serialized_f.note = f.note
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

--- Track paths with corrupt or unreadable persisted state to prevent accidental overwrite
M._corrupted_roots = {}

--- Check if a project root has a corrupted state file that shouldn't be overwritten blindly
---@param root string
---@return boolean
function M.is_corrupted(root)
  local norm_root = vim.fs.normalize(root)
  return M._corrupted_roots[norm_root] == true
end

--- Clear corrupted status for root (e.g. after deliberate recovery)
---@param root string
function M.clear_corrupted(root)
  local norm_root = vim.fs.normalize(root)
  M._corrupted_roots[norm_root] = nil
end

--- Validates a frame object decoded from persistence
---@param f any
---@return table? normalized_frame
local function validate_frame(f)
  if type(f) ~= "table" then
    return nil
  end

  local path = f.path or f.file
  if type(path) ~= "string" or vim.trim(path) == "" then
    return nil
  end

  local file = (type(f.file) == "string" and f.file ~= "") and f.file or path

  -- Validate line: must be valid positive integer if provided
  local line = 1
  if f.line ~= nil then
    local num = tonumber(f.line)
    if not num or num < 1 or math.floor(num) ~= num then
      return nil
    end
    line = math.floor(num)
  end

  -- Validate col / column: must be valid positive integer if provided
  local col = 1
  local raw_col = f.col or f.column
  if raw_col ~= nil then
    local num = tonumber(raw_col)
    if not num or num < 1 or math.floor(num) ~= num then
      return nil
    end
    col = math.floor(num)
  end

  local method = (type(f.method) == "string") and f.method or ""
  local origin = (f.origin == "manual" or f.origin == "stacktrace") and f.origin or "stacktrace"
  local raw_line = (type(f.raw_line) == "string") and f.raw_line or ""

  local note = nil
  if f.note ~= nil then
    local note_str = vim.trim(tostring(f.note))
    if note_str ~= "" then
      note = note_str
    end
  end

  return {
    path = path,
    file = file,
    line = math.floor(line),
    col = math.floor(col),
    column = math.floor(col),
    method = method,
    origin = origin,
    raw_line = raw_line,
    external = type(f.external) == "boolean" and f.external or nil,
    source_kind = type(f.source_kind) == "string" and f.source_kind or nil,
    resolution = type(f.resolution) == "string" and f.resolution or nil,
    note = note,
  }
end

--- Load persisted sessions from disk for a given project root
--- Lazy-loaded on demand. Handles corrupt files gracefully with structural validation.
--- Preserves original bytes and tags root as corrupted if invalid.
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
    -- Existing file could not be opened for reading: protect it from overwrite!
    M._corrupted_roots[norm_root] = true
    vim.notify("Unwind: Could not open existing session file for read: " .. filepath, vim.log.levels.WARN)
    return {}
  end

  local content = f:read("*all")
  f:close()

  if not content or vim.trim(content) == "" then
    -- Empty state file is invalid/corrupt
    M._corrupted_roots[norm_root] = true
    vim.notify("Unwind: Persisted sessions file is empty: " .. filepath, vim.log.levels.WARN)
    return {}
  end

  local is_list = vim.islist or vim.tbl_islist

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" or is_list(data) then
    M._corrupted_roots[norm_root] = true
    vim.notify("Unwind: Could not parse persisted sessions file (corrupt JSON): " .. filepath, vim.log.levels.WARN)
    return {}
  end

  -- Validate top-level schema v1 requirements:
  -- schema_version: required and must equal 1
  if data.schema_version ~= 1 then
    M._corrupted_roots[norm_root] = true
    vim.notify(string.format("Unwind: Missing or unsupported schema_version (%s) in %s", tostring(data.schema_version), filepath), vim.log.levels.WARN)
    return {}
  end

  -- root: required, must be nonempty string matching normalized root
  if type(data.root) ~= "string" or vim.trim(data.root) == "" or vim.fs.normalize(data.root) ~= norm_root then
    M._corrupted_roots[norm_root] = true
    vim.notify(string.format("Unwind: Missing or mismatched root (%s) in %s", tostring(data.root), filepath), vim.log.levels.WARN)
    return {}
  end

  -- sessions: required and must be an array (list)
  if type(data.sessions) ~= "table" or not is_list(data.sessions) then
    M._corrupted_roots[norm_root] = true
    vim.notify("Unwind: Missing or corrupt sessions field (expected array) in " .. filepath, vim.log.levels.WARN)
    return {}
  end

  local sessions_list = {}
  local raw_list = data.sessions

  for s_idx, s_data in ipairs(raw_list) do
    if type(s_data) ~= "table" or type(s_data.name) ~= "string" or vim.trim(s_data.name) == "" then
      M._corrupted_roots[norm_root] = true
      vim.notify("Unwind: Malformed session entry in " .. filepath, vim.log.levels.WARN)
      return {}
    end

    local raw_frames = s_data.frames
    if raw_frames ~= nil and (type(raw_frames) ~= "table" or not is_list(raw_frames)) then
      M._corrupted_roots[norm_root] = true
      vim.notify("Unwind: Malformed frames array in session " .. tostring(s_data.name), vim.log.levels.WARN)
      return {}
    end

    local frames = {}
    for _, f in ipairs(raw_frames or {}) do
      local valid_f = validate_frame(f)
      if not valid_f then
        -- Any invalid frame means corrupt data; fail closed to avoid data loss!
        M._corrupted_roots[norm_root] = true
        vim.notify("Unwind: Malformed frame in session " .. tostring(s_data.name), vim.log.levels.WARN)
        return {}
      end
      table.insert(frames, valid_f)
    end

    local ok_enc, encoded = pcall(vim.json.encode, s_data)
    local persisted_size = (ok_enc and encoded) and #encoded or nil

    table.insert(sessions_list, {
      id = (type(s_data.id) == "string" and s_data.id ~= "") and s_data.id or ("sess_" .. os.time() .. "_" .. #sessions_list),
      name = vim.trim(s_data.name),
      transient = false,
      saved = true,
      root = norm_root,
      created_at = tonumber(s_data.created_at) or os.time(),
      updated_at = tonumber(s_data.updated_at) or os.time(),
      raw_frames = frames,
      frames = {},
      files = {},
      active_index = 0,
      active_file_index = 0,
      filter_enabled = s_data.filter_enabled == true,
      _persisted_size = persisted_size,
    })
  end

  -- Successfully decoded and validated
  M._corrupted_roots[norm_root] = nil
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

  -- Safety policy: Refuse to overwrite if the existing file on disk failed validation
  -- unless explicitly cleared or no corrupted state is flagged.
  if M.is_corrupted(norm_root) then
    vim.notify("Unwind: Refusing to overwrite existing corrupt session file: " .. filepath, vim.log.levels.ERROR)
    return false
  end

  -- Ensure directory exists
  vim.fn.mkdir(state_dir, "p")

  local serialized_sessions = {}
  for _, s in ipairs(sessions or {}) do
    if s.saved and s.name then
      local serialized = M.serialize_session(s)
      local ok_enc, encoded = pcall(vim.json.encode, serialized)
      if ok_enc and encoded then
        s._persisted_size = #encoded
      end
      table.insert(serialized_sessions, serialized)
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
