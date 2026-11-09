-- lua/unwind/collector.lua
-- File deduplication and frame grouping logic
-- Group parsed frames by unique file path, maintaining original occurrence order.

local M = {}

--- Checks if a file path matches any pattern in the ignore list or is external to workspace
---@param fpath string
---@param ignore_patterns? string[]
---@return boolean is_ignored
function M.is_vendor_or_ignored(fpath, ignore_patterns)
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
    if fpath:find(pattern) then
      return true
    end
  end

  -- Check if path is absolute and outside current working directory
  if fpath:sub(1, 1) == "/" or fpath:match("^%a:[/\\]") then
    local cwd = vim.fs.normalize(vim.fn.getcwd())
    local norm = vim.fs.normalize(fpath)
    if not vim.startswith(norm, cwd) then
      return true
    end
  end

  return false
end

--- Collects and deduplicates parsed frames by unique file path.
--- Retains original occurrence order (first file implicated in trace at index 1).
--- Tracks total frame count and primary line (the highest/first fault line) for each unique file.
--- Supports filtering out vendor / third-party / ignored library frames.
---@param frames table[] List of frame objects { file, line, col, method, raw_line }
---@param opts? { filter_vendor?: boolean, ignore_patterns?: string[], only_workspace_files?: boolean }
---@return { files: table[], frames: table[] }
function M.collect(frames, opts)
  opts = opts or {}
  local filter_vendor = opts.filter_vendor or false
  local ignore_patterns = opts.ignore_patterns

  local filtered_frames = {}
  for _, frame in ipairs(frames) do
    local fpath = frame.file
    local should_ignore = false

    if filter_vendor then
      if M.is_vendor_or_ignored(fpath, ignore_patterns) then
        should_ignore = true
      end
    end

    if not should_ignore then
      table.insert(filtered_frames, frame)
    end
  end

  -- If filter eliminated all frames, fallback to all frames so user isn't left empty-handed
  local active_frames = (#filtered_frames > 0) and filtered_frames or frames

  local files = {}
  local file_map = {} -- keyed by file path -> index in files list

  for _, frame in ipairs(active_frames) do
    local fpath = frame.file
    local existing_idx = file_map[fpath]

    if not existing_idx then
      local entry = {
        file = fpath,
        primary_line = frame.line,
        primary_col = frame.col or 1,
        primary_method = frame.method or "",
        total_frames = 1,
        frames = { frame },
        is_vendor = M.is_vendor_or_ignored(fpath, ignore_patterns),
      }
      table.insert(files, entry)
      file_map[fpath] = #files
    else
      local entry = files[existing_idx]
      entry.total_frames = entry.total_frames + 1
      table.insert(entry.frames, frame)
    end
  end

  return {
    files = files,
    frames = active_frames,
  }
end

return M
