# Maintainer's Onboarding Guide: File-by-File Breakdown of unwind.nvim

Welcome to the `unwind.nvim` maintainer team!

This guide is designed for engineers who are new to **Lua** and **Neovim plugin internals**. We will first cover the key Lua and Neovim concepts you need to read the codebase comfortably, and then walk through every single file in the repository step-by-step, explaining line-by-line what it does, why it exists, and how the pieces connect together.

---

## Part 1: Lua & Neovim Primer for Maintainers

If you are coming from Python, JavaScript/TypeScript, Go, or Rust, here are the essential Lua concepts you need to know:

1. **Tables are everything (`{}`)**:
   Lua has only one data structuring mechanism: the `table`.
   - As an array/list: `local list = { "a", "b", "c" }` (Note: **Lua arrays are 1-indexed**, meaning `list[1]` is `"a"`, not `list[0]`).
   - As a dictionary/hash map: `local dict = { key = "value", count = 5 }` or `dict["key"]`.
   - Length operator `#`: `#list` returns the number of elements in an array.

2. **Scope (`local` vs global)**:
   Any variable without `local` becomes a global variable. In Neovim plugins, **everything** should be declared `local` unless deliberately setting a global setting like `vim.g.loaded_unwind`.

3. **Modules and `require`**:
   Files return a table (conventionally named `M`):
   ```lua
   local M = {}
   function M.hello() return "world" end
   return M
   ```
   Other files import it using `local mymod = require("unwind.mymod")`. Neovim caches required modules in `package.loaded`.

4. **String Pattern Matching vs. Regex**:
   Lua does **not** use PCRE or standard regex. It has its own lightweight pattern engine:
   - `%d`: any digit (equivalent to `\d` in regex).
   - `%s`: any whitespace character (equivalent to `\s`).
   - `%w`: any alphanumeric character (equivalent to `\w`).
   - `%a`: any letter.
   - `[%w_%-./\\]`: a character class matching alphanumerics, underscores, dashes, dots, slashes, or backslashes.
   - `string:match(pattern)` returns captured groups in parentheses `()`.
   - `string:gsub(pattern, replacement)` performs search and replace.
   - `string:gmatch(pattern)` returns an iterator to loop over all matches.

5. **`pcall` (Protected Call)**:
   Lua does not have `try / catch`. Instead, errors are caught using `pcall(func, args...)`.
   It returns `ok, result_or_error`. If `ok` is `true`, no exception was thrown; if `false`, the second return value contains the error message.

6. **The `vim.*` API in Neovim**:
   - `vim.api.*`: C-level Neovim APIs (e.g. creating buffers, setting extmarks, configuring windows).
   - `vim.fn.*`: Legacy Vimscript functions exposed to Lua (e.g. `vim.fn.getreg("+")` for clipboard, `vim.fn.getcwd()` for working directory).
   - `vim.keymap.set(mode, lhs, rhs, opts)`: Binds shortcut keys.
   - `vim.notify(message, level)`: Displays popups/status messages to the user.
   - `vim.uv` (or `vim.loop`): Neovim's built-in libuv bindings for async I/O and file system stat operations (`vim.uv.fs_stat`).

---

## Part 2: Repository Structure Overview

```
.
├── plugin/
│   └── unwind.lua          # Auto-loaded entrypoint: registers user commands & default keymaps
├── lua/
│   └── unwind/
│       ├── init.lua        # Orchestrator & state store: jumps between frames, handles keymaps
│       ├── parser.lua      # Regex/pattern matching engine: extracts file, line, col, method
│       ├── collector.lua   # Deduplicator: collapses frames into unique files in chronological order
│       ├── decorator.lua   # Buffer renderer: draws virtual text lines (virt_lines) above fault lines
│       └── ui.lua          # Floating window: Harpoon-style scratchpad menu with slot jumping
└── tests/
    ├── fixtures/           # Real-world crash logs: Raygun, Rust compiler panics, Node.js, Ruby
    └── parser_spec.lua     # Automated test suite executable via headless Neovim
```

---

## Part 3: File-by-File Detailed Breakdown

### 1. `plugin/unwind.lua`

**Purpose:** Neovim automatically executes any `.lua` file placed inside the `plugin/` directory upon startup (or when loaded via `packadd unwind.nvim`). This is where user commands are registered.

#### Code Breakdown:
```lua
if vim.g.loaded_unwind == 1 then
  return
end
vim.g.loaded_unwind = 1
```
- **Guard clause:** `vim.g` represents global variables in Neovim. If the user re-sources their config, this prevents commands from being registered more than once.

```lua
local unwind = require("unwind")
```
- Imports the core controller module from `lua/unwind/init.lua`.

```lua
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
```
- Creates user-facing commands callable in Neovim command mode (`:Unwind`, `:UnwindFile`, `:UnwindInput`, `:UnwindClipboard`, `:UnwindSelection`).
- Notice `{ range = true }` on `UnwindSelection`: this allows the command to accept a visual line range (e.g. running `:'<,'>UnwindSelection`).
- `{ nargs = "?", complete = "file" }` allows filename auto-completion when supplying log files directly.

