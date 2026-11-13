---@module "unwind.buffer"
--- Dedicated modifiable buffer and mini.files-style synchronization engine.
--- Single source of truth for the unwind call-trace buffer ("unwind://sidebar").

local parser = require("unwind.parser")
local sessions = require("unwind.sessions")
local session_actions = require("unwind.session_actions")
local state = require("unwind.state")
local text_util = require("unwind.text")
local navigation = require("unwind.navigation")

local M = {}

local canonical_buf = nil

local ns_buffer = vim.api.nvim_create_namespace("unwind_sidebar")
local ns_active = vim.api.nvim_create_namespace("unwind_sidebar_active")

--- Set up syntax highlights
local function setup_highlights()
  vim.api.nvim_set_hl(0, "UnwindSidebarActive", { default = true, link = "CursorLine" })
  vim.api.nvim_set_hl(0, "UnwindSidebarMissing", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "UnwindSidebarHeader", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "UnwindSidebarMuted", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "UnwindSidebarAnnotated", { default = true, link = "Special" })
end

--- Return the existing canonical unwind buffer if already created, without allocating a new one
---@return integer? bufnr
function M.get()
  if canonical_buf and vim.api.nvim_buf_is_valid(canonical_buf) then
    return canonical_buf
  end

  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find("unwind://sidebar") then
      canonical_buf = b
      return canonical_buf
    end
  end

  return nil
end

--- Get or create the canonical unwind buffer ("unwind://sidebar")
--- Configures buftype=acwrite, bufhidden=hide, buflisted=true, filetype=unwind, modifiable=true, swapfile=false
--- Attaches BufWriteCmd and QuitPre autocmds ONCE.
---@return integer bufnr
function M.get_or_create()
  local existing = M.get()
  if existing then
    return existing
  end

  canonical_buf = vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, canonical_buf, "unwind://sidebar")

  local buf = canonical_buf
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = true
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "unwind"
  vim.bo[buf].modifiable = true

  -- Attach buffer syntax rules for concealing the ^<uid> prefix
  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[syntax match UnwindFrameUid /^\^\d\+\s/ conceal]])
  end)

  -- Attach BufWriteCmd and QuitPre autocmds once for this buffer
  local augroup = vim.api.nvim_create_augroup("UnwindBuffer_" .. buf, { clear = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = buf,
    callback = function()
      local cur_sess = state.current()
      if cur_sess then
        M.synchronize(buf, cur_sess)
      end
    end,
  })

  vim.api.nvim_create_autocmd("QuitPre", {
    group = augroup,
    buffer = buf,
    callback = function()
      -- :q! (cmdbang) skips the prompt entirely and allows the quit
      if vim.v.cmdbang == 1 then
        return
      end
      local cur_sess = state.current()
      if cur_sess and M.has_unsynced_changes(buf, cur_sess) then
        local choice = vim.fn.confirm("Call trace has unsynchronized changes. Synchronize before closing?", "&Yes\n&No\n&Cancel", 1)
        if choice == 1 then
          -- Yes: sync without duplicate confirm prompt
          M.synchronize(buf, cur_sess, { skip_confirm = true })
          -- If sync failed the buffer remains modified which will prevent the quit naturally
        elseif choice == 2 then
          -- No: discard edits, re-render and allow quit
          vim.bo[buf].modified = false
          M.render(cur_sess, buf)
        else
          -- Cancel: keep buffer modified so Neovim's built-in unsaved buffer check blocks quit
          vim.bo[buf].modified = true
        end
      end
    end,
  })

  M.setup_keymaps(buf)

  return buf
end

--- Configure window options for a window displaying the unwind buffer
---@param win integer
function M.configure_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].conceallevel = 3
  vim.wo[win].concealcursor = "nvic"
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
end

