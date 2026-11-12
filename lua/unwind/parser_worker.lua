-- lua/unwind/parser_worker.lua
-- Standalone worker script executed in a separate Neovim / Lua process for async parsing.
-- Receives raw stacktrace via stdin, parses it, and writes JSON to stdout.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local parser = require("unwind.parser")

local input = io.read("*a") or ""
local frames = parser.parse(input)
local encoded = vim.json.encode(frames)
io.write(encoded)
io.flush()
