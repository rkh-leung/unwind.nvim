# Changelog

All notable changes to `unwind.nvim` are documented in this file.

## [1.3.0] - 2026-11-12

### Added
- **Hook & Extension API (`unwind.hooks`)**:
  - `register_resolver` / `unregister_resolver`: Register custom language and path resolvers with collision guards and shape validation.
  - `register_ui_component` / `unregister_ui_component`: Register custom UI components.
  - `register_exporter` / `unregister_exporter`: Register custom session exporters.
  - `on_event` / `off_event`: Subscribe/unsubscribe with lifecycle event whitelist validation.
  - `hooks.list()` and `hooks.clear_all()` for inspection and test isolation.
- **Async Parsing (`unwind.async.parser`)**:
  - Spawns background worker process (`lua/unwind/parser_worker.lua`) via `unwind.parse_async(text, cb)`.
  - Ingests large stacktraces without blocking the Neovim editor UI thread.
  - Automatic cancellation of previous in-flight jobs and explicit `unwind.cancel_parse_async(handle)` API.
  - Added microbenchmark measuring async parsing round-trip latency (~16.8 ms).
- **Config Validator (`unwind.config.validator`)**:
  - Strict type and schema validation via `vim.validate` during `setup(opts)`.
  - Deep validation of `path_mappings` key/value types, positive `max_input_bytes`, and upper-bound limits on `max_frames` (≤ 20,000).
  - Sanitized error diagnostics without noisy stack traces.
- **Vim Help Documentation**:
  - Added `:help unwind-config` and `doc/unwind.txt`.
- **Testing & Quality Assurance**:
  - Shared test fixtures in `tests/helpers/init.lua`.
  - Comprehensive edge-case and malformed trace test suite (`tests/edge_case_parser_spec.lua`).
  - GitHub Actions CI workflow (`.github/workflows/ci.yml`) testing linting, full test suite, and microbenchmarks across macOS and Linux on Neovim v0.10.0 and stable.

### Refactored
- **Modularized Collector**:
  - Split core collector logic into `lua/unwind/collector/data.lua`, `lua/unwind/collector/ui.lua`, and `lua/unwind/collector/persistence.lua` with pure-logic functional boundaries.
- **Extracted Version Manager Common Helpers**:
  - Introduced `lua/unwind/resolvers/common.lua` for shared environment variable lookups and executable binary presence checks across Ruby version manager adapters (`asdf`, `rbenv`, `mise`, `chruby`, `rvm`).
- **Centralized Keymap Management**:
  - Moved keymap installation and state tracking to `lua/unwind/keymaps.lua`.
