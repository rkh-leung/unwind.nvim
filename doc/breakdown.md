# Maintainer's Onboarding Guide: File-by-File Breakdown of unwind.nvim

Welcome to the `unwind.nvim` maintainer team!

This guide is designed for engineers who are working on `unwind.nvim`. We cover core Lua/Neovim plugin fundamentals and walk through every single file in the repository step-by-step, explaining architecture, design decisions, and system invariants.

---

## Part 1: Lua & Neovim Primer for Maintainers

1. **Tables are everything (`{}`)**:
   Lua tables represent arrays, dictionaries, and objects. **Lua arrays are 1-indexed** (`list[1]` is the first item).
2. **Local by Default**:
   All variables and functions must be explicitly declared `local` unless deliberately defining a global setting (e.g. `vim.g.loaded_unwind`).
3. **Modules and `require`**:
   Modules return a table (conventionally `local M = {} ... return M`) cached in `package.loaded`.
4. **Lua Pattern Matching**:
   Uses lightweight string pattern characters: `%d` (digit), `%s` (whitespace), `%w` (alphanumeric), `[%w_%-./\\]` (path characters).
5. **`pcall` (Protected Call)**:
   Catches runtime exceptions cleanly without crashing: `local ok, res = pcall(func, args...)`.
6. **Neovim API**:
   - `vim.api.*`: Low-level C APIs (extmarks, buffers, windows).
   - `vim.uv` (or `vim.loop`): Libuv filesystem and event loop functions (`fs_stat`, `hrtime`).
   - `vim.keymap.set()`: Keybinding registration.
   - `vim.json`: Native JSON encoder and decoder (`vim.json.encode`, `vim.json.decode`).

---

## Part 2: Repository Structure Overview

```text
.
├── plugin/
│   └── unwind.lua          # Auto-loaded entrypoint: user commands (:UnwindAdd, etc.) & default keymaps
├── lua/
│   └── unwind/
│       ├── init.lua        # Facade & public API orchestration
│       ├── state.lua       # Centralized runtime state container and multi-root session caching
│       ├── ingest.lua      # Ingestion entry points from text, clipboard, files, ranges, and selections
│       ├── navigation.lua  # Buffer navigation, cursor jumping, frame cycling, quickfix export
│       ├── session_actions.lua # Session modifications, frame mutations, filter reapplication, refresh
│       ├── sessions.lua    # Session domain model and transactional mutation API
│       ├── persistence.lua # Atomic state serialization and disk persistence with structural validation
│       ├── events.lua      # Event bus for session lifecycle notifications
│       ├── location.lua    # Tree-sitter AST function declaration resolver and cursor fallback
│       ├── sidebar.lua     # Persistent right vertical split sidebar & interactive call-path editor
│       ├── parser.lua      # Pure Lua stacktrace pattern matcher and path normalizer
│       ├── path.lua        # Filesystem path helpers and stat caching
│       ├── collector.lua   # Aggregator: deduplicates files in trace order & tags vendor paths
│       ├── decorator.lua   # Extmarks: renders virtual line banners (virt_lines) above fault lines
│       ├── text.lua        # UTF-8 display width truncation helpers
│       ├── ui.lua          # Floating UI: session manager float, input scratchpad, single-line prompt
│       └── resolvers/      # Multi-tiered path resolution subsystem
│           ├── init.lua    # Resolver pipeline coordinator (workspace -> mappings -> language)
│           ├── workspace.lua # Local workspace and container prefix resolution
│           └── ruby/       # Ruby language resolver (gems, git gems, stdlib)
│               ├── init.lua        # Public Ruby resolver interface
│               ├── environment.lua # Version discovery & runtime probe cache
│               ├── path.lua        # Path pattern extractor
│               ├── gems.lua        # Exact gem-version matching
│               ├── git_gems.lua    # Bundler git gems matching
│               ├── stdlib.lua      # Standard library resolution
│               └── managers/       # Adapters: rbenv, asdf, mise, chruby, rvm, system
├── scripts/
│   ├── test.sh             # Isolated headless test suite runner
│   └── benchmark.sh        # Isolated microbenchmark runner
└── tests/
    ├── helpers/            # Shared test environment isolation helpers
    ├── fixtures/           # Real-world crash traces and test dummy files
    ├── annotation_spec.lua # Frame annotations and virtual line note rendering
    ├── clipboard_spec.lua  # Clipboard isolation test suite
    ├── collector_spec.lua  # Derived frames collection and vendor tagging
    ├── correctness_spec.lua# Functional correctness and navigation invariants
    ├── decoration_sync_spec.lua # Visual synchronization across reordering and availability
    ├── ingestion_spec.lua  # Ingestion consistency and transient session isolation
    ├── isolation_spec.lua  # State isolation from genuine user storage
    ├── leak_spec.lua       # Memory stability, garbage collection, and window/buffer leak test
    ├── location_spec.lua   # Tree-sitter and cursor location extraction test suite
    ├── parser_spec.lua     # Automated functional, regression, and invariant test suite
    ├── path_spec.lua       # Path resolution and lexical canonicalization
    ├── perf_spec.lua       # Performance invariants
    ├── persistence_validation_spec.lua # Persistence schema validation and corrupt file handling
    ├── regression_fixes_spec.lua # Checklist and regression verification
    ├── ruby_resolver_spec.lua    # Ruby environment detection and gem resolution
    ├── ruby/git_gems_spec.lua    # Bundler git gems resolution
    ├── ruby/stdlib_spec.lua      # Sparse stdlib directory resolution
    ├── session_spec.lua    # Session model, mutation API, and disk persistence test suite
    ├── sidebar_spec.lua    # Sidebar display formatting and truncation
    └── state_spec.lua      # Runtime state and multi-root caching
```

