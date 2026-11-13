# unwind.nvim

A lightweight, high-performance persistent debugging path and session manager written entirely in native Lua (targeting Neovim >= 0.10).

A debugging session in `unwind.nvim` is a **mutable ordered list of source locations**. A stacktrace is only one way to create or bootstrap that list. You can start with a stacktrace, construct a debugging path manually from cursor locations while exploring code, or combine both into hybrid investigation paths.

Debugging sessions are managed through a centralized session manager (`<leader>w`), edited and navigated via a Yazi‑style persistent right vertical split sidebar, and projected as inline call‑path telemetry into source buffers using Neovim's extended marks (`virt_lines`) API.

There are zero external binary dependencies for core Unwind (no external CLI tools, no external JSON parsers, no database, no RPC processes). Stacktrace syntax recognition is performed in‑process using Lua pattern matching. Path resolution may query the local filesystem, and optional language‑specific enrichment may probe a locally installed runtime. Runtime environment discovery is cached per project root.

---

## Target Workflows

`unwind.nvim` supports two equally valid workflows:

### 1. Stacktrace‑first (`<leader>c`)
```
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

### 2. Scratch‑first (`<leader>w` or `:UnwindAdd`)
```
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
- **Tree‑sitter Smart Location Resolution**: When adding frames with `:UnwindAdd`, Tree‑sitter resolves the enclosing function/method definition and its declaration line across languages (Lua, Python, JavaScript, TypeScript, Rust, Go, Ruby, C, C++), with graceful fallback to cursor position.
- **Editable Call‑Path Buffer & `mini.files`‑Style Synchronization**: The sidebar buffer (`unwind://sidebar`) is a dedicated modifiable buffer where every line corresponds 1:1 to a stack frame:
  - `=`: Synchronize staged buffer edits to the session with an action diff summary and confirmation prompt.
  - `<BS>`: Reset and discard unsynchronized buffer edits back to current session state.
  - `<CR>`: Jump to frame in source buffer.
  - `o` / `O`: Insert source window's cursor location after / before the frame under cursor.
  - `a`: Add or edit frame annotation notes (indicated by `●`).
  - `e`: Replace selected frame with current source location (ideal when code moved).
  - `s`: Save session (prompts for name).
  - `r`: Refresh file availability.
  - `E`: Export session to Markdown.
  - `/` or `<leader>f`: Open fuzzy finder (`unwind.search()`).
  - `q`: Close window (prompts to sync if unsynchronized changes exist).
  - Native Vim motions (`dd`, `p`, `yyp`, visual block moves `:m '>+1<CR>gv=gv`, `u`, `<C-r>`) operate natively without custom overrides.
- **Pluggable Fuzzy Finder**: Search call trace frames with `:UnwindSearch` / `:UnwindFind` / `unwind.search()`, with automatic backend detection and seamless fallbacks across `fzf-lua`, `telescope`, `snacks`, `mini.pick`, and built-in `vim.ui.select`. Custom pickers can be registered with `unwind.register_picker()`.
- **Positional Frame Addition**: Add cursor locations at precise stack positions with `:UnwindAdd <index>`, `:UnwindAddBefore`, or `:UnwindAddAfter`.
- **Full Window Editing**: Open `unwind://sidebar` in the current main window with `:UnwindBuffer` for distraction-free navigation.
- **Frame Annotations & Contextual Virtual Lines**: Annotate individual debugging frames with hypotheses and observations via `a` in sidebar or `:UnwindAnnotate`. Single‑line annotations are the current feature; multiline editing is a possible future enhancement, not implemented functionality. Virtual lines display neutral contextual headings (`[DEBUG PATH]` for manual steps and `[STACK FRAME]` for stacktraces) alongside inline note banners (`💬 <note>`). Annotations persist across restarts for saved sessions.
- **Pure Lua In‑Memory Parsing**: Ingests and parses crash stacktraces in‑process via native Lua pattern matching (Raygun/.NET, Java, Rust, Node.js/V8, Python, Ruby, compiler errors, generic logs).
- **Multi‑Tiered Path Resolvers (Ruby Gems, Bundler Git, & Stdlib)**: Automatically enriches deployed container / production traces into navigable local files:
  - Application workspace resolver with container prefix stripping (`/app/`, `/var/task/`).
  - Configurable `path_mappings`.
  - Ruby environment discovery (detects `.ruby-version`, `.tool-versions`, `mise.toml`, `.mise.toml`, `Gemfile`) across version managers (`rbenv`, `asdf`, `mise`, `chruby`, `rvm`, system).
  - Exact gem‑version matching, Bundler git gem resolution, and Ruby standard library resolution.
