---@module "unwind.resolvers.ruby.managers.rbenv"
--- rbenv Ruby manager adapter

local common = require("unwind.resolvers.common")

local M = {}

--- Detect if rbenv is in use
---@param root string
---@return boolean
function M.detect(root)
  local rbenv_root = common.getenv("RBENV_ROOT")
  local home = common.getenv("HOME")
  if rbenv_root and common.exists(rbenv_root) then
    return true
  end
  if home and common.exists(home .. "/.rbenv") then
    return true
  end
  return false
end

--- Find ruby executable for a requested version
---@param version string
---@return string? ruby_bin
function M.find_ruby(version)
  if not version or version == "" then
    return nil
  end

  local candidate_roots = {}
  local rbenv_root = common.getenv("RBENV_ROOT")
  if rbenv_root then
    table.insert(candidate_roots, rbenv_root)
  end
  local home = common.getenv("HOME")
  if home then
    table.insert(candidate_roots, home .. "/.rbenv")
  end

  for _, root in ipairs(candidate_roots) do
    local ruby_bin = root .. "/versions/" .. version .. "/bin/ruby"
    if common.is_executable_file(ruby_bin) then
      return ruby_bin
    end
  end

  return nil
end

return M
