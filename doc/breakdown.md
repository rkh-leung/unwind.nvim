# Maintainer's Onboarding Guide: File-by-File Breakdown of unwind.nvim

Welcome to the `unwind.nvim` maintainer team!

This guide is designed for engineers who are working on `unwind.nvim`. We cover core Lua/Neovim plugin fundamentals and walk through every single file in the repository step-by-step, explaining architecture, design decisions, and system invariants.

---

## Part 1: Lua \& Neovim Primer for Maintainers

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
│       ├── state.lua       # Centralized runtime state container & multi-root caching
│       ├── ingest.lua      # Ingestion entry points (clipboard, text, files, ranges, selections)
│       ├── navigation.lua  # Buffer jumping, cursor positioning, frame cycling, quickfix export
│       ├── session_actions.lua # Frame mutations, filter reapplication, refresh
│       ├── sessions.lua    # Session domain model & transactional mutation API
│       ├── export.lua      # Markdown export generator respecting active session filtering
│       ├── source_extract.lua # Tree-sitter AST method extraction & fallback excerpt reader
│       ├── persistence.lua # Atomic JSON disk persistence layer with structural validation
│       ├── events.lua      # Monotonic event bus for session lifecycle notifications
│       ├── location.lua    # Tree-sitter function resolver & cursor extraction
│       ├── sidebar.lua     # Persistent right vertical split sidebar & interactive editor
│       ├── parser.lua      # Pure Lua stacktrace pattern matcher & path normalizer
│       ├── path.lua        # Filesystem path helpers & stat caching
│       ├── collector/      # Split collector logic (see below)
│       │   ├── collector.lua     # Facade that re‑exports `data`, `ui`, and `persistence`
│       │   ├── data.lua          # Pure data logic: deduplication, vendor filtering, raw‑index assignment
│       │   ├── ui.lua            # UI‑related helpers used by the collector (sidebar updates, etc.)
│       │   └── persistence.lua   # Stub for future persistence hooks (currently unused)
│       ├── decorator.lua   # Extmarks: renders virtual line banners (virt_lines) above fault lines
│       ├── text.lua        # UTF‑8 display width truncation helpers
│       ├── ui.lua          # Floating UI components (session manager float, input scratchpad, prompt)
│       ├── async/          # Async parsing utilities
│       │   ├── parser.lua        # Non‑blocking background parser spawning `parser_worker.lua`
│       │   └── parser_worker.lua # Minimal worker script executed in a headless Neovim process
│       ├── config/         # Configuration handling
│       │   └── validator.lua     # Schema validation for user options (type checks, limits, path_mappings)
│       └── resolvers/      # Multi‑tiered path resolution subsystem
│           ├── init.lua        # Resolver pipeline coordinator (workspace → mappings → language)
│           ├── workspace.lua   # Workspace path normalizer & container prefix stripping
│           ├── common.lua      # Shared helpers for language resolvers (binary discovery, utilities)
│           └── ruby/           # Ruby language resolver (gems, git gems, stdlib)
│               ├── init.lua        # Public Ruby resolver interface
│               ├── environment.lua # Version discovery & runtime probe cache
│               ├── path.lua        # Path pattern extractor
│               ├── gems.lua        # Exact gem‑version matching
│               ├── git_gems.lua    # Bundler git gem resolution
│               ├── stdlib.lua      # Standard library resolution
│               └── managers/       # Adapters for rbenv, asdf, mise, chruby, rvm, system
├── scripts/
│   ├── test.sh               # Isolated headless test suite runner
│   └── benchmark.sh          # Isolated microbenchmark runner
└── tests/
    ├── helpers/               # Shared test environment isolation helpers
    ├── fixtures/              # Real‑world crash traces and test dummy files
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

---

## Part 3: File-by-File Detailed Breakdown

### 1. `plugin/unwind.lua`

**Purpose:** Neovim runs this file automatically when the plugin is loaded. It registers user commands and sets up default keybindings.

Key points:
- Prevents redundant execution using `vim.g.loaded_unwind`.
- Registers a comprehensive set of commands (`:Unwind`, `:UnwindClipboard`, `:UnwindAdd`, etc.).
- Calls `unwind.install_keymaps()` to bind default single‑key leader shortcuts (`<leader>w`, `<leader>c`) without overriding custom user keymaps unless explicitly forced.

---

### 2. `lua/unwind/init.lua`

**Purpose:** Central coordinator, runtime state container, and public API.

#### State Structure:
```lua
raw_state = {
  root = nil,               -- Pinned project root at ingestion time
  sessions = {},            -- Loaded saved sessions for project root
  sessions_loaded = false,  -- Lazy‑load flag
  active_session = nil,     -- Active session table
}
```
Compatibility metatable `M.state` delegates queries like `unwind.state.frames` to `raw_state.active_session.frames`.

#### Core Responsibilities:
- `check_file_availability` → disk‑authority existence check via `vim.uv.fs_stat`.
- `jump_to_frame` → fast navigation with a single `fs_stat` validation, sidebar sync, and virt‑line rendering.
- `delete_frame_from_session` → safe removal with transactional rollback and automatic active‑frame reselection.

---

### 3. `lua/unwind/sessions.lua`

**Purpose:** Disk persistence layer managing saved debugging sessions.

- **Storage Location:** `stdpath("state")/unwind/<sha256(root)>.json`.
- **Stable Debugging Facts Only:** Serializes `name`, `filter_enabled`, and `raw_frames` (no runtime handles).
- **Atomic File Writes** and **Transactional Rollback** ensure consistency on disk write failures.

