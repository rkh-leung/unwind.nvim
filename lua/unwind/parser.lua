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
--- Also supports configurable path_mappings and memoizes resolutions.
---@param raw_path string
---@param opts? { path_mappings?: table<string, string>, cache?: table<string, string> }
---@return string
function M.normalize_path(raw_path, opts)
  if not raw_path or raw_path == "" then
    return raw_path
  end

  opts = opts or {}
  local cache = opts.cache
  if cache and cache[raw_path] then
    return cache[raw_path]
  end

  local function store_cache(res)
    if cache then
      cache[raw_path] = res
    end
    return res
  end

  -- Replace backslashes with forward slashes for uniform processing
  local normalized = raw_path:gsub("\\", "/")

  local cwd = vim.fn.getcwd():gsub("\\", "/")
  if cwd:sub(-1) ~= "/" then
    cwd = cwd .. "/"
  end

  -- 1. Apply explicit path_mappings if provided
  -- Sort mappings longest-prefix-first so overlapping prefixes resolve deterministically.
  if opts.path_mappings then
    local mapping_keys = {}
    for prefix in pairs(opts.path_mappings) do
      table.insert(mapping_keys, prefix)
    end
    table.sort(mapping_keys, function(a, b)
      return #a > #b
    end)

    for _, prefix in ipairs(mapping_keys) do
      local target = opts.path_mappings[prefix]
      local norm_prefix = prefix:gsub("\\", "/")
      local norm_target = target:gsub("\\", "/")

      -- Path-segment boundary check: prefix must match exact path or end at path separator
      local is_match = false
      local rest = ""
      if normalized == norm_prefix then
        is_match = true
        rest = ""
      elseif norm_prefix:sub(-1) == "/" and normalized:sub(1, #norm_prefix) == norm_prefix then
        is_match = true
        rest = normalized:sub(#norm_prefix + 1)
      elseif norm_prefix:sub(-1) ~= "/" and normalized:sub(1, #norm_prefix + 1) == norm_prefix .. "/" then
        is_match = true
        rest = normalized:sub(#norm_prefix + 2)
      end

      if is_match then
        if norm_target:sub(-1) == "/" and rest:sub(1, 1) == "/" then
          rest = rest:sub(2)
        elseif norm_target:sub(-1) ~= "/" and rest:sub(1, 1) ~= "/" and norm_target ~= "" and rest ~= "" then
          rest = "/" .. rest
        end
        local candidate = norm_target .. rest
        -- If leading ./ exists, clean it up
        candidate = candidate:gsub("^%./", "")
        -- Explicit path_mappings are intentional user configurations.
        -- Map to candidate directly so remote prefixes map to configured local destinations.
        return store_cache(candidate)
      end
    end
  end

  -- If it's already an absolute path inside cwd, make it relative
  -- On Windows, drive letter case might differ (e.g. C:/ vs c:/)
  local is_in_cwd = normalized:sub(1, #cwd) == cwd
  if not is_in_cwd and (vim.fn.has("win32") == 1 or normalized:match("^%a:[/\\]") or cwd:match("^%a:[/\\]")) then
    if normalized:sub(1, #cwd):lower() == cwd:lower() then
      is_in_cwd = true
    end
  end
  if is_in_cwd then
    local rel = normalized:sub(#cwd + 1)
    if file_exists(rel) then
      return store_cache(rel)
    end
  end

  -- If directly readable as-is, return it
  if file_exists(raw_path) or file_exists(normalized) then
    return store_cache(normalized)
  end

  -- Common container / build prefixes to strip
  -- Conceptually strip a single project component, e.g. /usr/src/<project>/,
  -- rather than greedily consuming multiple path components.
  local known_prefixes = {
    "^/app/",
    "^/var/task/",
    "^/usr/src/[^/]+/",
    "^%a:[/\\]workspace[/\\]?",
    "^%a:[/\\]project[/\\]?",
    "^%a:[/\\]",
    "^/[^/]+/", -- strip leading /dir/
  }

  for _, prefix in ipairs(known_prefixes) do
    local stripped = normalized:gsub(prefix, "")
    if stripped ~= normalized and stripped ~= "" then
      -- Ambiguity check: if stripping leaves only 1 segment (e.g. "main.lua"),
      -- do not loosely match root-level file unless original normalized path had <= 2 segments.
      local stripped_segments_count = 0
      for _ in stripped:gmatch("[^/]+") do
        stripped_segments_count = stripped_segments_count + 1
      end
      local orig_segments_count = 0
      for _ in normalized:gmatch("[^/]+") do
        orig_segments_count = orig_segments_count + 1
      end

      if stripped_segments_count >= 2 or orig_segments_count <= 2 then
        if file_exists(stripped) or file_exists(cwd .. stripped) then
          return store_cache(stripped)
        end
      end
    end
  end

  -- Try incrementally stripping leading directory segments to find a match in cwd.
  -- To prevent ambiguous matching where a path matches an unrelated root-level file
  -- (e.g. resolving /remote/service_a/main.py to root main.py), only strip if
  -- sub_path has at least 2 components or if stripped segments were leading container roots.
  local segments = {}
  for segment in normalized:gmatch("[^/]+") do
    table.insert(segments, segment)
  end

  for i = 2, #segments do
    -- If only 1 segment remains (e.g. "main.py"), do not loosely match root-level file
    -- unless the original path only had 2 segments to begin with.
    if (#segments - i + 1) >= 2 or #segments <= 2 then
      local sub_path = table.concat(segments, "/", i)
      if file_exists(sub_path) or file_exists(cwd .. sub_path) then
        return store_cache(sub_path)
      end
    end
  end

  -- If no local match found, return the sanitized path
  return store_cache(normalized)
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
  -- Supports inner classes ($), lambdas ($ and /), Kotlin coroutines ($)
  function(line)
    local method, file, lnum = line:match("^%s*at%s+(.-)%s*%(([%w_%-./\\]+%.%w+):(%d+)%)")
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
  -- "--> src/main.rs:45:12" or "--> src/main.rs:45" or "--> C:\project\src\main.rs:45:12"
  function(line)
    local file, lnum, col = line:match("^%s*%-%-%>%s+([%a]:[/\\]?[%w_%-./\\]+%.%w+):(%d+):?(%d*)")
    if not file then
      file, lnum, col = line:match("^%s*%-%-%>%s+([%w_%-./\\]+%.%w+):(%d+):?(%d*)")
    end
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
    local method, file, lnum, col = line:match("^%s*at%s+(.-)%s*%(%s*(.-):(%d+):(%d+)%s*%)")
    if not file then
      method, file, lnum = line:match("^%s*at%s+(.-)%s*%(%s*(.-):(%d+)%s*%)")
      col = 1
    end
    if file and lnum then
      return {
        file = vim.trim(file),
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
    local file, lnum, col = line:match("^%s*at%s+(.-):(%d+):(%d+)")
    if not file then
      file, lnum = line:match("^%s*at%s+(.-):(%d+)")
      col = 1
    end
    if file and lnum then
      return {
        file = vim.trim(file),
        line = tonumber(lnum),
        col = tonumber(col) or 1,
        method = "",
      }
    end
    return nil
  end,

  -- 6. Python style:
  -- 'File "/path/to/file.py", line 45, in method_name'
  -- allow angle brackets, spaces, and optional method names (<module>, <listcomp>, <lambda>)
  function(line)
    local file, lnum, method = line:match('File%s+"([^"]+)",%s*line%s+(%d+),?%s*(.*)')
    if file and lnum then
      local m = method:match("^in%s+(.+)$") or method
      return {
        file = file,
        line = tonumber(lnum),
        col = 1,
        method = vim.trim(m),
      }
    end
    return nil
  end,

  -- 7. Ruby style:
  -- 'from /path/to/file.rb:12:in `method_name'\'' or '/path/to/file.rb:12:in `method_name\': error msg'
  -- or with single quotes: 'from /path/to/file.rb:12:in '\''method_name\'\''
  -- or blocks: 'from /path/to/file.rb:12:in `block in foo'\''
  function(line)
    -- Check Windows drive letter path first e.g. C:\project\app.rb:12:in ...
    local file, lnum, method = line:match("([%a]:[/\\][^:]+%.%w+):(%d+):in%s+[`'](.-)['`]")
    if not file then
      file, lnum, method = line:match("([^:]+%.%w+):(%d+):in%s+[`'](.-)['`]")
    end
    if file and lnum then
      file = file:match("^%s*from%s+(.+)$") or file
      return {
        file = vim.trim(file),
        line = tonumber(lnum),
        col = 1,
        method = method or "",
      }
    end
    -- Also match Ruby lines where in has no backticks/quotes or is omitted:
    local f2, l2 = line:match("([%a]:[/\\][^:]+%.%w+):(%d+):?")
    if not f2 then
      f2, l2 = line:match("([^:]+%.%w+):(%d+):?")
    end
    if f2 and l2 and (line:find("^%s*from%s+") or line:find("%.rb:%d+")) then
      f2 = f2:match("^%s*from%s+(.+)$") or f2
      return {
        file = vim.trim(f2),
        line = tonumber(l2),
        col = 1,
        method = "",
      }
    end
    return nil
  end,

  -- 8. Generic fallback:
  -- matches path:line:col or path:line
  -- support paths with spaces, @, +, (), etc.
  -- enforce that file extension begins with an alphabetical character to prevent matching timestamps
  function(line)
    -- Skip URLs early
    if line:match("https?://") or line:match("ftp://") then
      return nil
    end

    local file, lnum, col

    -- 1. Try Windows path (e.g. C:\path\file.ext:line[:col]) without spaces
    file, lnum, col = line:match("([%a]:[/\\][%w_%-./\\]+%.%a%w*):(%d+):?(%d*)")

    -- 2. Standard clean path token without prefix words (e.g. "[ERROR] src/main.rs:45:12" -> "src/main.rs")
    if not file then
      file, lnum, col = line:match("([%w_%-./\\]+%.%a%w*):(%d+):?(%d*)")
    end

    -- 3. Fallback for paths with spaces, @, +, (), anchored after whitespace/brackets/quotes
    if not file then
      file, lnum, col = line:match("[%s%[\"'%(]([%a]:[/\\][^:\r\n\"'%[%]%(%)]+%.%a%w*):(%d+):?(%d*)")
    end
    if not file then
      file, lnum, col = line:match("[%s%[\"'%(]([^:\r\n\"'%[%]%(%)]+%.%a%w*):(%d+):?(%d*)")
    end

    -- 4. Start of line with path that might contain spaces/special characters
    if not file then
      file, lnum, col = line:match("^%s*([%a]:[/\\][^:\r\n\"'%[%]%(%)]+%.%a%w*):(%d+):?(%d*)")
    end
    if not file then
      file, lnum, col = line:match("^%s*([^:\r\n\"'%[%]%(%)]+%.%a%w*):(%d+):?(%d*)")
    end

    if file and lnum then
      -- Skip common falsy URL prefixes like http:// or https://
      if file:match("^https?:") or file:match("^ftp:") then
        return nil
      end
      return {
        file = vim.trim(file),
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
--- Inverts Python traceback blocks individually so that crash-first navigation starts
--- at the innermost fault frame instead of the outermost frame, without reordering
--- unrelated non-Python stack frames in a mixed trace.
--- For Python traceback blocks exceeding max_frames, retains the innermost (last N)
--- crash frames rather than the outermost.
---@param text string
---@param opts? { path_mappings?: table<string, string>, max_frames?: number }
---@return table[]
function M.parse(text, opts)
  opts = opts or {}
  local frames = {}
  if not text or text == "" then
    return frames
  end

  local cache = {}
  local norm_opts = {
    path_mappings = opts.path_mappings,
    cache = cache,
  }

  local max_frames = opts.max_frames or 1000

  -- State machine for per-block Python traceback parsing
  local in_python_block = false
  local python_block_frames = {}

  local function flush_python_block()
    if #python_block_frames > 0 then
      -- If the block exceeds available remaining frame budget or max_frames,
      -- retain the LAST N frames (innermost exception frames)
      local remaining_capacity = math.max(0, max_frames - #frames)
      local count_to_keep = math.min(#python_block_frames, remaining_capacity)
      local start_idx = #python_block_frames - count_to_keep + 1

      -- Reverse innermost -> outermost
      for i = #python_block_frames, start_idx, -1 do
        table.insert(frames, python_block_frames[i])
      end
      python_block_frames = {}
    end
    in_python_block = false
  end

  for line in text:gmatch("[^\r\n]+") do
    if #frames >= max_frames then
      break
    end

    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      -- Check for Python traceback header
      if line:find("Traceback %s*%(most recent call last%):") then
        flush_python_block()
        in_python_block = true
      else
        local matched_frame = nil
        local is_python_frame = false

        if in_python_block then
          -- Check Python matcher (matcher #6)
          matched_frame = matchers[6](line)
          if matched_frame then
            is_python_frame = true
          else
            -- If in Python block and line doesn't match Python frame, check if it's
            -- Python traceback code line / exception line or a different stack trace
            -- Python traceback lines are typically indented (e.g. "    response = handler()")
            -- or exception message "ValueError: ...". If it matches another frame type
            -- (like "at ..."), then the Python block has ended.
            for idx, matcher in ipairs(matchers) do
              if idx ~= 6 then
                local candidate = matcher(line)
                if candidate then
                  matched_frame = candidate
                  break
                end
              end
            end

            if matched_frame then
              -- Non-Python frame encountered; flush python block
              flush_python_block()
            end
          end
        else
          for _, matcher in ipairs(matchers) do
            local candidate = matcher(line)
            if candidate then
              matched_frame = candidate
              break
            end
          end
        end

        if matched_frame then
          matched_frame.raw_line = line
          matched_frame.file = M.normalize_path(matched_frame.file, norm_opts)
          matched_frame.method = matched_frame.method or ""

          if is_python_frame then
            table.insert(python_block_frames, matched_frame)
          else
            table.insert(frames, matched_frame)
          end
        end
      end
    end
  end

  flush_python_block()

  return frames
end

return M
