---@module "unwind.location"
--- Tree-sitter function and declaration resolver with graceful fallback to cursor location.

local M = {}

--- Language adapters for AST function nodes and name extraction
M.adapters = {
  lua = {
    function_nodes = {
      function_declaration = true,
      function_definition = true,
    },
    get_name = function(node, bufnr)
      local names = node:field("name")
      if names and names[1] then
        return vim.treesitter.get_node_text(names[1], bufnr)
      end
      return nil
    end,
  },
  python = {
    function_nodes = {
      function_definition = true,
    },
    get_name = function(node, bufnr)
      local names = node:field("name")
      if names and names[1] then
        return vim.treesitter.get_node_text(names[1], bufnr)
      end
      return nil
    end,
  },
  javascript = {
    function_nodes = {
      function_declaration = true,
      function_expression = true,
      method_definition = true,
      arrow_function = true,
    },
    get_name = function(node, bufnr)
      local names = node:field("name")
      if names and names[1] then
        return vim.treesitter.get_node_text(names[1], bufnr)
      end
      -- For arrow functions assigned to variables: const foo = () => ...
      local parent = node:parent()
      if parent and parent:type() == "variable_declarator" then
        local pnames = parent:field("name")
        if pnames and pnames[1] then
          return vim.treesitter.get_node_text(pnames[1], bufnr)
        end
      end
      return nil
    end,
  },
  typescript = {
    function_nodes = {
      function_declaration = true,
      function_expression = true,
      method_definition = true,
      arrow_function = true,
    },
    get_name = function(node, bufnr)
      local names = node:field("name")
      if names and names[1] then
        return vim.treesitter.get_node_text(names[1], bufnr)
      end
      local parent = node:parent()
      if parent and parent:type() == "variable_declarator" then
        local pnames = parent:field("name")
        if pnames and pnames[1] then
          return vim.treesitter.get_node_text(pnames[1], bufnr)
        end
      end
      return nil
    end,
  },
  rust = {
    function_nodes = {
      function_item = true,
      closure_expression = true,
    },
    get_name = function(node, bufnr)
      local names = node:field("name")
      if names and names[1] then
        return vim.treesitter.get_node_text(names[1], bufnr)
      end
      return nil
    end,
  },
  go = {
    function_nodes = {
      function_declaration = true,
      method_declaration = true,
      func_literal = true,
    },
    get_name = function(node, bufnr)
      local names = node:field("name")
      if names and names[1] then
        return vim.treesitter.get_node_text(names[1], bufnr)
      end
      return nil
    end,
  },
  c = {
    function_nodes = {
      function_definition = true,
    },
    get_name = function(node, bufnr)
      local declarator = node:field("declarator")[1]
      if declarator then
        local name_node = declarator:field("declarator")[1] or declarator
        return vim.treesitter.get_node_text(name_node, bufnr)
      end
      return nil
    end,
  },
  cpp = {
    function_nodes = {
      function_definition = true,
    },
    get_name = function(node, bufnr)
      local declarator = node:field("declarator")[1]
      if declarator then
        local name_node = declarator:field("declarator")[1] or declarator
        return vim.treesitter.get_node_text(name_node, bufnr)
      end
      return nil
    end,
  },
  ruby = {
    function_nodes = {
      method = true,
      singleton_method = true,
    },
    get_name = function(node, bufnr)
      local names = node:field("name")
      if names and names[1] then
        return vim.treesitter.get_node_text(names[1], bufnr)
      end
      return nil
    end,
  },
}

--- Generic function node check for languages without explicit adapter
M.generic_function_types = {
  ["function_definition"] = true,
  ["function_declaration"] = true,
  ["method_definition"] = true,
  ["method_declaration"] = true,
  ["function_item"] = true,
  ["function"] = true,
  ["method"] = true,
}

--- Check if AST node is a function or method definition
---@param lang string
---@param node any
---@return boolean
function M.is_function_node(lang, node)
  if not node then return false end
  local node_type = node:type()
  local adapter = M.adapters[lang]
  if adapter and adapter.function_nodes then
    return adapter.function_nodes[node_type] == true
  end
  return M.generic_function_types[node_type] == true
end

