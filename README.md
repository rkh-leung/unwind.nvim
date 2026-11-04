# unwind.nvim

A high-performance, standalone Neovim plugin written entirely in native Lua (targeting Neovim >= 0.10).

`unwind.nvim` ingests plain-text crash stacktraces directly from the system clipboard or active buffers (handling Raygun traces, compiler errors, Rust panics, Node.js/V8 traces, Python tracebacks, Ruby backtraces, and generic call frames). It parses the text in memory using pure Lua pattern matching, deduplicates the referenced files into a Harpoon-style fast-switching modal menu showing only unique files, and projects inline call-stack telemetry into source buffers using Neovim's extended marks (`virt_lines`) API.

There are zero external binary dependencies (no Rust CLI, no external JSON parsing, no external RPC processes). Everything executes in-process via LuaJIT with sub-millisecond response times.

---

## Features

- **Pure Lua In-Memory Parsing**: Zero external CLI processes or regex libraries. Instantaneous parsing of 100+ line stacktraces.
- **Multi-Language Support**:
  - Raygun / .NET / Java (`at Namespace.Class.Method(...) in /path/to/file.cs:line 123` or `at Class.Method(File.java:123)`)
  - Rust / Cargo / Compiler (`--> src/main.rs:45:12` or `at /path/to/main.rs:45`)
  - Node.js / V8 (`at Method (/path/to/file.js:45:12)` or `at /path/to/file.js:45:12`)
  - Python (`File "/path/to/file.py", line 45, in method_name`)
  - Ruby (`from /path/to/file.rb:12:in 'method_name'` or `/path/to/file.rb:12:in \`method_name\``)
  - Generic fallback (`([%w_%-./\\]+%.%w+):(%d+):?(%d*)`)
- **Intelligent Path Normalization**: Automatically strips container and virtual prefixes (e.g. `/app/`, `/var/task/`, `C:\workspace\`) to map to local files relative to `vim.fn.getcwd()`.
- **Harpoon-Style Floating Menu**: Centered floating scratch window listing distinct files in occurrence order with frame counts, quick jump (`<CR>`, `1`–`9`), and wipeout on exit.
- **Inline Virtual Line Telemetry**: Extended mark (`virt_lines`) decorations above fault lines with frame depth, method name, file, and line information.

---

## Installation

### Using native Vim packages (`vim.pack` / `packpath`)

Because `unwind.nvim` follows standard Neovim plugin conventions (with `plugin/` and `lua/` directories), it can be installed natively using Vim/Neovim packages without any external package manager:

1. Clone `unwind.nvim` into your package path (`packpath`):

```bash
# For automatic loading on startup:
git clone https://github.com/unwind-nvim/unwind.nvim.git ~/.local/share/nvim/site/pack/plugins/start/unwind.nvim

# Or for optional loading on demand:
git clone https://github.com/unwind-nvim/unwind.nvim.git ~/.local/share/nvim/site/pack/plugins/opt/unwind.nvim
```

2. Configure and load in your `init.lua`:

```lua
-- If placed under pack/*/opt/unwind.nvim, load it with packadd:
vim.cmd.packadd("unwind.nvim")

-- Optionally customize configuration (single-key leader keymaps are configured by default):
require("unwind").setup({
  keymaps = {
    menu = "<leader>w",      -- Open Harpoon-style distinct files menu (single key)
    clipboard = "<leader>c", -- Ingest stacktrace from clipboard (+) (single key)
    next = "]u",             -- Jump to next stack frame
    prev = "[u",             -- Jump to previous stack frame
  },
})
```

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "unwind-nvim/unwind.nvim",
  config = function()
    require("unwind").setup({
      keymaps = {
        menu = "<leader>w",      -- Open Harpoon-style distinct files menu (single key)
        clipboard = "<leader>c", -- Ingest stacktrace from clipboard (+) (single key)
        next = "]u",             -- Jump to next stack frame
        prev = "[u",             -- Jump to previous stack frame
      },
    })
  end,
}
```

---

## Commands

| Command | Description |
|---|---|
| `:UnwindClipboard` | Ingests stacktrace from clipboard `+` register |
| `:UnwindSelection` | Ingests stacktrace from visually highlighted range |
| `:UnwindMenu` | Toggles the Harpoon-style floating distinct files menu |
| `:UnwindNext` | Jumps to next stack frame with inline virtual line context |
| `:UnwindPrev` | Jumps to previous stack frame with inline virtual line context |
| `:UnwindClear` | Clears active decorations, highlights, and state |

---

## Default Keybindings

All leader keymaps use a single key after `<leader>`:

- `<leader>w` -> Toggle file menu
- `<leader>c` -> Ingest from clipboard
- `]u` -> Next stack frame
- `[u` -> Previous stack frame

Inside the floating file menu:
- `<CR>` -> Jump to selected file at primary fault line
- `1` through `9` -> Jump directly to slot index 1–9
- `q` / `<Esc>` -> Dismiss and wipe menu window
- `j` / `k` -> Navigate list

---

## Running Tests

Run the test suite using Neovim headless:

```bash
nvim --headless -u NONE -c "luafile tests/parser_spec.lua" -c "qa!"
```
