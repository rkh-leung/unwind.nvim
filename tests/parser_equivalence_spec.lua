-- tests/parser_equivalence_spec.lua
-- Verify that the current parser output matches the baseline "golden" fixtures.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local parser = require("unwind.parser")
local uv = vim.uv or vim.loop

local fixtures_dir = "tests/fixtures"
local golden_dir = fixtures_dir .. "/parser_golden"
local golden_root = "/__unwind_golden_root__"

local function read_file(path)
  local fd = uv.fs_open(path, "r", 438) -- 0666
  if not fd then error("cannot open " .. path) end
  local stat = uv.fs_fstat(fd)
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

local function load_golden(path)
  local raw = read_file(path)
  -- golden files contain the inspected Lua table representation.
  local fn, err = loadstring("return " .. raw)
  if not fn then error("failed to load golden " .. path .. ": " .. err) end
  return fn()
end

local function list_files(dir)
  local files = {}
  local fd = uv.fs_scandir(dir)
  if not fd then return files end
  while true do
    local name = uv.fs_scandir_next(fd)
    if not name then break end
    table.insert(files, name)
  end
  return files
end

local fixtures = list_files(fixtures_dir)
for _, name in ipairs(fixtures) do
  if not name:match("%.golden$") and name ~= "parser_golden" then
    local fixture_path = fixtures_dir .. "/" .. name
    local golden_path = golden_dir .. "/" .. name .. ".golden"
    local content = read_file(fixture_path)
    local actual = parser.parse(content, { root = golden_root })
    local expected = load_golden(golden_path)
    if not vim.deep_equal(actual, expected) then
      error(string.format("Parser output for %s does not match golden file", name))
    end
  end
end

print("All parser equivalence golden tests passed")
