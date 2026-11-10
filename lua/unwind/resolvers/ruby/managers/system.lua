-- lua/unwind/resolvers/ruby/managers/system.lua
-- System Ruby fallback adapter

local M = {}

--- Detect system ruby
---@param root string
---@return boolean
function M.detect(root)
  return vim.fn.executable("ruby") == 1
end

--- Find system ruby executable
---@param version? string
---@return string? ruby_bin
function M.find_ruby(version)
  local bin = vim.fn.exepath("ruby")
  if bin and bin ~= "" then
    return bin
  end
  return nil
end

return M