- **Named Persistent Debugging Sessions**: Transient sessions (`name = nil`) stay in‑memory; named sessions persist immediately across Neovim restarts in `stdpath("state")/unwind/` scoped to your repository root.
- **First‑Class Missing File Handling**: Missing or deleted files remain selectable as red `N/A` positions without creating dummy buffers or crashing.
- **Inline Virtual Line Telemetry**: Extended mark (`virt_lines`) decorations above fault lines with frame depth (`#depth/total`), method name, file, and line information.
- **Vendor / Gem / Library Filtering**: Automatically tags non‑workspace third‑party library frames, allowing toggleable filtering on demand (`:UnwindToggleFilter`).
- **File vs. Frame Cycling**: Instant file‑by‑file navigation (`]f` / `[f`) alongside detailed frame‑by‑frame stepping (`]u` / `[u`).
- **Quickfix Export**: Export all active debugging frames directly to Neovim's quickfix list with `:UnwindQuickfix`.
- **Markdown Investigation Export**: Export active debugging sessions with unrestricted extracted method bodies, investigation paths, annotations, filter status, and accurate byte size reporting to a Markdown scratch buffer (`:UnwindExport` or `E` in sidebar), respecting active frame filtering.

---

## Async Parsing

`unwind.async.parser.parse_async(text, callback)` runs the heavy stack‑trace parsing in a **background Neovim process**, keeping the UI completely responsive while the work is performed.

- The worker script (`parser_worker.lua`) is located using `vim.api.nvim_get_runtime_file`, so the parser works correctly regardless of the current working directory.
- A new `unwind.async.parser.cancel()` helper aborts any in‑flight parse job. This is useful when the user changes the clipboard or input rapidly – the previous job is safely terminated before a new one starts.
- The async API is **backwards compatible**: existing commands (`:UnwindClipboard`, `:UnwindAdd`) continue to use it under the hood, and the behaviour of the plugin is unchanged for end users.

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
```
┌────────────────────────────────────────────────────────┐
│ Unwind                                                 │
│                                                        │
│   + New debugging session                              │
│   + Import stacktrace from clipboard                   │
│                                                        │
│   Current: Untitled             3 frames (2 project)   │
│   Save current session...                              │
│                                                        │
│ ─ Saved Sessions ───────────────────────────────────── │
│   Memory leak                  14 frames (10 project)  │
│   Login race condition          8 frames (8 project)   │
│                                                        │
│ Enter open   r rename   d delete                       │
└────────────────────────────────────────────────────────┘
```

### Call‑Trace Sidebar
```
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
```
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

## Handling Third‑Party & Vendor Stacktraces

Crash traces frequently contain deep stack frames from external packages and installed bundles that are not part of your application repository (e.g., `vendor/bundle/`, `node_modules/`, `/usr/lib/`).

`unwind.nvim` handles this seamlessly:
1. **Filtering**: Toggle hiding external vendor traces on the fly with `:UnwindToggleFilter`. Surviving frame positions are preserved.
2. **Workspace‑Only Ingestion**: Set `filter_out_of_project = true` in your setup configuration to hide vendor and out‑of‑workspace files automatically upon ingestion (defaults to `false`).

---

## Configuration Reference

The following table details every supported option in `require("unwind").setup(opts)`:

