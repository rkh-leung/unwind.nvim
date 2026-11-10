-- lua/unwind/collector.lua
-- File deduplication and frame grouping logic
-- Group parsed frames by unique file path, maintaining original occurrence order.

local M = {}

--- Checks if a file path matches any pattern in the ignore list or is external to workspace
---@param fpath string
---@param ignore_patterns? string[]
---@param root? string Root directory (defaults to vim.fn.getcwd())
---@return boolean is_ignored
function M.is_vendor_or_ignored(fpath, ignore_patterns, root)
  if not fpath then
    return false
  end

  local patterns = ignore_patterns or {
    "shared/bundle/",
    "vendor/bundle/",
    "/gems/",
    "node_modules/",
    "^/usr/",
  }

  for _, pattern in ipairs(patterns) do
    local ok, matched = pcall(string.find, fpath, pattern)
    if ok and matched then
      return true
    end
  end

  -- Resolve absolute path against workspace root
  local workspace_root = vim.fs.normalize(root or vim.fn.getcwd())
  local is_windows = vim.fn.has("win32") == 1 or fpath:match("^%a:[/\\]") or workspace_root:match("^%a:[/\\]")

  -- Canonicalize lexical path (resolving .. and .)
  local p = fpath:gsub("\\", "/")
  local is_abs_unix = p:sub(1, 1) == "/"
  local drive, rest = p:match("^([%a]:)/(.*)")
  if drive then
    p = "/" .. rest
  end

  local parts = {}
  if not is_abs_unix and not drive then
    -- Prepend workspace_root components
    local ws = workspace_root:gsub("\\", "/")
    local ws_drive, ws_rest = ws:match("^([%a]:)/(.*)")
    if ws_drive then
      drive = ws_drive
      ws = "/" .. ws_rest
    elseif ws:sub(1, 1) == "/" then
      is_abs_unix = true
    end
    for part in ws:gmatch("[^/]+") do
      table.insert(parts, part)
    end
  end

  for part in p:gmatch("[^/]+") do
    if part == "." then
      -- skip
    elseif part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        table.remove(parts)
      elseif not is_abs_unix and not drive then
        table.insert(parts, "..")
      end
    else
      table.insert(parts, part)
    end
  end

  local norm = table.concat(parts, "/")
  if drive then
    norm = drive .. "/" .. norm
  elseif is_abs_unix then
    norm = "/" .. norm
  end

  local check_root = is_windows and workspace_root:lower() or workspace_root
  local check_norm = is_windows and norm:lower() or norm

  -- Proper boundary check: must either be exact root or have root followed by path separator '/'
  local is_in_workspace = (check_norm == check_root) or vim.startswith(check_norm, check_root .. "/")
  if not is_in_workspace then
    return true
  end

  return false
end

--- Collects and deduplicates parsed frames by unique file path (using resolved_path or file).
--- Retains original occurrence order (first file implicated in trace at index 1).
--- Tracks total frame count and primary line (the highest/first fault line) for each unique file.
--- Stores cross-indexes (frame.file_index, file.primary_frame_index) for O(1) lookups.
--- Supports filtering out vendor / third-party / ignored library frames.
---@param frames table[] List of frame objects { file, resolved_path, navigable, line, col, method, raw_line }
---@param opts? { root?: string, filter_vendor?: boolean, ignore_patterns?: string[] }
---@return { files: table[], frames: table[] }
function M.collect(frames, opts)
  opts = opts or {}
  local filter_vendor = opts.filter_vendor or false
  local ignore_patterns = opts.ignore_patterns
  local root = opts.root

  local vendor_cache = {}
  local function is_vendor(fpath)
    local cached = vendor_cache[fpath]
    if cached ~= nil then
      return cached
    end
    local val = M.is_vendor_or_ignored(fpath, ignore_patterns, root)
    vendor_cache[fpath] = val
    return val
  end

  local filtered_frames = {}
  for _, frame in ipairs(frames) do
    local fpath = frame.resolved_path or frame.file
    local should_ignore = false

    if filter_vendor then
      if is_vendor(fpath) or is_vendor(frame.file) then
        should_ignore = true
      end
    end

    if not should_ignore then
      table.insert(filtered_frames, frame)
    end
  end

  -- If filter is enabled and all frames were filtered out, do not silently restore
  local active_frames = filter_vendor and filtered_frames or frames

  local files = {}
  local file_map = {} -- keyed by canonical comparison path -> index in files list

  for frame_idx, frame in ipairs(active_frames) do
    -- Canonical key for grouping: use resolved_path if available, fallback to file
    local canonical_key = frame.resolved_path or frame.file
    if vim.fn.has("win32") == 1 or canonical_key:match("^%a:[/\\]") then
      canonical_key = canonical_key:lower()
    end

    local existing_idx = file_map[canonical_key]

    if not existing_idx then
      local entry = {
        file = frame.file,
        resolved_path = frame.resolved_path or frame.file,
        navigable = frame.navigable ~= false,
        primary_line = frame.line,
        primary_col = frame.col or 1,
        primary_method = frame.method or "",
        primary_frame_index = frame_idx,
        total_frames = 1,
        frames = { frame },
        is_vendor = is_vendor(frame.resolved_path or frame.file) or is_vendor(frame.file),
      }
      table.insert(files, entry)
      local new_f_idx = #files
      file_map[canonical_key] = new_f_idx
      frame.file_index = new_f_idx
    else
      local entry = files[existing_idx]
      entry.total_frames = entry.total_frames + 1
      table.insert(entry.frames, frame)
      frame.file_index = existing_idx
    end
  end

  return {
    files = files,
    frames = active_frames,
  }
end

return M
