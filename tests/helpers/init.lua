---@module "tests.helpers"
--- Shared fixtures and testing helpers for unwind.nvim test suites

local env = require("tests.helpers.environment")

local M = {}

M.env = env
M.create_temp_dir = env.create_temp_dir
M.setup_isolated_env = env.setup_isolated_env
M.cleanup_dir = env.cleanup_dir
M.cleanup_all = env.cleanup_all
M.setup_test_clipboard = env.setup_test_clipboard

--- Helper to safely write content to a file
---@param path string
---@param content string
function M.write_file(path, content)
  local f = io.open(path, "w")
  if not f then error("Could not write file: " .. path) end
  f:write(content)
  f:close()
end

--- Helper to safely read content from a file
---@param path string
---@return string
function M.read_file(path)
  local f = io.open(path, "r")
  if not f then error("Could not read file: " .. path) end
  local content = f:read("*a")
  f:close()
  return content
end

return M
