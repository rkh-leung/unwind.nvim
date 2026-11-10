-- lua/unwind/parser.lua
-- Pure Lua In-Memory Text Parsing for plain-text crash stacktraces
-- Zero external binary dependencies. Uses Lua pattern matching.

local M = {}

--- Check if a path represents a non-navigable pseudo-path (e.g. node:*, <frozen ...>, <string>, etc.)
---@param path string
---@return boolean
function M.is_non_navigable_path(path)
  if not path or path == "" then
    return true
  end
  local trimmed = vim.trim(path)
  if trimmed:match("^node:") or trimmed:match("^file://") or trimmed:match("^https?://") or trimmed:match("^ftp://") then
    return true
  end
  if trimmed:match("^<.*>$") then
    return true
  end
  if trimmed == "[native code]" or trimmed:match("^unknown%s*source") then
    return true
  end
  return false
end

--- Check if a file is readable or exists
---@param path string
---@return boolean
local function file_exists(path)
  if not path or path == "" then
    return false
  end
  if M.is_non_navigable_path(path) then
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

--- Canonicalize path lexical components:
--- Replaces backslashes with forward slashes, strips duplicate slashes and redundant ./,
--- resolves .. segments where possible.
---@param path string
---@return string
local function canonicalize_lexical(path)
  if not path or path == "" then
    return path
  end
  local p = path:gsub("\\", "/")
  -- Preserve leading slash or drive letter
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

--- Compiles and sorts path mappings longest-prefix first
---@param mappings? table<string, string>
---@return table[] sorted_mappings List of { prefix, target, is_prefix_dir }
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

