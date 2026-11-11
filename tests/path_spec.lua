-- tests/path_spec.lua
-- Tests for pure path utility functions: canonicalize, is_file, is_in_root, compile_mappings

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

local path = require("unwind.path")

print("--> [Path Spec 1] Lexical canonicalization...")
do
  assert_eq(path.canonicalize("foo/bar/../baz"), "foo/baz")
  assert_eq(path.canonicalize("foo/./bar"), "foo/bar")
  assert_eq(path.canonicalize("/foo/bar/../../baz"), "/baz")
  assert_eq(path.canonicalize("C:\\foo\\bar\\..\\baz"), "C:/foo/baz")
  assert_eq(path.canonicalize("foo/bar/"), "foo/bar")
end

print("--> [Path Spec 2] Workspace containment...")
do
  local root = "/home/user/project"
  local inside, rel = path.is_in_root("/home/user/project/src/main.rs", root)
  assert_true(inside, "file is in root")
  assert_eq(rel, "src/main.rs", "correct relative path")

  local outside = path.is_in_root("/home/user/other/file.txt", root)
  assert_true(not outside, "file is not in root")

  local prefix_trick = path.is_in_root("/home/user/project_fake/file.txt", root)
  assert_true(not prefix_trick, "prefix boundary check")
end

print("--> [Path Spec 3] Path mappings compilation...")
do
  local mappings = {
    ["/short/"] = "./src/",
    ["/very/long/prefix/"] = "./vendor/",
  }
  local compiled = path.compile_mappings(mappings)
  assert_eq(#compiled, 2, "2 compiled mappings")
  assert_eq(compiled[1].prefix, "/very/long/prefix/", "longest prefix first")
  assert_eq(compiled[2].prefix, "/short/", "shorter prefix second")
end

print("--> [Path Spec 4] File presence and stat cache...")
do
  local cache = {}
  local is_f = path.is_file("README.md", cache)
  assert_true(is_f, "README.md exists and is a file")
  assert_eq(cache["README.md"], true, "cached file existence")

  local is_dir = path.is_file("lua", cache)
  assert_true(not is_dir, "directory is not a file")
  assert_eq(cache["lua"], false, "cached non-file")
end

print("All path spec tests PASSED successfully!")
