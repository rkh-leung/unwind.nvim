-- tests/ruby/git_gems_spec.lua
-- Tests for Bundler git gems resolution and directory caching

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

local git_gems = require("unwind.resolvers.ruby.git_gems")

print("--> [Git Gems Spec 1] Bundler git gem discovery and caching...")
do
  local test_root = "/tmp/test_git_gems"
  local bundler_gems_dir = test_root .. "/bundler/gems/mygem-abc123456789/lib"
  vim.fn.mkdir(bundler_gems_dir, "p")

  local test_file = bundler_gems_dir .. "/mygem.rb"
  local f = io.open(test_file, "w")
  f:write("module MyGem; end")
  f:close()

  local env = {
    gem_paths = { test_root },
  }

  local parsed = {
    gem_name = "mygem",
    revision = "abc1234", -- short SHA prefix
    relative_path = "lib/mygem.rb",
  }

  local res = git_gems.resolve(parsed, env)
  assert_true(res ~= nil, "git gem resolved")
  assert_eq(res.path, vim.fs.normalize(test_file))
  assert_eq(res.gem, "mygem")

  -- Subsequent resolve uses cached directory lookup
  local res2 = git_gems.resolve(parsed, env)
  assert_true(res2 ~= nil, "cached git gem resolved")
  assert_eq(res2.path, vim.fs.normalize(test_file))

  -- Cleanup
  git_gems.clear_cache()
  pcall(os.remove, test_file)
end

print("All git gems spec tests PASSED successfully!")
