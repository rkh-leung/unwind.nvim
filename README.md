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
- **Inline Virtual Line Telemetry**: Extended mark (`virt_lines`) decorations above fault lines with frame depth (`#depth/total`), method name (omitting noisy `anonymous()` placeholders), file, and line information.
- **Vendor / Gem / Library Filtering**: Automatically flags or collapses non-workspace third-party library frames (e.g. `shared/bundle/ruby/...`, `/gems/`, `vendor/bundle/`, `node_modules/`, `/usr/lib/`).
- **File vs. Frame Cycling**: Instant file-by-file navigation (`]f` / `[f`) alongside detailed frame-by-frame stepping (`]u` / `[u`).

---

## Understanding Frames vs. Files

### What is a Stack Frame, and Why Are There Multiples per File?
In runtime crash dumps and tracebacks, a **stack frame** represents a single activation record / function call currently on the call execution stack.

When you see multiple frames associated with one file:
- **Middleware and Callback Chains**: Libraries like Rails `ActiveSupport` or `ActiveRecord` often execute through deep chains of callbacks, instrumentation blocks, and query wrappers within the same file (e.g., 27 frames inside `callbacks.rb`).
- **Nested Functions & Blocks**: Multiple blocks or nested method calls inside the same file appear as separate frames at different line numbers.
- **Recursion**: Recursive functions produce a new frame for every recursive depth level.

### Frame Navigation vs. File Navigation
- **Frame Cycling (`]u` / `[u`)**: Steps through every individual execution frame in the call stack sequentially. If a file has 27 frames (such as an internal framework wrapper), pressing `]u` steps through each of those 27 frames line-by-line.
- **File Cycling (`]f` / `[f`)**: Jumps directly between **unique implicated files** at their primary fault lines (identical to jumping from the `<leader>w` menu, but as a direct keybinding). Use `]f` / `[f` when you want to quickly navigate between distinct codebase files without stepping through repetitive internal frames.

---

## Handling Third-Party & Vendor Stacktraces

Crash traces frequently contain deep stack frames from external packages and installed bundles that are not part of your application repository (e.g., `/apps/.../shared/bundle/ruby/3.3.0/gems/...`, `vendor/bundle/`, `node_modules/`, `/usr/lib/`).

`unwind.nvim` handles this seamlessly:
1. **Visual Tagging**: The floating menu (`<leader>w`) identifies and tags external paths with `[vendor]`.
2. **Filtering**: You can toggle hiding external vendor traces on the fly with `:UnwindToggleFilter`.
3. **Workspace-Only by Default**: Enable `filter_out_of_project = true` in your setup configuration to hide vendor and out-of-workspace files automatically upon ingestion, keeping only your project's codebase files in view.

---

## How to Use & Workflow Guide

`unwind.nvim` is designed to be used directly from your codebase directory so that paths in stacktraces are automatically mapped to your local source files.

### 1. Launch Neovim in your project root

Navigate to your code repository and launch Neovim with the repository as the root directory:

```bash
cd /path/to/my-project
nvim .
```

Running `nvim .` ensures Neovim's current working directory (`vim.fn.getcwd()`) points to your codebase. `unwind.nvim` uses this working directory to automatically strip container and build prefixes (e.g. `/app/`, `/var/task/`, `C:\workspace\`) and resolve files in the stacktrace to local project files.

### 2. Provide the stacktrace

You can provide a crash stacktrace using any of four flexible methods:

1. **Directly from system clipboard** (Fastest):
   - Copy the stacktrace to your system clipboard from your terminal, CI log, or browser.
   - In Neovim, press `<leader>c` (or run `:UnwindClipboard`).
2. **From an interactive scratchpad window** (Great for remote SSH / tmux sessions without clipboard support):
   - Run `:UnwindInput` or `:Unwind`.
   - A floating input window will appear. Paste or type your stacktrace into the buffer.
   - Press `<C-s>` or `:w<CR>` to submit, or `q` / `<Esc>` in normal mode to cancel.
