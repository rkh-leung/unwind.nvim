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

--- Extract enclosing method or context excerpt for a frame
---@param abs_path string
---@param target_line number
---@param opts? { method_hint?: string, fallback_context_lines?: number }
---@return {
---   kind: "method"|"excerpt",
---   name: string,
---   code: string,
---   lang: string,
---   start_line: number,
---   end_line: number,
---   trace_line: number,
---   source_type: string,
---   truncated: boolean,
---   incomplete?: boolean,
---   warning?: string
--- }|nil
function M.extract(abs_path, target_line, opts)
  opts = opts or {}
  local method_hint = opts.method_hint
  local fallback_lines_count = opts.fallback_context_lines or 10

  local src = M.read_source(abs_path)
  if not src then
    return nil
  end

  local lines = src.lines
  local total_lines = #lines
  local fence_lang = M.detect_fence_lang(abs_path)

  local extracted = nil

  -- Attempt Tree-sitter extraction
  if vim.treesitter and vim.treesitter.get_parser then
    local scratch_buf = nil
    local owns_scratch = false

    if src.bufnr then
      scratch_buf = src.bufnr
    else
      scratch_buf = vim.api.nvim_create_buf(false, true)
      owns_scratch = true
      pcall(vim.api.nvim_buf_set_lines, scratch_buf, 0, -1, false, lines)
    end

    local ok_lang, parser_lang = pcall(function()
      local ft = vim.filetype.match({ filename = abs_path, buf = scratch_buf })
      return ft or fence_lang
    end)
    local lang_to_use = (ok_lang and parser_lang and parser_lang ~= "") and parser_lang or fence_lang

    local ok_parser, ts_parser = pcall(vim.treesitter.get_parser, scratch_buf, lang_to_use)
    if ok_parser and ts_parser then
      pcall(function() ts_parser:parse() end)
      local ts_row = math.max(0, (target_line or 1) - 1)
      local ts_col = 0

      local node = nil
      if vim.treesitter.get_node then
        local ok_node, n = pcall(vim.treesitter.get_node, {
          bufnr = scratch_buf,
          pos = { ts_row, ts_col },
        })
        if ok_node then
          node = n
        end
      end

      -- Ascend AST: if inside a block or closure, continue ascending to find
      -- enclosing method or function (especially vital for Ruby block frames)
      local current = node
      while current do
        if location.is_function_node(lang_to_use, current) then
          local s_row, _, e_row, _ = current:range()
          local extracted_name = location.get_function_name(lang_to_use, current, scratch_buf) or method_hint or "anonymous"
          local method_slice = vim.api.nvim_buf_get_lines(scratch_buf, s_row, e_row + 1, false)

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
            end_line = e_row + 1,
            trace_line = target_line,
            source_type = src.source_type,
            truncated = false,
            incomplete = false,
            warning = warning,
          }
          break
        end
        current = current:parent()
      end
    end

    if owns_scratch and scratch_buf then
      pcall(vim.api.nvim_buf_delete, scratch_buf, { force = true })
    end
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
      source_type = src.source_type,
      truncated = false,
      incomplete = true,
      warning = "Tree-sitter parser or enclosing method not found; extracted source excerpt",
    }
  end

  return nil
end

return M