--- Format a single canonical line for a frame
--- Format: `^<uid> <marker><idx> <method_or_NA>  <basename>:<line>`
---@param frame table
---@param idx integer
---@param session table
---@param win_width? integer
---@return string line
function M.format_frame_line(frame, idx, session, win_width)
  local uid = frame.uid or 0
  local file_entry = (frame.file_index and session.files) and session.files[frame.file_index] or nil
  local is_avail = true
  if file_entry and file_entry.available ~= nil then
    is_avail = file_entry.available
  elseif frame.navigable ~= nil then
    is_avail = frame.navigable
  end

  local has_note = frame.note ~= nil and frame.note ~= ""
  local marker = has_note and "●" or " "
  local num_str = string.format("%2d", idx)
  local loc_str = string.format("%s:%d", vim.fs.basename(frame.file or frame.path or ""), frame.line or 1)
  local status_str
  if not is_avail then
    status_str = "N/A"
  elseif frame.method and frame.method ~= "" then
    status_str = frame.method
  else
    status_str = loc_str
    loc_str = ""
  end

  local strwidth = vim.api.nvim_strwidth or function(s) return #s end
  win_width = win_width or 36

  local line_body
  if loc_str ~= "" then
    local base_w = strwidth(string.format(" %s%s   %s", marker, num_str, loc_str))
    if base_w + strwidth(status_str) > win_width and win_width > 12 then
      local max_status_w = math.max(4, win_width - strwidth(num_str) - strwidth(loc_str) - 8)
      status_str = text_util.truncate_display(status_str, max_status_w)
    end
    line_body = string.format(" %s%s %s  %s", marker, num_str, status_str, loc_str)
  else
    line_body = string.format(" %s%s %s", marker, num_str, status_str)
  end

  return string.format("^%d %s", uid, line_body)
end

--- Check if the unwind buffer has unsynchronized changes
---@param buf integer
---@param session table
---@return boolean
function M.has_unsynced_changes(buf, session)
  buf = buf or canonical_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if not session then
    return false
  end
  if not vim.bo[buf].modified then
    return false
  end

  -- Verify if content differs from canonical session lines
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local non_blank_lines = {}
  for _, l in ipairs(lines) do
    if vim.trim(l) ~= "" then
      table.insert(non_blank_lines, l)
    end
  end

  local frames = session.frames or {}
  if #non_blank_lines ~= #frames then
    return true
  end

  for idx, frame in ipairs(frames) do
    local line = non_blank_lines[idx]
    local uid_match = line:match("^%^(%d+)%s+")
    if not uid_match or tonumber(uid_match) ~= frame.uid then
      return true
    end
  end

  return false
end

--- Render active session frames into the buffer
--- Every line corresponds 1:1 to a frame row (line 1 == frame 1, line N == frame N).
--- Chrome (session title + filter/modified status) rendered in winbar,
--- and active frame summary + keymap hint rendered in statusline.
---@param session table
---@param target_buf? integer
---@param target_win? integer
function M.render(session, target_buf, target_win)
  if not session then
    return
  end
  sessions.ensure_uids(session.raw_frames)
  sessions.ensure_uids(session.frames)
  setup_highlights()

  local buf = target_buf or canonical_buf or M.get_or_create()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns_buffer, 0, -1)

  local win = target_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
        win = w
        break
      end
    end
  end

  local win_width = 36
  if win and vim.api.nvim_win_is_valid(win) then
    win_width = vim.api.nvim_win_get_width(win)
    M.configure_window(win)
  end

  local frames = session.frames or {}
  local lines = {}

  if #frames == 0 then
    table.insert(lines, "")
  else
    for idx, f in ipairs(frames) do
      table.insert(lines, M.format_frame_line(f, idx, session, win_width))
    end
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  -- Apply syntax highlights
  for idx, f in ipairs(frames) do
    local buf_line = idx - 1 -- 0-indexed line in buffer
    local file_entry = (f.file_index and session.files) and session.files[f.file_index] or nil
    local is_avail = true
    if file_entry and file_entry.available ~= nil then
      is_avail = file_entry.available
    elseif f.navigable ~= nil then
      is_avail = f.navigable
    end

    if f.note ~= nil and f.note ~= "" then
      vim.api.nvim_buf_add_highlight(buf, ns_buffer, "UnwindSidebarAnnotated", buf_line, 0, -1)
    end

    if not is_avail then
      vim.api.nvim_buf_add_highlight(buf, ns_buffer, "UnwindSidebarMissing", buf_line, 0, -1)
    else
      vim.api.nvim_buf_add_highlight(buf, ns_buffer, "UnwindSidebarMuted", buf_line, 0, -1)
    end
  end

  -- Update chrome (winbar and statusline)
  M.update_chrome(session, win)

  -- Update active frame highlight and cursor
  M.set_active(session, session.active_index or 1, buf, win)
end

