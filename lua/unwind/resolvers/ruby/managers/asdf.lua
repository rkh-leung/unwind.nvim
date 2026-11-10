-- lua/unwind/resolvers/ruby/managers/asdf.lua
-- asdf Ruby manager adapter

local M = {}

--- Detect if asdf is in use
---@param root string
---@return boolean
function M.detect(root)
  local asdf_data = os.getenv("ASDF_DATA_DIR")
  local home = os.getenv("HOME")
  if asdf_data and (vim.uv or vim.loop).fs_stat(asdf_data .. "/installs/ruby") then
    return true
  end
  if home and (vim.uv or vim.loop).fs_stat(home .. "/.asdf/installs/ruby") then
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
  local asdf_data = os.getenv("ASDF_DATA_DIR")
  if asdf_data and asdf_data ~= "" then
    table.insert(candidate_roots, asdf_data .. "/installs/ruby")
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    table.insert(candidate_roots, home .. "/.asdf/installs/ruby")
  end

  for _, root in ipairs(candidate_roots) do
    local ruby_bin = root .. "/" .. version .. "/bin/ruby"
    local stat = (vim.uv or vim.loop).fs_stat(ruby_bin)
    if stat and (stat.type == "file" or stat.type == "link") then
      return ruby_bin
    end
  end

  return nil
end

return M
