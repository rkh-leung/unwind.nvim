-- lua/unwind/resolvers/ruby/environment.lua
-- Ruby version discovery, manager detection, and runtime environment probing

local rbenv = require("unwind.resolvers.ruby.managers.rbenv")
local asdf = require("unwind.resolvers.ruby.managers.asdf")
local mise = require("unwind.resolvers.ruby.managers.mise")
local chruby = require("unwind.resolvers.ruby.managers.chruby")
local rvm = require("unwind.resolvers.ruby.managers.rvm")
local system = require("unwind.resolvers.ruby.managers.system")

local M = {}

--- Cache probed environments per project root
--- Key: canonical root path -> RubyEnv table | false (negative cache sentinel)
M.env_cache = {}

--- Invalidate Ruby environment cache
---@param root? string Optional project root to invalidate, or nil for all
function M.invalidate(root)
  if root then
    M.env_cache[vim.fs.normalize(root)] = nil
  else
    M.env_cache = {}
  end
end

--- Reads the entire content of a file if it exists
---@param path string
---@return string?
local function read_file_content(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

--- Discover project's Ruby version from repository files
--- Priority:
---   1. .ruby-version
---   2. .tool-versions
---   3. mise.toml
---   4. .mise.toml
---   5. Gemfile ruby directive
---   6. Fallback: nil (indicates system/active ruby)
---@param root string
---@return table { version: string?, source: string? }
function M.discover_ruby_version(root)
  root = vim.fs.normalize(root)

  -- 1. .ruby-version
  local rv_content = read_file_content(root .. "/.ruby-version")
  if rv_content then
    local v = rv_content:match("^%s*([%w%.%-%_]+)")
    if v and v ~= "" then
      -- strip leading 'ruby-' if present
      v = v:gsub("^ruby%-", "")
      return { version = v, source = ".ruby-version" }
    end
  end

  -- 2. .tool-versions
  local tv_content = read_file_content(root .. "/.tool-versions")
  if tv_content then
    for line in tv_content:gmatch("[^\r\n]+") do
      local ruby_v = line:match("^%s*ruby%s+([%w%.%-%_]+)")
      if ruby_v and ruby_v ~= "" then
        ruby_v = ruby_v:gsub("^ruby%-", "")
        return { version = ruby_v, source = ".tool-versions" }
      end
    end
  end

  -- 3. mise.toml
  local mise_content = read_file_content(root .. "/mise.toml")
  if mise_content then
    local v = mise_content:match('ruby%s*=%s*["\']([^"\']+)["\']')
    if v and v ~= "" then
      v = v:gsub("^ruby%-", "")
      return { version = v, source = "mise.toml" }
    end
  end

  -- 4. .mise.toml
  local dot_mise_content = read_file_content(root .. "/.mise.toml")
  if dot_mise_content then
    local v = dot_mise_content:match('ruby%s*=%s*["\']([^"\']+)["\']')
    if v and v ~= "" then
      v = v:gsub("^ruby%-", "")
      return { version = v, source = ".mise.toml" }
    end
  end

  -- 5. Gemfile
  local gemfile_content = read_file_content(root .. "/Gemfile")
  if gemfile_content then
    local v = gemfile_content:match('ruby%s+["\']([^"\']+)["\']')
    if v and v ~= "" then
      v = v:gsub("^ruby%-", "")
      return { version = v, source = "Gemfile" }
    end
  end

  return { version = nil, source = "system" }
end

--- Manager adapters list in precedence order
local manager_adapters = {
  { name = "rbenv", adapter = rbenv },
  { name = "asdf", adapter = asdf },
  { name = "mise", adapter = mise },
  { name = "chruby", adapter = chruby },
  { name = "rvm", adapter = rvm },
  { name = "system", adapter = system },
}

--- Detect installed Ruby executable and manager
---@param root string
---@param version? string
---@return table? { manager: string, ruby_bin: string }
function M.detect_ruby_executable(root, version)
  -- If a specific version is requested, try managers that have that version installed
  for _, m in ipairs(manager_adapters) do
    if m.adapter.detect(root) then
      local bin = m.adapter.find_ruby(version)
      if bin then
        return { manager = m.name, ruby_bin = bin }
      end
    end
  end

  -- If not found with detected managers, search all adapters for the requested version
  if version then
    for _, m in ipairs(manager_adapters) do
      local bin = m.adapter.find_ruby(version)
      if bin then
        return { manager = m.name, ruby_bin = bin }
      end
    end
  end

  -- Fallback to system ruby
  local sys_bin = system.find_ruby()
  if sys_bin then
    return { manager = "system", ruby_bin = sys_bin }
  end

  return nil
end

--- Probes a Ruby executable by executing a single in-process command:
---   ruby -rrubygems -rjson -e 'puts JSON.dump(...)'
--- Returns environment details:
---   ruby_version, ruby_api_version, gem_dir, gem_paths, rubylibdir, archdir, sitelibdir, vendorlibdir
---@param ruby_bin string
---@return table?
function M.probe_ruby(ruby_bin)
  if not ruby_bin or vim.fn.executable(ruby_bin) ~= 1 then
    return nil
  end

  -- Compact Ruby snippet to output JSON
  local probe_cmd = {
    ruby_bin,
    "-rrubygems",
    "-rjson",
    "-e",
    'puts JSON.dump({' ..
      'ruby_version: RUBY_VERSION,' ..
      'ruby_api_version: RbConfig::CONFIG["ruby_version"],' ..
      'gem_dir: Gem.dir,' ..
      'gem_paths: Gem.path,' ..
      'rubylibdir: RbConfig::CONFIG["rubylibdir"],' ..
      'archdir: RbConfig::CONFIG["archdir"],' ..
      'sitelibdir: RbConfig::CONFIG["sitelibdir"],' ..
      'vendorlibdir: RbConfig::CONFIG["vendorlibdir"]' ..
    '})'
  }

  local res = vim.fn.system(probe_cmd)
  if vim.v.shell_error ~= 0 or not res or res == "" then
    return nil
  end

  local ok, data = pcall(vim.json.decode, res)
  if not ok or type(data) ~= "table" then
    return nil
  end

  -- Normalize gem_paths
  local gem_paths = {}
  if type(data.gem_paths) == "table" then
    for _, gp in ipairs(data.gem_paths) do
      table.insert(gem_paths, vim.fs.normalize(gp))
    end
  elseif data.gem_dir then
    table.insert(gem_paths, vim.fs.normalize(data.gem_dir))
  end

  return {
    ruby_version = data.ruby_version,
    ruby_api_version = data.ruby_api_version,
    gem_dir = data.gem_dir and vim.fs.normalize(data.gem_dir) or nil,
    gem_paths = gem_paths,
    rubylibdir = data.rubylibdir and vim.fs.normalize(data.rubylibdir) or nil,
    archdir = data.archdir and vim.fs.normalize(data.archdir) or nil,
    sitelibdir = data.sitelibdir and vim.fs.normalize(data.sitelibdir) or nil,
    vendorlibdir = data.vendorlibdir and vim.fs.normalize(data.vendorlibdir) or nil,
  }
end

--- Get or load the Ruby environment for a project root (cached)
--- Uses `false` as negative-cache sentinel to prevent repeated failed discovery
---@param root string
---@param force_reload? boolean
---@return table? RubyEnv
function M.get_environment(root, force_reload)
  root = vim.fs.normalize(root)

  if force_reload then
    M.invalidate(root)
  elseif M.env_cache[root] ~= nil then
    return M.env_cache[root] or nil
  end

  local ver_info = M.discover_ruby_version(root)
  local exec_info = M.detect_ruby_executable(root, ver_info.version)
  if not exec_info then
    M.env_cache[root] = false
    return nil
  end

  local probe = M.probe_ruby(exec_info.ruby_bin)
  if not probe then
    M.env_cache[root] = false
    return nil
  end

  local env = {
    root = root,
    manager = exec_info.manager,
    ruby_bin = exec_info.ruby_bin,
    discovered_version = ver_info.version,
    version_source = ver_info.source,
    ruby_version = probe.ruby_version,
    ruby_api_version = probe.ruby_api_version,
    gem_dir = probe.gem_dir,
    gem_paths = probe.gem_paths,
    rubylibdir = probe.rubylibdir,
    archdir = probe.archdir,
    sitelibdir = probe.sitelibdir,
    vendorlibdir = probe.vendorlibdir,
  }

  M.env_cache[root] = env
  return env
end

return M
