# Technical Report: unwind.nvim Architecture & Operational Walkthrough

## Executive Summary

`unwind.nvim` is a lightweight, standalone Neovim plugin designed for Neovim >= 0.10. It establishes the **debugging session as a mutable ordered list of source locations** as its primary abstraction. A stacktrace is only one mechanism to initialize or populate that list; developers can also build debugging paths interactively from cursor locations using Tree-sitter resolution (`:UnwindAdd`), reorder steps (`J` / `K`), replace outdated frames (`e`), and save named sessions across Neovim restarts.

Debugging sessions are managed via a persistent session manager (`<leader>w`), inspected with an editable Yazi-style persistent right vertical split sidebar (`sidebar.lua`), and projected as inline virtual line (`virt_lines`) telemetry at fault locations.

The plugin requires zero external binary dependencies for core Unwind (no external Rust, Go, or Python binaries, and no RPC servers). All parsing, session persistence, Tree-sitter AST resolution, and telemetry injection run in-process via LuaJIT with minimal overhead. Optional language source enrichment (e.g. Ruby gems and stdlib resolution) optionally queries the project's local language runtime once to discover exact installed library paths.

---

## 1. High-Level Architecture & Persistence Model

The plugin follows a centralized session-centric architecture:

```text
  clipboard / stacktrace ──► parser ──┐
                                      ▼
             menu (<leader>w) ──► session manager ◄── :UnwindAdd / Tree-sitter
                                      │
                               session changed
                                      │
                         ┌────────────┼────────────┐
                         ▼            ▼            ▼
                      sidebar     navigator    decorator
```

```text
unwind.nvim/
├── plugin/
│   └── unwind.lua       # Auto-loaded entry point registering Vim commands (:UnwindAdd, etc.)
├── lua/unwind/
│   ├── init.lua         # Public API facade and high-level orchestration
│   ├── state.lua        # Multi-root session state tracking and lifecycle
│   ├── ingest.lua       # Ingestion from clipboard, text, files, and ranges
│   ├── navigation.lua   # Buffer jumping, cursor positioning, and frame cycling
│   ├── session_actions.lua # Frame mutations, filter reapplication, refresh
│   ├── sessions.lua     # Session domain model and mutation rollback
│   ├── persistence.lua  # Atomic JSON disk persistence layer with structural validation
│   ├── events.lua       # Monotonic event bus for session state changes
│   ├── location.lua     # Tree-sitter function resolver and cursor extraction
│   ├── sidebar.lua      # Persistent right-hand call-trace sidebar
│   ├── parser.lua       # Stacktrace pattern matcher with ring buffer
│   ├── path.lua         # Canonical path and filesystem stat cache
│   ├── collector.lua    # Frame aggregation, deduplication, and vendor filtering
│   ├── decorator.lua    # Neovim extmarks & virt_lines inline telemetry
│   ├── text.lua         # UTF-8 safe display width truncation
│   ├── ui.lua           # Floating UI modals and prompts
│   └── resolvers/       # Multi-tiered path resolution subsystem
│       ├── init.lua     # Central resolver chain (workspace -> mappings -> language)
│       ├── workspace.lua # Workspace path normalizer and container prefix stripper
│       └── ruby/        # Ruby environment detection, gems, git gems, and stdlib resolver
├── scripts/
│   ├── test.sh          # Headless test runner in isolated environment
│   └── benchmark.sh     # Headless benchmark runner in isolated environment
└── tests/
    ├── helpers/         # Test environment isolation utilities
    ├── fixtures/        # Sample stack traces (Raygun, Rust, Node.js, Ruby, dummy fixtures)
    ├── annotation_spec.lua
    ├── clipboard_spec.lua
    ├── collector_spec.lua
    ├── correctness_spec.lua
    ├── decoration_sync_spec.lua
    ├── ingestion_spec.lua
    ├── isolation_spec.lua
    ├── leak_spec.lua
    ├── location_spec.lua
    ├── parser_spec.lua
    ├── path_spec.lua
    ├── perf_spec.lua
    ├── persistence_validation_spec.lua
    ├── regression_fixes_spec.lua
    ├── ruby_resolver_spec.lua
    ├── ruby/git_gems_spec.lua
    ├── ruby/stdlib_spec.lua
    ├── session_spec.lua
    ├── sidebar_spec.lua
    └── state_spec.lua
```

### End-to-End Execution Flow

```text
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
             sessions.new_working(...)  --> Transmit to active_session
                        │
                        ▼
             unwind.jump_to_frame(1)
         ├── ui.ensure_source_window()
         ├── sidebar.ensure_source_window()
         ├── check_file_availability() [disk authority]
         ├── vim.cmd.edit(file)
         ├── vim.api.nvim_win_set_cursor(...)
         ├── decorator.render(bufnr, line, depth, method, file)
         └── sidebar.set_active(session, 1)
```

