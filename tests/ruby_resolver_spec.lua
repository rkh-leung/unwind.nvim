-- tests/ruby_resolver_spec.lua
-- Unit and integration test suite for Ruby language resolver (gems, bundler git gems, stdlib)

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_true(cond, msg)
  if not cond then
    error(msg or "assertion failed: expected true")
  end
end

local function write_file(path, content)
  local f = io.open(path, "w")
  assert_true(f ~= nil, "failed to open " .. path .. " for writing")
  f:write(content)
  f:close()
end

local ruby_path = require("unwind.resolvers.ruby.path")
local environment = require("unwind.resolvers.ruby.environment")
local gems = require("unwind.resolvers.ruby.gems")
local git_gems = require("unwind.resolvers.ruby.git_gems")
local stdlib = require("unwind.resolvers.ruby.stdlib")
local ruby = require("unwind.resolvers.ruby")
local unwind = require("unwind")
local parser = require("unwind.parser")
local sessions = require("unwind.sessions")

print("--> [Ruby Spec 1] Path parsing: gems, bundler git gems, stdlib...")
do
  -- 1. Regular gem
  local g = ruby_path.parse_gem_path("/apps/sample_app/shared/bundle/ruby/3.3.0/gems/i18n-1.8.11/lib/i18n.rb")
  assert_true(g ~= nil, "gem parsed")
  assert_eq(g.gem_name, "i18n")
  assert_eq(g.gem_version, "1.8.11")
  assert_eq(g.relative_path, "lib/i18n.rb")

  local g2 = ruby_path.parse_gem_path("/deploy/bundle/ruby/3.3.0/gems/actionpack-8.1.3.1/lib/abstract_controller/base.rb")
  assert_true(g2 ~= nil, "gem2 parsed")
  assert_eq(g2.gem_name, "actionpack")
  assert_eq(g2.gem_version, "8.1.3.1")
  assert_eq(g2.relative_path, "lib/abstract_controller/base.rb")

  -- 2. Bundler git gem
  local git = ruby_path.parse_bundler_git_path("/deploy/shared/bundle/ruby/3.3.0/bundler/gems/flux-jobs-9e92dbf2fd24/app/models/job_run.rb")
  assert_true(git ~= nil, "bundler git gem parsed")
  assert_eq(git.gem_name, "flux-jobs")
  assert_eq(git.revision, "9e92dbf2fd24")
  assert_eq(git.relative_path, "app/models/job_run.rb")

  -- Ensure gem parser ignores bundler/gems
  local not_g = ruby_path.parse_gem_path("/deploy/shared/bundle/ruby/3.3.0/bundler/gems/flux-jobs-9e92dbf2fd24/app/models/job_run.rb")
  assert_eq(not_g, nil, "gem parser ignores bundler/gems")

  -- 3. Stdlib
  local s1 = ruby_path.parse_stdlib_path("/usr/lib/x86_64-linux-gnu/ruby/3.3.0/delegate.rb")
  assert_true(s1 ~= nil, "stdlib parsed")
  assert_eq(s1.stdlib_path, "delegate.rb")
  assert_eq(s1.module_name, "delegate")

  local s2 = ruby_path.parse_stdlib_path("/opt/rubies/3.3.5/lib/ruby/3.3.0/net/http.rb")
  assert_true(s2 ~= nil, "nested stdlib parsed")
  assert_eq(s2.stdlib_path, "net/http.rb")
  assert_eq(s2.module_name, "net/http")
end

