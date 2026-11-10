-- lua/unwind/resolvers/ruby/stdlib.lua
-- Ruby standard library file resolution

local M = {}

--- Checks if a file path exists and is a regular file
---@param path string
---@return boolean
local function is_file(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

--- Resolve Ruby standard library file against environment libdirs:
--- env.rubylibdir, env.archdir, env.sitelibdir, env.vendorlibdir
---@param parsed_stdlib table { stdlib_path: string, module_name: string }
---@param env table RubyEnv from environment.lua
---@return table? { path: string, module: string }
function M.resolve(parsed_stdlib, env)
  if not parsed_stdlib or not env then
    return nil
  end

  local search_dirs = {
    env.rubylibdir,
    env.archdir,
    env.sitelibdir,
    env.vendorlibdir,
  }

  for _, dir in ipairs(search_dirs) do
    if dir and dir ~= "" then
      local candidate = vim.fs.normalize(dir .. "/" .. parsed_stdlib.stdlib_path)
      if is_file(candidate) then
        return {
          path = candidate,
          module = parsed_stdlib.module_name,
        }
      end
    end
  end

  return nil
end

return M
