---@module "unwind.hooks"
--- Extensibility and plugin hook registry for unwind.nvim
--- Exposes extension points for resolvers, UI components, exporters, and lifecycle events.

local events = require("unwind.events")

local M = {}

M._resolvers = {}
M._ui_components = {}
M._exporters = {}

--- Known lifecycle event names
M.events = {
  "session_activated",
  "session_created",
  "session_changed",
  "session_deleted",
}

local event_set = {}
for _, ev in ipairs(M.events) do
  event_set[ev] = true
end

--- Register a custom language/path resolver
---@param name string Unique resolver name
---@param resolver table Object implementing `resolve(frame, root)`
function M.register_resolver(name, resolver)
  if type(name) ~= "string" or name == "" then
    error("Resolver name must be a non-empty string", 2)
  end
  if M._resolvers[name] then
    error(string.format("Resolver %q already registered – use a different name or unregister first", name), 2)
  end
  if type(resolver) ~= "table" or type(resolver.resolve) ~= "function" then
    error("Resolver must be a table with a `resolve(frame, root)` function", 2)
  end
  M._resolvers[name] = resolver
end

--- Unregister a custom resolver
---@param name string
function M.unregister_resolver(name)
  M._resolvers[name] = nil
end

--- Get a registered resolver
---@param name string
---@return table?
function M.get_resolver(name)
  return M._resolvers[name]
end

--- Register a custom UI component
---@param name string
---@param component table Component implementation
function M.register_ui_component(name, component)
  if type(name) ~= "string" or name == "" then
    error("UI component name must be a non-empty string", 2)
  end
  if M._ui_components[name] then
    error(string.format("UI component %q already registered – use a different name or unregister first", name), 2)
  end
  if type(component) ~= "table" then
    error("UI component must be a table", 2)
  end
  M._ui_components[name] = component
end

--- Unregister a custom UI component
---@param name string
function M.unregister_ui_component(name)
  M._ui_components[name] = nil
end

--- Get a registered UI component
---@param name string
---@return table?
function M.get_ui_component(name)
  return M._ui_components[name]
end

--- Register a custom exporter
---@param name string
---@param exporter table Object implementing `export(session, opts)`
function M.register_exporter(name, exporter)
  if type(name) ~= "string" or name == "" then
    error("Exporter name must be a non-empty string", 2)
  end
  if M._exporters[name] then
    error(string.format("Exporter %q already registered – use a different name or unregister first", name), 2)
  end
  if type(exporter) ~= "table" or type(exporter.export) ~= "function" then
    error("Exporter must be a table with an `export(session, opts)` function", 2)
  end
  M._exporters[name] = exporter
end

--- Unregister a custom exporter
---@param name string
function M.unregister_exporter(name)
  M._exporters[name] = nil
end

--- Get a registered exporter
---@param name string
---@return table?
function M.get_exporter(name)
  return M._exporters[name]
end

--- List all registered extension items
---@return { resolvers: string[], ui_components: string[], exporters: string[] }
function M.list()
  local function get_keys(t)
    local keys = {}
    for k in pairs(t) do
      table.insert(keys, k)
    end
    table.sort(keys)
    return keys
  end

  return {
    resolvers = get_keys(M._resolvers),
    ui_components = get_keys(M._ui_components),
    exporters = get_keys(M._exporters),
  }
end

--- Reset all registered extensions (primarily for testing)
function M.clear_all()
  M._resolvers = {}
  M._ui_components = {}
  M._exporters = {}
end

--- Subscribe to lifecycle events (session_created, session_activated, session_changed, session_deleted)
---@param event string
---@param callback fun(payload: table)
---@return number listener_id
function M.on_event(event, callback)
  if type(event) ~= "string" or event == "" then
    error("Event name must be a non-empty string", 2)
  end
  if not event_set[event] then
    error(string.format("Unknown event %q. Accepted events: %s", event, table.concat(M.events, ", ")), 2)
  end
  if type(callback) ~= "function" then
    error("Event callback must be a function", 2)
  end
  return events.on(event, callback)
end

--- Unsubscribe from a lifecycle event
---@param event string
---@param listener_id number
function M.off_event(event, listener_id)
  events.off(event, listener_id)
end

return M
