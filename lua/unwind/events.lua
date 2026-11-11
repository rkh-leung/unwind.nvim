-- lua/unwind/events.lua
-- Internal event bus for Unwind session lifecycle

local M = {}

local listeners = {}
local next_listener_id = 0

--- Register an event listener
---@param event string
---@param callback fun(...)
---@return integer id Listener subscription ID
function M.on(event, callback)
  listeners[event] = listeners[event] or {}
  next_listener_id = next_listener_id + 1
  local id = next_listener_id
  listeners[event][id] = callback
  return id
end

--- Unregister an event listener
---@param event string
---@param id integer
function M.off(event, id)
  if listeners[event] and listeners[event][id] then
    listeners[event][id] = nil
  end
end

--- Emit an event to all subscribers
---@param event string
---@param ... any
function M.emit(event, ...)
  if not listeners[event] then
    return
  end
  for _, callback in pairs(listeners[event]) do
    if type(callback) == "function" then
      pcall(callback, ...)
    end
  end
end

--- Clear all listeners (for testing/reset)
function M.clear_all()
  listeners = {}
  next_listener_id = 0
end

return M
