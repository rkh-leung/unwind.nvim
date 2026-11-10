# unwind.nvim

A lightweight, high-performance stacktrace navigation plugin written entirely in native Lua (targeting Neovim >= 0.10).

`unwind.nvim` turns plain-text crash stacktraces directly into navigable Neovim source locations. It handles Raygun traces, compiler errors, Rust panics, Node.js/V8 traces, Python tracebacks, Ruby backtraces, and generic call frames. Traces are parsed entirely in-memory using pure Lua pattern matching, deduplicated into a Harpoon-style fast-switching modal menu showing unique implicated files, and projected as inline call-stack telemetry into source buffers using Neovim's extended marks (`virt_lines`) API.

There are zero external binary dependencies (no external CLI tools, no external JSON parsers, no RPC processes). All parsing and buffer navigation run entirely in-process within Neovim.

---

## Quick Start

1. Install with your plugin manager (e.g. `lazy.nvim`):
```lua
{
  "rkh-leung/unwind.nvim",
  config = function()
    require("unwind").setup()
  end,
}
```

2. Open Neovim in your project root (`cd /path/to/project && nvim .`).
3. Copy a crash stacktrace to your system clipboard.
4. Press `<leader>c` (or run `:UnwindClipboard`).
5. `unwind.nvim` automatically jumps to the primary fault location with an inline error overlay. Cycle frames with `]u` / `[u`, cycle distinct files with `]f` / `[f`, or press `<leader>w` to open the file selection menu.

---

## Features

- **Pure Lua In-Memory Parsing**: Zero external CLI processes or regex libraries. Ingests and parses 100+ line stacktraces in-process via native LuaJIT.
- **Multi-Language Support**:
  - Raygun / .NET / Java (`at Namespace.Class.Method(...) in /path/to/file.cs:line 123` or `at Class.Method(File.java:123)`)
  - Rust / Cargo / Compiler (`--> src/main.rs:45:12` or `at /path/to/main.rs:45`)
  - Node.js / V8 (`at Method (/path/to/file.js:45:12)` or `at /path/to/file.js:45:12`)
  - Python (`File "/path/to/file.py", line 45, in method_name`)
  - Ruby (`from /path/to/file.rb:12:in 'method_name'` or `/path/to/file.rb:12:in \`method_name\``)
  - Generic fallback (`([%w_%-./\\]+%.%w+):(%d+):?(%d*)`)