--- Normalizes a file path:
--- Strips container / virtual prefixes (e.g. /app/, /var/task/, C:\workspace\)
--- if a corresponding relative path exists within Neovim's cwd / root.
--- Also supports configurable path_mappings and memoizes resolutions.
--- Returns:
---   display_path: string (relative or display presentation)
---   resolved_path: string (canonical resolved filesystem path or best canonicalized path)
---   navigable: boolean (whether resolved_path points to an actual file or is a non-navigable pseudo-path)
---@param raw_path string
---@param opts? { root?: string, path_mappings?: table<string, string>, compiled_mappings?: table[], cache?: table<string, table> }
---@return string display_path
---@return string resolved_path
---@return boolean navigable
function M.resolve_and_normalize_path(raw_path, opts)
  if not raw_path or raw_path == "" then
    return raw_path, raw_path, false
  end

  opts = opts or {}
  local cache = opts.cache
  if cache and cache[raw_path] then
    local entry = cache[raw_path]
    return entry.display, entry.resolved, entry.navigable
  end

  local function store_cache(display, resolved, navigable)
    display = canonicalize_lexical(display)
    resolved = canonicalize_lexical(resolved)
    if cache then
      cache[raw_path] = { display = display, resolved = resolved, navigable = navigable }
    end
    return display, resolved, navigable
  end

  if M.is_non_navigable_path(raw_path) then
    return store_cache(raw_path, raw_path, false)
  end

  local normalized = canonicalize_lexical(raw_path)

  local root = opts.root or vim.fn.getcwd()
  root = canonicalize_lexical(root)
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end

  local is_windows = vim.fn.has("win32") == 1 or normalized:match("^%a:[/\\]") or root:match("^%a:[/\\]")

  -- 1. Apply explicit path_mappings if provided
  local compiled_mappings = opts.compiled_mappings
  if not compiled_mappings and opts.path_mappings then
    compiled_mappings = M.compile_path_mappings(opts.path_mappings)
  end

  if compiled_mappings then
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
        local candidate = canonicalize_lexical(norm_target .. rest)
        candidate = candidate:gsub("^%./", "")

        local resolved = candidate
        if candidate:sub(1, 1) ~= "/" and not candidate:match("^%a:[/\\]") then
          resolved = canonicalize_lexical(root .. candidate)
        end
        local exists = file_exists(candidate) or file_exists(resolved)
        return store_cache(candidate, resolved, exists)
      end
    end
  end

  -- If it's already an absolute path inside root, make display relative
  local check_norm = is_windows and normalized:lower() or normalized
  local check_root = is_windows and root:lower() or root
  local is_in_root = check_norm:sub(1, #check_root) == check_root

  if is_in_root then
    local rel = normalized:sub(#root + 1)
    if file_exists(rel) or file_exists(root .. rel) or file_exists(normalized) then
      local abs = file_exists(normalized) and normalized or canonicalize_lexical(root .. rel)
      return store_cache(rel, abs, true)
    end
  end

  -- If directly readable as-is, return it
  if file_exists(raw_path) or file_exists(normalized) then
    local abs = normalized
    if normalized:sub(1, 1) ~= "/" and not normalized:match("^%a:[/\\]") then
      abs = canonicalize_lexical(root .. normalized)
    end
    local display = normalized
    if is_in_root then
      display = normalized:sub(#root + 1)
    end
    return store_cache(display, abs, true)
  end

  -- If buffer already loaded in Neovim matching normalized path or root .. normalized
  local check_loaded_buf = function(p)
    local b = vim.fn.bufnr(p)
    if b ~= -1 and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
      return true
    end
    return false
  end
  local abs_cand = normalized
  if normalized:sub(1, 1) ~= "/" and not normalized:match("^%a:[/\\]") then
    abs_cand = canonicalize_lexical(root .. normalized)
  end
  if check_loaded_buf(normalized) or check_loaded_buf(abs_cand) then
    local display = normalized
    if is_in_root then
      display = normalized:sub(#root + 1)
    end
    return store_cache(display, abs_cand, true)
  end

  -- Common container / build prefixes to strip
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
        local abs_candidate = canonicalize_lexical(root .. stripped)
        if file_exists(stripped) or file_exists(abs_candidate) then
          return store_cache(stripped, abs_candidate, true)
        end
      end
    end
  end

  -- Try incrementally stripping leading directory segments to find a match in root.
  local segments = {}
  for segment in normalized:gmatch("[^/]+") do
    table.insert(segments, segment)
  end

  for i = 2, #segments do
    if (#segments - i + 1) >= 2 or #segments <= 2 then
      local sub_path = table.concat(segments, "/", i)
      local abs_candidate = canonicalize_lexical(root .. sub_path)
      if file_exists(sub_path) or file_exists(abs_candidate) then
        return store_cache(sub_path, abs_candidate, true)
      end
    end
  end

  -- Check language resolvers (e.g. Ruby gems, git gems, stdlib)
  local ok_ruby, ruby_resolver = pcall(require, "unwind.resolvers.ruby")
  if ok_ruby and ruby_resolver and ruby_resolver.resolve then
    local r_res = ruby_resolver.resolve(raw_path, { root = root })
    if r_res and r_res.path and file_exists(r_res.path) then
      local display = normalized
      if is_in_root then
        display = normalized:sub(#root + 1)
      end
      return store_cache(display, r_res.path, true)
    end
  end

  -- If no local match found, return the sanitized path
  local abs = normalized
  if normalized:sub(1, 1) ~= "/" and not normalized:match("^%a:[/\\]") then
    abs = canonicalize_lexical(root .. normalized)
  end
  return store_cache(normalized, abs, false)
end

--- Backwards-compatible normalize_path function
---@param raw_path string
---@param opts? table
---@return string
function M.normalize_path(raw_path, opts)
  local display, _ = M.resolve_and_normalize_path(raw_path, opts)
  return display
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

---@class UnwindResolution
---@field manager? string
---@field ruby_version? string
---@field gem? string
---@field gem_version? string
---@field revision? string
---@field stdlib_module? string

---@class UnwindFrame
---@field path string              -- original trace path
---@field resolved_path string?    -- local navigable path
---@field file string              -- display path or relative path
---@field line integer
---@field col integer?
---@field column integer?
---@field method string?
---@field navigable boolean?
---@field external boolean?
---@field source_kind string?      -- "workspace" | "ruby_gem" | "ruby_bundler_git" | "ruby_stdlib" | etc.
---@field resolution UnwindResolution?
---@field raw_line string?
---@field origin string?

--- Parses a raw plain-text stacktrace into a list of frame objects:
--- { path, file, resolved_path, navigable, line, col, method, raw_line, external, source_kind, resolution }
--- Inverts Python traceback blocks individually so that crash-first navigation starts
--- at the innermost fault frame instead of the outermost frame, without reordering
--- unrelated non-Python stack frames in a mixed trace.
--- For Python traceback blocks exceeding max_frames, retains the innermost (last N)
--- crash frames rather than the outermost using bounded storage.
--- Also avoids misinterpreting indented Python source lines (e.g. value = "file:123")
--- as non-Python frames.
---@param text string
---@param opts? { root?: string, path_mappings?: table<string, string>, max_frames?: number }
---@return table[]
function M.parse(text, opts)
  opts = opts or {}
  local frames = {}
  if not text or text == "" then
    return frames
  end

  local compiled_mappings = opts.path_mappings and M.compile_path_mappings(opts.path_mappings) or nil
  local cache = {}
  local norm_opts = {
    root = opts.root,
    compiled_mappings = compiled_mappings,
    cache = cache,
  }

  local max_frames = opts.max_frames or 1000

  -- State machine for per-block Python traceback parsing
  local in_python_block = false
  -- python_block_frames holds at most max_frames items
  local python_block_frames = {}

  local function flush_python_block()
    if #python_block_frames > 0 then
      local remaining_capacity = math.max(0, max_frames - #frames)
      local count_to_keep = math.min(#python_block_frames, remaining_capacity)
      local start_idx = #python_block_frames - count_to_keep + 1

      for i = #python_block_frames, start_idx, -1 do
        table.insert(frames, python_block_frames[i])
      end
      python_block_frames = {}
    end
    in_python_block = false
  end

  for line in text:gmatch("[^\r\n]+") do
    if #frames >= max_frames and not in_python_block then
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
            -- If in Python block and line is indented (starts with whitespace) and does NOT
            -- start with "at " or "from " or "--> ", it's source code or error message.
            -- Do not attempt generic or non-Python matchers on indented source lines!
            local is_indented_source = (line:match("^%s") ~= nil) and not line:match("^%s*at%s+") and not line:match("^%s*from%s+") and not line:match("^%s*%-%-%>")
            if not is_indented_source then
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
          local original_path = matched_frame.file
          local display, resolved, navigable = M.resolve_and_normalize_path(original_path, norm_opts)

          -- Check Ruby language resolver for metadata enrichment
          local ok_ruby, ruby_resolver = pcall(require, "unwind.resolvers.ruby")
          local ruby_meta = nil
          if ok_ruby and ruby_resolver and ruby_resolver.resolve then
            ruby_meta = ruby_resolver.resolve(original_path, { root = opts.root })
          end

          matched_frame.raw_line = line
          matched_frame.path = original_path
          matched_frame.file = display
          if ruby_meta and ruby_meta.path then
            matched_frame.resolved_path = ruby_meta.path
            matched_frame.navigable = true
            matched_frame.external = true
            matched_frame.source_kind = ruby_meta.source_kind
            matched_frame.resolution = ruby_meta.resolution
          else
            matched_frame.resolved_path = resolved
            matched_frame.navigable = navigable
          end
          matched_frame.method = matched_frame.method or ""

          if is_python_frame then
            -- Bounded storage: keep only the last max_frames items
            local remaining_budget = math.max(0, max_frames - #frames)
            if remaining_budget > 0 then
              if #python_block_frames >= remaining_budget then
                table.remove(python_block_frames, 1)
              end
              table.insert(python_block_frames, matched_frame)
            end
          else
            if #frames < max_frames then
              table.insert(frames, matched_frame)
            end
          end
        end
      end
    end
  end

  flush_python_block()

  return frames
end

return M
