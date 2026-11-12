-- tests/edge_case_parser_spec.lua
-- Unit tests for edge-case, malformed, and huge stacktraces

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local parser = require("unwind.parser")
local async_parser = require("unwind.async.parser")

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: expected %s, got %s. %s", vim.inspect(b), vim.inspect(a), msg or ""))
  end
end

print("--> [Edge Case Spec 1] Empty and whitespace inputs...")
assert_eq(#parser.parse(""), 0)
assert_eq(#parser.parse("   \n\n  \t  \n"), 0)

print("--> [Edge Case Spec 2] Malformed lines with missing colons or line numbers...")
local malformed = [[
Traceback (most recent call last):
  File "broken_path", line , in <module>
  Random console log line with no stack structure
  File "", line 10, in foo
  /not/a/frame.rb:not_a_line:in `bar'
]]
local frames = parser.parse(malformed)
-- Ensure parser gracefully processes and does not crash
assert_eq(type(frames), "table")

print("--> [Edge Case Spec 3] Huge stacktrace parsing stability...")
local lines = {}
for i = 1, 5000 do
  table.insert(lines, string.format('  File "app/worker_%d.py", line %d, in task_%d', i, i, i))
  table.insert(lines, string.format('    execute_step_%d()', i))
end
local huge_trace = table.concat(lines, "\n")
local parsed_huge = parser.parse(huge_trace, { max_frames = 1000 })
assert_eq(#parsed_huge, 1000, "capped at max_frames")

print("--> [Edge Case Spec 4] Async parser handles empty & malformed gracefully...")
local done = false
async_parser.parse_async(malformed, function(async_frames, err)
  assert_eq(err, nil)
  assert_eq(type(async_frames), "table")
  done = true
end)

local uv = vim.uv or vim.loop
local start_t = uv.hrtime()
while not done and (uv.hrtime() - start_t) < 5e9 do
  vim.wait(50, function() return done end)
end

if not done then
  error("Async parser timed out")
end

print("All edge case parser spec tests PASSED successfully!")
