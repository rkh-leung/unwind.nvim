-- lua/unwind/keymaps.lua
--- Keymap installation, tracking, and teardown for unwind.nvim
local M = {}

--- Track keymaps installed by Unwind so subsequent setup() calls clean up old ones
M.installed_keymaps = {}

--- Centralized keymap installer with ownership tracking
---@param keymaps table|boolean|nil Keymap table or false to disable
---@param force? boolean If true, overrides existing non-Unwind keymaps
---@param callbacks? table Map of action names to callback functions
function M.install_keymaps(keymaps, force, callbacks)
  callbacks = callbacks or {}

  for _, lhs in ipairs(M.installed_keymaps) do
    local map = vim.fn.maparg(lhs, "n", false, true)
    if map and map.desc and map.desc:match("^Unwind:") then
      pcall(vim.keymap.del, "n", lhs)
    end
  end
  M.installed_keymaps = {}

  if not keymaps or keymaps == false then
    return
  end

  local function register_key(lhs, fn, desc)
    if lhs and lhs ~= "" and fn then
      local existing = vim.fn.maparg(lhs, "n", false, true)
      local is_empty = not existing or existing.lhs == nil or existing.lhs == ""
      local is_unwind = existing and existing.desc and existing.desc:match("^Unwind:")

      if is_empty or is_unwind or force then
        vim.keymap.set("n", lhs, fn, { desc = desc, silent = true })
        table.insert(M.installed_keymaps, lhs)
      end
    end
  end

  register_key(keymaps.menu, callbacks.menu, "Unwind: Open session manager")
  register_key(keymaps.clipboard, callbacks.clipboard, "Unwind: Ingest stacktrace from clipboard")
  register_key(keymaps.next, callbacks.next, "Unwind: Next stack frame")
  register_key(keymaps.prev, callbacks.prev, "Unwind: Previous stack frame")
  register_key(keymaps.next_file, callbacks.next_file, "Unwind: Next stacktrace file")
  register_key(keymaps.prev_file, callbacks.prev_file, "Unwind: Previous stacktrace file")
end

return M
