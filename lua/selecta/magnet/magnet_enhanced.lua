--[[ magnet.lua
Quick LSP symbol jumping with live preview and fuzzy finding.

Features:
- Fuzzy find LSP symbols
- Live preview as you move
- Auto-sized window
- Filtered by symbol kinds
- Configurable exclusions

This version includes:
1. Full integration with our enhanced `selecta` module
2. Live preview as you move through symbols
3. Proper highlight cleanup
4. Position restoration on cancel
5. Auto-sized window
6. Fuzzy finding with highlighting
7. Type annotations
8. Configurable through setup function
9. Better error handling
10. Optional keymap setup

You can enhance it further with:
1. Symbol kind icons in the display
2. More sophisticated preview behavior
3. Additional filtering options
4. Symbol documentation preview
5. Multi-select support

Usage in your Neovim config:

```lua
-- In your init.lua or similar

-- Optional: Configure selecta first
require('selecta').setup({
    window = {
        border = 'rounded',
        title_prefix = "󰍇 > ",
    }
})

-- Configure magnet
require('magnet').setup({
    -- Optional: Override default config
    includeKinds = {
        -- Add custom kinds per filetype
        python = { "Function", "Class", "Method" },
    },
    window = {
        auto_size = true,
        min_width = 50,
        padding = 2,
    },
    -- Custom highlight for preview
    highlight = "MagnetPreview",
})

-- Optional: Set up default keymaps
require('magnet').setup_keymaps()

-- Or set your own keymap
vim.keymap.set('n', 'gs', require('magnet').jump, {
    desc = "Jump to symbol"
})
```
]]

local selecta = require("selecta.selecta")
local M = {}

---@alias LSPSymbolKind string
-- ---@alias TSNode userdata
-- ---@alias vim.lsp.Client table

---@class LSPSymbol
---@field name string Symbol name
---@field kind number LSP symbol kind number
---@field range table<string, table> Symbol range in the document
---@field children? LSPSymbol[] Child symbols

---@class MagnetConfig
---@field AllowKinds table<string, string[]> Symbol kinds to include
---@field display table<string, string|number> Display configuration
---@field kindText table<string, string> Text representation of kinds
---@field kindIcons table<string, string> Icons for kinds
---@field BlockList table<string, string[]> Patterns to exclude
---@field icon string Icon for the picker
---@field highlight string Highlight group for preview
---@field highlights table<string, string> Highlight groups
---@field window table Window configuration
---@field debug boolean Enable debug logging
---@field focus_current_symbol boolean Focus the current symbol
---@field auto_select boolean Auto-select single matches
---@field row_position "center"|"top10" Window position preset
---@field multiselect table Multiselect configuration
---@field keymaps table Keymap configuration

---@class MagnetState
---@field original_win number|nil Original window
---@field original_buf number|nil Original buffer
---@field original_ft string|nil Original filetype
---@field original_pos table|nil Original cursor position
---@field preview_ns number|nil Preview namespace
---@field current_request table|nil Current LSP request ID

-- Store original window and position for preview
---@type MagnetState
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = vim.api.nvim_create_namespace("magnet_preview"),
  current_request = nil,
}