---

### 4. `lua/unwind/sidebar.lua`

**Purpose:** Persistent right‑hand vertical split call‑trace sidebar.

- Re‑uses a single `unwind://sidebar` buffer.
- Renders indexed frames, annotation indicator `●`, and missing‑file highlighting.
- Provides interactive annotation (`a`), deletion (`d`), and safe navigation safeguards.
- Guarantees a source window exists before any navigation.

---

### 5. `lua/unwind/parser.lua`

**Purpose:** Pure Lua pattern matcher parsing stack traces into `{file, line, col, method, raw_line}`.

- Supports many languages/formats (Raygun, Java, Rust, Node.js, Python, Ruby, generic logs).
- Normalises container prefixes and resolves paths relative to the project root.
- Performs deferred path resolution after frame collection to minimise filesystem calls.

---

### 6. `lua/unwind/collector/`

The collector has been split into three focused modules:

| File | Purpose |
|------|---------|
| `collector.lua` | Facade that re‑exports the three sub‑modules (`data`, `ui`, `persistence`). |
| `data.lua` | Pure data logic: deduplication, vendor/ignore‑pattern filtering, raw‑index assignment, and construction of the `files` table returned to the session manager. |
| `ui.lua` | UI‑related helpers used by the collector (e.g., updating the sidebar when frames are filtered or when the collector runs in “filter‑off” mode). |
| `persistence.lua` | Placeholder for future persistence hooks; currently unused but kept for symmetry and potential extensions. |

---

### 7. `lua/unwind/decorator.lua`

**Purpose:** Draws inline `virt_lines` above fault lines using Neovim's extmarks API (`unwind_diagnostics` namespace). Renders contextual headers (`● [DEBUG PATH]` vs `● [STACK FRAME]`) and single‑line annotations (`💬 <note>`).

---

### 8. `lua/unwind/ui.lua`

**Purpose:** Floating UI components:
- `open_session_manager` – Interactive session manager floating menu.
- `open_input` – Scratchpad for pasting stack traces.
- `prompt_input` – Single‑line modal for naming/renaming sessions.

---

### 9. `lua/unwind/config/validator.lua`

**Purpose:** Validates the user‑provided options passed to `require('unwind').setup(opts)`.
- Checks types for all documented options.
- Enforces sane limits on numeric fields (`max_input_bytes`, `max_frames`).
- Verifies that `path_mappings` keys and values are strings.
- Returns `true`/`false` with an error message for integration into `init.lua`'s startup validation.

---

### 10. `lua/unwind/async/parser.lua`

**Purpose:** Non‑blocking background parser.
- Resolves `parser_worker.lua` via `vim.api.nvim_get_runtime_file` to guarantee correct path regardless of `cwd`.
- Stores the most recent `uv.spawn` handle in `last_handle`.
- **Cancel helper** (`M.cancel()`) aborts any in‑flight job, preventing zombie processes when rapid parses are triggered.
- Falls back to synchronous parsing if spawning fails, ensuring the caller always receives a result.
- Covered by `tests/async_parser_spec.lua`.

---

### 11. `lua/unwind/resolvers/`

**Purpose:** Multi‑tiered path resolution pipeline.

- `init.lua` – Coordinates resolver precedence: workspace → `path_mappings` → language resolvers.
- `workspace.lua` – Handles container‑prefix stripping and relative‑to‑root resolution.
- **`common.lua`** – Shared utilities for all language resolvers (e.g., locating version‑manager binaries, path normalisation helpers). This reduces duplication across the Ruby manager modules.
- `ruby/` – Ruby‑specific resolution (environment discovery, gem matching, git gem handling, stdlib lookup).

---

## Part 4: Key Maintainer Invariants

1. **Zero External Binaries** – All parsing and persistence run in pure native Lua.
2. **Disk as Authority** – Missing files must be marked `N/A`; in‑memory buffers never override disk state.
3. **Transactional Persistence** – Memory mutations must roll back if disk writes fail.
4. **Single‑Key Leader Mappings** – Follow `<leader>w` and `<leader>c` single‑key conventions.
5. **Source Window Isolation** – Navigation must never replace the sidebar buffer or floating windows with source buffers.

---

## Part 5: Async Parser Enhancements (Low‑Effort Patches)

The async parser lives in `lua/unwind/async/parser.lua`. Two small but important changes were added to make it more robust:

1. **Absolute worker script resolution** – The worker (`parser_worker.lua`) is now located via
   ```lua
   local worker_path = vim.api.nvim_get_runtime_file('lua/unwind/parser_worker.lua', false)[1]
   ```
   This guarantees the background process starts correctly even when Neovim's current working directory is not the plugin root.
2. **Cancel helper** – A public `M.cancel()` function aborts any in‑flight parse job:
   ```lua
   function M.cancel()
     if last_handle and not last_handle:is_closing() then
       last_handle:kill('sigterm')
       last_handle = nil
       return true
     end
     return false
   end
   ```
   It is automatically invoked at the start of `M.parse_async` to prevent zombie processes when the user triggers multiple parses in quick succession (e.g., rapidly changing clipboard contents).

Both changes are covered by the new `tests/async_parser_spec.lua` suite and keep the public API unchanged; existing commands (`:UnwindClipboard`, `:UnwindAdd`, etc.) continue to use the async parser transparently.

---

*The maintainer’s onboarding guide (`doc/breakdown.md`) now reflects these async‑parser updates and the collector split, and the old report artifact has been deprecated.*