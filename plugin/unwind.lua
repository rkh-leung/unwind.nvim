-- plugin/unwind.lua
-- Auto-loaded entrypoint; commands and default keybindings

if vim.g.loaded_unwind == 1 then
  return
end
vim.g.loaded_unwind = 1

-- User Commands (using inline require("unwind") calls to preserve lazy loading)
vim.api.nvim_create_user_command("UnwindClipboard", function()
  require("unwind").ingest_clipboard()
end, { desc = "Ingest stacktrace from clipboard" })

vim.api.nvim_create_user_command("UnwindSelection", function(opts)
  if opts.range and opts.range > 0 then
    require("unwind").ingest_range(opts.line1, opts.line2)
  else
    require("unwind").ingest_selection()
  end
end, { range = true, desc = "Ingest stacktrace from visual selection" })

vim.api.nvim_create_user_command("UnwindFile", function(opts)
  require("unwind").ingest_file(opts.args)
end, { nargs = 1, complete = "file", desc = "Ingest stacktrace from file" })

vim.api.nvim_create_user_command("UnwindInput", function()
  require("unwind").open_input()
end, { desc = "Open interactive input buffer to paste/type stacktrace" })

vim.api.nvim_create_user_command("Unwind", function(opts)
  require("unwind").unwind(opts.args)
end, { nargs = "?", complete = "file", desc = "Ingest stacktrace from file or open interactive input window" })

vim.api.nvim_create_user_command("UnwindMenu", function()
  require("unwind").menu()
end, { desc = "Toggle persistent session manager" })

vim.api.nvim_create_user_command("UnwindAdd", function()
  require("unwind").add_current_location()
end, { desc = "Add current source location to active debugging session" })

vim.api.nvim_create_user_command("UnwindSidebar", function()
  require("unwind").toggle_sidebar()
end, { desc = "Toggle persistent call-trace sidebar" })

vim.api.nvim_create_user_command("UnwindNext", function()
  require("unwind").next()
end, { desc = "Jump to next stack frame" })

vim.api.nvim_create_user_command("UnwindPrev", function()
  require("unwind").prev()
end, { desc = "Jump to previous stack frame" })

vim.api.nvim_create_user_command("UnwindNextFile", function()
  require("unwind").next_file()
end, { desc = "Jump to next stacktrace file" })

vim.api.nvim_create_user_command("UnwindPrevFile", function()
  require("unwind").prev_file()
end, { desc = "Jump to previous stacktrace file" })

vim.api.nvim_create_user_command("UnwindToggleFilter", function()
  require("unwind").toggle_filter()
end, { desc = "Toggle filtering out vendor and external library files" })

vim.api.nvim_create_user_command("UnwindQuickfix", function()
  require("unwind").quickfix()
end, { desc = "Export active stacktrace frames to Neovim's quickfix list" })

vim.api.nvim_create_user_command("UnwindClear", function()
  require("unwind").clear()
end, { desc = "Clear active decorations and state" })

-- Keymaps are managed by require("unwind").setup()