---@type MagnetConfig
M.config = {
  AllowKinds = {
    default = {
      "Function",
      "Method",
      "Class",
      "Module",
      "Property",
      "Variable",
      "Constant",
      "Enum",
      "Interface",
      "Field",
    },
    -- Filetype specific
    yaml = { "Object", "Array" },
    json = { "Module" },
    toml = { "Object" },
    markdown = { "String" },
  },
  display = {
    mode = "text", -- or "icon"
    padding = 2,
  },
  kindText = {
    Function = "function",
    Method = "method",
    Class = "class",
    Module = "module",
    Constructor = "constructor",
    Interface = "interface",
    Property = "property",
    Field = "field",
    Enum = "enum",
    Constant = "constant",
    Variable = "variable",
  },
  kindIcons = {
    File = "󰈙",
    Module = "󰏗",
    Namespace = "󰌗",
    Package = "󰏖",
    Class = "󰌗",
    Method = "󰆧",
    Property = "󰜢",
    Field = "󰜢",
    Constructor = "󰆧",
    Enum = "󰒻",
    Interface = "󰕘",
    Function = "󰊕",
    Variable = "󰀫",
    Constant = "󰏿",
    String = "󰀬",
    Number = "󰎠",
    Boolean = "󰨙",
    Array = "󰅪",
    Object = "󰅩",
    Key = "󰌋",
    Null = "󰟢",
    EnumMember = "󰒻",
    Struct = "󰌗",
    Event = "󰉁",
    Operator = "󰆕",
    TypeParameter = "󰊄",
  },
  BlockList = {
    default = {},
    -- Filetype-specific
    lua = {
      "^vim%.", -- anonymous functions passed to nvim api
      "%.%.%. :", -- vim.iter functions
      ":gsub", -- lua string.gsub
      "^callback$", -- nvim autocmds
      "^filter$",
      "^map$", -- nvim keymaps
    },
    -- python = {},
    -- rust = {}
  },
  icon = "󱠦", -- 󱠦 -  -  -- 󰚟
  highlight = "MagnetPreview",
  highlights = {
    parent = "MagnetParent",
    nested = "MagnetNested",
    style = "MagnetStyle",
  },
  window = {
    auto_size = true,
    min_width = 30,
    padding = 4,
    border = "rounded",
    show_footer = true,
    footer_pos = "right",
  },
  debug = false, -- Debug flag for both magnet and selecta
  focus_current_symbol = true, -- Add this option to control the feature
  auto_select = false,
  row_position = "center", -- options: "center"|"top10",
  multiselect = {
    enabled = true,
    indicator = "●", -- or "✓"
    keymaps = {
      toggle = "<Tab>",
      select_all = "<C-a>",
      clear_all = "<C-l>",
    },
    max_items = nil, -- No limit by default
  },
  keymaps = {
    {
      key = "<C-o>",
      handler = function(items_or_item)
        if type(items_or_item) == "table" and items_or_item[1] then
          M.add_symbol_to_codecompanion(items_or_item, state.original_buf)
        else
          -- Single item case
          M.add_symbol_to_codecompanion({ items_or_item }, state.original_buf)
        end
      end,
      desc = "Add symbol to CodeCompanion",
    },
  },
}
end

---Find the symbol that contains the cursor position
---@param items table[] Selecta items list
---@return table|nil symbol The matching symbol if found
local function find_containing_symbol(items)
  -- Cache cursor position
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local cursor_line, cursor_col = cursor_pos[1], cursor_pos[2] + 1

  -- Early exit if no items
  if #items == 0 then
    return nil
  end

  -- Binary search optimization for initial range
  ---@diagnostic disable-next-line: redefined-local
  local function binary_search_range(items, target_line)
    local left, right = 1, #items
    while left <= right do
      local mid = math.floor((left + right) / 2)
      local symbol = items[mid].value

      if symbol.lnum <= target_line and symbol.end_lnum >= target_line then
        return mid
      elseif symbol.lnum > target_line then
        right = mid - 1
      else
        left = mid + 1
      end
    end
    return left
  end

  -- Find approximate position using binary search
  local start_index = binary_search_range(items, cursor_line)

  -- Search window size
  local WINDOW_SIZE = 10
  local start_pos = math.max(1, start_index - WINDOW_SIZE)
  local end_pos = math.min(#items, start_index + WINDOW_SIZE)

  -- Find the most specific symbol within the window
  local matching_symbol = nil
  local smallest_area = math.huge

  for i = start_pos, end_pos do
    local item = items[i]
    local symbol = item.value

    -- Quick bounds check
    if not (symbol.lnum and symbol.end_lnum and symbol.col and symbol.end_col) then
      goto continue
    end

    -- Fast range check
    if cursor_line < symbol.lnum or cursor_line > symbol.end_lnum then
      goto continue
    end

    -- Detailed position check
    local in_range = (
      (cursor_line > symbol.lnum or (cursor_line == symbol.lnum and cursor_col >= symbol.col))
      and (cursor_line < symbol.end_lnum or (cursor_line == symbol.end_lnum and cursor_col <= symbol.end_col))
    )

    if in_range then
      -- Optimize area calculation
      local area = (symbol.end_lnum - symbol.lnum + 1) * 1000 + (symbol.end_col - symbol.col)
      if area < smallest_area then
        smallest_area = area
        matching_symbol = item
      end
    end

    ::continue::
  end

  return matching_symbol
end

-- Cache for symbol ranges
local symbol_range_cache = {}

-- Function to update symbol ranges cache
local function update_symbol_ranges_cache(items)
  symbol_range_cache = {}
  for i, item in ipairs(items) do
    local symbol = item.value
    if symbol.lnum and symbol.end_lnum then
      table.insert(symbol_range_cache, {
        index = i,
        start_line = symbol.lnum,
        end_line = symbol.end_lnum,
        item = item,
      })
    end
  end
  -- Sort by start line for binary search
  table.sort(symbol_range_cache, function(a, b)
    return a.start_line < b.start_line
  end)
end

---Find the index of a symbol in the filtered items list
---@param items SelectaItem[] The filtered items list
---@param symbol SelectaItem table The symbol to find
---@return number|nil index The index of the symbol if found
local function find_symbol_index(items, symbol)
  for i, item in ipairs(items) do
    -- Compare the essential properties to find a match
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

---Find Node for Preview
---@param node TSNode The treesitter node
---@param lnum number The line number (0-based)
---@return TSNode|nil
local function find_meaningful_node(node, lnum)
  if not node then
    return nil
  end
  -- Helper to check if a node starts at our target line
  local function starts_at_line(n)
    local start_row = select(1, n:range())
    return start_row == lnum
  end
  -- Get the root-most node that starts at our line
  local current = node
  local target_node = node
  while current and starts_at_line(current) do
    target_node = current
    ---@diagnostic disable-next-line: undefined-field
    current = current:parent()
  end

  -- Now we have the largest node that starts at our line
  ---@diagnostic disable-next-line: undefined-field
  local type = target_node:type()

  -- Quick check if we're already at the right node type
  if type == "function_definition" then
    return node
  end

  -- Handle assignment cases (like MiniPick.stop = function())
  if type == "assignment_statement" then
    -- First try to get the function from the right side
    ---@diagnostic disable-next-line: undefined-field
    local expr_list = target_node:field("rhs")[1]
    if expr_list then
      for i = 0, expr_list:named_child_count() - 1 do
        local child = expr_list:named_child(i)
        if child and child:type() == "function_definition" then
          -- For assignments, we want to include the entire assignment
          -- not just the function definition
          return target_node
        end
      end
    end
  end

  -- Handle local function declarations
  if type == "local_function" or type == "function_declaration" then
    return target_node
  end

  -- Handle local assignments with functions
  if type == "local_declaration" then
    ---@diagnostic disable-next-line: undefined-field
    local values = target_node:field("values")
    if values and values[1] and values[1]:type() == "function_definition" then
      return target_node
    end
  end

  -- Handle method definitions
  if type == "method_definition" then
    return target_node
  end

  return target_node
end

---@param symbol table LSP symbol item
local function highlight_symbol(symbol)
    local picker_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(state.original_win)
    vim.api.nvim_buf_clear_namespace(0, state.preview_ns, 0, -1)

    -- Get the line content
    local bufnr = vim.api.nvim_win_get_buf(state.original_win)
    local line = vim.api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.lnum, false)[1]

    -- Find first non-whitespace character position
    local first_char_col = line:find("%S")
    if not first_char_col then return end
    first_char_col = first_char_col - 1 -- Convert to 0-based index

    -- Get node at the first non-whitespace character
    local node = vim.treesitter.get_node({
        pos = { symbol.lnum - 1, first_char_col },
        ignore_injections = false,
    })
    -- Try to find a more meaningful node
    node = find_meaningful_node(node, symbol.lnum - 1)

    if node then
        local srow, scol, erow, ecol = node:range()

        -- Create extmark for the entire node range
        vim.api.nvim_buf_set_extmark(bufnr, state.preview_ns, srow, 0, {
            end_row = erow,
            end_col = ecol,
            hl_group = M.config.highlight,
            hl_eol = true,
            priority = 100,
            strict = false -- Allow marks beyond EOL
        })

        -- Center the view on the node
        vim.api.nvim_win_set_cursor(state.original_win, { srow + 1, scol })
        vim.cmd("normal! zz")