---

## Part 3: File-by-File Detailed Breakdown

### 1. `plugin/unwind.lua`

**Purpose:** Neovim runs this file automatically when the plugin is loaded. It registers user commands and sets up default keybindings.

Key points:
- Prevents redundant execution using `vim.g.loaded_unwind`.
- Registers user commands: `:Unwind`, `:UnwindFile`, `:UnwindInput`, `:UnwindClipboard`, `:UnwindSelection`, `:UnwindMenu`, `:UnwindSidebar`, `:UnwindNext`, `:UnwindPrev`, `:UnwindNextFile`, `:UnwindPrevFile`, `:UnwindToggleFilter`, `:UnwindQuickfix`, `:UnwindClear`, `:UnwindRubyInfo`, `:UnwindAnnotate`.
- Calls `unwind.install_keymaps()` to bind default single-key leader shortcuts (`<leader>w`, `<leader>c`) without overriding custom user keymaps unless explicitly forced.

---

### 2. `lua/unwind/init.lua`

**Purpose:** Central coordinator, runtime state container, and public API.

#### State Structure:
```lua
raw_state = {
  root = nil,               -- Pinned project root at ingestion time
  sessions = {},            -- Loaded saved sessions for project root
  sessions_loaded = false,  -- Lazy-load flag
  active_session = nil,     -- Active session table
}
```
Compatibility metatable `M.state` delegates queries like `unwind.state.frames` to `raw_state.active_session.frames`.

#### Core Responsibilities:
- **`check_file_availability(file_path, root)`**: Evaluates filesystem existence via `vim.uv.fs_stat()`. Disk presence is the sole authority; in-memory loaded buffers are never used to fake availability for deleted files.
- **`jump_to_frame(idx)`**:
  - Validates cached path against disk with a single `fs_stat` for high performance during rapid stepping (`]u` / `[u`).
  - If a file is missing, commits `active_index`, highlights the frame in the sidebar as red `N/A`, clears inline decorations, and never creates an empty buffer.
  - Ensures source window focus via `ui.ensure_source_window()` and `sidebar.ensure_source_window()`.
  - Sets cursor and renders inline `virt_lines` telemetry via `decorator.render()`.
- **`delete_frame_from_session(session, frame_idx)`**:
  - Removes the frame from `session.raw_frames`.
  - Persists change to disk if saved; if disk persistence fails, rolls back the raw frame array.
  - Preserves current active frame if a non-active frame was deleted.
  - If the active frame was deleted, routes through `jump_to_frame()` to select the nearest surviving frame and synchronize source buffer cursor, decorator, and sidebar.

---

### 3. `lua/unwind/sessions.lua`

**Purpose:** Disk persistence layer managing saved debugging sessions.

- **Storage Location**: Scoped to project root: `stdpath("state")/unwind/<sha256(root)>.json`.
- **Stable Debugging Facts Only**: Serializes only `name`, `filter_enabled`, and `raw_frames` (`file`, `line`, `col`, `method`, `raw_line`, and optional single-line `note`). Excludes runtime handles (bufnr, winid, extmarks, active indices).
- **Atomic File Writes**: Serializes JSON to a temporary file (`.tmp.<hrtime>`), verifies `write()` and `flush()` success, then renames over the target file via `os.rename()`.
- **Transactional Rollback**: `save_working()`, `rename()`, and `delete()` revert in-memory mutations if `sessions.save()` returns `false`.

