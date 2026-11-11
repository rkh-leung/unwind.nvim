-- lua/unwind/decorator.lua
-- In-Buffer Extended Marks & Virtual Lines (virt_lines) API
-- Projects inline call-stack telemetry into source buffers

local M = {}

local ns = vim.api.nvim_create_namespace("unwind_diagnostics")
local last_buf = nil

--- Set up decorator highlight groups if not yet defined
local function setup_highlights()
  vim.api.nvim_set_hl(0, "UnwindDecorManual", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "UnwindDecorStack", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "UnwindAnnotation", { default = true, link = "Comment" })
end

--- Get namespace ID
---@return number
function M.get_namespace()
  return ns
end

--- Clear all unwind diagnostics extmarks for a specific buffer or the last decorated buffer
---@param bufnr? number If nil, clears the last decorated buffer
function M.clear(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  elseif last_buf and vim.api.nvim_buf_is_valid(last_buf) then
    vim.api.nvim_buf_clear_namespace(last_buf, ns, 0, -1)
  end
  if not bufnr or bufnr == last_buf then
    last_buf = nil
  end
end

--- Format the method header cleanly based on frame origin:
--- manual -> ● [DEBUG PATH] Step <depth>[/<total>]: <method>()
--- stacktrace -> ● [STACK FRAME] Frame <depth>[/<total>]: <method>()
--- If method is empty, nil, or generic "anonymous", omit it to avoid clutter.
--- If method already has parentheses or brackets (e.g. `<main>`, `<top>`), don't add redundant `()`.
---@param depth number
---@param method? string
---@param total_frames? number
---@param origin? string "manual" or "stacktrace"
---@return string header_text
---@return string hl_group
local function format_header(depth, method, total_frames, origin)
  local depth_str = tostring(depth)
  if total_frames and total_frames > 0 then
    depth_str = depth_str .. "/" .. tostring(total_frames)
  end

  local prefix
  local hl_group
  if origin == "manual" then
    prefix = "  ● [DEBUG PATH] Step " .. depth_str
    hl_group = "UnwindDecorManual"
  else
    prefix = "  ● [STACK FRAME] Frame " .. depth_str
    hl_group = "UnwindDecorStack"
  end

  if not method or method == "" or method == "anonymous" then
    return prefix, hl_group
  end

  local method_str = method
  if not method:find("%(") and not method:find("^<.*>$") then
    method_str = method .. "()"
  end

  return prefix .. ": " .. method_str, hl_group
end

--- Render call-stack telemetry above the given line in bufnr
--- Virtual line content:
---   Badge/Header:   ● [DEBUG PATH] Step #<depth>[/<total>]: <method>() or ● [STACK FRAME] Frame <depth>[/<total>]: <method>()
---   Details line:     ↳ <file>:<line> (highlighted via DiagnosticVirtualTextInfo)
---   Note line:        💬 <note> (highlighted via UnwindAnnotation)
---@param bufnr number Buffer handle
---@param line number 1-indexed target line number
---@param depth number 1-indexed stack frame depth
---@param method? string Frame method name
---@param file string Frame file path
---@param total_frames? number Total stack frames count
---@param opts? { origin?: string, note?: string }
---@return number|nil extmark_id
function M.render(bufnr, line, depth, method, file, total_frames, opts)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end

  setup_highlights()

  -- Clear previous decorations so only the active frame is marked
  M.clear()

  opts = opts or {}
  local origin = opts.origin
  local note = opts.note

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local target_line = math.max(1, math.min(line or 1, line_count))
  local zero_based_line = target_line - 1

  local header_text, header_hl = format_header(depth, method, total_frames, origin)

  local virt_lines = {
    {
      { header_text, header_hl },
    },
    {
      { "    ↳ " .. tostring(file) .. ":" .. tostring(line), "DiagnosticVirtualTextInfo" },
    },
  }

  if note and note ~= "" then
    table.insert(virt_lines, {
      { "    💬 " .. tostring(note), "UnwindAnnotation" },
    })
  end

  local opts = {
    virt_lines = virt_lines,
    virt_lines_above = true,
    strict = false,
  }

  local ok, extmark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, zero_based_line, 0, opts)
  if ok then
    last_buf = bufnr
    return extmark_id
  end

  return nil
end

return M
