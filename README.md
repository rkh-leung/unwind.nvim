# unwind.nvim

A lightweight, high-performance stacktrace navigation and persistent debugging session plugin written entirely in native Lua (targeting Neovim >= 0.10).

`unwind.nvim` turns plain-text crash stacktraces directly into navigable Neovim source locations and persistent debugging sessions. It handles Raygun traces, compiler errors, Rust panics, Node.js/V8 traces, Python tracebacks, Ruby backtraces, and generic call frames. Traces are parsed entirely in-memory using pure Lua pattern matching, managed via a persistent session manager (`<leader>w`), inspected with a Yazi-style persistent right-hand call-trace sidebar, and projected as inline call-stack telemetry into source buffers using Neovim's extended marks (`virt_lines`) API.

There are zero external binary dependencies (no external CLI tools, no external JSON parsers, no database, no RPC processes). All parsing, session persistence, and buffer navigation run entirely in-process within Neovim.

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
5. `unwind.nvim` automatically jumps to the primary fault location with an inline error overlay. Cycle frames with `]u` / `[u`, cycle distinct files with `]f` / `[f`, or press `<leader>w` to open the session manager.

---

## Features

- **Pure Lua In-Memory Parsing**: Zero external CLI processes or regex libraries. Ingests and parses 100+ line stacktraces in-process via native LuaJIT.
- **Named Persistent Debugging Sessions**: Ingested traces start as transient working sessions that can be named and saved (e.g. "Memory leak", "Login race condition"). Saved sessions persist across Neovim restarts scoped to your project root in `stdpath("state")/unwind/`.
- **Yazi-Style Persistent Call-Trace Sidebar**: A lightweight right vertical split displaying every active call frame in trace order, synchronizing dynamically with `]u` / `[u` and `]f` / `[f`.
- **First-Class Missing File Handling**: Missing or stale source files are treated as valid stacktrace positions marked with a red `N/A`. Selecting a missing frame never crashes, never creates an empty buffer, and clears stale inline decorations. If the file reappears, pressing `r` in the sidebar restores navigability.
- **Non-Destructive Clearing**: `:UnwindClear` deactivates active presentations and discards unsaved traces without deleting your saved debugging sessions.
- **Multi-Language Support**:
  - Raygun / .NET / Java (`at Namespace.Class.Method(...) in /path/to/file.cs:line 123` or `at Class.Method(File.java:123)`)
  - Rust / Cargo / Compiler (`--> src/main.rs:45:12` or `at /path/to/main.rs:45`)
  - Node.js / V8 (`at Method (/path/to/file.js:45:12)` or `at /path/to/file.js:45:12`)
  - Python (`File "/path/to/file.py", line 45, in method_name`)
  - Ruby (`from /path/to/file.rb:12:in 'method_name'` or `/path/to/file.rb:12:in \`method_name\``)
  - Generic fallback (`([%w_%-./\\]+%.%w+):(%d+):?(%d*)`)
