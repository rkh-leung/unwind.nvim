-- tests/helpers/environment.lua
-- Isolated test environment helpers to prevent tests/benchmarks from touching real user state

local M = {}

local uv = vim.uv or vim.loop
local created_dirs = {}

--- Create a temporary directory safely
---@param prefix? string
---@return string path
function M.create_temp_dir(prefix)
  prefix = prefix or "unwind_test_"
  local base = vim.fs.normalize(vim.fn.tempname())
  local dir = base .. "_" .. prefix .. tostring(uv.hrtime())
  vim.fn.mkdir(dir, "p")
  table.insert(created_dirs, dir)
  return dir
end

--- Set up an isolated environment (XDG_STATE_HOME, XDG_DATA_HOME, XDG_CONFIG_HOME)
--- Returns the root of the isolated state directory
---@return { state_dir: string, cleanup: fun() }
function M.setup_isolated_env()
  local temp_state = M.create_temp_dir("xdg_state_")
  local prev_state = vim.env.XDG_STATE_HOME
  local prev_data = vim.env.XDG_DATA_HOME
  local prev_config = vim.env.XDG_CONFIG_HOME

  vim.env.XDG_STATE_HOME = temp_state
  vim.env.XDG_DATA_HOME = temp_state .. "/data"
  vim.env.XDG_CONFIG_HOME = temp_state .. "/config"
  vim.fn.mkdir(temp_state .. "/data", "p")
  vim.fn.mkdir(temp_state .. "/config", "p")

  local function cleanup()
    if prev_state then
      vim.env.XDG_STATE_HOME = prev_state
    else
      vim.env.XDG_STATE_HOME = nil
    end
    if prev_data then
      vim.env.XDG_DATA_HOME = prev_data
    else
      vim.env.XDG_DATA_HOME = nil
    end
    if prev_config then
      vim.env.XDG_CONFIG_HOME = prev_config
    else
      vim.env.XDG_CONFIG_HOME = nil
    end
    M.cleanup_dir(temp_state)
  end

  return {
    state_dir = temp_state,
    cleanup = cleanup,
  }
end

--- Recursively remove a temporary directory created by tests
--- Refuses to remove paths not in temporary directories
---@param path string
function M.cleanup_dir(path)
  if not path or path == "" then return end
  local norm = vim.fs.normalize(path)
  -- Safety check: only clean up paths under /tmp or standard temp locations
  local is_temp = norm:match("^/tmp/") or norm:match("^/var/tmp/") or norm:match("unwind_test_")
  if not is_temp then
    error("Safety violation: refusing to delete non-temporary directory: " .. norm)
  end

  if vim.fn.delete then
    vim.fn.delete(norm, "rf")
  end
end

--- Cleanup all tracked temporary directories created during this test process
function M.cleanup_all()
  for _, dir in ipairs(created_dirs) do
    pcall(M.cleanup_dir, dir)
  end
  created_dirs = {}
end

return M
