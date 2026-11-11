# unwind.nvim Performance Benchmark Baseline

Environment:
- Neovim: 0.9.5 (compatible with >= 0.10)
- Lua: LuaJIT 2.1 (Lua 5.1 compatibility)
- OS: Linux 6.8.0 x86_64
- CPU: Intel(R) Xeon(R) Processor @ 2.30GHz

## Baseline Results (Commit 9f2230c)

| Scenario                               | Iterations | Median (ms)    | p95 (ms)       |
|----------------------------------------|------------|----------------|----------------|
| 2 MiB mixed parse                      | 10         | 2774.637       | 2781.924       |
| 1000 repeated path parse               | 20         | 12.267         | 13.548         |
| 1000 unique path parse                 | 20         | 118.179        | 121.797        |
| 5000 Python frames                     | 15         | 597.040        | 608.443        |
| collector filter off                   | 20         | 1.842          | 2.174          |
| collector filter on                    | 20         | 1.249          | 2.034          |
| 1000-frame session mutation            | 20         | 20.800         | 21.513         |
| saved-session persistence              | 10         | 8.294          | 9.714          |
| 1000-row sidebar render                | 20         | 6.478          | 8.293          |
| Ruby repeated-path resolve (100 paths) | 50         | 9.272          | 10.435         |
| Ruby refresh (1000 frames, 20 unique)  | 1          | 103132.669     | 103132.669     |
