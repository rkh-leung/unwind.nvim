-- lua/unwind/collector.lua
-- File deduplication and frame grouping logic
-- Group parsed frames by unique file path, maintaining original occurrence order.

local M = {}

--- Collects and deduplicates parsed frames by unique file path.
--- Retains original occurrence order (first file implicated in trace at index 1).
--- Tracks total frame count and primary line (the highest/first fault line) for each unique file.
---@param frames table[] List of frame objects { file, line, col, method, raw_line }
---@return { files: table[], frames: table[] }
function M.collect(frames)
  local files = {}
  local file_map = {} -- keyed by file path -> index in files list

  for _, frame in ipairs(frames) do
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
    frames = frames,
  }
end

return M
