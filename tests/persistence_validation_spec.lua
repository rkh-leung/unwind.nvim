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

print("--> [Persistence Val Top-Level 1] Missing sessions field rejected and protected...")
do
  local payload = {
    schema_version = 1,
    root = test_root,
  }
  local encoded_raw = vim.json.encode(payload)
  write_raw(encoded_raw)

  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root), "missing sessions marked corrupt")
  local saved_ok = persistence.save(test_root, {})
  assert_eq(saved_ok, false, "save refused")

  local f = io.open(storage_file, "r")
  assert_eq(f:read("*all"), encoded_raw, "bytes preserved")
  f:close()
end

print("--> [Persistence Val Top-Level 2] Missing schema_version rejected and protected...")
do
  local payload = {
    root = test_root,
    sessions = {},
  }
  local encoded_raw = vim.json.encode(payload)
  write_raw(encoded_raw)

  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root), "missing schema_version marked corrupt")
  local saved_ok = persistence.save(test_root, {})
  assert_eq(saved_ok, false, "save refused")

  local f = io.open(storage_file, "r")
  assert_eq(f:read("*all"), encoded_raw, "bytes preserved")
  f:close()
end

print("--> [Persistence Val Top-Level 3] Missing root rejected and protected...")
do
  local payload = {
    schema_version = 1,
    sessions = {},
  }
  local encoded_raw = vim.json.encode(payload)
  write_raw(encoded_raw)

  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root), "missing root marked corrupt")
  local saved_ok = persistence.save(test_root, {})
  assert_eq(saved_ok, false, "save refused")

  local f = io.open(storage_file, "r")
  assert_eq(f:read("*all"), encoded_raw, "bytes preserved")
  f:close()
end

