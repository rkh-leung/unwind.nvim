# Unwind.nvim — Repository-Wide Performance Engineering Report

## Executive Summary

This engineering pass conducted a comprehensive, systematic performance optimization across the `unwind.nvim` repository.

All performance improvements were achieved while strictly preserving the observable behavior of Unwind:
- Exact stacktrace format recognition and language coverage (Raygun/.NET, Java inner classes/lambdas/coroutines, Rust/Cargo compiler styles, Node.js/V8, Python tracebacks, Ruby stacktraces, and generic fallbacks).
- Strict Python context handling and crash-first innermost-frame ordering.
- Multi-tiered path resolution precedence (Workspace -> Path Mappings -> Language Resolvers).
- Session semantics, transactional mutation rollbacks, persistence corruption safety, and exact Markdown export byte reporting.

## 1. System & Benchmark Environment

- **Base Commit SHA:** `21ea8d105e39a7e4b4ff7f6745de6fe09af4b604`
- **Environment:** Ubuntu Linux x86_64
- **Neovim Version:** NVIM v0.10.4 (Release, LuaJIT 2.1.1713484068)
- **Suite Verification:** 22/22 test suites passing (zero failures) via `./scripts/test.sh`

## 2. Before & After Benchmark Comparison

Measurements were taken using the identical benchmark runner (`./scripts/benchmark.sh`) under isolated headless Neovim execution on the same machine:

| Workload | Baseline (Commit `21ea8d1`) | Optimized | Percentage Change |
|---|---:|---:|---:|
| **2 MiB mixed-log parse** | 3269.725 ms | **73.744 ms** | **-97.74% (44.3x speedup)** |
| **5,000 Python frames** | 324.478 ms | **156.113 ms** | **-51.89% (2.1x speedup)** |
| **1,000 unique path parse** | 171.781 ms | **129.438 ms** | **-24.65% (1.33x speedup)** |
| **1,000 repeated path parse** | 11.965 ms | **10.056 ms** | **-15.95%** |
| **Collector (filter disabled)** | 2.022 ms | **1.771 ms** | **-12.41%** |
| **Collector (filter enabled)** | 1.306 ms | **1.084 ms** | **-17.00%** |
| **1,000-frame session mutation** | 0.348 ms | **0.285 ms** | **-18.10%** |
| **Saved-session persistence** | 14.164 ms | **12.009 ms** | **-15.21%** |
| **1,000-row sidebar render** | 6.965 ms | **5.551 ms** | **-20.30%** |
| **Ruby repeated-path resolve** | 1.329 ms | **1.009 ms** | **-24.08%** |
| **Ruby refresh** | 120.456 ms | **111.022 ms** | **-7.83%** |
| **Markdown export (200 frames)** | *(new)* | **2.954 ms** | *Baseline established* |
| **E2E frame reorder action (200 frames)** | *(new)* | **0.698 ms** | *Baseline established* |

## 3. Optimizations Implemented by Subsystem

