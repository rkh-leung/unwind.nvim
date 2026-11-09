# Technical Report: unwind.nvim Architecture & Operational Walkthrough

## Executive Summary

`unwind.nvim` is a high-performance, standalone Neovim plugin designed for Neovim >= 0.10. It enables developers to ingest crash stacktraces and error logs directly from system clipboards or Neovim visual buffer selections, parses the trace text using pure Lua pattern matching, deduplicates implicated files into a Harpoon-style floating menu, and projects inline virtual lines (`virt_lines`) at fault locations with interactive navigation.

The plugin requires zero external binary dependencies (no external Rust, Go, or Python binaries, and no RPC servers). All parsing and telemetry injection are executed in-process via LuaJIT with sub-millisecond overhead.

---

## 1. High-Level Architecture

The plugin is structured into distinct, modular layers following standard Neovim plugin conventions:

```
unwind.nvim/
├── plugin/
│   └── unwind.lua       # Auto-loaded entry point registering Vim commands and setup
├── lua/unwind/
│   ├── init.lua         # Plugin lifecycle, state container, navigation controller, public API
│   ├── parser.lua       # Multi-language stacktrace pattern matcher and path normalizer
│   ├── collector.lua    # Frame aggregation, file deduplication, and ordering logic
│   ├── decorator.lua    # Neovim extmarks & virt_lines inline telemetry projection
│   └── ui.lua           # Harpoon-style centered floating scratch window
└── tests/
    ├── fixtures/        # Sample stack traces (Raygun, Rust, Node.js, Ruby)
    └── parser_spec.lua  # Headless test runner testing parsing and aggregation
```

### End-to-End Execution Flow

```
[Clipboard (+)] or [Visual Selection]
                │
                ▼
      unwind.ingest(text)
                │
                ▼
      parser.parse(text)
         ├── Pattern Matchers (Raygun, Rust, Node, Python, Ruby, Generic)
         └── parser.normalize_path(path) (strips /app/, /var/task/, etc.)
                │
                ▼
     collector.collect(frames)
         ├── Deduplicate unique files (preserving occurrence order)
         └── Group frames & determine primary fault line
                │
                ▼
     unwind.jump_to_frame(1)
         ├── vim.cmd.edit(file)
         ├── vim.api.nvim_win_set_cursor(...)
         └── decorator.render(bufnr, line, depth, method, file)
                │
                ▼
    [Buffer extmark virt_lines active] <──> [ui.open(files) Floating Menu]
```

---

## 2. Component Deep Dive

### 2.1 Entry Point (`plugin/unwind.lua`)
When Neovim starts up or when the plugin is loaded via `packadd` or a plugin manager, `plugin/unwind.lua` is executed:
- Prevents redundant execution using `vim.g.loaded_unwind`.
- Registers user commands:
  - `:Unwind`: Ingests stacktrace from an optional file argument or opens an interactive paste scratchpad.
  - `:UnwindFile`: Ingests stacktrace from a specified file path.
  - `:UnwindInput`: Opens an interactive scratchpad window to paste/type a stacktrace.
  - `:UnwindClipboard`: Ingests trace from the `+` register.
  - `:UnwindSelection`: Ingests visually selected text using `range = true`.
  - `:UnwindMenu`: Toggles the Harpoon-style file switching float.
  - `:UnwindNext`: Cycles forward to the next stack frame.
  - `:UnwindPrev`: Cycles backward to the previous stack frame.
  - `:UnwindNextFile`: Cycles forward directly to the next unique file.
  - `:UnwindPrevFile`: Cycles backward directly to the previous unique file.
  - `:UnwindToggleFilter`: Toggles vendor / out-of-workspace library filtering.
  - `:UnwindClear`: Clears all extmarks, floating windows, and state.
- Automatically calls `unwind.setup()` with defaults unless pre-configured.

### 2.2 Core Controller & State (`lua/unwind/init.lua`)
`init.lua` serves as the central orchestrator and manages state:
```lua
M.state = {
  frames = {},        -- Ordered list of all parsed frames
  files = {},         -- Deduplicated list of unique file records
  active_index = 0,   -- Currently inspected frame index (1-based)
}
```
Key responsibilities:
- **`ingest_clipboard()`**: Reads `vim.fn.getreg("+")` and delegates to `ingest()`.
- **`ingest_selection()`**: Calculates visual bounds via `vim.fn.getpos("'<")` and `getpos("'>")`, slices buffer lines with column precision, and passes joined text to `ingest()`.
- **`jump_to_frame(idx)`**:
  - Clamps `idx` within `[1, #M.state.frames]`.
  - Uses `vim.cmd.edit` with `vim.fn.fnameescape` to switch to or open the target buffer.
  - Clamps line number to the buffer line count (`vim.api.nvim_buf_line_count`).
  - Sets the cursor via `nvim_win_set_cursor`.
  - Triggers `decorator.render()` to paint fault telemetry above the active line.
- **`next()` / `prev()`**: Circular cycling through the stack trace.
- **`clear()`**: Clears extmarks in buffers, closes floating windows, and resets state.