--- Update winbar and statusline for window
---@param session table
---@param win? integer
function M.update_chrome(session, win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local title = (session.name or "Untitled"):gsub("%%", "%%%%")
  local filter_str = session.filter_enabled and " [filtered]" or ""
  local buf = vim.api.nvim_win_get_buf(win)
  local mod_str = (buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified) and " [+]" or ""

  local winbar_text = string.format(" Unwind: %s%s%s", title, filter_str, mod_str)
  pcall(function() vim.wo[win].winbar = winbar_text end)

  local status_text
  local frames = session.frames or {}
  if #frames > 0 and session.active_index and session.active_index > 0 and frames[session.active_index] then
    local act_frame = frames[session.active_index]
    local safe_file = (act_frame.file or act_frame.path or ""):gsub("%%", "%%%%")
    status_text = string.format(
      " %d/%d %s:%d  = sync%%<  <CR> open  o/O add  q close%%=",
      session.active_index,
      #frames,
      safe_file,
      act_frame.line or 1
    )
  else
    status_text = " = sync%%<  o/O add  q close%%="
  end
  pcall(function() vim.wo[win].statusline = status_text end)
end

--- Update active row highlight and cursor
---@param session table
---@param index number
---@param target_buf? integer
---@param target_win? integer
function M.set_active(session, index, target_buf, target_win)
  local buf = target_buf or canonical_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not session then
    return
  end

  local frames = session.frames or {}
  if #frames == 0 then
    return
  end

  index = math.max(1, math.min(index or 1, #frames))
  local target_buf_line = index - 1 -- 0-indexed line

  local win = target_win
  if not win or not vim.api.nvim_win_is_valid(win) then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
        win = w
        break
      end
    end
  end

  if win and vim.api.nvim_win_is_valid(win) then
    local max_line = vim.api.nvim_buf_line_count(buf)
    local cur_target = math.min(target_buf_line + 1, max_line)
    pcall(vim.api.nvim_win_set_cursor, win, { cur_target, 0 })
    M.update_chrome(session, win)
  end

  vim.api.nvim_buf_clear_namespace(buf, ns_active, 0, -1)

  local file_entry = (frames[index].file_index and session.files) and session.files[frames[index].file_index] or nil
  local is_avail = true
  if file_entry then
    is_avail = file_entry.available ~= false
  elseif frames[index].navigable ~= nil then
    is_avail = frames[index].navigable
  end

  vim.api.nvim_buf_add_highlight(buf, ns_active, "UnwindSidebarActive", target_buf_line, 0, -1)
  if not is_avail then
    vim.api.nvim_buf_add_highlight(buf, ns_active, "UnwindSidebarMissing", target_buf_line, 0, -1)
  end
end

--- Parse a manually entered line (without ^<uid>) into frame objects
---@param line string
---@param trimmed string
---@param session table
---@param config table
---@return table[]? frames
local function parse_manual_buffer_line(line, trimmed, session, config)
  local clean_line = line:gsub("^%s*%^%d+%s+", "")
  local clean_trimmed = vim.trim(clean_line)
  local parsed = parser.parse(clean_line, { root = session.root, path_mappings = config.path_mappings })
  if parsed and #parsed > 0 then
    for _, pf in ipairs(parsed) do
      pf.origin = "manual"
    end
    return parsed
  end

  -- Simple file:line pattern fallback
  local file_cand, line_cand = clean_trimmed:match("^([%w_%-./\\]+%.%w+):(%d+)$")
  if file_cand and line_cand then
    return {
      {
        path = file_cand,
        file = file_cand,
        line = tonumber(line_cand) or 1,
        col = 1,
        origin = "manual",
      },
    }
  end

  -- Bare file path fallback (if it exists in workspace)
  local is_avail, resolved = navigation.check_file_availability(clean_trimmed, session.root, config.path_mappings)
  if is_avail then
    return {
      {
        path = clean_trimmed,
        file = clean_trimmed,
        resolved_path = resolved,
        line = 1,
        col = 1,
        origin = "manual",
      },
    }
  end

  return nil
end

--- Diff & Reconciliation Algorithm (triggered by `=` or `:w` or QuitPre)
---@param buf integer
---@param session table
---@param opts? { skip_confirm?: boolean }
---@return boolean success
function M.synchronize(buf, session, opts)
  opts = opts or {}
  buf = buf or canonical_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) or not session then
    return false
  end

  sessions.ensure_uids(session.raw_frames)
  sessions.ensure_uids(session.frames)

  local unwind = require("unwind")
  local config = unwind.config or {}

  -- 1. Build lookup map uid_to_raw from session.raw_frames and track seen_uids
  local uid_to_raw = {}
  for _, rf in ipairs(session.raw_frames or {}) do
    if rf.uid then
      uid_to_raw[rf.uid] = rf
    end
  end

  local seen_uids = {}
  local reconciled_visible_frames = {}
  local actions_summary = {}
  local skipped_lines = {}

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for _, line in ipairs(lines) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then
      local uid_str = line:match("^%^(%d+)%s+")
      if uid_str then
        local uid = tonumber(uid_str)
        local raw_frame = uid_to_raw[uid]
        if raw_frame then
          if not seen_uids[uid] then
            seen_uids[uid] = true
            table.insert(reconciled_visible_frames, raw_frame)
          else
            -- Duplicate frame (yyp)
            local cloned = sessions.clone_frame(raw_frame)
            table.insert(reconciled_visible_frames, cloned)
            table.insert(actions_summary, string.format("Duplicate: %s:%d", cloned.file or cloned.path, cloned.line or 1))
          end
        else
          local parsed = parse_manual_buffer_line(line, trimmed, session, config)
          if parsed then
            for _, pf in ipairs(parsed) do
              table.insert(reconciled_visible_frames, pf)
              table.insert(actions_summary, string.format("Add: %s:%d", pf.file or pf.path, pf.line or 1))
            end
          else
            table.insert(skipped_lines, trimmed)
          end
        end
      else
        -- User opened a line with o/O or pasted path/to/file.lua:42
        local parsed = parse_manual_buffer_line(line, trimmed, session, config)
        if parsed then
          for _, pf in ipairs(parsed) do
            table.insert(reconciled_visible_frames, pf)
            table.insert(actions_summary, string.format("Add: %s:%d", pf.file or pf.path, pf.line or 1))
          end
        else
          table.insert(skipped_lines, trimmed)
        end
      end
    end
  end

  if #skipped_lines > 0 then
    vim.notify(
      "Unwind: Ignored unrecognized line(s) during sync: " .. table.concat(skipped_lines, ", "),
      vim.log.levels.WARN
    )
  end

  -- Detect removed frames (uid missing from seen_uids)
  for _, vf in ipairs(session.frames or {}) do
    if vf.uid and not seen_uids[vf.uid] then
      local desc = (vf.method and vf.method ~= "") and vf.method or (vf.file or vf.path or "")
      table.insert(actions_summary, string.format("Delete: %s:%d", desc, vf.line or 1))
    end
  end

  -- Check reordering
  local reordered_count = 0
  for idx, vf in ipairs(session.frames or {}) do
    local new_f = reconciled_visible_frames[idx]
    if new_f and new_f.uid ~= vf.uid then
      reordered_count = reordered_count + 1
    end
  end
  if reordered_count > 0 then
    table.insert(actions_summary, string.format("Reorder: %d frame(s) repositioned", reordered_count))
  end

  -- 4. If no semantic changes exist
  local has_semantic_changes = (#actions_summary > 0)
    or (#reconciled_visible_frames ~= #(session.frames or {}))

  if not has_semantic_changes then
    vim.bo[buf].modified = false
    M.render(session, buf)
    return true
  end

  -- 5. Confirm sync prompt if enabled and not skipped
  if not opts.skip_confirm and config.confirm_sync ~= false then
    local prompt_lines = { "Synchronize call trace changes?" }
    table.insert(prompt_lines, "")
    for _, act in ipairs(actions_summary) do
      table.insert(prompt_lines, "  • " .. act)
    end
    local msg = table.concat(prompt_lines, "\n")
    local choice = vim.fn.confirm(msg, "&Yes\n&No\n&Cancel", 1)
    if choice == 1 then
      -- proceed
    elseif choice == 2 then
      -- discard and re-render
      vim.bo[buf].modified = false
      M.render(session, buf)
      return false
    else
      -- cancel
      return false
    end
  end

  -- 6. Filter preservation:
  -- If session.filter_enabled == true, hidden vendor frames from session.raw_frames
  -- must be preserved in their closest relative positions rather than dropped.
  local reconciled_raw_frames = {}
  if session.filter_enabled then
    local visible_uids_initial = {}
    for _, f in ipairs(session.frames or {}) do
      if f.uid then
        visible_uids_initial[f.uid] = true
      end
    end

    local rec_idx = 1
    for _, rf in ipairs(session.raw_frames or {}) do
      if rf.uid and not visible_uids_initial[rf.uid] then
        table.insert(reconciled_raw_frames, rf)
      else
        if rec_idx <= #reconciled_visible_frames then
          table.insert(reconciled_raw_frames, reconciled_visible_frames[rec_idx])
          rec_idx = rec_idx + 1
        end
      end
    end
    while rec_idx <= #reconciled_visible_frames do
      table.insert(reconciled_raw_frames, reconciled_visible_frames[rec_idx])
      rec_idx = rec_idx + 1
    end
  else
    reconciled_raw_frames = reconciled_visible_frames
  end

  -- 7. Commit via session_actions.replace_frames_in_session
  local saved_sessions = state.ensure_sessions_loaded(session.root)
  local ok, err = session_actions.replace_frames_in_session(session, reconciled_raw_frames, saved_sessions, config)
  if not ok then
    vim.notify("Unwind: Sync failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end

  vim.bo[buf].modified = false
  M.render(session, buf)
  session_actions.refresh_active_presentation(session)
  return true
end

--- Set up keymaps for the unwind buffer
---@param buf integer
function M.setup_keymaps(buf)
  local key_opts = { noremap = true, silent = true, buffer = buf }

  local function get_active_session()
    return state.current()
  end

  -- = : Synchronize staged buffer edits to session
  vim.keymap.set("n", "=", function()
    local s = get_active_session()
    if s then
      M.synchronize(buf, s)
    end
  end, key_opts)

  -- <BS> : Reset/discard unsynchronized buffer edits back to current session state
  vim.keymap.set("n", "<BS>", function()
    local s = get_active_session()
    if s then
      M.render(s, buf)
    end
  end, key_opts)

  -- <CR> : Jump to frame under cursor
  vim.keymap.set("n", "<CR>", function()
    local s = get_active_session()
    if not s then
      return
    end
    if M.has_unsynced_changes(buf, s) then
      vim.notify("Unwind: Buffer has unsynchronized edits. Press '=' to sync first.", vim.log.levels.WARN)
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line_idx = cursor[1] -- 1-indexed line in buffer == frame index
    if s.frames and line_idx >= 1 and line_idx <= #s.frames then
      navigation.jump_to_frame(s, line_idx)
    end
  end, key_opts)

  -- o : Insert source window's cursor location AFTER frame under cursor
  vim.keymap.set("n", "o", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local frame_idx = cursor[1]
    require("unwind").add_current_location({ index = frame_idx + 1 })
  end, key_opts)

  -- O : Insert source window's cursor location BEFORE frame under cursor
  vim.keymap.set("n", "O", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local frame_idx = cursor[1]
    require("unwind").add_current_location({ index = frame_idx })
  end, key_opts)

  -- a : Annotate frame under cursor
  vim.keymap.set("n", "a", function()
    local s = get_active_session()
    if not s then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local frame_idx = cursor[1]
    if s.frames and frame_idx >= 1 and frame_idx <= #s.frames then
      require("unwind").annotate(frame_idx, s)
    end
  end, key_opts)

  -- e : Replace frame under cursor with source window's cursor location
  vim.keymap.set("n", "e", function()
    local s = get_active_session()
    if not s then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local frame_idx = cursor[1]
    if s.frames and frame_idx >= 1 and frame_idx <= #s.frames then
      require("unwind").replace_frame_in_session(s, frame_idx)
    end
  end, key_opts)

  -- s : Save session to disk
  vim.keymap.set("n", "s", function()
    local s = get_active_session()
    if s then
      require("unwind").prompt_save_session(s)
    end
  end, key_opts)

  -- r : Refresh file availability
  vim.keymap.set("n", "r", function()
    require("unwind").refresh_availability()
  end, key_opts)

  -- E : Export session to Markdown
  vim.keymap.set("n", "E", function()
    local s = get_active_session()
    require("unwind").export(s)
  end, key_opts)

  -- / or <leader>f : Open fuzzy finder
  vim.keymap.set("n", "/", function()
    require("unwind").search()
  end, key_opts)

  vim.keymap.set("n", "<leader>f", function()
    require("unwind").search()
  end, key_opts)

  -- q : Close window (triggers unsynchronized-changes guard)
  vim.keymap.set("n", "q", function()
    local s = get_active_session()
    if s and M.has_unsynced_changes(buf, s) then
      local choice = vim.fn.confirm("Call trace has unsynchronized changes. Synchronize before closing?", "&Yes\n&No\n&Cancel", 1)
      if choice == 1 then
        local ok = M.synchronize(buf, s, { skip_confirm = true })
        if not ok then
          return
        end
      elseif choice == 2 then
        vim.bo[buf].modified = false
        M.render(s, buf)
      else
        return
      end
    end

    local sidebar = require("unwind.sidebar")
    local cur_win = vim.api.nvim_get_current_win()
    local tracked_sidebar_win = sidebar.get_sidebar_win()

    if tracked_sidebar_win and cur_win == tracked_sidebar_win then
      sidebar.hide()
      local src = sidebar.get_source_window()
      if src and vim.api.nvim_win_is_valid(src) then
        pcall(vim.api.nvim_set_current_win, src)
      end
    else
      local win_count = #vim.api.nvim_list_wins()
      if win_count > 1 then
        pcall(vim.cmd, "close")
      else
        pcall(vim.cmd, "buffer #")
      end
    end
  end, key_opts)
end

return M
