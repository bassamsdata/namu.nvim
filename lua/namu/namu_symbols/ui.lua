local M = {}

-- Internal state for UI operations
local state = {
  preview_ns = vim.api.nvim_create_namespace("namu_preview"),
}

local ns_id = vim.api.nvim_create_namespace("namu_symbols")

-- Cache for symbol ranges
local symbol_range_cache = {}

function M.setup_highlights()
  local highlights = {
    NamuPrefixSymbol = { link = "@Comment" },
    NamuSymbolFunction = { link = "@function" },
    NamuSymbolMethod = { link = "@function.method" },
    NamuSymbolClass = { link = "@lsp.type.class" },
    NamuSymbolInterface = { link = "@lsp.type.interface" },
    NamuSymbolVariable = { link = "@lsp.type.variable" },
    NamuSymbolConstant = { link = "@lsp.type.constant" },
    NamuSymbolProperty = { link = "@lsp.type.property" },
    NamuSymbolField = { link = "@lsp.type.field" },
    NamuSymbolEnum = { link = "@lsp.type.enum" },
    NamuSymbolModule = { link = "@lsp.type.module" },
  }

  for name, attrs in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, attrs)
  end
end

function M.clear_preview_highlight(win, ns_id)
  if ns_id then
    local bufnr = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
end

-- Style options for nested items
---@param depth number
---@param style number 1: Just indentation, 2: Dot style, 3: Arrow style
---@return string
function M.get_prefix(depth, style)
  local prefix = depth == 0 and ""
    or (
      style == 1 and string.rep("  ", depth)
      or style == 2 and string.rep("  ", depth - 1) .. ".."
      or style == 3 and string.rep("  ", depth - 1) .. " →"
      or string.rep("  ", depth)
    )

  return prefix
end

---Finds index of symbol at current cursor position
---@param items SelectaItem[] The filtered items list
---@param symbol SelectaItem table The symbol to find
---@return number|nil index The index of the symbol if found
function M.find_symbol_index(items, symbol)
  for i, item in ipairs(items) do
    if
      item.value.lnum == symbol.value.lnum
      and item.value.col == symbol.value.col
      and item.value.name == symbol.value.name
    then
      return i
    end
  end
  return nil
end

---Traverses syntax tree to find significant nodes for better symbol context
---@param node TSNode The treesitter node
---@param lnum number The line number (0-based)
---@return TSNode|nil
function M.find_meaningful_node(node, lnum)
  if not node then
    return nil
  end

  local function starts_at_line(n)
    local start_row = select(1, n:range())
    return start_row == lnum
  end

  local current = node
  local target_node = node
  while current and starts_at_line(current) do
    target_node = current
    ---@diagnostic disable-next-line: undefined-field
    current = current:parent()
  end

  ---@diagnostic disable-next-line: undefined-field
  local type = target_node:type()

  local filetype = vim.o.filetype
  -- TODO: this is hack for python first method highlight. I need to test it in rust or TS or ruby
  if filetype == "python" then
    if type == "block" then
      return node
    end
  end
  if type == "function_definition" then
    return node
  end

  if type == "assignment_statement" then
    ---@diagnostic disable-next-line: undefined-field
    local expr_list = target_node:field("rhs")[1]
    if expr_list then
      for i = 0, expr_list:named_child_count() - 1 do
        local child = expr_list:named_child(i)
        if child and child:type() == "function_definition" then
          return target_node
        end
      end
    end
  end

  if type == "local_function" or type == "function_declaration" then
    return target_node
  end

  if type == "local_declaration" then
    ---@diagnostic disable-next-line: undefined-field
    local values = target_node:field("values")
    if values and values[1] and values[1]:type() == "function_definition" then
      return target_node
    end
  end

  if type == "method_definition" then
    return target_node
  end

  return target_node
end

---Handles visual highlighting of selected symbols in preview
---@param symbol table LSP symbol item
---@param win number Window handle
function M.highlight_symbol(symbol, win, ns_id)
  local picker_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

  local bufnr = vim.api.nvim_win_get_buf(win)
  local line = vim.api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.lnum, false)[1]
  local first_char_col = line:find("%S")
  if not first_char_col then
    return
  end
  first_char_col = first_char_col - 1

  local node = vim.treesitter.get_node({
    pos = { symbol.lnum - 1, first_char_col },
    ignore_injections = false,
  })

  if node then
    node = M.find_meaningful_node(node, symbol.lnum - 1)
  end

  if node then
    local srow, scol, erow, ecol = node:range()

    vim.api.nvim_buf_set_extmark(bufnr, ns_id, srow, 0, {
      end_row = erow,
      end_col = ecol,
      hl_group = M.config.highlight,
      hl_eol = true,
      priority = 1,
      strict = false,
    })

    vim.api.nvim_win_set_cursor(win, { srow + 1, scol })
    vim.cmd("normal! zz")
  end

  vim.api.nvim_set_current_win(picker_win)
end

function M.apply_kind_highlights(buf, items, config)
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  for idx, item in ipairs(items) do
    local line = idx - 1
    local kind = item.kind
    local hl_group = config.kinds.highlights[kind]

    if hl_group then
      local line_text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
      if not line_text then
        goto continue
      end

      if item.depth and item.depth > 0 then
        local prefix = M.get_prefix(item.depth, config.display.style or 2)
        local prefix_symbol = config.display.style == 2 and ".." or (config.display.style == 3 and "→" or nil)

        if prefix_symbol then
          local symbol_pos = line_text:find(prefix_symbol, 1, true)
          if symbol_pos then
            vim.api.nvim_buf_set_extmark(buf, ns_id, line, symbol_pos - 1, {
              end_row = line,
              end_col = symbol_pos - 1 + #prefix_symbol,
              hl_group = config.kinds.highlights.PrefixSymbol,
              priority = 91,
              strict = false,
            })
          end
        end
      end

      local full_name = item.value.name
      local symbol_pos = line_text:find(full_name, 1, true)

      if symbol_pos then
        vim.api.nvim_buf_set_extmark(buf, ns_id, line, symbol_pos - 1, {
          end_row = line,
          end_col = symbol_pos - 1 + #full_name,
          hl_group = hl_group,
          priority = 90,
          strict = false,
        })
      end
      ::continue::
    end
  end
end

-- Initialize UI module with config
function M.setup(config)
  M.config = config
end

return M
