-- lua/unwind/resolvers/workspace.lua
-- Workspace path resolver: resolves local files, relative paths, and common container prefix stripping

local M = {}

--- Checks if a path points to an actual file on disk
---@param p string
---@return boolean
local function file_exists(p)
  if not p or p == "" then
    return false
  end
  local stat = (vim.uv or vim.loop).fs_stat(p)
  return stat ~= nil and stat.type == "file"
end

--- Normalizes a path lexically resolving . and ..
---@param path string
---@return string
function M.canonicalize_lexical(path)
  if not path or path == "" then
    return path
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

--- Resolve a path against the workspace root
---@param raw_path string
---@param opts? { root?: string }
---@return table? result { path: string, display: string, kind: string }
function M.resolve(raw_path, opts)
  if not raw_path or raw_path == "" then
    return nil
  end

  opts = opts or {}
  local root = opts.root or vim.fn.getcwd()
  root = M.canonicalize_lexical(root)
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end

  local normalized = M.canonicalize_lexical(raw_path)
  local is_windows = vim.fn.has("win32") == 1 or normalized:match("^%a:[/\\]") or root:match("^%a:[/\\]")

  -- If it's already an absolute path inside root, check existence
  local check_norm = is_windows and normalized:lower() or normalized
  local check_root = is_windows and root:lower() or root
  local is_in_root = check_norm:sub(1, #check_root) == check_root

  if is_in_root then
    local rel = normalized:sub(#root + 1)
    if file_exists(rel) or file_exists(root .. rel) or file_exists(normalized) then
      local abs = file_exists(normalized) and normalized or M.canonicalize_lexical(root .. rel)
      return {
        path = abs,
        display = rel,
        kind = "workspace",
      }
    end
  end

  -- If directly readable as-is
  if file_exists(raw_path) or file_exists(normalized) then
    local abs = normalized
    if normalized:sub(1, 1) ~= "/" and not normalized:match("^%a:[/\\]") then
      abs = M.canonicalize_lexical(root .. normalized)
    end
    local display = normalized
    if is_in_root then
      display = normalized:sub(#root + 1)
    end
    return {
      path = abs,
      display = display,
      kind = "workspace",
    }
  end

  -- Stripping known container / build prefixes
  local known_prefixes = {
    "^/app/",
    "^/var/task/",
    "^/usr/src/[^/]+/",
    "^%a:[/\\]workspace[/\\]?",
    "^%a:[/\\]project[/\\]?",
    "^%a:[/\\]",
    "^/[^/]+/",
  }

  for _, prefix in ipairs(known_prefixes) do
    local stripped = normalized:gsub(prefix, "")
    if stripped ~= normalized and stripped ~= "" then
      local stripped_segments_count = 0
      for _ in stripped:gmatch("[^/]+") do
        stripped_segments_count = stripped_segments_count + 1
      end
      local orig_segments_count = 0
      for _ in normalized:gmatch("[^/]+") do
        orig_segments_count = orig_segments_count + 1
      end

      if stripped_segments_count >= 2 or orig_segments_count <= 2 then
        local abs_candidate = M.canonicalize_lexical(root .. stripped)
        if file_exists(stripped) or file_exists(abs_candidate) then
          return {
            path = file_exists(stripped) and M.canonicalize_lexical(stripped) or abs_candidate,
            display = stripped,
            kind = "workspace",
          }
        end
      end
    end
  end

  -- Try incrementally stripping leading directory segments
  local segments = {}
  for segment in normalized:gmatch("[^/]+") do
    table.insert(segments, segment)
  end

  for i = 2, #segments do
    if (#segments - i + 1) >= 2 or #segments <= 2 then
      local sub_path = table.concat(segments, "/", i)
      local abs_candidate = M.canonicalize_lexical(root .. sub_path)
      if file_exists(sub_path) or file_exists(abs_candidate) then
        return {
          path = file_exists(sub_path) and M.canonicalize_lexical(sub_path) or abs_candidate,
          display = sub_path,
          kind = "workspace",
        }
      end
    end
  end

  return nil
end

return M