print("--> [Persistence Val Top-Level 4] Explicit null top-level fields rejected...")
do
  local raw_null_sessions = '{"schema_version": 1, "root": "' .. test_root .. '", "sessions": null}'
  write_raw(raw_null_sessions)
  local loaded1 = persistence.load(test_root)
  assert_eq(#loaded1, 0)
  assert_true(persistence.is_corrupted(test_root))
  assert_eq(persistence.save(test_root, {}), false)

  local raw_null_root = '{"schema_version": 1, "root": null, "sessions": []}'
  write_raw(raw_null_root)
  local loaded2 = persistence.load(test_root)
  assert_eq(#loaded2, 0)
  assert_true(persistence.is_corrupted(test_root))
  assert_eq(persistence.save(test_root, {}), false)

  local raw_null_version = '{"schema_version": null, "root": "' .. test_root .. '", "sessions": []}'
  write_raw(raw_null_version)
  local loaded3 = persistence.load(test_root)
  assert_eq(#loaded3, 0)
  assert_true(persistence.is_corrupted(test_root))
  assert_eq(persistence.save(test_root, {}), false)
end

print("--> [Persistence Val Top-Level 5] Explicitly empty sessions accepted...")
do
  local payload = {
    schema_version = 1,
    root = test_root,
    sessions = {},
  }
  write_raw(vim.json.encode(payload))
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(not persistence.is_corrupted(test_root), "valid empty state not corrupt")
  local saved_ok = persistence.save(test_root, loaded)
  assert_true(saved_ok, "saving permitted for valid empty state")
end

print("--> [Persistence Val Unreadable 1] Genuinely missing file vs existing unreadable file...")
do
  -- 1. Absent file
  local absent_root = test_env.create_temp_dir("absent_root_")
  local loaded_absent = persistence.load(absent_root)
  assert_eq(#loaded_absent, 0)
  assert_true(not persistence.is_corrupted(absent_root), "absent file is not corrupt")
  local saved_absent_ok = persistence.save(absent_root, {})
  assert_true(saved_absent_ok, "can save to create absent file")

  -- 2. Existing but unreadable file (simulated read failure)
  local unreadable_root = test_env.create_temp_dir("unreadable_root_")
  local u_file, u_dir = persistence.storage_path(unreadable_root)
  vim.fn.mkdir(u_dir, "p")
  local valid_content = vim.json.encode({
    schema_version = 1,
    root = unreadable_root,
    sessions = {
      {
        id = "u_sess",
        name = "Unreadable Session",
        frames = { { file = "a.py", line = 1 } },
      },
    },
  })
  local f = io.open(u_file, "w")
  f:write(valid_content)
  f:close()

  -- Confirm file exists on disk
  local stat = (vim.uv or vim.loop).fs_stat(u_file)
  assert_true(stat ~= nil, "file exists on disk")

  -- Mock io.open to simulate read failure specifically on u_file with mode "r"
  local orig_io_open = io.open
  io.open = function(path, mode)
    if vim.fs.normalize(path) == vim.fs.normalize(u_file) and (mode == "r" or mode == nil) then
      return nil
    end
    return orig_io_open(path, mode)
  end

  local loaded_unreadable = persistence.load(unreadable_root)
  assert_eq(#loaded_unreadable, 0)
  assert_true(persistence.is_corrupted(unreadable_root), "unreadable file marked corrupt")

  -- Subsequent save attempt is refused
  local save_blocked = persistence.save(unreadable_root, {})
  assert_eq(save_blocked, false, "refused to overwrite unreadable file")

  -- Restore io.open
  io.open = orig_io_open

  -- File content on disk is completely untouched
  local f_check = io.open(u_file, "r")
  assert_eq(f_check:read("*all"), valid_content, "unreadable file bytes preserved")
  f_check:close()

  -- Recovery: when readable again, load succeeds and clears corruption flag
  local recovered_sessions = persistence.load(unreadable_root)
  assert_eq(#recovered_sessions, 1, "session recovered")
  assert_true(not persistence.is_corrupted(unreadable_root), "corrupted status cleared")
  local save_recovered = persistence.save(unreadable_root, recovered_sessions)
  assert_true(save_recovered, "saving permitted after recovery")
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

print("--> [Persistence Val 6] Invalid frame entries fail load and protect data from overwrite...")
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
  local encoded_raw = vim.json.encode(payload)
  write_raw(encoded_raw)
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0, "malformed frame fails load entirely to prevent data loss")
  assert_true(persistence.is_corrupted(test_root), "flagged as corrupt")

  -- Subsequent save is refused
  local saved_ok = persistence.save(test_root, {})
  assert_eq(saved_ok, false, "refuses to overwrite corrupted file")

  -- Verify original file bytes remain intact
  local f = io.open(storage_file, "r")
  local bytes = f:read("*all")
  f:close()
  assert_eq(bytes, encoded_raw, "original file bytes preserved")
end

print("--> [Persistence Val 6b] Root mismatch fails closed and protects data from overwrite...")
do
  local foreign_root = "/another/foreign/project"
  local payload = {
    schema_version = 1,
    root = foreign_root,
    sessions = {
      {
        id = "s1",
        name = "Foreign Root Session",
        frames = {
          { file = "main.py", line = 10 },
        },
      },
    },
  }
  local encoded_raw = vim.json.encode(payload)
  write_raw(encoded_raw)

  -- Loading under test_root should detect root mismatch, fail load, and flag corruption
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root), "root mismatch flagged as corrupt")

  -- Save attempt under test_root must be blocked
  local saved_ok = persistence.save(test_root, {})
  assert_eq(saved_ok, false, "refused to overwrite foreign root state")

  -- Verify original file bytes intact
  local f = io.open(storage_file, "r")
  local bytes = f:read("*all")
  f:close()
  assert_eq(bytes, encoded_raw, "foreign root file bytes preserved")
end

print("--> [Persistence Val 6c] Non-string root type fails closed and protects data...")
do
  local payload = {
    schema_version = 1,
    root = 12345, -- invalid type
    sessions = {},
  }
  local encoded_raw = vim.json.encode(payload)
  write_raw(encoded_raw)

  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0)
  assert_true(persistence.is_corrupted(test_root), "invalid root type flagged as corrupt")

  local saved_ok = persistence.save(test_root, {})
  assert_eq(saved_ok, false)

  local f = io.open(storage_file, "r")
  local bytes = f:read("*all")
  f:close()
  assert_eq(bytes, encoded_raw)
end

print("--> [Persistence Val 6d] Invalid line or col values rejected cleanly...")
do
  local payload_bad_line = {
    schema_version = 1,
    root = test_root,
    sessions = {
      {
        id = "s_bad_line",
        name = "Bad Line",
        frames = {
          { file = "ok.py", line = -5 },
        },
      },
    },
  }
  local encoded_bad_line = vim.json.encode(payload_bad_line)
  write_raw(encoded_bad_line)
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 0, "negative line rejected")
  assert_true(persistence.is_corrupted(test_root))

  local payload_bad_col = {
    schema_version = 1,
    root = test_root,
    sessions = {
      {
        id = "s_bad_col",
        name = "Bad Col",
        frames = {
          { file = "ok.py", line = 10, col = "not_a_num" },
        },
      },
    },
  }
  local encoded_bad_col = vim.json.encode(payload_bad_col)
  write_raw(encoded_bad_col)
  local loaded2 = persistence.load(test_root)
  assert_eq(#loaded2, 0, "invalid col string rejected")
  assert_true(persistence.is_corrupted(test_root))
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
