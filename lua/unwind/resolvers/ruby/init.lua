-- lua/unwind/resolvers/ruby/init.lua
-- Ruby resolver entry point: gems, bundler git gems, and stdlib

local environment = require("unwind.resolvers.ruby.environment")
local ruby_path = require("unwind.resolvers.ruby.path")
local gems = require("unwind.resolvers.ruby.gems")
local git_gems = require("unwind.resolvers.ruby.git_gems")
local stdlib = require("unwind.resolvers.ruby.stdlib")

local M = {}

--- Per-root resolution cache
local resolution_cache = {}

local function cache_for_root(root)
  root = vim.fs.normalize(root)
  if not resolution_cache[root] then
    resolution_cache[root] = {}
  end
  return resolution_cache[root]
end

--- Invalidate resolution and environment caches for root or all
---@param root? string
function M.invalidate(root)
  if root then
    root = vim.fs.normalize(root)
    resolution_cache[root] = nil
    environment.invalidate(root)
  else
    resolution_cache = {}
    environment.invalidate()
  end
  git_gems.clear_cache()
end

--- Public API: resolve a stack frame path to a local Ruby file
---@param frame_path string
---@param opts? { root?: string, force_reload?: boolean }
---@return table? result { path: string, kind: string, manager: string, resolution: table }
function M.resolve(frame_path, opts)
  if not frame_path or frame_path == "" then
    return nil
  end

  opts = opts or {}
  local root = opts.root or vim.fs.normalize(vim.fn.getcwd())
  root = vim.fs.normalize(root)

  if opts.force_reload then
    M.invalidate(root)
  end

  local cache = cache_for_root(root)
  local cached = cache[frame_path]
  if cached ~= nil then
    return cached or nil
  end

  local function store(res)
    cache[frame_path] = res or false
    return res
  end

  -- 1. Try parsing path pattern before loading/probing environment (fast fail)
  local parsed_gem = ruby_path.parse_gem_path(frame_path)
  local parsed_git_gem = not parsed_gem and ruby_path.parse_bundler_git_path(frame_path) or nil
  local parsed_stdlib = not parsed_gem and not parsed_git_gem and ruby_path.parse_stdlib_path(frame_path) or nil

  -- If path has no Ruby library signatures, do not pollute negative cache
  if not parsed_gem and not parsed_git_gem and not parsed_stdlib then
    return nil
  end

  -- 2. Obtain cached or probed Ruby environment for this root
  local env = environment.get_environment(root, false)
  if not env then
    return store(nil)
  end

  -- 3. Resolve regular gem
  if parsed_gem then
    local res = gems.resolve(parsed_gem, env)
    if res then
      return store({
        path = res.path,
        kind = "gem",
        source_kind = "ruby_gem",
        manager = env.manager,
        ruby_version = env.ruby_version,
        gem = res.gem,
        gem_version = res.gem_version,
        resolution = {
          manager = env.manager,
          ruby_version = env.ruby_version,
          gem = res.gem,
          gem_version = res.gem_version,
        },
      })
    end
  end

  -- 4. Resolve Bundler git gem
  if parsed_git_gem then
    local res = git_gems.resolve(parsed_git_gem, env)
    if res then
      return store({
        path = res.path,
        kind = "bundler_git_gem",
        source_kind = "ruby_bundler_git",
        manager = env.manager,
        ruby_version = env.ruby_version,
        gem = res.gem,
        revision = res.revision,
        resolution = {
          manager = env.manager,
          ruby_version = env.ruby_version,
          gem = res.gem,
          revision = res.revision,
        },
      })
    end
  end

  -- 5. Resolve Ruby stdlib
  if parsed_stdlib then
    local res = stdlib.resolve(parsed_stdlib, env)
    if res then
      return store({
        path = res.path,
        kind = "stdlib",
        source_kind = "ruby_stdlib",
        manager = env.manager,
        ruby_version = env.ruby_version,
        stdlib_module = res.module,
        resolution = {
          manager = env.manager,
          ruby_version = env.ruby_version,
          stdlib_module = res.module,
        },
      })
    end
  end

  return store(nil)
end

--- Get environment info for diagnostics
---@param root? string
---@return table?
function M.info(root)
  root = root or vim.fs.normalize(vim.fn.getcwd())
  return environment.get_environment(root)
end

return M