- **Intelligent Path Normalization**: Automatically translates remote/container prefixes (e.g. `/app/`, `/var/task/`, `C:\workspace\`) to local files relative to `vim.fn.getcwd()`, and supports explicit `path_mappings`.
- **Inline Virtual Line Telemetry**: Extended mark (`virt_lines`) decorations above fault lines with frame depth (`#depth/total`), method name (omitting noisy `anonymous()` placeholders), file, and line information.
- **Vendor / Gem / Library Filtering**: Automatically tags non-workspace third-party library frames (e.g. `shared/bundle/ruby/...`, `/gems/`, `vendor/bundle/`, `node_modules/`, `/usr/lib/`), allowing toggleable filtering on demand.
- **File vs. Frame Cycling**: Instant file-by-file navigation (`]f` / `[f`) alongside detailed frame-by-frame stepping (`]u` / `[u`).
- **Quickfix Export**: Export all active stacktrace frames directly to Neovim's quickfix list with `:UnwindQuickfix`.

---

## Session Manager & Right Sidebar Workflow

`unwind.nvim` models stacktraces as persistent debugging sessions scoped to each repository.

### 1. Ingest a trace
Ingest any trace using `<leader>c` (clipboard), `:UnwindInput` (interactive scratchpad), or `:Unwind <file>`. The trace immediately becomes an active transient working session.

### 2. Save the session
Open the session manager with `<leader>w` (or `:UnwindMenu`):
```text
+----------------------------------+
| Unwind Sessions                  |
|                                  |
| > + Save current trace...        |
|   Memory leak          14 frames |
|   Login race condition  8 frames |
|                                  |
| Enter open   r rename   d delete |
+----------------------------------+
```
Select `+ Save current trace...` and enter a session name (e.g. `Worker deadlock`). Once saved, the session remains stored on disk until you explicitly delete it.

### 3. Persistent right sidebar
Selecting a session activates it and opens the call-trace sidebar on the right:
```text
+----------------------------------------------+---------------------------+
|                                              | Worker deadlock           |
| source buffer                                |                           |
|                                              |   1 allocate_buffer       |
| function retain_object() {                   |   2 process_request       |
|     ...                                      | > 3 retain_object         |
| }                                            |   4 N/A                   |
|                                              |   5 main                  |
|                                              |                           |
|                                              | 3/5 src/cache.lua:117     |
+----------------------------------------------+---------------------------+
```
Sidebar keymaps:
- `<CR>`: Jump to and open the frame under cursor in the source window.
- `d`: Delete the selected frame from the session (persists immediately if session is saved).
- `r`: Refresh file availability statuses.
- `q`: Hide the sidebar.
- `j` / `k`: Standard navigation.

Navigation while focused inside the sidebar split targets the source window, never replacing the sidebar split buffer.

### 4. Handling missing or stale files
If a source file was deleted or only exists on another git branch:
- The sidebar displays `N/A` with error highlighting.
- Moving onto the frame (`]u` / `[u`) moves the sidebar highlight to that frame, clears previous inline source decorations, and never creates an empty buffer.
- When the file reappears on disk, press `r` in the sidebar to re-check availability and resume source navigation.

---

## Handling Third-Party & Vendor Stacktraces

Crash traces frequently contain deep stack frames from external packages and installed bundles that are not part of your application repository (e.g., `vendor/bundle/`, `node_modules/`, `/usr/lib/`).

`unwind.nvim` handles this seamlessly:
1. **Filtering**: Toggle hiding external vendor traces on the fly with `:UnwindToggleFilter`. Surviving frame positions are preserved.
2. **Workspace-Only Ingestion**: Set `filter_out_of_project = true` in your setup configuration to hide vendor and out-of-workspace files automatically upon ingestion (defaults to `false`).

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
| Session Manager | `:UnwindMenu` | `<leader>w` | Open persistent session manager |
| Ingest Clipboard | `:UnwindClipboard` | `<leader>c` | Ingest stacktrace from system clipboard (`+`) |
| Next Frame | `:UnwindNext` | `]u` | Jump to next stack frame |
| Previous Frame | `:UnwindPrev` | `[u` | Jump to previous stack frame |
| Next File | `:UnwindNextFile` | `]f` | Jump directly to next unique file |
| Previous File | `:UnwindPrevFile` | `[f` | Jump directly to previous unique file |
| Toggle Sidebar | `:UnwindSidebar` | - | Toggle persistent call-trace sidebar |
| Toggle Filter | `:UnwindToggleFilter` | - | Toggle hiding/showing vendor & external frames |
| Quickfix Export | `:UnwindQuickfix` | - | Export stack frames to Neovim's quickfix list |
| Clear Telemetry | `:UnwindClear` | - | Clear active decorations and deactivate session |

---

## Commands

| Command | Description |
|---|---|
| `:Unwind [path]` | Ingests stacktrace from file `[path]` or opens interactive paste modal |
| `:UnwindFile <path>` | Ingests stacktrace from specified file |
| `:UnwindInput` | Opens interactive floating scratchpad to paste/type a stacktrace |
| `:UnwindClipboard` | Ingests stacktrace from clipboard `+` register |
| `:UnwindSelection` | Ingests stacktrace from visually highlighted range |
| `:UnwindMenu` | Opens the persistent debugging session manager |
| `:UnwindSidebar` | Toggles the persistent call-trace right sidebar |
| `:UnwindNext` | Jumps to next stack frame |
| `:UnwindPrev` | Jumps to previous stack frame |
| `:UnwindNextFile` | Jumps directly to next unique file at primary fault line |
| `:UnwindPrevFile` | Jumps directly to previous unique file at primary fault line |
| `:UnwindToggleFilter` | Toggles filtering out vendor / third-party library files |
| `:UnwindQuickfix` | Exports active stacktrace frames to Neovim's quickfix list |
| `:UnwindClear` | Clears active decorations and deactivates active session |

---

## Running Tests

Run the headless test suite:

```bash
nvim --headless -u NONE -c "luafile tests/parser_spec.lua" -c "qa!"
nvim --headless -u NONE -c "luafile tests/leak_spec.lua" -c "qa!"
```
