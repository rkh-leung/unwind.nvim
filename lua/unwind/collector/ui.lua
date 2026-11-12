---@module "unwind.collector.ui"
--- UI formatting and display helpers for collector data

local M = {}

--- Format file entry for display
---@param file_entry table
---@return string
function M.format_file_summary(file_entry)
  if not file_entry then return "" end
  local count = file_entry.total_frames or 1
  local suffix = count == 1 and "frame" or "frames"
  return string.format("%s (%d %s)", file_entry.file or "", count, suffix)
end

return M
