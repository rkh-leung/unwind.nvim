---@module "unwind.resolvers.ruby.managers.mise"
--- mise (formerly rtx) Ruby manager adapter

local common = require("unwind.resolvers.common")

local M = {}

--- Detect if mise is in use
---@param root string
---@return boolean
function M.detect(root)
  local mise_data = common.getenv("MISE_DATA_DIR")
  local home = common.getenv("HOME")
  if mise_data and common.exists(mise_data .. "/installs/ruby") then
    return true
  end
  if home and (common.exists(home .. "/.local/share/mise/installs/ruby")
      or common.exists(home .. "/.local/share/rtx/installs/ruby")) then
    return true
  end
  return common.exists(root .. "/mise.toml") or common.exists(root .. "/.mise.toml")
end

--- Find ruby executable for a requested version
---@param version string
---@return string? ruby_bin
function M.find_ruby(version)
  if not version or version == "" then
    return nil
  end

  local candidate_roots = {}
  local mise_data = common.getenv("MISE_DATA_DIR")
  if mise_data then
    table.insert(candidate_roots, mise_data .. "/installs/ruby")
  end
  local home = common.getenv("HOME")
  if home then
    table.insert(candidate_roots, home .. "/.local/share/mise/installs/ruby")
    table.insert(candidate_roots, home .. "/.local/share/rtx/installs/ruby")
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
