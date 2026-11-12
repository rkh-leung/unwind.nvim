---@module "unwind.resolvers.ruby.managers.rvm"
--- RVM Ruby manager adapter

local common = require("unwind.resolvers.common")

local M = {}

--- Detect if RVM is in use
---@param root string
---@return boolean
function M.detect(root)
  local rvm_path = common.getenv("rvm_path")
  local home = common.getenv("HOME")
  if rvm_path and common.exists(rvm_path) then
    return true
  end
  if home and common.exists(home .. "/.rvm") then
    return true
  end
  if common.exists("/usr/local/rvm") then
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
  local rvm_path = common.getenv("rvm_path")
  if rvm_path then
    table.insert(candidate_roots, rvm_path .. "/rubies")
  end
  local home = common.getenv("HOME")
  if home then
    table.insert(candidate_roots, home .. "/.rvm/rubies")
  end
  table.insert(candidate_roots, "/usr/local/rvm/rubies")

  for _, root in ipairs(candidate_roots) do
    local try_dirs = { root .. "/" .. version, root .. "/ruby-" .. version }
    for _, dir in ipairs(try_dirs) do
      local ruby_bin = dir .. "/bin/ruby"
      if common.is_executable_file(ruby_bin) then
        return ruby_bin
      end
    end
  end

  return nil
end

return M
