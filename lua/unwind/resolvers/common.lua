---@module "unwind.resolvers.common"
--- Helper utilities for version manager and environment detection

local M = {}

local uv = vim.uv or vim.loop

--- Check if a path exists on disk
---@param path string
---@return boolean
function M.exists(path)
  if not path or path == "" then return false end
  local stat = uv.fs_stat(path)
  return stat ~= nil
end

--- Check if an executable binary file exists
---@param path string
---@return boolean
function M.is_executable_file(path)
  if not path or path == "" then return false end
  local stat = uv.fs_stat(path)
  return stat and (stat.type == "file" or stat.type == "link") or false
end

--- Get environment variable safely
---@param name string
---@return string?
function M.getenv(name)
  local val = os.getenv(name)
  if val and val ~= "" then
    return val
  end
  return nil
end

--- Check candidate directories and return the first one that exists
---@param paths string[]
---@return string?
function M.find_first_existing(paths)
  for _, p in ipairs(paths) do
    if M.exists(p) then
      return p
    end
  end
  return nil
end

return M
