-- lua/unwind/resolvers/ruby/gems.lua
-- Regular RubyGems exact version resolution

local M = {}

--- Checks if a file path exists and is a regular file
---@param path string
---@return boolean
local function is_file(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

--- Resolve regular gem location against probed gem_paths
--- Resolution rule: EXACT gem + EXACT version.
--- Never fall back to another installed gem version.
---@param parsed_gem table { gem_name: string, gem_version: string, relative_path: string }
---@param env table RubyEnv from environment.lua
---@return table? { path: string, gem: string, version: string }
function M.resolve(parsed_gem, env)
  if not parsed_gem or not env then
    return nil
  end

  local gem_folder = parsed_gem.gem_name .. "-" .. parsed_gem.gem_version
  local gem_paths = env.gem_paths or {}
  if #gem_paths == 0 and env.gem_dir then
    gem_paths = { env.gem_dir }
  end

  for _, gp in ipairs(gem_paths) do
    local candidate = vim.fs.normalize(gp .. "/gems/" .. gem_folder .. "/" .. parsed_gem.relative_path)
    if is_file(candidate) then
      return {
        path = candidate,
        gem = parsed_gem.gem_name,
        gem_version = parsed_gem.gem_version,
      }
    end
  end

  return nil
end

return M
