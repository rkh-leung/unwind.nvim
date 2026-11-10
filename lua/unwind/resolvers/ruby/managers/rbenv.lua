-- lua/unwind/resolvers/ruby/managers/rbenv.lua
-- rbenv Ruby manager adapter

local M = {}

--- Detect if rbenv is in use
---@param root string
---@return boolean
function M.detect(root)
  local rbenv_root = os.getenv("RBENV_ROOT")
  local home = os.getenv("HOME")
  if rbenv_root and (vim.uv or vim.loop).fs_stat(rbenv_root) then
    return true
  end
  if home and (vim.uv or vim.loop).fs_stat(home .. "/.rbenv") then
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
  local rbenv_root = os.getenv("RBENV_ROOT")
  if rbenv_root and rbenv_root ~= "" then
    table.insert(candidate_roots, rbenv_root)
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    table.insert(candidate_roots, home .. "/.rbenv")
  end

  for _, root in ipairs(candidate_roots) do
    local ruby_bin = root .. "/versions/" .. version .. "/bin/ruby"
    local stat = (vim.uv or vim.loop).fs_stat(ruby_bin)
    if stat and (stat.type == "file" or stat.type == "link") then
      return ruby_bin
    end
  end

  return nil
end

return M
