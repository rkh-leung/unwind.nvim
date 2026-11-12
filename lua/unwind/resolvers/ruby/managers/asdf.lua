---@module "unwind.resolvers.ruby.managers.asdf"
--- asdf Ruby manager adapter

local common = require("unwind.resolvers.common")

local M = {}

--- Detect if asdf is in use
---@param root string
---@return boolean
function M.detect(root)
  local asdf_data = common.getenv("ASDF_DATA_DIR")
  local home = common.getenv("HOME")
  if asdf_data and common.exists(asdf_data .. "/installs/ruby") then
    return true
  end
  if home and common.exists(home .. "/.asdf/installs/ruby") then
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
  local asdf_data = common.getenv("ASDF_DATA_DIR")
  if asdf_data then
    table.insert(candidate_roots, asdf_data .. "/installs/ruby")
  end
  local home = common.getenv("HOME")
  if home then
    table.insert(candidate_roots, home .. "/.asdf/installs/ruby")
  end

  for _, root in ipairs(candidate_roots) do
    local ruby_bin = root .. "/" .. version .. "/bin/ruby"
    if common.is_executable_file(ruby_bin) then
      return ruby_bin
    end
  end

  return nil
end

return M
