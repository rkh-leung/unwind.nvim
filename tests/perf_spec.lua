-- tests/perf_spec.lua
-- Deterministic performance-regression assertions (call counts, cache behavior).
-- Does NOT assert wall-clock timing.

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

local cwd = vim.fs.normalize(vim.fn.getcwd())

print("--> [Perf Spec 1] Events: listener IDs remain unique after removals...")
do
  local events = require("unwind.events")
  events.clear_all()

  local received = {}
  local id1 = events.on("test_event", function(arg) table.insert(received, "id1:" .. arg) end)
  local id2 = events.on("test_event", function(arg) table.insert(received, "id2:" .. arg) end)

  assert_true(id1 ~= id2, "id1 and id2 must be distinct")

  events.off("test_event", id1)

  local id3 = events.on("test_event", function(arg) table.insert(received, "id3:" .. arg) end)
  assert_true(id2 ~= id3, "id2 and id3 must have distinct IDs")
  assert_true(id1 ~= id3, "id3 must not reuse old id1 directly in a way that collides")

  events.emit("test_event", "hello")
  assert_eq(#received, 2, "2 listeners received event")
  assert_eq(received[1], "id2:hello", "id2 received event")
  assert_eq(received[2], "id3:hello", "id3 received event")

  events.clear_all()
end

print("--> [Perf Spec 2] Ruby resolver: repeated identical path resolution...")
do
  local ok_ruby, ruby_resolver = pcall(require, "unwind.resolvers.ruby")
  if ok_ruby and ruby_resolver and ruby_resolver.resolve then
    local env_mod = require("unwind.resolvers.ruby.environment")
    local original_probe = env_mod.probe_ruby
    local probe_count = 0
    env_mod.probe_ruby = function(...)
      probe_count = probe_count + 1
      return original_probe(...)
    end

    local path = "/gems/rack-2.2.8/lib/rack.rb"
    for _ = 1, 100 do
      ruby_resolver.resolve(path, { root = cwd })
    end

    assert_true(probe_count <= 1, string.format("probe_ruby was called %d times, expected at most 1", probe_count))
    env_mod.probe_ruby = original_probe
  end
end

print("--> [Perf Spec 3] Ruby refresh: environment probe occurs at most once across 1000 frames...")
do
  local unwind = require("unwind")
  local sessions = require("unwind.sessions")
  local env_mod = require("unwind.resolvers.ruby.environment")
  local original_probe = env_mod.probe_ruby
  local probe_count = 0
  env_mod.probe_ruby = function(...)
    probe_count = probe_count + 1
    return original_probe(...)
  end

  local raw_frames = {}
  for i = 1, 1000 do
    local path = string.format("/gems/rack-2.2.8/lib/rack_%d.rb", i % 10)
    table.insert(raw_frames, { file = path, path = path, line = i, col = 1 })
  end

  local session = sessions.create({ root = cwd, transient = true, frames = raw_frames })
  unwind.state.active_session = session

  unwind.refresh_availability()

  assert_true(probe_count <= 1, string.format("Ruby refresh probed %d times, expected at most 1", probe_count))
  env_mod.probe_ruby = original_probe
  unwind.clear()
end

print("--> [Perf Spec 4] Transient mutation does not invoke vim.deepcopy...")
do
  local sessions = require("unwind.sessions")
  local orig_deepcopy = vim.deepcopy
  local deepcopy_called = 0
  vim.deepcopy = function(...)
    deepcopy_called = deepcopy_called + 1
    return orig_deepcopy(...)
  end

  local session = sessions.create({ root = cwd, transient = true, frames = { { file = "a.py", line = 1 } } })
  sessions.add_frame(session, { file = "b.py", line = 2 })
  sessions.update_frame(session, 1, { file = "a2.py", line = 1 })
  sessions.move_frame(session, 1, 2)
  sessions.remove_frame(session, 2)

  assert_eq(deepcopy_called, 0, "vim.deepcopy was not called during transient mutations")
  vim.deepcopy = orig_deepcopy
end

print("--> [Perf Spec 5] Collector: filter disabled does not allocate new frame table...")
do
  local collector = require("unwind.collector")
  local frames = { { file = "a.py", line = 1 } }
  local res = collector.collect(frames, { root = cwd, filter_vendor = false })
  assert_true(res.frames == frames, "frame table reused directly when filtering is disabled")
end

print("--> [Perf Spec 6] Frame actions use raw_index directly...")
do
  local unwind = require("unwind")
  local sessions = require("unwind.sessions")
  local raw_frames = {
    { file = "a.py", line = 1 },
    { file = "b.py", line = 2 },
  }
  local session = sessions.create({ root = cwd, transient = true, frames = raw_frames })
  unwind.activate_session(session)

  assert_eq(session.frames[1].raw_index, 1)
  assert_eq(session.frames[2].raw_index, 2)

  unwind.move_frame_in_session(session, 1, 2)
  assert_eq(session.raw_frames[1].line, 2)
  assert_eq(session.raw_frames[2].line, 1)

  unwind.clear()
end

print("All deterministic perf spec tests PASSED successfully!")