---Determines if a symbol should be included based on its kind and configured filters
---@param symbol LSPSymbol
---@return boolean
local function should_include_symbol(symbol)
  local kind = M.symbol_kind(symbol.kind)
  local includeKinds = M.config.AllowKinds[vim.bo.filetype] or M.config.AllowKinds.default
  local excludeResults = M.config.BlockList[vim.bo.filetype] or M.config.BlockList.default

  local include = vim.tbl_contains(includeKinds, kind)
  local exclude = vim.iter(excludeResults):any(function(pattern)
    return symbol.name:find(pattern) ~= nil
  end)

  return include and not exclude
end

---Transforms LSP symbols into SelectaItem format with caching, nesting, and filtering
---@param raw_symbols LSPSymbol[]
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols)
  local bufnr = vim.api.nvim_get_current_buf()
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  if M.symbol_cache and M.symbol_cache.key == cache_key then
    return M.symbol_cache.items
  end

  local items = {}
  local STYLE = 2 -- TODO: move it to config later

  ---[local] Recursively processes each symbol and its children into SelectaItem format with proper indentation
  ---@param result LSPSymbol
  ---@param depth number Current depth level
  local function processSymbolResult(result, depth)
    if not result or not result.name then
      return
    end

    if not should_include_symbol(result) then
      if result.children then
        for _, child in ipairs(result.children) do
          processSymbolResult(child, depth)
        end
      end
      return
    end

    local clean_name = result.name:match("^([^%s%(]+)") or result.name
    local prefix = depth == 0 and ""
      or (
        STYLE == 1 and string.rep("  ", depth)
        or STYLE == 2 and string.rep("  ", depth - 1) .. ".."
        or STYLE == 3 and string.rep("  ", depth - 1) .. " →"
        or string.rep("  ", depth)
      )

    local display_text = prefix .. clean_name

    local item = {
      text = display_text,
      value = {
        text = clean_name,
        name = clean_name,
        kind = M.symbol_kind(result.kind),
        lnum = result.range.start.line + 1,
        col = result.range.start.character + 1,
        end_lnum = result.range["end"].line + 1,
        end_col = result.range["end"].character + 1,
      },
      icon = M.config.kindIcons[M.symbol_kind(result.kind)] or M.config.icon,
      kind = M.symbol_kind(result.kind),
      depth = depth,
    }

    table.insert(items, item)

    if result.children then
      for _, child in ipairs(result.children) do
        processSymbolResult(child, depth + 1)
      end
    end
  end

  for _, symbol in ipairs(raw_symbols) do
    processSymbolResult(symbol, 0)
  end

  M.symbol_cache = { key = cache_key, items = items }
  update_symbol_ranges_cache(items)
  return items
