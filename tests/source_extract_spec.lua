-- tests/source_extract_spec.lua
-- Unit tests for Tree-sitter method extraction, fallback excerpts, and buffer reading

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

local source_extract = require("unwind.source_extract")

print("--> [Source Extract 1] Language fence detection...")
do
  assert_eq(source_extract.detect_fence_lang("foo.rb"), "ruby")
  assert_eq(source_extract.detect_fence_lang("foo.py"), "python")
  assert_eq(source_extract.detect_fence_lang("foo.lua"), "lua")
  assert_eq(source_extract.detect_fence_lang("foo.js"), "javascript")
  assert_eq(source_extract.detect_fence_lang("foo.ts"), "typescript")
  assert_eq(source_extract.detect_fence_lang("unknown.xyz"), "xyz")
end

print("--> [Source Extract 2] Method name mismatch detection...")
do
  assert_true(source_extract.methods_disagree("expected_method", "completely_different"))
  assert_true(not source_extract.methods_disagree("FeedInRow#feed_in_row", "feed_in_row"))
  assert_true(not source_extract.methods_disagree("Foo::Bar.call", "call"))
  assert_true(not source_extract.methods_disagree("block in run", "run"))
  assert_true(not source_extract.methods_disagree(nil, "anything"))
end

print("--> [Source Extract 3] Reading disk vs unsaved buffer...")
do
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/sample.py"

  local f = io.open(file_path, "w")
  f:write("def disk_version():\n    return 1\n")
  f:close()

  -- Read from disk
  local res1 = source_extract.read_source(file_path)
  assert_true(res1 ~= nil, "read from disk succeeds")
  assert_eq(res1.source_type, "disk")
  assert_eq(res1.is_modified, false)
  assert_eq(res1.lines[1], "def disk_version():")

  -- Open buffer and make unsaved modifications
  local bufnr = vim.fn.bufadd(file_path)
  vim.fn.bufload(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "def buffer_version():", "    return 2" })
  vim.bo[bufnr].modified = true

  local res2 = source_extract.read_source(file_path)
  assert_true(res2 ~= nil, "read from loaded buffer succeeds")
  assert_eq(res2.source_type, "buffer (unsaved)")
  assert_eq(res2.is_modified, true)
  assert_eq(res2.lines[1], "def buffer_version():")

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  pcall(vim.fn.delete, temp_dir, "rf")
end

print("--> [Source Extract 4] Method extraction with Lua / fallback...")
do
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/test.lua"

  local lua_code = table.concat({
    "local function helper_fn()",
    "  local x = 10",
    "  return x * 2",
    "end",
    "",
    "local function main_fn(arg)",
    "  local y = helper_fn()",
    "  return y + arg",
    "end",
  }, "\n")

  local f = io.open(file_path, "w")
  f:write(lua_code)
  f:close()

  local ext = source_extract.extract(file_path, 2, { method_hint = "helper_fn" })
  assert_true(ext ~= nil, "extracted function")
  assert_eq(ext.lang, "lua")
  assert_true(ext.code:find("helper_fn") ~= nil, "contains function code")

  local ext2 = source_extract.extract(file_path, 8, { method_hint = "main_fn" })
  assert_true(ext2 ~= nil, "extracted second function")
  assert_true(ext2.code:find("main_fn") ~= nil, "contains second function code")

  -- Location outside function or parser unavailable extracts excerpt
  local ext3 = source_extract.extract(file_path, 5)
  assert_true(ext3 ~= nil, "fallback excerpt extracted")
  if ext3.kind == "excerpt" then
    assert_true(ext3.warning ~= nil, "excerpt includes warning")
  end

  pcall(vim.fn.delete, temp_dir, "rf")
end

print("--> [Source Extract 5] Methods longer than 400 lines extract completely without truncation...")
do
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/long.lua"

  local lines = { "local function huge_function()" }
  for i = 1, 450 do
    table.insert(lines, "  local a" .. i .. " = " .. i)
  end
  table.insert(lines, "  return 0")
  table.insert(lines, "end")

  local f = io.open(file_path, "w")
  f:write(table.concat(lines, "\n"))
  f:close()

  local ext = source_extract.extract(file_path, 2)
  assert_true(ext ~= nil, "extracted method")
  assert_eq(ext.kind, "method", "extracted as full method")
  assert_eq(ext.incomplete, false, "method is complete")
  assert_true(ext.code:find("local a1 = 1") ~= nil, "contains beginning lines")
  assert_true(ext.code:find("local a450 = 450") ~= nil, "contains end lines past 400 lines")

  local line_count = #vim.split(ext.code, "\n", { plain = true })
  assert_true(line_count >= 452, "all 452 lines of method preserved")

  pcall(vim.fn.delete, temp_dir, "rf")
end

print("--> [Source Extract 6] Missing source file handling...")
do
  local ext = source_extract.extract("/nonexistent/path/to/missing_file.py", 10)
  assert_eq(ext, nil, "returns nil on missing source file without crashing")
end

