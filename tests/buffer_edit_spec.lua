-- tests/buffer_edit_spec.lua
-- Tests for mini.files-style editable call-trace buffer, '=' synchronization,
-- visual block moves, dd/p, yyp duplication, manual line addition, and unsynced changes guard.

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
local buffer_mod = require("unwind.buffer")

local test_root = vim.fs.normalize(vim.fn.getcwd())

print("--> [Buffer Edit Spec 1] Visual block move marks buffer modified without mutating session until '='...")
do
  unwind.clear()
  unwind.setup({ confirm_sync = false })

  local trace = [[
  File "tests/fixtures/dummy.txt", line 10, in method_one
  File "tests/fixtures/dummy.txt", line 20, in method_two
  File "tests/fixtures/dummy.txt", line 30, in method_three
]]
  local s = unwind.ingest(trace)
  assert_true(s ~= nil, "session ingested")
  assert_eq(#s.raw_frames, 3, "3 raw frames")

  sidebar.open(s)
  local buf = buffer_mod.get_or_create()
  assert_true(vim.api.nvim_buf_is_valid(buf), "unwind buffer valid")
  assert_eq(vim.bo[buf].modified, false, "buffer initially not modified")

  -- Move line 1 to after line 2 using Vim command: :1move 2
  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[1move 2]])
  end)

  assert_eq(vim.bo[buf].modified, true, "buffer is marked modified after move")
  assert_eq(s.raw_frames[1].method, "method_one", "session.raw_frames[1] unchanged before sync")
  assert_eq(s.raw_frames[2].method, "method_two", "session.raw_frames[2] unchanged before sync")

  -- Synchronize via '=' (buffer.synchronize)
  local sync_ok = buffer_mod.synchronize(buf, s, { skip_confirm = true })
  assert_true(sync_ok, "synchronize succeeded")

  assert_eq(vim.bo[buf].modified, false, "buffer modified reset to false after sync")
  assert_eq(#s.raw_frames, 3, "raw frames count maintained")
  assert_eq(s.raw_frames[1].method, "method_two", "method_two is now first")
  assert_eq(s.raw_frames[2].method, "method_one", "method_one is now second")
  assert_eq(s.raw_frames[3].method, "method_three", "method_three is third")

  sidebar.hide()
  unwind.clear()
end

print("--> [Buffer Edit Spec 2] 'dd' + 'p' reorders frames on '='; 'yyp' duplicates frame with distinct uid & note...")
do
  unwind.clear()
  unwind.setup({ confirm_sync = false })

  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 11, method = "func1", note = "Original Note" },
      { file = "tests/fixtures/dummy.txt", line = 22, method = "func2" },
    },
  })
  unwind.activate_session(s)
  local orig_uid_1 = s.raw_frames[1].uid
  assert_true(orig_uid_1 ~= nil, "frame 1 has uid")

  local buf = buffer_mod.get_or_create()
  local side_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if sidebar.is_sidebar_window(w) then
      side_win = w
      break
    end
  end
  assert_true(side_win ~= nil, "sidebar window open")

  -- Duplicate line 1 using yyp
  vim.api.nvim_win_set_cursor(side_win, { 1, 0 })
  vim.api.nvim_win_call(side_win, function()
    vim.cmd([[execute "normal yyp"]])
  end)

  assert_eq(vim.bo[buf].modified, true, "buffer modified after yyp")
  local line_count = vim.api.nvim_buf_line_count(buf)
  assert_eq(line_count, 3, "buffer now has 3 lines")

  -- Synchronize
  buffer_mod.synchronize(buf, s, { skip_confirm = true })
  assert_eq(#s.raw_frames, 3, "session now has 3 raw frames")
  assert_eq(s.raw_frames[1].method, "func1")
  assert_eq(s.raw_frames[2].method, "func1", "duplicated frame inserted")

  -- Duplicated frame must have distinct UID
  assert_true(s.raw_frames[2].uid ~= s.raw_frames[1].uid, "duplicated frame has fresh uid")
  assert_eq(s.raw_frames[2].uid ~= orig_uid_1, true, "duplicated frame has distinct uid from original")

  -- Annotating duplicate does NOT mutate original
  s.raw_frames[2].note = "Duplicate Note"
  assert_eq(s.raw_frames[1].note, "Original Note", "original frame note is preserved independently")

  sidebar.hide()
  unwind.clear()
end

print("--> [Buffer Edit Spec 3] Opening a blank line ('o') and writing 'app/foo.lua:25' parses and inserts manual frame on '='...")
do
  unwind.clear()
  unwind.setup({ confirm_sync = false })

  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 1, method = "first" },
      { file = "tests/fixtures/dummy.txt", line = 2, method = "second" },
    },
  })
  unwind.activate_session(s)
  local buf = buffer_mod.get_or_create()

  -- Insert a line between frame 1 and 2: "app/foo.lua:25"
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  table.insert(lines, 2, "app/foo.lua:25")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = true

  buffer_mod.synchronize(buf, s, { skip_confirm = true })
  assert_eq(#s.raw_frames, 3, "3 frames after manual add")
  assert_eq(s.raw_frames[2].file, "app/foo.lua", "new frame parsed file")
  assert_eq(s.raw_frames[2].line, 25, "new frame parsed line")
  assert_eq(s.raw_frames[2].origin, "manual", "new frame marked origin manual")

  sidebar.hide()
  unwind.clear()
end

print("--> [Buffer Edit Spec 4] Closing ('q') with unsynchronized changes prompts confirm...")
do
  unwind.clear()
  unwind.setup({ confirm_sync = true })

  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 1, method = "m1" },
      { file = "tests/fixtures/dummy.txt", line = 2, method = "m2" },
    },
  })
  unwind.activate_session(s)
  local buf = buffer_mod.get_or_create()
  local side_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if sidebar.is_sidebar_window(w) then
      side_win = w
      break
    end
  end

  -- Modify buffer: delete line 1
  vim.api.nvim_win_set_cursor(side_win, { 1, 0 })
  vim.api.nvim_win_call(side_win, function()
    vim.cmd([[execute "normal dd"]])
  end)
  assert_eq(buffer_mod.has_unsynced_changes(buf, s), true, "has unsynced changes")

  -- Case A: Prompt confirm returns 3 (Cancel) -> window and edits remain open
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function() return 3 end

  vim.api.nvim_win_call(side_win, function()
    vim.cmd([[execute "normal q"]])
  end)
  assert_true(sidebar.is_open(), "sidebar stays open after Cancel")
  assert_eq(vim.bo[buf].modified, true, "buffer remains modified")
  assert_eq(#s.raw_frames, 2, "session raw_frames untouched")

  -- Case B: Prompt confirm returns 2 (No) -> discard edits and close
  vim.fn.confirm = function() return 2 end
  vim.api.nvim_win_call(side_win, function()
    vim.cmd([[execute "normal q"]])
  end)
  assert_true(not sidebar.is_open(), "sidebar closed after No (discard)")
  assert_eq(vim.bo[buf].modified, false, "buffer marked unmodified")
  assert_eq(#s.raw_frames, 2, "session raw_frames untouched")

  -- Case C: Prompt confirm returns 1 (Yes) -> sync and close
  sidebar.open(s)
  side_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if sidebar.is_sidebar_window(w) then
      side_win = w
      break
    end
  end
  vim.api.nvim_win_set_cursor(side_win, { 1, 0 })
  vim.api.nvim_win_call(side_win, function()
    vim.cmd([[execute "normal dd"]])
  end)

  vim.fn.confirm = function() return 1 end
  vim.api.nvim_win_call(side_win, function()
    vim.cmd([[execute "normal q"]])
  end)
  assert_true(not sidebar.is_open(), "sidebar closed after Yes (sync)")
  assert_eq(#s.raw_frames, 1, "session frame synced (deleted frame removed)")

  vim.fn.confirm = orig_confirm
  unwind.clear()
end

print("--> [Buffer Edit Spec 5] '<BS>' resets unsynchronized buffer edits back to current session state...")
do
  unwind.clear()
  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 10 },
      { file = "tests/fixtures/dummy.txt", line = 20 },
    },
  })
  unwind.activate_session(s)
  local buf = buffer_mod.get_or_create()
  local side_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if sidebar.is_sidebar_window(w) then
      side_win = w
      break
    end
  end

  -- Mess up buffer lines
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "garbage line 1", "garbage line 2" })
  vim.bo[buf].modified = true
  assert_true(buffer_mod.has_unsynced_changes(buf, s), "buffer is dirty")

  -- Press <BS>
  vim.api.nvim_win_call(side_win, function()
    vim.cmd([[execute "normal \<BS>"]])
  end)

  assert_eq(vim.bo[buf].modified, false, "buffer modified is reset")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(#lines, 2, "canonical 2 frames restored")
  assert_true(lines[1]:find("dummy.txt:10") ~= nil, "frame 1 restored")
  assert_true(lines[2]:find("dummy.txt:20") ~= nil, "frame 2 restored")

  sidebar.hide()
  unwind.clear()
end

print("--> [Buffer Edit Spec 6] :UnwindAddBefore and :UnwindAddAfter insert relative to active_index...")
do
  unwind.clear()
  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 10, method = "first" },
      { file = "tests/fixtures/dummy.txt", line = 20, method = "second" },
    },
  })
  unwind.activate_session(s)
  unwind.jump_to_frame(1)
  assert_eq(s.active_index, 1, "frame 1 active")

  -- Open a named file buffer as current window
  local dummy_buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(dummy_buf, test_root .. "/inserted.lua")
  vim.api.nvim_buf_set_lines(dummy_buf, 0, -1, false, { "line 1", "line 2", "line 3" })
  vim.api.nvim_set_current_buf(dummy_buf)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })

  -- :UnwindAddAfter -> inserts after active frame (at index 2)
  unwind.add_current_location({ position = "after_active" })
  assert_eq(#s.raw_frames, 3, "3 frames after add_after")
  assert_eq(s.raw_frames[2].file, "inserted.lua", "inserted at index 2")
  assert_eq(s.active_index, 2, "active index jumped to newly inserted frame")

  -- :UnwindAddBefore -> inserts before active frame (at index 2)
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  unwind.add_current_location({ position = "before_active" })
  assert_eq(#s.raw_frames, 4, "4 frames after add_before")
  assert_eq(s.raw_frames[2].line, 3, "inserted before active frame")
  assert_eq(s.active_index, 2, "active index jumped to newly inserted frame")

  pcall(vim.api.nvim_buf_delete, dummy_buf, { force = true })
  sidebar.hide()
  unwind.clear()
end

print("--> [Buffer Edit Spec 7] Editing and syncing ('=') while session.filter_enabled == true preserves hidden vendor frames...")
do
  unwind.clear()
  unwind.setup({ confirm_sync = false })

  local raw = {
    { file = "tests/fixtures/dummy.txt", line = 1, method = "user1" },
    { file = "vendor/bundle/gem.rb", line = 50, method = "vendor_hidden", external = true },
    { file = "tests/fixtures/dummy.txt", line = 2, method = "user2" },
  }
  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = raw,
    filter_enabled = true,
  })
  unwind.activate_session(s)

  assert_eq(#s.frames, 2, "2 visible frames in session.frames")
  assert_eq(#s.raw_frames, 3, "3 frames in raw_frames")

  local buf = buffer_mod.get_or_create()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert_eq(#lines, 2, "only 2 visible frames in buffer")

  -- Swap the 2 visible lines
  lines[1], lines[2] = lines[2], lines[1]
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = true

  buffer_mod.synchronize(buf, s, { skip_confirm = true })

  -- Check raw_frames: vendor frame must be preserved!
  assert_eq(#s.raw_frames, 3, "vendor frame was preserved in raw_frames")
  assert_eq(s.raw_frames[1].method, "user2", "user2 is now first")
  assert_eq(s.raw_frames[2].method, "vendor_hidden", "vendor_hidden preserved in relative position")
  assert_eq(s.raw_frames[3].method, "user1", "user1 is now third")

  sidebar.hide()
  unwind.clear()
end

print("--> [Buffer Edit Spec 8] :UnwindBuffer in main editor window: navigation updates active_index...")
do
  unwind.clear()
  unwind.setup({ confirm_sync = false })

  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 10, method = "nav_a" },
      { file = "tests/fixtures/dummy.txt", line = 20, method = "nav_b" },
      { file = "tests/fixtures/dummy.txt", line = 30, method = "nav_c" },
    },
  })
  unwind.activate_session(s)

  local buf = buffer_mod.get_or_create()
  local cur_win = vim.api.nvim_get_current_win()

  vim.api.nvim_set_current_buf(buf)
  buffer_mod.configure_window(cur_win)
  buffer_mod.render(s, buf, cur_win)

  assert_true(sidebar.is_sidebar_window(cur_win), "is_sidebar_window true for :UnwindBuffer window")

  local navigation = require("unwind.navigation")
  vim.api.nvim_win_set_cursor(cur_win, { 2, 0 })
  navigation.jump_to_frame(s, 2)
  assert_eq(s.active_index, 2, "active_index updated to 2 after navigation")

  vim.api.nvim_win_set_cursor(cur_win, { 3, 0 })
  navigation.jump_to_frame(s, 3)
  assert_eq(s.active_index, 3, "active_index updated to 3 after navigation")

  unwind.clear()