---

## 2. Component Deep Dive

### 2.1 Entry Point (`plugin/unwind.lua`)
- Registers user commands:
  - `:Unwind`: Ingests stacktrace from an optional file argument or opens an interactive paste scratchpad.
  - `:UnwindFile`: Ingests stacktrace from a specified file path.
  - `:UnwindInput`: Opens an interactive scratchpad window to paste/type a stacktrace.
  - `:UnwindClipboard`: Ingests trace from the `+` register.
  - `:UnwindSelection`: Ingests visually selected text (`range = true`).
  - `:UnwindMenu`: Opens the persistent session manager (`<leader>w`).
  - `:UnwindSidebar`: Toggles the persistent right-hand call-trace sidebar.
  - `:UnwindNext`: Cycles forward to the next stack frame (`]u`).
  - `:UnwindPrev`: Cycles backward to the previous stack frame (`[u`).
  - `:UnwindNextFile`: Cycles forward directly to the next unique file (`]f`).
  - `:UnwindPrevFile`: Cycles backward directly to the previous unique file (`[f`).
  - `:UnwindToggleFilter`: Toggles vendor / out-of-workspace library filtering while preserving active context.
  - `:UnwindQuickfix`: Exports active stacktrace frames to Neovim's quickfix list.
  - `:UnwindExport`: Exports active debugging session to a Markdown scratch buffer without arbitrary limits, respecting active filter state and accurately reporting exact document byte size and extraction statistics.
  - `:UnwindClear`: Clears all extmarks, hides sidebar, and deactivates active session non-destructively.
  - `:UnwindRubyInfo`: Displays diagnostic information about the detected Ruby environment, managers, and gem roots.
  - `:UnwindAnnotate`: Prompts user to annotate the active debugging frame with a note.
- Installs default keymaps with tracked ownership in `_installed_keymaps`.

### 2.2 Core Controller & State (`lua/unwind/init.lua`)
`init.lua` orchestrates session management and navigation:
```lua
raw_state = {
  root = nil,               -- Pinned project root at ingestion time
  sessions = {},            -- Loaded saved sessions for project root
  sessions_loaded = false,  -- Lazy-load flag
  active_session = nil,     -- Currently active session table
}
```
Key invariants & responsibilities:
- **Disk as Sole Authority**: `check_file_availability()` checks filesystem presence directly (`fs_stat`). In-memory loaded buffers never mask deleted files, ensuring deleted files correctly display as red `N/A`.
- **Fast Navigation Path**: During `jump_to_frame()`, cached `file_entry.canonical_resolved` is validated with a single `fs_stat` call instead of repeating multi-step path resolution heuristics.
- **Re-Resolution on Saved Session Activation**: Persisted sessions deliberately do not store runtime `resolved_path` or availability. When a saved session is activated, `ensure_frames_resolved` re-runs normalization on the original frame paths against the current project root and path mappings, guaranteeing reliable navigation across Neovim restarts.
- **Synchronized Deletion**: When deleting a frame via `delete_frame_from_session()`, if the deleted frame was active, the nearest surviving frame is selected via `jump_to_frame()`, keeping the source buffer, cursor, extmark decorator, and sidebar strictly in sync. Non-active frame deletions preserve the active frame's identity.
- **Window Isolation**: `ui.ensure_source_window()` and `sidebar.ensure_source_window()` guarantee navigation operates strictly in a normal source window, never in a floating window or the sidebar split.
- **Sidebar Callback Isolation**: Sidebar buffer-local keymaps query the active session dynamically rather than closing over a captured session instance, preventing mutations from targeting stale sessions.

### 2.3 Persistent Sessions Store (`lua/unwind/sessions.lua`)
- **Storage Scope**: Sessions are persisted per project root in `stdpath("state")/unwind/<sha256(root)>.json`.
- **Stable Debugging Facts Only**: Only serializes `name`, `filter_enabled`, and `raw_frames` (`file`, `line`, `col`, `method`, `raw_line`, and optional single-line `note`). Transient state (buffer IDs, window IDs, extmarks, availability, active indices) is never persisted.
- **Transactional Persistence**: `save_working()`, `rename()`, `delete()`, and frame deletion perform in-memory rollback if disk write fails.
- **Atomic File Writes**: Serializes payload to `<filepath>.tmp.<hrtime>`, verifies return values of both `write()` and `flush()`, and renames atomically over the target state file.

