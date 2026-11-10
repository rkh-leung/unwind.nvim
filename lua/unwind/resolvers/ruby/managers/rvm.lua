-- lua/unwind/resolvers/ruby/managers/rvm.lua
-- RVM Ruby manager adapter

local M = {}

--- Detect if RVM is in use
---@param root string
---@return boolean
function M.detect(root)
  local rvm_path = os.getenv("rvm_path")
  local home = os.getenv("HOME")
  if rvm_path and (vim.uv or vim.loop).fs_stat(rvm_path) then
    return true
  end
  if home and (vim.uv or vim.loop).fs_stat(home .. "/.rvm") then
    return true
  end
  if (vim.uv or vim.loop).fs_stat("/usr/local/rvm") then
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
  local rvm_path = os.getenv("rvm_path")
  if rvm_path and rvm_path ~= "" then
    table.insert(candidate_roots, rvm_path .. "/rubies")
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    table.insert(candidate_roots, home .. "/.rvm/rubies")
  end
  table.insert(candidate_roots, "/usr/local/rvm/rubies")

  for _, root in ipairs(candidate_roots) do
    local try_dirs = { root .. "/" .. version, root .. "/ruby-" .. version }
    for _, dir in ipairs(try_dirs) do
      local ruby_bin = dir .. "/bin/ruby"
      local stat = (vim.uv or vim.loop).fs_stat(ruby_bin)
      if stat and (stat.type == "file" or stat.type == "link") then
        return ruby_bin
      end
    end
  end

  return nil
end

return M
