-- tests/state_spec.lua
-- Tests for state management and multi-root session caching

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_true(val, msg)
  if not val then
    error(msg or "expected truthy value")
  end
end

local state = require("unwind.state")
local sessions = require("unwind.sessions")

print("--> [State Spec 1] State root tracking and reset...")
do
  state.reset()
  assert_eq(state.current(), nil, "no active session after reset")
  state.set_root("/my/test/project")
  assert_eq(state.get_root(), "/my/test/project", "root correctly set")

  local s = sessions.create({ root = state.get_root(), name = "TestSess" })
  state.set_current(s)
  assert_eq(state.current().name, "TestSess", "active session set")

  state.reset()
  assert_eq(state.current(), nil, "active session cleared on reset")
end

print("--> [State Spec 2] Metatable backwards compatibility...")
do
  state.reset()
  state.compat.root = "/compat/root"
  assert_eq(state.get_root(), "/compat/root")

  local sess = sessions.create({ root = "/compat/root", name = "CompatSess", frames = { { file = "c.py", line = 1 } } })
  state.set_current(sess)
  assert_eq(state.compat.name, "CompatSess")
  assert_eq(#state.compat.raw_frames, 1)

  state.reset()
end

print("All state spec tests PASSED successfully!")
