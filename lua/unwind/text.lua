-- lua/unwind/text.lua
-- String display and UTF-8 manipulation utilities for Neovim

local M = {}

--- Truncates text so its display width (via nvim_strwidth) does not exceed max_width.
--- Uses binary search over UTF-8 characters via vim.str_utfindex and vim.str_byteindex.
--- Guarantees UTF-8 character boundary safety without corrupting multibyte sequences.
---@param text string
---@param max_width number
---@return string
function M.truncate_display(text, max_width)
  if not text or text == "" or max_width <= 0 then
    return ""
  end

  local strwidth = vim.api.nvim_strwidth(text)
  if strwidth <= max_width then
    return text
  end

  -- vim.str_utfindex(s) returns character count in Neovim
  local char_count = vim.str_utfindex(text)
  local low = 0
  local high = char_count

  while low < high do
    local mid = math.floor((low + high + 1) / 2)
    local byte_index = vim.str_byteindex(text, mid)
    local candidate = text:sub(1, byte_index)

    if vim.api.nvim_strwidth(candidate) <= max_width then
      low = mid
    else
      high = mid - 1
    end
  end

  local byte_index = vim.str_byteindex(text, low)
  return text:sub(1, byte_index)
end

--- Formats byte size into human-readable binary units (B, KiB, MiB, GiB).
--- Uses 1024-based binary units with readable precision.
---@param bytes number
---@return string
function M.format_bytes(bytes)
  if not bytes or bytes <= 0 then
    return "0 B"
  elseif bytes < 1024 then
    return string.format("%d B", bytes)
  elseif bytes < 1024 * 1024 then
    return string.format("%.1f KiB", bytes / 1024)
  elseif bytes < 1024 * 1024 * 1024 then
    return string.format("%.2f MiB", bytes / (1024 * 1024))
  else
    return string.format("%.2f GiB", bytes / (1024 * 1024 * 1024))
  end
end

return M