```lua
vim.api.nvim_create_user_command("UnwindMenu", ...)
vim.api.nvim_create_user_command("UnwindNext", ...)
vim.api.nvim_create_user_command("UnwindPrev", ...)
vim.api.nvim_create_user_command("UnwindNextFile", ...)
vim.api.nvim_create_user_command("UnwindPrevFile", ...)
vim.api.nvim_create_user_command("UnwindToggleFilter", ...)
vim.api.nvim_create_user_command("UnwindClear", ...)
```
- Exposes commands to toggle the menu, cycle forward/backward through call stack frames, navigate directly between unique files, toggle third-party vendor filtering, and clear active diagnostics.

```lua
unwind.setup()
```
- Calls `setup()` on `lua/unwind/init.lua` using default settings so keymaps are ready out of the box without requiring manual setup code.

---

### 2. `lua/unwind/init.lua`

**Purpose:** This is the brain and public API of the plugin. It maintains the in-memory state of active stack traces and manages jumping to frames, updating cursor positions, and wiring up user keymaps.

#### State Structure:
```lua
M.state = {
  frames = {},        -- Array of all parsed frames in trace order
  files = {},         -- Array of unique files produced by collector.lua
  active_index = 0,   -- The currently viewed frame (1-based index)
}
```

#### Configuration & Keybindings:
```lua
M.config = {
  keymaps = {
    menu = "<leader>w",
    clipboard = "<leader>c",
    next = "]u",
    prev = "[u",
  },
}
```
- `M.setup(opts)`: Uses `vim.tbl_deep_extend("force", M.config, opts or {})` to merge user preferences into `M.config`.
- Sets normal mode keymaps (`"n"`) via `vim.keymap.set`. Note that all leader keymaps are single-letter following `<leader>` (e.g., `<leader>w`, `<leader>c`).

#### Ingestion:
- `M.ingest_clipboard()`: Calls `vim.fn.getreg("+")` to fetch whatever is in the operating system clipboard, then forwards it to `M.ingest(text)`.
- `M.ingest_selection()`: Queries visual marks `vim.fn.getpos("'<")` and `vim.fn.getpos("'>")`, slices the exact selected characters using `nvim_buf_get_lines` and `string.sub`, joins them with newlines, and calls `M.ingest(text)`.
- `M.ingest(text)`:
  1. Calls `parser.parse(text)`.
  2. Passes the parsed frames to `collector.collect(frames)`.
  3. Updates `M.state.frames` and `M.state.files`.
  4. Automatically calls `M.jump_to_frame(1)` so the user is immediately taken to the primary crash location.

#### Frame Navigation (`jump_to_frame`, `next`, `prev`):
```lua
function M.jump_to_frame(idx)
```
- Clamps `idx` between `1` and `#M.state.frames`.
- Calls `vim.cmd.edit(vim.fn.fnameescape(frame.file))` wrapped in `pcall` to open or switch to the target file buffer safely.
- Clamps the target line number against `vim.api.nvim_buf_line_count(bufnr)` so Neovim will never throw an out-of-bounds error if a file was modified.
- Moves the cursor via `vim.api.nvim_win_set_cursor(0, { target_line, target_col })`.
- Calls `decorator.render(bufnr, target_line, idx, frame.method, frame.file)` to draw virtual lines.

---

### 3. `lua/unwind/parser.lua`

**Purpose:** Pure Lua text parser. It scans stacktrace text line-by-line and extracts `{ file, line, col, method, raw_line }`.

#### Path Normalization (`normalize_path`):
Stacktraces from production often contain container paths or absolute paths from CI servers like:
- `/app/src/services/payment.rb`
- `/var/task/handler.py`
- `C:\workspace\project\main.rs`

