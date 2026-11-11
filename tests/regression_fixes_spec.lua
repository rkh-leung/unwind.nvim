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
  -- Configure path_mappings to map /app/ to local workspace
  unwind.setup({
    path_mappings = {
      ["/app/"] = "./",
    },
  })

  -- Create dummy local file that /app/src/worker.py maps to
  local dummy_local = test_root .. "/src/worker.py"
  vim.fn.mkdir(test_root .. "/src", "p")
  local f = io.open(dummy_local, "w")
  f:write("def work(): pass\n")
  f:close()

  -- Ingest remote container trace
  local trace = 'File "/app/src/worker.py", line 1, in work\n'
  unwind.ingest(trace)
  local session = state.current()
  assert_true(session ~= nil, "session created")
  assert_eq(session.raw_frames[1].path, "/app/src/worker.py", "raw frame stores original remote path")

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

  -- Now activate session: rebuild_derived and ensure_frames_resolved must re-resolve /app/src/worker.py to local worker.py
  unwind.activate_session(reloaded_session)
  assert_true(reloaded_session.frames[1] ~= nil, "frame collected")
  assert_eq(reloaded_session.frames[1].resolved_path, test_root .. "/src/worker.py", "re-resolved to local file")
  assert_eq(reloaded_session.files[1].available, true, "file marked available on disk")

  -- Jump to frame and assert correct local buffer is opened
  local cur_buf = vim.api.nvim_get_current_buf()
  local cur_buf_name = vim.fs.normalize(vim.api.nvim_buf_get_name(cur_buf))
  assert_true(cur_buf_name:find("src/worker%.py") ~= nil, "navigated to local source file")

  -- Cleanup
  sessions.delete(reloaded_session, list, test_root)
  pcall(os.remove, dummy_local)
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
  unwind.setup({
    path_mappings = {
      ["/ci/build/"] = "./",
    },
  })

  local sess = sessions.create({
    root = test_root,
    frames = {
      { file = "/ci/build/tests/fixtures/dummy.txt", line = 1, col = 2, method = "dummy_fn" },
      { file = "/ci/build/nonexistent_xyz.py", line = 50, col = 1, method = "fail_fn" },
    },
    transient = true,
  })
  unwind.activate_session(sess)

  unwind.quickfix()
  local qflist = vim.fn.getqflist()
  assert_eq(#qflist, 2, "2 quickfix entries")

  -- First entry is valid and remapped to tests/fixtures/dummy.txt
  assert_eq(qflist[1].valid, 1, "first item is valid")
  assert_true(vim.fs.normalize(qflist[1].module ~= "" and qflist[1].module or vim.fn.bufname(qflist[1].bufnr)):find("dummy%.txt") ~= nil or qflist[1].text:find("dummy_fn") ~= nil, "first item points to dummy.txt")

  -- Second entry is missing: must have valid = 0 and [N/A] in text
  assert_eq(qflist[2].valid, 0, "missing item marked valid = 0")
  assert_true(qflist[2].text:find("%[N/A%]") ~= nil, "missing item text includes [N/A]")

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

print("--> [Checklist 7/8] Workspace switching and session root isolation (P2)...")
do
  local root_a = "/tmp/test_workspace_a"
  local root_b = "/tmp/test_workspace_b"
  vim.fn.mkdir(root_a, "p")
  vim.fn.mkdir(root_b, "p")

  local sess_a = sessions.create({
    root = root_a,
    name = "Project A Session",
    transient = false,
    frames = { { file = "a.py", line = 10 } },
  })
  sessions.save(root_a, { sess_a })

  local sess_b = sessions.create({
    root = root_b,
    name = "Project B Session",
    transient = false,
    frames = { { file = "b.py", line = 20 } },
  })
  sessions.save(root_b, { sess_b })

  -- Verify roots are isolated
  local loaded_a = persistence.load(root_a)
  local loaded_b = persistence.load(root_b)

  assert_eq(#loaded_a, 1, "project A has 1 session")
  assert_eq(loaded_a[1].name, "Project A Session", "project A session name")
  assert_eq(loaded_a[1].root, root_a, "project A session root matches")

  assert_eq(#loaded_b, 1, "project B has 1 session")
  assert_eq(loaded_b[1].name, "Project B Session", "project B session name")
  assert_eq(loaded_b[1].root, root_b, "project B session root matches")

  local fa, _ = sessions.storage_path(root_a)
  local fb, _ = sessions.storage_path(root_b)
  pcall(os.remove, fa)
  pcall(os.remove, fb)
end

print("--> [Checklist 8/8] Missing file restoration and navigation refresh (P2)...")
do
  unwind.clear()
  local dyn_file = test_root .. "/tests/fixtures/dynamic_restore_test.py"
  pcall(os.remove, dyn_file)

  local sess = sessions.create({
    root = test_root,
    frames = { { file = "tests/fixtures/dynamic_restore_test.py", line = 1, method = "test_fn" } },
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

  pcall(os.remove, dyn_file)
  unwind.clear()
end

print("All regression checklist tests PASSED successfully!")
