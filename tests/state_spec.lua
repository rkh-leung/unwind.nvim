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

print("--> [State Spec 3] Full reset clears sessions_by_root without touching disk...")
do
  local test_env = require("tests.helpers.environment")
  local isolated = test_env.setup_isolated_env()
  local root1 = test_env.create_temp_dir("state_spec_root1_")
  local root2 = test_env.create_temp_dir("state_spec_root2_")

  -- Create and save session in root1
  local s1 = sessions.create({ root = root1, name = "Root1 Session" })
  local list1 = state.ensure_sessions_loaded(root1)
  sessions.save_working(s1, "Root1 Session", list1, root1)

  -- Create and save session in root2
  local s2 = sessions.create({ root = root2, name = "Root2 Session" })
  local list2 = state.ensure_sessions_loaded(root2)
  sessions.save_working(s2, "Root2 Session", list2, root2)

  assert_true(state.sessions_by_root[root1] ~= nil, "root1 cached")
  assert_true(state.sessions_by_root[root2] ~= nil, "root2 cached")

  -- Perform reset
  state.reset()

  assert_eq(state.current(), nil, "no active session")
  assert_eq(next(state.sessions_by_root), nil, "sessions_by_root completely cleared")

  -- Reload from disk verifies data on disk is preserved
  local reloaded1 = state.ensure_sessions_loaded(root1)
  assert_eq(#reloaded1, 1, "disk data preserved for root1")
  assert_eq(reloaded1[1].name, "Root1 Session")

  state.reset()
  isolated.cleanup()
  test_env.cleanup_all()
end

print("All state spec tests PASSED successfully!")
