-- lua/unwind/export.lua
-- Markdown export for active Unwind debugging sessions respecting filter state

local path_util = require("unwind.path")
local source_extract = require("unwind.source_extract")
local ui = require("unwind.ui")
local sidebar = require("unwind.sidebar")

local M = {}

--- Default export configuration options
M.defaults = {
  fallback_context_lines = 10,
}

--- Determine a safe markdown code fence string that exceeds any consecutive backticks in code
---@param code string
---@return string fence
local function get_safe_fence(code)
  local max_ticks = 2
  for ticks in code:gmatch("`+") do
    if #ticks > max_ticks then
      max_ticks = #ticks
    end
  end
  return string.rep("`", max_ticks + 1)
end

--- Build structured Markdown export data from a session
---@param session table
---@param opts? table Export configuration options
---@return { lines: string[], warnings: string[], manifest: table }
function M.build(session, opts)
  if not session then
    return {
      lines = { "# Unwind Investigation Export", "", "_No active session._" },
      warnings = { "No active session" },
      manifest = {},
    }
  end

  opts = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  local root = session.root or vim.fs.normalize(vim.fn.getcwd())
  local filter_enabled = session.filter_enabled == true
  local total_frames = session.raw_frames and #session.raw_frames or 0

  -- 1. FRAME SELECTION & FILTERING
  -- When filter is enabled: use session.frames (the authoritative filtered collection)
  -- When filter is disabled: use session.raw_frames (all frames in active session)
  local included_frames
  if filter_enabled then
    included_frames = session.frames or {}
  else
    included_frames = session.raw_frames or {}
  end

  local included_count = #included_frames
  local excluded_count = total_frames - included_count
  if excluded_count < 0 then
    excluded_count = 0
  end

  local project_name = vim.fs.basename(root)
  if not project_name or project_name == "" then
    project_name = root
  end

  local session_name = session.name or "Untitled"
  local mode_desc = filter_enabled and "Filtered — project source only" or "Unfiltered — all sources"

  local warnings = {}
  local manifest = {
    session_name = session_name,
    project_name = project_name,
    filter_enabled = filter_enabled,
    total_frames = total_frames,
    included_frames = included_count,
    excluded_frames = excluded_count,
    extracted_methods = {},
    unavailable_sources = 0,
    incomplete_extractions = 0,
    export_bytes = 0,
    export_size = "",
  }

  local lines = {}
  table.insert(lines, "# Unwind Investigation Export")
  table.insert(lines, "")
  table.insert(lines, string.format("Session: %s", session_name))
  table.insert(lines, string.format("Project: %s", project_name))
  table.insert(lines, string.format("Filter: %s", mode_desc))
  table.insert(lines, "")

  -- Diagnostic preamble for receiving LLM
  table.insert(lines, "> **Diagnostic Context & Source Revision Notice**")
  table.insert(lines, "> The source code below was extracted from the local repository checkout.")
  table.insert(lines, "> Local sources may differ from the environment where the original trace was captured.")
  table.insert(lines, "> Manually added debugging steps reflect investigator exploration and do not prove runtime execution.")
  table.insert(lines, "> Distinguish direct code evidence from hypotheses and propose verifiable reproduction steps.")
  table.insert(lines, "")

  -- 2. INVESTIGATION PATH
  table.insert(lines, "## Investigation Path")
  table.insert(lines, "")

  if included_count == 0 then
    table.insert(lines, "_No frames included in export._")
    table.insert(lines, "")
  end

  -- Pre-scan included frames to resolve paths and extract methods with deduplication
  local method_items = {}
  local method_dedup_map = {} -- key: resolved_path + ":" + start_line + ":" + end_line -> method_index
  local frame_to_method_idx = {} -- included_idx -> method_index or nil

  for idx, frame in ipairs(included_frames) do
    local abs_target = frame.resolved_path or frame.path or frame.file
    if abs_target and not path_util.is_absolute(abs_target) then
      abs_target = root .. "/" .. abs_target
    end
    abs_target = abs_target and vim.fs.normalize(abs_target) or nil

    local is_available = abs_target and (path_util.is_file(abs_target) or (vim.uv or vim.loop).fs_stat(abs_target) ~= nil) and frame.navigable ~= false

    if not is_available then
      frame_to_method_idx[idx] = nil
      manifest.unavailable_sources = manifest.unavailable_sources + 1
      table.insert(warnings, string.format("Source file unavailable for frame %d: %s", frame.raw_index or idx, frame.file or frame.path or "unknown"))
    else
      local extracted = source_extract.extract(abs_target, frame.line, {
        method_hint = frame.method,
        fallback_context_lines = opts.fallback_context_lines,
      })

      if not extracted then
        frame_to_method_idx[idx] = nil
        manifest.unavailable_sources = manifest.unavailable_sources + 1
        table.insert(warnings, string.format("Could not read or extract source for frame %d: %s:%d", frame.raw_index or idx, frame.file or frame.path, frame.line or 1))
      else
        if extracted.warning then
          table.insert(warnings, string.format("Frame %d (%s): %s", frame.raw_index or idx, frame.file or frame.path, extracted.warning))
        end

        local dedup_key = string.format("%s:%d:%d", abs_target, extracted.start_line, extracted.end_line)
        local existing_method_idx = method_dedup_map[dedup_key]

        if existing_method_idx then
          frame_to_method_idx[idx] = existing_method_idx
        else
          if extracted.kind == "excerpt" or extracted.incomplete then
            manifest.incomplete_extractions = manifest.incomplete_extractions + 1
          end

          table.insert(method_items, {
            id = #method_items + 1,
            frame_num = frame.raw_index or idx,
            file = frame.file or frame.path,
            resolved_path = abs_target,
            trace_line = frame.line,
            method_name = extracted.name,
            kind = extracted.kind,
            code = extracted.code,
            lang = extracted.lang,
            start_line = extracted.start_line,
            end_line = extracted.end_line,
            source_type = extracted.source_type,
            truncated = extracted.truncated or false,
            warning = extracted.warning,
          })
          local new_method_idx = #method_items
          method_dedup_map[dedup_key] = new_method_idx
          frame_to_method_idx[idx] = new_method_idx
        end
      end
    end
  end

  -- Render Investigation Path items
  for idx, frame in ipairs(included_frames) do
    local frame_num = idx
    local method_label = (frame.method and frame.method ~= "") and frame.method or (frame.file or "Unknown")
    local origin_suffix = (frame.origin == "manual") and " [manual]" or ""

    table.insert(lines, string.format("%d. %s%s", frame_num, method_label, origin_suffix))

    local display_file = frame.file or frame.path or "unknown"
    local line_num = frame.line or 1
    local col_num = frame.col or frame.column
    local file_line_str = (col_num and col_num > 1) and string.format("%s:%d:%d", display_file, line_num, col_num) or string.format("%s:%d", display_file, line_num)

    table.insert(lines, string.format("   File: %s", file_line_str))

    if frame.note and frame.note ~= "" then
      table.insert(lines, string.format("   Annotation: %s", frame.note))
    end

    local method_idx = frame_to_method_idx[idx]
    if method_idx then
      local m_item = method_items[method_idx]
      local label_prefix = (m_item.kind == "excerpt") and "Excerpt" or "Method"
      table.insert(lines, string.format("   Source: %s %d", label_prefix, method_idx))
    else
      table.insert(lines, "   Source: Unavailable")
    end

    table.insert(lines, "")
  end

  -- 3. EXTRACTED SOURCE
  table.insert(lines, "## Extracted Source")
  table.insert(lines, "")

  if #method_items == 0 then
    table.insert(lines, "_No source methods extracted._")
    table.insert(lines, "")
  else
    for _, item in ipairs(method_items) do
      local label_prefix = (item.kind == "excerpt") and "Excerpt" or "Method"
      table.insert(lines, string.format("### %s %d — %s", label_prefix, item.id, item.method_name))
      table.insert(lines, "")
      table.insert(lines, string.format("File: %s", item.file))
      if item.source_type and item.source_type ~= "disk" then
        table.insert(lines, string.format("Source origin: %s", item.source_type))
      end
      table.insert(lines, string.format("Trace line: %d", item.trace_line or 1))

      if item.kind == "method" then
        table.insert(lines, string.format("Method lines: %d–%d", item.start_line, item.end_line))
      else
        table.insert(lines, string.format("Context lines: %d–%d [Excerpt: Tree-sitter unavailable or location outside method]", item.start_line, item.end_line))
      end

      if item.warning then
        table.insert(lines, string.format("Warning: %s", item.warning))
      end

      table.insert(lines, "")
      local fence = get_safe_fence(item.code)
      table.insert(lines, string.format("%s%s", fence, item.lang or ""))
  local code_lines = vim.split(item.code, "\n", { plain = true })
  for _, c_line in ipairs(code_lines) do
    table.insert(lines, c_line)
  end
      table.insert(lines, fence)
      table.insert(lines, "")
    end
  end

  -- 4. EXPORT SUMMARY
  table.insert(lines, "## Export Summary")
  table.insert(lines, "")
  table.insert(lines, string.format("Frames in session: %d", total_frames))
  table.insert(lines, string.format("Frames included: %d", included_count))
  table.insert(lines, string.format("Frames excluded by filter: %d", excluded_count))
  table.insert(lines, string.format("Unique methods extracted: %d", #method_items))
  table.insert(lines, string.format("Unavailable sources: %d", manifest.unavailable_sources))
  table.insert(lines, string.format("Incomplete extractions: %d", manifest.incomplete_extractions))

  local size_line_idx = #lines + 1
  table.insert(lines, "") -- placeholder for Export size line

  if #warnings > 0 then
    table.insert(lines, "")
    table.insert(lines, "### Warnings")
    for _, w in ipairs(warnings) do
      table.insert(lines, string.format("- %s", w))
    end
  end
  table.insert(lines, "")

  manifest.extracted_methods = method_items

  -- Measure final generated output and report exact byte count accurately describing finished document
  local text_util = require("unwind.text")
  local total_output_bytes = 0
  for _ = 1, 10 do
    local readable = text_util.format_bytes(total_output_bytes)
    lines[size_line_idx] = string.format("Export size: %d bytes (%s)", total_output_bytes, readable)
    local doc = table.concat(lines, "\n")
    if #doc == total_output_bytes then
      break
    end
    total_output_bytes = #doc
  end

  manifest.export_bytes = total_output_bytes
  manifest.export_size = text_util.format_bytes(total_output_bytes)

  return {
    lines = lines,
    warnings = warnings,
    manifest = manifest,
  }
end

--- Export the active session to a new Markdown scratch buffer
---@param session? table Active session (defaults to state.current())
---@param opts? table Export configuration options
---@return integer bufnr Created buffer handle or -1 on error
function M.export_to_buffer(session, opts)
  local state = require("unwind.state")
  session = session or state.current()

  if not session or not session.raw_frames or #session.raw_frames == 0 then
    vim.notify("Unwind: No active session to export.", vim.log.levels.WARN)
    return -1
  end

  local result = M.build(session, opts)

  ui.ensure_source_window()
  sidebar.ensure_source_window()

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"

  local sname = session.name or "untitled"
  local clean_name = sname:lower():gsub("[^%w_%-]", "_")
  local bufname = string.format("unwind://export/%s.md", clean_name)
  pcall(vim.api.nvim_buf_set_name, bufnr, bufname)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, result.lines)
  vim.bo[bufnr].modified = false

  vim.api.nvim_set_current_buf(bufnr)

  local warn_count = #result.warnings
  if warn_count > 0 then
    vim.notify(string.format("Unwind: Exported to Markdown buffer with %d warning(s).", warn_count), vim.log.levels.WARN)
  else
    vim.notify("Unwind: Exported debugging session to Markdown buffer.", vim.log.levels.INFO)
  end

  return bufnr
end

return M
