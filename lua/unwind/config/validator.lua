---@module "unwind.config.validator"
--- Schema validation for unwind.nvim configuration options

local M = {}

local function clean_error(err)
  if not err then
    return "unknown error"
  end
  local str = tostring(err)
  local msg = str:match(":%d+:%s*(.+)$") or str
  return msg
end

--- Validate options table against unwind config schema
---@param opts table
---@return boolean ok
---@return string? err
function M.validate(opts)
  if opts == nil then
    return true
  end
  if type(opts) ~= "table" then
    return false, "opts must be a table, got " .. type(opts)
  end

  local ok, err = pcall(vim.validate, {
    filter_out_of_project = { opts.filter_out_of_project, "boolean", true },
    path_mappings = { opts.path_mappings, "table", true },
    max_input_bytes = { opts.max_input_bytes, "number", true },
    max_frames = { opts.max_frames, "number", true },
    ignore_patterns = { opts.ignore_patterns, "table", true },
    export = { opts.export, "table", true },
    keymaps = { opts.keymaps, { "table", "boolean" }, true },
    force_keymaps = { opts.force_keymaps, "boolean", true },
    add_position = { opts.add_position, "string", true },
    confirm_sync = { opts.confirm_sync, "boolean", true },
    picker = { opts.picker, { "string", "function" }, true },
  })

  if not ok then
    return false, clean_error(err)
  end

  if opts.add_position and opts.add_position ~= "after_active" and opts.add_position ~= "before_active" and opts.add_position ~= "end" then
    return false, "add_position must be 'after_active', 'before_active', or 'end'"
  end

  if opts.picker and type(opts.picker) == "string" and opts.picker == "" then
    return false, "picker cannot be an empty string"
  end

  if opts.max_input_bytes and opts.max_input_bytes <= 0 then
    return false, "max_input_bytes must be a positive number"
  end

  if opts.max_frames then
    if opts.max_frames <= 0 then
      return false, "max_frames must be a positive number"
    elseif opts.max_frames > 20000 then
      return false, "max_frames exceeds maximum allowed limit (20000)"
    end
  end

  if opts.path_mappings then
    for k, v in pairs(opts.path_mappings) do
      if type(k) ~= "string" or type(v) ~= "string" then
        return false, "path_mappings keys and values must all be strings"
      end
    end
  end

  if opts.export and type(opts.export) == "table" then
    local exp_ok, exp_err = pcall(vim.validate, {
      fallback_context_lines = { opts.export.fallback_context_lines, "number", true },
    })
    if not exp_ok then
      return false, clean_error(exp_err)
    end
    if opts.export.fallback_context_lines and opts.export.fallback_context_lines < 0 then
      return false, "fallback_context_lines must be non-negative"
    end
  end

  if opts.keymaps and type(opts.keymaps) == "table" then
    local km_ok, km_err = pcall(vim.validate, {
      menu = { opts.keymaps.menu, { "string", "boolean" }, true },
      clipboard = { opts.keymaps.clipboard, { "string", "boolean" }, true },
      next = { opts.keymaps.next, { "string", "boolean" }, true },
      prev = { opts.keymaps.prev, { "string", "boolean" }, true },
      next_file = { opts.keymaps.next_file, { "string", "boolean" }, true },
      prev_file = { opts.keymaps.prev_file, { "string", "boolean" }, true },
    })
    if not km_ok then
      return false, clean_error(km_err)
    end
  end

  return true
end

return M
