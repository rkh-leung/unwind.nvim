# Technical Report: unwind.nvim Architecture & Operational Walkthrough

## Executive Summary

`unwind.nvim` is a lightweight, standalone Neovim plugin designed for Neovim >= 0.10. It enables developers to ingest crash stacktraces and error logs directly from system clipboards or Neovim visual buffer selections, parses the trace text using pure Lua pattern matching, deduplicates implicated files into a Harpoon-style floating menu, and projects inline virtual lines (`virt_lines`) at fault locations with interactive navigation.

The plugin requires zero external binary dependencies (no external Rust, Go, or Python binaries, and no RPC servers). All parsing and telemetry injection are executed in-process via LuaJIT with minimal overhead.

---

## 1. High-Level Architecture

The plugin is structured into distinct, modular layers following standard Neovim plugin conventions:

```
unwind.nvim/
├── plugin/
│   └── unwind.lua       # Auto-loaded entry point registering Vim commands and keymaps
├── lua/unwind/
│   ├── init.lua         # Plugin lifecycle, state container, navigation controller, public API
│   ├── parser.lua       # Multi-language stacktrace pattern matcher and path normalizer
│   ├── collector.lua    # Frame aggregation, file deduplication, and vendor filtering logic
│   ├── decorator.lua    # Neovim extmarks & virt_lines inline telemetry projection
│   └── ui.lua           # Harpoon-style centered floating scratch window and input scratchpad
└── tests/
    ├── fixtures/        # Sample stack traces (Raygun, Rust, Node.js, Ruby)
    ├── parser_spec.lua  # Headless test runner testing parsing, navigation, and state
    └── leak_spec.lua    # Memory stability and lifecycle verification
```

### End-to-End Execution Flow

```
[Clipboard (+)] or [Visual Selection] or [Log File]
                        │
                        ▼
               unwind.ingest(text)
                        │
                        ▼
               parser.parse(text)
         ├── Pattern Matchers (Raygun, Rust, Node, Python, Ruby, Generic)
         ├── Bounded frame retention (innermost frames for Python)
         └── parser.resolve_and_normalize_path(path)
                        │
                        ▼
             collector.collect(frames)
         ├── Deduplicate unique files (preserving occurrence order)
         ├── Tag vendor / out-of-workspace library frames
         └── Group frames & determine primary fault line
                        │
                        ▼
             unwind.jump_to_frame(1)
         ├── ui.ensure_source_window()
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
  - `:UnwindToggleFilter`: Toggles vendor / out-of-workspace library filtering while preserving active context.
  - `:UnwindQuickfix`: Exports active stacktrace frames to Neovim's quickfix list.
  - `:UnwindClear`: Clears all extmarks, floating windows, and state.
- Calls `unwind.install_keymaps()` with tracked ownership to configure default keybindings without stomping existing user mappings.

### 2.2 Core Controller & State (`lua/unwind/init.lua`)
`init.lua` serves as the central orchestrator and manages state:
```lua
M.state = {
  root = nil,               -- Pinned project root at ingestion time
  raw_frames = {},          -- Ordered list of all parsed frames prior to filtering
  frames = {},              -- Active list of parsed frames
  files = {},               -- Deduplicated list of unique file records
  active_index = 0,         -- Currently inspected frame index (1-based)
  active_file_index = 0,    -- Currently inspected file index (1-based)
  filter_enabled = false,   -- Current vendor filter toggle state
}
```
Key responsibilities:
- **`ingest_clipboard()`**: Reads `vim.fn.getreg("+")` and delegates to `ingest()`.
- **`ingest_selection()`**: Calculates visual bounds via `vim.fn.getpos("'<")` and `getpos("'>")`, slices buffer lines with column precision, and passes joined text to `ingest()`.
- **`jump_to_frame(idx)`**:
  - Validates that target path points to an actual file on disk or loaded buffer prior to editing, avoiding empty buffer creation.
  - Directs editing to non-floating source windows via `ui.ensure_source_window()`.
  - Clamps line number to the buffer line count (`vim.api.nvim_buf_line_count`).
  - Sets the cursor via `nvim_win_set_cursor`.
  - Triggers `decorator.render()` to paint fault telemetry above the active line.
  - Updates `active_index` and `active_file_index` only after navigation succeeds.
- **`next()` / `prev()` / `next_file()` / `prev_file()`**: Loops up to `#frames` or `#files` times to find the next navigable frame rather than trapping on unresolvable frames.
- **`toggle_filter()` & `reapply_filter()`**: Toggles vendor filtering while preserving the active frame and file index if it survives, or falls back to the nearest surviving frame.
- **`quickfix()`**: Exports active frames to Neovim's quickfix list.
- **`clear()`**: Clears extmarks in buffers, closes floating windows, and resets state.

