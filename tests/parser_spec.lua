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
assert_true(header:find("Frame #1/5") ~= nil, "header should contain Frame #1/5, got: " .. header)

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
  unwind.jump_to_frame(1)
  local bufs_after = #vim.api.nvim_list_bufs()
  assert_eq(bufs_after, bufs_before, "nonexistent file should not add an empty buffer to buffer list")
  assert_eq(unwind.state.active_index, 0, "active_index should NOT be updated if file open failed")
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

print("All parser, collector & integration unit tests PASSED successfully!")
