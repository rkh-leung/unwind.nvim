# unwind.nvim

A lightweight, high-performance persistent debugging path and session manager written entirely in native Lua (targeting Neovim >= 0.10).

A debugging session in `unwind.nvim` is a **mutable ordered list of source locations**. A stacktrace is only one way to create or bootstrap that list. You can start with a stacktrace, construct a debugging path manually from cursor locations while exploring code, or combine both into hybrid investigation paths.

Debugging sessions are managed through a centralized session manager (`<leader>w`), edited and navigated via a Yazi-style persistent right vertical split sidebar, and projected as inline call-path telemetry into source buffers using Neovim's extended marks (`virt_lines`) API.

There are zero external binary dependencies for core Unwind (no external CLI tools, no external JSON parsers, no database, no RPC processes). Stacktrace syntax recognition is performed in-process using Lua pattern matching. Path resolution may query the local filesystem, and optional language-specific enrichment may probe a locally installed runtime. Runtime environment discovery is cached per project root.

---

## Target Workflows

`unwind.nvim` supports two equally valid workflows:

### 1. Stacktrace-first (`<leader>c`)
```text
clipboard contains stacktrace
        │
        ▼
     <leader>c
        │
        ▼
create new unnamed transient session
        │
        ▼
parse clipboard → frames
        │
        ▼
activate session
        ├── jump to first useful frame
        └── open/update sidebar
```
Pressing `<leader>c` (or running `:UnwindClipboard`) always creates a **new unnamed transient session**, never mutating whichever session happened to be active.

### 2. Scratch-first (`<leader>w` or `:UnwindAdd`)
```text
     <leader>w
         │
         ▼
    Unwind menu
         │
         ├── New debugging session
         ├── Import clipboard
         ├── Save current session...
         └── Existing sessions...
                  │
                  ▼
          empty unnamed session
                  │
                  ▼
            sidebar opens
                  │
                  ▼
         navigate source code
                  │
                  ▼
    :UnwindAdd current location
```
You can start a session from scratch without having a stacktrace at all. Run `:UnwindAdd` in any file to add the current source location to your active session. If no session exists, `:UnwindAdd` automatically creates an unnamed session and opens the sidebar.

---

## Features

- **Debugging Session as Primary Abstraction**: Sessions are mutable ordered lists of source locations (`UnwindSession`). A session can start empty, grow manually, or be bootstrapped from stacktraces.
- **Tree-sitter Smart Location Resolution**: When adding frames with `:UnwindAdd`, Tree-sitter resolves the enclosing function/method definition and its declaration line across languages (Lua, Python, JavaScript, TypeScript, Rust, Go, Ruby, C, C++), with graceful fallback to cursor position.
- **Editable Call-Path Sidebar**: The persistent right vertical split sidebar acts as an interactive call-path editor:
  - `<CR>`: Jump to frame in source buffer.
  - `J` / `K`: Move selected frame down/up in the call order.
  - `a`: Add or edit frame annotation notes (indicated by `●`).
  - `e`: Replace selected frame with current source location (ideal when code moved).
  - `d`: Delete frame from session (persists immediately if saved).
  - `s`: Save session (prompts for name).
  - `r`: Refresh file availability.
  - `q`: Hide sidebar.
- **Frame Annotations & Contextual Virtual Lines**: Annotate individual debugging frames with hypotheses and observations via `a` in sidebar or `:UnwindAnnotate`. Virtual lines display neutral contextual headings (`[DEBUG PATH]` for manual steps and `[STACK FRAME]` for stacktraces) alongside inline note banners (`💬 <note>`). Annotations persist across restarts for saved sessions.
- **Pure Lua In-Memory Parsing**: Ingests and parses crash stacktraces in-process via native Lua pattern matching (Raygun/.NET, Java, Rust, Node.js/V8, Python, Ruby, compiler errors, generic logs).
- **Multi-Tiered Path Resolvers (Ruby Gems, Bundler Git, & Stdlib)**: Automatically enriches deployed container / production traces into navigable local files:
  - Application workspace resolver with container prefix stripping (`/app/`, `/var/task/`).
  - Configurable `path_mappings`.
  - Ruby environment discovery (detects `.ruby-version`, `.tool-versions`, `mise.toml`, `.mise.toml`, `Gemfile`) across version managers (`rbenv`, `asdf`, `mise`, `chruby`, `rvm`, system).
  - Exact gem-version matching, Bundler git gem resolution, and Ruby standard library resolution.
