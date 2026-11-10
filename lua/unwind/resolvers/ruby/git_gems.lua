-- lua/unwind/resolvers/ruby/git_gems.lua
-- Bundler git gems resolution: bundler/gems/<gem_name>-<revision>/<relative_path>

local M = {}

--- Checks if a file path exists and is a regular file
---@param path string
---@return boolean
local function is_file(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

--- Resolve Bundler git gem location
---@param parsed_git_gem table { gem_name: string, revision: string, relative_path: string }
---@param env table RubyEnv from environment.lua
---@return table? { path: string, gem: string, revision: string }
function M.resolve(parsed_git_gem, env)
  if not parsed_git_gem or not env then
    return nil
  end

  local folder_exact = parsed_git_gem.gem_name .. "-" .. parsed_git_gem.revision
  local gem_paths = env.gem_paths or {}
  if #gem_paths == 0 and env.gem_dir then
    gem_paths = { env.gem_dir }
  end

  -- Search each gem root under bundler/gems/
  for _, gp in ipairs(gem_paths) do
    local bundler_gems_dir = vim.fs.normalize(gp .. "/bundler/gems")
    local exact_cand = vim.fs.normalize(bundler_gems_dir .. "/" .. folder_exact .. "/" .. parsed_git_gem.relative_path)
    if is_file(exact_cand) then
      return {
        path = exact_cand,
        gem = parsed_git_gem.gem_name,
        revision = parsed_git_gem.revision,
      }
    end

    -- If exact candidate not found, check if a directory prefix matches revision (e.g. short vs long git SHA)
    local handle = (vim.uv or vim.loop).fs_scandir(bundler_gems_dir)
    if handle then
      while true do
        local name, type = (vim.uv or vim.loop).fs_scandir_next(handle)
        if not name then break end
        if type == "directory" then
          -- Check if directory matches name-<prefix of revision> or name-<revision prefix>
          if vim.startswith(name, parsed_git_gem.gem_name .. "-") then
            local cand_rev = name:sub(#parsed_git_gem.gem_name + 2)
            if vim.startswith(cand_rev, parsed_git_gem.revision) or vim.startswith(parsed_git_gem.revision, cand_rev) then
              local cand_file = vim.fs.normalize(bundler_gems_dir .. "/" .. name .. "/" .. parsed_git_gem.relative_path)
              if is_file(cand_file) then
                return {
                  path = cand_file,
                  gem = parsed_git_gem.gem_name,
                  revision = cand_rev,
                }
              end
            end
          end
        end
      end
    end
  end

  return nil
end

return M