- **Intelligent Path Normalization**: Automatically translates remote/container prefixes (e.g. `/app/`, `/var/task/`, `C:\workspace\`) to local files relative to `vim.fn.getcwd()`, and supports explicit `path_mappings`.
- **Harpoon-Style Floating Menu**: Centered floating scratch window listing distinct files in occurrence order with frame counts, quick jump (`<CR>`, `1`–`9`), multibyte-aware layout, and clean wipeout on exit.
- **Inline Virtual Line Telemetry**: Extended mark (`virt_lines`) decorations above fault lines with frame depth (`#depth/total`), method name (omitting noisy `anonymous()` placeholders), file, and line information.
- **Vendor / Gem / Library Filtering**: Automatically flags or collapses non-workspace third-party library frames (e.g. `shared/bundle/ruby/...`, `/gems/`, `vendor/bundle/`, `node_modules/`, `/usr/lib/`).
- **File vs. Frame Cycling**: Instant file-by-file navigation (`]f` / `[f`) alongside detailed frame-by-frame stepping (`]u` / `[u`).
- **Quickfix Export**: Export all parsed stacktrace frames directly to Neovim's quickfix list with `:UnwindQuickfix`.

---

## Handling Third-Party & Vendor Stacktraces

Crash traces frequently contain deep stack frames from external packages and installed bundles that are not part of your application repository (e.g., `/apps/.../shared/bundle/ruby/3.3.0/gems/...`, `vendor/bundle/`, `node_modules/`, `/usr/lib/`).

`unwind.nvim` handles this seamlessly:
1. **Visual Tagging**: The floating menu (`<leader>w`) identifies and tags external paths with `[vendor]`.
2. **Filtering**: You can toggle hiding external vendor traces on the fly with `:UnwindToggleFilter`. Navigation context is preserved: if the currently inspected frame survives filtering, focus remains on it; otherwise, navigation falls back to the nearest surviving frame.
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

Running `nvim .` ensures Neovim's current working directory (`vim.fn.getcwd()`) points to your codebase. `unwind.nvim` pins this root on ingestion to translate container and build prefixes (e.g. `/app/`, `/var/task/`, `C:\workspace\`) to local project files, remaining invariant across buffer `:cd` changes.

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
  - Run `:UnwindToggleFilter` to toggle hiding/showing external vendor/library frames on demand. Surviving frame positions are preserved.
- **Quickfix Export**:
  - Run `:UnwindQuickfix` to export active frames to Neovim's quickfix list (`copen`), allowing standard `:cnext` and `:cprev` navigation.
- **Clear Overlays**:
  - Run `:UnwindClear` whenever you want to dismiss all active decorations and reset state.

---

## Path Resolution & Limitations

When stacktraces originate from remote systems, Docker containers, or CI runners, file paths often do not match the local filesystem exactly.

`unwind.nvim` resolves paths using the following priority:
1. **Explicit `path_mappings`**: Exact prefix translations configured in `setup()`. This is always the most reliable and recommended method for container or remote CI environments (e.g. `["/app/"] = vim.fn.getcwd()`).
2. **Direct Workspace Match**: Paths that exist directly on disk or as loaded buffers.
3. **Known Container Prefix Stripping**: Heuristic stripping of common prefixes (`/app/`, `/var/task/`, Windows drive roots).
4. **Iterative Suffix Matching**: Stripping leading path components progressively.

> **Note on Heuristic Suffix Resolution**: Suffix-based resolution is heuristic. If a project contains identical relative paths across multiple directories or monorepo subprojects, suffix stripping may resolve to the first matching file. In ambiguous environments, configure explicit `path_mappings` in `setup()` for deterministic resolution. Frames that cannot be resolved to existing local files remain navigable in the menu and quickfix list, but opening nonexistent files is prevented to avoid creating empty buffers.

---

## Installation

### Using native Vim packages (`vim.pack` / `packpath`)

Because `unwind.nvim` follows standard Neovim plugin conventions (with `plugin/` and `lua/` directories), it can be installed natively using Vim/Neovim packages without any external package manager:

1. Clone `unwind.nvim` into your package path (`packpath`):

```bash
# For automatic loading on startup:
git clone https://github.com/rkh-leung/unwind.nvim.git ~/.local/share/nvim/site/pack/plugins/start/unwind.nvim

# Or for optional loading on demand:
git clone https://github.com/rkh-leung/unwind.nvim.git ~/.local/share/nvim/site/pack/plugins/opt/unwind.nvim
```

2. Configure and load in your `init.lua`:

```lua
-- If placed under pack/*/opt/unwind.nvim, load it with packadd:
vim.cmd.packadd("unwind.nvim")

-- Configure options:
require("unwind").setup({
  filter_out_of_project = false,
  path_mappings = {
    ["/app"] = vim.fn.getcwd(),
  },
})
```

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "rkh-leung/unwind.nvim",
  config = function()
    require("unwind").setup({
      filter_out_of_project = false,
      path_mappings = {
        ["/app"] = vim.fn.getcwd(),
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
  end,
}
```

---

## Configuration Reference

The following table details every supported option in `require("unwind").setup(opts)`:

| Option | Type | Default | Description |
|---|---|---|---|
| `filter_out_of_project` | `boolean` | `false` | When `true`, automatically filters out vendor and external paths upon ingestion. |
| `path_mappings` | `table<string, string>` | `{}` | Key-value table mapping remote/container directory prefixes to local paths (e.g. `{ ["/app/"] = "./" }`). Evaluated longest prefix first. |
| `max_input_bytes` | `number` | `2097152` (2 MiB) | Maximum size in bytes of stacktrace text ingested from file or buffer before truncating. |
| `max_frames` | `number` | `1000` | Maximum number of stack frames retained in memory. For Python tracebacks, the innermost (last N) crash frames are preserved. |
| `ignore_patterns` | `string[]` | `{"shared/bundle/", "vendor/bundle/", "/gems/", "node_modules/", "^/usr/"}` | Lua patterns used to classify frames as external vendor or third-party code. |
| `keymaps` | `table\|false` | See table below | Keymap table for default normal mode bindings, or `false` to disable automatic keybinding registration. |
| `force_keymaps` | `boolean` | `false` | When `true`, overrides existing non-Unwind keymaps during setup. By default, Unwind respects user mappings and only overrides mappings it owns. |

### Default Keybindings

All leader keymaps follow single-key mappings:

| Action | Command | Default Keymap | Description |
|---|---|---|---|
| Toggle Menu | `:UnwindMenu` | `<leader>w` | Open Harpoon-style distinct files menu |
| Ingest Clipboard | `:UnwindClipboard` | `<leader>c` | Ingest stacktrace from system clipboard (`+`) |
| Next Frame | `:UnwindNext` | `]u` | Jump to next stack frame |
| Previous Frame | `:UnwindPrev` | `[u` | Jump to previous stack frame |
| Next File | `:UnwindNextFile` | `]f` | Jump directly to next unique file |
| Previous File | `:UnwindPrevFile` | `[f` | Jump directly to previous unique file |
| Toggle Filter | `:UnwindToggleFilter` | - | Toggle hiding/showing vendor & external frames |
| Quickfix Export | `:UnwindQuickfix` | - | Export stack frames to Neovim's quickfix list |
| Clear Telemetry | `:UnwindClear` | - | Clear active decorations, highlights, and state |

Inside the floating file menu:
- `<CR>` -> Jump to selected file at primary fault line
- `1` through `9` -> Jump directly to slot index 1–9
- `q` / `<Esc>` -> Dismiss and wipe menu window
- `j` / `k` -> Navigate rows

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
| `:UnwindQuickfix` | Exports active stacktrace frames to Neovim's quickfix list |
| `:UnwindClear` | Clears active decorations, highlights, and state |

---

## Running Tests

Run the headless test suite:

```bash
nvim --headless -u NONE -c "luafile tests/parser_spec.lua" -c "qa!"
nvim --headless -u NONE -c "luafile tests/leak_spec.lua" -c "qa!"
```