print("--> [Ruby Spec 2] Ruby version discovery precedence...")
do
  local test_tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(test_tmp, "p")

  -- Priority 5: Gemfile
  write_file(test_tmp .. "/Gemfile", "source 'https://rubygems.org'\nruby '3.1.2'\n")
  local v5 = environment.discover_ruby_version(test_tmp)
  assert_eq(v5.version, "3.1.2")
  assert_eq(v5.source, "Gemfile")

  -- Priority 4: .mise.toml
  write_file(test_tmp .. "/.mise.toml", '[tools]\nruby = "3.2.0"\n')
  local v4 = environment.discover_ruby_version(test_tmp)
  assert_eq(v4.version, "3.2.0")
  assert_eq(v4.source, ".mise.toml")

  -- Priority 3: mise.toml
  write_file(test_tmp .. "/mise.toml", '[tools]\nruby = "3.2.1"\n')
  local v3 = environment.discover_ruby_version(test_tmp)
  assert_eq(v3.version, "3.2.1")
  assert_eq(v3.source, "mise.toml")

  -- Priority 2: .tool-versions
  write_file(test_tmp .. "/.tool-versions", "nodejs 20.0.0\nruby 3.3.0\n")
  local v2 = environment.discover_ruby_version(test_tmp)
  assert_eq(v2.version, "3.3.0")
  assert_eq(v2.source, ".tool-versions")

  -- Priority 1: .ruby-version
  write_file(test_tmp .. "/.ruby-version", "3.3.5\n")
  local v1 = environment.discover_ruby_version(test_tmp)
  assert_eq(v1.version, "3.3.5")
  assert_eq(v1.source, ".ruby-version")

  -- Clean up
  vim.fn.delete(test_tmp, "rf")
end

print("--> [Ruby Spec 3] Exact gem matching & no fallback on version mismatch...")
do
  local test_tmp = vim.fs.normalize(vim.fn.tempname())
  local gem_home = test_tmp .. "/lib/ruby/gems/3.3.0"
  local installed_gem_dir = gem_home .. "/gems/actionpack-8.1.3.1/lib/abstract_controller"
  vim.fn.mkdir(installed_gem_dir, "p")
  local target_file = installed_gem_dir .. "/base.rb"
  write_file(target_file, "# actionpack 8.1.3.1 base.rb\n")

  local mock_env = {
    ruby_version = "3.3.5",
    ruby_api_version = "3.3.0",
    gem_dir = gem_home,
    gem_paths = { gem_home },
  }

  -- Exact match succeeds
  local parsed_exact = {
    gem_name = "actionpack",
    gem_version = "8.1.3.1",
    relative_path = "lib/abstract_controller/base.rb",
  }
  local res_exact = gems.resolve(parsed_exact, mock_env)
  assert_true(res_exact ~= nil, "exact gem resolved")
  assert_eq(res_exact.path, target_file)

  -- Version mismatch DOES NOT fall back
  local parsed_diff_ver = {
    gem_name = "actionpack",
    gem_version = "8.1.4",
    relative_path = "lib/abstract_controller/base.rb",
  }
  local res_mismatch = gems.resolve(parsed_diff_ver, mock_env)
  assert_eq(res_mismatch, nil, "mismatched gem version must NOT resolve")

  vim.fn.delete(test_tmp, "rf")
end

print("--> [Ruby Spec 4] Bundler git gem resolution...")
do
  local test_tmp = vim.fs.normalize(vim.fn.tempname())
  local gem_home = test_tmp .. "/lib/ruby/gems/3.3.0"
  local git_gem_dir = gem_home .. "/bundler/gems/flux-jobs-9e92dbf2fd24/app/models"
  vim.fn.mkdir(git_gem_dir, "p")
  local target_file = git_gem_dir .. "/job_run.rb"
  write_file(target_file, "# flux-jobs job_run.rb\n")

  local mock_env = {
    ruby_version = "3.3.5",
    ruby_api_version = "3.3.0",
    gem_dir = gem_home,
    gem_paths = { gem_home },
  }

  local parsed_git = {
    gem_name = "flux-jobs",
    revision = "9e92dbf2fd24",
    relative_path = "app/models/job_run.rb",
  }
  local res_git = git_gems.resolve(parsed_git, mock_env)
  assert_true(res_git ~= nil, "bundler git gem resolved")
  assert_eq(res_git.path, target_file)

  -- Short SHA match if folder has full SHA
  local git_gem_full = gem_home .. "/bundler/gems/my-gem-abcdef1234567890/lib"
  vim.fn.mkdir(git_gem_full, "p")
  local target_full = git_gem_full .. "/entry.rb"
  write_file(target_full, "# my-gem\n")

  local parsed_short = {
    gem_name = "my-gem",
    revision = "abcdef12",
    relative_path = "lib/entry.rb",
  }
  local res_short = git_gems.resolve(parsed_short, mock_env)
  assert_true(res_short ~= nil, "short SHA resolved to full SHA folder")
  assert_eq(res_short.path, target_full)

  vim.fn.delete(test_tmp, "rf")
