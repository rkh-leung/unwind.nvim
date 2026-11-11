-- tests/session_spec.lua
-- Tests for Generalized Session Model, Mutation API, and Persistence

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
local env_setup = test_env.setup_isolated_env()
local sessions = require("unwind.sessions")
local persistence = require("unwind.persistence")
local unwind = require("unwind")
local events = require("unwind.events")
local test_root = test_env.create_temp_dir("session_spec_root_")
local storage_file = sessions.storage_path(test_root)

print("--> [Session Spec 1] Creates an empty unnamed session...")
do
  local s = sessions.create({ root = test_root })
  assert_true(s.id ~= nil, "session has unique id")
  assert_eq(s.name, nil, "session is unnamed")
  assert_true(s.transient, "session is transient")
  assert_eq(#s.raw_frames, 0, "session starts with 0 frames")
  assert_eq(s.active_index, 0, "active_index is 0 for empty session")
end

print("--> [Session Spec 2] Unnamed session isn't persisted to disk...")
do
  pcall(os.remove, storage_file)
  local s = sessions.create({ root = test_root })
  sessions.add_frame(s, { file = "foo.lua", line = 10, origin = "manual" })

  local loaded = sessions.load(test_root)
  assert_eq(#loaded, 0, "no sessions should be on disk for unnamed session")
end

print("--> [Session Spec 3] Named session is persisted and mutations persist immediately...")
do
  pcall(os.remove, storage_file)
  local list = {}
  local s = sessions.create({ root = test_root })
  sessions.add_frame(s, { file = "step1.lua", line = 1, origin = "manual" })

  local ok_save, err = sessions.save_working(s, "Test Named Session", list, test_root)
  assert_true(ok_save, "saved session: " .. tostring(err))
  assert_eq(s.name, "Test Named Session", "session has name")
  assert_true(not s.transient, "saved session is not transient")
  assert_true(s.saved, "session is marked saved")

  -- Check disk
  local loaded1 = sessions.load(test_root)
  assert_eq(#loaded1, 1, "1 session on disk")
  assert_eq(#loaded1[1].raw_frames, 1, "1 frame on disk")

  -- Add frame to named session -> immediately writes to disk
  sessions.add_frame(s, { file = "step2.lua", line = 2, origin = "manual" }, nil, list)
  local loaded2 = sessions.load(test_root)
  assert_eq(#loaded2[1].raw_frames, 2, "2 frames on disk after mutation")

  -- Move frame
  sessions.move_frame(s, 2, 1, list)
  local loaded3 = sessions.load(test_root)
  assert_eq(loaded3[1].raw_frames[1].file, "step2.lua", "moved frame persisted to disk")

  -- Update frame
  sessions.update_frame(s, 1, { file = "updated.lua", line = 99, origin = "manual" }, list)
  local loaded4 = sessions.load(test_root)
  assert_eq(loaded4[1].raw_frames[1].file, "updated.lua", "updated frame persisted to disk")
  assert_eq(loaded4[1].raw_frames[1].line, 99, "updated line persisted to disk")

  -- Remove frame
  sessions.remove_frame(s, 2, list)
  local loaded5 = sessions.load(test_root)
  assert_eq(#loaded5[1].raw_frames, 1, "frame removal persisted to disk")

  -- Deleting last frame leaves valid empty session
  sessions.remove_frame(s, 1, list)
  local loaded6 = sessions.load(test_root)
  assert_eq(#loaded6[1].raw_frames, 0, "session on disk has 0 frames")
  assert_eq(s.active_index, 0, "session active_index is 0")

  -- Cleanup
  sessions.delete(s, list, test_root)
end

print("--> [Session Spec 4] Event emissions on session lifecycle...")
do
  local created_fired = false
  local changed_fired = false
  local deleted_fired = false

  local id1 = events.on("session_created", function() created_fired = true end)
  local id2 = events.on("session_changed", function() changed_fired = true end)
  local id3 = events.on("session_deleted", function() deleted_fired = true end)

  local s = sessions.create({ root = test_root })
  assert_true(created_fired, "session_created event fired")

  sessions.add_frame(s, { file = "a.lua", line = 1 })
  assert_true(changed_fired, "session_changed event fired")

  local list = { s }
  s.saved = true
  s.name = "Event Test"
  sessions.delete(s, list, test_root)
  assert_true(deleted_fired, "session_deleted event fired")

  events.off("session_created", id1)
  events.off("session_changed", id2)
  events.off("session_deleted", id3)
end

print("--> [Session Spec 5] Moving frames preserves active selection correctly...")
do
  local s = sessions.create({ root = test_root })
  sessions.add_frame(s, { file = "f1.lua", line = 1 })
  sessions.add_frame(s, { file = "f2.lua", line = 2 })
  sessions.add_frame(s, { file = "f3.lua", line = 3 })

  -- active_index = 1 (f1)
  s.active_index = 1
  sessions.move_frame(s, 1, 2)
  -- f1 moved to index 2, active_index should track it to index 2
  assert_eq(s.active_index, 2, "active_index tracked moving frame down")

  -- Move non-active frame 3 to 1
  sessions.move_frame(s, 3, 1)
  -- items: was [f2, f1, f3] -> move f3 to 1 -> [f3, f2, f1]
  -- active was f1 at index 2, now at index 3
  assert_eq(s.active_index, 3, "active_index adjusted when other frame moved before it")
end

print("--> [Session Spec 6] Mutation failure handling and rollback in add_current_location...")
do
  local unwind = require("unwind")
  local persistence = require("unwind.persistence")
  local state = require("unwind.state")

  unwind.clear()
  local dummy_buf = vim.api.nvim_create_buf(true, false)
  local file_path = test_root .. "/dummy_add.lua"
  vim.api.nvim_buf_set_name(dummy_buf, file_path)
  vim.api.nvim_buf_set_lines(dummy_buf, 0, -1, false, { "line 1", "line 2", "line 3" })
  vim.api.nvim_win_set_buf(0, dummy_buf)
  vim.api.nvim_win_set_cursor(0, { 2, 1 })

  -- Setup a saved named session
  state.set_root(test_root)
  local list = state.ensure_sessions_loaded(test_root)
  local s = sessions.create({ root = test_root, name = "Persisted Add Test" })
  sessions.save_working(s, "Persisted Add Test", list, test_root)
  state.set_current(s)

  assert_eq(#s.raw_frames, 0)
  assert_eq(s.active_index, 0)

  -- Simulate persistence failure
  local orig_save = persistence.save
  persistence.save = function() return false end

  local err_notified = false
  local info_notified = false
  local orig_notify = vim.notify
  vim.notify = function(msg, lvl)
    if lvl == vim.log.levels.ERROR then
      err_notified = true
    elseif lvl == vim.log.levels.INFO then
      info_notified = true
    end
  end

  unwind.add_current_location()

  vim.notify = orig_notify
  persistence.save = orig_save

  assert_true(err_notified, "error notification emitted on failed add")
  assert_true(not info_notified, "no success message emitted on failed add")
  assert_eq(#s.raw_frames, 0, "raw frames rolled back to 0")
  assert_eq(s.active_index, 0, "active_index not advanced")

  -- Restore persistence and retry
  unwind.add_current_location()
  assert_eq(#s.raw_frames, 1, "successfully added frame after persistence restored")
  assert_eq(s.active_index, 1, "active_index updated after successful add")

  pcall(vim.api.nvim_buf_delete, dummy_buf, { force = true })
  unwind.clear()
end

print("--> [Session Spec 7] Transactional persistence size & failure rollback...")
do
  unwind.clear()
  local s = sessions.create({
    root = test_root,
    name = "Size Tx Session",
    transient = false,
    saved = true,
    frames = {
      { file = "app/file1.lua", line = 10 },
    },
  })

  -- Uncommitted in-memory session reports estimated size
  local est_sz, est_exact = sessions.get_size(s)
  assert_true(est_sz > 0, "estimated size computed")
  assert_eq(est_exact, false, "uncommitted session reports is_exact = false")

  -- Save to disk
  local saved_list = { s }
  local ok = sessions.save(test_root, saved_list)
  assert_true(ok, "session saved to disk")

  local commit_sz, commit_exact = sessions.get_size(s)
  assert_true(commit_exact, "saved session reports is_exact = true")
  assert_eq(s._persisted_size, commit_sz, "_persisted_size committed to session")

  -- Now simulate persistence failure during mutation
  local orig_save = persistence.save
  persistence.save = function() return false end

  local ok_add = sessions.add_frame(s, { file = "app/file2.lua", line = 20 }, nil, saved_list)
  assert_eq(ok_add, false, "mutation fails when disk write fails")
  assert_eq(s._persisted_size, commit_sz, "_persisted_size preserved after failed save")

  persistence.save = orig_save
  unwind.clear()
end

print("--> [Session Spec 8] Dynamic project-frame counting across pattern and root changes...")
do
  unwind.clear()
  local s = sessions.create({
    root = test_root,
    name = "Dynamic Project Frame Session",
    transient = true,
    frames = {
      { file = "app/code.lua", line = 1 },
      { file = "vendor/bundle/lib.lua", line = 2 },
      { file = "custom_ignore/code.lua", line = 3 },
    },
  })

  -- Default patterns: custom_ignore is inside workspace and not in default ignore list
  local count1 = sessions.get_project_frame_count(s, test_root, { "vendor/bundle/" })
  assert_eq(count1, 2, "app/code.lua and custom_ignore/code.lua are project frames")

  -- Change ignore_patterns to include custom_ignore/
  local count2 = sessions.get_project_frame_count(s, test_root, { "vendor/bundle/", "custom_ignore/" })
  assert_eq(count2, 1, "immediately reflects updated patterns without stale caching")

  -- Frame with explicit external=true
  table.insert(s.raw_frames, { file = "app/external.lua", line = 4, external = true })
  local count3 = sessions.get_project_frame_count(s, test_root, { "vendor/bundle/", "custom_ignore/" })
  assert_eq(count3, 1, "external=true frame not counted as project")

  unwind.clear()
end

env_setup.cleanup()
test_env.cleanup_all()

print("All session spec tests PASSED successfully!")