end

print("--> [Buffer Edit Spec 9] :UnwindBuffer o/O keymaps insert correctly relative to cursor line...")
do
  unwind.clear()
  unwind.setup({ confirm_sync = false })

  local s = sessions.create({
    root = test_root,
    transient = true,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 10, method = "orig_a" },
      { file = "tests/fixtures/dummy.txt", line = 20, method = "orig_b" },
    },
  })
  unwind.activate_session(s)

  local buf = buffer_mod.get_or_create()
  local cur_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_buf(buf)
  buffer_mod.render(s, buf, cur_win)

  -- Create a named file buffer (buftype == "") in a split so ensure_source_window & add_current_location accept it
  local src_buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(src_buf, test_root .. "/inserted_spec9.lua")
  vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, { "line 1", "line 2", "line 3" })

  vim.cmd("leftabove vsplit")
  local src_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(src_win, src_buf)
  vim.api.nvim_win_set_cursor(src_win, { 2, 0 })

  -- Switch back to the unwind buffer window and invoke 'o' keymap on line 1
  vim.api.nvim_set_current_win(cur_win)
  vim.api.nvim_win_set_cursor(cur_win, { 1, 0 })
  vim.api.nvim_win_call(cur_win, function()
    vim.cmd([[execute "normal o"]])
  end)
  assert_eq(#s.raw_frames, 3, "3 frames after 'o' (insert after cursor line 1)")
  assert_eq(s.raw_frames[2].file, "inserted_spec9.lua", "inserted at index 2 after frame 1")

  -- Move cursor to line 2 in src_win and invoke 'O' keymap on line 1 of unwind buffer
  vim.api.nvim_win_set_cursor(src_win, { 3, 0 })
  vim.api.nvim_set_current_win(cur_win)
  vim.api.nvim_win_set_cursor(cur_win, { 1, 0 })
  vim.api.nvim_win_call(cur_win, function()
    vim.cmd([[execute "normal O"]])
  end)
  assert_eq(#s.raw_frames, 4, "4 frames after 'O' (insert before cursor line 1)")
  assert_eq(s.raw_frames[1].file, "inserted_spec9.lua", "inserted at index 1 before frame 1")
  assert_eq(s.raw_frames[1].line, 3, "captured line 3 from source window")

  pcall(vim.api.nvim_win_close, src_win, true)
  pcall(vim.api.nvim_buf_delete, src_buf, { force = true })

  sidebar.hide()
  unwind.setup({ confirm_sync = true })
  unwind.clear()
end

print("All buffer_edit_spec tests PASSED successfully!")
