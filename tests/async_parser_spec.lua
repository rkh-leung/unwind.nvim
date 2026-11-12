-- tests/async_parser_spec.lua
-- Unit tests for async parser absolute path lookup and cancellation

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local async_parser = require("unwind.async.parser")
local uv = vim.uv or vim.loop

local function assert_eq(a, b, msg)
  if a ~= b then
    error(string.format("Assertion failed: expected %s, got %s. %s", vim.inspect(b), vim.inspect(a), msg or ""))
  end
end

local function assert_true(cond, msg)
  if not cond then
    error("Assertion failed: " .. (msg or "expected true"))
  end
end

print("--> [Async Parser Spec 1] Absolute worker path exists and is resolved...")
local worker_file = vim.api.nvim_get_runtime_file("lua/unwind/parser_worker.lua", false)[1]
assert_true(worker_file ~= nil and worker_file ~= "", "parser_worker.lua must be resolvable via runtime")
assert_true(uv.fs_stat(worker_file) ~= nil, "Resolved worker file must exist on disk")

print("--> [Async Parser Spec 2] Normal async parse execution...")
local trace = [[
File "test_async.py", line 12, in sample_func
  execute()
]]

local parsed = false
local result_frames = nil
async_parser.parse_async(trace, function(frames, err)
  assert_eq(err, nil)
  result_frames = frames
  parsed = true
end)

local start = uv.hrtime()
while not parsed and (uv.hrtime() - start) < 5e9 do
  vim.wait(20, function() return parsed end)
end

assert_true(parsed, "Async parse must complete successfully")
assert_true(#result_frames > 0, "Frames must be parsed")
assert_eq(result_frames[1].file, "test_async.py")

print("--> [Async Parser Spec 3] Cancel helper aborts active job...")
-- Launch a parse job and cancel it immediately
local called = false
local handle = async_parser.parse_async(trace, function()
  called = true
end)

assert_true(handle ~= nil, "Handle must be returned from parse_async")
local cancelled = async_parser.cancel(handle)
assert_true(cancelled, "Job must report as cancelled")

-- Also test M.cancel() with no argument returns false when no job active
local cancel_empty = async_parser.cancel()
assert_true(not cancel_empty, "M.cancel() when no active job must return false")

print("All async parser spec tests PASSED successfully!")