### 3.1 Stacktrace Ingestion & Parsing (`lua/unwind/parser.lua`)
- **Root Cause of Baseline Bottleneck:** In a 20,000-line diagnostic log, Matchers 1–8 were invoked sequentially on every irrelevant line. In particular, Matcher 7 (Ruby) attempted expensive character-class regexes (`([^:]+%.%w+):(%d+):in...`), and Matcher 8 (Generic) executed a sequence of multi-character patterns.
- **Optimization:**
  1. Implemented cheap candidate-line rejection `is_candidate_line`: lines lacking stacktrace tokens (`at `, `File "`, `-->`, `:in`, `from `, `%.rb:%d+`, or `%.%a%w*:%d+`) immediately bypass Matchers 1..8 without evaluating regexes.
  2. Preserved Python traceback state machine: Python header detection (`Traceback`) and indented source lines are processed before rejection.
  3. Guarded Matcher 7 with fast substring probes (`:in%s+[`']`, `from `, `%.rb:%d+`).
  4. Added fast upfront check for `:%d+` in Matcher 8 to reject non-frame lines before regex matching.
- **Verification:** `tests/parser_spec.lua` and `tests/ingestion_spec.lua` passed. 2 MiB mixed parse dropped from ~3270 ms to ~74 ms.

### 3.2 Path Normalization & Filesystem Resolution (`lua/unwind/parser.lua`)
- **Optimization:**
  1. In `resolve_and_normalize_path`, guarded language resolver calls with fast signature check (`raw_path:find("%.rb")`, `/gems/`, `/bundler/gems/`). Non-Ruby paths skip language resolver probing entirely.
  2. Streamlined directory segment loop to avoid repeated `canonicalize_lexical` calls during progressive suffix matching.
- **Verification:** `tests/path_spec.lua` and `tests/regression_fixes_spec.lua` passed. 1,000 unique paths parse dropped from 172 ms to 129 ms.

### 3.3 Ruby Resolver & Cache Efficiency (`lua/unwind/resolvers/ruby/init.lua`)
- **Optimization:**
  1. In `resolvers/ruby/init.lua`, eliminated negative-cache pollution (`cache[frame_path] = false`) for paths lacking any Ruby library pattern (`parse_gem_path`, `parse_bundler_git_path`, `parse_stdlib_path`).
  2. Negative entries are now retained solely for genuine Ruby resolution attempts.
- **Verification:** `tests/ruby_resolver_spec.lua`, `tests/ruby/git_gems_spec.lua`, and `tests/ruby/stdlib_spec.lua` passed.

### 3.4 Session State & Actions (`lua/unwind/session_actions.lua`)
- **Optimization:**
  1. In `ensure_frames_resolved`, updated loop to resolve only frames where `not f.resolved_path`, avoiding re-resolving existing frames across routine session actions.
  2. Maintained transactional rollback safety on disk write failures.
- **Verification:** `tests/correctness_spec.lua`, `tests/isolation_spec.lua`, and `tests/session_spec.lua` passed.

### 3.5 Markdown Export & Source Extraction (`lua/unwind/export.lua`, `lua/unwind/source_extract.lua`)
- **Audit & Invariant Verification:**
  1. Verified per-export extraction reuse via `create_context()`, ensuring AST parsers and source buffers are reused across repeated frames referring to the same file or method.
  2. Confirmed that temporary scratch buffers are cleaned up via `ctx:dispose()` without resource leaks.
  3. Verified deterministic byte calculation and document equality invariant assertions.
- **Verification:** `tests/export_spec.lua` and `tests/source_extract_spec.lua` passed. Added new benchmark workload for 200-frame Markdown export (median 2.95 ms).

### 3.6 Sidebar, Navigation & Extmark Efficiency (`lua/unwind/sidebar.lua`, `lua/unwind/navigation.lua`, `lua/unwind/decorator.lua`)
- **Audit & Profiling:**
  1. Verified targeted active-row updates via `sidebar.set_active` (~0.04 ms per selection update).
  2. Confirmed `jump_to_frame` utilizes cached canonical resolved paths to validate file availability via a single `fs_stat`.
  3. Confirmed window focus preservation and cursor clamping.
- **Verification:** `tests/sidebar_spec.lua`, `tests/decoration_sync_spec.lua`, and `tests/annotation_spec.lua` passed.

## 4. Correctness Evidence Summary

1. **Parser & Format Golden Coverage:** Tested across Raygun C#, Java inner classes/lambdas/coroutines, Rust/Cargo compiler styles, Node.js V8 traces, Python crash-first reversal and bounded ring buffer, Ruby stacktraces, and generic token fallback with prefix stripping.
2. **Resolver Precedence:** Workspace resolution -> Path mappings -> Ruby resolvers verified intact.
3. **Session Invariants & Rollback Safety:** Transactional rollbacks verified across failed disk writes during save, rename, delete, and annotation.
4. **Memory & Buffer Lifecycle:** Measured heap growth across repeated ingestion/clear cycles (<0.5 KB growth, zero orphan buffers).
5. **CI & Test Suite:** Full suite execution (`./scripts/test.sh`) reports **22/22 passed, 0 failed**.

## 5. Summary of Files Modified

- `lua/unwind/parser.lua`: Candidate-line pre-filtering, Matcher 7/8 guarding, Ruby resolver call filtering.
- `lua/unwind/resolvers/ruby/init.lua`: Negative-cache protection against unrelated paths.
- `lua/unwind/session_actions.lua`: Selective frame resolution in `ensure_frames_resolved`.
- `bench/benchmark.lua`: Added Markdown export and E2E frame action benchmarks.
- `doc/performance-report.md`: Comprehensive engineering report.
