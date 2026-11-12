---@module "unwind.collector.persistence"
--- Persistence-specific serialization helpers for collector collections

local M = {}

--- Sanitize files/frames collection for serialization
---@param collection table
---@return table
function M.prepare_for_persistence(collection)
  if not collection then return {} end
  return {
    files = collection.files or {},
    frames = collection.frames or {},
  }
end

return M
