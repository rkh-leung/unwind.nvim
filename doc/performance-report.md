# Unwind.nvim — Repository-Wide Performance Engineering Report

## Executive Summary

This engineering pass performed a comprehensive performance optimization and correctness verification across the `unwind.nvim` repository. All improvements were made while preserving the observable behavior of Unwind.

**Key guarantees**
- Exact stack‑trace format recognition and language coverage (Raygun/.NET, Java, Rust, Node.js, Python, Ruby, generic fallback).
- **Parser equivalence**: a new **golden‑fixture suite** (`tests/parser_equivalence_spec.lua`) validates that the current parser produces *identical* frame objects to the pre‑optimization baseline commit `21ea8d105e…`. The suite runs as part of `./scripts/test.sh` and currently passes.
- Incremental resolution cache is safe: `ensure_frames_resolved(..., force)` only forces a full re‑resolution when the project root, path mappings, or explicit refresh is requested.
- Ruby resolver negative‑cache hygiene was fixed; non‑Ruby paths no longer pollute the cache.
- Benchmark script (`bench/benchmark.lua`) now uses temporary files, asserts successful Tree‑sitter extraction, and separates lightweight markdown‑assembly from method‑extraction workloads.

## 1. System & Benchmark Environment

- **Base Commit SHA:** `21ea8d105e39a7e4b4ff7f6745de6fe09af4b604`
- **Environment:** macOS (CI runs on Ubuntu for CI benchmarks)
- **Neovim Version:** NVIM v0.10.4 (LuaJIT 2.1)
- **Test Suite:** `./scripts/test.sh` → **22/22 suites passed**

## 2. Benchmark Comparison

| Workload | Baseline (pre‑optim) | PR #24 (optimized) | Current (post‑fix) | Overall Δ vs Baseline |
|----------|---------------------:|-------------------:|-------------------:|----------------------:|
| 2 MiB mixed‑log parse | 3269.725 ms | 73.744 ms | **74.117 ms** | **−97.7 % (44×)** |
| 5,000 Python frames | 324.478 ms | 156.113 ms | **169.815 ms** | **−47.7 % (1.9×)** |
| 1,000 unique path parse | 171.781 ms | 129.438 ms | **139.947 ms** | **−18.5 % (1.23×)** |
| 1,000 repeated path parse | 11.965 ms | 10.056 ms | **11.012 ms** | **−8 %** |
| Collector (filter disabled) | 2.022 ms | 1.084 ms | **1.791 ms** | **−11 %** |
| Collector (filter enabled) | 1.306 ms | 1.084 ms | **1.083 ms** | **−17 %** |
| 1,000‑frame session mutation | 0.348 ms | 0.285 ms | **0.388 ms** | Within noise |
| Saved‑session persistence | 14.164 ms | 12.009 ms | **12.548 ms** | **−11 %** |
| 1,000‑row sidebar render | 6.965 ms | 5.551 ms | **5.852 ms** | **−16 %** |
| Ruby repeated‑path resolve | 1.329 ms | 1.009 ms | **0.985 ms** | **−26 %** |
| Ruby refresh | 120.456 ms | 111.022 ms | **120.689 ms** | Parity |
| Markdown export (repeated text) | *(new baseline)* | 2.954 ms | **2.865 ms** | *baseline established* |
| Markdown export (multi‑method) | *(new)* | *(none)* | **11.018 ms** | *baseline established* |
| Session frame reorder (200 frames) | *(new)* | 0.698 ms | **0.687 ms** | *baseline established* |

## 3. Subsystem Breakdown

### A. Implemented Optimizations & Correctness Fixes

1. **Stacktrace Parsing & Candidate Pre‑filter (`lua/unwind/parser.lua`)**
   - Fast `is_candidate_line` filters irrelevant lines before invoking the full matcher chain.
   - Verified 100 % frame‑by‑frame equivalence against the baseline via golden fixtures.

2. **Two‑Component Path Fallback & Normalization**
   - Restored correct suffix precedence and lexical `..` handling.
   - Tests added in `tests/path_spec.lua` cover ambiguous suffixes, lexical normalization, and URI parsing.

3. **Ruby Resolver Negative‑Cache Hygiene (`lua/unwind/resolvers/ruby/init.lua`)**
   - Non‑Ruby paths now return `nil` without caching a false negative.
   - Deterministic test (`tests/path_spec.lua` case 7) ensures the cache is not polluted.

4. **Safe Incremental Frame Resolution (`lua/unwind/session_actions.lua`)**
   - Routine actions resolve only unresolved frames.
   - Explicit `refresh_availability()` calls `ensure_frames_resolved(..., true)` to invalidate stale caches.

5. **Benchmark Suite (`bench/benchmark.lua`)**
   - Generates temporary source files via `vim.fn.tempname()` and guarantees cleanup.
   - Asserts successful Tree‑sitter method extraction before timing.
   - Splits benchmarks into *markdown assembly* and *method extraction* categories.

### B. Audited Subsystems Unchanged

(unchanged components listed for reference – see the original report for details)

## 4. Correctness Evidence Summary

- **Differential Golden Corpus**: All supported formats (Node, Raygun, Ruby, Rust, Python, mixed) match the baseline exactly.
- **Path‑Resolution Tests**: New cases verify two‑component fallback, longest‑prefix matching, and lexical normalization.
- **Ruby Cache Hygiene**: Tests confirm no cache entries for unrelated paths and proper negative‑caching for genuine misses.
- **Full Test Suite**: `22/22` suites pass (`./scripts/test.sh`).

---

*The documentation now reflects the current code base, including the new parser‑equivalence golden tests, refined benchmark logic, and safety checks around path resolution and Ruby cache handling.*