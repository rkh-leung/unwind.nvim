-- lua/unwind/state.lua
-- Centralized runtime state container for active sessions and multi-root project sessions

local persistence = require("unwind.persistence")
local sessions = require("unwind.sessions")

local M = {}

--- Map of project root -> list of saved sessions
M.sessions_by_root = {}

--- Internal raw state
M.raw = {
  root = nil,
  sessions = {},
  sessions_loaded = false,
  sessions_root = nil,
  active_session = nil,
}

--- Reset in-memory state (useful for clear and test teardown)
function M.reset()
  M.raw.root = nil
  M.raw.sessions = {}
  M.raw.sessions_loaded = false
  M.raw.sessions_root = nil
  M.raw.active_session = nil
end

--- Get the current active session
---@return table?
function M.current()
  return M.raw.active_session
end

--- Set the current active session
---@param session table?
function M.set_current(session)
  M.raw.active_session = session
end

--- Get current active project root
---@return string
function M.get_root()
  return M.raw.root or (M.raw.active_session and M.raw.active_session.root) or vim.fs.normalize(vim.fn.getcwd())
end

--- Set current active project root
---@param root string
function M.set_root(root)
  local norm = vim.fs.normalize(root)
  M.raw.root = norm
  if M.raw.active_session then
    M.raw.active_session.root = norm
  end
end

--- Ensure persisted sessions are loaded for project root
---@param root? string
---@return table[] sessions
function M.ensure_sessions_loaded(root)
  local normalized_root = vim.fs.normalize(root or M.get_root())

  if not M.sessions_by_root[normalized_root] then
    M.sessions_by_root[normalized_root] = persistence.load(normalized_root)
  end

  M.raw.sessions = M.sessions_by_root[normalized_root]
  M.raw.sessions_root = normalized_root
  M.raw.sessions_loaded = true
  M.raw.root = normalized_root
  return M.raw.sessions
end

--- Backwards-compatible state metatable
--- Delegates top-level queries (unwind.state.frames, unwind.state.root, etc.)
M.compat = setmetatable({}, {
  __index = function(_, k)
    if k == "root" then
      return M.raw.root or (M.raw.active_session and M.raw.active_session.root)
    elseif k == "sessions" then
      return M.raw.sessions
    elseif k == "sessions_loaded" then
      return M.raw.sessions_loaded
    elseif k == "active_session" then
      return M.raw.active_session
    elseif M.raw.active_session and M.raw.active_session[k] ~= nil then
      return M.raw.active_session[k]
    end
    return M.raw[k]
  end,
  __newindex = function(_, k, v)
    if k == "root" then
      M.set_root(v)
    elseif k == "sessions" then
      M.raw.sessions = v
      if M.raw.sessions_root then
        M.sessions_by_root[M.raw.sessions_root] = v
      end
    elseif k == "sessions_loaded" then
      M.raw.sessions_loaded = v
    elseif k == "active_session" then
      M.raw.active_session = v
    else
      if not M.raw.active_session then
        M.raw.active_session = sessions.new_working(M.get_root(), {})
      end
      M.raw.active_session[k] = v
    end
  end,
})

return M
