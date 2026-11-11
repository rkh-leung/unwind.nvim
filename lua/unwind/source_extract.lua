-- lua/unwind/source_extract.lua
-- Source method extraction using Tree-sitter AST and fallback excerpts
-- Reads from loaded Neovim buffers (including unsaved edits) or directly from disk

local path_util = require("unwind.path")
local location = require("unwind.location")

local M = {}

--- Detect markdown code fence language identifier from file extension or path
---@param fpath string
---@return string
function M.detect_fence_lang(fpath)
  if not fpath then return "" end
  local ext = fpath:match("%.([%w_]+)$")
  if not ext then return "" end
  ext = ext:lower()
  local map = {
    lua = "lua",
    py = "python",
    rb = "ruby",
    js = "javascript",
    ts = "typescript",
    jsx = "javascript",
    tsx = "typescript",
    rs = "rust",
    go = "go",
    c = "c",
    h = "c",
    cpp = "cpp",
    hpp = "cpp",
    cc = "cpp",
    java = "java",
    cs = "csharp",
    sh = "bash",
    json = "json",
    yml = "yaml",
    yaml = "yaml",
  }
  return map[ext] or ext
end

--- Read source lines and metadata without modifying editor window/buffer state.
--- Uses loaded Neovim buffer (including unsaved modifications) if one exists for the canonical path;
--- otherwise reads cleanly from disk.
---@param abs_path string
---@return { lines: string[], source_type: string, is_modified: boolean }|nil
function M.read_source(abs_path)
  if not abs_path or abs_path == "" then
    return nil
  end

  local norm_path = vim.fs.normalize(abs_path)
  local real_path = (vim.uv or vim.loop).fs_realpath(norm_path) or norm_path

  -- Check if there is an existing loaded Neovim buffer
  local target_bufnr = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
      local bname = vim.fs.normalize(vim.api.nvim_buf_get_name(b))
      if bname ~= "" then
        local real_bname = (vim.uv or vim.loop).fs_realpath(bname) or bname
        if real_bname == real_path or bname == norm_path then
          target_bufnr = b
          break
        end
      end
    end
  end

  if target_bufnr then
    local is_mod = vim.bo[target_bufnr].modified
    local lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
    return {
      lines = lines,
      source_type = is_mod and "buffer (unsaved)" or "buffer",
      is_modified = is_mod,
      bufnr = target_bufnr,
    }
  end

  -- Fallback to reading file directly from disk
  if not path_util.is_file(norm_path) and not path_util.is_file(abs_path) then
    return nil
  end

  local f = io.open(norm_path, "r") or io.open(abs_path, "r")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()

  if not content then
    return nil
  end

  local lines = vim.split(content, "\n", { plain = true })
  return {
    lines = lines,
    source_type = "disk",
    is_modified = false,
  }
end

--- Check if method name in trace and extracted method clearly disagree
---@param trace_method? string
---@param extracted_name? string
---@return boolean disagree
function M.methods_disagree(trace_method, extracted_name)
  if not trace_method or trace_method == "" or not extracted_name or extracted_name == "" then
    return false
  end

  local tm = trace_method:lower()
  local em = extracted_name:lower()

  -- Remove common prefixes/qualifiers like Class#method or Mod::Class.method
  local bare_tm = tm:match("[#:%.]([^#:%.]+)$") or tm
  local bare_em = em:match("[#:%.]([^#:%.]+)$") or em

  -- Strip trailing parentheses or args
  bare_tm = bare_tm:match("^([%w_]+)") or bare_tm
  bare_em = bare_em:match("^([%w_]+)") or bare_em

  if bare_tm == bare_em or bare_tm:find(bare_em, 1, true) or bare_em:find(bare_tm, 1, true) then
    return false
  end

  -- Special case: block or anonymous in trace is not a mismatch against enclosing method
  if bare_tm == "block" or bare_tm:match("^block") or bare_tm == "eval" or bare_tm == "<top>" or bare_tm == "main" then
    return false
  end

  return true
end

--- Create a scoped extraction context to reuse parsed files and methods within a single export
---@return table context
function M.create_context()
  local ctx = {
    sources = {},        -- abs_path -> source record or false
    methods = {},        -- "abs_path:start_row:end_row" -> method record
    temp_buffers = {},   -- scratch buffers allocated by this context
  }

  function ctx:dispose()
    for _, bufnr in ipairs(self.temp_buffers) do
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    self.sources = {}
    self.methods = {}
    self.temp_buffers = {}
  end

  return ctx
end

