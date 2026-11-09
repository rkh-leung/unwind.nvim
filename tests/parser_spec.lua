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

print("--> Testing unwind.ingest_file...")
local unwind = require("unwind")
unwind.clear()
unwind.ingest_file("tests/fixtures/node_trace.txt")
assert_true(#unwind.state.frames >= 4, "ingest_file loaded node frames")
assert_eq(unwind.state.active_index, 1, "active frame index reset to 1")

print("--> Testing unwind.unwind dispatcher...")
unwind.clear()
unwind.unwind("tests/fixtures/ruby_trace.txt")
assert_eq(#unwind.state.frames, 5, "unwind(filepath) loaded ruby frames")

print("--> Testing interactive input scratchpad ui.open_input...")
local ui = require("unwind.ui")
local submitted_text = nil
ui.open_input(function(text)
  submitted_text = text
end)

-- Find the created buffer and populate it
local bufs = vim.api.nvim_list_bufs()
local test_buf = nil
for _, b in ipairs(bufs) do
  if vim.bo[b].buftype == "nofile" and vim.bo[b].bufhidden == "wipe" then
    test_buf = b
    break
  end
end
assert_true(test_buf ~= nil, "input buffer created")
vim.api.nvim_buf_set_lines(test_buf, 0, -1, false, { "File \"test.py\", line 10, in do_work" })
-- Trigger the submit command
vim.api.nvim_buf_call(test_buf, function()
  vim.cmd("Write")
end)
assert_true(submitted_text ~= nil, "scratchpad on_submit was invoked")
assert_true(submitted_text:find("do_work") ~= nil, "scratchpad content correctly submitted")

print("--> Testing vendor filtering and file navigation...")
local vendor_trace = [[
core/app/presenters/feed.rb:10:in `render'
/apps/powershop/shared/bundle/ruby/3.3.0/gems/activesupport-8.1.3.1/lib/active_support/callbacks.rb:27:in `run'
/apps/powershop/shared/bundle/ruby/3.3.0/gems/activesupport-8.1.3.1/lib/active_support/callbacks.rb:50:in `compile'
/usr/lib/x86_64-linux-gnu/ruby/3.3.0/delegate.rb:15:in `method_missing'
app/models/brand.rb:5:in `name'
]]

unwind.clear()
unwind.ingest(vendor_trace)
assert_eq(#unwind.state.frames, 5, "total raw frames without filter")
assert_eq(#unwind.state.files, 4, "total files without filter")

-- Check vendor tagging
assert_true(not unwind.state.files[1].is_vendor, "feed.rb should not be vendor")
assert_true(unwind.state.files[2].is_vendor, "activesupport should be tagged vendor")
assert_true(unwind.state.files[3].is_vendor, "delegate.rb should be tagged vendor")
assert_true(not unwind.state.files[4].is_vendor, "brand.rb should not be vendor")

-- Test next_file / prev_file cycling
unwind.jump_to_file(1)
assert_eq(unwind.state.active_file_index, 1, "active file index 1")
unwind.next_file()
assert_eq(unwind.state.active_file_index, 2, "next_file moved to index 2")
unwind.prev_file()
assert_eq(unwind.state.active_file_index, 1, "prev_file moved back to index 1")

-- Test toggle_filter
unwind.toggle_filter()
assert_true(unwind.state.filter_enabled, "filter enabled")
assert_eq(#unwind.state.files, 2, "filtered files should only have 2 workspace files")
assert_eq(unwind.state.files[1].file, "core/app/presenters/feed.rb", "filtered file 1")
assert_eq(unwind.state.files[2].file, "app/models/brand.rb", "filtered file 2")

-- Toggle filter off
unwind.toggle_filter()
assert_true(not unwind.state.filter_enabled, "filter disabled")
assert_eq(#unwind.state.files, 4, "all files restored after toggling filter off")

print("--> Testing decorator formatting without anonymous()...")
local decorator = require("unwind.decorator")
local decor_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(decor_buf, 0, -1, false, { "line 1", "line 2" })
local ext_id = decorator.render(decor_buf, 1, 1, "", "core/test.rb", 5)
assert_true(ext_id ~= nil, "decorator extmark rendered")
local extmarks = vim.api.nvim_buf_get_extmarks(decor_buf, decorator.get_namespace(), 0, -1, { details = true })
assert_true(#extmarks > 0, "extmarks exist in buffer")
local header = extmarks[1][4].virt_lines[1][1][1]
assert_true(header:find("anonymous") == nil, "header should not contain anonymous, got: " .. header)
assert_true(header:find("Frame #1/5") ~= nil, "header should contain Frame #1/5, got: " .. header)

print("All parser, collector & integration unit tests PASSED successfully!")
