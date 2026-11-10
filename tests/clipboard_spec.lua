-- tests/clipboard_spec.lua
-- Tests for clipboard stacktrace ingestion semantics

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

local unwind = require("unwind")
local sessions = require("unwind.sessions")
local sidebar = require("unwind.sidebar")

print("--> [Clipboard Spec 1] Clipboard creates a NEW unnamed transient session...")
do
  unwind.clear()
  vim.fn.setreg("+", 'File "test_clip_1.py", line 10, in fn1\n')
  local s1 = unwind.ingest_clipboard()
  assert_true(s1 ~= nil, "s1 was created from clipboard")
  assert_eq(s1.name, nil, "s1 is unnamed")
  assert_true(s1.transient, "s1 is transient")
  assert_eq(#s1.raw_frames, 1, "s1 has 1 raw frame")
  assert_eq(unwind.state.active_session.id, s1.id, "s1 is active")

  -- Run again with different clipboard content
  vim.fn.setreg("+", 'File "test_clip_2.py", line 20, in fn2\n')
  local s2 = unwind.ingest_clipboard()
  assert_true(s2 ~= nil, "s2 was created from clipboard")
  assert_true(s2.id ~= s1.id, "s2 is a distinct new session from s1")
  assert_eq(s2.name, nil, "s2 is unnamed")
  assert_true(s2.transient, "s2 is transient")
  assert_eq(#s2.raw_frames, 1, "s2 has 1 raw frame")
  assert_eq(s2.raw_frames[1].line, 20, "s2 has new frame")
  assert_eq(unwind.state.active_session.id, s2.id, "s2 is now active")

  -- Original s1 frames remain intact
  assert_eq(#s1.raw_frames, 1, "s1 frames were not overwritten")
  assert_eq(s1.raw_frames[1].line, 10, "s1 line 10 intact")
  sidebar.hide()
  unwind.clear()
end

print("--> [Clipboard Spec 2] Clipboard does not mutate saved active session...")
do
  unwind.clear()
  local test_root = vim.fs.normalize(vim.fn.getcwd())
  local storage_file = sessions.storage_path(test_root)

  vim.fn.setreg("+", 'File "saved_test.py", line 15, in fn_saved\n')
  local s_saved = unwind.ingest_clipboard()
  unwind.ensure_sessions_loaded(test_root)
  sessions.save_working(s_saved, "Preserved Saved Trace", unwind.state.sessions, test_root)

  -- Ingest another clipboard trace
  vim.fn.setreg("+", 'File "new_trace.py", line 99, in fn_new\n')
  local s_new = unwind.ingest_clipboard()

  assert_true(s_new.id ~= s_saved.id, "new session ID differs from saved")
  assert_eq(s_saved.name, "Preserved Saved Trace", "saved session name intact")
  assert_eq(#s_saved.raw_frames, 1, "saved session frame count intact")
  assert_eq(s_saved.raw_frames[1].line, 15, "saved session line intact")

  sidebar.hide()
  sessions.delete(s_saved, unwind.state.sessions, test_root)
  pcall(os.remove, storage_file)
  unwind.clear()
end

print("--> [Clipboard Spec 3] Empty/invalid clipboard does not destroy current session...")
do
  unwind.clear()
  vim.fn.setreg("+", 'File "valid.py", line 5, in fn\n')
  local s_valid = unwind.ingest_clipboard()
  assert_true(s_valid ~= nil, "valid session exists")

  -- Now empty clipboard
  vim.fn.setreg("+", "")
  local s_empty = unwind.ingest_clipboard()
  assert_true(s_empty == nil, "empty clipboard returns nil")
  assert_eq(unwind.state.active_session.id, s_valid.id, "active session was not destroyed")

  -- Non-trace clipboard
  vim.fn.setreg("+", "just some plain words without trace numbers")
  local s_non_trace = unwind.ingest_clipboard()
  assert_true(s_non_trace == nil, "non-trace clipboard returns nil")
  assert_eq(unwind.state.active_session.id, s_valid.id, "active session was still not destroyed")

  sidebar.hide()
  unwind.clear()
end

print("All clipboard spec tests PASSED successfully!")
