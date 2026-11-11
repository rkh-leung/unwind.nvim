-- tests/isolation_spec.lua
-- Verifies that test and benchmark runners do not modify, read, or delete real user state

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

print("--> [Isolation Spec] Verifying persistence isolation from user state...")
do
  -- Create a sentinel session under a mocked non-test root in a controlled location
  local sentinel_root = "/tmp/unwind_sentinel_project_root"
  local sentinel_file, sentinel_dir = persistence.storage_path(sentinel_root)
  vim.fn.mkdir(sentinel_dir, "p")

  local sentinel_data = {
    schema_version = 1,
    root = sentinel_root,
    sessions = {
      {
        id = "sentinel_sess_1",
        name = "Genuine User Session",
        filter_enabled = false,
        created_at = 1234567890,
        updated_at = 1234567890,
        frames = {
          {
            path = "app/models/user.rb",
            file = "app/models/user.rb",
            line = 42,
            col = 1,
            method = "find_by_token",
            origin = "manual",
            raw_line = "app/models/user.rb:42",
          },
        },
      },
    },
  }

  local f = io.open(sentinel_file, "w")
  assert_true(f ~= nil, "could create sentinel file")
  f:write(vim.json.encode(sentinel_data))
  f:close()

  local initial_stat = (vim.uv or vim.loop).fs_stat(sentinel_file)
  local f_read = io.open(sentinel_file, "r")
  local initial_content = f_read:read("*all")
  f_read:close()

  -- Perform session operations in test
  local test_env = require("tests.helpers.environment")
  local isolated = test_env.setup_isolated_env()
  local test_root = test_env.create_temp_dir("isolation_test_")

  local s = sessions.create({ root = test_root, name = "Test Session" })
  sessions.add_frame(s, { file = "test.lua", line = 1, origin = "manual" })
  local list = {}
  sessions.save_working(s, "Test Session", list, test_root)

  isolated.cleanup()
  test_env.cleanup_all()

  -- Verify sentinel file is completely untouched
  local post_stat = (vim.uv or vim.loop).fs_stat(sentinel_file)
  assert_true(post_stat ~= nil, "sentinel file still exists")

  local f_post = io.open(sentinel_file, "r")
  local post_content = f_post:read("*all")
  f_post:close()

  assert_eq(post_content, initial_content, "sentinel content unchanged")
  assert_eq(post_stat.size, initial_stat.size, "sentinel size unchanged")

  pcall(os.remove, sentinel_file)
end

print("Isolation spec tests PASSED successfully!")
