-- tests/regression_fixes_spec.lua
-- Comprehensive regression test suite covering code review and evaluation checklist:
-- 1. Persistence round-trip with remote path mapping & re-resolution on restart (P0)
-- 2. Sidebar callback isolation across session switches (P1)
-- 3. Filter toggle persistence failure and rollback (P1)
-- 4. Ruby external-to-local metadata refresh and vendor filtering (P1)
-- 5. Quickfix export filename accuracy with remapped paths (P1)
-- 6. Generic path parsing with spaces and log prefixes (P2)
-- 7. Workspace switching isolation (P2)
-- 8. Missing file restoration and refresh (P2)

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
local state = require("unwind.state")
local parser = require("unwind.parser")
local persistence = require("unwind.persistence")
local session_actions = require("unwind.session_actions")

local test_root = vim.fs.normalize(vim.fn.getcwd())

print("--> [Checklist 1/8] Persistence round-trip with remote path mapping (P0)...")
do
  unwind.clear()
  -- Use an isolated temporary directory for test
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir .. "/local_src", "p")
  local dummy_local = temp_dir .. "/local_src/worker.py"
  local f = io.open(dummy_local, "w")
  f:write("def work(): pass\n")
  f:close()

  unwind.setup({
    path_mappings = {
      ["/app/"] = temp_dir .. "/local_src/",
    },
  })

  -- Ingest remote container trace
  local trace = 'File "/app/worker.py", line 1, in work\n'
  unwind.ingest(trace)
  local session = state.current()
  assert_true(session ~= nil, "session created")
  assert_eq(session.raw_frames[1].path, "/app/worker.py", "raw frame stores original remote path")

  -- Save session
  local list = {}
  local ok_save = sessions.save_working(session, "Remote Mapped Session", list, test_root)
  assert_true(ok_save, "saved remote mapped session")

  -- Simulate restart: clear in-memory state and reload persisted sessions from disk
  unwind.clear()
  local reloaded_list = persistence.load(test_root)
  assert_eq(#reloaded_list, 1, "1 session reloaded from disk")
  local reloaded_session = reloaded_list[1]

  -- In raw loaded state from disk, runtime resolved_path is not serialized
  assert_eq(reloaded_session.raw_frames[1].resolved_path, nil, "resolved_path is nil on freshly loaded session")

  -- Now activate session: rebuild_derived and ensure_frames_resolved must re-resolve /app/worker.py to local worker.py
  unwind.activate_session(reloaded_session)
  assert_true(reloaded_session.frames[1] ~= nil, "frame collected")
  assert_eq(reloaded_session.frames[1].resolved_path, dummy_local, "re-resolved to local file")
  assert_eq(reloaded_session.files[1].available, true, "file marked available on disk")

  -- Jump to frame and assert correct local buffer is opened
  local cur_buf = vim.api.nvim_get_current_buf()
  local cur_buf_name = vim.fs.normalize(vim.api.nvim_buf_get_name(cur_buf))
  -- On macOS /var is often a symlink to /private/var, so canonicalize realpath for comparison
  local real_cur = (vim.uv or vim.loop).fs_realpath(cur_buf_name) or cur_buf_name
  local real_expected = (vim.uv or vim.loop).fs_realpath(dummy_local) or dummy_local
  assert_eq(vim.fs.normalize(real_cur), vim.fs.normalize(real_expected), "navigated to local source file")

  -- Cleanup
  sessions.delete(reloaded_session, list, test_root)
  pcall(vim.fn.delete, temp_dir, "rf")
  unwind.setup({ path_mappings = {} })
  unwind.clear()
end

print("--> [Checklist 2/8] Sidebar callback isolation across session switches (P1)...")
do
  unwind.clear()
  -- Open session A with sidebar visible
  local sess_a = sessions.create({
    root = test_root,
    name = "Session A",
    transient = false,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 1, method = "A1" },
      { file = "tests/fixtures/dummy.txt", line = 1, method = "A2" },
    },
  })
  unwind.activate_session(sess_a)
  assert_true(sidebar.is_open(), "sidebar opened with session A")
  assert_eq(#sess_a.frames, 2, "session A has 2 frames")

  -- Ingest session B via text ingestion
  local sess_b = unwind.ingest([[
  File "tests/fixtures/dummy.txt", line 1, in B1
  File "tests/fixtures/dummy.txt", line 1, in B2
  File "tests/fixtures/dummy.txt", line 1, in B3
]])
  assert_true(sess_b ~= nil, "session B ingested")
  assert_eq(state.current(), sess_b, "session B is active")
  assert_eq(#sess_b.frames, 3, "session B has 3 frames")

  -- Delete frame 2 from sidebar
  -- Because sidebar callbacks now query current active session, deleting frame 2 affects session B, NOT session A!
  local side_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if sidebar.is_sidebar_window(w) then
      side_win = w
      break
    end
  end
  assert_true(side_win ~= nil, "sidebar window found")

  -- Position cursor on frame 2 (line 4 in buffer)
  vim.api.nvim_win_set_cursor(side_win, { 4, 0 })
  vim.api.nvim_win_call(side_win, function()
    vim.cmd([[execute "normal d"]])
  end)

  -- Session B should have 2 frames left, and Session A must remain untouched with 2 frames
  assert_eq(#sess_b.frames, 2, "session B frame was deleted")
  assert_eq(#sess_a.raw_frames, 2, "session A raw_frames remained untouched")

  sidebar.hide()
  unwind.clear()
end

print("--> [Checklist 3/8] Filter toggle persistence failure and rollback (P1)...")
do
  unwind.clear()
  local sess = sessions.create({
    root = test_root,
    name = "Saved Filter Session",
    transient = false,
    filter_enabled = false,
    frames = {
      { file = "tests/fixtures/dummy.txt", line = 1, method = "m1" },
    },
  })
  local saved_list = { sess }

  -- Mock sessions.save to return false (persistence failure)
  local orig_save = sessions.save
  sessions.save = function() return false end

  state.set_current(sess)
  assert_eq(sess.filter_enabled, false, "filter initially disabled")

  -- Attempt to toggle filter
  session_actions.toggle_filter(sess, saved_list, unwind.config)

  -- Because save failed, filter_enabled must be rolled back to false
  assert_eq(sess.filter_enabled, false, "filter_enabled rolled back to false on save failure")

  -- Restore sessions.save
  sessions.save = orig_save
  unwind.clear()
end

print("--> [Checklist 4/8] Ruby external-to-local metadata refresh and vendor filtering (P1)...")
do
  unwind.clear()
  local ruby_frame = {
    path = "lib/active_support.rb",
    file = "lib/active_support.rb",
    resolved_path = "/usr/local/bundle/gems/activesupport/lib/active_support.rb",
    line = 10,
    external = true,
    source_kind = "ruby_gem",
    resolution = { gem = "activesupport" },
  }
  local sess = sessions.create({
    root = test_root,
    frames = { ruby_frame },
    transient = true,
  })
  unwind.activate_session(sess)
  assert_eq(sess.frames[1].external, true, "initially external = true")

  -- Now simulate resolver re-evaluating: run refresh_availability
  -- Since lib/active_support.rb does not resolve to an external gem on this machine,
  -- refresh_availability must clear external, source_kind, and resolution to nil
  session_actions.refresh_availability(sess, unwind.config)
  assert_eq(sess.frames[1].external, nil, "external metadata cleared to nil")
  assert_eq(sess.frames[1].source_kind, nil, "source_kind metadata cleared to nil")
  assert_eq(sess.frames[1].resolution, nil, "resolution metadata cleared to nil")

  unwind.clear()
end

print("--> [Checklist 5/8] Quickfix export with remapped and missing paths (P1)...")
do
  unwind.clear()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local expected_file = temp_dir .. "/actual_file.lua"
  local f = io.open(expected_file, "w")
  f:write("return true\n")
  f:close()

  unwind.setup({
    path_mappings = {
      ["/ci/build/"] = temp_dir .. "/",
    },
  })

  local sess = sessions.create({
    root = test_root,
    frames = {
      { file = "/ci/build/actual_file.lua", line = 1, col = 2, method = "dummy_fn" },
      { file = "/ci/build/nonexistent_xyz.py", line = 50, col = 1, method = nil, raw_line = nil },
    },
    transient = true,
  })
  unwind.activate_session(sess)

  unwind.quickfix()
  local qflist = vim.fn.getqflist()
  assert_eq(#qflist, 2, "2 quickfix entries")

  -- First entry is valid and remapped to expected_file (assert exact filename, not method fallback)
  assert_eq(qflist[1].valid, 1, "first item is valid")
  local actual_fname = vim.fs.normalize(vim.fn.bufname(qflist[1].bufnr))
  assert_eq(actual_fname, expected_file, "first item points exactly to resolved filename")
  assert_eq(qflist[1].lnum, 1, "first item line number")
  assert_eq(qflist[1].col, 2, "first item column")

  -- Second entry is missing with nil method and raw_line: must not crash, have valid = 0 and [N/A] in text
  assert_eq(qflist[2].valid, 0, "missing item marked valid = 0")
  assert_true(qflist[2].text:find("%[N/A%]") ~= nil, "missing item text includes [N/A]")

  pcall(vim.fn.delete, temp_dir, "rf")
  unwind.setup({ path_mappings = {} })
  unwind.clear()
end

print("--> [Checklist 6/8] Generic path parsing with spaces and log prefixes (P2)...")
do
  local log_line = "[ERROR] /Users/Jane Doe/project/main.go:50:10: runtime error"
  local frames = parser.parse(log_line)
  assert_eq(#frames, 1, "parsed 1 frame from generic log line")
  assert_eq(frames[1].file, "/Users/Jane Doe/project/main.go", "captured entire path with spaces")
  assert_eq(frames[1].line, 50, "line is 50")
  assert_eq(frames[1].col, 10, "col is 10")
end

print("--> [Checklist 7/8] Workspace switching, activation, and navigation isolation (P2)...")
do
  unwind.clear()
  local root_a = vim.fn.tempname()
  local root_b = vim.fn.tempname()
  vim.fn.mkdir(root_a, "p")
  vim.fn.mkdir(root_b, "p")

  local file_a = root_a .. "/main_a.py"
  local f_a = io.open(file_a, "w")
  f_a:write("print('project a')\n")
  f_a:close()

  local file_b = root_b .. "/main_b.py"
  local f_b = io.open(file_b, "w")
  f_b:write("print('project b')\n")
  f_b:close()

  local sess_a = sessions.create({
    root = root_a,
    name = "Project A Session",
    transient = false,
    frames = { { file = "main_a.py", line = 1, method = "fn_a" } },
  })
  sessions.save(root_a, { sess_a })

  local sess_b = sessions.create({
    root = root_b,
    name = "Project B Session",
    transient = false,
    frames = { { file = "main_b.py", line = 1, method = "fn_b" } },
  })
  sessions.save(root_b, { sess_b })

  -- Activate session A
  unwind.activate_session(sess_a)
  assert_eq(state.get_root(), root_a, "active root is root_a")
  assert_eq(sess_a.frames[1].resolved_path, file_a, "session A resolved to file_a")
  local cur_buf_a = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  assert_eq(cur_buf_a, file_a, "navigation opened file_a")

  -- Switch active project to session B
  unwind.activate_session(sess_b)
  assert_eq(state.get_root(), root_b, "active root switched to root_b")
  assert_eq(sess_b.frames[1].resolved_path, file_b, "session B resolved to file_b")
  local cur_buf_b = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  assert_eq(cur_buf_b, file_b, "navigation opened file_b")

  -- Mutate session B (e.g. toggle filter) and verify session A's disk persistence is unaffected
  unwind.toggle_filter()
  local loaded_a = persistence.load(root_a)
  local loaded_b = persistence.load(root_b)

  assert_eq(#loaded_a, 1, "root_a still has 1 session")
  assert_eq(loaded_a[1].name, "Project A Session", "root_a session intact")
  assert_eq(loaded_a[1].filter_enabled, false, "root_a session filter remained false")

  assert_eq(#loaded_b, 1, "root_b has 1 session")
  assert_eq(loaded_b[1].name, "Project B Session", "root_b session name")
  assert_eq(loaded_b[1].filter_enabled, true, "root_b session filter toggled to true")

  local fa, _ = sessions.storage_path(root_a)
  local fb, _ = sessions.storage_path(root_b)
  pcall(os.remove, fa)
  pcall(os.remove, fb)
  pcall(vim.fn.delete, root_a, "rf")
  pcall(vim.fn.delete, root_b, "rf")
  unwind.clear()
end

print("--> [Checklist 8/8] Missing file restoration and navigation refresh (P2)...")
do
  unwind.clear()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local dyn_file = temp_dir .. "/dynamic_restore_test.py"

  local sess = sessions.create({
    root = temp_dir,
    frames = { { file = "dynamic_restore_test.py", line = 1, method = "test_fn" } },
    transient = true,
  })
  unwind.activate_session(sess)
  assert_eq(sess.files[1].available, false, "initially missing file is unavailable")

  -- Restore file on disk
  local f = io.open(dyn_file, "w")
  f:write("def test_fn(): pass\n")
  f:close()

  -- Refresh availability
  unwind.refresh_availability()
  assert_eq(sess.files[1].available, true, "file becomes available after refresh")

  -- Jump to frame
  local selected, opened = unwind.jump_to_frame(1)
  assert_true(selected and opened, "navigation succeeds now that file is restored")
  local cur_buf = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  assert_eq(cur_buf, dyn_file, "opened restored file in source window")

  pcall(vim.fn.delete, temp_dir, "rf")
  unwind.clear()
end

print("--> [Follow-up 1] Prompt save session uses captured saved_sessions rather than mutated state.raw.sessions...")
do
  unwind.clear()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")

  local sess = sessions.create({
    root = temp_dir,
    name = nil,
    transient = true,
    frames = { { file = "temp.lua", line = 1 } },
  })
  unwind.activate_session(sess)

  -- Mock ui.prompt_input so it defers and changes state.raw.sessions before callback executes
  local orig_prompt = require("unwind.ui").prompt_input
  local captured_cb = nil
  require("unwind.ui").prompt_input = function(prompt, default_val, cb)
    captured_cb = cb
  end

  unwind.prompt_save_session(sess)
  assert_true(captured_cb ~= nil, "prompt_input was called")

  -- Mutate global state.raw.sessions before executing the deferred callback
  local poisoned_list = {}
  state.raw.sessions = poisoned_list

  -- Execute deferred callback
  captured_cb("Captured Session")

  -- Verify session was saved to temp_dir and was placed into the captured collection, not the poisoned list
  local loaded = persistence.load(temp_dir)
  assert_eq(#loaded, 1, "session persisted to disk")
  assert_eq(loaded[1].name, "Captured Session", "persisted session name")
  assert_eq(#poisoned_list, 0, "poisoned list was not used")

  -- Restore ui.prompt_input
  require("unwind.ui").prompt_input = orig_prompt
  pcall(vim.fn.delete, temp_dir, "rf")
  unwind.clear()
end

print("--> [Follow-up 2] toggle_filter identity precedence: IDs over duplicate names & legacy sessions...")
do
  unwind.clear()
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")

  -- Create two distinct sessions sharing the same name but different IDs
  local sess_1 = sessions.create({
    id = "id_alpha",
    root = temp_dir,
    name = "Duplicate Name",
    transient = false,
    filter_enabled = false,
    frames = { { file = "a.lua", line = 1 } },
  })
  local sess_2 = sessions.create({
    id = "id_beta",
    root = temp_dir,
    name = "Duplicate Name",
    transient = false,
    filter_enabled = false,
    frames = { { file = "b.lua", line = 2 } },
  })
  local saved_list = { sess_1, sess_2 }
  sessions.save(temp_dir, saved_list)

  -- Toggle filter on sess_1 (id_alpha)
  session_actions.toggle_filter(sess_1, saved_list, unwind.config)

  -- sess_1 must have filter_enabled = true; sess_2 must remain false despite having the same name
  assert_eq(sess_1.filter_enabled, true, "sess_1 filter toggled to true")
  assert_eq(sess_2.filter_enabled, false, "sess_2 filter remained false because ID differs")

  -- Test legacy sessions without ID: fallback to matching name
  local legacy_saved = {
    { name = "Legacy A", filter_enabled = false, saved = true, root = temp_dir, raw_frames = { { file = "l.lua", line = 1 } } }
  }
  local legacy_target = { name = "Legacy A", filter_enabled = false, saved = true, root = temp_dir, raw_frames = { { file = "l.lua", line = 1 } } }
  session_actions.toggle_filter(legacy_target, legacy_saved, unwind.config)
  assert_eq(legacy_target.filter_enabled, true, "legacy target toggled")
  assert_eq(legacy_saved[1].filter_enabled, true, "legacy saved matched by name fallback")

  pcall(vim.fn.delete, temp_dir, "rf")
  unwind.clear()
end

print("All regression checklist tests PASSED successfully!")
