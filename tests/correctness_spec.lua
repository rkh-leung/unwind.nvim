-- tests/correctness_spec.lua
-- Tests for correctness fixes:
-- 1. Multi-root session caching
-- 2. Sidebar reopen callbacks
-- 3. Frame deletion selection correctness
-- 4. Monotonic event listener IDs

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
local events = require("unwind.events")

print("--> [Correctness 1] Multi-root session caching...")
do
  local root_a = "/tmp/test_project_root_a"
  local root_b = "/tmp/test_project_root_b"

  vim.fn.mkdir(root_a, "p")
  vim.fn.mkdir(root_b, "p")

  local sess_a = sessions.create({ root = root_a, name = "Sess_A", transient = false, frames = { { file = "a.py", line = 1 } } })
  sessions.save(root_a, { sess_a })

  local sess_b = sessions.create({ root = root_b, name = "Sess_B", transient = false, frames = { { file = "b.py", line = 2 } } })
  sessions.save(root_b, { sess_b })

  unwind.ensure_sessions_loaded(root_a)
  assert_eq(#unwind.state.sessions, 1, "root_a has 1 session")
  assert_eq(unwind.state.sessions[1].name, "Sess_A", "root_a session name")

  unwind.ensure_sessions_loaded(root_a)
  assert_eq(unwind.state.sessions[1].name, "Sess_A", "root_a session name cached")

  unwind.ensure_sessions_loaded(root_b)
  assert_eq(#unwind.state.sessions, 1, "root_b has 1 session")
  assert_eq(unwind.state.sessions[1].name, "Sess_B", "root_b session name")

  unwind.ensure_sessions_loaded(root_a)
  assert_eq(#unwind.state.sessions, 1, "root_a has 1 session again")
  assert_eq(unwind.state.sessions[1].name, "Sess_A", "root_a session name after switching back")

  local fa, _ = sessions.storage_path(root_a)
  local fb, _ = sessions.storage_path(root_b)
  pcall(os.remove, fa)
  pcall(os.remove, fb)
end

print("--> [Correctness 2] Frame deletion selection correctness...")
do
  unwind.clear()
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local raw_frames = {
    { file = "a.py", line = 10, method = "A" },
    { file = "b.py", line = 20, method = "B" },
    { file = "c.py", line = 30, method = "C" },
  }
  local session = sessions.create({ root = cwd, transient = true, frames = raw_frames })
  unwind.activate_session(session)

  unwind.jump_to_frame(2)
  assert_eq(session.active_index, 2, "B is active at index 2")
  local frame_b = session.frames[2]

  unwind.delete_frame_from_session(session, 1)

  assert_eq(#session.frames, 2, "session has 2 frames left")
  assert_eq(session.frames[1], frame_b, "frame B shifted to index 1")
  assert_eq(session.active_index, 1, "B remains active at index 1")

  unwind.delete_frame_from_session(session, 1)
  assert_eq(#session.frames, 1, "1 frame left")
  assert_eq(session.frames[1].method, "C", "C is remaining frame")
  assert_eq(session.active_index, 1, "C is now active")

  local filter_frames = {
    { file = "vendor/bundle/lib.py", line = 1, method = "v1" },
    { file = "src/main.py", line = 2, method = "app1" },
    { file = "src/main.py", line = 3, method = "app2" },
  }
  local s_filter = sessions.create({ root = cwd, transient = true, frames = filter_frames, filter_enabled = true })
  unwind.activate_session(s_filter)
  assert_eq(#s_filter.frames, 2, "2 non-vendor frames active")

  unwind.jump_to_frame(2)
  assert_eq(s_filter.active_index, 2, "app2 active")
  local app2_frame = s_filter.frames[2]

  unwind.delete_frame_from_session(s_filter, 1)
  assert_eq(#s_filter.frames, 1, "1 filtered frame left")
  assert_eq(s_filter.frames[1], app2_frame, "app2 survives")
  assert_eq(s_filter.active_index, 1, "app2 is active at index 1")

  sidebar.hide()
  unwind.clear()
end

print("--> [Correctness 3] Sidebar reopen callbacks completeness...")
do
  unwind.clear()
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local session = sessions.create({
    root = cwd,
    transient = true,
    frames = {
      { file = "x.py", line = 1, method = "X" },
      { file = "y.py", line = 2, method = "Y" },
    },
  })
  unwind.activate_session(session)
  assert_true(sidebar.is_open(), "sidebar is open initially")

  sidebar.hide()
  assert_true(not sidebar.is_open(), "sidebar is closed")

  unwind.toggle_sidebar()
  assert_true(sidebar.is_open(), "sidebar reopened with toggle_sidebar")

  local buf = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find("unwind://sidebar") then
      buf = b
      break
    end
  end
  assert_true(buf ~= nil, "sidebar buffer found")
  local maps = vim.api.nvim_buf_get_keymap(buf, "n")
  local map_keys = {}
  for _, m in ipairs(maps) do
    map_keys[m.lhs] = true
  end

  assert_true(map_keys["<CR>"] or map_keys["\r"], "Enter keymap present")
  assert_true(map_keys["d"], "d keymap present")
  assert_true(map_keys["J"], "J keymap present")
  assert_true(map_keys["K"], "K keymap present")
  assert_true(map_keys["e"], "e keymap present")
  assert_true(map_keys["s"], "s keymap present")
  assert_true(map_keys["r"], "r keymap present")
  assert_true(map_keys["q"], "q keymap present")

  sidebar.hide()
  unwind.clear()
end

print("--> [Correctness 4] Monotonic event listener IDs...")
do
  events.clear_all()
  local order = {}
  local id_a = events.on("ev", function() table.insert(order, "A") end)
  local id_b = events.on("ev", function() table.insert(order, "B") end)
  assert_true(id_a ~= id_b, "id_a and id_b are distinct")

  events.off("ev", id_a)
  local id_c = events.on("ev", function() table.insert(order, "C") end)

  assert_true(id_b ~= id_c, "id_b and id_c are distinct")
  assert_true(id_a ~= id_c, "id_a and id_c are distinct")

  events.emit("ev")
  assert_eq(#order, 2, "B and C fired")
  assert_eq(order[1], "B", "B fired first")
  assert_eq(order[2], "C", "C fired second")

  events.clear_all()
end

print("All correctness tests PASSED successfully!")
