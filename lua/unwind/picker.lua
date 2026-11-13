---@module "unwind.picker"
--- Pluggable fuzzy finder and quick search interface for unwind.nvim.
--- Supports fzf-lua, telescope, snacks, mini.pick, and vim.ui.select fallback.

local navigation = require("unwind.navigation")
local session_actions = require("unwind.session_actions")
local hooks = require("unwind.hooks")
local state = require("unwind.state")

local M = {}

--- Returns normalized items for active session or provided session
---@param session? table Defaults to state.current()
---@param opts? { all?: boolean }
---@return table[] items
function M.get_items(session, opts)
  session = session or state.current()
  opts = opts or {}
  if not session then
    return {}
  end

  local frames
  if opts.all or not session.filter_enabled then
    frames = session.raw_frames or {}
  else
    frames = session.frames or {}
  end

  local items = {}
  local root = session.root or state.get_root()

  for idx, frame in ipairs(frames) do
    local file = frame.file or frame.path or ""
    local line = frame.line or 1
    local col = frame.col or frame.column or 1
    local method = frame.method or ""
    local origin = frame.origin or "stacktrace"
    local note = frame.note
    local uid = frame.uid

    -- Resolve canonical path & availability
    local resolved_path = frame.resolved_path
    if not resolved_path or resolved_path == "" then
      resolved_path = frame.path or frame.file
    end
    if resolved_path and not require("unwind.path").is_absolute(resolved_path) then
      resolved_path = vim.fs.normalize(root .. "/" .. resolved_path)
    end

    local file_entry = (frame.file_index and session.files) and session.files[frame.file_index] or nil
    local is_available = true
    if file_entry and file_entry.available ~= nil then
      is_available = file_entry.available
    elseif frame.navigable ~= nil then
      is_available = frame.navigable
    else
      local check_ok, avail = pcall(navigation.check_file_availability, resolved_path or file, root)
      if check_ok then
        is_available = avail
      end
    end

    local method_label = (method and method ~= "") and method or "<anonymous>"
    local note_suffix = (note and note ~= "") and ("  [" .. note .. "]") or ""
    local display = string.format("%2d  %s  %s:%d%s", idx, method_label, file, line, note_suffix)

    table.insert(items, {
      index = idx,
      raw_index = frame.raw_index or idx,
      uid = uid,
      file = file,
      resolved_path = resolved_path,
      line = line,
      col = col,
      method = method,
      origin = origin,
      note = note,
      available = is_available,
      display = display,
      frame = frame,
      session = session,
    })
  end

  return items
end

--- Build standard action handlers for a session
---@param session table
---@param config table
---@return table actions
function M.build_actions(session, config)
  local unwind = require("unwind")
  return {
    jump = function(item)
      if not item then
        return
      end
      local cur_sess = state.current() or session
      local target_idx = nil
      for d_idx, f in ipairs(cur_sess.frames or {}) do
        if f == item.frame or (item.uid and f.uid == item.uid) or (f.raw_index and f.raw_index == item.raw_index) then
          target_idx = d_idx
          break
        end
      end
      if not target_idx then
        target_idx = item.index
      end
      navigation.jump_to_frame(cur_sess, target_idx)
    end,
    delete = function(item)
      if not item then
        return
      end
      local cur_sess = state.current() or session
      local target_idx = nil
      for d_idx, f in ipairs(cur_sess.frames or {}) do
        if f == item.frame or (item.uid and f.uid == item.uid) or (f.raw_index and f.raw_index == item.raw_index) then
          target_idx = d_idx
          break
        end
      end
      if target_idx then
        unwind.delete_frame_from_session(cur_sess, target_idx)
      elseif item.raw_index then
        local saved_sessions = state.ensure_sessions_loaded(cur_sess.root)
        require("unwind.sessions").remove_frame(cur_sess, item.raw_index, saved_sessions)
        session_actions.rebuild_derived(cur_sess, config)
        session_actions.refresh_active_presentation(cur_sess)
      end
    end,
    annotate = function(item)
      if not item then
        return
      end
      local cur_sess = state.current() or session
      unwind.annotate(item.frame or item.index, cur_sess)
    end,
  }
end

