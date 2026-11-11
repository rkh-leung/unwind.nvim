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

print("--> [Source Extract 5] Method line truncation...")
do
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")
  local file_path = temp_dir .. "/long.lua"

  local lines = { "local function huge_function()" }
  for i = 1, 50 do
    table.insert(lines, "  local a" .. i .. " = " .. i)
  end
  table.insert(lines, "  return 0")
  table.insert(lines, "end")

  local f = io.open(file_path, "w")
  f:write(table.concat(lines, "\n"))
  f:close()

  local ext = source_extract.extract(file_path, 2, { max_method_lines = 10 })
  assert_true(ext ~= nil, "extracted method")
  if ext.kind == "method" then
    assert_true(ext.truncated, "method was truncated")
    assert_true(ext.code:find("truncated") ~= nil, "includes truncation notice in code")
  end

  pcall(vim.fn.delete, temp_dir, "rf")
end

print("--> [Source Extract 6] Missing source file handling...")
do
  local ext = source_extract.extract("/nonexistent/path/to/missing_file.py", 10)
  assert_eq(ext, nil, "returns nil on missing source file without crashing")
end

print("All source_extract spec tests PASSED successfully!")
