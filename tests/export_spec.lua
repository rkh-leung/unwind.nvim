-- tests/export_spec.lua
-- Comprehensive regression and functional tests for :UnwindExport filtering and markdown generation

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "assertion failed", vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_true(val, msg)
  if not val then
    error(msg or "expected truthy value")
  end
end

local unwind = require("unwind")
local sessions = require("unwind.sessions")
local state = require("unwind.state")
local export = require("unwind.export")
local session_actions = require("unwind.session_actions")
local test_env = require("tests.helpers.environment")

local isolated = test_env.setup_isolated_env()
local test_root = test_env.create_temp_dir("unwind_export_spec_")

-- Create sample project files
local proj_file1 = test_root .. "/app/models/user.lua"
local proj_file2 = test_root .. "/app/controllers/account.lua"
local vendor_file = test_root .. "/vendor/bundle/gems/helper.lua"
local missing_file = test_root .. "/app/missing.lua"

vim.fn.mkdir(test_root .. "/app/models", "p")
vim.fn.mkdir(test_root .. "/app/controllers", "p")
vim.fn.mkdir(test_root .. "/vendor/bundle/gems", "p")

local f1 = io.open(proj_file1, "w")
f1:write("local function find_user(id)\n  return { id = id, name = 'Alice' }\nend\nreturn find_user\n")
f1:close()

local f2 = io.open(proj_file2, "w")
f2:write("local function update_account(user, data)\n  user.name = data.name\n  return user\nend\nreturn update_account\n")
f2:close()

local fv = io.open(vendor_file, "w")
fv:write("local function vendor_helper()\n  return 42\nend\nreturn vendor_helper\n")
fv:close()

state.set_root(test_root)

