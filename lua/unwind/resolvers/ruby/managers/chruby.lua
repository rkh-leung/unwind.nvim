-- lua/unwind/resolvers/ruby/managers/chruby.lua
-- chruby / ruby-install Ruby manager adapter

local M = {}

--- Detect if chruby/ruby-install is in use
---@param root string
---@return boolean
function M.detect(root)
  local home = os.getenv("HOME")
  if (vim.uv or vim.loop).fs_stat("/opt/rubies") then
    return true
  end
  if home and (vim.uv or vim.loop).fs_stat(home .. "/.rubies") then
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
  local home = os.getenv("HOME")
  if home and home ~= "" then
    table.insert(candidate_roots, home .. "/.rubies")
  end

  for _, root in ipairs(candidate_roots) do
    -- chruby folders can be <version> or ruby-<version>
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
