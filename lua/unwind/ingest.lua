-- lua/unwind/ingest.lua
-- Stacktrace ingestion from text, clipboard, files, line ranges, and visual selections

local parser = require("unwind.parser")
local sessions = require("unwind.sessions")
local decorator = require("unwind.decorator")
local sidebar = require("unwind.sidebar")
local ui = require("unwind.ui")
local navigation = require("unwind.navigation")
local session_actions = require("unwind.session_actions")

local M = {}

--- Ingest a raw plain-text stacktrace string
---@param text string
---@param config table
---@param state table
---@param activate_fn fun(session: table)
---@return table|nil session
function M.from_text(text, config, state, activate_fn)
  if not text or text == "" then
    vim.notify("Unwind: Ingested text is empty.", vim.log.levels.WARN)
    return nil
  end

  local max_bytes = config.max_input_bytes or (2 * 1024 * 1024)
  if #text > max_bytes then
    vim.notify(string.format("Unwind: Ingested text exceeds maximum limit (%d bytes), truncating.", max_bytes), vim.log.levels.WARN)
    text = text:sub(1, max_bytes)
  end

  local root = vim.fs.normalize(vim.fn.getcwd())
  state.set_root(root)

  local frames = parser.parse(text, {
    root = root,
    path_mappings = config.path_mappings,
    max_frames = config.max_frames,
  })
  if #frames == 0 then
    vim.notify("Unwind: No stack frames recognized in input.", vim.log.levels.WARN)
    return nil
  end

  local filter_enabled = config.filter_out_of_project or false
  local session = sessions.create({
    root = root,
    frames = frames,
    filter_enabled = filter_enabled,
    transient = true,
    name = nil,
  })

  activate_fn(session)
  return session
end

--- Ingest stacktrace from clipboard register '+'
--- Always creates a NEW unnamed transient session rather than mutating active session.
---@param config table
---@param state table
---@param activate_fn fun(session: table)
---@return table|nil session
function M.from_clipboard(config, state, activate_fn)
  local text = vim.fn.getreg("+")
  if not text or text == "" then
    vim.notify("Unwind: Clipboard (+) is empty.", vim.log.levels.WARN)
    return nil
  end

  local max_bytes = config.max_input_bytes or (2 * 1024 * 1024)
  if #text > max_bytes then
    vim.notify(string.format("Unwind: Ingested text exceeds maximum limit (%d bytes), truncating.", max_bytes), vim.log.levels.WARN)
    text = text:sub(1, max_bytes)
  end

  local root = vim.fs.normalize(vim.fn.getcwd())
  state.set_root(root)

  local frames = parser.parse(text, {
    root = root,
    path_mappings = config.path_mappings,
    max_frames = config.max_frames,
  })
  if #frames == 0 then
    vim.notify("Unwind: No stack frames recognized in clipboard.", vim.log.levels.WARN)
    return nil
  end

  local session = sessions.create({
    root = root,
    frames = frames,
    name = nil,
    transient = true,
    filter_enabled = config.filter_out_of_project or false,
  })

  activate_fn(session)
  return session
end

--- Ingest stacktrace from a 1-indexed line range
---@param line1 number
---@param line2 number
---@param config table
---@param state table
---@param activate_fn fun(session: table)
function M.from_range(line1, line2, config, state, activate_fn)
  line1, line2 = math.min(line1, line2), math.max(line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
  return M.from_text(table.concat(lines, "\n"), config, state, activate_fn)
end

--- Ingest stacktrace from visual selection range
---@param config table
---@param state table
---@param activate_fn fun(session: table)
function M.from_selection(config, state, activate_fn)
  local mode = vim.fn.mode()
  if mode:find("[vV\22]") then
    vim.cmd([[execute "normal! \<ESC>"]])
  end

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local s_buf, s_row = start_pos[1], start_pos[2]
  local e_buf, e_row = end_pos[1], end_pos[2]

  local cur_buf = vim.api.nvim_get_current_buf()
  if s_row == 0 or e_row == 0 or (s_buf ~= 0 and s_buf ~= cur_buf) then
    vim.notify("Unwind: No visual selection found.", vim.log.levels.WARN)
    return
  end

  if s_row > e_row then
    s_row, e_row = e_row, s_row
  end

  return M.from_range(s_row, e_row, config, state, activate_fn)
end

--- Ingest stacktrace from a file path
---@param filepath string
---@param config table
---@param state table
---@param activate_fn fun(session: table)
function M.from_file(filepath, config, state, activate_fn)
  if not filepath or filepath == "" then
    vim.notify("Unwind: File path must be specified.", vim.log.levels.ERROR)
    return
  end

  local expanded_path = vim.fn.expand(filepath)
  local f = io.open(expanded_path, "r")
  if not f then
    vim.notify("Unwind: Could not open file: " .. tostring(expanded_path), vim.log.levels.ERROR)
    return
  end

  local limit = config.max_input_bytes or (2 * 1024 * 1024)
  local ok, content = pcall(function()
    return f:read(limit + 1)
  end)
  f:close()

  if not ok then
    vim.notify("Unwind: Error reading file " .. tostring(expanded_path) .. ": " .. tostring(content), vim.log.levels.ERROR)
    return
  end

  if not content or content == "" then
    vim.notify("Unwind: File is empty: " .. tostring(expanded_path), vim.log.levels.WARN)
    return
  end

  if #content > limit then
    vim.notify(string.format("Unwind: Ingested file exceeds maximum limit (%d bytes), truncating.", limit), vim.log.levels.WARN)
    content = content:sub(1, limit)
  end

  return M.from_text(content, config, state, activate_fn)
end

return M
