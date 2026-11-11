-- lua/unwind/path.lua
-- Pure filesystem and path manipulation utilities

local M = {}

--- Check if running on Windows or if path contains Windows drive prefix
---@param path? string
---@return boolean
function M.is_windows_path(path)
  if vim.fn.has("win32") == 1 then
    return true
  end
  if path and path:match("^%a:[/\\]") then
    return true
  end
  return false
end

--- Returns a case-normalized key for path comparison/grouping
--- (lower-case on Windows, unchanged on Unix)
---@param path string
---@return string
function M.comparison_key(path)
  if not path or path == "" then
    return ""
  end
  if M.is_windows_path(path) then
    return path:lower()
  end
  return path
end

--- Check if a path is absolute (Unix leading / or Windows drive letter)
---@param path string
---@return boolean
function M.is_absolute(path)
  if not path or path == "" then
    return false
  end
  local p = path:gsub("\\", "/")
  return p:sub(1, 1) == "/" or p:match("^%a:/") ~= nil
end

--- Canonicalize path lexical components:
--- Replaces backslashes with forward slashes, strips duplicate slashes and redundant ./,
--- resolves .. segments where possible.
---@param path string
---@return string
function M.canonicalize(path)
  if not path or path == "" then
    return path or ""
  end
  local p = path:gsub("\\", "/")
  local is_abs_unix = p:sub(1, 1) == "/"
  local drive, rest = p:match("^([%a]:)/(.*)")
  if drive then
    p = "/" .. rest
  end

  local parts = {}
  for part in p:gmatch("[^/]+") do
    if part == "." then
      -- skip
    elseif part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        table.remove(parts)
      elseif not is_abs_unix and not drive then
        table.insert(parts, "..")
      end
    else
      table.insert(parts, part)
    end
  end

  local res = table.concat(parts, "/")
  if drive then
    res = drive .. "/" .. res
  elseif is_abs_unix then
    res = "/" .. res
  end
  return res ~= "" and res or (is_abs_unix and "/" or ".")
end

--- Check if path exists and is a regular file using an optional operation cache.
--- Strictly requires stat.type == "file" (directories are not navigable files).
---@param path string
---@param cache? table<string, boolean>
---@return boolean
function M.is_file(path, cache)
  if not path or path == "" then
    return false
  end

  if cache and cache[path] ~= nil then
    return cache[path]
  end

  local stat = (vim.uv or vim.loop).fs_stat(path)
  local exists = stat ~= nil and stat.type == "file"

  if cache then
    cache[path] = exists
  end

  return exists
end

--- Check if a path is located inside the given workspace root
---@param path string
---@param root string
---@return boolean is_inside
---@return string? relative_path
function M.is_in_root(path, root)
  if not path or not root or path == "" or root == "" then
    return false, nil
  end

  local norm_path = M.canonicalize(path)
  local norm_root = M.canonicalize(root)
  if norm_root:sub(-1) ~= "/" then
    norm_root = norm_root .. "/"
  end

  local check_path = M.comparison_key(norm_path)
  local check_root = M.comparison_key(norm_root)

  if check_path:sub(1, #check_root) == check_root then
    local rel = norm_path:sub(#norm_root + 1)
    return true, rel
  end

  return false, nil
end

--- Compiles and sorts path mappings longest-prefix first
---@param mappings? table<string, string>
---@return table[] sorted_mappings List of { prefix, target }
function M.compile_mappings(mappings)
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

return M
