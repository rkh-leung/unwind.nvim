-- lua/unwind/resolvers/init.lua
-- Central resolver pipeline coordinating workspace, path_mappings, and language resolvers

local workspace_resolver = require("unwind.resolvers.workspace")

local M = {}

--- Compiles and sorts path mappings longest-prefix first
---@param mappings? table<string, string>
---@return table[] sorted_mappings List of { prefix, target }
function M.compile_path_mappings(mappings)
  if not mappings then
    return {}
  end
  local compiled = {}
  for prefix, target in pairs(mappings) do
    local norm_prefix = prefix:gsub("\\", "/")
    local norm_target = target:gsub("\\", "/")
    table.insert(compiled, {
      prefix = norm_prefix,
      target = norm_target,
    })
  end
  table.sort(compiled, function(a, b)
    return #a.prefix > #b.prefix
  end)
  return compiled
end

--- Apply user configured path mappings
---@param raw_path string
---@param opts? { root?: string, path_mappings?: table<string, string>, compiled_mappings?: table[] }
---@return table? result
local function resolve_path_mappings(raw_path, opts)
  opts = opts or {}
  local compiled_mappings = opts.compiled_mappings
  if not compiled_mappings and opts.path_mappings then
    compiled_mappings = M.compile_path_mappings(opts.path_mappings)
  end
  if not compiled_mappings or #compiled_mappings == 0 then
    return nil
  end

  local normalized = workspace_resolver.canonicalize_lexical(raw_path)
  local root = opts.root or vim.fn.getcwd()
  root = workspace_resolver.canonicalize_lexical(root)
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end

  local is_windows = vim.fn.has("win32") == 1 or normalized:match("^%a:[/\\]") or root:match("^%a:[/\\]")

  for _, item in ipairs(compiled_mappings) do
    local norm_prefix = item.prefix
    local norm_target = item.target

    local is_match = false
    local rest = ""

    local check_norm = is_windows and normalized:lower() or normalized
    local check_prefix = is_windows and norm_prefix:lower() or norm_prefix

    if check_norm == check_prefix then
      is_match = true
      rest = ""
    elseif norm_prefix:sub(-1) == "/" and check_norm:sub(1, #norm_prefix) == check_prefix then
      is_match = true
      rest = normalized:sub(#norm_prefix + 1)
    elseif norm_prefix:sub(-1) ~= "/" and check_norm:sub(1, #norm_prefix + 1) == check_prefix .. "/" then
      is_match = true
      rest = normalized:sub(#norm_prefix + 2)
    end

    if is_match then
      if norm_target:sub(-1) == "/" and rest:sub(1, 1) == "/" then
        rest = rest:sub(2)
      elseif norm_target:sub(-1) ~= "/" and rest:sub(1, 1) ~= "/" and norm_target ~= "" and rest ~= "" then
        rest = "/" .. rest
      end
      local candidate = workspace_resolver.canonicalize_lexical(norm_target .. rest)
      candidate = candidate:gsub("^%./", "")

      local resolved = candidate
      if candidate:sub(1, 1) ~= "/" and not candidate:match("^%a:[/\\]") then
        resolved = workspace_resolver.canonicalize_lexical(root .. candidate)
      end
      return {
        path = resolved,
        display = candidate,
        kind = "path_mapping",
      }
    end
  end

  return nil
end

--- Main resolution entry point
--- Resolves a raw trace frame path through:
---   1. Direct existence / Workspace resolver
---   2. Configured user path_mappings
---   3. Language resolvers (e.g. Ruby)
---@param raw_path string
---@param opts? { root?: string, path_mappings?: table<string, string>, compiled_mappings?: table[] }
---@return table? resolution
function M.resolve(raw_path, opts)
  if not raw_path or raw_path == "" then
    return nil
  end

  opts = opts or {}
  local root = opts.root or vim.fn.getcwd()

  -- 1. Check workspace resolver first
  local ws_res = workspace_resolver.resolve(raw_path, { root = root })
  if ws_res then
    return {
      path = ws_res.path,
      display = ws_res.display,
      kind = "workspace",
      external = false,
      source_kind = "workspace",
    }
  end

  -- 2. Check user-configured path mappings
  local map_res = resolve_path_mappings(raw_path, opts)
  if map_res then
    local stat = (vim.uv or vim.loop).fs_stat(map_res.path)
    local exists = stat ~= nil and stat.type == "file"
    return {
      path = map_res.path,
      display = map_res.display,
      kind = "path_mapping",
      external = false,
      source_kind = "path_mapping",
      exists = exists,
    }
  end

  -- 3. Check language resolvers (Ruby)
  local ok_ruby, ruby_resolver = pcall(require, "unwind.resolvers.ruby")
  if ok_ruby and ruby_resolver and ruby_resolver.resolve then
    local ruby_res = ruby_resolver.resolve(raw_path, { root = root })
    if ruby_res then
      return {
        path = ruby_res.path,
        display = raw_path, -- Keep original trace path or relative for display
        kind = ruby_res.kind,
        external = true,
        source_kind = ruby_res.source_kind or ("ruby_" .. (ruby_res.kind or "gem")),
        resolution = ruby_res.resolution or {
          manager = ruby_res.manager,
          ruby_version = ruby_res.ruby_version,
          gem = ruby_res.gem,
          gem_version = ruby_res.gem_version,
          revision = ruby_res.revision,
          stdlib_module = ruby_res.stdlib_module,
        },
      }
    end
  end

  return nil
end

return M
