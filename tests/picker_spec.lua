-- tests/picker_spec.lua
-- Tests for pluggable fuzzy finder, unwind.get_frames(), custom picker hooks, and vim.ui.select fallback

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
local picker = require("unwind.picker")
local hooks = require("unwind.hooks")

local test_root = vim.fs.normalize(vim.fn.getcwd())

print("--> [Picker Spec 1] unwind.get_frames() returns normalized items and respects filter_enabled vs { all = true }...")
do
  unwind.clear()

  local raw = {
    { file = "app/service.lua", line = 15, method = "process_data", note = "Entry point" },
    { file = "vendor/bundle/lib.lua", line = 100, method = "vendor_helper", external = true },
    { file = "app/handler.lua", line = 45, method = "handle_req" },
  }
  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = raw,
    filter_enabled = true,
  })
  unwind.activate_session(s)

  -- When filter_enabled is true, default get_frames() returns only visible frames (2 frames)
  local visible_items = unwind.get_frames()
  assert_eq(#visible_items, 2, "visible items count matches filtered frames")
  assert_eq(visible_items[1].method, "process_data")
  assert_eq(visible_items[1].index, 1)
  assert_eq(visible_items[1].note, "Entry point")
  assert_true(visible_items[1].uid ~= nil, "item has uid")
  assert_true(visible_items[1].display:find("process_data") ~= nil, "display contains method")
  assert_true(visible_items[1].display:find("app/service.lua:15") ~= nil, "display contains file:line")
  assert_true(visible_items[1].display:find("[Entry point]") ~= nil, "display contains note")

  assert_eq(visible_items[2].method, "handle_req")
  assert_eq(visible_items[2].index, 2)

  -- With opts.all = true, returns all raw frames including vendor frames (3 frames)
  local all_items = unwind.get_frames({ all = true })
  assert_eq(#all_items, 3, "all items returns all 3 raw frames")
  assert_eq(all_items[2].method, "vendor_helper", "vendor frame included")

  unwind.clear()
end

print("--> [Picker Spec 2] Custom config.picker function receives items and invokes actions.jump(item)...")
do
  unwind.clear()

  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 1, method = "f1" },
      { file = "tests/fixtures/dummy.txt", line = 2, method = "f2" },
    },
  })
  unwind.activate_session(s)
  assert_eq(s.active_index, 1, "starts at frame 1")

  local picker_called = false
  local received_items = nil
  local received_actions = nil

  unwind.setup({
    picker = function(items, actions)
      picker_called = true
      received_items = items
      received_actions = actions
      -- Jump to item 2
      actions.jump(items[2])
    end,
  })

  unwind.search()

  assert_true(picker_called, "custom picker function was invoked")
  assert_eq(#received_items, 2, "received 2 items")
  assert_true(received_actions.jump ~= nil, "jump action provided")
  assert_eq(s.active_index, 2, "jump action successfully jumped to frame 2")

  unwind.setup({ picker = "auto" })
  unwind.clear()
end

print("--> [Picker Spec 3] unwind.register_picker() receives items and executes actions...")
do
  unwind.clear()

  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 10, method = "start" },
      { file = "tests/fixtures/dummy.txt", line = 20, method = "target" },
    },
  })
  unwind.activate_session(s)
  assert_eq(s.active_index, 1, "starts at frame 1")

  local hook_called = false
  unwind.register_picker("test_hook_picker", function(items, actions)
    hook_called = true
    actions.jump(items[2])
  end)

  unwind.search({ picker = "test_hook_picker" })
  assert_true(hook_called, "registered picker was called")
  assert_eq(s.active_index, 2, "jumped to frame 2 via registered picker")

  unwind.unregister_picker("test_hook_picker")
  unwind.clear()
end

print("--> [Picker Spec 4] vim.ui.select fallback selects and jumps to chosen frame cleanly...")
do
  unwind.clear()
  unwind.setup({ picker = "select" })

  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 1, method = "one" },
      { file = "tests/fixtures/dummy.txt", line = 2, method = "two" },
    },
  })
  unwind.activate_session(s)
  assert_eq(s.active_index, 1, "active_index 1")

  local orig_select = vim.ui.select
  local select_called = false
  local select_prompt = nil

  vim.ui.select = function(items, opts, on_choice)
    select_called = true
    select_prompt = opts.prompt
    -- User selects item 2
    on_choice(items[2])
  end

  unwind.search()

  assert_true(select_called, "vim.ui.select was called")
  assert_eq(select_prompt, "Unwind Call Trace", "prompt was Unwind Call Trace")
  assert_eq(s.active_index, 2, "active_index updated to 2 after select choice")

  vim.ui.select = orig_select
  unwind.setup({ picker = "auto" })
  unwind.clear()
end

print("All picker_spec tests PASSED successfully!")
