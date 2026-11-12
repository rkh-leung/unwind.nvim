---@module "unwind.resolvers.ruby.managers.chruby"
--- chruby / ruby-install Ruby manager adapter

local common = require("unwind.resolvers.common")

local M = {}

--- Detect if chruby/ruby-install is in use
---@param root string
---@return boolean
function M.detect(root)
  local home = common.getenv("HOME")
  if common.exists("/opt/rubies") then
    return true
  end
  if home and common.exists(home .. "/.rubies") then
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

  local candidate_roots = { "/opt/rubies" }
  local home = common.getenv("HOME")
  if home then
    table.insert(candidate_roots, home .. "/.rubies")
  end

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
