-- lua/unwind/resolvers/ruby/managers/mise.lua
-- mise (formerly rtx) Ruby manager adapter

local M = {}

--- Detect if mise is in use
---@param root string
---@return boolean
function M.detect(root)
  local mise_data = os.getenv("MISE_DATA_DIR")
  local home = os.getenv("HOME")
  if mise_data and (vim.uv or vim.loop).fs_stat(mise_data .. "/installs/ruby") then
    return true
  end
  if home and ((vim.uv or vim.loop).fs_stat(home .. "/.local/share/mise/installs/ruby")
      or (vim.uv or vim.loop).fs_stat(home .. "/.local/share/rtx/installs/ruby")) then
    return true
  end
  local stat_mise = (vim.uv or vim.loop).fs_stat(root .. "/mise.toml")
  local stat_dot_mise = (vim.uv or vim.loop).fs_stat(root .. "/.mise.toml")
  return stat_mise ~= nil or stat_dot_mise ~= nil
end

--- Find ruby executable for a requested version
---@param version string
---@return string? ruby_bin
function M.find_ruby(version)
  if not version or version == "" then
    return nil
  end

  local candidate_roots = {}
  local mise_data = os.getenv("MISE_DATA_DIR")
  if mise_data and mise_data ~= "" then
    table.insert(candidate_roots, mise_data .. "/installs/ruby")
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    table.insert(candidate_roots, home .. "/.local/share/mise/installs/ruby")
    table.insert(candidate_roots, home .. "/.local/share/rtx/installs/ruby")
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
