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

return M
