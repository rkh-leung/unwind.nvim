-- bench/benchmark.lua
-- Microbenchmarks for unwind.nvim measuring wall-clock performance
-- Generates synthetic traces in memory to avoid committing multi-megabyte fixtures.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local uv = vim.uv or vim.loop

local function percentile(sorted, p)
  if #sorted == 0 then
    return 0
  end

  local idx = math.ceil(#sorted * p)
  idx = math.max(1, math.min(idx, #sorted))
  return sorted[idx]
end

local function benchmark(name, iterations, fn, warmup_count)
  warmup_count = warmup_count ~= nil and warmup_count or 5
  for _ = 1, warmup_count do
    fn()
  end

  collectgarbage("collect")

  local samples = {}

  for i = 1, iterations do
    local start = uv.hrtime()
    fn()
    samples[i] = (uv.hrtime() - start) / 1e6
  end

  table.sort(samples)

  local median = percentile(samples, 0.50)
  local p95 = percentile(samples, 0.95)

  print(string.format(
    "%-40s median=%8.3f ms  p95=%8.3f ms",
    name,
    median,
    p95
  ))

  return {
    name = name,
    median_ms = median,
    p95_ms = p95,
  }
end

local parser = require("unwind.parser")
local collector = require("unwind.collector")
local sessions = require("unwind.sessions")
local sidebar = require("unwind.sidebar")
local unwind = require("unwind")

local cwd = vim.fs.normalize(vim.fn.getcwd())

print("=========================================================================")
print(string.format("Unwind Benchmarks | Neovim %s | Lua %s", tostring(vim.version()), _VERSION))
print("=========================================================================")

local results = {}

-- 1. Parser: ~2 MiB mostly non-matching log
do
  local lines = {}
  local approx_bytes = 0
  local target_bytes = 2 * 1024 * 1024
  local dummy_line = "2026-03-30T10:15:30.123456Z [INFO] worker.service: Processing job event payload without stacktrace data...\n"
  local frame_line = "    at Service.processJob (src/worker/service.ts:142:15)\n"

  local counter = 0
  while approx_bytes < target_bytes do
    counter = counter + 1
    if counter % 100 == 0 then
      table.insert(lines, frame_line)
      approx_bytes = approx_bytes + #frame_line
    else
      table.insert(lines, dummy_line)
      approx_bytes = approx_bytes + #dummy_line
    end
  end
  local trace_2mb = table.concat(lines)

  table.insert(results, benchmark("2 MiB mixed parse", 10, function()
    parser.parse(trace_2mb, { root = cwd, max_frames = 1000 })
  end))
end

-- 2. Parser: 1000 frames using one repeated path
do
  local lines = {}
  for i = 1, 1000 do
    table.insert(lines, string.format("    at Handler.execute (src/handler.js:%d:5)", i))
  end
  local trace_1000_repeated = table.concat(lines, "\n")

  table.insert(results, benchmark("1000 repeated path parse", 20, function()
    parser.parse(trace_1000_repeated, { root = cwd, max_frames = 1000 })
  end))
end

-- 3. Parser: 1000 frames using unique paths
do
  local lines = {}
  for i = 1, 1000 do
    table.insert(lines, string.format("    at Handler.execute (src/handlers/file_%d.js:10:5)", i))
  end
  local trace_1000_unique = table.concat(lines, "\n")

  table.insert(results, benchmark("1000 unique path parse", 20, function()
    parser.parse(trace_1000_unique, { root = cwd, max_frames = 1000 })
  end))
end

-- 4. Parser: 5000-frame Python traceback capped to 1000
do
  local lines = { "Traceback (most recent call last):" }
  for i = 1, 5000 do
    table.insert(lines, string.format('  File "app/core/step_%d.py", line %d, in run_step', i, i * 2))
    table.insert(lines, '    result = compute_step()')
  end
  table.insert(lines, 'ZeroDivisionError: division by zero')
  local trace_python_5000 = table.concat(lines, "\n")

  table.insert(results, benchmark("5000 Python frames", 15, function()
    parser.parse(trace_python_5000, { root = cwd, max_frames = 1000 })
  end))
end

-- 5 & 6. Collector: 1000 frames, filtering disabled and enabled
do
  local raw_frames = {}
  for i = 1, 1000 do
    local is_vendor = (i % 2 == 0)
    local path = is_vendor and string.format("vendor/bundle/ruby/3.3.0/gems/lib_%d/foo.rb", i % 50)
                           or string.format("app/models/user_%d.rb", i % 50)
    table.insert(raw_frames, {
      file = path,
      resolved_path = cwd .. "/" .. path,
      line = (i % 100) + 1,
      col = 1,
      method = "method_" .. i,
      raw_line = path .. ":1",
    })
  end

  table.insert(results, benchmark("collector filter off", 20, function()
    collector.collect(raw_frames, {
      root = cwd,
      filter_vendor = false,
      ignore_patterns = { "vendor/bundle/" },
    })
  end))

  table.insert(results, benchmark("collector filter on", 20, function()
    collector.collect(raw_frames, {
      root = cwd,
      filter_vendor = true,
      ignore_patterns = { "vendor/bundle/" },
    })
  end))
end

-- 7. Sessions: repeated mutation of a 1000-frame transient session
do
  local base_frames = {}
  for i = 1, 1000 do
    table.insert(base_frames, {
      file = "src/foo.py",
      line = i,
      col = 1,
      method = "step",
      raw_line = "src/foo.py:" .. i,
    })
  end

  table.insert(results, benchmark("1000-frame session mutation", 20, function()
    local session = sessions.create({ root = cwd, transient = true, frames = base_frames })
    for i = 1, 10 do
      sessions.add_frame(session, { file = "src/bar.py", line = i, col = 1 })
      sessions.remove_frame(session, 1)
    end
  end))
end

-- 8. Sessions: save project containing multiple 1000-frame saved sessions
do
  local saved_sessions = {}
  for s = 1, 3 do
    local s_frames = {}
    for i = 1, 1000 do
      table.insert(s_frames, {
        file = string.format("app/worker_%d.rb", i % 20),
        line = i,
        col = 1,
        method = "work",
        raw_line = "app/worker:1",
      })
    end
    local sess = sessions.create({
      root = cwd,
      name = "Bench Saved " .. s,
      transient = false,
      frames = s_frames,
    })
    table.insert(saved_sessions, sess)
  end

  table.insert(results, benchmark("saved-session persistence", 10, function()
    sessions.save(cwd, saved_sessions)
  end))

  local filepath = sessions.storage_path(cwd)
  pcall(os.remove, filepath)
end

-- 9. Sidebar: render 1000 frames
do
  local frames = {}
  for i = 1, 1000 do
    table.insert(frames, {
      file = string.format("app/services/process_%d.rb", i % 50),
      resolved_path = cwd .. "/app/services/process.rb",
      line = i,
      col = 1,
      method = "call_step_" .. i,
    })
  end
  local session = sessions.create({ root = cwd, frames = frames, transient = true })
  session.frames = frames
  session.files = { { file = "app/services/process.rb", available = true } }
  sidebar.open(session, {})

  table.insert(results, benchmark("1000-row sidebar render", 20, function()
    sidebar.render(session)
  end))

  sidebar.hide()
end

-- 10. Ruby resolver: repeated identical Ruby gem paths
do
  local ok_ruby, ruby_resolver = pcall(require, "unwind.resolvers.ruby")
  if ok_ruby and ruby_resolver and ruby_resolver.resolve then
    local gem_path = "/usr/local/bundle/gems/rack-2.2.8/lib/rack.rb"
    table.insert(results, benchmark("Ruby repeated-path resolve", 50, function()
      for _ = 1, 100 do
        ruby_resolver.resolve(gem_path, { root = cwd })
      end
    end))
  end
end

-- 11. Ruby refresh: session containing many Ruby frames but few unique paths
do
  local raw_frames = {}
  for i = 1, 1000 do
    local path = string.format("/gems/activerecord-7.1.0/lib/active_record/relation_%d.rb", i % 20)
    table.insert(raw_frames, {
      file = path,
      path = path,
      line = i,
      col = 1,
      method = "resolve",
      raw_line = path .. ":1",
    })
  end
  local session = sessions.create({ root = cwd, transient = true, frames = raw_frames })
  unwind.state.active_session = session

  -- In unoptimized main, this performs 1000 Ruby process invocations per run.
  -- 0 warmup and 1 iteration allows baseline to finish without timeout.
  table.insert(results, benchmark("Ruby refresh", 1, function()
    unwind.refresh_availability()
  end, 0))

  unwind.clear()
end

print("=========================================================================")
print("Benchmark run complete.")
print("=========================================================================")

return results