### 2.3 Pure Lua Parsing & Normalization (`lua/unwind/parser.lua`)
The parser processes text line-by-line without invoking shell utilities or external regex engines.

#### Supported Trace Formats & Matchers:
1. **Raygun / .NET / C#**: `at Namespace.Class.Method(...) in /path/to/file.cs:line 123`
2. **Java / .NET Parenthesized**: `at Class.Method(File.java:123)` (supporting inner classes, lambdas, Kotlin coroutines)
3. **Rust / Cargo Compiler**: `--> src/main.rs:45:12`
4. **Node.js / V8**: `at Method (/path/to/file.js:45:12)` or `at /path/to/file.js:45:12`
5. **Python**: `File "/path/to/file.py", line 45, in method_name` (inverted per traceback block so innermost frame comes first, indented source lines ignored)
6. **Ruby**: `from /path/to/file.rb:12:in 'method_name'` or `/path/to/file.rb:12:in \`method_name\``
7. **Generic Fallback**: Matches `([%w_%-./\\]+%.%w+):(%d+):?(%d*)` while rejecting URL schemes (`http:`, `https:`, `ftp:`).

#### Path Normalization (`resolve_and_normalize_path`):
1. Normalizes backslashes (`\`) to forward slashes (`/`).
2. Applies explicit `path_mappings` configured by user (sorted longest prefix first with directory boundary checks).
3. Checks direct file existence using `vim.uv.fs_stat` (or `vim.loop.fs_stat` / `vim.fn.filereadable`).
4. If not found, strips known container prefixes (`^/app/`, `^/var/task/`, `^/usr/src/...`, Windows workspace roots).
5. Progressively checks relative path segments against `opts.root`.
6. Returns display path, immutable resolved path, and navigability flag.

### 2.4 File Aggregator (`lua/unwind/collector.lua`)
Groups parsed frames into unique file entries while strictly maintaining their chronological occurrence order (first fault file appears at index 1):
```lua
{
  file = "src/services/checkout.lua",
  resolved_path = "/workspace/src/services/checkout.lua",
  navigable = true,
  primary_line = 104,
  primary_col = 1,
  primary_method = "ProcessPayment",
  primary_frame_index = 1,
  total_frames = 2,
  frames = { ... },
  is_vendor = false,
}
```
Cross-indexes `frame.file_index` and `file.primary_frame_index` for O(1) lookups during navigation.

### 2.5 In-Buffer Extmarks & Telemetry (`lua/unwind/decorator.lua`)
Projects inline diagnostics directly above fault lines without mutating buffer text:
- Creates a dedicated namespace (`unwind_diagnostics`).
- Clears prior decorations on the target buffer before rendering.
- Employs `vim.api.nvim_buf_set_extmark` with `virt_lines_above = true`:
  ```
    ✕ [CALL STACK FAULT] Frame #1/5: ProcessPayment()   (DiagnosticError)
      ↳ src/services/checkout.lua:104                   (DiagnosticVirtualTextInfo)
  ```
- Gracefully handles line boundaries and missing method names.

### 2.6 Floating Menu & Input UI (`lua/unwind/ui.lua`)
- **Menu Float**: Centered floating scratch window formatted using `vim.api.nvim_strwidth` for precise multibyte Unicode alignment. Provides quick jump (`<CR>`, `1`–`9`), vendor tags (`[vendor]`), and clean wipeout on exit.
- **Input Float**: Scratch buffer for pasting traces (`:UnwindInput` / `:Unwind`). Supports `<C-s>` and `:w` submission with session ID cancellation guards.
- **Safe Focus Restoration**: Verifies that the float was the active window before restoring focus to the originating window.

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
| Quickfix Export | `:UnwindQuickfix` | - | - |
| Clear Telemetry | `:UnwindClear` | - | - |
| Select Slot 1–9 | - | - | `1` – `9` |
| Confirm Selection | - | - | `<CR>` |
| Close Menu | - | - | `q` or `<Esc>` |

---

## 4. Performance & Reliability

1. **In-Process Parsing**: Ingesting and parsing stack traces occurs in-process via Lua pattern matching, eliminating external process spawns.
2. **Buffer Safety**: Validates file existence prior to buffer editing to prevent orphan empty buffers, and clamps cursor coordinates.
3. **Clean Teardown**: Auto-commands clean up scratch buffers upon window wipeout (`BufWipeout`), preventing buffer and autocmd leaks.