3. **From a file on disk**:
   - Run `:UnwindFile /path/to/trace.log` (or `:Unwind path/to/trace.log`). Path completion is enabled via `<Tab>`.
4. **From a visual selection in an open buffer**:
   - Highlight the lines containing the stacktrace in visual mode (`V`).
   - Run `:UnwindSelection`.

### 3. Navigate the codebase with the stacktrace overlay

Once ingested:
- **Instant Overlay**: `unwind.nvim` automatically opens the file of the first (primary) fault frame, moves the cursor to the exact line and column, and overlays an inline diagnostic banner (`virt_lines`) right above the fault line:
  ```text
    ✕ [CALL STACK FAULT] Frame #1: ProcessPayment()
      ↳ src/services/checkout.lua:104
  ```
- **Cycle Through Frames**:
  - `]u` (or `:UnwindNext`): Jump to the next stack frame down the call stack.
  - `[u` (or `:UnwindPrev`): Jump to the previous stack frame up the call stack.
- **Cycle Through Distinct Files Directly**:
  - `]f` (or `:UnwindNextFile`): Jump immediately to the next unique file at its primary fault line.
  - `[f` (or `:UnwindPrevFile`): Jump immediately to the previous unique file at its primary fault line.
- **Harpoon-Style File Menu**:
  - Press `<leader>w` (or run `:UnwindMenu`) to open the floating menu showing unique implicated files in occurrence order.
  - Press `1` through `9` to jump directly to slot 1–9.
  - Press `<CR>` to jump to the selected file at its primary fault line.
  - Press `q` or `<Esc>` to dismiss the menu.
- **Filter Vendor/Third-Party Traces**:
  - Run `:UnwindToggleFilter` to toggle hiding/showing external vendor/library frames on demand.
- **Clear Overlays**:
  - Run `:UnwindClear` whenever you want to dismiss all active decorations and reset state.

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
  filter_out_of_project = false, -- Set to true to hide vendor/library frames by default
  ignore_patterns = {            -- Custom patterns to identify vendor paths
    "shared/bundle/",
    "vendor/bundle/",
    "/gems/",
    "node_modules/",
    "^/usr/",
  },
  keymaps = {
    menu = "<leader>w",      -- Open Harpoon-style distinct files menu (single key)
    clipboard = "<leader>c", -- Ingest stacktrace from clipboard (+) (single key)
    next = "]u",             -- Jump to next stack frame
    prev = "[u",             -- Jump to previous stack frame
    next_file = "]f",        -- Jump directly to next unique file
    prev_file = "[f",        -- Jump directly to previous unique file
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
| `:Unwind [path]` | Ingests stacktrace from file `[path]` or opens interactive paste modal |
| `:UnwindFile <path>` | Ingests stacktrace from specified file |
| `:UnwindInput` | Opens interactive floating scratchpad to paste/type a stacktrace |
| `:UnwindClipboard` | Ingests stacktrace from clipboard `+` register |
| `:UnwindSelection` | Ingests stacktrace from visually highlighted range |
| `:UnwindMenu` | Toggles the Harpoon-style floating distinct files menu |
| `:UnwindNext` | Jumps to next stack frame with inline virtual line context |
| `:UnwindPrev` | Jumps to previous stack frame with inline virtual line context |
| `:UnwindNextFile` | Jumps directly to next unique file at primary fault line |
| `:UnwindPrevFile` | Jumps directly to previous unique file at primary fault line |
| `:UnwindToggleFilter` | Toggles filtering out vendor / third-party library files |
| `:UnwindClear` | Clears active decorations, highlights, and state |

---

## Default Keybindings

All leader keymaps use a single key after `<leader>`:

- `<leader>w` -> Toggle file menu
- `<leader>c` -> Ingest from clipboard
- `]u` -> Next stack frame
- `[u` -> Previous stack frame
- `]f` -> Next unique file
- `[f` -> Previous unique file

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
