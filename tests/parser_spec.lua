-- tests/parser_spec.lua
-- Tests for unwind.nvim parser, collector, and integrations

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

local parser = require("unwind.parser")
local collector = require("unwind.collector")

local function read_fixture(filepath)
  local f = io.open(filepath, "r")
  if not f then
    error("could not open fixture: " .. filepath)
  end
  local content = f:read("*all")
  f:close()
  return content
end

print("--> Testing parser with raygun_sample.txt...")
local raygun_text = read_fixture("tests/fixtures/raygun_sample.txt")
local raygun_frames = parser.parse(raygun_text)
assert_true(#raygun_frames >= 5, "raygun should parse at least 5 frames, got " .. #raygun_frames)
assert_eq(raygun_frames[1].line, 104, "frame 1 line")
assert_true(raygun_frames[1].file:find("CheckoutController%.cs") ~= nil, "frame 1 file")
assert_true(raygun_frames[1].method:find("ProcessPayment") ~= nil, "frame 1 method")
assert_eq(raygun_frames[4].line, 55, "frame 4 line")
assert_true(raygun_frames[4].file:find("UserService%.java") ~= nil, "frame 4 java file")

print("--> Testing parser with rust_panic.txt...")
local rust_text = read_fixture("tests/fixtures/rust_panic.txt")
local rust_frames = parser.parse(rust_text)
assert_true(#rust_frames >= 5, "rust should parse at least 5 frames, got " .. #rust_frames)
-- Find the compiler style --> src/main.rs:45:12
local found_arrow = false
for _, f in ipairs(rust_frames) do
  if f.file:find("src/main%.rs") and f.line == 45 and f.col == 12 then
    found_arrow = true
    break
  end
end
assert_true(found_arrow, "should parse rust compiler arrow frame")

print("--> Testing parser with node_trace.txt...")
local node_text = read_fixture("tests/fixtures/node_trace.txt")
local node_frames = parser.parse(node_text)
assert_true(#node_frames >= 4, "node should parse at least 4 frames, got " .. #node_frames)
assert_eq(node_frames[1].line, 45, "node frame 1 line")
assert_eq(node_frames[1].col, 12, "node frame 1 col")
assert_true(node_frames[1].file:find("session%.js") ~= nil, "node frame 1 file")
assert_true(node_frames[1].method:find("AuthService%.validateSession") ~= nil, "node frame 1 method")

print("--> Testing Python traceback parsing...")
local python_text = [[
Traceback (most recent call last):
  File "/var/task/app/main.py", line 45, in execute_request
    response = handler()
  File "lib/handler.py", line 12, in handler
    raise ValueError("invalid")
]]
local py_frames = parser.parse(python_text)
assert_eq(#py_frames, 2, "python frames count")
assert_eq(py_frames[1].line, 45, "python frame 1 line")
assert_eq(py_frames[1].method, "execute_request", "python frame 1 method")

print("--> Testing Ruby stacktrace parsing...")
local ruby_text = read_fixture("tests/fixtures/ruby_trace.txt")
local ruby_frames = parser.parse(ruby_text)
assert_eq(#ruby_frames, 5, "ruby frames count")
assert_eq(ruby_frames[1].line, 25, "ruby frame 1 line")
assert_true(ruby_frames[1].file:find("users_controller%.rb") ~= nil, "ruby frame 1 file")
assert_eq(ruby_frames[1].method, "show", "ruby frame 1 method")
assert_eq(ruby_frames[2].line, 42, "ruby frame 2 line")
assert_eq(ruby_frames[2].method, "find_user", "ruby frame 2 method")
assert_eq(ruby_frames[3].line, 18, "ruby frame 3 line")
assert_eq(ruby_frames[3].method, "authenticate!", "ruby frame 3 method")
assert_eq(ruby_frames[4].method, "<main>", "ruby frame 4 method")
assert_eq(ruby_frames[5].method, "<top (required)>", "ruby frame 5 method")

print("--> Testing generic fallback...")
local generic_text = "some/module/worker.go:99:4: something went wrong"
local gen_frames = parser.parse(generic_text)
assert_true(#gen_frames >= 1, "generic fallback frame parsed")
assert_eq(gen_frames[1].line, 99, "generic line")
assert_eq(gen_frames[1].col, 4, "generic col")

print("--> Testing collector deduplication...")
local collected = collector.collect(raygun_frames)
assert_true(#collected.files > 0, "collected files should not be empty")
-- First file implicated is CheckoutController.cs
assert_true(collected.files[1].file:find("CheckoutController%.cs") ~= nil, "first file order preserved")
assert_eq(collected.files[1].primary_line, 104, "primary fault line matches highest/first fault line")

print("All parser & collector unit tests PASSED successfully!")