---

### 4. `lua/unwind/sidebar.lua`

**Purpose:** Persistent right-hand vertical split call-trace sidebar.

- **Reusable Split Window**: Uses one persistent `unwind://sidebar` buffer across all sessions.
- **Trace Formatting**: Renders indexed call frames with method, filename, and line number. Renders `●` indicator for annotated frames (`UnwindSidebarAnnotated`).
- **Interactive Annotation Keybinding (`a`)**: Prepopulates current annotation in `ui.prompt_input()` to add, edit, or remove notes.
- **Active Missing Frame Highlighting**: Uses `UnwindSidebarActive` combined with `UnwindSidebarMissing` for missing active frames.
- **Reserved Footer**: Always reserves a footer row during initial render so `set_active()` can update `1/N file:line` when loaded sessions activate.
- **Bounded Navigation**: Keymaps `<CR>` and `d` enforce row bounds (`1 <= frame_idx <= #frames`), preventing jumps on footer/blank rows.
- **Window Safety**: If the sidebar is the only normal window left in Neovim, `ensure_source_window()` splits a normal window before navigation.

---

### 5. `lua/unwind/parser.lua`

**Purpose:** Pure Lua pattern matcher parsing stack traces into `{ file, line, col, method, raw_line }`.

- Supports Raygun/.NET, Java inner classes/lambdas, Rust compiler arrows, Node.js/V8, Python tracebacks, Ruby, and generic formats.
- Inverts Python traceback blocks so the innermost crash frame appears first.
- Strips container/virtual path prefixes (`/app/`, `/var/task/`, `C:\workspace\`) and resolves paths relative to project root.

---

### 6. `lua/unwind/collector.lua`

**Purpose:** Deduplicates frames into unique file entries while preserving chronological occurrence order. Tags third-party vendor frames (`vendor/bundle/`, `node_modules/`, `/usr/lib/`, relative paths ascending outside workspace).

---

### 7. `lua/unwind/decorator.lua`

**Purpose:** Draws inline virtual lines (`virt_lines`) above fault lines in source buffers using Neovim's extmarks API (`unwind_diagnostics` namespace). Renders contextual headers (`● [DEBUG PATH] Step X/Y: method()` vs `● [STACK FRAME] Frame X/Y: method()`) and displays single-line annotations (`💬 <note>`) using the `UnwindAnnotation` highlight group.

---

### 8. `lua/unwind/ui.lua`

**Purpose:** Floating UI components:
- `open_session_manager(items, callbacks)`: Interactive session manager floating menu with open, save, rename (`r`), and delete (`d`) actions.
- `open_input(on_submit)`: Scratchpad for pasting stacktraces with `<C-s>` and `:w` support.
- `prompt_input(title, default_val, on_submit)`: Single-line modal for naming and renaming sessions.

---

### 9. `lua/unwind/resolvers/`

**Purpose:** Multi-tiered path resolution pipeline converting remote/container paths to local files.

- `resolvers/init.lua`: Coordinates resolver precedence:
  1. Workspace resolver (`resolvers/workspace.lua`).
  2. Configured user `path_mappings`.
  3. Language resolvers (`resolvers/ruby/`).
- `resolvers/ruby/`:
  - `environment.lua`: Version discovery (`.ruby-version`, `.tool-versions`, `mise.toml`, `.mise.toml`, `Gemfile`) and runtime environment probing. Caches results per project root to prevent spawning ruby processes repeatedly.
  - `managers/`: Filesystem-based adapter discovery for `rbenv`, `asdf`, `mise`, `chruby`, `rvm`, and `system`.
  - `gems.lua`: Exact gem-version resolution against RubyGems installation roots.
  - `git_gems.lua`: Bundler git gem resolution under `bundler/gems/`.
  - `stdlib.lua`: Ruby standard library resolution against `rubylibdir`, `archdir`, `sitelibdir`, `vendorlibdir`.

---

## Part 4: Key Maintainer Invariants

1. **Zero External Binaries**: All parsing and persistence run in pure native Lua.
2. **Disk as Authority**: Missing files must be marked `N/A`; loaded in-memory buffers do not override disk state.
3. **Transactional Persistence**: Memory mutations must roll back if disk writes fail.
4. **Single-Key Leader Mappings**: Follow `<leader>w` and `<leader>c` single-key conventions.
5. **Source Window Isolation**: Navigation must never replace the sidebar buffer or floating windows with source buffers.