If those paths don't exist directly on the developer's laptop, `normalize_path`:
1. Normalizes all backslashes `\` to forward slashes `/`.
2. Checks if the file is readable directly via `file_exists()`.
3. If not, strips common virtual prefixes (`/app/`, `/var/task/`, `/usr/src/...`, Windows drive letters).
4. Iteratively strips leading directory path components and checks if the relative path exists in `vim.fn.getcwd()`.
5. Returns the matched relative path (or the sanitized path if no local match is found).

#### Language Pattern Matchers:
The parser contains an array of matcher functions executed in order:
1. **Raygun / C#**: `^%s*at%s+(.-)%s+in%s+(.-):line%s+(%d+)`
2. **Java / .NET**: `^%s*at%s+([%w_%.%<%>&]+)%(([%w_%-./\\]+%.%w+):(%d+)%)`
3. **Rust Compiler Arrow**: `^%s*%-%-%>%s+([%w_%-./\\]+%.%w+):(%d+):?(%d*)`
4. **Node.js with method**: `^%s*at%s+(.-)%s*%(%s*([%w_%-./\\]+%.%w+):(%d+):?(%d*)%s*%)`
5. **Node.js / Rust without method**: `^%s*at%s+([%w_%-./\\]+%.%w+):(%d+):?(%d*)`
6. **Python**: `File%s+"([^"]+)",%s*line%s+(%d+),%s*in%s+([%w_]+)`
7. **Ruby**: `([%w_%-./\\]+%.%w+):(%d+):in%s+['`](.-)['`]` (handles backticks and quotes)
8. **Generic fallback**: `([%w_%-./\\]+%.%w+):(%d+):?(%d*)` (ignores `http://` or `ftp://` URLs).

---

### 4. `lua/unwind/collector.lua`

**Purpose:** Takes the raw flat list of frames and aggregates them by file.

#### Why is this necessary?
A deep stacktrace might have 30 frames, but only 3 distinct source files in the project repository. Navigating 30 frames one by one is exhausting. The collector deduplicates the files while:
- Retaining **chronological occurrence order**: The first file where the crash happened stays at index 1.
- Recording `primary_line`: The first fault line encountered for that file.
- Counting `total_frames`: How many times that file appears across the trace.

```lua
local entry = {
  file = fpath,
  primary_line = frame.line,
  primary_col = frame.col or 1,
  primary_method = frame.method or "",
  total_frames = 1,
  frames = { frame },
}
```

---

### 5. `lua/unwind/decorator.lua`

**Purpose:** Projects telemetry into the buffer without touching the file's text on disk.

#### How Extmarks & `virt_lines` Work in Neovim:
Neovim features an **extended marks** (extmarks) subsystem in namespaces (`nvim_create_namespace("unwind_diagnostics")`).
Extmarks can attach virtual text lines (`virt_lines`) that appear between normal code lines:
```lua
local virt_lines = {
  {
    { "  ✕ [CALL STACK FAULT] Frame #" .. tostring(depth) .. ": " .. method_str, "DiagnosticError" },
  },
  {
    { "    ↳ " .. tostring(file) .. ":" .. tostring(line), "DiagnosticVirtualTextInfo" },
  },
}
```
- `virt_lines_above = true`: Injects the banner immediately **above** the fault line.
- `strict = false`: Prevents crashing if the line number is slightly off.
- `M.clear(bufnr)`: Cleans up any prior extmarks before rendering new ones so marks never pile up.

---

### 6. `lua/unwind/ui.lua`

**Purpose:** Renders the floating popup window for file selection (inspired by ThePrimeagen's Harpoon).

#### How the Floating Window is Built:
1. **Creates a scratch buffer**:
   ```lua
   local buf = vim.api.nvim_create_buf(false, true)
   vim.bo[buf].buftype = "nofile"
   vim.bo[buf].bufhidden = "wipe"
   ```
   `nofile` ensures Neovim knows this buffer should never be saved to disk. `wipe` automatically discards buffer memory when closed.
2. **Formats lines**:
   Calculates column padding so that frame counts line up nicely:
   `1. src/services/checkout.lua                (2 frames)`
3. **Centers the window**:
   Reads `vim.o.columns` (editor width) and `vim.o.lines` (editor height) and computes `row = (lines - height) / 2` and `col = (columns - width) / 2`.
4. **Keymap bindings inside the float**:
   Buffer-local keymaps (`buffer = buf`):
   - `<CR>`: Inspects cursor row via `nvim_win_get_cursor(win)` and triggers selection.
   - `1` through `9`: Instantly invokes slot `1` to `9` and dismisses the popup window immediately.
   - `q` / `<Esc>`: Closes the float.

---

### 7. `tests/parser_spec.lua` & Fixtures

**Purpose:** Automated integration testing for parser regexes and collection logic.

- Can be run in headless Neovim:
  ```bash
  nvim --headless -u NONE -c "luafile tests/parser_spec.lua" -c "qa!"
  ```
- Reads trace files from `tests/fixtures/` (`raygun_sample.txt`, `rust_panic.txt`, `node_trace.txt`, `ruby_trace.txt`).
- Asserts that correct file paths, line numbers, column numbers, and function names are parsed across all supported languages.

---

## Part 4: Key Maintainer Tips & Invariants

When adding features or reviewing pull requests, keep these golden rules in mind:

1. **Zero External Binaries**: Never introduce dependencies on external CLI tools (e.g. `rg`, `sed`, `node`, `python`). Everything must stay in native LuaJIT.
2. **Single-Key Leader Mappings**: As established in project conventions, all `<leader>` keymaps must be single-key (e.g., `<leader>w`, `<leader>c`).
3. **1-Based Indexing**: Always remember that Lua arrays and Neovim lines are 1-based, while Neovim buffer API coordinates (`nvim_buf_set_extmark`, `nvim_win_set_cursor`) take 0-based lines and columns.
4. **Buffer & File Safety**: Always wrap file loading (`vim.cmd.edit`) in `pcall` and clamp line numbers to `nvim_buf_line_count`. Never let an invalid stacktrace crash a user's Neovim session.
