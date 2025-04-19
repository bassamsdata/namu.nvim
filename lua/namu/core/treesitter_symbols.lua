--[[ This is Ecpermintanl and we'll be revisited often next, still needs
tests, move to queries totally?, add types
]]
local api = vim.api
local ts_queries = require("namu.core.treesitter_queries")
local M = {}

-- Map definition types to LSP SymbolKind names
local kind_mapping = {
  ["function"] = "Function",
  ["method"] = "Method",
  ["class"] = "Class",
  ["struct"] = "Struct",
  ["interface"] = "Interface",
  ["module"] = "Module",
  ["namespace"] = "Namespace",
  ["variable"] = "Variable",
  ["constant"] = "Constant",
  ["field"] = "Field",
  ["property"] = "Property",
  ["enum"] = "Enum",
  ["enumMember"] = "EnumMember",
  ["type"] = "TypeParameter",
  ["import"] = "Module",
  ["macro"] = "Function",
}
local default_kind = "Variable"
-- Filetypes that need special handling
local special_filetypes = {
  typescript = true,
  javascript = true,
  json = true,
  -- org = true,
  vimdoc = true,
  markdown = true,
}

-- Extract name from node using query captures
local function extract_name_from_captures(node, query, bufnr)
  -- Look for name capture
  for id, node_inner, _ in query:iter_captures(node, bufnr) do
    if query.captures[id] == "name" then
      return vim.treesitter.get_node_text(node_inner, bufnr)
    end
  end
  -- Look for string capture if name not found
  for id, node_inner, _ in query:iter_captures(node, bufnr) do
    if query.captures[id] == "string" then
      return vim.treesitter.get_node_text(node_inner, bufnr)
    end
  end
  -- Fallback to first line of node text
  local text = vim.treesitter.get_node_text(node, bufnr) or ""
  local first_line = text:match("^([^\n]+)") or ""
  if #first_line > 50 then
    return first_line:sub(1, 47) .. "..."
  end
  return first_line
end

-- Get kind from metadata
local function get_kind_from_metadata(node, captures_by_id)
  if not captures_by_id[tostring(node:id())] then
    return default_kind
  end
  for _, capture in ipairs(captures_by_id[tostring(node:id())]) do
    if capture.metadata and capture.metadata["kind"] then
      return capture.metadata["kind"]
    end
  end
  return default_kind
end

-- Create a symbol from a node
local function create_symbol_from_node(node, name, kind, bufnr)
  local range = { node:range() }
  if not (range[1] and range[2] and range[3] and range[4]) then
    return nil
  end
  return {
    id = tostring(node:id()),
    name = name,
    node = node,
    range = {
      start = { line = range[1], character = range[2] },
      ["end"] = { line = range[3], character = range[4] },
    },
    kind = kind_mapping[kind] or kind,
    children = {},
  }
end

-- Collect captures by node ID
local function collect_captures(query, root_node, bufnr)
  local captures_by_id = {}
  for id, node, metadata in query:iter_captures(root_node, bufnr) do
    local capture_name = query.captures[id]
    if not captures_by_id[tostring(node:id())] then
      captures_by_id[tostring(node:id())] = {}
    end
    table.insert(captures_by_id[tostring(node:id())], {
      name = capture_name,
      metadata = metadata,
    })
  end
  return captures_by_id
end

-- Collect symbols from custom query
local function collect_symbols_from_query(query, root_node, bufnr)
  local symbols = {}
  local seen_symbols = {}
  local captures_by_id = collect_captures(query, root_node, bufnr)
  -- Find all symbol nodes
  for id, node, _ in query:iter_captures(root_node, bufnr) do
    local capture_name = query.captures[id]
    if capture_name == "symbol" and not seen_symbols[tostring(node:id())] then
      seen_symbols[tostring(node:id())] = true
      local name = extract_name_from_captures(node, query, bufnr)
      local kind = get_kind_from_metadata(node, captures_by_id)
      -- Create symbol if we have a valid name
      if name and name ~= "" then
        local symbol = create_symbol_from_node(node, name, kind, bufnr)
        if symbol then
          table.insert(symbols, symbol)
        end
      end
    end
  end
  return symbols
end