- **Named Persistent Debugging Sessions**: Transient sessions (`name = nil`) stay in-memory; named sessions persist immediately across Neovim restarts in `stdpath("state")/unwind/` scoped to your repository root.
- **First-Class Missing File Handling**: Missing or deleted files remain selectable as red `N/A` positions without creating dummy buffers or crashing.
- **Inline Virtual Line Telemetry**: Extended mark (`virt_lines`) decorations above fault lines with frame depth (`#depth/total`), method name, file, and line information.
- **Vendor / Gem / Library Filtering**: Automatically tags non-workspace third-party library frames, allowing toggleable filtering on demand (`:UnwindToggleFilter`).
- **File vs. Frame Cycling**: Instant file-by-file navigation (`]f` / `[f`) alongside detailed frame-by-frame stepping (`]u` / `[u`).
- **Quickfix Export**: Export all active debugging frames directly to Neovim's quickfix list with `:UnwindQuickfix`.

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
3. Either:
   - Copy a stacktrace and press `<leader>c` to start debugging it immediately.
   - Or press `<leader>w` and choose `+ New debugging session`, then navigate code and run `:UnwindAdd`.

---

## Session Manager & Right Sidebar Workflow

### Unwind Menu (`<leader>w` / `:UnwindMenu`)
```text
┌──────────────────────────────────────────────┐
│ Unwind                                       │
│                                              │
│   + New debugging session                    │
│   + Import stacktrace from clipboard         │
│                                              │
│   Current: Untitled                 3 frames │
│   Save current session...                    │
│                                              │
│ ─ Saved Sessions ─────────────────────────── │
│   Memory leak                      14 frames │
│   Login race condition              8 frames │
│                                              │
│ Enter open   r rename   d delete             │
└──────────────────────────────────────────────┘
```

### Call-Trace Sidebar
```text
┌────────────────────────────┐
│ Untitled                   │
│                            │
│   1 authenticate           │
│ > 2 load_user              │
│   3 update_account         │
│   4 save                   │
│                            │
│ 2/4 src/user.lua:81        │
│                            │
│ enter open   d delete      │
│ J/K move     e replace     │
│ a note       s save        │
│ q close                    │
└────────────────────────────┘
```

When no locations have been added yet, the sidebar displays an empty state:
```text
┌────────────────────────────┐
│ Untitled                   │
│                            │
│   No locations yet         │
│                            │
│   Add a source location    │
│   (:UnwindAdd)             │
└────────────────────────────┘
```

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
| Ingest Clipboard | `:UnwindClipboard` | `<leader>c` | Ingest stacktrace from system clipboard into new session |
| Add Location | `:UnwindAdd` | - | Add current source location to active debugging session |
| Annotate Frame | `:UnwindAnnotate` | - | Annotate active frame with a note |
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
| `:UnwindAdd` | Adds the current cursor/function location to the active debugging session (creates session if none exists) |
| `:UnwindAnnotate` | Prompts for a single-line annotation note for the active debugging frame |
| `:UnwindClipboard` | Ingests stacktrace from clipboard `+` register into a new transient session |
| `:Unwind [path]` | Ingests stacktrace from file `[path]` or opens interactive paste modal |
| `:UnwindFile <path>` | Ingests stacktrace from specified file |
| `:UnwindInput` | Opens interactive floating scratchpad to paste/type a stacktrace |
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
| `:UnwindRubyInfo` | Displays diagnostic information about the detected Ruby environment, managers, and gem roots |

---

## Running Tests and Benchmarks

Run the headless test suite:

```bash
nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/parser_spec.lua" -c "qa!"
nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/leak_spec.lua" -c "qa!"
nvim --headless -u NONE -c "set rtp+=." -c "luafile tests/perf_spec.lua" -c "qa!"
```

Run benchmarks:

```bash
nvim --headless -u NONE -c "set rtp+=." -c "luafile bench/benchmark.lua" -c "qa!"
```