end

print("--> [Ruby Spec 5] Ruby stdlib resolution...")
do
  local test_tmp = vim.fs.normalize(vim.fn.tempname())
  local rubylib = test_tmp .. "/lib/ruby/3.3.0"
  vim.fn.mkdir(rubylib, "p")
  local target_delegate = rubylib .. "/delegate.rb"
  write_file(target_delegate, "# delegate.rb\n")

  local mock_env = {
    ruby_version = "3.3.5",
    ruby_api_version = "3.3.0",
    rubylibdir = rubylib,
  }

  local parsed_stdlib = {
    stdlib_path = "delegate.rb",
    module_name = "delegate",
  }
  local res_stdlib = stdlib.resolve(parsed_stdlib, mock_env)
  assert_true(res_stdlib ~= nil, "stdlib resolved")
  assert_eq(res_stdlib.path, target_delegate)

  vim.fn.delete(test_tmp, "rf")
end

print("--> [Ruby Spec 6] End-to-end trace parsing, resolution, and sidebar status...")
do
  local test_root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(test_root, "p")

  -- Create fake rbenv setup in temp dir
  local fake_gem_dir = test_root .. "/gems/i18n-1.8.11/lib"
  vim.fn.mkdir(fake_gem_dir, "p")
  local fake_i18n_rb = fake_gem_dir .. "/i18n.rb"
  write_file(fake_i18n_rb, "module I18n\n  def self.with_locale; end\nend\n")

  -- Mock ruby environment in cache for test_root
  environment.env_cache[test_root] = {
    root = test_root,
    manager = "rbenv",
    ruby_version = "3.3.5",
    ruby_api_version = "3.3.0",
    gem_dir = test_root,
    gem_paths = { test_root },
    rubylibdir = test_root,
  }

  unwind.clear()
  local trace = [[
/apps/sample_app/shared/bundle/ruby/3.3.0/gems/i18n-1.8.11/lib/i18n.rb:314:in `with_locale'
/apps/sample_app/shared/bundle/ruby/3.3.0/gems/nonexistent-1.0.0/lib/nonexistent.rb:10:in `run'
]]

  local frames = parser.parse(trace, { root = test_root })
  assert_eq(#frames, 2, "2 frames parsed")

  local f1 = frames[1]
  assert_eq(f1.external, true, "f1 marked external")
  assert_eq(f1.source_kind, "ruby_gem")
  assert_eq(f1.navigable, true)
  assert_eq(f1.resolved_path, fake_i18n_rb)
  assert_eq(f1.resolution.gem, "i18n")
  assert_eq(f1.resolution.gem_version, "1.8.11")

  local f2 = frames[2]
  assert_eq(f2.navigable, false, "nonexistent gem not navigable")

  -- Ingest into session
  local session = sessions.new_working(test_root, frames)
  unwind.rebuild_derived(session)

  -- Verify files and availability
  assert_eq(session.files[1].available, true, "resolved gem file is available (not N/A)")
  assert_eq(session.files[1].is_vendor, true, "resolved gem file is tagged as vendor/external")
  assert_eq(session.files[2].available, false, "unresolved gem is marked N/A")

  -- Verify vendor filtering: toggling filter hides external gem
  session.filter_enabled = true
  unwind.rebuild_derived(session)
  assert_eq(#session.frames, 0, "both frames filtered out when filter_enabled")

  session.filter_enabled = false
  unwind.rebuild_derived(session)
  assert_eq(#session.frames, 2, "both frames visible when filter disabled")

  unwind.clear()
  vim.fn.delete(test_root, "rf")
end

print("--> [Ruby Spec 7] :UnwindRubyInfo execution...")
do
  -- Verify calling ruby_info does not throw errors
  local ok, err = pcall(unwind.ruby_info)
  assert_true(ok, "ruby_info executes cleanly: " .. tostring(err))
end

print("All Ruby resolver unit and integration tests PASSED successfully!")
