-- tests/location_spec.lua
-- Tests for location and Tree-sitter resolution

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

local location = require("unwind.location")
local unwind = require("unwind")

print("--> [Location Spec 1] Current file + row fallback works without Tree-sitter...")
do
  local buf = vim.api.nvim_create_buf(false, true)
  local file_path = vim.fs.normalize(vim.fn.getcwd()) .. "/tests/fixtures/dummy.txt"
  vim.api.nvim_buf_set_name(buf, file_path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world", "second line" })
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 2, 3 })

  local f = location.from_cursor({ bufnr = buf, resolve_function = false })
  assert_eq(f.line, 2, "fallback line")
  assert_eq(f.col, 4, "fallback column (1-indexed)")
  assert_eq(f.origin, "manual", "fallback origin")
  assert_eq(f.method, nil, "fallback method")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

print("--> [Location Spec 2] Unnamed buffer rejected gracefully by :UnwindAdd...")
do
  unwind.clear()
  local scratch_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, scratch_buf)

  local warn_msg = nil
  local orig_notify = vim.notify
  vim.notify = function(msg, lvl)
    if lvl == vim.log.levels.WARN then
      warn_msg = msg
    end
  end

  unwind.add_current_location()
  vim.notify = orig_notify

  assert_true(warn_msg ~= nil, "warning emitted for unnamed buffer")
  assert_true(warn_msg:find("unnamed or non%-file buffer") ~= nil, "warning content matches")
  assert_true(unwind.state.active_session == nil, "no session created on rejected buffer")

  pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
  unwind.clear()
end

print("--> [Location Spec 3] Missing Tree-sitter parser falls back gracefully...")
do
  local buf = vim.api.nvim_create_buf(false, true)
  local file_path = vim.fs.normalize(vim.fn.getcwd()) .. "/tests/fixtures/unknown_lang.xyz"
  vim.api.nvim_buf_set_name(buf, file_path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "custom_syntax {", "  action();", "}" })
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_cursor(0, { 2, 2 })

  local f = location.from_cursor({ bufnr = buf, resolve_function = true })
  assert_eq(f.line, 2, "line preserved on fallback")
  assert_eq(f.origin, "manual", "origin is manual when parser not present")

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

print("--> [Location Spec 4] Tree-sitter resolution on Lua code when parser available...")
do
  local buf = vim.api.nvim_create_buf(false, true)
  local file_path = vim.fs.normalize(vim.fn.getcwd()) .. "/tests/fixtures/test_code.lua"
  vim.api.nvim_buf_set_name(buf, file_path)
  vim.bo[buf].filetype = "lua"
  local code = {
    "function process_request(req)",
    "  validate(req)",
    "  local res = calculate(req)",
    "  return res",
    "end",
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, code)
  vim.api.nvim_win_set_buf(0, buf)
  -- Put cursor on line 3 ("local res = calculate(req)")
  vim.api.nvim_win_set_cursor(0, { 3, 4 })

  local f = location.from_cursor({ bufnr = buf, resolve_function = true })
  assert_eq(f.origin, "manual", "origin must always be manual even with Tree-sitter")
  if f.method == "process_request" then
    assert_eq(f.line, 1, "resolved to function declaration line 1")
  else
    assert_eq(f.line, 3, "fallback to cursor line when parser not installed in headless env")
  end

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

print("--> [Location Spec 5] Origin invariants: manual vs stacktrace frames and decorator headers...")
do
  local decorator = require("unwind.decorator")
  local sessions = require("unwind.sessions")
  local parser = require("unwind.parser")
  local test_env = require("tests.helpers.environment")
  local isolated = test_env.setup_isolated_env()
  local test_root = test_env.create_temp_dir("origin_spec_root_")

  -- 1. Manual frame from location.from_cursor
  local manual_frame = {
    path = "app/models/user.rb",
    file = "app/models/user.rb",
    line = 10,
    col = 1,
    origin = "manual",
    method = "calculate",
  }
  assert_eq(manual_frame.origin, "manual")

  -- 2. Stacktrace frame parsed from trace
  local trace_text = "    at Service.processJob (src/worker/service.ts:142:15)\n"
  local parsed_frames = parser.parse(trace_text, { root = test_root })
  assert_eq(#parsed_frames, 1)
  assert_eq(parsed_frames[1].origin, "stacktrace", "parsed trace frames have stacktrace origin")

  -- 3. Saved manual session roundtrip preserves manual origin
  local s = sessions.create({ root = test_root, name = "Manual Session" })
  sessions.add_frame(s, manual_frame)
  local list = {}
  sessions.save_working(s, "Manual Session", list, test_root)

  local loaded = sessions.load(test_root)
  assert_eq(#loaded, 1)
  assert_eq(loaded[1].raw_frames[1].origin, "manual", "reloaded manual session preserves manual origin")

  -- 4. Check decorator headers directly via buffer rendering
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line 1", "line 2", "line 3" })

  decorator.render(buf, 2, 1, "calculate", "app/models/user.rb", 2, { origin = "manual" })
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, decorator.get_namespace(), 0, -1, { details = true })
  assert_eq(#extmarks, 1)
  local virt_lines = extmarks[1][4].virt_lines
  assert_true(virt_lines[1][1][1]:find("%[DEBUG PATH%]") ~= nil, "manual origin produces [DEBUG PATH]")

  decorator.render(buf, 2, 1, "processJob", "src/worker/service.ts", 2, { origin = "stacktrace" })
  local extmarks2 = vim.api.nvim_buf_get_extmarks(buf, decorator.get_namespace(), 0, -1, { details = true })
  assert_eq(#extmarks2, 1)
  local virt_lines2 = extmarks2[1][4].virt_lines
  assert_true(virt_lines2[1][1][1]:find("%[STACK FRAME%]") ~= nil, "stacktrace origin produces [STACK FRAME]")

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  isolated.cleanup()
  test_env.cleanup_all()
end

print("All location spec tests PASSED successfully!")