print("--> [Source Extract 7] Indented method & column fallback to first non-whitespace byte...")
do
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/indented.lua"

  local code = table.concat({
    "local M = {}",
    "    local function indented_helper()",
    "      local val = 42",
    "      return val",
    "    end",
    "return M",
  }, "\n")

  local f = io.open(file_path, "w")
  f:write(code)
  f:close()

  -- Column 1 is leading whitespace: extractor must fall back to first non-whitespace byte
  local ext1 = source_extract.extract(file_path, 2, { col = 1 })
  assert_true(ext1 ~= nil, "extracted indented method with col 1")
  assert_eq(ext1.kind, "method")
  assert_eq(ext1.name, "indented_helper")
  assert_true(ext1.code:find("return val") ~= nil)

  -- Missing column: extractor falls back to first non-whitespace byte
  local ext2 = source_extract.extract(file_path, 2)
  assert_true(ext2 ~= nil, "extracted indented method without col")
  assert_eq(ext2.name, "indented_helper")

  -- Column inside method body: statement at line 3, col 7
  local ext3 = source_extract.extract(file_path, 3, { col = 7 })
  assert_true(ext3 ~= nil, "extracted enclosing method from statement inside body")
  assert_eq(ext3.name, "indented_helper")

  pcall(vim.fn.delete, temp_dir, "rf")
end

print("--> [Source Extract 8] End-exclusive ranges: sentinel line between adjacent methods excluded...")
do
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/adjacent.lua"

  local code = table.concat({
    "-- line 1",
    "local function method_one()",
    "  local x = 1",
    "  return x",
    "end",
    "-- line 6: DISTINCTIVE_SENTINEL_LINE",
    "local function method_two()",
    "  local y = 2",
    "  return y",
    "end",
  }, "\n")

  local f = io.open(file_path, "w")
  f:write(code)
  f:close()

  local ext = source_extract.extract(file_path, 3, { method_hint = "method_one" })
  assert_true(ext ~= nil, "extracted method_one")
  assert_eq(ext.kind, "method")
  assert_eq(ext.start_line, 2, "start_line is 2")
  assert_eq(ext.end_line, 5, "end_line is 5")

  assert_true(ext.code:find("method_one") ~= nil, "includes declaration")
  assert_true(ext.code:find("return x") ~= nil, "includes body")
  assert_true(ext.code:find("end") ~= nil, "includes closing end delimiter")
  assert_true(ext.code:find("DISTINCTIVE_SENTINEL_LINE") == nil, "sentinel line strictly excluded")
  assert_true(ext.code:find("method_two") == nil, "following method strictly excluded")

  pcall(vim.fn.delete, temp_dir, "rf")
end

print("--> [Source Extract 9] Single-line vs multiline methods...")
do
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/single.lua"

  local code = "local function oneliner(a) return a * 2 end\n"
  local f = io.open(file_path, "w")
  f:write(code)
  f:close()

  local ext = source_extract.extract(file_path, 1, { method_hint = "oneliner" })
  assert_true(ext ~= nil, "extracted single line method")
  assert_eq(ext.kind, "method")
  assert_eq(ext.start_line, 1)
  assert_eq(ext.end_line, 1)
  assert_eq(ext.code, "local function oneliner(a) return a * 2 end")

  pcall(vim.fn.delete, temp_dir, "rf")
end

print("--> [Source Extract 10] Multiple functions on one line resolved by column...")
do
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/two_on_one_line.lua"

  local code = "local function first_fn() return 1 end; local function second_fn() return 2 end\n"
  local f = io.open(file_path, "w")
  f:write(code)
  f:close()

  -- Column 15 points into first_fn
  local ext1 = source_extract.extract(file_path, 1, { column = 15 })
  assert_true(ext1 ~= nil)
  assert_eq(ext1.name, "first_fn")

  -- Column 55 points into second_fn
  local ext2 = source_extract.extract(file_path, 1, { column = 55 })
  assert_true(ext2 ~= nil)
  assert_eq(ext2.name, "second_fn")

  pcall(vim.fn.delete, temp_dir, "rf")
end

print("--> [Source Extract 11] Empty line and out-of-bounds column...")
do
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/edge_cases.lua"

  local code = "local function test_fn()\n\n  return 99\nend\n"
  local f = io.open(file_path, "w")
  f:write(code)
  f:close()

  -- Empty line 2
  local ext_empty = source_extract.extract(file_path, 2)
  assert_true(ext_empty ~= nil)
  assert_eq(ext_empty.name, "test_fn")

  -- Column way outside line length (e.g. col 999)
  local ext_oob = source_extract.extract(file_path, 1, { col = 999 })
  assert_true(ext_oob ~= nil)
  assert_eq(ext_oob.name, "test_fn")

  pcall(vim.fn.delete, temp_dir, "rf")
end

print("--> [Source Extract 12] UTF-8 text preceding function location...")
do
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/utf8.lua"

  -- Multibyte characters preceding function declaration
  local code = "-- 日本語テストコメント\nlocal function utf8_test_fn()\n  return 'ok'\nend\n"
  local f = io.open(file_path, "w")
  f:write(code)
  f:close()

  local ext = source_extract.extract(file_path, 2)
  assert_true(ext ~= nil)
  assert_eq(ext.name, "utf8_test_fn")
  assert_eq(ext.start_line, 2)
  assert_eq(ext.end_line, 4)

  pcall(vim.fn.delete, temp_dir, "rf")
end

print("All source_extract spec tests PASSED successfully!")