### 2.3 Pure Lua Parsing & Normalization (`lua/unwind/parser.lua`)
The parser processes text line-by-line without invoking shell utilities or external regex engines.

#### Supported Trace Formats & Matchers:
1. **Raygun / .NET / C#**: `at Namespace.Class.Method(...) in /path/to/file.cs:line 123`
2. **Java / .NET Parenthesized**: `at Class.Method(File.java:123)`
3. **Rust / Cargo Compiler**: `--> src/main.rs:45:12`
4. **Node.js / V8**: `at Method (/path/to/file.js:45:12)` or `at /path/to/file.js:45:12`
5. **Python**: `File "/path/to/file.py", line 45, in method_name`
6. **Ruby**: `from /path/to/file.rb:12:in 'method_name'` or `/path/to/file.rb:12:in \`method_name\``
7. **Generic Fallback**: Matches `([%w_%-./\\]+%.%w+):(%d+):?(%d*)` while rejecting URL schemes (`http:`, `https:`, `ftp:`).

#### Path Normalization (`normalize_path`):
Stack traces from CI, Docker containers, or cloud environments frequently contain foreign root paths (e.g., `/app/src/...`, `/var/task/...`, `C:\workspace\...`).
The normalizer:
1. Converts backslashes (`\`) to forward slashes (`/`).
2. Checks direct file existence using `vim.uv.fs_stat` (or `vim.loop.fs_stat` / `vim.fn.filereadable`).
3. If not found, strips known container prefixes (`^/app/`, `^/var/task/`, `^/usr/src/...`, `^[A-Za-z]:/workspace/`, etc.) and tests for existence relative to current working directory (`vim.fn.getcwd()`).
4. Iteratively strips leading path segments if needed until a matching file is found within the local project workspace.

### 2.4 File Aggregator (`lua/unwind/collector.lua`)
Groups parsed frames into unique file entries while strictly maintaining their chronological occurrence order (first fault file appears at index 1):
```lua
{
  file = "src/services/checkout.lua",
  primary_line = 104,
  primary_col = 1,
  primary_method = "ProcessPayment",
  total_frames = 2,
  frames = { ... }
}
```
This enables Harpoon-style fast indexing where slot 1 always points to the origin of the crash.

### 2.5 In-Buffer Extmarks & Telemetry (`lua/unwind/decorator.lua`)
Projects inline diagnostics directly above fault lines without mutating buffer text:
- Creates a dedicated namespace (`unwind_diagnostics`).
- Clears prior decorations on the target buffer before rendering.
- Employs `vim.api.nvim_buf_set_extmark` with `virt_lines_above = true` and `virt_lines_overflow = "scroll"`:
  ```
    ✕ [CALL STACK FAULT] Frame #1: ProcessPayment()   (DiagnosticError)
      ↳ src/services/checkout.lua:104                 (DiagnosticVirtualTextInfo)
  ```
- Gracefully handles variable line length boundaries and fallbacks.

### 2.6 Floating Menu UI (`lua/unwind/ui.lua`)
Provides a fast, modal selection interface inspired by Harpoon:
- Creates an unlisted scratch buffer (`nofile`, `wipe`, `bufhidden`).
- Dynamically formats entries with aligned frame counts:
  `1. src/services/checkout.lua                (2 frames)`
- Spawns a rounded, centered floating window (`nvim_open_win`) centered against `vim.o.columns` and `vim.o.lines`.
- Keybindings inside float:
  - `<CR>`: Jump to selected file at primary fault line.
  - `1` through `9`: Instantly select slot 1 to 9 and close menu.
  - `q` / `<Esc>`: Dismiss and wipe window.
  - `j` / `k`: Navigate rows.

---

## 3. Configuration & Keybindings

All default leader keymaps follow single-key mappings:

| Action | Command | Default Keymap | Floating Menu Keymap |
|---|---|---|---|
| Toggle Menu | `:UnwindMenu` | `<leader>w` | - |
| Ingest Clipboard | `:UnwindClipboard` | `<leader>c` | - |
| Next Frame | `:UnwindNext` | `]u` | - |
| Previous Frame | `:UnwindPrev` | `[u` | - |
| Next File | `:UnwindNextFile` | `]f` | - |
| Previous File | `:UnwindPrevFile` | `[f` | - |
| Toggle Filter | `:UnwindToggleFilter` | - | - |
| Clear Telemetry | `:UnwindClear` | - | - |
| Select Slot 1–9 | - | - | `1` – `9` |
| Confirm Selection | - | - | `<CR>` |
| Close Menu | - | - | `q` or `<Esc>` |

---

## 4. Performance & Reliability

1. **Sub-millisecond Execution**: Ingesting and parsing a 100+ line stack trace occurs instantaneously in-memory via Lua pattern matching, eliminating process spawn overhead.
2. **Buffer Safety**: Uses `pcall` when reading files and setting cursor coordinates, ensuring that missing files or truncated lines do not raise unhandled Lua errors.
3. **Clean Teardown**: Auto-commands clean up scratch buffers upon window wipeout (`BufWipeout`), avoiding buffer leaks.