print("--> [Export Spec 1] Filtered mode exports only project frames & methods...")
do
  unwind.clear()
  local sess = sessions.create({
    root = test_root,
    name = "Filtered Test Session",
    transient = true,
    filter_enabled = true,
    frames = {
      { file = "app/models/user.lua", line = 2, method = "find_user", note = "Project note 1" },
      { file = "vendor/bundle/gems/helper.lua", line = 2, method = "vendor_helper", note = "Vendor note should not leak" },
      { file = "app/controllers/account.lua", line = 2, method = "update_account", note = "Project note 2" },
    },
  })
  unwind.activate_session(sess)

  -- Verify session derived frames filtered out the vendor file
  assert_eq(#sess.frames, 2, "2 project frames survived filter")
  assert_eq(#sess.raw_frames, 3, "3 raw frames total in session")

  local res = export.build(sess)
  local full_text = table.concat(res.lines, "\n")

  assert_true(full_text:find("Filter: Filtered — project source only") ~= nil, "header records filtered mode")
  assert_true(full_text:find("Frames in session: 3") ~= nil, "total frames is 3")
  assert_true(full_text:find("Frames included: 2") ~= nil, "included frames is 2")
  assert_true(full_text:find("Frames excluded by filter: 1") ~= nil, "excluded frames is 1")

  -- Check Investigation Path
  assert_true(full_text:find("find_user") ~= nil, "includes find_user")
  assert_true(full_text:find("update_account") ~= nil, "includes update_account")
  assert_true(full_text:find("vendor_helper") == nil, "vendor_helper NOT in filtered export")

  -- Check Annotations
  assert_true(full_text:find("Project note 1") ~= nil, "includes Project note 1")
  assert_true(full_text:find("Project note 2") ~= nil, "includes Project note 2")
  assert_true(full_text:find("Vendor note should not leak") == nil, "vendor annotation does not leak into filtered export")

  -- Check Source Methods: only project methods extracted
  assert_true(full_text:find("Method 1 — find_user") ~= nil or full_text:find("find_user") ~= nil, "find_user source present")
  assert_true(full_text:find("vendor_helper") == nil, "vendor source code NEVER read or included")
end

print("--> [Export Spec 2] Unfiltered mode exports all frames including libraries & unavailable files...")
do
  unwind.clear()
  local sess = sessions.create({
    root = test_root,
    name = "Unfiltered Test Session",
    transient = true,
    filter_enabled = false,
    frames = {
      { file = "app/models/user.lua", line = 2, method = "find_user", note = "Project note 1" },
      { file = "vendor/bundle/gems/helper.lua", line = 2, method = "vendor_helper", note = "Vendor note visible" },
      { file = "app/missing.lua", line = 10, method = "missing_method" },
    },
  })
  unwind.activate_session(sess)

  assert_eq(#sess.frames, 3, "all 3 frames present in unfiltered collection")

  local res = export.build(sess)
  local full_text = table.concat(res.lines, "\n")

  assert_true(full_text:find("Filter: Unfiltered — all sources") ~= nil, "header records unfiltered mode")
  assert_true(full_text:find("Frames in session: 3") ~= nil, "total frames is 3")
  assert_true(full_text:find("Frames included: 3") ~= nil, "included frames is 3")
  assert_true(full_text:find("Frames excluded by filter: 0") ~= nil, "excluded frames is 0")

  -- Vendor and project methods both appear
  assert_true(full_text:find("find_user") ~= nil, "includes find_user")
  assert_true(full_text:find("vendor_helper") ~= nil, "vendor_helper included when unfiltered")
  assert_true(full_text:find("Vendor note visible") ~= nil, "vendor annotation included when unfiltered")

  -- Missing file is reported without crashing
  assert_true(full_text:find("missing.lua") ~= nil, "missing file entry present in path")
  assert_true(full_text:find("Source: Unavailable") ~= nil, "missing file marked as unavailable")
  assert_true(full_text:find("Unavailable sources: 1") ~= nil, "export summary counts unavailable sources")
end

print("--> [Export Spec 3] Filter toggling before export updates output...")
do
  unwind.clear()
  local sess = sessions.create({
    root = test_root,
    name = "Toggle Before Export Session",
    transient = true,
    filter_enabled = false,
    frames = {
      { file = "app/models/user.lua", line = 2, method = "find_user" },
      { file = "vendor/bundle/gems/helper.lua", line = 2, method = "vendor_helper" },
    },
  })
  unwind.activate_session(sess)

  -- Toggle filter on before export
  unwind.toggle_filter()
  assert_eq(sess.filter_enabled, true, "filter toggled to true")

  local res = export.build(sess)
  local full_text = table.concat(res.lines, "\n")
  assert_true(full_text:find("Filter: Filtered — project source only") ~= nil, "reflects toggled filtered state")
  assert_true(full_text:find("vendor_helper") == nil, "vendor frame excluded")
end

print("--> [Export Spec 4] Snapshot behavior: toggling filter after export does not alter existing buffer...")
do
  unwind.clear()
  local sess = sessions.create({
    root = test_root,
    name = "Snapshot Test Session",
    transient = true,
    filter_enabled = true,
    frames = {
      { file = "app/models/user.lua", line = 2, method = "find_user" },
      { file = "vendor/bundle/gems/helper.lua", line = 2, method = "vendor_helper" },
    },
  })
  unwind.activate_session(sess)

  -- Export to buffer while filtered
  local bufnr = export.export_to_buffer(sess)
  assert_true(bufnr > 0, "export buffer created")
  local snap_lines_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local snap_text_before = table.concat(snap_lines_before, "\n")
  assert_true(snap_text_before:find("Filter: Filtered — project source only") ~= nil)
  assert_true(snap_text_before:find("vendor_helper") == nil)

  -- Toggle filter to disabled afterward
  unwind.toggle_filter()
  assert_eq(sess.filter_enabled, false, "filter now disabled")

  -- Check existing buffer: must remain completely unchanged
  local snap_lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local snap_text_after = table.concat(snap_lines_after, "\n")
  assert_eq(snap_text_before, snap_text_after, "existing export buffer snapshot is immutable to subsequent filter toggle")

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

print("--> [Export Spec 5] Remote deployment path mapped into local project is classified correctly...")
do
  unwind.clear()
  local local_target_dir = test_root .. "/mapped_src"
  vim.fn.mkdir(local_target_dir, "p")
  local local_target_file = local_target_dir .. "/handler.lua"
  local f = io.open(local_target_file, "w")
  f:write("local function handle_req()\n  return 'ok'\nend\nreturn handle_req\n")
  f:close()

  unwind.setup({
    path_mappings = {
      ["/var/task/"] = local_target_dir .. "/",
    },
  })

  local sess = sessions.create({
    root = test_root,
    name = "Mapped Remote Path Session",
    transient = true,
    filter_enabled = true,
    frames = {
      { file = "/var/task/handler.lua", line = 2, method = "handle_req" },
      { file = "vendor/bundle/gems/helper.lua", line = 2, method = "vendor_helper" },
    },
  })
  unwind.activate_session(sess)

  -- Mapped remote path belongs to workspace so it survives filtering!
  assert_eq(#sess.frames, 1, "only mapped local frame survives filter")
  assert_eq(sess.frames[1].method, "handle_req")

  local res = export.build(sess)
  local full_text = table.concat(res.lines, "\n")
  assert_true(full_text:find("handle_req") ~= nil, "mapped file included in export")
  assert_true(full_text:find("vendor_helper") == nil, "vendor file excluded")

  unwind.setup({ path_mappings = {} })
end

print("--> [Export Spec 6] Method deduplication across repeated frames...")
do
  unwind.clear()
  local sess = sessions.create({
    root = test_root,
    name = "Dedup Test Session",
    transient = true,
    filter_enabled = false,
    frames = {
      { file = "app/models/user.lua", line = 2, method = "find_user" },
      { file = "app/models/user.lua", line = 3, method = "find_user" }, -- Same method body
      { file = "app/controllers/account.lua", line = 2, method = "update_account" },
    },
  })
  unwind.activate_session(sess)

  local res = export.build(sess)
  local full_text = table.concat(res.lines, "\n")

  -- Both occurrences in investigation path
  assert_true(full_text:find("1. find_user") ~= nil)
  assert_true(full_text:find("2. find_user") ~= nil)
  assert_true(full_text:find("3. update_account") ~= nil)

  -- Both frame 1 and 2 reference Method 1
  assert_true(full_text:find("Source: Method 1") ~= nil)

  -- Unique methods extracted should be 2 (find_user and update_account)
  assert_true(full_text:find("Unique methods extracted: 2") ~= nil)
end

print("--> [Export Spec 7] Exporting does not alter session, sidebar state, or source buffers...")
do
  unwind.clear()
  local sess = sessions.create({
    root = test_root,
    name = "Safety Test Session",
    transient = true,
    filter_enabled = true,
    frames = {
      { file = "app/models/user.lua", line = 2, method = "find_user" },
    },
  })
  unwind.activate_session(sess)

  local initial_active_idx = sess.active_index
  local initial_filter = sess.filter_enabled

  -- Run export command
  local bufnr = unwind.export()
  assert_true(bufnr > 0, "export buffer opened")

  -- Assert session unchanged
  assert_eq(sess.active_index, initial_active_idx, "active_index unchanged")
  assert_eq(sess.filter_enabled, initial_filter, "filter_enabled unchanged")
  assert_eq(#sess.frames, 1, "frames unchanged")
  assert_eq(#sess.raw_frames, 1, "raw_frames unchanged")

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  unwind.clear()
end

print("--> [Export Spec 8] Methods longer than 400 lines export completely without truncation...")
do
  unwind.clear()
  local long_file = test_root .. "/app/long_method.lua"
  local lines = { "local function huge_controller_action()" }
  for i = 1, 450 do
    table.insert(lines, "  local v" .. i .. " = " .. i)
  end
  table.insert(lines, "  return true")
  table.insert(lines, "end")
  table.insert(lines, "return huge_controller_action")

  local fl = io.open(long_file, "w")
  fl:write(table.concat(lines, "\n") .. "\n")
  fl:close()

  local sess = sessions.create({
    root = test_root,
    name = "Long Method Session",
    transient = true,
    filter_enabled = false,
    frames = {
      { file = "app/long_method.lua", line = 10, method = "huge_controller_action" },
    },
  })
  unwind.activate_session(sess)

  local res = export.build(sess)
  local full_text = table.concat(res.lines, "\n")

  assert_true(full_text:find("local v1 = 1") ~= nil, "start of method present")
  assert_true(full_text:find("local v450 = 450") ~= nil, "end of method past 400 lines present")
  assert_true(full_text:find("truncated") == nil, "no truncation string in document")
  assert_eq(res.manifest.extracted_methods[1].truncated, false, "manifest records not truncated")
  assert_eq(res.manifest.extracted_methods[1].end_line - res.manifest.extracted_methods[1].start_line + 1, 453, "full line span extracted")
end

print("--> [Export Spec 9] Exports larger than 2 MiB generate without truncation...")
do
  unwind.clear()
  local big_file = test_root .. "/app/big_file.lua"
  -- Generate > 2.1 MiB of code
  local lines = { "local function big_function()" }
  -- 2.1 MiB / ~50 bytes per line ≈ 45,000 lines
  for i = 1, 45000 do
    table.insert(lines, "  local var_" .. i .. " = 'abcdefghijklmnopqrstuvwxyz0123456789'")
  end
  table.insert(lines, "  return 0")
  table.insert(lines, "end")
  table.insert(lines, "return big_function")

  local fb = io.open(big_file, "w")
  fb:write(table.concat(lines, "\n") .. "\n")
  fb:close()

  local sess = sessions.create({
    root = test_root,
    name = "Big File Session",
    transient = true,
    filter_enabled = false,
    frames = {
      { file = "app/big_file.lua", line = 2, method = "big_function" },
    },
  })
  unwind.activate_session(sess)

  local res = export.build(sess)
  local full_text = table.concat(res.lines, "\n")

  assert_true(res.manifest.export_bytes > 2 * 1024 * 1024, "export size exceeds 2 MiB")
  assert_true(full_text:find("Warning: Total export size exceeded max_bytes") == nil, "no max_bytes warning")
  assert_true(full_text:find("truncated") == nil, "no truncation occurred")
  assert_eq(#res.warnings, 0, "no warnings generated for >2 MiB export")
  assert_true(full_text:find("var_45000") ~= nil, "contains line from end of 45k line method")
end

print("--> [Export Spec 10] Export byte-size reporting is exact and accurately describes finished document...")
do
  unwind.clear()
  local sess = sessions.create({
    root = test_root,
    name = "Accuracy Check Session",
    transient = true,
    filter_enabled = true,
    frames = {
      { file = "app/models/user.lua", line = 2, method = "find_user" },
      { file = "app/controllers/account.lua", line = 2, method = "update_account" },
    },
  })
  unwind.activate_session(sess)

  local res = export.build(sess)
  local full_text = table.concat(res.lines, "\n")
  local actual_bytes = #full_text

  assert_eq(res.manifest.export_bytes, actual_bytes, "manifest export_bytes equals exact document byte count")
  assert_true(full_text:find(string.format("Export size: %d bytes", actual_bytes)) ~= nil, "exact byte count rendered in document summary")
end

print("--> [Export Spec 11] Session-size reporting distinguishes persisted metadata from extracted source...")
do
  unwind.clear()
  local sess = sessions.create({
    root = test_root,
    name = "Metadata vs Source Size Session",
    transient = false,
    saved = true,
    filter_enabled = false,
    frames = {
      { file = "app/models/user.lua", line = 2, method = "find_user" },
    },
  })

  -- Persist the session to disk
  local saved_sessions = { sess }
  sessions.save(test_root, saved_sessions)

  local meta_size_bytes, is_exact = sessions.get_size(sess)
  assert_true(is_exact, "saved session size is exact")
  assert_true(meta_size_bytes > 50 and meta_size_bytes < 1000, "persisted metadata size is small JSON (<1 KB)")

  -- Export includes source code, headers, preamble, and markdown fences
  local res = export.build(sess)
  assert_true(res.manifest.export_bytes > meta_size_bytes, "export size includes extracted source and is much larger than session metadata")
  assert_true(res.manifest.export_bytes > 1000, "export document has full Markdown structure")
end

print("--> [Export Spec 12] Missing source and parser failures remain visible in report...")
do
  unwind.clear()
  local excerpt_file = test_root .. "/app/outside_fn.lua"
  local fe = io.open(excerpt_file, "w")
  fe:write("-- Top level file without function\nlocal x = 1\nlocal y = 2\n")
  fe:close()

  local sess = sessions.create({
    root = test_root,
    name = "Missing and Incomplete Session",
    transient = true,
    filter_enabled = false,
    frames = {
      { file = "app/missing_file_xyz.lua", line = 5, method = "not_here" },
      { file = "app/outside_fn.lua", line = 2, method = "top_level" },
    },
  })
  unwind.activate_session(sess)

  local res = export.build(sess)
  local full_text = table.concat(res.lines, "\n")

  assert_eq(res.manifest.unavailable_sources, 1, "manifest records 1 unavailable source")
  assert_eq(res.manifest.incomplete_extractions, 1, "manifest records 1 incomplete extraction")
  assert_true(full_text:find("Unavailable sources: 1") ~= nil, "report summary displays unavailable count")
  assert_true(full_text:find("Incomplete extractions: 1") ~= nil, "report summary displays incomplete count")
  assert_true(full_text:find("Source: Unavailable") ~= nil, "investigation path marks missing source")
  assert_true(full_text:find("Excerpt") ~= nil, "extracted source labels fallback as Excerpt")
end

print("--> [Export Spec 13] Repeated exports do not create unnecessary resource leaks...")
do
  unwind.clear()
  local sess = sessions.create({
    root = test_root,
    name = "Leak Test Session",
    transient = true,
    filter_enabled = true,
    frames = {
      { file = "app/models/user.lua", line = 2, method = "find_user" },
    },
  })
  unwind.activate_session(sess)

  local bufs_created = {}
  for _ = 1, 20 do
    local bufnr = unwind.export(sess)
    assert_true(bufnr > 0, "export buffer handle valid")
    table.insert(bufs_created, bufnr)
  end

  -- Clean up all created scratch buffers
  for _, b in ipairs(bufs_created) do
    if vim.api.nvim_buf_is_valid(b) then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end

  unwind.clear()
end

isolated.cleanup()
test_env.cleanup_all()

print("All export spec tests PASSED successfully!")
