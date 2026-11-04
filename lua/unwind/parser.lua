-- lua/unwind/parser.lua
-- Pure Lua In-Memory Text Parsing for plain-text crash stacktraces
-- Zero external binary dependencies. Uses Lua pattern matching.

local M = {}

--- Check if a file is readable or exists
---@param path string
---@return boolean
local function file_exists(path)
  if not path or path == "" then
    return false
  end
  if vim.uv and vim.uv.fs_stat then
    local stat = vim.uv.fs_stat(path)
    return stat ~= nil
  elseif vim.loop and vim.loop.fs_stat then
    local stat = vim.loop.fs_stat(path)
    return stat ~= nil
  end
  return vim.fn.filereadable(path) == 1
end

--- Normalizes a file path:
--- Strips container / virtual prefixes (e.g. /app/, /var/task/, C:\workspace\)
--- if a corresponding relative path exists within Neovim's cwd (vim.fn.getcwd()).
---@param raw_path string
---@return string
function M.normalize_path(raw_path)
  if not raw_path or raw_path == "" then
    return raw_path
  end

  -- Replace backslashes with forward slashes for uniform processing
  local normalized = raw_path:gsub("\\", "/")

  -- If directly readable as-is, return it
  if file_exists(raw_path) or file_exists(normalized) then
    return normalized
  end

  local cwd = vim.fn.getcwd():gsub("\\", "/")
  if cwd:sub(-1) ~= "/" then
    cwd = cwd .. "/"
  end

  -- If it's already an absolute path inside cwd, make it relative
  if normalized:sub(1, #cwd) == cwd then
    local rel = normalized:sub(#cwd + 1)
    if file_exists(rel) then
      return rel
    end
  end

  -- Common container / build prefixes to strip
  local known_prefixes = {
    "^/app/",
    "^/var/task/",
    "^/usr/src/[%w_%-./]+/",
    "^%a:[/\\]workspace[/\\]?",
    "^%a:[/\\]project[/\\]?",
    "^%a:[/\\]",
    "^/[^/]+/", -- strip leading /dir/
  }

  for _, prefix in ipairs(known_prefixes) do
    local stripped = normalized:gsub(prefix, "")
    if stripped ~= normalized and stripped ~= "" then
      if file_exists(stripped) or file_exists(cwd .. stripped) then
        return stripped
      end
    end
  end

  -- Try incrementally stripping leading directory segments to find a match in cwd
  local segments = {}
  for segment in normalized:gmatch("[^/]+") do
    table.insert(segments, segment)
  end

  for i = 2, #segments do
    local sub_path = table.concat(segments, "/", i)
    if file_exists(sub_path) or file_exists(cwd .. sub_path) then
      return sub_path
    end
  end

  -- If no local match found, return the sanitized path
  return normalized
end

--- Matchers list: functions that accept a line and return { file, line, col, method, raw_line } or nil
local matchers = {
  -- 1. Raygun / .NET / C# style:
  -- "at Namespace.Class.Method(...) in /path/to/file.cs:line 123"
  function(line)
    local method, file, lnum = line:match("^%s*at%s+(.-)%s+in%s+(.-):line%s+(%d+)")
    if file and lnum then
      return {
        file = file,
        line = tonumber(lnum),
        col = 1,
        method = method or "",
      }
    end
    return nil
  end,

  -- 2. Java / .NET without "in ... :line":
  -- "at Class.Method(File.java:123)" or "at Class.Method(Unknown Source)"
  function(line)
    local method, file, lnum = line:match("^%s*at%s+([%w_%.%<%>&]+)%(([%w_%-./\\]+%.%w+):(%d+)%)")
    if file and lnum then
      return {
        file = file,
        line = tonumber(lnum),
        col = 1,
        method = method or "",
      }
    end
    return nil
  end,

  -- 3. Rust / Cargo compiler style:
  -- "--> src/main.rs:45:12" or "--> src/main.rs:45"
  function(line)
    local file, lnum, col = line:match("^%s*%-%-%>%s+([%w_%-./\\]+%.%w+):(%d+):?(%d*)")
    if file and lnum then
      return {
        file = file,
        line = tonumber(lnum),
        col = tonumber(col) or 1,
        method = "compiler",
      }
    end
    return nil
  end,

  -- 4. Node.js / V8 with method:
  -- "at Method (/path/to/file.js:45:12)" or "at async Method (/path/to/file.js:45:12)"
  function(line)
    local method, file, lnum, col = line:match("^%s*at%s+(.-)%s*%(%s*([%w_%-./\\]+%.%w+):(%d+):?(%d*)%s*%)")
    if file and lnum then
      return {
        file = file,
        line = tonumber(lnum),
        col = tonumber(col) or 1,
        method = method or "",
      }
    end
    return nil
  end,

  -- 5. Rust backtrace or Node.js without parenthesized method:
  -- "at /path/to/main.rs:45:12" or "at /path/to/file.js:45"
  function(line)
    local file, lnum, col = line:match("^%s*at%s+([%w_%-./\\]+%.%w+):(%d+):?(%d*)")
    if file and lnum then
      return {
        file = file,
        line = tonumber(lnum),
        col = tonumber(col) or 1,
        method = "",
      }
    end
    return nil
  end,

  -- 6. Python style:
  -- 'File "/path/to/file.py", line 45, in method_name'
  function(line)
    local file, lnum, method = line:match('File%s+"([^"]+)",%s*line%s+(%d+),%s*in%s+([%w_]+)')
    if file and lnum then
      return {
        file = file,
        line = tonumber(lnum),
        col = 1,
        method = method or "",
      }
    end
    return nil
  end,

  -- 7. Generic fallback:
  -- "([%w_%-./\\]+%.%w+):(%d+):?(%d*)"
  function(line)
    local file, lnum, col = line:match("([%w_%-./\\]+%.%w+):(%d+):?(%d*)")
    if file and lnum then
      -- Skip common falsy URL prefixes like http:// or https://
      if file:match("^https?:") or file:match("^ftp:") then
        return nil
      end
      return {
        file = file,
        line = tonumber(lnum),
        col = tonumber(col) or 1,
        method = "",
      }
    end
    return nil
  end,
}

--- Parses a raw plain-text stacktrace into a list of frame objects:
--- { file, line, col, method, raw_line }
---@param text string
---@return table[]
function M.parse(text)
  local frames = {}
  if not text or text == "" then
    return frames
  end

  for line in text:gmatch("[^\r\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      for _, matcher in ipairs(matchers) do
        local frame = matcher(line)
        if frame then
          frame.raw_line = line
          frame.file = M.normalize_path(frame.file)
          if not frame.method or frame.method == "" then
            frame.method = "anonymous"
          end
          table.insert(frames, frame)
          break
        end
      end
    end
  end

  return frames
end

return M