| Option | Type | Default | Description |
|---|---|---|---|
| `filter_out_of_project` | `boolean` | `false` | When `true`, automatically filters out vendor and external paths upon ingestion. |
| `path_mappings` | `table<string, string>` | `{}` | Key‑value table mapping remote/container directory prefixes to local paths (e.g. `{ ["/app/"] = "./" }`). Evaluated longest prefix first. |
| `max_input_bytes` | `number` | `2097152` (2 MiB) | Maximum size in bytes of stacktrace text ingested from file or buffer before truncating. |
| `max_frames` | `number` | `1000` | Maximum number of stack frames retained in memory. For Python tracebacks, the innermost (last N) crash frames are preserved. |
| `ignore_patterns` | `string[]` | `{"shared/bundle/", "vendor/bundle/", "/gems/", "node_modules/", "^/usr/"}` | Lua patterns used to classify frames as external vendor or third‑party code. |
| `export` | `table` | `{ fallback_context_lines = 10 }` | Configuration options for `:UnwindExport`. |
| `keymaps` | `table|false` | See table below | Keymap table for default normal mode bindings, or `false` to disable automatic keybinding registration. |
| `force_keymaps` | `boolean` | `false` | When `true`, overrides existing non‑Unwind keymaps during setup. By default, Unwind respects user mappings and only overrides mappings it owns. |
| `add_position` | `"after_active" \| "before_active" \| "end"` | `"after_active"` | Default insertion position for `:UnwindAdd`. |
| `confirm_sync` | `boolean` | `true` | When `true`, prompts with action summary before applying buffer edits on `=`. |
| `picker` | `"auto" \| "fzf-lua" \| "telescope" \| "snacks" \| "mini.pick" \| "select" \| function` | `"auto"` | Fuzzy finder provider backend. |

### Default Keybindings

All leader keymaps follow single‑key mappings:

| Action | Command | Default Keymap | Description |
|---|---|---|---|
| Session Manager | `:UnwindMenu` | `<leader>w` | Open persistent session manager |
| Ingest Clipboard | `:UnwindClipboard` | `<leader>c` | Ingest stacktrace from system clipboard into new session |
| Add Current Location | `:UnwindAdd [idx]` | — | Add cursor location to active session (optional positional index) |
| Add Before Active | `:UnwindAddBefore` | — | Add cursor location immediately before active frame |
| Add After Active | `:UnwindAddAfter` | — | Add cursor location immediately after active frame |
| Toggle Sidebar | `:UnwindSidebar` | — | Toggle right vertical split call-trace sidebar |
| Open Unwind Buffer | `:UnwindBuffer` | — | Open `unwind://sidebar` in current window |
| Fuzzy Search | `:UnwindSearch` / `:UnwindFind` | — | Fuzzy search frames with configured picker |
| Next Frame | `:UnwindNext` | `]u` | Jump to next frame |
| Prev Frame | `:UnwindPrev` | `[u` | Jump to previous frame |
| Next File | `:UnwindNextFile` | `]f` | Jump to next file in the session |
| Prev File | `:UnwindPrevFile` | `[f` | Jump to previous file |
| Toggle Vendor Filter | `:UnwindToggleFilter` | `\` | Hide/show external vendor frames |
| Quickfix Export | `:UnwindQuickfix` | — | Export all frames to the quickfix list |
| Markdown Export | `:UnwindExport` | — | Export session to a markdown scratch buffer |
| Annotate Frame | `:UnwindAnnotate` | `a` (sidebar) | Add or edit a single‑line note for the selected frame |
| Sync Buffer Edits | — | `=` (sidebar) | Apply staged buffer edits to session |
| Discard Buffer Edits| — | `<BS>` (sidebar) | Discard buffer edits back to session state |
| Save Session | `:UnwindSave` | `s` (sidebar) | Persist the current session to disk |
| Refresh Availability | `:UnwindRefresh` | `r` (sidebar) | Re‑check file existence on disk |

---

*For a deeper dive into the internal architecture, see the maintainer’s onboarding guide in `doc/breakdown.md`.*