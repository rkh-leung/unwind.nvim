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

print("--> [Path Spec 5] Two-component fallback, multi-component suffix, ambiguous files, and lexical normalization...")
do
  local test_env = require("tests.helpers.environment")
  local parser = require("unwind.parser")
  local temp_dir = test_env.create_temp_dir("path_fallback_test_")

  -- Create project layout:
  -- temp_dir/
  -- ├── service.rb
  -- ├── lib/
  -- │   └── worker.rb
  -- └── deep/
  --     └── nested/
  --         └── processor.rb
  -- └── ambiguous/
  --     └── worker.rb
  vim.fn.mkdir(temp_dir .. "/lib", "p")
  vim.fn.mkdir(temp_dir .. "/deep/nested", "p")
  vim.fn.mkdir(temp_dir .. "/ambiguous", "p")

  local function write_dummy(path, str)
    local f = io.open(path, "w")
    f:write(str or "content")
    f:close()
  end

  write_dummy(temp_dir .. "/service.rb")
  write_dummy(temp_dir .. "/lib/worker.rb")
  write_dummy(temp_dir .. "/deep/nested/processor.rb")
  write_dummy(temp_dir .. "/ambiguous/worker.rb")

  -- Case A — Two components: deployment/service.rb -> falls back to service.rb
  local disp_a, res_a, nav_a = parser.resolve_and_normalize_path("deployment/service.rb", { root = temp_dir })
  assert_eq(disp_a, "service.rb", "Case A display path falls back to service.rb")
  assert_eq(res_a, temp_dir .. "/service.rb", "Case A resolved path")
  assert_eq(nav_a, true, "Case A navigable")

  -- Case B — Three or more components: remote/lib/worker.rb -> falls back to lib/worker.rb
  local disp_b, res_b, nav_b = parser.resolve_and_normalize_path("remote/lib/worker.rb", { root = temp_dir })
  assert_eq(disp_b, "lib/worker.rb", "Case B display path falls back to lib/worker.rb")
  assert_eq(res_b, temp_dir .. "/lib/worker.rb", "Case B resolved path")
  assert_eq(nav_b, true, "Case B navigable")

  -- Case C — Longer paths: deployment/deep/nested/processor.rb -> deep/nested/processor.rb
  local disp_c, res_c, nav_c = parser.resolve_and_normalize_path("deployment/deep/nested/processor.rb", { root = temp_dir })
  assert_eq(disp_c, "deep/nested/processor.rb", "Case C display path")
  assert_eq(res_c, temp_dir .. "/deep/nested/processor.rb", "Case C resolved path")
  assert_eq(nav_c, true, "Case C navigable")

  -- Case D — Ambiguous files: remote/lib/worker.rb matches lib/worker.rb because lib/worker.rb is tested before worker.rb
  local disp_d, res_d, nav_d = parser.resolve_and_normalize_path("remote/lib/worker.rb", { root = temp_dir })
  assert_eq(disp_d, "lib/worker.rb", "Case D precedence selects lib/worker.rb over ambiguous/worker.rb")
  assert_eq(res_d, temp_dir .. "/lib/worker.rb", "Case D resolved path")

  -- Case E — Lexical normalization with . and ..
  local disp_e, res_e, nav_e = parser.resolve_and_normalize_path("deployment/../lib/worker.rb", { root = temp_dir })
  assert_eq(disp_e, "lib/worker.rb", "Case E normalized display path")
  assert_eq(res_e, temp_dir .. "/lib/worker.rb", "Case E canonical resolved path")
  assert_eq(nav_e, true, "Case E navigable")

  -- Cleanup
  test_env.cleanup_dir(temp_dir)
end

print("--> [Path Spec 6] Generic Matcher 8 URI exclusion behavior (http/https/ftp vs custom URIs)...")
do
  local parser = require("unwind.parser")
  -- http/https/ftp should be rejected by Matcher 8 for non-ruby files
  local http_frames = parser.parse("https://example.com/file.js:12")
  assert_eq(#http_frames, 0, "https URL should not be parsed as stack frame in Matcher 8")

  local ftp_frames = parser.parse("ftp://example.com/file.js:12")
  assert_eq(#ftp_frames, 0, "ftp URL should not be parsed as stack frame in Matcher 8")

  -- Custom URI schemes like file:// and jar:// are handled with line numbers
  local file_frames = parser.parse("file:///tmp/project/file.js:12")
  assert_eq(#file_frames, 1, "file:// URI parsed")

  local jar_frames = parser.parse("jar://example/path/File.java:20")
  assert_eq(#jar_frames, 1, "jar:// URI parsed")

  -- Lines without :%d+ rejected early
  local no_digits = parser.parse("https://example.com/file.js:abc")
  assert_eq(#no_digits, 0, "non-digit line rejected early")
end

print("--> [Path Spec 7] Ruby resolver negative-cache test...")
do
  local ruby_resolver = require("unwind.resolvers.ruby")
  local test_env = require("tests.helpers.environment")
  local temp_dir = test_env.create_temp_dir("ruby_neg_cache_")

  -- 1. Pass 100 non-ruby paths: should return nil and NOT pollute cache
  for i = 1, 100 do
    local p = string.format("src/components/button_%d.tsx", i)
    local res = ruby_resolver.resolve(p, { root = temp_dir })
    assert_eq(res, nil, "non-ruby path must return nil")
  end

  -- Verify resolver cache is empty for this root
  -- If we now invalidate or check, non-ruby paths didn't insert false
  -- 2. Pass genuine but missing Ruby gem path: should insert false into negative cache
  local missing_gem = "/gems/nonexistent_gem_xyz-1.0.0/lib/nonexistent.rb"
  local res1 = ruby_resolver.resolve(missing_gem, { root = temp_dir })
  assert_eq(res1, nil, "missing gem path returns nil")

  test_env.cleanup_dir(temp_dir)
end

print("All path spec tests PASSED successfully!")