--- Extract enclosing method or context excerpt for a frame
---@param abs_path string
---@param target_line number
---@param opts? { column?: number, col?: number, method_hint?: string, fallback_context_lines?: number }
---@param ctx? table Optional per-export extraction context for caching
---@return {
---   kind: "method"|"excerpt",
---   name: string,
---   code: string,
---   lang: string,
---   start_line: number,
---   end_line: number,
---   trace_line: number,
---   source_type: string,
---   incomplete?: boolean,
---   warning?: string
--- }|nil
function M.extract(abs_path, target_line, opts, ctx)
  opts = opts or {}
  local method_hint = opts.method_hint
  local fallback_lines_count = opts.fallback_context_lines or 10

  local file_entry = nil
  if ctx and ctx.sources then
    file_entry = ctx.sources[abs_path]
  end

  if file_entry == false then
    return nil
  end

  if not file_entry then
    local src = M.read_source(abs_path)
    if not src then
      if ctx and ctx.sources then
        ctx.sources[abs_path] = false
      end
      return nil
    end

    local fence_lang = M.detect_fence_lang(abs_path)
    local scratch_buf = nil
    local owns_scratch = false

    if vim.treesitter and vim.treesitter.get_parser then
      if src.bufnr then
        scratch_buf = src.bufnr
      else
        scratch_buf = vim.api.nvim_create_buf(false, true)
        owns_scratch = true
        if ctx and ctx.temp_buffers then
          table.insert(ctx.temp_buffers, scratch_buf)
        end
        pcall(vim.api.nvim_buf_set_lines, scratch_buf, 0, -1, false, src.lines)
      end
    end

    local lang_to_use = fence_lang
    local ts_parser = nil
    if scratch_buf then
      local ok_lang, parser_lang = pcall(function()
        local ft = vim.filetype.match({ filename = abs_path, buf = scratch_buf })
        return ft or fence_lang
      end)
      lang_to_use = (ok_lang and parser_lang and parser_lang ~= "") and parser_lang or fence_lang
      local ok_p, p = pcall(vim.treesitter.get_parser, scratch_buf, lang_to_use)
      if ok_p and p then
        ts_parser = p
        pcall(function() p:parse() end)
      end
    end

    file_entry = {
      lines = src.lines,
      total_lines = #src.lines,
      source_type = src.source_type,
      fence_lang = fence_lang,
      lang_to_use = lang_to_use,
      scratch_buf = scratch_buf,
      owns_scratch = owns_scratch,
      ts_parser = ts_parser,
    }

    if ctx and ctx.sources then
      ctx.sources[abs_path] = file_entry
    end
  end

  local lines = file_entry.lines
  local total_lines = file_entry.total_lines
  local fence_lang = file_entry.fence_lang
  local lang_to_use = file_entry.lang_to_use
  local scratch_buf = file_entry.scratch_buf
  local ts_parser = file_entry.ts_parser

  local extracted = nil

  -- Attempt Tree-sitter extraction
  if scratch_buf and ts_parser then
      local ts_row = math.max(0, (target_line or 1) - 1)
      local target_line_text = lines[ts_row + 1] or ""
      local line_len = #target_line_text

      -- Compute candidate 0-indexed byte columns
      local first_non_ws_byte = target_line_text:find("%S")
      local fallback_col = first_non_ws_byte and (first_non_ws_byte - 1) or 0

      local raw_col = opts.column or opts.col
      local primary_col = nil
      if type(raw_col) == "number" and raw_col >= 1 then
        primary_col = math.floor(raw_col) - 1
        if primary_col < 0 or primary_col >= line_len then
          primary_col = nil
        end
      end

      local function find_enclosing_function_at(col)
        if not vim.treesitter.get_node then return nil end
        local ok_node, n = pcall(vim.treesitter.get_node, {
          bufnr = scratch_buf,
          pos = { ts_row, col },
        })
        if not ok_node or not n then return nil end
        local cur = n
        while cur do
          if location.is_function_node(lang_to_use, cur) then
            return cur
          end
          cur = cur:parent()
        end
        return nil
      end

      local func_node = nil
      if primary_col then
        func_node = find_enclosing_function_at(primary_col)
      end
      if not func_node then
        func_node = find_enclosing_function_at(fallback_col)
      end
      if not func_node and primary_col ~= 0 and fallback_col ~= 0 and line_len > 0 then
        func_node = find_enclosing_function_at(0)
      end

      if func_node then
        local s_row, s_col, e_row, e_col = func_node:range()
        local method_cache_key = string.format("%s:%d:%d", abs_path, s_row, e_row)
        if ctx and ctx.methods and ctx.methods[method_cache_key] then
          extracted = ctx.methods[method_cache_key]
        else
          local end_exclusive = (e_col == 0 and e_row > s_row) and e_row or (e_row + 1)
          local method_slice = vim.api.nvim_buf_get_lines(scratch_buf, s_row, end_exclusive, false)
          local extracted_name = location.get_function_name(lang_to_use, func_node, scratch_buf) or method_hint or "anonymous"

          local warning = nil
          if M.methods_disagree(method_hint, extracted_name) then
            warning = string.format("Extracted method '%s' differs from trace method '%s'", extracted_name, method_hint)
          end

          extracted = {
            kind = "method",
            name = extracted_name,
            code = table.concat(method_slice, "\n"),
            lang = fence_lang,
            start_line = s_row + 1,
            end_line = s_row + #method_slice,
            trace_line = target_line,
            source_type = file_entry.source_type,
            incomplete = false,
            warning = warning,
          }
          if ctx and ctx.methods then
            ctx.methods[method_cache_key] = extracted
          end
        end
      end
    end

    if not ctx and file_entry.owns_scratch and scratch_buf then
      pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
    end

  if extracted then
    return extracted
  end

  -- Fallback: extract context lines around target_line
  if target_line and total_lines > 0 then
    local clamped_line = math.max(1, math.min(target_line, total_lines))
    local half = math.floor(fallback_lines_count / 2)
    local s_idx = math.max(1, clamped_line - half)
    local e_idx = math.min(total_lines, s_idx + fallback_lines_count - 1)
    if e_idx - s_idx + 1 < fallback_lines_count then
      s_idx = math.max(1, e_idx - fallback_lines_count + 1)
    end

    local snippet_lines = {}
    for i = s_idx, e_idx do
      table.insert(snippet_lines, lines[i])
    end

    return {
      kind = "excerpt",
      name = method_hint or string.format("line %d", clamped_line),
      code = table.concat(snippet_lines, "\n"),
      lang = fence_lang,
      start_line = s_idx,
      end_line = e_idx,
      trace_line = target_line,
      source_type = file_entry.source_type,
      incomplete = true,
      warning = "Tree-sitter parser or enclosing method not found; extracted source excerpt",
    }
  end

  return nil
end

return M
