-- tests/annotation_spec.lua
-- Tests for frame annotations, contextual labels, persistence, and sidebar presentation

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

local sessions = require("unwind.sessions")
local persistence = require("unwind.persistence")
local decorator = require("unwind.decorator")
local sidebar = require("unwind.sidebar")
local unwind = require("unwind")

local test_root = vim.fs.normalize(vim.fn.getcwd())
local storage_file = sessions.storage_path(test_root)

print("--> [Annotation Spec 1] Frame creation without note, adding note, updating note, removing note...")
do
  local frame = {
    file = "src/foo.lua",
    line = 10,
    col = 5,
    method = "calc",
    origin = "manual",
  }
  local s = sessions.create({
    root = test_root,
    frames = { frame },
    transient = true,
  })

  assert_eq(#s.raw_frames, 1, "1 raw frame")
  assert_eq(s.raw_frames[1].note, nil, "note is initially nil")

  -- Add note
  s.raw_frames[1].note = "Check boundary calculation"
  assert_eq(s.raw_frames[1].note, "Check boundary calculation", "note added")

  -- Update note
  s.raw_frames[1].note = "Updated hypothesis"
  assert_eq(s.raw_frames[1].note, "Updated hypothesis", "note updated")

  -- Remove note (empty string / whitespace treated as absent)
  sessions.update_frame(s, 1, {
    file = "src/foo.lua",
    line = 10,
    col = 5,
    method = "calc",
    origin = "manual",
    note = "   ",
  })
  assert_eq(s.raw_frames[1].note, nil, "whitespace note treated as nil")
end

print("--> [Annotation Spec 2] Loading legacy sessions without note property & persistence round-trip...")
do
  pcall(os.remove, storage_file)
  -- 1. Create a legacy json without note fields
  local legacy_json = vim.json.encode({
    schema_version = 1,
    root = test_root,
    sessions = {
      {
        id = "sess_legacy_1",
        name = "Legacy Session",
        filter_enabled = false,
        created_at = os.time(),
        updated_at = os.time(),
        frames = {
          {
            path = "src/old.lua",
            file = "src/old.lua",
            line = 5,
            col = 1,
            method = "legacy_fn",
            origin = "stacktrace",
            raw_line = "src/old.lua:5",
          }
        }
      }
    }
  })
  local _, state_dir = persistence.storage_path(test_root)
  vim.fn.mkdir(state_dir, "p")
  local f = io.open(storage_file, "w")
  f:write(legacy_json)
  f:close()

  -- Load legacy session
  local loaded = persistence.load(test_root)
  assert_eq(#loaded, 1, "legacy session loaded")
  assert_eq(loaded[1].name, "Legacy Session", "legacy name matches")
  assert_eq(#loaded[1].raw_frames, 1, "1 raw frame")
  assert_eq(loaded[1].raw_frames[1].note, nil, "legacy frame note must be nil")

  -- Add an annotation to the loaded session and persist
  loaded[1].raw_frames[1].note = "Legacy frame observed"
  local ok_save = persistence.save(test_root, loaded)
  assert_true(ok_save, "saved annotated session to disk")

  -- Reload and verify note persisted
  local reloaded = persistence.load(test_root)
  assert_eq(reloaded[1].raw_frames[1].note, "Legacy frame observed", "persisted note restored correctly")

  pcall(os.remove, storage_file)
end

print("--> [Annotation Spec 3] Preserving notes across frame reorder (J/K) and frame replacement (e)...")
do
  local f1 = { file = "tests/fixtures/dummy.txt", line = 1, col = 1, method = "m1", origin = "manual", note = "Note for F1" }
  local f2 = { file = "tests/fixtures/dummy.txt", line = 1, col = 1, method = "m2", origin = "manual", note = "Note for F2" }
  local s = sessions.create({
    root = test_root,
    name = "Reorder Test",
    frames = { f1, f2 },
    transient = false,
  })

  -- Move frame 1 to 2
  local ok_move = sessions.move_frame(s, 1, 2)
  assert_true(ok_move, "move frame succeeded")
  assert_eq(s.raw_frames[1].method, "m2", "frame 1 is now m2")
  assert_eq(s.raw_frames[1].note, "Note for F2", "frame 1 retained Note for F2")
  assert_eq(s.raw_frames[2].method, "m1", "frame 2 is now m1")
  assert_eq(s.raw_frames[2].note, "Note for F1", "frame 2 retained Note for F1")

  -- Replace frame 2: note should be preserved if not explicitly overwritten
  unwind.clear()
  unwind.activate_session(s)
  local dummy_path = test_root .. "/tests/fixtures/dummy.txt"
  local dummy_buf = vim.fn.bufnr(dummy_path)
  if dummy_buf == -1 then
    dummy_buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, dummy_buf, dummy_path)
  end
  vim.api.nvim_set_current_buf(dummy_buf)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  unwind.replace_frame_in_session(s, 2)
  assert_eq(s.raw_frames[2].note, "Note for F1", "replacing frame preserved existing note")

  unwind.clear()
end

print("--> [Annotation Spec 4] Duplicate source locations retain independent annotations...")
do
  local s = sessions.create({
    root = test_root,
    frames = {
      { file = "src/dup.lua", line = 20, method = "dup_fn", origin = "stacktrace", note = "First call observation" },
      { file = "src/dup.lua", line = 20, method = "dup_fn", origin = "stacktrace", note = "Second recursive call observation" },
    },
    transient = true,
  })

  assert_eq(#s.raw_frames, 2, "2 duplicate frames")
  assert_eq(s.raw_frames[1].note, "First call observation", "frame 1 note")
  assert_eq(s.raw_frames[2].note, "Second recursive call observation", "frame 2 note")
end

print("--> [Annotation Spec 5] Filtered views update correct raw frame and note indicator in sidebar...")
do
  local vendor_and_app_trace = [[
core/app/feed.rb:10:in `render'
/apps/myapp/shared/bundle/ruby/3.3.0/gems/activesupport/callbacks.rb:27:in `run'
app/models/brand.rb:5:in `name'
]]
  unwind.clear()
  unwind.ingest(vendor_and_app_trace)
  local s = unwind.state.active_session

  -- Enable filter: hides callbacks.rb (vendor)
  s.filter_enabled = true
  unwind.reapply_filter()
  assert_eq(#s.frames, 2, "2 filtered frames (feed.rb and brand.rb)")
  assert_eq(s.frames[2].file, "app/models/brand.rb", "frame 2 in filtered view is brand.rb")

  -- Annotate frame 2 in filtered view
  local ok_ann = require("unwind.session_actions").annotate_frame_in_session(s, 2, "Brand lookup note", nil, unwind.config)
  assert_true(ok_ann, "annotate_frame_in_session succeeded")

  -- Verify raw_frames[3] (brand.rb) has the note
  assert_eq(s.raw_frames[3].note, "Brand lookup note", "brand.rb in raw_frames has note")
  assert_eq(s.raw_frames[2].note, nil, "vendor callbacks.rb was NOT modified")

  -- Disable filter: all 3 frames present, brand.rb still has note
  s.filter_enabled = false
  unwind.reapply_filter()
  assert_eq(#s.frames, 3, "3 frames restored")
  assert_eq(s.frames[3].note, "Brand lookup note", "frame 3 retains note")

  -- Verify sidebar renders indicator ●
  unwind.toggle_sidebar()
  local side_buf = vim.fn.bufnr("unwind://sidebar")
  assert_true(side_buf ~= -1, "sidebar buffer found")
  local lines = vim.api.nvim_buf_get_lines(side_buf, 0, -1, false)
  -- Row for frame 3 should have ● indicator
  -- lines: 0=Header, 1="", 2=frame 1, 3=frame 2, 4=frame 3
  local frame3_line = lines[5] -- 1-indexed in Lua
  assert_true(frame3_line:find("●") ~= nil, "frame 3 row contains ● indicator: " .. frame3_line)
  local frame1_line = lines[3]
  assert_true(frame1_line:find("●") == nil, "frame 1 row does not contain ● indicator: " .. frame1_line)

  sidebar.hide()
  unwind.clear()
end

print("--> [Annotation Spec 6] Virtual-line rendering and contextual labels ([DEBUG PATH] vs [STACK FRAME])...")
do
  local decor_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(decor_buf, 0, -1, false, { "def my_code", "end" })

  -- 1. Manual frame with note
  local ext_id_manual = decorator.render(decor_buf, 1, 1, "test_step", "app/service.rb", 3, {
    origin = "manual",
    note = "Testing validation error",
  })
  assert_true(ext_id_manual ~= nil, "rendered manual frame")

  local extmarks_manual = vim.api.nvim_buf_get_extmarks(decor_buf, decorator.get_namespace(), 0, -1, { details = true })
  assert_eq(#extmarks_manual, 1, "1 extmark for manual frame")
  local virt_lines_m = extmarks_manual[1][4].virt_lines
  assert_eq(#virt_lines_m, 3, "3 virtual lines (header, details, note)")
  local header_m = virt_lines_m[1][1][1]
  local header_hl_m = virt_lines_m[1][1][2]
  assert_true(header_m:find("%[DEBUG PATH%] Step 1/3: test_step%(%)") ~= nil, "header has [DEBUG PATH] Step 1/3: " .. header_m)
  assert_eq(header_hl_m, "UnwindDecorManual", "header hl group UnwindDecorManual")

  local details_m = virt_lines_m[2][1][1]
  assert_true(details_m:find("↳ app/service.rb:1") ~= nil, "details line has ↳ file:line: " .. details_m)

  local note_m = virt_lines_m[3][1][1]
  local note_hl_m = virt_lines_m[3][1][2]
  assert_true(note_m:find("💬 Testing validation error") ~= nil, "note line has 💬 text: " .. note_m)
  assert_eq(note_hl_m, "UnwindAnnotation", "note hl group UnwindAnnotation")

  -- 2. Stacktrace frame without note
  local ext_id_stack = decorator.render(decor_buf, 1, 2, "process", "gems/lib.rb", 10, {
    origin = "stacktrace",
    note = nil,
  })
  assert_true(ext_id_stack ~= nil, "rendered stacktrace frame")

  local extmarks_stack = vim.api.nvim_buf_get_extmarks(decor_buf, decorator.get_namespace(), 0, -1, { details = true })
  local virt_lines_s = extmarks_stack[1][4].virt_lines
  assert_eq(#virt_lines_s, 2, "2 virtual lines (header, details; no note line)")
  local header_s = virt_lines_s[1][1][1]
  local header_hl_s = virt_lines_s[1][1][2]
  assert_true(header_s:find("%[STACK FRAME%] Frame 2/10: process%(%)") ~= nil, "header has [STACK FRAME] Frame 2/10: " .. header_s)
  assert_eq(header_hl_s, "UnwindDecorStack", "header hl group UnwindDecorStack")

  -- 3. Verify underlying source buffer content was NEVER modified
  local buf_lines = vim.api.nvim_buf_get_lines(decor_buf, 0, -1, false)
  assert_eq(#buf_lines, 2, "source buffer still has 2 lines")
  assert_eq(buf_lines[1], "def my_code", "source line 1 untouched")
  assert_eq(buf_lines[2], "end", "source line 2 untouched")

  pcall(vim.api.nvim_buf_delete, decor_buf, { force = true })
end

print("--> [Annotation Spec 7] :UnwindAnnotate and sidebar 'a' action integration...")
do
  unwind.clear()
  unwind.ingest('File "tests/fixtures/dummy.txt", line 1, in do_work\n')
  local s = unwind.state.active_session

  -- Simulate ui.prompt_input by mocking it temporarily
  local ui = require("unwind.ui")
  local orig_prompt = ui.prompt_input
  local prompt_called = false
  local prompt_default = nil

  ui.prompt_input = function(title, default_val, on_submit)
    prompt_called = true
    prompt_default = default_val
    on_submit("Simulated annotation note")
  end

  -- Ensure plugin commands are loaded
  pcall(vim.cmd, "source plugin/unwind.lua")
  -- Call :UnwindAnnotate (delegates to unwind.annotate())
  vim.cmd("UnwindAnnotate")
  assert_true(prompt_called, "prompt_input was called by :UnwindAnnotate")
  assert_eq(prompt_default, "", "initial default value was empty")
  assert_eq(s.frames[1].note, "Simulated annotation note", "frame note updated via prompt")

  -- Call :UnwindAnnotate again: should prepopulate existing note
  prompt_called = false
  ui.prompt_input = function(title, default_val, on_submit)
    prompt_called = true
    prompt_default = default_val
    -- User cancels (does not invoke on_submit)
  end

  vim.cmd("UnwindAnnotate")
  assert_true(prompt_called, "prompt_input was called second time")
  assert_eq(prompt_default, "Simulated annotation note", "prepopulated with existing note")
  assert_eq(s.frames[1].note, "Simulated annotation note", "canceling prompt leaves note unchanged")

  -- Restore ui.prompt_input
  ui.prompt_input = orig_prompt
  unwind.clear()
end

print("All annotation spec tests PASSED successfully!")