local function contains(range_a, range_b)
  local a_start = range_a.start
  local a_end = range_a["end"]
  local b_start = range_b.start
  local b_end = range_b["end"]

  -- Check start line/char
  local starts_after = b_start.line > a_start.line
    or (b_start.line == a_start.line and b_start.character >= a_start.character)
  -- Check end line/char
  local ends_before = b_end.line < a_end.line or (b_end.line == a_end.line and b_end.character <= a_end.character)

  return starts_after and ends_before
end

-- Build hierarchy from flat list of symbols
local function build_hierarchy_from_symbols(symbols)
  if not symbols or #symbols == 0 then
    return {}
  end
  -- Sort symbols by start position (line, then character)
  table.sort(symbols, function(a, b)
    if a.range.start.line == b.range.start.line then
      return a.range.start.character < b.range.start.character
    end
    return a.range.start.line < b.range.start.line
  end)
  local root_symbols = {}
  local stack = {} -- Stack to keep track of potential parent symbols
  for _, symbol in ipairs(symbols) do
    -- Pop symbols from stack that cannot contain the current symbol
    while #stack > 0 and not contains(stack[#stack].range, symbol.range) do
      table.remove(stack)
    end
    if #stack > 0 then
      -- Top of stack is the parent
      local parent = stack[#stack]
      table.insert(parent.children, symbol)
    else
      -- No containing parent found on stack, it's a root symbol
      table.insert(root_symbols, symbol)
    end
    table.insert(stack, symbol)
  end

  return root_symbols
end

-- Process custom queries for special filetypes
local function get_symbols_custom(bufnr, filetype)
  local query_string = ts_queries.get_query_for_filetype(filetype)
  if not query_string then
    return {}
  end
  local lang = vim.treesitter.language.get_lang(filetype)
  if not lang then
    return {}
  end
  local parser = vim.treesitter.get_parser(bufnr, lang)
  if not parser then
    return {}
  end
  local ok, query = pcall(vim.treesitter.query.parse, lang, query_string)
  if not ok then
    return {}
  end
  parser:parse(true)
  local tree = parser:parse()[1]
  if not tree then
    return {}
  end
  local symbols = collect_symbols_from_query(query, tree:root(), bufnr)
  return build_hierarchy_from_symbols(symbols)
end

-- Simple symbol creation from a node
local function create_symbol(node, bufnr, capture_name)
  -- Get range information
  local range = { node:range() }
  if not (range[1] and range[2] and range[3] and range[4]) then
    return nil
  end
  -- Get name from first identifier child or fallback to node text
  local name = ""
  for i = 0, node:named_child_count() - 1 do
    local child = node:named_child(i)
    if child:type() == "identifier" then
      name = vim.treesitter.get_node_text(child, bufnr) or ""
      break
    end
  end
  -- If no identifier found, use first line of node text
  if name == "" then
    local text = vim.treesitter.get_node_text(node, bufnr) or ""
    name = text:match("^([^\n]+)") or ""
    if #name > 50 then
      name = name:sub(1, 47) .. "..."
    end
  end
  if name == "" then
    return nil
  end
  -- Set symbol properties
  -- @Thanks to folke for this
  local def_type = capture_name:match("^local%.definition%.(.*)$")
  local node_type = node:type()
  local symbol = {
    id = tostring(node:id()),
    name = name,
    node = node,
    range = {
      start = { line = range[1], character = range[2] },
      ["end"] = { line = range[3], character = range[4] },
    },
    children = {},
  }
  -- Set type and kind
  if def_type then
    symbol.kind = kind_mapping[def_type] or default_kind
    symbol.type = "definition"
  else
    symbol.type = "scope"
    symbol.kind = "Namespace"
    -- Set kind based on node type
    if node_type:match("class") then
      symbol.kind = "Class"
    elseif node_type:match("interface") then
      symbol.kind = "Interface"
    elseif node_type:match("function") then
      symbol.kind = "Function"
    elseif node_type:match("method") then
      symbol.kind = "Method"
    end
  end
  return symbol
end

-- @Thanks to folke snacks treesiteer for the idea of "locals"
-- basically this borrowed from snacks so credit to snacks.nvim
-- Get symbols using standard "locals" query
local function get_symbols_standard(bufnr)
  local definitions = {}
  local scopes = {}
  local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
  if not lang then
    return {}, {}
  end
  local ok, query = pcall(vim.treesitter.query.get, lang, "locals")
  if not ok or not query then
    return {}, {}
  end
  local parser = vim.treesitter.get_parser(bufnr, lang)
  if not parser then
    return {}, {}
  end
  parser:parse(true)
  local seen_defs = {}
  -- Process query captures
  for _, tree in ipairs(parser:trees()) do
    for id, node, meta in query:iter_captures(tree:root(), bufnr) do
      local capture_name = query.captures[id]
      -- Process scopes that are meaningful
      if capture_name == "local.scope" then
        local node_type = node:type()
        local is_meaningful = node_type:match("class")
          or node_type:match("function")
          or node_type:match("method")
          or node_type:match("interface")
          or node_type:match("namespace")
          or node_type:match("module")
        if is_meaningful then
          local symbol = create_symbol(node, bufnr, capture_name)
          if symbol then
            scopes[symbol.id] = symbol
          end
        end
      -- Process definitions (skip parameters)
      elseif capture_name:match("^local%.definition%.") and not capture_name:match("parameter") then
        local symbol = create_symbol(node, bufnr, capture_name)
        if symbol then
          -- Avoid duplicates
          local pos_key = symbol.range.start.line .. ":" .. symbol.range.start.character
          if not seen_defs[pos_key] then
            seen_defs[pos_key] = true
            definitions[symbol.id] = symbol
          end
        end
      end
    end
  end
  return definitions, scopes
end

-- Find parent scope for a node
local function find_parent_scope(node, scopes)
  local current = node:parent()
  while current do
    local id = tostring(current:id())
    if scopes[id] then
      return scopes[id]
    end
    current = current:parent()
  end
  return nil
end

-- Build symbol hierarchy
local function build_hierarchy(definitions, scopes)
  -- Find definitions that match scopes
  for _, scope in pairs(scopes) do
    for _, def in pairs(definitions) do
      -- Only consider definitions that start on same line as scope
      if
        def.range.start.line == scope.range.start.line
        and def.range.start.character > scope.range.start.character
        and def.range.start.character < scope.range.start.character + 20
      then
        -- Use definition's name for scope
        scope.name = def.name
        scope.kind = def.kind
        def.is_scope_name = true
        break
      end
    end
  end

  -- Add definitions to their parent scopes
  for _, def in pairs(definitions) do
    if not def.is_scope_name then
      local parent = find_parent_scope(def.node, scopes)
      if parent then
        table.insert(parent.children, def)
      end
    end
  end
  -- Build scope hierarchy
  local root_symbols = {}
  for id, scope in pairs(scopes) do
    local parent = find_parent_scope(scope.node, scopes)
    if parent and parent.id ~= id then
      table.insert(parent.children, scope)
    else
      table.insert(root_symbols, scope)
    end
  end
  -- Add orphaned definitions as root items
  if #root_symbols == 0 then
    for def_id, def in pairs(definitions) do
      if not def.is_scope_name and not find_parent_scope(def.node, scopes) then
        table.insert(root_symbols, def)
      end
    end
  end

  return root_symbols
end

-- Sort symbols by position
local function sort_symbols(symbols)
  table.sort(symbols, function(a, b)
    if a.range.start.line == b.range.start.line then
      return a.range.start.character < b.range.start.character
    end
    return a.range.start.line < b.range.start.line
  end)
  for _, symbol in ipairs(symbols) do
    if #symbol.children > 0 then
      sort_symbols(symbol.children)
    end
  end
end
-- Clean node references
local function clean_nodes(symbols)
  for _, symbol in ipairs(symbols) do
    symbol.node = nil
    if symbol.children and #symbol.children > 0 then
      clean_nodes(symbol.children)
    end
  end
end

-- Main function to get symbols
function M.get_symbols(bufnr)
  if not api.nvim_buf_is_valid(bufnr) or not api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  local filetype = vim.bo[bufnr].filetype
  local root_symbols
  -- Choose symbol extraction method based on filetype
  if special_filetypes[filetype] and ts_queries.get_query_for_filetype(filetype) then
    root_symbols = get_symbols_custom(bufnr, filetype)
  else
    local definitions, scopes = get_symbols_standard(bufnr)
    root_symbols = build_hierarchy(definitions, scopes)
  end
  if root_symbols and #root_symbols > 0 then
    sort_symbols(root_symbols)
    clean_nodes(root_symbols)
    return root_symbols
  end

  return nil
end

return M
