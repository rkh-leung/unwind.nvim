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
  File "script.py", line 1, in <module>
    items = [x for x in range(10)]
  File "script.py", line 2, in <listcomp>
    x = lambda y: y + 1
  File "script.py", line 3, in <lambda>
    pass
]]
local py_frames = parser.parse(python_text)
assert_eq(#py_frames, 5, "python frames count including <module>, <listcomp>, <lambda>")
-- In Python tracebacks, innermost/fault frame is reversed to frame 1 for crash-first navigation
assert_eq(py_frames[1].line, 3, "python frame 1 line (innermost call <lambda>)")
assert_eq(py_frames[1].method, "<lambda>", "python frame 1 method <lambda>")
assert_eq(py_frames[2].method, "<listcomp>", "python frame 2 method <listcomp>")
assert_eq(py_frames[3].method, "<module>", "python frame 3 method <module>")
assert_eq(py_frames[5].method, "execute_request", "python frame 5 method execute_request (outermost call)")

print("--> Testing path normalization & modern paths with @, +, (), spaces...")
-- Scoped packages with @
local scoped_line = "    at Object.run (/app/node_modules/@prisma/client/runtime.js:12:34)"
local scoped_frame = parser.parse(scoped_line)
assert_eq(#scoped_frame, 1, "scoped package parsed")
assert_true(scoped_frame[1].file:find("@prisma") ~= nil, "scoped path preserved")
assert_eq(scoped_frame[1].line, 12, "scoped line")
assert_eq(scoped_frame[1].col, 34, "scoped col")

-- Next.js route groups with () and +
local route_line = "    at Page (/app/src/app/(auth)/login/+page.svelte:42:8)"
local route_frame = parser.parse(route_line)
assert_eq(#route_frame, 1, "route group parsed")
assert_true(route_frame[1].file:find("%(auth%)") ~= nil, "route group parentheses preserved")
assert_true(route_frame[1].file:find("%+page") ~= nil, "route group + preserved")
assert_eq(route_frame[1].line, 42, "route line")

-- Paths with spaces
local space_line = "    at /Users/Jane Doe/dev/project/main.go:50:10"
local space_frame = parser.parse(space_line)
assert_eq(#space_frame, 1, "path with spaces parsed")
assert_true(space_frame[1].file:find("Jane Doe") ~= nil, "spaces preserved in path")
assert_eq(space_frame[1].line, 50, "space path line")

-- Relativizing cwd-prefixed path
local cwd = vim.fn.getcwd():gsub("\\", "/")
local abs_cwd_path = cwd .. "/lua/unwind/parser.lua"
local rel_norm = parser.normalize_path(abs_cwd_path)
assert_eq(rel_norm, "lua/unwind/parser.lua", "normalize_path should relativize cwd path")

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

print("--> Testing Java inner classes, lambdas, and Kotlin coroutines in Matcher 2...")
local java_inner = "    at com.example.Outer$Inner.run(Outer.java:42)"
local java_inner_frames = parser.parse(java_inner)
assert_eq(#java_inner_frames, 1, "java inner class parsed")
assert_eq(java_inner_frames[1].file, "Outer.java", "java inner file")
assert_eq(java_inner_frames[1].line, 42, "java inner line")
assert_eq(java_inner_frames[1].method, "com.example.Outer$Inner.run", "java inner method")

local java_lambda = "    at com.example.Service$$Lambda$1/0x000.run(Service.java:10)"
local java_lambda_frames = parser.parse(java_lambda)
assert_eq(#java_lambda_frames, 1, "java lambda parsed")
assert_eq(java_lambda_frames[1].file, "Service.java", "java lambda file")
assert_eq(java_lambda_frames[1].line, 10, "java lambda line")
assert_eq(java_lambda_frames[1].method, "com.example.Service$$Lambda$1/0x000.run", "java lambda method")

local kotlin_trace = "    at com.example.MainKt$main$1.invokeSuspend(Main.kt:15)"
local kotlin_frames = parser.parse(kotlin_trace)
assert_eq(#kotlin_frames, 1, "kotlin coroutine parsed")
assert_eq(kotlin_frames[1].file, "Main.kt", "kotlin file")
assert_eq(kotlin_frames[1].line, 15, "kotlin line")
assert_eq(kotlin_frames[1].method, "com.example.MainKt$main$1.invokeSuspend", "kotlin method")

print("--> Testing generic fallback & prefix word stripping...")
local generic_text = "some/module/worker.go:99:4: something went wrong"
local gen_frames = parser.parse(generic_text)
assert_true(#gen_frames >= 1, "generic fallback frame parsed")
assert_eq(gen_frames[1].line, 99, "generic line")
assert_eq(gen_frames[1].col, 4, "generic col")

-- Generic fallback should reject log timestamps like "2026-11-10 10:20:30.123:45"
local timestamp_text = "2026-11-10 10:20:30.123:45 INFO server started"
local timestamp_frames = parser.parse(timestamp_text)
assert_eq(#timestamp_frames, 0, "log timestamp should not be parsed as a file:line frame")

-- Generic matcher prefix word stripping
local prefix_frames = parser.parse([[
[ERROR] src/main.rs:45:12
failed in test/runner.py:10
]])
assert_eq(#prefix_frames, 2, "prefix lines parsed")
assert_eq(prefix_frames[1].file, "src/main.rs", "prefix frame 1 file stripped of [ERROR]")
assert_eq(prefix_frames[1].line, 45, "prefix frame 1 line")
assert_eq(prefix_frames[1].col, 12, "prefix frame 1 col")
assert_eq(prefix_frames[2].file, "test/runner.py", "prefix frame 2 file stripped of 'failed in'")
assert_eq(prefix_frames[2].line, 10, "prefix frame 2 line")

-- Windows drive letter support in Generic and Ruby matchers
print("--> Testing Windows drive letter parsing...")
-- Cargo compiler style with Windows path
local win_cargo = "  --> C:\\project\\src\\main.rs:10:5"
local win_cargo_frames = parser.parse(win_cargo)
assert_eq(#win_cargo_frames, 1, "windows cargo frame parsed")
assert_true(win_cargo_frames[1].file:find("src/main%.rs") ~= nil or win_cargo_frames[1].file:find("main%.rs") ~= nil, "windows cargo normalized")
assert_eq(win_cargo_frames[1].line, 10, "windows cargo line")
assert_eq(win_cargo_frames[1].col, 5, "windows cargo col")
assert_eq(win_cargo_frames[1].method, "compiler", "windows cargo method must be compiler")

local win_ruby = [[
C:\project\app.rb:12:in `show'
C:/project/helpers/util.rb:34:in 'format'
]]
local win_ruby_frames = parser.parse(win_ruby)
assert_eq(#win_ruby_frames, 2, "windows ruby frames count")
assert_true(win_ruby_frames[1].file:find("project/app%.rb") ~= nil or win_ruby_frames[1].file:find("app%.rb") ~= nil, "windows ruby frame 1 path normalized")
assert_eq(win_ruby_frames[1].line, 12, "windows ruby frame 1 line")
assert_eq(win_ruby_frames[1].method, "show", "windows ruby frame 1 method")
assert_eq(win_ruby_frames[2].line, 34, "windows ruby frame 2 line")
assert_eq(win_ruby_frames[2].method, "format", "windows ruby frame 2 method")

local win_generic = "C:\\workspace\\src\\server.ts:88:5"
local win_gen_frames = parser.parse(win_generic)
assert_eq(#win_gen_frames, 1, "windows generic frame parsed")
assert_true(win_gen_frames[1].file:find("src/server%.ts") ~= nil or win_gen_frames[1].file:find("server%.ts") ~= nil, "windows generic normalized")
assert_eq(win_gen_frames[1].line, 88, "windows generic line")
assert_eq(win_gen_frames[1].col, 5, "windows generic col")

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
  if vim.bo[b].buftype == "acwrite" and vim.bo[b].bufhidden == "wipe" then
    test_buf = b
    break
  end
end
assert_true(test_buf ~= nil, "input buffer created")
assert_true(vim.api.nvim_buf_get_name(test_buf):find("unwind://input") ~= nil, "input buffer named unwind://input")
vim.api.nvim_buf_set_lines(test_buf, 0, -1, false, { "File \"test.py\", line 10, in do_work" })
-- Trigger the submit command via :w and verify no E32
vim.api.nvim_buf_call(test_buf, function()
  vim.cmd("w")
end)
vim.wait(100, function() return submitted_text ~= nil end)
assert_true(submitted_text ~= nil, "scratchpad on_submit was invoked via :w")
assert_true(submitted_text:find("do_work") ~= nil, "scratchpad content correctly submitted")

-- Test reopening ui.open_input to verify no E95: Buffer with this name already exists
local reopen_ok, reopen_err = pcall(function()
  ui.open_input(function(_) end)
  ui.close_input()
  ui.open_input(function(_) end)
  ui.close_input()
end)
assert_true(reopen_ok, "reopening input scratchpad should succeed without E95: " .. tostring(reopen_err))

print("--> Testing vendor filtering and file navigation...")
local vendor_trace = [[
core/app/presenters/feed.rb:10:in `render'
/apps/myapp/shared/bundle/ruby/3.3.0/gems/activesupport-8.1.3.1/lib/active_support/callbacks.rb:27:in `run'
/apps/myapp/shared/bundle/ruby/3.3.0/gems/activesupport-8.1.3.1/lib/active_support/callbacks.rb:50:in `compile'
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

-- Test next_file / prev_file cycling when files exist on disk
-- Create dummy buffers or mock jump_to_frame to simulate navigation
local feed_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(feed_buf, vim.fs.normalize(vim.fn.getcwd()) .. "/core/app/presenters/feed.rb")
vim.api.nvim_buf_set_lines(feed_buf, 0, -1, false, { "class Feed", "end" })

local as_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(as_buf, "/apps/myapp/shared/bundle/ruby/3.3.0/gems/activesupport-8.1.3.1/lib/active_support/callbacks.rb")
vim.api.nvim_buf_set_lines(as_buf, 0, -1, false, { "module Callbacks", "end" })

local del_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(del_buf, "/usr/lib/x86_64-linux-gnu/ruby/3.3.0/delegate.rb")
vim.api.nvim_buf_set_lines(del_buf, 0, -1, false, { "class Delegate", "end" })

local brand_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(brand_buf, vim.fs.normalize(vim.fn.getcwd()) .. "/app/models/brand.rb")
vim.api.nvim_buf_set_lines(brand_buf, 0, -1, false, { "class Brand", "end" })

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

-- Test out-of-workspace absolute paths filtering (e.g. /opt/package/lib.py)
print("--> Testing out-of-workspace external path filtering...")
local external_trace = string.format([[
/opt/third_party/lib.py:42: in external_fn
%s/src/app.py:10: in local_fn
]], vim.fs.normalize(vim.fn.getcwd()))
unwind.clear()
unwind.ingest(external_trace)
assert_eq(#unwind.state.files, 2, "2 files before filter")
assert_true(unwind.state.files[1].is_vendor, "external absolute path /opt/... must be tagged vendor")
assert_true(not unwind.state.files[2].is_vendor, "local path must not be tagged vendor")
unwind.toggle_filter()
assert_eq(#unwind.state.files, 1, "only 1 file after filter enabled")
assert_true(unwind.state.files[1].file:find("src/app%.py") ~= nil, "local file kept")
unwind.toggle_filter()

print("--> Testing decorator formatting and global clear across buffers...")
local decorator = require("unwind.decorator")
local decor_buf1 = vim.api.nvim_create_buf(false, true)
local decor_buf2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(decor_buf1, 0, -1, false, { "line 1", "line 2" })
vim.api.nvim_buf_set_lines(decor_buf2, 0, -1, false, { "line 1", "line 2" })

local ext_id1 = decorator.render(decor_buf1, 1, 1, "", "core/test.rb", 5)
assert_true(ext_id1 ~= nil, "decorator extmark rendered in buf 1")
local extmarks1 = vim.api.nvim_buf_get_extmarks(decor_buf1, decorator.get_namespace(), 0, -1, { details = true })
assert_true(#extmarks1 > 0, "extmarks exist in buffer 1")
local header = extmarks1[1][4].virt_lines[1][1][1]
assert_true(header:find("anonymous") == nil, "header should not contain anonymous, got: " .. header)
assert_true(header:find("Frame 1/5") ~= nil or header:find("Frame #1/5") ~= nil, "header should contain Frame 1/5, got: " .. header)

-- Rendering in buf 2 must globally clear buf 1's extmarks
local ext_id2 = decorator.render(decor_buf2, 1, 2, "process", "core/other.rb", 5)
assert_true(ext_id2 ~= nil, "decorator extmark rendered in buf 2")
local extmarks1_after = vim.api.nvim_buf_get_extmarks(decor_buf1, decorator.get_namespace(), 0, -1, {})
assert_eq(#extmarks1_after, 0, "buffer 1 extmarks should be cleared when rendering in buffer 2")
local extmarks2 = vim.api.nvim_buf_get_extmarks(decor_buf2, decorator.get_namespace(), 0, -1, {})
assert_true(#extmarks2 > 0, "buffer 2 extmarks should exist")

print("--> Testing quickfix export...")
unwind.clear()
unwind.ingest([[
  File "app/main.py", line 10, in do_foo
    call_bar()
  File "app/utils.py", line 25, in call_bar
    crash()
]])
unwind.quickfix()
local qflist = vim.fn.getqflist()
assert_eq(#qflist, 2, "quickfix items count")
assert_true(qflist[1].text:find("at do_foo") ~= nil, "quickfix method formatted")
assert_eq(qflist[1].lnum, 10, "quickfix line 1")
assert_eq(qflist[2].lnum, 25, "quickfix line 2")

print("--> Testing ingest_range and active visual selection...")
local range_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(range_buf, 0, -1, false, {
  "irrelevant line 1",
  'File "range_test.py", line 99, in test_fn',
  "irrelevant line 3",
})
vim.api.nvim_win_set_buf(0, range_buf)
unwind.clear()
unwind.ingest_range(2, 2)
assert_eq(#unwind.state.frames, 1, "ingest_range parsed frame")
assert_eq(unwind.state.frames[1].line, 99, "ingest_range line")

-- Test ingest_range with inverted arguments (line1 > line2)
vim.api.nvim_win_set_buf(0, range_buf)
unwind.clear()
unwind.ingest_range(3, 1)
assert_eq(#unwind.state.frames, 1, "ingest_range with inverted bounds parsed frame")
assert_eq(unwind.state.frames[1].line, 99, "ingest_range inverted line")

-- Test ingest_selection while visual mode is active
vim.api.nvim_win_set_buf(0, range_buf)
unwind.clear()
vim.cmd("normal! 2GV") -- select line 2 in visual line mode
unwind.ingest_selection()
assert_eq(#unwind.state.frames, 1, "ingest_selection from active visual mode parsed frame")
assert_eq(unwind.state.frames[1].line, 99, "ingest_selection active visual mode line")

print("--> Testing setup ignore_patterns array replacement...")
unwind.setup({ ignore_patterns = { "custom_only/" } })
assert_eq(#unwind.config.ignore_patterns, 1, "setup should replace ignore_patterns array completely")
assert_eq(unwind.config.ignore_patterns[1], "custom_only/", "custom pattern set")
-- Restore default ignore patterns
unwind.setup({
  ignore_patterns = {
    "shared/bundle/",
    "vendor/bundle/",
    "/gems/",
    "node_modules/",
    "^/usr/",
  },
})

print("--> Testing jump_to_frame cursor column clamping and existing buffer reuse...")
local nav_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(nav_buf, vim.fs.normalize(vim.fn.getcwd()) .. "/tests/fixtures/dummy.txt")
vim.api.nvim_buf_set_lines(nav_buf, 0, -1, false, { "hi" }) -- 2 characters long
vim.api.nvim_win_set_buf(0, nav_buf)
unwind.state.frames = {
  { file = "tests/fixtures/dummy.txt", line = 1, col = 50, method = "test_col" },
}
unwind.state.files = {
  { file = "tests/fixtures/dummy.txt", primary_line = 1, primary_col = 50, primary_method = "test_col", total_frames = 1 },
}
unwind.jump_to_frame(1)
local cur_pos = vim.api.nvim_win_get_cursor(0)
assert_eq(cur_pos[1], 1, "jump_to_frame moved to line 1")
assert_true(cur_pos[2] <= 1, "cursor column clamped to line length (expected <= 1, got " .. cur_pos[2] .. ")")

-- Test 1-line range command in plugin/unwind.lua
print("--> Testing 1-line range command...")
-- Load plugin commands if not yet sourced
pcall(vim.cmd, "source plugin/unwind.lua")
require("unwind").clear()
-- Trigger UnwindSelection on line 1 of nav_buf
vim.api.nvim_buf_set_lines(nav_buf, 0, -1, false, { 'File "single_range.py", line 77, in single_fn' })
vim.cmd("1UnwindSelection")
assert_eq(#unwind.state.frames, 1, "1-line range command parsed frame")
assert_eq(unwind.state.frames[1].line, 77, "1-line range line 77")

print("--> Testing floating file menu wrap setting...")
unwind.clear()
unwind.ingest('File "test_wrap.py", line 1, in func')
unwind.menu()
-- Find open menu window and check wrap setting
local wins = vim.api.nvim_list_wins()
local menu_win_found = false
for _, w in ipairs(wins) do
  local b = vim.api.nvim_win_get_buf(w)
  local bt = vim.bo[b].buftype
  if bt == "nofile" and vim.wo[w].cursorline then
    assert_eq(vim.wo[w].wrap, false, "menu window wrap must be false")
    menu_win_found = true
    break
  end
end
assert_true(menu_win_found, "floating menu window found and verified wrap=false")
unwind.clear()

-- =========================================================================
-- REPRODUCTION TESTS FOR CODE REVIEW FINDINGS
-- =========================================================================

print("--> [Finding A] Nonexistent file navigation should not create empty buffer...")
do
  unwind.clear()
  local bufs_before = #vim.api.nvim_list_bufs()
  unwind.state.frames = {
    { file = "/remote/container/app/totally_missing_nonexistent_xyz.py", line = 125, method = "test" }
  }
  unwind.state.files = {
    { file = "/remote/container/app/totally_missing_nonexistent_xyz.py", primary_line = 125, total_frames = 1 }
  }
  unwind.state.active_index = 0
  local selected, opened = unwind.jump_to_frame(1)
  local bufs_after = #vim.api.nvim_list_bufs()
  assert_eq(bufs_after, bufs_before, "nonexistent file should not add an empty buffer to buffer list")
  assert_true(selected, "missing frame should still be selected as valid stacktrace position")
  assert_true(not opened, "source file could not be opened")
  assert_eq(unwind.state.active_index, 1, "active_index commits to missing frame in persistent sessions")
end

print("--> [Finding F] Workspace prefix boundary check in collector...")
do
  local root = vim.fs.normalize(vim.fn.getcwd())
  local project_other = root .. "-other/sub/file.lua"
  local project_exact = root .. "/sub/file.lua"
  assert_true(collector.is_vendor_or_ignored(project_other), "project-other should be treated as outside workspace (vendor)")
  assert_true(not collector.is_vendor_or_ignored(project_exact), "project child should be treated as inside workspace")
end

print("--> [Finding G] Python traceback crash-first navigation (most recent call first)...")
do
  local py_trace = [[
Traceback (most recent call last):
  File "lib/outer.py", line 10, in outer_func
    mid_func()
  File "lib/middle.py", line 20, in mid_func
    inner_func()
  File "src/inner.py", line 30, in inner_func
    raise RuntimeError("crash")
]]
  local py_parsed = parser.parse(py_trace)
  assert_eq(#py_parsed, 3, "parsed 3 python frames")
  assert_eq(py_parsed[1].file, "src/inner.py", "frame 1 should be the innermost/most recent call")
  assert_eq(py_parsed[1].line, 30, "frame 1 line should be 30")
  assert_eq(py_parsed[3].file, "lib/outer.py", "frame 3 should be the outermost call")
end

print("--> [Finding E] Repeated setup() keymap cleanup and opts immutability...")
do
  local custom_opts = {
    ignore_patterns = { "my_pattern/" },
    keymaps = { next = "]x", prev = "[x" },
  }
  unwind.setup(custom_opts)
  assert_true(custom_opts.ignore_patterns ~= nil, "setup must not mutate caller opts table")
  -- Verify ]x is mapped
  local map_x = vim.fn.maparg("]x", "n")
  assert_true(map_x ~= "", "]x should be mapped after setup")

  -- Now reconfigure with different keymaps
  unwind.setup({
    keymaps = { next = "]z", prev = "[z" },
  })
  local map_z = vim.fn.maparg("]z", "n")
  assert_true(map_z ~= "", "]z should be mapped after re-setup")
  local old_map_x = vim.fn.maparg("]x", "n")
  assert_eq(old_map_x, "", "]x mapping should be cleaned up after re-setup")

  -- Restore defaults
  unwind.setup({
    keymaps = {
      menu = "<leader>w",
      clipboard = "<leader>c",
      next = "]u",
      prev = "[u",
      next_file = "]f",
      prev_file = "[f",
    },
    ignore_patterns = {
      "shared/bundle/",
      "vendor/bundle/",
      "/gems/",
      "node_modules/",
      "^/usr/",
    },
  })
end

print("--> [Finding I] Collector filter behavior when all frames are filtered out...")
do
  local all_vendor = {
    { file = "node_modules/pkg/index.js", line = 1, col = 1, method = "run" },
    { file = "/usr/lib/system.js", line = 2, col = 1, method = "init" },
  }
  local res = collector.collect(all_vendor, { filter_vendor = true })
  assert_eq(#res.frames, 0, "frames should be empty when everything is filtered out")
  assert_eq(#res.files, 0, "files should be empty when everything is filtered out")
end

print("--> [Finding C] Configurable path mappings and safer suffix resolution...")
do
  -- Remote path mapping
  local remote_line = "  File \"/remote/ci/project/src/worker.py\", line 15, in do_work"
  local mapped_frames = parser.parse(remote_line, {
    path_mappings = {
      ["/remote/ci/project/"] = "./",
    }
  })
  assert_eq(#mapped_frames, 1, "parsed frame with path_mappings")
  assert_eq(mapped_frames[1].file, "src/worker.py", "mapped remote path to local")
end

-- =========================================================================
-- ADDITIONAL REGRESSION TESTS FOR LATEST CODE REVIEW FINDINGS
-- =========================================================================

print("--> [Regression] Overlapping path_mappings longest-prefix matching & segment boundary...")
do
  local trace = [[
  File "/remote/app/sub/service.py", line 10, in run
  File "/remote/app/root.py", line 20, in start
  File "/remote/application/other.py", line 30, in other
]]
  local frames = parser.parse(trace, {
    path_mappings = {
      ["/remote/app/"] = "local/app/",
      ["/remote/app/sub/"] = "local/sub/",
    }
  })
  assert_eq(#frames, 3, "parsed 3 frames")
  -- Longest prefix /remote/app/sub/ must match /remote/app/sub/service.py first
  assert_eq(frames[1].file, "local/sub/service.py", "longest prefix mapping matched")
  assert_eq(frames[2].file, "local/app/root.py", "shorter prefix mapping matched")
  -- Segment boundary: /remote/application/ should NOT match /remote/app/
  assert_true(frames[3].file:find("local/app") == nil, "/remote/application should not match /remote/app")
end

print("--> [Regression] /usr/src/<project>/src/main.lua prefix stripping without greedy collapse...")
do
  local path = "/usr/src/service/src/main.lua"
  -- If /usr/src/ was greedy with /usr/src/[%w_%-./]+/, it would eat /usr/src/service/src/
  -- Our non-greedy prefix only eats /usr/src/service/
  -- If local src/main.lua doesn't exist, it should not greedily collapse to root main.lua
  local normalized = parser.normalize_path(path)
  -- Since neither service/src/main.lua nor src/main.lua exist in root cwd, it preserves normalized path
  assert_eq(normalized, "/usr/src/service/src/main.lua", "non-existent path with /usr/src/ is not corrupted")
end

print("--> [Regression] Centralized keymap ownership with setup({ keymaps = false })...")
do
  -- Re-register default keymaps first via unwind.setup()
  unwind.setup({
    keymaps = {
      menu = "<leader>w",
      clipboard = "<leader>c",
      next = "]u",
      prev = "[u",
      next_file = "]f",
      prev_file = "[f",
    }
  })
  assert_true(vim.fn.maparg("]u", "n") ~= "", "]u should be mapped")

  -- Disable keymaps completely
  unwind.setup({ keymaps = false })
  assert_eq(vim.fn.maparg("]u", "n"), "", "]u should be removed when keymaps = false")
  assert_eq(vim.fn.maparg("[u", "n"), "", "[u should be removed when keymaps = false")
  assert_eq(vim.fn.maparg("]f", "n"), "", "]f should be removed when keymaps = false")
  assert_eq(#unwind._installed_keymaps, 0, "no installed keymaps tracked")

  -- Restore default keymaps
  unwind.setup({
    keymaps = {
      menu = "<leader>w",
      clipboard = "<leader>c",
      next = "]u",
      prev = "[u",
      next_file = "]f",
      prev_file = "[f",
    }
  })
  assert_true(vim.fn.maparg("]u", "n") ~= "", "]u restored")
end

print("--> [Regression] Failed jump_to_file() preserving active_index and active_file_index...")
do
  unwind.clear()
  -- Set active state
  unwind.state.frames = {
    { file = "tests/fixtures/dummy.txt", line = 1, col = 1, method = "test" },
    { file = "/nonexistent/path/never_there.txt", line = 1, col = 1, method = "fail" },
  }
  unwind.state.files = {
    { file = "tests/fixtures/dummy.txt", primary_line = 1, primary_col = 1, total_frames = 1 },
    { file = "/nonexistent/path/never_there.txt", primary_line = 1, primary_col = 1, total_frames = 1 },
  }
  -- Navigate to file 1 successfully
  local ok1 = unwind.jump_to_file(1)
  assert_true(ok1, "file 1 jump succeeded")
  assert_eq(unwind.state.active_index, 1, "active_index is 1")
  assert_eq(unwind.state.active_file_index, 1, "active_file_index is 1")

  -- Now attempt to jump to file 2 (nonexistent)
  -- In persistent sessions, missing file selects the primary frame in sidebar and updates indices
  local ok2 = unwind.jump_to_file(2)
  assert_true(ok2, "file 2 frame selected as N/A in persistent sessions")
  assert_eq(unwind.state.active_index, 2, "active_index moved to file 2's frame")
  assert_eq(unwind.state.active_file_index, 2, "active_file_index moved to file 2")
  unwind.clear()
end

print("--> [Regression] Mixed traces (Node/.NET/Rust + Python) reversing only Python blocks...")
do
  local mixed_trace = [[
    at Object.run (/app/src/index.js:10:5)
    at Server.listen (/app/src/server.js:25:3)
Traceback (most recent call last):
  File "lib/outer.py", line 10, in outer
    call_inner()
  File "lib/inner.py", line 20, in inner
    crash()
  --> src/main.rs:50:2
]]
  local frames = parser.parse(mixed_trace)
  assert_eq(#frames, 5, "parsed 5 total frames")
  -- First two frames are Node.js in forward order
  assert_true(frames[1].file:find("index.js") ~= nil, "frame 1 is index.js")
  assert_eq(frames[1].line, 10, "frame 1 line 10")
  assert_true(frames[2].file:find("server.js") ~= nil, "frame 2 is server.js")
  assert_eq(frames[2].line, 25, "frame 2 line 25")

  -- Python block frames (3 and 4) are reversed (inner then outer)
  assert_true(frames[3].file:find("inner.py") ~= nil, "frame 3 is innermost python frame inner.py")
  assert_eq(frames[3].line, 20, "frame 3 line 20")
  assert_true(frames[4].file:find("outer.py") ~= nil, "frame 4 is outermost python frame outer.py")
  assert_eq(frames[4].line, 10, "frame 4 line 10")

  -- Frame 5 is Rust compiler in forward order
  assert_true(frames[5].file:find("main.rs") ~= nil, "frame 5 is main.rs")
  assert_eq(frames[5].line, 50, "frame 5 line 50")
end

print("--> [Regression] Python trace exceeding max_frames retains innermost crash frames...")
do
  local deep_python = "Traceback (most recent call last):\n"
  for i = 1, 20 do
    deep_python = deep_python .. string.format('  File "step_%02d.py", line %d, in func_%d\n    pass\n', i, i, i)
  end
  deep_python = deep_python .. '  File "final_crash.py", line 99, in crash\n    raise Exception("boom")\n'

  -- Total 21 frames in Python traceback. If max_frames = 5:
  local frames = parser.parse(deep_python, { max_frames = 5 })
  assert_eq(#frames, 5, "capped at 5 frames")
  -- Innermost crash frame (final_crash.py) must be at frame 1!
  assert_eq(frames[1].file, "final_crash.py", "innermost crash frame retained at index 1")
  assert_eq(frames[1].line, 99, "innermost crash frame line 99")
  assert_eq(frames[2].file, "step_20.py", "frame 2 is step_20.py")
  assert_eq(frames[5].file, "step_17.py", "frame 5 is step_17.py")
end

print("--> [Regression] Bounded file read in ingest_file...")
do
  -- Create a temporary file larger than max_input_bytes
  local tmp_file = vim.fn.tempname()
  local f = io.open(tmp_file, "w")
  local line = 'File "test_bounded.py", line 10, in work\n'
  -- Write 1000 lines
  for _ = 1, 1000 do
    f:write(line)
  end
  f:close()

  unwind.clear()
  -- Set small max_input_bytes
  local orig_limit = unwind.config.max_input_bytes
  unwind.config.max_input_bytes = 200 -- 200 bytes limit
  unwind.ingest_file(tmp_file)
  assert_true(#unwind.state.frames > 0, "frames loaded despite truncation")
  -- Restore original limit
  unwind.config.max_input_bytes = orig_limit
  os.remove(tmp_file)
  unwind.clear()
end

print("--> [Regression] Input scratchpad cancellation invalidates scheduled submit...")
do
  local ui = require("unwind.ui")
  local submitted = false
  ui.open_input(function(_)
    submitted = true
  end)

  -- Find input buffer
  local bufs = vim.api.nvim_list_bufs()
  local in_buf = nil
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find("unwind://input") then
      in_buf = b
      break
    end
  end
  assert_true(in_buf ~= nil, "input buffer found")

  -- Trigger submit via :w then immediately close_input() before vim.schedule executes callback
  vim.api.nvim_buf_call(in_buf, function()
    vim.cmd("w")
  end)
  ui.close_input()

  vim.wait(50, function() return false end)
  assert_true(not submitted, "scheduled callback must not run after close_input()")
end

print("--> [Regression] Small terminal dimensions do not crash ui.open / ui.open_input and leak no buffers...")
do
  local ui = require("unwind.ui")
  local orig_cols = vim.o.columns
  local orig_lines = vim.o.lines

  local orig_laststatus = vim.o.laststatus
  vim.o.laststatus = 0
  vim.o.lines = 4

  local bufs_before = #vim.api.nvim_list_bufs()

  local ok_open = pcall(function()
    ui.open_session_manager({ { type = "session", name = "test.lua", frame_count = 1 } }, {})
  end)
  assert_true(ok_open, "ui.open_session_manager should not throw on small terminal")
  local bufs_after_menu = #vim.api.nvim_list_bufs()
  assert_eq(bufs_after_menu, bufs_before, "ui.open_session_manager must not leak scratch buffer on small terminal early return")

  local ok_input = pcall(function()
    ui.open_input(function() end)
  end)
  assert_true(ok_input, "ui.open_input should not throw on small terminal")
  local bufs_after_input = #vim.api.nvim_list_bufs()
  assert_eq(bufs_after_input, bufs_before, "ui.open_input must not leak scratch buffer on small terminal early return")

  vim.o.columns = orig_cols
  vim.o.lines = orig_lines
  vim.o.laststatus = orig_laststatus
end

print("--> [New Invariants] Project root pinning and :cd cwd invariance...")
do
  unwind.clear()
  local dummy_path = "tests/fixtures/dummy.txt"
  local trace = 'File "' .. dummy_path .. '", line 1, in test_fn\n'
  unwind.ingest(trace)
  assert_true(unwind.state.root ~= nil, "state.root must be pinned")

  -- Change Neovim cwd to a different subdirectory
  local orig_cwd = vim.fn.getcwd()
  vim.cmd("cd tests")

  -- Navigation should still resolve relative to pinned state.root
  local nav_ok = unwind.jump_to_frame(1)
  assert_true(nav_ok, "jump_to_frame should succeed even after :cd because root was pinned")
  assert_eq(unwind.state.active_index, 1, "active_index is 1")

  -- Return to original cwd
  vim.cmd("cd " .. vim.fn.fnameescape(orig_cwd))
  unwind.clear()
end

print("--> [New Invariants] Navigation across missing and valid frames...")
do
  unwind.clear()
  -- Stacktrace with:
  -- frame 1: missing
  -- frame 2: valid (tests/fixtures/dummy.txt)
  -- frame 3: missing
  local mixed_trace = [[
  File "missing_one.py", line 10, in f1
  File "tests/fixtures/dummy.txt", line 1, in f2
  File "missing_two.py", line 20, in f3
]]
  unwind.ingest(mixed_trace)
  -- Ingestion starts at frame 1 (selecting missing frame 1 as N/A)
  assert_eq(unwind.state.active_index, 1, "initial navigation lands on frame 1")

  -- Calling next() moves to frame 2 (valid)
  unwind.next()
  assert_eq(unwind.state.active_index, 2, "next() moves to frame 2")

  -- Calling next() moves to frame 3 (missing)
  unwind.next()
  assert_eq(unwind.state.active_index, 3, "next() moves to frame 3")
  unwind.clear()
end

print("--> [New Invariants] Floating menu window isolation during navigation...")
do
  unwind.clear()
  unwind.ingest('File "tests/fixtures/dummy.txt", line 1, in f1')
  -- Open menu float
  unwind.menu()
  -- Current window is the floating menu
  assert_true(ui.is_floating(0), "current window is float")

  -- Pressing next() while inside float should NOT turn the float into a source window
  local wins_before = #vim.api.nvim_list_wins()
  unwind.next()
  -- Float must have been closed or replaced with source window
  assert_true(not ui.is_floating(0), "navigation moved to source window")
  local cur_buf = vim.api.nvim_get_current_buf()
  assert_true(vim.api.nvim_buf_get_name(cur_buf):find("dummy%.txt") ~= nil, "source buffer loaded in normal window")
  unwind.clear()
end

print("--> [New Invariants] Python indented source lines containing 'file:line' are not treated as frames...")
do
  local py_code_trace = [[
Traceback (most recent call last):
  File "outer.py", line 10, in outer
    value = "src/config.py:123"
  File "inner.py", line 20, in inner
    crash()
RuntimeError: boom
]]
  local frames = parser.parse(py_code_trace)
  assert_eq(#frames, 2, "only 2 python frames should be parsed; src/config.py:123 source line must be ignored")
  assert_eq(frames[1].file, "inner.py", "frame 1 is inner.py (innermost)")
  assert_eq(frames[2].file, "outer.py", "frame 2 is outer.py (outermost)")
end

print("--> [New Invariants] Non-file pseudo-paths classification (<frozen ...>, node:, file://)...")
do
  local pseudo_trace = [[
    at Object.<anonymous> (node:internal/process/task_queues:95:5)
  File "<frozen importlib._bootstrap>", line 1000, in _find_and_load
  File "<string>", line 1, in <module>
    at run (file:///app/src/index.js:10:20)
]]
  local frames = parser.parse(pseudo_trace)
  assert_eq(#frames, 4, "parsed 4 frames")
  for _, f in ipairs(frames) do
    assert_true(not f.navigable, "pseudo frame " .. f.file .. " must be marked non-navigable")
  end
end

print("--> [New Invariants] Canonical path deduplication (./src/foo.lua vs src/foo.lua)...")
do
  local rel_frames = {
    { file = "./tests/fixtures/dummy.txt", resolved_path = "tests/fixtures/dummy.txt", line = 1, col = 1, method = "m1" },
    { file = "tests/fixtures/dummy.txt", resolved_path = "tests/fixtures/dummy.txt", line = 1, col = 1, method = "m2" },
  }
  local res = collector.collect(rel_frames)
  assert_eq(#res.files, 1, "lexically equivalent paths must be deduplicated into 1 file entry")
  assert_eq(res.files[1].total_frames, 2, "total frames count is 2")
end

print("--> [New Review Tests] Preserving navigation context during filter toggle...")
do
  local mixed_trace = [[
core/app/feed.rb:10:in `render'
/apps/myapp/shared/bundle/ruby/3.3.0/gems/activesupport/callbacks.rb:27:in `run'
app/models/brand.rb:5:in `name'
]]
  unwind.clear()
  unwind.ingest(mixed_trace)
  assert_eq(#unwind.state.frames, 3, "3 raw frames")

  -- Set active_index to frame 3 (brand.rb, a non-vendor frame)
  unwind.state.active_index = 3

  -- Reapply filter to hide vendor frames
  unwind.state.filter_enabled = true
  unwind.reapply_filter()

  -- brand.rb is non-vendor, so it should still be present in filtered frames
  assert_eq(#unwind.state.frames, 2, "2 frames after filtering vendor")
  assert_eq(unwind.state.frames[unwind.state.active_index].file, "app/models/brand.rb", "active frame context preserved")

  -- Now test fallback when active frame IS vendor
  unwind.state.filter_enabled = false
  unwind.reapply_filter()
  assert_eq(#unwind.state.frames, 3, "3 frames when filter disabled")
  -- Select frame 2 (activesupport, which is vendor)
  unwind.state.active_index = 2

  unwind.state.filter_enabled = true
  unwind.reapply_filter()
  assert_eq(#unwind.state.frames, 2, "2 frames after filter")
  -- Nearest surviving frame to index 2 is index 2 (brand.rb)
  assert_true(unwind.state.active_index > 0 and unwind.state.active_index <= #unwind.state.frames, "active_index falls back cleanly")
  unwind.clear()
end

print("--> [New Review Tests] Multibyte string display width in floating menu...")
do
  local multibyte_items = {
    { type = "session", name = "src/日本語/サービス.lua", frame_count = 2 },
    { type = "session", name = "src/emoji_🚀_test.lua", frame_count = 1 },
  }
  -- Should open and close without throwing any error
  ui.open_session_manager(multibyte_items, {})
  assert_true(ui.is_floating(), "menu window is open and floating")
  ui.close()
  assert_true(not ui.is_floating(), "menu window is closed")
end

print("--> [New Review Tests] ui.close() does not steal focus when user moved to another window...")
do
  local test_buf1 = vim.api.nvim_create_buf(false, true)
  local test_buf2 = vim.api.nvim_create_buf(false, true)
  local win1 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win1, test_buf1)

  -- Open floating menu
  ui.open_session_manager({ { type = "session", name = "dummy.lua", frame_count = 1 } }, {})

  -- Create a second normal window and move focus to it while float is open
  vim.cmd("vsplit")
  local win2 = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win2, test_buf2)

  -- Current window is win2, not the float. Now close float.
  ui.close()

  -- Focus should stay in win2, not forced back to win1
  assert_eq(vim.api.nvim_get_current_win(), win2, "focus remained in win2 after ui.close()")

  -- Cleanup
  vim.api.nvim_win_close(win2, true)
  pcall(vim.api.nvim_buf_delete, test_buf1, { force = true })
  pcall(vim.api.nvim_buf_delete, test_buf2, { force = true })
end

print("--> [New Review Tests] Relative paths outside workspace (../outside/foo.lua) treated as vendor/external...")
do
  assert_true(collector.is_vendor_or_ignored("../outside/project/foo.lua"), "relative path ascending out of workspace must be vendor")
  assert_true(not collector.is_vendor_or_ignored("src/local/foo.lua"), "local relative path must not be vendor")
end

print("--> [New Review Tests] Malformed ignore patterns do not crash collection or setup...")
do
  -- Protected pattern evaluation in is_vendor_or_ignored
  local malformed_ok = pcall(function()
    collector.is_vendor_or_ignored("some/path/file.lua", { "[malformed(" })
  end)
  assert_true(malformed_ok, "is_vendor_or_ignored should handle malformed patterns safely without crashing")

  -- Validation in setup()
  unwind.setup({ ignore_patterns = { "[invalid(", "valid_pattern/" } })
  assert_eq(#unwind.config.ignore_patterns, 1, "setup should discard invalid patterns")
  assert_eq(unwind.config.ignore_patterns[1], "valid_pattern/", "valid pattern kept")

  -- Restore default ignore patterns
  unwind.setup({
    ignore_patterns = {
      "shared/bundle/",
      "vendor/bundle/",
      "/gems/",
      "node_modules/",
      "^/usr/",
    },
  })
end

print("All parser, collector & integration unit tests PASSED successfully!")

-- =========================================================================
-- PERSISTENT SESSIONS & SIDEBAR SPEC SUITE
-- =========================================================================

print("--> [Session Spec 1] Persistence roundtrip and non-serialization of runtime fields...")
do
  local test_sessions = require("unwind.sessions")
  local test_root = vim.fs.normalize(vim.fn.getcwd())
  local storage_file = test_sessions.storage_path(test_root)

  local raw = {
    { file = "src/cache.lua", line = 117, col = 4, method = "retain_object", raw_line = "raw line 1" },
    { file = "src/worker.lua", line = 42, col = 1, method = "worker_loop", raw_line = "raw line 2" },
  }
  local test_s = test_sessions.new_working(test_root, raw, false)
  local list = {}
  local ok, err = test_sessions.save_working(test_s, "Memory leak", list, test_root)
  assert_true(ok, "session saved successfully: " .. tostring(err))

  local f = io.open(storage_file, "r")
  assert_true(f ~= nil, "state file opened")
  local txt = f:read("*all")
  f:close()
  local json = vim.json.decode(txt)
  assert_eq(#json.sessions, 1, "1 session serialized")
  assert_eq(json.sessions[1].name, "Memory leak", "session name serialized")
  -- Runtime fields must NOT be serialized
  assert_true(json.sessions[1].frames[1].resolved_path == nil, "resolved_path not serialized")
  assert_true(json.sessions[1].frames[1].navigable == nil, "navigable not serialized")
  assert_true(json.sessions[1].active_index == nil, "active_index not serialized")

  -- Reload
  local reloaded = test_sessions.load(test_root)
  assert_eq(#reloaded, 1, "1 session reloaded")
  assert_eq(reloaded[1].name, "Memory leak", "reloaded name matches")
  assert_eq(#reloaded[1].raw_frames, 2, "reloaded raw frames count matches")

  test_sessions.delete(reloaded[1], list, test_root)
  pcall(os.remove, storage_file)
end

print("--> [Session Spec 2] Ingestion does not overwrite saved session...")
do
  local test_sessions = require("unwind.sessions")
  local test_root = vim.fs.normalize(vim.fn.getcwd())
  local storage_file = test_sessions.storage_path(test_root)

  unwind.clear()
  -- 1. Create and save Session A
  unwind.ingest('File "session_a.py", line 10, in fn_a\n')
  local s_a = unwind.state.active_session
  unwind.ensure_sessions_loaded(test_root)
  test_sessions.save_working(s_a, "Session A", unwind.state.sessions, test_root)

  local f1 = io.open(storage_file, "r")
  local disk1 = f1:read("*all")
  f1:close()

  -- 2. Ingest Trace B
  unwind.ingest('File "session_b.py", line 99, in fn_b\n')
  local s_b = unwind.state.active_session
  assert_true(not s_b.saved, "Session B must be unsaved working session")
  assert_eq(s_b.name, nil, "Session B must be unnamed")

  -- 3. Verify disk content for Session A was untouched
  local f2 = io.open(storage_file, "r")
  local disk2 = f2:read("*all")
  f2:close()
  assert_eq(disk1, disk2, "Disk state for saved Session A must remain untouched by new ingestion")

  -- Cleanup
  test_sessions.delete(s_a, unwind.state.sessions, test_root)
  pcall(os.remove, storage_file)
  unwind.clear()
end

print("--> [Session Spec 3] Missing file after persistence shows red N/A without empty buffer...")
do
  local test_sessions = require("unwind.sessions")
  local test_sidebar = require("unwind.sidebar")
  local test_root = vim.fs.normalize(vim.fn.getcwd())
  local dummy_file = test_root .. "/tests/fixtures/session_dummy.py"
  local f = io.open(dummy_file, "w")
  f:write("print('hello')\n")
  f:close()

  unwind.clear()
  unwind.ingest('File "tests/fixtures/session_dummy.py", line 1, in run\n')
  local s = unwind.state.active_session
  unwind.ensure_sessions_loaded(test_root)
  test_sessions.save_working(s, "Dummy Session", unwind.state.sessions, test_root)

  -- Delete source file
  os.remove(dummy_file)
  local b = vim.fn.bufnr(dummy_file)
  if b ~= -1 then pcall(vim.api.nvim_buf_delete, b, { force = true }) end

  local bufs_before = #vim.api.nvim_list_bufs()
  unwind.activate_session(s)
  local bufs_after = #vim.api.nvim_list_bufs()

  -- Verify no empty buffer was created for the missing file
  assert_true(test_sidebar.is_open(), "sidebar opened on session activation")
  assert_eq(s.files[1].available, false, "file must be marked unavailable")
  assert_eq(s.active_index, 1, "missing frame selected")
  assert_true(bufs_after <= bufs_before + 1, "no empty source buffer created (only sidebar buffer allowed)")

  test_sidebar.hide()
  test_sessions.delete(s, unwind.state.sessions, test_root)
  local storage_file = test_sessions.storage_path(test_root)
  pcall(os.remove, storage_file)
  unwind.clear()
end

print("--> [Session Spec 4] Frame cycling across missing and valid frames with sidebar synchronization...")
do
  local test_sidebar = require("unwind.sidebar")
  unwind.clear()
  local trace = [[
  File "missing_a.py", line 10, in fn_a
  File "tests/fixtures/dummy.txt", line 1, in fn_b
  File "missing_c.py", line 30, in fn_c
]]
  unwind.ingest(trace)
  unwind.toggle_sidebar()
  assert_true(test_sidebar.is_open(), "sidebar is open")

  -- Frame 1 (missing)
  assert_eq(unwind.state.active_index, 1, "frame 1 active")
  local decor_ns = require("unwind.decorator").get_namespace()
  local marks1 = vim.api.nvim_buf_get_extmarks(0, decor_ns, 0, -1, {})
  assert_eq(#marks1, 0, "no source decoration for missing frame 1")

  -- Cycle next -> Frame 2 (valid)
  unwind.next()
  assert_eq(unwind.state.active_index, 2, "frame 2 active")
  local cur_buf = vim.api.nvim_get_current_buf()
  assert_true(vim.api.nvim_buf_get_name(cur_buf):find("dummy%.txt") ~= nil, "source window opened dummy.txt")
  local marks2 = vim.api.nvim_buf_get_extmarks(cur_buf, decor_ns, 0, -1, {})
  assert_true(#marks2 > 0, "source decoration rendered for valid frame 2")

  -- Cycle next -> Frame 3 (missing)
  unwind.next()
  assert_eq(unwind.state.active_index, 3, "frame 3 active")
  local marks3 = vim.api.nvim_buf_get_extmarks(cur_buf, decor_ns, 0, -1, {})
  assert_eq(#marks3, 0, "source decoration cleared when moving to missing frame 3")

  test_sidebar.hide()
  unwind.clear()
end

print("--> [Session Spec 5] Sidebar frame deletion ('d') persists for saved session...")
do
  local test_sessions = require("unwind.sessions")
  local test_sidebar = require("unwind.sidebar")
  local test_root = vim.fs.normalize(vim.fn.getcwd())
  local storage_file = test_sessions.storage_path(test_root)

  unwind.clear()
  local trace = [[
  File "tests/fixtures/dummy.txt", line 1, in f1
  File "tests/fixtures/dummy.txt", line 1, in f2
  File "tests/fixtures/dummy.txt", line 1, in f3
]]
  unwind.ingest(trace)
  local s = unwind.state.active_session
  unwind.ensure_sessions_loaded(test_root)
  test_sessions.save_working(s, "Delete Test", unwind.state.sessions, test_root)

  assert_eq(#s.raw_frames, 3, "3 raw frames originally")
  unwind.toggle_sidebar()

  -- Delete frame 2
  unwind.delete_frame_from_session(s, 2)
  assert_eq(#s.raw_frames, 2, "2 raw frames after deletion")
  assert_eq(#s.frames, 2, "2 derived frames after deletion")

  -- Verify persisted immediately
  local reloaded = test_sessions.load(test_root)
  assert_eq(#reloaded[1].raw_frames, 2, "persisted session has 2 frames after deletion")

  test_sidebar.hide()
  test_sessions.delete(s, unwind.state.sessions, test_root)
  pcall(os.remove, storage_file)
  unwind.clear()
end

print("--> [Session Spec 6] Navigation while sidebar has focus preserves sidebar window...")
do
  local test_sidebar = require("unwind.sidebar")
  unwind.clear()
  unwind.ingest('File "tests/fixtures/dummy.txt", line 1, in fn1\nFile "tests/fixtures/dummy.txt", line 1, in fn2\n')
  unwind.toggle_sidebar()
  assert_true(test_sidebar.is_open(), "sidebar open")

  -- Focus sidebar window
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if test_sidebar.is_sidebar_window(w) then
      vim.api.nvim_set_current_win(w)
      break
    end
  end
  assert_true(test_sidebar.is_sidebar_window(), "focused in sidebar")

  -- Trigger next()
  unwind.next()

  -- Verify sidebar window buffer was not replaced
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if test_sidebar.is_sidebar_window(w) then
      local b = vim.api.nvim_win_get_buf(w)
      assert_true(vim.api.nvim_buf_get_name(b):find("unwind://sidebar") ~= nil, "sidebar window must retain sidebar buffer")
    end
  end

  test_sidebar.hide()
  unwind.clear()
end

print("--> [Session Spec 7] :UnwindClear is non-destructive to saved sessions...")
do
  local test_sessions = require("unwind.sessions")
  local test_root = vim.fs.normalize(vim.fn.getcwd())
  local storage_file = test_sessions.storage_path(test_root)

  unwind.clear()
  unwind.ingest('File "session_clear.py", line 5, in fn\n')
  local s = unwind.state.active_session
  unwind.ensure_sessions_loaded(test_root)
  test_sessions.save_working(s, "Preserved Session", unwind.state.sessions, test_root)

  -- Run clear()
  unwind.clear()
  assert_true(unwind.state.active_session == nil, "active_session is deactivated")

  -- Verify session still exists in persisted sessions list
  local reloaded = test_sessions.load(test_root)
  assert_eq(#reloaded, 1, "saved session was NOT deleted by clear()")
  assert_eq(reloaded[1].name, "Preserved Session", "saved session intact")

  test_sessions.delete(reloaded[1], unwind.state.sessions, test_root)
  pcall(os.remove, storage_file)
end

print("--> [Session Spec 8] Persistence hot-path assertion: zero disk writes during navigation...")
do
  local test_sessions = require("unwind.sessions")
  local orig_save = test_sessions.save
  local save_called = false
  test_sessions.save = function(...)
    save_called = true
    return orig_save(...)
  end

  unwind.clear()
  unwind.ingest([[
  File "tests/fixtures/dummy.txt", line 1, in f1
  File "tests/fixtures/dummy.txt", line 1, in f2
  File "missing.py", line 1, in f3
]])

  save_called = false
  unwind.next()
  assert_true(not save_called, "next() must not write to disk")
  unwind.prev()
  assert_true(not save_called, "prev() must not write to disk")
  unwind.next_file()
  assert_true(not save_called, "next_file() must not write to disk")
  unwind.prev_file()
  assert_true(not save_called, "prev_file() must not write to disk")

  test_sessions.save = orig_save
  unwind.clear()
end

-- =========================================================================
-- REGRESSION TESTS FOR REVIEW FINDINGS (P1/P2/PERF)
-- =========================================================================

print("--> [Review Regression 1] Deleted file without unloading loaded buffer becomes N/A...")
do
  local test_root = vim.fs.normalize(vim.fn.getcwd())
  local dummy_buf_file = test_root .. "/tests/fixtures/dummy_loaded_buf.py"
  local f = io.open(dummy_buf_file, "w")
  f:write("print('loaded')\n")
  f:close()

  unwind.clear()
  -- Open dummy_buf_file in Neovim so buffer remains loaded
  vim.cmd.edit(vim.fn.fnameescape(dummy_buf_file))
  local b = vim.fn.bufnr(dummy_buf_file)
  assert_true(b ~= -1 and vim.api.nvim_buf_is_loaded(b), "buffer is loaded in Neovim")

  -- Ingest trace pointing to dummy_buf_file
  unwind.ingest('File "tests/fixtures/dummy_loaded_buf.py", line 1, in run\n')
  assert_eq(unwind.state.active_session.files[1].available, true, "file available while on disk")

  -- Delete file from filesystem WITHOUT deleting loaded buffer in Neovim
  os.remove(dummy_buf_file)
  assert_true(vim.api.nvim_buf_is_loaded(b), "buffer still loaded after file removal")

  -- Re-check availability (via refresh_availability or jump_to_frame)
  unwind.refresh_availability()
  assert_eq(unwind.state.active_session.files[1].available, false, "file must be marked N/A despite loaded buffer")

  -- Clean up buffer
  pcall(vim.api.nvim_buf_delete, b, { force = true })
  unwind.clear()
end

print("--> [Review Regression 2] Persistence save failure triggers rollback on save/rename/delete/frame-delete...")
do
  local test_sessions = require("unwind.sessions")
  local test_root = vim.fs.normalize(vim.fn.getcwd())

  -- 1. Rollback on save_working()
  local s_work = test_sessions.new_working(test_root, { { file = "a.py", line = 1 } })
  local session_list = {}
  local orig_save = test_sessions.save
  test_sessions.save = function() return false end

  local ok_save = test_sessions.save_working(s_work, "Should Fail", session_list, test_root)
  assert_true(not ok_save, "save_working should fail when disk write fails")
  assert_eq(s_work.saved, false, "session.saved should roll back to false")
  assert_eq(s_work.name, nil, "session.name should roll back to nil")
  assert_eq(#session_list, 0, "session should not remain in session list")

  -- 2. Rollback on rename()
  test_sessions.save = orig_save
  test_sessions.save_working(s_work, "Initial Name", session_list, test_root)
  test_sessions.save = function() return false end

  local ok_rename = test_sessions.rename(s_work, "New Name", session_list, test_root)
  assert_true(not ok_rename, "rename should fail when disk write fails")
  assert_eq(s_work.name, "Initial Name", "session.name must roll back to Initial Name")

  -- 3. Rollback on delete()
  local ok_del = test_sessions.delete(s_work, session_list, test_root)
  assert_true(not ok_del, "delete should fail when disk write fails")
  assert_eq(#session_list, 1, "session must remain in session list after failed delete")
  assert_eq(s_work.saved, true, "session.saved must remain true after failed delete")

  -- 4. Rollback on delete_frame_from_session()
  unwind.clear()
  unwind.state.active_session = s_work
  rawset(unwind.state, "sessions", session_list)
  assert_eq(#s_work.raw_frames, 1, "1 raw frame before delete")
  unwind.delete_frame_from_session(s_work, 1)
  assert_eq(#s_work.raw_frames, 1, "raw_frames must roll back after failed persistence")

  -- Clean up
  test_sessions.save = orig_save
  test_sessions.delete(s_work, session_list, test_root)
  unwind.clear()
end

print("--> [Review Regression 3] Active vs non-active frame deletion visual synchronization...")
do
  local test_sidebar = require("unwind.sidebar")
  local test_root = vim.fs.normalize(vim.fn.getcwd())
  local multiline_dummy = test_root .. "/tests/fixtures/multiline_dummy.txt"
  local f = io.open(multiline_dummy, "w")
  f:write("line 1\nline 2\nline 3\n")
  f:close()

  unwind.clear()
  local trace = [[
  File "tests/fixtures/multiline_dummy.txt", line 1, in f1
  File "tests/fixtures/multiline_dummy.txt", line 2, in f2
  File "tests/fixtures/multiline_dummy.txt", line 3, in f3
]]
  unwind.ingest(trace)
  local s = unwind.state.active_session
  unwind.toggle_sidebar()

  -- Initially frame 1 is active
  assert_eq(s.active_index, 1, "frame 1 initially active")
  local cur_pos1 = vim.api.nvim_win_get_cursor(0)
  assert_eq(cur_pos1[1], 1, "cursor is at line 1")

  -- Delete non-active frame 3: active frame 1 should be preserved
  unwind.delete_frame_from_session(s, 3)
  assert_eq(#s.frames, 2, "2 frames remaining")
  assert_eq(s.active_index, 1, "active_index preserved at frame 1")
  local cur_pos_preserved = vim.api.nvim_win_get_cursor(0)
  assert_eq(cur_pos_preserved[1], 1, "cursor remained at frame 1")

  -- Move to frame 2 and delete active frame 2
  unwind.jump_to_frame(2)
  assert_eq(s.active_index, 2, "frame 2 active")
  local cur_pos2 = vim.api.nvim_win_get_cursor(0)
  assert_eq(cur_pos2[1], 2, "cursor is at line 2")

  unwind.delete_frame_from_session(s, 2)
  assert_eq(#s.frames, 1, "1 frame remaining")
  assert_eq(s.active_index, 1, "nearest surviving frame 1 becomes active")
  local cur_pos_after = vim.api.nvim_win_get_cursor(0)
  assert_eq(cur_pos_after[1], 1, "source window cursor synchronized to surviving frame line 1")

  test_sidebar.hide()
  os.remove(multiline_dummy)
  unwind.clear()
end

print("--> [Review Regression 4] Active missing-frame highlight gets UnwindSidebarMissing...")
do
  local test_sidebar = require("unwind.sidebar")
  unwind.clear()
  unwind.ingest('File "completely_missing.py", line 10, in f_missing\n')
  unwind.toggle_sidebar()

  -- Frame 1 is missing and active
  local s = unwind.state.active_session
  assert_eq(s.files[1].available, false, "file is missing")
  assert_eq(s.active_index, 1, "frame 1 is active")

  -- Inspect highlights on the active namespace in sidebar buffer
  local side_buf = vim.fn.bufnr("unwind://sidebar")
  assert_true(side_buf ~= -1, "sidebar buffer found")
  local ns_active = vim.api.nvim_create_namespace("unwind_sidebar_active")
  local marks = vim.api.nvim_buf_get_extmarks(side_buf, ns_active, 0, -1, { details = true })
  local has_missing_hl = false
  for _, m in ipairs(marks) do
    if m[4] and m[4].hl_group == "UnwindSidebarMissing" then
      has_missing_hl = true
      break
    end
  end
  assert_true(has_missing_hl, "active missing row must receive UnwindSidebarMissing highlight")

  test_sidebar.hide()
  unwind.clear()
end

print("--> [Review Regression 5] Reloaded session with active_index = 0 shows footer on activation...")
do
  local test_sessions = require("unwind.sessions")
  local test_sidebar = require("unwind.sidebar")
  local test_root = vim.fs.normalize(vim.fn.getcwd())
  local storage_file = test_sessions.storage_path(test_root)

  unwind.clear()
  unwind.ingest('File "tests/fixtures/dummy.txt", line 1, in run\n')
  local s = unwind.state.active_session
  unwind.ensure_sessions_loaded(test_root)
  test_sessions.save_working(s, "Footer Test", unwind.state.sessions, test_root)

  -- Reload from disk: loaded sessions have active_index = 0
  local reloaded = test_sessions.load(test_root)
  assert_eq(reloaded[1].active_index, 0, "freshly reloaded session has active_index 0")

  -- Activate session
  unwind.activate_session(reloaded[1])
  local side_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if test_sidebar.is_sidebar_window(w) then
      side_win = w
      break
    end
  end
  assert_true(side_win ~= nil, "sidebar window found")
  local stl = vim.wo[side_win].statusline or ""
  local footer_found = stl:find("1/1 tests/fixtures/dummy.txt:1") ~= nil
  assert_true(footer_found, "footer statusline must be present after activating reloaded session, statusline: " .. vim.inspect(stl))

  test_sidebar.hide()
  test_sessions.delete(reloaded[1], unwind.state.sessions, test_root)
  pcall(os.remove, storage_file)
  unwind.clear()
end

print("--> [Review Regression 6] Chrome isolated from buffer lines (strictly 1:1 frame rows)...")
do
  local test_sidebar = require("unwind.sidebar")
  unwind.clear()
  local trace = [[
  File "tests/fixtures/dummy.txt", line 1, in f1
  File "tests/fixtures/dummy.txt", line 2, in f2
]]
  unwind.ingest(trace)
  local s = unwind.state.active_session
  unwind.toggle_sidebar()

  local side_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if test_sidebar.is_sidebar_window(w) then
      side_win = w
      break
    end
  end
  assert_true(side_win ~= nil, "sidebar window found")

  local side_buf = vim.api.nvim_win_get_buf(side_win)
  local line_count = vim.api.nvim_buf_line_count(side_buf)
  -- Exactly 2 lines in buffer corresponding 1:1 to the 2 frames
  assert_eq(line_count, 2, "buffer lines strictly match frame count (line 1 == frame 1, line 2 == frame 2)")

  -- Make frame 1 active
  s.active_index = 1

  -- <CR> on line 1 jumps to frame 1
  vim.api.nvim_win_set_cursor(side_win, { 1, 0 })
  vim.api.nvim_win_call(side_win, function()
    vim.cmd([[execute "normal \<CR>"]])
  end)
  assert_eq(s.active_index, 1, "<CR> on line 1 activates frame 1")

  -- 'd' is unmapped for native vim motions, so executing 'd' does not trigger plugin deletion callback directly
  local frames_count_before = #s.frames
  vim.api.nvim_win_call(side_win, function()
    vim.cmd([[execute "normal dd"]])
  end)
  -- Buffer line was cut with dd (standard Vim motion), but session.frames is unchanged until = sync
  assert_eq(#s.frames, frames_count_before, "dd edits buffer without mutating session until = sync")
  assert_eq(vim.bo[side_buf].modified, true, "buffer is marked modified after dd")

  test_sidebar.hide()
  unwind.clear()
end

print("--> [Review Regression 7] Recreating missing file and refreshing ('r') updates availability...")
do
  local test_sidebar = require("unwind.sidebar")
  local test_root = vim.fs.normalize(vim.fn.getcwd())
  local dynamic_file = test_root .. "/tests/fixtures/reappear.py"
  pcall(os.remove, dynamic_file)

  unwind.clear()
  unwind.ingest('File "tests/fixtures/reappear.py", line 1, in f_reappear\n')
  local s = unwind.state.active_session
  assert_eq(s.files[1].available, false, "file starts unavailable")

  -- Create file on disk
  local f = io.open(dynamic_file, "w")
  f:write("print('now I exist')\n")
  f:close()

  -- Call refresh_availability
  unwind.refresh_availability()
  assert_eq(s.files[1].available, true, "file becomes available after refresh")

  -- Clean up
  os.remove(dynamic_file)
  unwind.clear()
end
