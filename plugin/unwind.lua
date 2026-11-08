-- plugin/unwind.lua
-- Auto-loaded entrypoint; commands and default keybindings

if vim.g.loaded_unwind == 1 then
  return
end
vim.g.loaded_unwind = 1

local unwind = require("unwind")

-- User Commands
vim.api.nvim_create_user_command("UnwindClipboard", function()
  unwind.ingest_clipboard()
end, { desc = "Ingest stacktrace from clipboard" })

vim.api.nvim_create_user_command("UnwindSelection", function()
  unwind.ingest_selection()
end, { range = true, desc = "Ingest stacktrace from visual selection" })

vim.api.nvim_create_user_command("UnwindFile", function(opts)
  unwind.ingest_file(opts.args)
end, { nargs = 1, complete = "file", desc = "Ingest stacktrace from file" })

vim.api.nvim_create_user_command("UnwindInput", function()
  unwind.open_input()
end, { desc = "Open interactive input buffer to paste/type stacktrace" })

vim.api.nvim_create_user_command("Unwind", function(opts)
  unwind.unwind(opts.args)
end, { nargs = "?", complete = "file", desc = "Ingest stacktrace from file or open interactive input window" })

vim.api.nvim_create_user_command("UnwindMenu", function()
  unwind.menu()
end, { desc = "Toggle Harpoon-style floating menu" })

vim.api.nvim_create_user_command("UnwindNext", function()
  unwind.next()
end, { desc = "Jump to next stack frame" })

vim.api.nvim_create_user_command("UnwindPrev", function()
  unwind.prev()
end, { desc = "Jump to previous stack frame" })

vim.api.nvim_create_user_command("UnwindClear", function()
  unwind.clear()
end, { desc = "Clear active decorations and state" })

-- Setup default keymaps if user hasn't explicitly disabled them
unwind.setup()