### 2.4 Call-Trace Sidebar (`lua/unwind/sidebar.lua`)
- **Persistent Pane**: Renders active call frames in trace order inside a reusable right vertical split (`unwind://sidebar`).
- **Missing File Highlighting**: Missing frames are highlighted red (`UnwindSidebarMissing`), including active missing frames.
- **Always-Reserved Footer**: Reserves a footer row on initial render so subsequent session activations reliably update `1/N file:line`.
- **Safe Row Actions**: Keymaps `<CR>` and `d` enforce upper-bound validation against `#session.frames`, preventing jumps on blank or footer rows.
- **Fallback Split**: If the user closes all other windows leaving only the sidebar, `ensure_source_window()` opens a normal split window before navigating.

### 2.5 Pure Lua Parsing & Normalization (`lua/unwind/parser.lua`)
Processes text line-by-line across Raygun/.NET, Java, Rust, Node.js/V8, Python, Ruby, and generic formats. Python tracebacks invert frames per traceback block so innermost crash frames appear first. Container path prefixes (`/app/`, `/var/task/`, `C:\workspace\`) are normalized to local workspace paths.
- **Deferred Path Resolution**: Syntactic parsing collects raw candidates first, bounded by `max_frames` and ring buffer pruning, before resolving paths against the filesystem only for the retained frames.
- **Generic Matcher Space Handling**: Prioritizes delimiter-anchored candidates so log lines such as `[ERROR] /Users/Jane Doe/project/main.go:50:10` capture the complete path without premature whitespace truncation.
- **Safe Quickfix Export**: Exports resolved canonical paths with `valid = 0` and `[N/A]` labeling for missing frames.

### 2.6 Extmarks & Floating Menu (`lua/unwind/decorator.lua` & `lua/unwind/ui.lua`)
- Injects non-invasive `virt_lines` telemetry above fault lines using `unwind_diagnostics` namespace.
- Contextual headers: renders `● [DEBUG PATH] Step X/Y: method()` for manual frames (`UnwindDecorManual`) and `● [STACK FRAME] Frame X/Y: method()` for imported traces (`UnwindDecorStack`).
- Frame annotations: when a frame has a note, renders an additional virtual line `💬 <note>` with `UnwindAnnotation` highlight group.
- Session manager modal (`ui.open_session_manager`) handles saving, selecting, renaming, and deleting saved sessions.
- Input scratchpad (`ui.open_input`) enables direct pasting of trace text with `<C-s>` / `:w` submission.

### 2.7 Multi-Tiered Path Resolvers (`lua/unwind/resolvers/`)
- **Resolver Pipeline (`resolvers/init.lua`)**:
  1. Workspace resolver: verifies filesystem paths and relative paths inside project root, with container prefix stripping (`/app/`, `/var/task/`).
  2. Configured `path_mappings`: user overrides applied longest prefix first.
  3. Language resolvers: detects runtime environments and locates external packages and standard libraries.
- **Ruby Resolver (`resolvers/ruby/`)**:
  - `environment.lua`: Version discovery across `.ruby-version`, `.tool-versions`, `mise.toml`, `.mise.toml`, and `Gemfile`.
  - `managers/`: Non-shell filesystem inspection for `rbenv`, `asdf`, `mise`, `chruby`, `rvm`, and system Ruby.
  - Probes discovered binary once via JSON for `gem_paths`, `gem_dir`, `rubylibdir`, caching results per project root.
  - `gems.lua`: Exact gem-version matching without fuzzy version fallback.
  - `git_gems.lua`: Bundler git gem resolution under `bundler/gems/`.
  - `stdlib.lua`: Standard library resolution against Ruby runtime library directories.

---

## 3. Configuration & Keybindings

All default leader keymaps follow single-key bindings:

| Action | Command | Default Keymap | Description |
|---|---|---|---|
| Session Manager | `:UnwindMenu` | `<leader>w` | Open persistent session manager |
| Ingest Clipboard | `:UnwindClipboard` | `<leader>c` | Ingest stacktrace from clipboard (`+`) |
| Next Frame | `:UnwindNext` | `]u` | Jump to next stack frame |
| Previous Frame | `:UnwindPrev` | `[u` | Jump to previous stack frame |
| Next File | `:UnwindNextFile` | `]f` | Jump directly to next unique file |
| Previous File | `:UnwindPrevFile` | `[f` | Jump directly to previous unique file |
| Toggle Sidebar | `:UnwindSidebar` | - | Toggle persistent call-trace sidebar |
| Toggle Filter | `:UnwindToggleFilter` | - | Toggle hiding/showing vendor & external frames |
| Quickfix Export | `:UnwindQuickfix` | - | Export stack frames to Neovim's quickfix list |
| Markdown Export | `:UnwindExport` | `E` (sidebar) | Export active debugging session to Markdown buffer |
| Clear Telemetry | `:UnwindClear` | - | Clear active decorations and deactivate session |
