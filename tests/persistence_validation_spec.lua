-- tests/persistence_validation_spec.lua
-- Tests for hardened persistence deserialization and corrupt file handling

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

local persistence = require("unwind.persistence")
local sessions = require("unwind.sessions")
local test_env = require("tests.helpers.environment")

local isolated = test_env.setup_isolated_env()
local test_root = test_env.create_temp_dir("persist_val_root_")
local storage_file, storage_dir = persistence.storage_path(test_root)
vim.fn.mkdir(storage_dir, "p")

local function write_raw(content)
  local f = io.open(storage_file, "w")
  assert_true(f ~= nil, "could open storage file")
  f:write(content)
  f:close()
end

print("--> [Persistence Val 1] Empty state file...")
do
  write_raw("")
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root), "flagged as corrupt")
  local saved_ok = persistence.save(test_root, {})
  assert_eq(saved_ok, false, "refused to overwrite empty/corrupted state")
end

print("--> [Persistence Val 2] Invalid JSON syntax...")
do
  write_raw("{ malformed json ...")
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root), "flagged as corrupt")
  local saved_ok = persistence.save(test_root, {})
  assert_eq(saved_ok, false, "refused to overwrite corrupt state")
end

print("--> [Persistence Val 3] Valid JSON with wrong top-level type (array instead of object)...")
do
  write_raw('[ "not", "an", "object" ]')
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root))
end

print("--> [Persistence Val 4] sessions field as string or object...")
do
  write_raw('{"schema_version": 1, "root": "' .. test_root .. '", "sessions": "not an array"}')
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root))

  write_raw('{"schema_version": 1, "root": "' .. test_root .. '", "sessions": {"key": "val"}}')
  local loaded2 = persistence.load(test_root)
  assert_eq(#loaded2, 0)
  assert_true(persistence.is_corrupted(test_root))
end

print("--> [Persistence Val 5] frames field as string or non-array...")
do
  local payload = {
    schema_version = 1,
    root = test_root,
    sessions = {
      {
        id = "s1",
        name = "Bad Frames Session",
        frames = "invalid_string",
      },
    },
  }
  write_raw(vim.json.encode(payload))
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root))
end

print("--> [Persistence Val 6] Invalid frame entries and missing path...")
do
  local payload = {
    schema_version = 1,
    root = test_root,
    sessions = {
      {
        id = "s1",
        name = "Mixed Frames Session",
        frames = {
          "not_a_table",
          { file = "", line = 10 }, -- empty path
          { file = "valid.lua", line = "invalid_line_str", col = nil, note = " hello " },
        },
      },
    },
  }
  write_raw(vim.json.encode(payload))
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 1)
  -- The one valid frame should be sanitized and loaded
  assert_eq(#loaded[1].raw_frames, 1)
  assert_eq(loaded[1].raw_frames[1].file, "valid.lua")
  assert_eq(loaded[1].raw_frames[1].line, 1, "invalid line fell back to 1")
  assert_eq(loaded[1].raw_frames[1].note, "hello", "trimmed note")
end

print("--> [Persistence Val 7] Unsupported future schema versions...")
do
  local payload = {
    schema_version = 999,
    root = test_root,
    sessions = {},
  }
  write_raw(vim.json.encode(payload))
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root))
end

print("--> [Persistence Val 8] Existing valid legacy sessions load cleanly...")
do
  local payload = {
    schema_version = 1,
    root = test_root,
    sessions = {
      {
        id = "legacy_1",
        name = "Legacy Session",
        filter_enabled = false,
        frames = {
          {
            path = "src/foo.py",
            file = "src/foo.py",
            line = 42,
            col = 5,
            method = "bar",
            origin = "manual",
          },
        },
      },
    },
  }
  write_raw(vim.json.encode(payload))
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 1)
  assert_eq(loaded[1].name, "Legacy Session")
  assert_eq(#loaded[1].raw_frames, 1)
  assert_eq(loaded[1].raw_frames[1].line, 42)
  assert_true(not persistence.is_corrupted(test_root))

  -- Save attempt succeeds on valid state
  local saved_ok = persistence.save(test_root, loaded)
  assert_true(saved_ok)
end

isolated.cleanup()
test_env.cleanup_all()

print("All persistence validation spec tests PASSED successfully!")