--- Execute search picker
---@param opts? { picker?: string|function, all?: boolean }
function M.search(opts)
  opts = opts or {}
  local session = state.current()
  if not session or ((not session.frames or #session.frames == 0) and (not session.raw_frames or #session.raw_frames == 0)) then
    vim.notify("Unwind: No active session or frames to search.", vim.log.levels.WARN)
    return
  end

  local unwind = require("unwind")
  local config = unwind.config or {}
  local items = M.get_items(session, opts)
  if #items == 0 then
    vim.notify("Unwind: No frames available to search.", vim.log.levels.WARN)
    return
  end

  local actions = M.build_actions(session, config)

  -- 1. Explicit picker override in opts or config
  local backend = opts.picker or config.picker or "auto"

  if type(backend) == "function" then
    backend(items, actions)
    return
  end

  -- Check registered picker in hooks
  local registered = hooks.get_picker(backend)
  if registered then
    registered(items, actions)
    return
  end

  local function do_jump(item)
    actions.jump(item)
  end

  -- 2. fzf-lua
  if backend == "fzf-lua" or (backend == "auto" and pcall(require, "fzf-lua")) then
    local ok, fzf = pcall(require, "fzf-lua")
    if ok and fzf and fzf.fzf_exec then
      local entries = {}
      local entry_map = {}
      for _, it in ipairs(items) do
        table.insert(entries, it.display)
        entry_map[it.display] = it
      end

      fzf.fzf_exec(entries, {
        prompt = "Unwind Trace> ",
        actions = {
          ["default"] = function(selected)
            if selected and selected[1] then
              local it = entry_map[selected[1]]
              if it then
                do_jump(it)
              end
            end
          end,
          ["ctrl-d"] = function(selected)
            if selected and selected[1] then
              local it = entry_map[selected[1]]
              if it then
                actions.delete(it)
              end
            end
          end,
          ["ctrl-a"] = function(selected)
            if selected and selected[1] then
              local it = entry_map[selected[1]]
              if it then
                actions.annotate(it)
              end
            end
          end,
        },
        previewer = false,
        preview = function(selected, _opts, fzf_cb)
          if not selected or not selected[1] then
            fzf_cb(nil)
            return
          end
          local it = entry_map[selected[1]]
          if not it or not it.resolved_path then
            fzf_cb(nil)
            return
          end
          local path = it.resolved_path
          local target_line = it.line or 1
          local ok_read, file_lines = pcall(vim.fn.readfile, path)
          if not ok_read or not file_lines then
            fzf_cb(nil)
            return
          end
          local context = 15
          local start_line = math.max(1, target_line - context)
          local end_line = math.min(#file_lines, target_line + context)
          for i = start_line, end_line do
            local prefix = (i == target_line) and "> " or "  "
            fzf_cb(string.format("%s%4d %s", prefix, i, file_lines[i] or ""))
          end
          fzf_cb(nil)
        end,
      })
      return
    elseif backend == "fzf-lua" then
      vim.notify("Unwind: fzf-lua is configured but not available.", vim.log.levels.ERROR)
      return
    end
  end

  -- 3. telescope
  if backend == "telescope" or (backend == "auto" and pcall(require, "telescope.pickers")) then
    local ok_pickers, pickers = pcall(require, "telescope.pickers")
    local ok_finders, finders = pcall(require, "telescope.finders")
    local ok_conf, conf = pcall(require, "telescope.config")
    local ok_actions, tele_actions = pcall(require, "telescope.actions")
    local ok_action_state, action_state = pcall(require, "telescope.actions.state")

    if ok_pickers and ok_finders and ok_conf and ok_actions and ok_action_state then
      pickers.new({}, {
        prompt_title = "Unwind Call Trace",
        finder = finders.new_table({
          results = items,
          entry_maker = function(entry)
            return {
              value = entry,
              display = entry.display,
              ordinal = entry.display,
              filename = entry.resolved_path or entry.file,
              lnum = entry.line,
              col = entry.col,
            }
          end,
        }),
        previewer = conf.values.grep_previewer({}),
        sorter = conf.values.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, _map)
          tele_actions.select_default:replace(function()
            tele_actions.close(prompt_bufnr)
            local selection = action_state.get_selected_entry()
            if selection and selection.value then
              do_jump(selection.value)
            end
          end)
          return true
        end,
      }):find()
      return
    elseif backend == "telescope" then
      vim.notify("Unwind: telescope is configured but not available.", vim.log.levels.ERROR)
      return
    end
  end

  -- 4. snacks
  if backend == "snacks" or (backend == "auto" and _G.Snacks and _G.Snacks.picker) then
    if _G.Snacks and _G.Snacks.picker then
      local snacks_items = {}
      for _, it in ipairs(items) do
        table.insert(snacks_items, {
          text = it.display,
          file = it.resolved_path or it.file,
          pos = { it.line, math.max(0, it.col - 1) },
          item = it,
        })
      end
      _G.Snacks.picker({
        title = "Unwind Call Trace",
        items = snacks_items,
        confirm = function(picker, sel)
          picker:close()
          if sel and sel.item then
            do_jump(sel.item)
          end
        end,
      })
      return
    elseif backend == "snacks" then
      vim.notify("Unwind: snacks.picker is configured but not available.", vim.log.levels.ERROR)
      return
    end
  end

  -- 5. mini.pick
  if backend == "mini.pick" or (backend == "auto" and pcall(require, "mini.pick")) then
    local ok_mini, mini_pick = pcall(require, "mini.pick")
    if ok_mini and mini_pick and mini_pick.start then
      local mini_items = {}
      for _, it in ipairs(items) do
        table.insert(mini_items, {
          text = it.display,
          path = it.resolved_path or it.file,
          line = it.line,
          col = it.col,
          item = it,
        })
      end
      mini_pick.start({
        source = {
          items = mini_items,
          name = "Unwind Call Trace",
          preview = mini_pick.default_preview,
          choose = function(chosen)
            if chosen and chosen.item then
              do_jump(chosen.item)
            end
          end,
        },
      })
      return
    elseif backend == "mini.pick" then
      vim.notify("Unwind: mini.pick is configured but not available.", vim.log.levels.ERROR)
      return
    end
  end

  -- 6. vim.ui.select fallback
  vim.ui.select(items, {
    prompt = "Unwind Call Trace",
    format_item = function(it)
      return it.display
    end,
  }, function(choice)
    if choice then
      do_jump(choice)
    end
  end)
end

return M
