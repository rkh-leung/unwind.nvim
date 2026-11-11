-- tests/decoration_sync_spec.lua
-- Tests for synchronizing active-frame decorations and sidebar across mutations and availability changes

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
local decorator = require("unwind.decorator")
local session_actions = require("unwind.session_actions")
local sessions = require("unwind.sessions")
local state = require("unwind.state")
local test_env = require("tests.helpers.environment")

local isolated = test_env.setup_isolated_env()
local test_root = test_env.create_temp_dir("decor_sync_root_")

local function get_virtual_lines(bufnr)
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, decorator.get_namespace(), 0, -1, { details = true })
  if #extmarks == 0 then return nil end
  return extmarks[1][4].virt_lines
end

print("--> [Decor Sync 1] Reordering active frame upward and downward updates virtual line depth...")
do
  unwind.clear()
  state.set_root(test_root)

  local file1 = test_root .. "/f1.lua"
  local f1 = io.open(file1, "w")
  f1:write("print('1')\nprint('2')\n")
  f1:close()

  local file2 = test_root .. "/f2.lua"
  local f2 = io.open(file2, "w")
  f2:write("print('a')\nprint('b')\n")
  f2:close()

  local buf1 = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf1, file1)
  vim.api.nvim_buf_set_lines(buf1, 0, -1, false, { "print('1')", "print('2')" })

  local buf2 = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf2, file2)
  vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "print('a')", "print('b')" })

  local raw_frames = {
    { file = "f1.lua", resolved_path = file1, line = 1, method = "step1", origin = "manual" },
    { file = "f2.lua", resolved_path = file2, line = 1, method = "step2", origin = "manual" },
  }

  local s = sessions.create({ root = test_root, frames = raw_frames })
  unwind.activate_session(s)
  unwind.jump_to_frame(1)

  local vl1 = get_virtual_lines(buf1)
  assert_true(vl1 ~= nil, "extmark exists on buf1")
  assert_true(vl1[1][1][1]:find("Step 1/2: step1") ~= nil, "initial step is 1/2")

  -- Move frame 1 down to 2
  unwind.move_frame_in_session(s, 1, 2)
  assert_eq(s.active_index, 2, "active index followed moved frame to 2")

  local vl1_after = get_virtual_lines(buf1)
  assert_true(vl1_after ~= nil, "extmark still exists on buf1")
  assert_true(vl1_after[1][1][1]:find("Step 2/2: step1") ~= nil, "header updated to Step 2/2 after move")

  -- Move frame 2 back up to 1
  unwind.move_frame_in_session(s, 2, 1)
  assert_eq(s.active_index, 1, "active index followed moved frame back to 1")
  local vl1_revert = get_virtual_lines(buf1)
  assert_true(vl1_revert[1][1][1]:find("Step 1/2: step1") ~= nil, "header updated back to Step 1/2")

  pcall(vim.api.nvim_buf_delete, buf1, { force = true })
  pcall(vim.api.nvim_buf_delete, buf2, { force = true })
  unwind.clear()
end

print("--> [Decor Sync 2] Reordering a non-active frame past the active frame updates depth...")
do
  unwind.clear()
  state.set_root(test_root)

  local file = test_root .. "/steps.lua"
  local fs = io.open(file, "w")
  fs:write("line 1\nline 2\nline 3\n")
  fs:close()

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, file)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "line 2", "line 3" })

  local raw_frames = {
    { file = "steps.lua", resolved_path = file, line = 1, method = "first", origin = "manual" },
    { file = "steps.lua", resolved_path = file, line = 2, method = "second", origin = "manual" },
    { file = "steps.lua", resolved_path = file, line = 3, method = "third", origin = "manual" },
  }

  local s = sessions.create({ root = test_root, frames = raw_frames })
  unwind.activate_session(s)
  -- Active is frame 2 ("second", line 2)
  unwind.jump_to_frame(2)

  local vl = get_virtual_lines(buf)
  assert_true(vl[1][1][1]:find("Step 2/3: second") ~= nil, "initially Step 2/3")

  -- Move frame 3 to 1 (frames become: third, first, second)
  -- Active frame "second" is now at index 3
  unwind.move_frame_in_session(s, 3, 1)
  assert_eq(s.active_index, 3, "active index shifted to 3")

  local vl_after = get_virtual_lines(buf)
  assert_true(vl_after[1][1][1]:find("Step 3/3: second") ~= nil, "header updated to Step 3/3 for active frame")

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  unwind.clear()
end

print("--> [Decor Sync 3] Availability refresh clears extmarks when file disappears and restores when reappears...")
do
  unwind.clear()
  state.set_root(test_root)

  local dynamic_file = test_root .. "/dynamic_sync.lua"
  local f = io.open(dynamic_file, "w")
  f:write("print('hello')\n")
  f:close()

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, dynamic_file)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "print('hello')" })

  local s = sessions.create({ root = test_root, frames = {
    { file = "dynamic_sync.lua", resolved_path = dynamic_file, line = 1, method = "hi", origin = "manual" },
  } })
  unwind.activate_session(s)
  unwind.jump_to_frame(1)

  local vl = get_virtual_lines(buf)
  assert_true(vl ~= nil, "extmarks exist for available file")

  -- Remove file from disk
  os.remove(dynamic_file)
  unwind.refresh_availability()

  local vl_missing = get_virtual_lines(buf)
  assert_true(vl_missing == nil, "extmarks cleared for now-unavailable file")

  -- Recreate file on disk
  local f2 = io.open(dynamic_file, "w")
  f2:write("print('recreated')\n")
  f2:close()

  unwind.refresh_availability()
  local vl_restored = get_virtual_lines(buf)
  assert_true(vl_restored ~= nil, "extmarks restored after file reappeared")

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  pcall(os.remove, dynamic_file)
  unwind.clear()
end

isolated.cleanup()
test_env.cleanup_all()

print("All decoration sync spec tests PASSED successfully!")
