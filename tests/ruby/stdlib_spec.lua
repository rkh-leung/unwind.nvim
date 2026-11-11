-- tests/ruby/stdlib_spec.lua
-- Tests for Ruby standard-library resolution robustness across sparse directory structures

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

local stdlib = require("unwind.resolvers.ruby.stdlib")
local test_env = require("tests.helpers.environment")
local isolated = test_env.setup_isolated_env()

local root_dir = test_env.create_temp_dir("ruby_stdlib_")
local dir_rubylib = root_dir .. "/rubylib"
local dir_arch = root_dir .. "/arch"
local dir_site = root_dir .. "/site"
local dir_vendor = root_dir .. "/vendor"

vim.fn.mkdir(dir_rubylib, "p")
vim.fn.mkdir(dir_arch, "p")
vim.fn.mkdir(dir_site, "p")
vim.fn.mkdir(dir_vendor, "p")

local function touch(path)
  local f = io.open(path, "w")
  if f then
    f:write("# ruby\n")
    f:close()
  end
end

print("--> [Ruby Stdlib Spec 1] All directories available...")
do
  touch(dir_rubylib .. "/json.rb")
  local env = {
    rubylibdir = dir_rubylib,
    archdir = dir_arch,
    sitelibdir = dir_site,
    vendorlibdir = dir_vendor,
  }
  local res = stdlib.resolve({ stdlib_path = "json.rb", module_name = "json" }, env)
  assert_true(res ~= nil, "found json.rb")
  assert_eq(res.path, vim.fs.normalize(dir_rubylib .. "/json.rb"))
  assert_eq(res.module, "json")
end

print("--> [Ruby Stdlib Spec 2] Only rubylibdir available (others nil)...")
do
  local env = {
    rubylibdir = dir_rubylib,
    archdir = nil,
    sitelibdir = nil,
    vendorlibdir = nil,
  }
  local res = stdlib.resolve({ stdlib_path = "json.rb", module_name = "json" }, env)
  assert_true(res ~= nil, "found json.rb in rubylibdir")
  assert_eq(res.path, vim.fs.normalize(dir_rubylib .. "/json.rb"))
end

print("--> [Ruby Stdlib Spec 3] rubylibdir is nil but archdir available...")
do
  touch(dir_arch .. "/socket.so")
  local env = {
    rubylibdir = nil,
    archdir = dir_arch,
    sitelibdir = nil,
    vendorlibdir = nil,
  }
  local res = stdlib.resolve({ stdlib_path = "socket.so", module_name = "socket" }, env)
  assert_true(res ~= nil, "found socket.so in archdir despite nil rubylibdir")
  assert_eq(res.path, vim.fs.normalize(dir_arch .. "/socket.so"))
end

print("--> [Ruby Stdlib Spec 4] Missing middle entry (archdir nil) followed by valid later directory (sitelibdir)...")
do
  touch(dir_site .. "/custom.rb")
  local env = {
    rubylibdir = dir_rubylib,
    archdir = nil,
    sitelibdir = dir_site,
    vendorlibdir = dir_vendor,
  }
  local res = stdlib.resolve({ stdlib_path = "custom.rb", module_name = "custom" }, env)
  assert_true(res ~= nil, "found custom.rb in sitelibdir despite nil archdir")
  assert_eq(res.path, vim.fs.normalize(dir_site .. "/custom.rb"))
end

print("--> [Ruby Stdlib Spec 5] Only vendorlibdir available (all prior directories nil)...")
do
  touch(dir_vendor .. "/vendor_lib.rb")
  local env = {
    rubylibdir = nil,
    archdir = nil,
    sitelibdir = nil,
    vendorlibdir = dir_vendor,
  }
  local res = stdlib.resolve({ stdlib_path = "vendor_lib.rb", module_name = "vendor_lib" }, env)
  assert_true(res ~= nil, "found vendor_lib.rb in vendorlibdir when all others are nil")
  assert_eq(res.path, vim.fs.normalize(dir_vendor .. "/vendor_lib.rb"))
end

print("--> [Ruby Stdlib Spec 6] Deterministic precedence (file in both rubylibdir and sitelibdir)...")
do
  touch(dir_rubylib .. "/conflict.rb")
  touch(dir_site .. "/conflict.rb")
  local env = {
    rubylibdir = dir_rubylib,
    archdir = dir_arch,
    sitelibdir = dir_site,
    vendorlibdir = dir_vendor,
  }
  local res = stdlib.resolve({ stdlib_path = "conflict.rb", module_name = "conflict" }, env)
  assert_true(res ~= nil, "found conflict.rb")
  assert_eq(res.path, vim.fs.normalize(dir_rubylib .. "/conflict.rb"), "rubylibdir takes precedence over sitelibdir")
end

print("--> [Ruby Stdlib Spec 7] No directories or file missing everywhere...")
do
  local env_empty = {}
  local res1 = stdlib.resolve({ stdlib_path = "json.rb", module_name = "json" }, env_empty)
  assert_eq(res1, nil, "returns nil when env is empty")

  local env_full = {
    rubylibdir = dir_rubylib,
    archdir = dir_arch,
    sitelibdir = dir_site,
    vendorlibdir = dir_vendor,
  }
  local res2 = stdlib.resolve({ stdlib_path = "nonexistent.rb", module_name = "nonexistent" }, env_full)
  assert_eq(res2, nil, "returns nil when file is absent from all search dirs")
end

isolated.cleanup()
test_env.cleanup_all()

print("All Ruby stdlib spec tests PASSED successfully!")
