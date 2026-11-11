-- tests/sidebar_spec.lua
-- Tests for sidebar UTF-8 truncation, window management, and active row highlighting

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

local sidebar = require("unwind.sidebar")
local text = require("unwind.text")
local sessions = require("unwind.sessions")

print("--> [Sidebar Spec 1] UTF-8 safe display truncation...")
do
  local strwidth = vim.api.nvim_strwidth
  -- Ordinary ASCII
  local s1 = "Hello World This Is A Long String"
  local t1 = text.truncate_display(s1, 10)
  assert_true(strwidth(t1) <= 10, "ASCII truncated within width")

  -- Accented Latin: café
  local s2 = "café au lait très bon"
  local t2 = text.truncate_display(s2, 6)
  assert_true(strwidth(t2) <= 6, "Latin accented truncated within width")

  -- Japanese (multibyte, 2-cell width per character)
  local s3 = "こんにちは世界"
  local t3 = text.truncate_display(s3, 5)
  assert_true(strwidth(t3) <= 5, "Japanese truncated within width")
  assert_eq(t3, "こん", "2 full characters (width 4 <= 5)")

  -- Emoji
  local s4 = "🚀🔥✨🎉"
  local t4 = text.truncate_display(s4, 4)
  assert_true(strwidth(t4) <= 4, "Emoji truncated within width")
end

print("--> [Sidebar Spec 2] Sidebar render and active state...")
do
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local sess = sessions.create({
    root = cwd,
    transient = true,
    frames = {
      { file = "a.py", line = 1, method = "test_method" },
    },
  })
  sess.frames = sess.raw_frames
  sess.files = { { file = "a.py", available = true } }

  sidebar.open(sess, {})
  assert_true(sidebar.is_open(), "sidebar opened")
  sidebar.render(sess)
  sidebar.set_active(sess, 1)

  sidebar.hide()
  assert_true(not sidebar.is_open(), "sidebar closed")
end

print("All sidebar spec tests PASSED successfully!")
