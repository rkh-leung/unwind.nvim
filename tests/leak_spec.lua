-- tests/leak_spec.lua
-- Memory and lifecycle regression test for unwind.nvim

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local ui = require("unwind.ui")
local unwind = require("unwind")

local function count_autocmds()
  return #vim.api.nvim_get_autocmds({
    event = { "BufWriteCmd", "BufWipeout" },
  })
end

local function snapshot()
  collectgarbage("collect")
  return {
    buffers = #vim.api.nvim_list_bufs(),
    autocmds = count_autocmds(),
    heap_kb = collectgarbage("count"),
  }
end

local files = {
  { file = "example.lua", total_frames = 1, is_vendor = false },
}

local before = snapshot()

for _ = 1, 500 do
  ui.open(files, function() end)
  ui.close()

  ui.open_input(function() end)
  ui.close_input()
end

local after = snapshot()

assert(after.buffers == before.buffers,
  string.format("UI buffers retained after cleanup: before %d, after %d", before.buffers, after.buffers))

assert(after.autocmds == before.autocmds,
  string.format("Autocommands retained after cleanup: before %d, after %d", before.autocmds, after.autocmds))

print("UI open/close lifecycle test passed. Buffer delta: " .. (after.buffers - before.buffers))

-- Test repeated ingestion and clear
local before_ingest = snapshot()
local sample_trace = [[
  File "app/main.py", line 10, in do_foo
    call_bar()
  File "app/utils.py", line 25, in call_bar
    crash()
]]

for _ = 1, 100 do
  unwind.ingest(sample_trace)
  unwind.clear()
end

local after_ingest = snapshot()
assert(after_ingest.buffers == before_ingest.buffers,
  string.format("Ingest buffers retained after clear: before %d, after %d", before_ingest.buffers, after_ingest.buffers))

print("Repeated ingestion/clear lifecycle test passed.")
