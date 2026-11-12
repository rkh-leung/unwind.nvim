---@module "unwind.async.parser"
--- Non-blocking background parser job spawning parser_worker.lua with cancellation support.
--- Exposes M.parse_async(text, cb) and M.cancel(handle?) to abort pending parses.

local M = {}

local uv = vim.uv or vim.loop

local worker_path = vim.api.nvim_get_runtime_file("lua/unwind/parser_worker.lua", false)[1]
if not worker_path or worker_path == "" then
  -- Fallback to relative resolution if runtime lookup didn't find it
  local candidate = "lua/unwind/parser_worker.lua"
  if uv.fs_stat(candidate) then
    worker_path = vim.fs.normalize(vim.fn.fnamemodify(candidate, ":p"))
  else
    error("Unable to locate parser_worker.lua – async parser cannot start")
  end
end

local last_handle = nil

--- Cancel any in-flight async parse job.
---@param handle? userdata Optional specific job handle to cancel. If omitted, cancels the last in-flight job.
---@return boolean true if a job was killed, false otherwise
function M.cancel(handle)
  local target = handle or last_handle
  if target and not target:is_closing() then
    pcall(function() target:kill("sigterm") end)
    if target == last_handle then
      last_handle = nil
    end
    return true
  end
  return false
end

--- Parse raw stacktrace text asynchronously using background job
---@param text string Raw stacktrace text
---@param cb fun(frames: table[]?, err: string?) Completion callback
---@return userdata? handle Process handle for cancellation
function M.parse_async(text, cb)
  if not text or text == "" then
    vim.schedule(function() cb({}) end)
    return nil
  end

  -- Cancel any previous background parse so we don't accumulate zombies
  if last_handle and not last_handle:is_closing() then
    last_handle:kill("sigterm")
    last_handle = nil
  end

  local rtp_entry = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(worker_path)))

  local stdout_chunks = {}
  local stderr_chunks = {}

  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local stdin = uv.new_pipe(false)

  -- Spawn a persistent-process worker that runs parser_worker.lua located via runtime lookup.
  local handle
  handle = uv.spawn("nvim", {
    args = {
      "--headless",
      "-u", "NONE",
      "-i", "NONE",
      "-c", string.format("set rtp+=%s", rtp_entry),
      "-c", string.format("luafile %s", worker_path),
      "-c", "qa!",
    },
    stdio = { stdin, stdout, stderr },
  }, function(code, signal)
    if stdout then stdout:close() end
    if stderr then stderr:close() end
    if handle and not handle:is_closing() then handle:close() end
    if handle == last_handle then
      last_handle = nil
    end

    if signal == 15 or signal == 9 then
      -- Cancelled explicitly
      return
    end

    local out_str = table.concat(stdout_chunks, "")
    local err_str = table.concat(stderr_chunks, "")

    vim.schedule(function()
      if code ~= 0 then
        -- Fallback to in-process synchronous parse on failure
        local fallback_parser = require("unwind.parser")
        local ok, frames = pcall(fallback_parser.parse, text)
        if ok and frames then
          cb(frames)
        else
          cb(nil, err_str ~= "" and err_str or ("Worker exited with code " .. tostring(code)))
        end
        return
      end

      local ok, frames = pcall(vim.json.decode, out_str)
      if ok and type(frames) == "table" then
        cb(frames)
      else
        local fallback_parser = require("unwind.parser")
        local f_ok, f_frames = pcall(fallback_parser.parse, text)
        if f_ok and f_frames then
          cb(f_frames)
        else
          cb(nil, "Failed to decode parser output: " .. tostring(frames))
        end
      end
    end)
  end)

  if not handle then
    if stdout then stdout:close() end
    if stderr then stderr:close() end
    if stdin then stdin:close() end
    last_handle = nil
    -- Fallback to in-process synchronous parsing
    local fallback_parser = require("unwind.parser")
    local ok, frames = pcall(fallback_parser.parse, text)
    vim.schedule(function()
      if ok then cb(frames) else cb(nil, tostring(frames)) end
    end)
    return nil
  end

  last_handle = handle

  uv.read_start(stdout, function(err, data)
    assert(not err, err)
    if data then
      table.insert(stdout_chunks, data)
    end
  end)

  uv.read_start(stderr, function(err, data)
    assert(not err, err)
    if data then
      table.insert(stderr_chunks, data)
    end
  end)

  stdin:write(text, function()
    stdin:close()
  end)

  return handle
end

return M