end

-- Cache for symbol kinds
local symbol_kinds = nil

---@param kind number
---@return LSPSymbolKind
function M.symbol_kind(kind)
  if not symbol_kinds then
    symbol_kinds = {}
    for k, v in pairs(vim.lsp.protocol.SymbolKind) do
      if type(v) == "number" then
        symbol_kinds[v] = k
      end
    end
  end
  return symbol_kinds[kind] or "Unknown"
end

---@param symbol table LSP symbol
local function jumpToSymbol(symbol)
    vim.cmd.normal({ "m`", bang = true }) -- set jump mark
    vim.api.nvim_win_set_cursor(state.original_win, { symbol.lnum, symbol.col - 1 })
end

function M.jump()
    -- Store current window and position
    state.original_win = vim.api.nvim_get_current_win()
    state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)

    -- Set up highlight group
    vim.api.nvim_set_hl(0, M.config.highlight, {
        background = "#2a2a2a", -- Adjust color to match your theme
        bold = true,
    })

    -- Create autocmd for cleanup
    local augroup = vim.api.nvim_create_augroup("MagnetCleanup", { clear = true })

    local params = vim.lsp.util.make_position_params(0, "utf-8")

    vim.lsp.buf_request(
        0,
        "textDocument/documentSymbol",
        params,
        function(err, result, _, _)
            if err then
                vim.notify(
                    "Error fetching symbols: " .. err.message,
                    vim.log.levels.ERROR,
                    { title = "Magnet", icon = M.config.icon }
                )
                return
            end
            if not result or #result == 0 then
                vim.notify(
                    "No results.",
                    vim.log.levels.WARN,
                    { title = "Magnet", icon = M.config.icon }
                )
                return
            end

            local items = vim.lsp.util.symbols_to_items(result or {}, 0) or {}
            local symbols = filterSymbols(items)

            if #symbols == 0 then
                vim.notify(
                    "Current `kindFilter` doesn't match any symbols.",
                    nil,
                    { title = "Magnet", icon = M.config.icon }
                )
                return
            end

            -- Convert symbols to selecta items
            local selectaItems = symbolsToSelectaItems(symbols)
            -- local prefix_width = calculate_prefix_width(selectaItems)

            local picker_win = selecta.pick(selectaItems, {
                title = "LSP Symbols",
                fuzzy = true,
                window = vim.tbl_deep_extend("force", M.config.window, {
                    title_prefix = M.config.icon .. " ",
                }),
                on_select = function(item)
                    clear_preview_highlight()
                    jumpToSymbol(item.value)
                end,
                on_cancel = function()
                    clear_preview_highlight()
                    if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
                        vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
                    end
                end,
                on_move = function(item)
                    if item then
                        highlight_symbol(item.value)
                    end
                end,
            })

            -- Add cleanup autocmd after picker is created
            if picker_win then
                vim.api.nvim_create_autocmd("WinClosed", {
                    group = augroup,
                    pattern = tostring(picker_win),
                    callback = function()
                        clear_preview_highlight()
                        vim.api.nvim_del_augroup_by_name("MagnetCleanup")
                    end,
                    once = true,
                })
            end
        end
    )
end

---@param opts? table
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    -- Configure selecta with appropriate options
    selecta.setup({
        debug = M.config.debug,
        display = {
            mode = M.config.display.mode,
            padding = M.config.display.padding
        },
        window = vim.tbl_deep_extend("force", {}, M.config.window)
    })
end

-- Optional: Add commands or keymaps in setup
function M.setup_keymaps()
    vim.keymap.set("n", "<leader>ss", M.jump, {
        desc = "Jump to LSP symbol",
        silent = true,
    })
end

return M
