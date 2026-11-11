-- tests/collector_spec.lua
-- Tests for collector grouping, deduplication, raw_index assignment, and vendor filtering

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

local collector = require("unwind.collector")
local cwd = vim.fs.normalize(vim.fn.getcwd())

print("--> [Collector Spec 1] Raw index assignment and preservation under filtering...")
do
  local frames = {
    { file = "vendor/bundle/a.rb", line = 1 },
    { file = "app/models/user.rb", line = 10 },
    { file = "app/models/user.rb", line = 25 },
    { file = "vendor/bundle/b.rb", line = 5 },
  }

  local res_unfiltered = collector.collect(frames, { root = cwd, filter_vendor = false })
  assert_eq(#res_unfiltered.frames, 4, "4 frames unfiltered")
  assert_eq(res_unfiltered.frames[1].raw_index, 1)
  assert_eq(res_unfiltered.frames[2].raw_index, 2)
  assert_eq(res_unfiltered.frames[3].raw_index, 3)
  assert_eq(res_unfiltered.frames[4].raw_index, 4)

  local res_filtered = collector.collect(frames, { root = cwd, filter_vendor = true })
  assert_eq(#res_filtered.frames, 2, "2 frames filtered")
  assert_eq(res_filtered.frames[1].raw_index, 2, "app frame 1 retains raw_index 2")
  assert_eq(res_filtered.frames[2].raw_index, 3, "app frame 2 retains raw_index 3")
end

print("--> [Collector Spec 2] No duplicate array allocation when filtering disabled...")
do
  local frames = {
    { file = "a.py", line = 1 },
    { file = "b.py", line = 2 },
  }
  local res = collector.collect(frames, { root = cwd, filter_vendor = false })
  assert_true(res.frames == frames, "res.frames references original frames array when filtering disabled")
end

print("All collector spec tests PASSED successfully!")