--- Extract function name from node using adapter or standard name field
---@param lang string
---@param node any
---@param bufnr integer
---@return string?
function M.get_function_name(lang, node, bufnr)
  if not node then return nil end
  local adapter = M.adapters[lang]
  if adapter and adapter.get_name then
    local ok, name = pcall(adapter.get_name, node, bufnr)
    if ok and name and name ~= "" then
      return name
    end
  end

  local ok_field, names = pcall(function() return node:field("name") end)
  if ok_field and names and names[1] then
    local ok_text, text = pcall(vim.treesitter.get_node_text, names[1], bufnr)
    if ok_text and text and text ~= "" then
      return text
    end
  end

  return nil
end

--- Resolves source location from current cursor position
--- Uses Tree-sitter when available to resolve enclosing function declaration line and name.
--- Falls back gracefully to cursor position.
---@param opts? { bufnr?: integer, row?: integer, col?: integer, root?: string, resolve_function?: boolean }
---@return table frame_data
function M.from_cursor(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local row = opts.row or vim.api.nvim_win_get_cursor(0)[1]
  local col = opts.col or (vim.api.nvim_win_get_cursor(0)[2] + 1)
  local root = opts.root or vim.fs.normalize(vim.fn.getcwd())
  local resolve_fn = (opts.resolve_function ~= false)
  -- New option: resolution mode (smart, scope, function, exact)
  local mode = opts.mode or "smart"

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local rel_path = bufname
  if vim.startswith(bufname, root .. "/") then
    rel_path = bufname:sub(#root + 2)
  end

  -- Default fallback frame
  local frame = {
    path = bufname,
    file = rel_path,
    line = row,
    col = col,
    column = col,
    method = nil,
    origin = "manual",
    raw_line = string.format("%s:%d:%d", rel_path, row, col),
    anchor_kind = "exact",
    label = nil,
  }

  if mode == "exact" then
    -- Return exact cursor location without further resolution
    return frame
  end

  if not resolve_fn or not vim.treesitter or not vim.treesitter.get_parser then
    return frame
  end

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not parser then
    return frame
  end

  -- Ensure fresh tree
  pcall(function() parser:parse() end)

  local ts_row = math.max(0, row - 1)
  local ts_col = math.max(0, col - 1)

  local node = nil
  if vim.treesitter.get_node then
    local ok_node, n = pcall(vim.treesitter.get_node, {
      bufnr = bufnr,
      pos = { ts_row, ts_col },
    })
    if ok_node then
      node = n
    end
  end

  if not node then
    return frame
  end

  local lang = parser:lang()

  -- Helper to set frame from a given node
  local function set_frame_from_node(target_node, kind, label)
    local start_row, start_col = target_node:range()
    frame.line = start_row + 1
    frame.col = start_col + 1
    frame.column = start_col + 1
    frame.anchor_kind = kind
    frame.label = label
    if kind ~= "exact" then
      local method_name = M.get_function_name(lang, target_node, bufnr)
      frame.method = method_name
    end
    frame.raw_line = string.format("%s:%d:%d%s", rel_path, frame.line, frame.col,
      label and (" at " .. label) or "")
  end

  -- Ruby specific scope detection
  if lang == "ruby" then
    -- If node is a call with a block, use it as scope
    local function is_call_with_block(n)
      if not n then return false end
      if n:type() ~= "call" then return false end
      -- Look for do_block or block child
      for child in n:iter_children() do
        local t = child:type()
        if t == "do_block" or t == "block" then
          return true, child
        end
      end
      return false, nil
    end
    local is_call, block_node = is_call_with_block(node)
    if is_call then
      -- Use the call node as anchor if mode permits
      if mode == "smart" or mode == "scope" then
        local call_text = vim.treesitter.get_node_text(node, bufnr)
        set_frame_from_node(node, "scope", call_text)
        return frame
      end
    end
    -- If cursor is inside a block, climb to the call node
    if mode ~= "exact" then
      local cur = node
      while cur do
        local parent = cur:parent()
        if not parent then break end
        local is_parent_call, _ = is_call_with_block(parent)
        if is_parent_call then
          local call_text = vim.treesitter.get_node_text(parent, bufnr)
          set_frame_from_node(parent, "scope", call_text)
          return frame
        end
        cur = parent
      end
    end
  end

  -- Existing function resolution (fallback)
  local current = node
  while current do
    if M.is_function_node(lang, current) then
      set_frame_from_node(current, "function", nil)
      return frame
    end
    current = current:parent()
  end

  return frame
end
  

return M
