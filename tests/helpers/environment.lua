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
--- Uses strict ownership tracking: only permits deletion of registered directories
---@param path string
function M.cleanup_dir(path)
  if not path or path == "" then return end
  local norm = vim.fs.normalize(path)

  local found_idx = nil
  for idx, dir in ipairs(created_dirs) do
    if vim.fs.normalize(dir) == norm then
      found_idx = idx
      break
    end
  end

  if not found_idx then
    error("Safety violation: refusing to delete unowned directory: " .. norm)
  end

  table.remove(created_dirs, found_idx)
  if vim.fn.delete then
    vim.fn.delete(norm, "rf")
  end
end

--- Set up an in-memory test clipboard provider using Neovim's vim.g.clipboard interface.
--- Provides copy and paste callbacks for the '+' and '*' registers.
---@return table store In-memory register storage
function M.setup_test_clipboard()
  local store = {
    ["+"] = { {}, "c" },
    ["*"] = { {}, "c" },
  }

  vim.g.clipboard = {
    name = "test_clipboard",
    copy = {
      ["+"] = function(lines, regtype)
        store["+"] = { lines, regtype }
      end,
      ["*"] = function(lines, regtype)
        store["*"] = { lines, regtype }
      end,
    },
    paste = {
      ["+"] = function()
        return store["+"]
      end,
      ["*"] = function()
        return store["*"]
      end,
    },
    cache_enabled = 0,
  }

  return store
end

--- Cleanup all tracked temporary directories created during this test process
function M.cleanup_all()
  local to_clean = {}
  for _, d in ipairs(created_dirs) do
    table.insert(to_clean, d)
  end
  for _, dir in ipairs(to_clean) do
    pcall(M.cleanup_dir, dir)
  end
  created_dirs = {}
end

return M
