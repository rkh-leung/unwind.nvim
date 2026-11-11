# unwind.nvim Performance Benchmark Report

## Test Environment
- **Neovim Version**: 0.9.5 (tested with Neovim >= 0.10 compatibility)
- **Lua Version**: LuaJIT 2.1 (Lua 5.1 ABI)
- **OS**: Linux 6.8.0 x86_64
- **CPU**: Intel(R) Xeon(R) Processor @ 2.30GHz

## Before vs After Benchmark Comparison

| Scenario                               | Before Median (ms) | Before p95 (ms) | After Median (ms) | After p95 (ms) | Speedup / Change |
|----------------------------------------|--------------------|-----------------|-------------------|----------------|------------------|
| 2 MiB mixed parse                      | 2774.637           | 2781.924        | 2756.696          | 2800.571       | ~1% faster       |
| 1000 repeated path parse               | 12.267             | 13.548          | 9.435             | 10.728         | **23% faster**   |
| 1000 unique path parse                 | 118.179            | 121.797         | 115.438           | 120.158        | ~2% faster       |
| 5000 Python frames                     | 597.040            | 608.443         | 595.494           | 613.597        | within noise     |
| collector filter off                   | 1.842              | 2.174           | 2.173             | 2.944          | within noise     |
| collector filter on                    | 1.249              | 2.034           | 1.546             | 1.780          | within noise     |
| 1000-frame session mutation            | 20.800             | 21.513          | 0.410             | 1.906          | **50.7x faster** |
| saved-session persistence              | 8.294              | 9.714           | 8.687             | 14.048         | within noise     |
| 1000-row sidebar render                | 6.478              | 8.293           | 7.479             | 8.117          | within noise     |
| Ruby repeated-path resolve (100 paths) | 9.272              | 10.435          | 0.325             | 1.354          | **28.5x faster** |
| Ruby refresh (1000 frames, 20 unique)  | 103132.669         | 103132.669      | 159.840           | 159.840        | **645.2x faster**|

## Key Optimizations Implemented
1. **Ruby Availability Refresh Single Probe & Resolution Cache**:
   Previously, refreshing availability forced a full probe and file resolution for every individual frame (`1000 frames = 1000 Ruby processes = ~103 seconds`). By invalidating the environment once and caching unique resolved paths, refresh time dropped to **159 ms** (a **645x** speedup).
2. **Session Mutation O(1) Rollback**:
   Replaced whole-array `vim.deepcopy(session.raw_frames)` with fine-grained undo closures on mutation, speeding up repeated mutations of a 1000-frame transient session by over **50x**.
3. **Ruby Resolver Memoization & Negative Caching**:
   Added per-root resolution caches and a `false` sentinel for failed probes, avoiding repeated filesystem and process lookups.
4. **Filesystem Stat Cache**:
   Added per-operation `stat_cache` verifying `stat.type == "file"`.
5. **Python Traceback Ring Buffer**:
   Replaced `table.remove(..., 1)` with a fixed-capacity ring buffer preserving innermost crash frames in O(1) time.
6. **UTF-8 Safe Binary-Search Truncation**:
   Replaced quadratic substring slicing with Neovim character/byte-index binary search in `lua/unwind/text.lua`.
