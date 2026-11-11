-- lua/unwind/collector.lua
-- File deduplication and frame grouping logic
-- Group parsed frames by unique file path, maintaining original occurrence order.

local path_util = require("unwind.path")

local M = {}

--- Default ignore patterns
local default_ignore_patterns = {
  "shared/bundle/",
  "vendor/bundle/",
  "/gems/",
  "node_modules/",
  "^/usr/",
}

--- Checks if a file path matches any pattern in the ignore list or is external to workspace.
--- Uses direct string.find for performance.
---@param fpath string
---@param ignore_patterns? string[]
---@param root? string Root directory (defaults to vim.fn.getcwd())
---@return boolean is_ignored
function M.is_vendor_or_ignored(fpath, ignore_patterns, root)
  if not fpath then
    return false
  end

  local patterns = ignore_patterns or default_ignore_patterns

  for _, pattern in ipairs(patterns) do
    -- Patterns are pre-validated during setup or default
    local ok, matched = pcall(string.find, fpath, pattern)
    if ok and matched then
      return true
    end
  end

  -- Resolve absolute path against workspace root
  local workspace_root = vim.fs.normalize(root or vim.fn.getcwd())
  local is_windows = path_util.is_windows_path(fpath) or path_util.is_windows_path(workspace_root)

  -- Canonicalize lexical path (resolving .. and .)
  local norm = path_util.canonicalize(fpath)
  if not path_util.is_absolute(norm) then
    norm = path_util.canonicalize(workspace_root .. "/" .. norm)
  end

  local check_root = is_windows and workspace_root:lower() or workspace_root
  local check_norm = is_windows and norm:lower() or norm

  local is_in_workspace = (check_norm == check_root) or vim.startswith(check_norm, check_root .. "/")
  if not is_in_workspace then
    return true
  end

  return false
end

--- Collects and deduplicates parsed frames by unique file path (using resolved_path or file).
--- Retains original occurrence order (first file implicated in trace at index 1).
--- Tracks total frame count and primary line for each unique file.
--- Assigns frame.raw_index for fast O(1) mutations.
--- Avoids allocating duplicate frame arrays when filtering is disabled.
---@param frames table[] List of frame objects
---@param opts? { root?: string, filter_vendor?: boolean, ignore_patterns?: string[] }
---@return { files: table[], frames: table[] }
function M.collect(frames, opts)
  opts = opts or {}
  local filter_vendor = opts.filter_vendor or false
  local ignore_patterns = opts.ignore_patterns or default_ignore_patterns
  local root = opts.root

  -- Assign raw_index to raw frames for O(1) identity mapping
  for raw_idx, frame in ipairs(frames) do
    frame.raw_index = raw_idx
  end

  local vendor_cache = {}
  local function is_vendor(fpath)
    if not fpath then
      return false
    end
    local cached = vendor_cache[fpath]
    if cached ~= nil then
      return cached
    end
    local val = M.is_vendor_or_ignored(fpath, ignore_patterns, root)
    vendor_cache[fpath] = val
    return val
  end

  local active_frames = frames
  if filter_vendor then
    active_frames = {}
    for _, frame in ipairs(frames) do
      local fpath = frame.resolved_path or frame.file
      local should_ignore = false

      if frame.external == true or is_vendor(fpath) or is_vendor(frame.file) or is_vendor(frame.path) then
        should_ignore = true
      end

      if not should_ignore then
        table.insert(active_frames, frame)
      end
    end
  end

  local files = {}
  local file_map = {}

  for frame_idx, frame in ipairs(active_frames) do
    local raw_key = frame.resolved_path or frame.file
    local canonical_key = path_util.comparison_key(raw_key)

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
        is_vendor = (frame.external == true) or is_vendor(frame.resolved_path or frame.file) or is_vendor(frame.file) or is_vendor(frame.path),
        external = frame.external,
        source_kind = frame.source_kind,
        resolution = frame.resolution,
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
