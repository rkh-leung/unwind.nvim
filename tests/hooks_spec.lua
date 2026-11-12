-- tests/hooks_spec.lua
-- Unit tests for unwind.hooks registry and extensibility API

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local hooks = require("unwind.hooks")

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: expected %s, got %s. %s", vim.inspect(b), vim.inspect(a), msg or ""))
  end
end

local function assert_true(cond, msg)
  if not cond then
    error("Assertion failed: " .. (msg or "expected true"))
  end
end

print("--> [Hooks Spec 1] Register, get, and unregister resolver...")
hooks.clear_all()

local dummy_resolver = {
  resolve = function(frame, root)
    return { resolved_path = root .. "/" .. frame.file }
  end
}

hooks.register_resolver("custom_ruby", dummy_resolver)
assert_eq(hooks.get_resolver("custom_ruby"), dummy_resolver)

-- Duplicate name guard
local dup_ok, _ = pcall(hooks.register_resolver, "custom_ruby", dummy_resolver)
assert_true(not dup_ok, "Duplicate resolver name registration must fail")

-- Invalid shape guard
local invalid_ok, _ = pcall(hooks.register_resolver, "broken", { not_resolve = 1 })
assert_true(not invalid_ok, "Resolver without resolve() function must fail")

hooks.unregister_resolver("custom_ruby")
assert_eq(hooks.get_resolver("custom_ruby"), nil)

print("--> [Hooks Spec 2] Register, list, and unregister UI components and exporters...")
hooks.register_ui_component("custom_sidebar", { render = function() end })
hooks.register_exporter("custom_json", { export = function() end })

local list = hooks.list()
assert_eq(#list.resolvers, 0)
assert_eq(#list.ui_components, 1)
assert_eq(list.ui_components[1], "custom_sidebar")
assert_eq(#list.exporters, 1)
assert_eq(list.exporters[1], "custom_json")

hooks.clear_all()
local empty_list = hooks.list()
assert_eq(#empty_list.ui_components, 0)
assert_eq(#empty_list.exporters, 0)

print("--> [Hooks Spec 3] on_event and off_event subscription lifecycle...")
local calls = 0
local listener_id = hooks.on_event("session_activated", function()
  calls = calls + 1
end)

local events = require("unwind.events")
events.emit("session_activated", {})
assert_eq(calls, 1)

hooks.off_event("session_activated", listener_id)
events.emit("session_activated", {})
assert_eq(calls, 1, "Listener must not be invoked after off_event")

-- Unknown event name guard
local unknown_ev_ok, _ = pcall(hooks.on_event, "nonexistent_event", function() end)
assert_true(not unknown_ev_ok, "Subscribing to unknown event must fail")

print("All hooks spec tests PASSED successfully!")
