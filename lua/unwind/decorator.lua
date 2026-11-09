-- lua/unwind/decorator.lua
-- In-Buffer Extended Marks & Virtual Lines (virt_lines) API
-- Projects inline call-stack telemetry into source buffers

local M = {}

local ns = vim.api.nvim_create_namespace("unwind_diagnostics")

--- Get namespace ID
---@return number
function M.get_namespace()
  return ns
end

--- Clear all unwind diagnostics extmarks across all buffers or for a specific buffer
---@param bufnr? number If nil, clears across all loaded buffers
function M.clear(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  else
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      end
    end
  end
end

--- Format the method header cleanly:
--- If method is empty, nil, or generic "anonymous", omit it to avoid clutter.
--- If method already has parentheses or brackets (e.g. `<main>`, `<top>`), don't add redundant `()`.
---@param depth number
---@param method? string
---@param total_frames? number
---@return string
local function format_header(depth, method, total_frames)
  local depth_str = tostring(depth)
  if total_frames and total_frames > 0 then
    depth_str = depth_str .. "/" .. tostring(total_frames)
  end

  if not method or method == "" or method == "anonymous" then
    return "  ✕ [CALL STACK FAULT] Frame #" .. depth_str
  end

  local method_str = method
  if not method:find("%(") and not method:find("^<.*>$") then
    method_str = method .. "()"
  end

  return "  ✕ [CALL STACK FAULT] Frame #" .. depth_str .. ": " .. method_str
end

--- Render call-stack telemetry above the given line in bufnr
--- Virtual line content:
---   Badge/Header:   ✕ [CALL STACK FAULT] Frame #<depth>[/<total>]: <method>() (highlighted via DiagnosticError / DiagnosticSignError)
---   Details line:     ↳ <file>:<line> (highlighted via Comment or DiagnosticVirtualTextInfo)
--- Configuration options: virt_lines_overflow = "scroll" and strict = false
---@param bufnr number Buffer handle
---@param line number 1-indexed target line number
---@param depth number 1-indexed stack frame depth
---@param method? string Frame method name
---@param file string Frame file path
---@param total_frames? number Total stack frames count
---@return number|nil extmark_id
function M.render(bufnr, line, depth, method, file, total_frames)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  -- Clear previous decorations in this buffer first
  M.clear(bufnr)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local target_line = math.max(1, math.min(line or 1, line_count))
  local zero_based_line = target_line - 1

  local header_text = format_header(depth, method, total_frames)

  local virt_lines = {
    {
      { header_text, "DiagnosticError" },
    },
    {
      { "    ↳ " .. tostring(file) .. ":" .. tostring(line), "DiagnosticVirtualTextInfo" },
    },
  }

  local opts = {
    virt_lines = virt_lines,
    virt_lines_above = true,
    strict = false,
  }

  -- In Neovim, test if virt_lines_overflow is supported; if error occurs, fallback without it
  local test_opts = vim.tbl_extend("force", opts, { virt_lines_overflow = "scroll" })
  local ok, extmark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, zero_based_line, 0, test_opts)
  if not ok then
    ok, extmark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, zero_based_line, 0, opts)
    if not ok then
      return nil
    end
  end

  return extmark_id
end

return M
