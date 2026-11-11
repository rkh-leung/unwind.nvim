-- tests/ingestion_spec.lua
-- Tests for ingestion behavior consistency and session isolation

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

local test_env = require("tests.helpers.environment")
test_env.setup_test_clipboard()

-- Verify that setting and reading the + register round-trips expected text
vim.fn.setreg("+", "test_ingestion_clipboard_roundtrip\n")
assert_eq(vim.fn.getreg("+"), "test_ingestion_clipboard_roundtrip\n", "clipboard provider round-trip verified")

local unwind = require("unwind")
local sidebar = require("unwind.sidebar")
local state = require("unwind.state")

local isolated = test_env.setup_isolated_env()
local test_root = test_env.create_temp_dir("ingestion_spec_root_")
state.set_root(test_root)

local dummy_file = test_root .. "/ingest_test.py"
local f = io.open(dummy_file, "w")
f:write("def foo():\n    pass\n")
f:close()

local sample_trace = string.format('  File "%s", line 1, in foo\n', dummy_file)

print("--> [Ingestion Spec 1] Ingest creates brand-new transient session...")
do
  unwind.clear()
  local s1 = unwind.ingest(sample_trace)
  assert_true(s1 ~= nil, "session created")
  assert_true(s1.transient, "session is transient")
  assert_eq(s1.name, nil, "session is unnamed")
  assert_eq(state.current(), s1, "session is active")

  -- Ingesting a second trace creates a brand-new session, not mutating s1
  local s2 = unwind.ingest(sample_trace)
  assert_true(s2 ~= nil)
  assert_true(s2 ~= s1, "second ingestion creates distinct session instance")
  assert_eq(state.current(), s2, "s2 became active")
  unwind.clear()
end

print("--> [Ingestion Spec 2] Direct M.ingest preserves sidebar visibility...")
do
  unwind.clear()
  assert_true(not sidebar.is_open(), "sidebar initially closed")

  unwind.ingest(sample_trace)
  assert_true(not sidebar.is_open(), "direct ingest does not open sidebar if closed")

  sidebar.open(state.current(), {})
  assert_true(sidebar.is_open(), "sidebar opened manually")

  unwind.ingest(sample_trace)
  assert_true(sidebar.is_open(), "direct ingest keeps sidebar open if previously open")
  sidebar.hide()
  unwind.clear()
end

print("--> [Ingestion Spec 3] Interactive clipboard ingestion activates and opens sidebar...")
do
  unwind.clear()
  vim.fn.setreg("+", sample_trace)
  assert_true(not sidebar.is_open(), "sidebar initially closed")

  unwind.ingest_clipboard()
  assert_true(sidebar.is_open(), "clipboard ingest opens sidebar")
  sidebar.hide()
  unwind.clear()
end

isolated.cleanup()
test_env.cleanup_all()

print("All ingestion spec tests PASSED successfully!")
