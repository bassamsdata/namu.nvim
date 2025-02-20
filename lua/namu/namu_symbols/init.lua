--[[ namu.lua
Quick LSP symbol jumping with live preview and fuzzy finding.

Features:
- Fuzzy find LSP symbols
- Live preview as you move
- Auto-sized window
- Filtered by symbol kinds
- Configurable exclusions


```lua
-- Configure Namu 
require('namu').setup({
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
    highlight = "NamuPreview",
})

-- set your own keymap
vim.keymap.set('n', 'gs', require('namu').jump, {
    desc = "Jump to symbol"
})
```
]]

local selecta = require("namu.selecta.selecta")
local M = {}

---@alias LSPSymbolKind string
-- ---@alias TSNode userdata
-- ---@alias vim.lsp.Client table

---@class LSPSymbol
---@field name string Symbol name
---@field kind number LSP symbol kind number
---@field range table<string, table> Symbol range in the document
---@field location? table<string, table>
---@field children? LSPSymbol[] Child symbols

---@class NamuConfig
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
---@field row_position "center"|"top10"|"top10_right"|"center_right"|"bottom" Window position preset
---@field multiselect table Multiselect configuration
---@field custom_keymaps table Keymap configuration

---@class NamuState
---@field original_win number|nil Original window
---@field original_buf number|nil Original buffer
---@field original_ft string|nil Original filetype
---@field original_pos table|nil Original cursor position
---@field preview_ns number|nil Preview namespace
---@field current_request table|nil Current LSP request ID

-- Store original window and position for preview
---@type NamuState
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = vim.api.nvim_create_namespace("namu_preview"),
  current_request = nil,
}

local ns_id = vim.api.nvim_create_namespace("namu_symbols")

---@type NamuConfig
M.config = {
  AllowKinds = {
    default = {
      "Function",
      "Method",
      "Class",
      "Module",
      "Property",
      "Variable",
      -- "Constant",
      -- "Enum",
      -- "Interface",
      -- "Field",
      -- "Struct",
    },
    go = {
      "Function",
      "Method",
      "Struct", -- For struct definitions
      "Field", -- For struct fields
      "Interface",
      "Constant",
      -- "Variable",
      "Property",
      -- "TypeParameter", -- For type parameters if using generics
    },
    lua = { "Function", "Method", "Table", "Module" },
    python = { "Function", "Class", "Method" },
    -- Filetype specific
    yaml = { "Object", "Array" },
    json = { "Module" },
    toml = { "Object" },
    markdown = { "String" },
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
    -- another example:
    -- python = { "^__" }, -- ignore __init__ functions
  },
  display = {
    mode = "icon", -- "icon" or "raw"
    padding = 2,
  },
  kindText = {
    Function = "function",
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
  preview = {
    highlight_on_move = true, -- Whether to highlight symbols as you move through them
    -- TODO: still needs implmenting, keep it always now
    highlight_mode = "always", -- "always" | "select" (only highlight when selecting)
  },
  icon = "󱠦", -- 󱠦 -  -  -- 󰚟
  highlight = "NamuPreview",
  highlights = {
    parent = "NamuParent",
    nested = "NamuNested",
    style = "NamuStyle",
  },
  kinds = {
    prefix_kind_colors = true,
    enable_highlights = true,
    highlights = {
      PrefixSymbol = "NamuPrefixSymbol",
      Function = "NamuSymbolFunction",
      Method = "NamuSymbolMethod",
      Class = "NamuSymbolClass",
      Interface = "NamuSymbolInterface",
      Variable = "NamuSymbolVariable",
      Constant = "NamuSymbolConstant",
      Property = "NamuSymbolProperty",
      Field = "NamuSymbolField",
      Enum = "NamuSymbolEnum",
      Module = "NamuSymbolModule",
    },
  },
  -- This is a preset that let's set window without really get into the hassle of tuning window options
  -- top10 meaning top 10% of the window
  row_position = "top10", -- options: "center"|"top10"|"top10_right"|"center_right"|"bottom",
  window = {
    auto_size = true,
    min_height = 1,
    min_width = 20,
    max_width = 120,
    max_height = 30,
    padding = 2,
    border = "rounded",
    title_pos = "left",
    show_footer = true,
    footer_pos = "right",
    relative = "editor",
    style = "minimal",
    width_ratio = 0.6,
    height_ratio = 0.6,
    title_prefix = "󱠦 ",
  },
  debug = true,
  focus_current_symbol = true,
  auto_select = false,
  initially_hidden = false,
  multiselect = {
    enabled = true,
    indicator = "✓", -- or "✓"●
    keymaps = {
      toggle = "<Tab>",
      untoggle = "<S-Tab>",
      select_all = "<C-a>",
      clear_all = "<C-l>",
    },
    max_items = nil, -- No limit by default
  },
  actions = {
    close_on_yank = false, -- Whether to close picker after yanking
    close_on_delete = true, -- Whether to close picker after deleting
  },
  movement = {
    next = { "<C-n>", "<DOWN>" }, -- Support multiple keys
    previous = { "<C-p>", "<UP>" }, -- Support multiple keys
    close = { "<ESC>" },
    select = { "<CR>" },
    delete_word = {},
    clear_line = {},
    -- Deprecated mappings (but still working)
    -- alternative_next = "<DOWN>", -- @deprecated: Will be removed in v1.0
    -- alternative_previous = "<UP>", -- @deprecated: Will be removed in v1.0
  },
  custom_keymaps = {
    yank = {
      keys = { "<C-y>" },
      handler = function(items_or_item, state)
        local success = M.yank_symbol_text(items_or_item, state)
        if success and M.config.actions.close_on_yank then
          M.clear_preview_highlight()
          return false
        end
      end,
      desc = "Yank symbol text",
    },
    delete = {
      keys = { "<C-d>" },
      handler = function(items_or_item, state)
        local deleted = M.delete_symbol_text(items_or_item, state)
        if deleted and M.config.actions.close_on_delete then
          M.clear_preview_highlight()
          return false
        end
      end,
      desc = "Delete symbol text",
    },
    vertical_split = {
      keys = { "<C-v>" },
      handler = function(item, selecta_state)
        if not state.original_buf then
          vim.notify("No original buffer available", vim.log.levels.ERROR)
          return
        end

        local new_win = selecta.open_in_split(selecta_state, item, "vertical", state)
        if new_win then
          local symbol = item.value
          if symbol and symbol.lnum and symbol.col then
            -- Set cursor to symbol position
            pcall(vim.api.nvim_win_set_cursor, new_win, { symbol.lnum, symbol.col - 1 })
            vim.cmd("normal! zz")
          end
          M.clear_preview_highlight()
          return false
        end
      end,
      desc = "Open in vertical split",
    },
    horizontal_split = {
      keys = { "<C-h>" },
      handler = function(item, selecta_state)
        if not state.original_buf then
          vim.notify("No original buffer available", vim.log.levels.ERROR)
          return
        end

        local new_win = selecta.open_in_split(selecta_state, item, "horizontal", state)
        if new_win then
          local symbol = item.value
          if symbol and symbol.lnum and symbol.col then
            -- Set cursor to symbol position
            pcall(vim.api.nvim_win_set_cursor, new_win, { symbol.lnum, symbol.col - 1 })
            vim.cmd("normal! zz")
          end
          M.clear_preview_highlight()
          return false
        end
      end,
      desc = "Open in horizontal split",
    },
    codecompanion = {
      keys = "<C-o>",
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
    avante = {
      keys = "<C-t>",
      handler = function(items_or_item)
        if type(items_or_item) == "table" and items_or_item[1] then
          M.add_symbol_to_avante(items_or_item, state.original_buf)
        else
          -- Single item case
          M.add_symbol_to_avante({ items_or_item }, state.original_buf)
        end
      end,
      desc = "Add symbol to Avante",
    },
  },
}

function M.setup_highlights()
  local highlights = {
    NamuPrefixSymbol = { link = "@Comment" }, -- or "@lsp.type.symbol"
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

---Yank the symbol text to registers
---@param items table|table[] Single item or array of selected items
---@param state table The picker state
function M.yank_symbol_text(items, state)
  if not state.original_buf or not vim.api.nvim_buf_is_valid(state.original_buf) then
    vim.notify("Invalid buffer", vim.log.levels.ERROR)
    return
  end

  -- Convert single item to array for consistent handling
  local symbols = type(items) == "table" and items[1] and items or { items }
  local all_text = {}

  -- Sort symbols by line number to maintain order
  table.sort(symbols, function(a, b)
    return a.value.lnum < b.value.lnum
  end)

  for _, item in ipairs(symbols) do
    local symbol = item.value
    if symbol and symbol.lnum and symbol.end_lnum then
      -- Get the text content
      local lines = vim.api.nvim_buf_get_lines(state.original_buf, symbol.lnum - 1, symbol.end_lnum, false)

      if #lines > 0 then
        -- Handle single line case
        if #lines == 1 then
          lines[1] = lines[1]:sub(symbol.col, symbol.end_col)
        else
          -- Handle multi-line case
          lines[1] = lines[1]:sub(symbol.col)
          lines[#lines] = lines[#lines]:sub(1, symbol.end_col)
        end
        table.insert(all_text, table.concat(lines, "\n"))
      end
    else
      vim.notify("Invalid symbol found, skipping", vim.log.levels.WARN)
    end
  end

  if #all_text > 0 then
    local final_text = table.concat(all_text, "\n\n")
    vim.fn.setreg('"', final_text) -- Set to unnamed register
    vim.fn.setreg("+", final_text) -- Set to system clipboard if unnamed register is not supported
    vim.notify(string.format("Yanked %d symbol(s) to clipboard", #symbols), vim.log.levels.INFO)
    return true
  end
  return false
end

---Delete the symbol text from buffer
---@param items table|table[] Single item or array of selected items
---@param state table The picker state
function M.delete_symbol_text(items, state)
  if not state.original_buf or not vim.api.nvim_buf_is_valid(state.original_buf) then
    vim.notify("Invalid buffer", vim.log.levels.ERROR)
    return
  end

  -- Convert single item to array for consistent handling
  local symbols = type(items) == "table" and items[1] and items or { items }

  -- Sort symbols by line number in reverse order (to delete from bottom up)
  table.sort(symbols, function(a, b)
    return a.value.lnum > b.value.lnum
  end)

  -- Confirm deletion
  local confirm = vim.fn.confirm(string.format("Delete %d selected symbol(s)?", #symbols), "&Yes\n&No", 2)

  if confirm ~= 1 then
    return
  end

  -- Create undo block
  vim.cmd("undojoin")

  local deleted_count = 0
  for _, item in ipairs(symbols) do
    local symbol = item.value
    if symbol and symbol.lnum and symbol.end_lnum then
      -- Delete the text
      vim.api.nvim_buf_set_lines(state.original_buf, symbol.lnum - 1, symbol.end_lnum, false, {})
      deleted_count = deleted_count + 1
    else
      vim.notify("Invalid symbol found, skipping", vim.log.levels.WARN)
    end
  end

  if deleted_count > 0 then
    vim.notify(string.format("Deleted %d symbol(s)", deleted_count), vim.log.levels.INFO)
    M.clear_preview_highlight()
    return true
  end
  return false
end

---Process and collect symbol text content
---@param items table[] Array of selected items
---@param bufnr number Buffer number
---@return table|nil {text: string, symbols: table[], content: string[]} Processed content and metadata
local function process_symbol_content(items, bufnr)
  if not items or #items == 0 then
    vim.notify("No items received", vim.log.levels.WARN)
    return nil
  end

  local sorted_symbols = {}
  local all_content = {}

  -- First pass: collect and sort symbols by line number
  for _, item in ipairs(items) do
    table.insert(sorted_symbols, item.value)
  end
  table.sort(sorted_symbols, function(a, b)
    return a.lnum < b.lnum
  end)

  -- Second pass: collect content with no duplicates
  local last_end_lnum = -1
  for _, symbol in ipairs(sorted_symbols) do
    -- Only add if this section doesn't overlap with the previous one
    if symbol.lnum > last_end_lnum then
      local lines = vim.api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.end_lnum, false)
      table.insert(all_content, table.concat(lines, "\n"))
      last_end_lnum = symbol.end_lnum
    end
  end

  return {
    text = table.concat(all_content, "\n\n"),
    symbols = sorted_symbols,
    content = all_content,
  }
end

---Add symbol text to CodeCompanion chat buffer
---@param items table[] Array of selected items from selecta
---@param bufnr number The buffer number of the original buffer
function M.add_symbol_to_codecompanion(items, bufnr)
  -- Check if the 'codecompanion' module is available
  local status, codecompanion = pcall(require, "codecompanion")
  if not status then
    return
  end

  local result = process_symbol_content(items, bufnr)
  if not result then
    return
  end

  local chat = codecompanion.last_chat()

  if not chat then
    chat = codecompanion.chat()
    if not chat then
      return vim.notify("Could not create chat buffer", vim.log.levels.WARN)
    end
  end

  chat:add_buf_message({
    role = require("codecompanion.config").constants.USER_ROLE,
    content = "Here is some code from "
      .. vim.api.nvim_buf_get_name(bufnr)
      .. ":\n\n```"
      .. vim.api.nvim_get_option_value("filetype", { buf = bufnr })
      .. "\n"
      .. result.text
      .. "\n```\n",
  })
  chat.ui:open()
end

---BUG: This function doesn't work as expected - need to check with Avante
---Add symbol text to Avante sidebar
---@param items table[] Array of selected items from selecta
---@param bufnr number The buffer number of the original buffer
function M.add_symbol_to_avante(items, bufnr)
  -- Check if the 'avante.api' module is available
  local status, avante_api = pcall(require, "avante.api")
  if not status then
    return
  end

  local result = process_symbol_content(items, bufnr)
  if not result then
    return
  end

  -- Create the selection object that Avante expects
  local selection = {
    text = result.text,
    range = {
      start = {
        line = result.symbols[1].lnum - 1,
        character = result.symbols[1].col - 1,
      },
      ["end"] = {
        line = result.symbols[#result.symbols].end_lnum - 1,
        character = result.symbols[#result.symbols].end_col - 1,
      },
    },
  }

  -- Call Avante's ask function with the selection
  avante_api.ask({
    selection = selection,
    floating = true,
  })
end

---find_containing_symbol: Locates the symbol that contains the current cursor position
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

  ---[local] Helper function to efficiently search through symbol ranges
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

--Maintains a cache of symbol ranges for quick lookup
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

---Finds index of symbol at current cursor position
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

---Traverses syntax tree to find significant nodes for better symbol context
---@param node TSNode The treesitter node
---@param lnum number The line number (0-based)
---@return TSNode|nil
local function find_meaningful_node(node, lnum)
  if not node then
    return nil
  end
  -- [local] Helper to check if a node starts at our target line
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

---Handles visual highlighting of selected symbols in preview
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
  if not first_char_col then
    return
  end
  first_char_col = first_char_col - 1 -- Convert to 0-based index

  -- Get node at the first non-whitespace character
  local node = vim.treesitter.get_node({
    pos = { symbol.lnum - 1, first_char_col },
    ignore_injections = false,
  })
  -- Try to find a more meaningful node
  if node then
    node = find_meaningful_node(node, symbol.lnum - 1)
  end

  if node then
    local srow, scol, erow, ecol = node:range()

    -- Create extmark for the entire node range
    vim.api.nvim_buf_set_extmark(bufnr, state.preview_ns, srow, 0, {
      end_row = erow,
      end_col = ecol,
      hl_group = M.config.highlight,
      hl_eol = true,
      priority = 1,
      strict = false, -- Allow marks beyond EOL
    })

    -- Center the view on the node
    vim.api.nvim_win_set_cursor(state.original_win, { srow + 1, scol })
    vim.cmd("normal! zz")
  end

  vim.api.nvim_set_current_win(picker_win)
end

---Filters symbols based on configured kinds and blocklist
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

-- Choose your style here: 1, 2, or 3
local STYLE = 2 -- TODO: move it to config later

-- Style options for nested items
---@param depth number
---@param style number 1: Just indentation, 2: Dot style, 3: Arrow style
---@return string
local function get_prefix(depth, style)
  local prefix = depth == 0 and ""
    or (
      style == 1 and string.rep("  ", depth)
      or style == 2 and string.rep("  ", depth - 1) .. ".."
      or style == 3 and string.rep("  ", depth - 1) .. " →"
      or string.rep("  ", depth)
    )

  return prefix
end

---Converts LSP symbols to selecta-compatible items with proper formatting
---@param raw_symbols LSPSymbol[]
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols)
  local bufnr = vim.api.nvim_get_current_buf()
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  if M.symbol_cache and M.symbol_cache.key == cache_key then
    return M.symbol_cache.items
  end

  local items = {}

  ---[local] Recursively processes each symbol and its children into SelectaItem format with proper indentation
  ---@param result LSPSymbol
  ---@param depth number Current depth level
  local function process_symbol_result(result, depth)
    if not result or not result.name then
      return
    end

    -- There are two possible schemas for symbols returned by LSP:
    --
    --    SymbolInformation:
    --      { name, kind, location, containerName? }
    --
    --    DocumentSymbol:
    --      { name, kind, range, selectionRange, children? }
    --
    --    In the case of DocumentSymbol, we need to use the `range` field for the symbol position.
    --    In the case of SymbolInformation, we need to use the `location.range` field for the symbol position.
    --
    --    source:
    --      https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.18/language/documentSymbol.md
    local range = result.range or (result.location and result.location.range)
    if not range or not range.start or not range["end"] then
      vim.notify("Symbol '" .. result.name .. "' has invalid structure", vim.log.levels.WARN)
      return
    end

    if not should_include_symbol(result) then
      if result.children then
        for _, child in ipairs(result.children) do
          process_symbol_result(child, depth)
        end
      end
      return
    end

    local clean_name = result.name:match("^([^%s%(]+)") or result.name
    local prefix = get_prefix(depth, STYLE)
    local display_text = prefix .. clean_name

    local item = {
      text = display_text,
      value = {
        text = clean_name,
        name = clean_name,
        kind = M.symbol_kind(result.kind),
        lnum = range.start.line + 1,
        col = range.start.character + 1,
        end_lnum = range["end"].line + 1,
        end_col = range["end"].character + 1,
      },
      icon = M.config.kindIcons[M.symbol_kind(result.kind)] or M.config.icon,
      kind = M.symbol_kind(result.kind),
      depth = depth,
    }

    table.insert(items, item)

    if result.children then
      for _, child in ipairs(result.children) do
        process_symbol_result(child, depth + 1)
      end
    end
  end

  for _, symbol in ipairs(raw_symbols) do
    process_symbol_result(symbol, 0)
  end

  M.symbol_cache = { key = cache_key, items = items }
  update_symbol_ranges_cache(items)
  return items
end

local function apply_kind_highlights(buf, items)
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  for idx, item in ipairs(items) do
    local line = idx - 1
    local kind = item.kind
    local hl_group = M.config.kinds.highlights[kind]

    if hl_group then
      local line_text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1]
      if not line_text then
        goto continue
      end

      -- First highlight the prefix symbol if it exists
      if item.depth and item.depth > 0 then
        local prefix = get_prefix(item.depth, STYLE)
        local prefix_symbol = STYLE == 2 and ".." or (STYLE == 3 and "→" or nil)

        if prefix_symbol then
          local symbol_pos = line_text:find(prefix_symbol, 1, true)
          if symbol_pos then
            vim.api.nvim_buf_set_extmark(buf, ns_id, line, symbol_pos - 1, {
              end_row = line,
              end_col = symbol_pos - 1 + #prefix_symbol,
              hl_group = M.config.kinds.highlights.PrefixSymbol,
              priority = 91, -- Slightly lower priority than the main highlight
              strict = false,
            })
          end
        end
      end

      -- Then highlight the main symbol
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

-- Cache for symbol kinds
local symbol_kinds = nil

---Converts LSP symbol kind numbers to readable strings
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

function M.clear_preview_highlight()
  if state.preview_ns and state.original_win then
    -- Get the buffer number from the original window
    local bufnr = vim.api.nvim_win_get_buf(state.original_win)
    vim.api.nvim_buf_clear_namespace(bufnr, state.preview_ns, 0, -1)
  end
end

local default_symbol_types = {
  -- Functions
  fn = {
    name = "function",
    aliases = { "function", "func", "method", "routine" },
    description = "Functions and methods",
  },
  -- Variables
  va = {
    name = "variable",
    aliases = { "variable", "var", "let" },
    description = "Variables and let bindings",
  },
  -- Classes
  cl = {
    name = "type",
    aliases = { "class", "struct", "type" },
    description = "Classes and complex types",
  },
  -- Constants
  co = {
    name = "constant",
    aliases = { "constant", "const" },
    description = "Constant values",
  },
  -- Methods
  me = {
    name = "method",
    aliases = { "method", "member", "func" },
    description = "Class/object methods",
  },
  -- Fields
  fi = {
    name = "field",
    aliases = { "field", "property", "prop" },
    description = "Object fields and properties",
  },
  -- Modules
  mo = {
    name = "module",
    aliases = { "module", "mod" },
    description = "Modules and packages",
  },
  -- Namespaces
  na = {
    name = "namespace",
    aliases = { "namespace", "ns" },
    description = "Namespaces and scopes",
  },
  -- Enums
  en = {
    name = "enum",
    aliases = { "enum", "enumeration" },
    description = "Enumerations",
  },
}

---@class SymbolTypeHelp
---@field create_help_buffer function Create and show the help buffer
local SymbolTypeHelp = {}

function SymbolTypeHelp.create_help_buffer()
  -- Create a new buffer
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set buffer options
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "namu-help")

  -- Create content
  local lines = {
    "Namu Symbol Types",
    string.rep("=", 40),
    "",
    "Usage: Type %xx followed by search term",
    "Example: %fn main - finds functions containing 'main'",
    "",
    "Available Symbol Types:",
    string.rep("-", 40),
    "",
  }

  -- Add symbol types
  for code, symbol_type in pairs(default_symbol_types) do
    table.insert(lines, string.format("  %s - %s", code, symbol_type.description))
    table.insert(lines, string.format("    Matches: %s", table.concat(symbol_type.aliases, ", ")))
    table.insert(lines, "")
  end

  -- Set buffer content
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  -- Create window
  local width = math.min(60, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
  })

  -- Set window options
  vim.wo[win].conceallevel = 2
  vim.wo[win].foldenable = false
  vim.wo[win].wrap = false

  -- Setup highlights
  vim.cmd([[
    highlight default link NamuHelpHeader Title
    highlight default link NamuHelpSubHeader Statement
    highlight default link NamuHelpCode Special
    highlight default link NamuHelpType Type
    highlight default link NamuHelpAlias Comment
  ]])

  -- Apply highlights
  local ns_id = vim.api.nvim_create_namespace("namu_help")

  -- Header
  vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuHelpHeader", 0, 0, -1)

  -- Usage section
  vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuHelpSubHeader", 3, 0, 5)
  vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuHelpCode", 4, 0, -1)

  -- Symbol types section
  vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuHelpSubHeader", 6, 0, -1)

  -- Highlight each symbol type
  local current_line = 9
  for _ in pairs(default_symbol_types) do
    -- Highlight the code and description
    vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuHelpCode", current_line, 2, 4)
    vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuHelpType", current_line, 7, -1)
    -- Highlight aliases
    vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuHelpAlias", current_line + 1, 4, -1)
    current_line = current_line + 3
  end

  -- Set buffer keymaps
  local opts = { noremap = true, silent = true }
  vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)

  -- Return buffer and window IDs
  return buf, win
end

-- Add to your module
function M.show_symbol_help()
  SymbolTypeHelp.create_help_buffer()
end

---@class SymbolTypeFilter
---@field type string The type of symbol to filter
---@field remaining string The remaining query to match
local function parse_symbol_filter(query)
  if #query >= 3 and query:sub(1, 1) == "%" then
    local type_code = query:sub(2, 3)
    local symbol_type = default_symbol_types[type_code]

    if symbol_type then
      return {
        type = symbol_type.name,
        aliases = symbol_type.aliases,
        remaining = query:sub(4),
        description = symbol_type.description,
      }
    end
  end
  return nil
end

---Performs the actual jump to selected symbol location
---@param symbol table LSP symbol
local function jump_to_symbol(symbol)
  vim.cmd.normal({ "m`", bang = true }) -- set jump mark
  vim.api.nvim_win_set_cursor(state.original_win, { symbol.lnum, symbol.col - 1 })
end

---Displays the fuzzy finder UI with symbol list
---@param selectaItems SelectaItem[]
---@param notify_opts? {title: string, icon: string}
local function show_picker(selectaItems, notify_opts)
  if #selectaItems == 0 then
    vim.notify("Current `kindFilter` doesn't match any symbols.", nil, notify_opts)
    return
  end

  -- Find containing symbol for current cursor position
  local current_symbol = find_containing_symbol(selectaItems)
  local picker_opts = {
    title = "LSP Symbols",
    fuzzy = false,
    preserve_order = true,
    window = M.config.window,
    display = M.config.display,
    auto_select = M.config.auto_select,
    initially_hidden = M.config.initially_hidden,
    movement = vim.tbl_deep_extend("force", M.config.movement, {}),
    row_position = M.config.row_position,
    debug = M.config.debug,
    pre_filter = function(items, query)
      local filter = parse_symbol_filter(query)
      if filter then
        -- print(string.format("Pre-filter: query=%s, filter_type=%s", query, filter.type))
        -- print("Available kinds in items:")
        local kind_count = {}
        for _, item in ipairs(items) do
          kind_count[item.kind] = (kind_count[item.kind] or 0) + 1
        end
        -- for kind, count in pairs(kind_count) do
        --   print(string.format("  - %s: %d items", kind, count))
        -- end

        local filtered = vim.tbl_filter(function(item)
          local matches = string.lower(item.kind or "") == string.lower(filter.type)
          -- print(
          --   string.format(
          --     "Item: kind=%s, filter_type=%s, matches=%s",
          --     item.kind or "nil",
          --     filter.type,
          --     tostring(matches)
          --   )
          -- )
          return matches
        end, items)

        -- print(string.format("Filtered results: %d items", #filtered))

        if #filtered == 0 then
          vim.notify(string.format("No symbols of type '%s' found", filter.type), vim.log.levels.INFO)
        end

        return filtered, filter.remaining
      end
      return items, query
    end,
    hooks = {
      on_render = function(buf, filtered_items)
        apply_kind_highlights(buf, filtered_items)
      end,
      on_buffer_clear = function()
        M.clear_preview_highlight()
        if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
          vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
        end
      end,
    },
    custom_keymaps = M.config.custom_keymaps,
    -- TODO: Enable multiselect if configured
    multiselect = {
      enabled = M.config.multiselect.enabled,
      indicator = M.config.multiselect.indicator,
      on_select = function(selected_items)
        -- TODO: we need smart mechanis on here.
        if M.config.preview.highlight_mode == "select" then
          M.clear_preview_highlight()
          if type(selected_items) == "table" and selected_items[1] then
            highlight_symbol(selected_items[1].value)
          end
        end
        if type(selected_items) == "table" and selected_items[1] then
          jump_to_symbol(selected_items[1].value)
        end
      end,
    },
    initial_index = M.config.focus_current_symbol and current_symbol and find_symbol_index(
      selectaItems,
      current_symbol
    ) or nil,
    on_select = function(item)
      M.clear_preview_highlight()
      jump_to_symbol(item.value)
    end,
    on_cancel = function()
      M.clear_preview_highlight()
      if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
        vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
      end
    end,
    on_move = function(item)
      if M.config.preview.highlight_on_move and M.config.preview.highlight_mode == "always" then
        if item then
          highlight_symbol(item.value)
        end
      end
    end,
  }
  if M.config.kinds.prefix_kind_colors then
    picker_opts.prefix_highlighter = function(buf, line_nr, item, icon_end, ns_id)
      local kind_hl = M.config.kinds.highlights[item.kind]
      if kind_hl then
        vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, 0, {
          end_col = icon_end,
          hl_group = kind_hl,
          priority = 100,
          hl_mode = "combine",
        })
      end
    end
  end

  local picker_win = selecta.pick(selectaItems, picker_opts)
  -- print("Sample items:")
  -- for i, item in ipairs(selectaItems) do
  --   if i <= 5 then -- Just show first 3 items
  --     print(vim.inspect(item))
  --   end
  -- end

  -- Add cleanup autocmd after picker is created
  if picker_win then
    local augroup = vim.api.nvim_create_augroup("NamuCleanup", { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = tostring(picker_win),
      callback = function()
        M.clear_preview_highlight()
        vim.api.nvim_del_augroup_by_name("NamuCleanup")
      end,
      once = true,
    })
  end
end

---Thanks to @folke snacks lsp for this handling, basically this function mostly borrowed from him
---Fixes old style clients
---@param client vim.lsp.Client
---@return vim.lsp.Client
local function ensure_client_compatibility(client)
  -- If client already has the new-style API, return it as-is
  if getmetatable(client) and getmetatable(client).request then
    return client
  end

  -- If we've already wrapped this client, don't wrap it again
  if client.namu_wrapped then
    return client
  end

  -- Create a wrapper for older style clients
  local wrapped = {
    namu_wrapped = true,
  }

  return setmetatable(wrapped, {
    __index = function(_, key)
      -- Special handling for supports_method in older versions
      if key == "supports_method" then
        return function(_, method)
          return client.supports_method(method)
        end
      end

      -- Handle request and cancel_request methods
      if key == "request" or key == "cancel_request" then
        return function(_, ...)
          return client[key](...)
        end
      end

      -- Pass through all other properties
      return client[key]
    end,
  })
end

---Returns the LSP client with document symbols support
---@param bufnr number
---@return vim.lsp.Client|nil, string|nil
local function get_client_with_symbols(bufnr)
  ---@diagnostic disable-next-line: deprecated
  local get_clients_fn = vim.lsp.get_clients or vim.lsp.get_active_clients

  local clients = vim.tbl_map(ensure_client_compatibility, get_clients_fn({ bufnr = bufnr }))

  if vim.tbl_isempty(clients) then
    return nil, "No LSP client attached to buffer"
  end

  for _, client in ipairs(clients) do
    if client and client.server_capabilities and client.server_capabilities.documentSymbolProvider then
      return client, nil
    end
  end

  return nil, "No LSP client supports document symbols"
end

-- Add the new request_symbols function
---@param bufnr number
---@param callback fun(err: any, result: any, ctx: any)
local function request_symbols(bufnr, callback)
  -- Cancel any existing request
  if state.current_request then
    local client = state.current_request.client
    local request_id = state.current_request.request_id
    -- Check if client and cancel_request are valid before calling
    if client and type(client.cancel_request) == "function" and request_id then
      client:cancel_request(request_id)
    end
    state.current_request = nil
  end

  -- Get client with document symbols
  local client, err = get_client_with_symbols(bufnr)
  if err then
    callback(err, nil, nil)
    return
  end

  -- Create params manually instead of using make_position_params
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr) or { uri = vim.uri_from_bufnr(bufnr) },
  }

  -- Send the request to the LSP server
  local success, request_id = client:request("textDocument/documentSymbol", params, function(request_err, result, ctx)
    state.current_request = nil
    callback(request_err, result, ctx)
  end)
  -- Check if the request was successful and that the request_id is not nil
  if success and request_id then
    -- Store the client and request_id
    state.current_request = {
      client = client,
      request_id = request_id,
    }
  else
    -- Handle the case where the request was not successful
    callback("Request failed or request_id was nil", nil, nil)
  end

  return state.current_request
end

local lsp_symbol_kinds = {
  [1] = "File",
  [2] = "Module",
  [3] = "Namespace",
  [4] = "Package",
  [5] = "Class",
  [6] = "Method",
  [7] = "Property",
  [8] = "Field",
  [9] = "Constructor",
  [10] = "Enum",
  [11] = "Interface",
  [12] = "Function",
  [13] = "Variable",
  [14] = "Constant",
  [15] = "String",
  [16] = "Number",
  [17] = "Boolean",
  [18] = "Array",
  [19] = "Object",
  [20] = "Key",
  [21] = "Null",
  [22] = "EnumMember",
  [23] = "Struct",
  [24] = "Event",
  [25] = "Operator",
  [26] = "TypeParameter",
}

---@class SymbolAnalyzer
---@field create_analysis_buffer function Create and show the analysis buffer
local SymbolAnalyzer = {}

function SymbolAnalyzer.create_analysis_buffer()
  local current_buf = vim.api.nvim_get_current_buf()
  local current_bufname = vim.api.nvim_buf_get_name(current_buf)

  -- Create a new buffer
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set buffer options
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "namu-analysis")

  -- Function to collect symbols
  local function collect_symbols(callback)
    request_symbols(current_buf, function(err, result, _)
      if err then
        vim.notify("Error fetching symbols: " .. vim.inspect(err), vim.log.levels.ERROR)
        return
      end
      callback(result or {})
    end)
  end

  -- Create the analysis window while waiting for symbols
  local width = math.min(70, vim.o.columns - 4)
  local height = math.min(20, vim.o.lines - 4)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
  })

  -- Set window options
  vim.wo[win].conceallevel = 2
  vim.wo[win].foldenable = false
  vim.wo[win].wrap = false

  -- Setup highlights
  vim.cmd([[
    highlight default link NamuAnalysisHeader Title
    highlight default link NamuAnalysisSubHeader Statement
    highlight default link NamuAnalysisCount Number
    highlight default link NamuAnalysisKind Type
    highlight default link NamuAnalysisFilter Special
    highlight default link NamuAnalysisPath Comment
  ]])

  -- Collect and display symbols
  collect_symbols(function(symbols)
    -- Analyze symbols
    local kind_count = {}
    local kind_examples = {}
    local total_symbols = 0

    local function analyze_symbol(symbol)
      if symbol.kind then
        -- Convert numeric kind to string
        local kind_str = type(symbol.kind) == "number" and lsp_symbol_kinds[symbol.kind] or symbol.kind

        if kind_str then
          kind_count[kind_str] = (kind_count[kind_str] or 0) + 1
          total_symbols = total_symbols + 1

          -- Store example if we don't have one yet
          if not kind_examples[kind_str] and symbol.name then
            kind_examples[kind_str] = symbol.name
          end
        end
      end

      -- Recurse into children if they exist
      if symbol.children then
        for _, child in ipairs(symbol.children) do
          analyze_symbol(child)
        end
      end
    end

    -- Analyze all symbols
    for _, symbol in ipairs(symbols) do
      analyze_symbol(symbol)
    end

    -- Create content
    local lines = {
      "Symbol Analysis",
      string.rep("=", 50),
      "",
      string.format("File: %s", vim.fn.fnamemodify(current_bufname, ":.")),
      string.format("Total Symbols: %d", total_symbols),
      "",
      "Symbol Distribution:",
      string.rep("-", 50),
      "",
    }

    -- Find matching symbol types
    local matched_types = {}
    for kind, _ in pairs(kind_count) do
      for code, symbol_type in pairs(default_symbol_types) do
        if vim.tbl_contains(symbol_type.aliases, string.lower(kind)) then
          matched_types[kind] = code
          break
        end
      end
    end

    -- Add symbol counts and examples
    for kind, count in pairs(kind_count) do
      local filter_code = matched_types[kind] or "??"
      local example = kind_examples[kind] or "N/A"
      table.insert(lines, string.format("  %s (%d symbols)", kind, count))
      table.insert(lines, string.format("    Filter: %%%s", filter_code))
      table.insert(lines, string.format("    Example: %s", example))
      table.insert(lines, "")
    end

    -- Add usage hints
    table.insert(lines, "Usage Tips:")
    table.insert(lines, string.rep("-", 50))
    table.insert(lines, "  - Use the filters shown above to narrow down symbols")
    table.insert(lines, "  - Combine with text: %fn main")
    table.insert(lines, "  - Press ? in symbol picker for more help")

    -- Set buffer content
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)

    -- Apply highlights
    local ns_id = vim.api.nvim_create_namespace("namu_analysis")

    -- Header
    vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuAnalysisHeader", 0, 0, -1)

    -- File info
    vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuAnalysisPath", 3, 6, -1)
    vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuAnalysisCount", 4, 15, -1)

    -- Symbol Distribution header
    vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuAnalysisSubHeader", 6, 0, -1)

    -- Highlight each symbol type section
    local current_line = 9
    for _ in pairs(kind_count) do
      -- Kind and count
      vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuAnalysisKind", current_line, 2, -1)
      -- Filter
      vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuAnalysisFilter", current_line + 1, 12, -1)
      current_line = current_line + 4
    end

    -- Usage tips header
    vim.api.nvim_buf_add_highlight(buf, ns_id, "NamuAnalysisSubHeader", current_line, 0, -1)
  end)

  -- Set buffer keymaps
  local opts = { noremap = true, silent = true }
  vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)

  return buf, win
end

-- Add to your module
function M.show_symbol_analysis()
  SymbolAnalyzer.create_analysis_buffer()
end

---Main entry point for symbol jumping functionality
---@param opts? {filter_kind?: string} Optional settings to filter specific kinds
function M.show(opts)
  opts = opts or {}
  -- Store current window and position
  state.original_win = vim.api.nvim_get_current_win()
  state.original_buf = vim.api.nvim_get_current_buf()
  state.original_ft = vim.bo.filetype
  state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)

  -- TODO: Move this to the setup highlights
  vim.api.nvim_set_hl(0, M.config.highlight, {
    link = "Visual",
  })

  local notify_opts = { title = "Namu", icon = M.config.icon }

  -- Use cached symbols if available
  local bufnr = vim.api.nvim_get_current_buf()
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  if M.symbol_cache and M.symbol_cache.key == cache_key then
    local items = M.symbol_cache.items
    -- If filter_kind is specified, filter the cached items
    if opts.filter_kind then
      items = vim.tbl_filter(function(item)
        return item.kind == opts.filter_kind
      end, items)
    end
    show_picker(items, notify_opts)
    return
  end

  request_symbols(state.original_buf, function(err, result, _)
    if err then
      local error_message = type(err) == "table" and err.message or err
      vim.notify("Error fetching symbols: " .. error_message, vim.log.levels.ERROR, notify_opts)
      return
    end
    if not result or #result == 0 then
      vim.notify("No results.", vim.log.levels.WARN, notify_opts)
      return
    end

    -- Convert directly to selecta items preserving hierarchy
    local selectaItems = symbols_to_selecta_items(result)

    -- Update cache
    M.symbol_cache = {
      key = cache_key,
      items = selectaItems,
    }

    -- Apply filter if specified
    if opts.filter_kind then
      selectaItems = vim.tbl_filter(function(item)
        return item.kind == opts.filter_kind
      end, selectaItems)
    end

    show_picker(selectaItems, notify_opts)
  end)
end

---Initializes the module with user configuration
function M.setup(opts)
  -- Merge user options with our defaults
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  if M.config.kinds and M.config.kinds.enable_highlights then
    vim.schedule(function()
      M.setup_highlights()
    end)
  end

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("namuHighlights", { clear = true }),
    callback = function()
      M.setup_highlights()
    end,
  })
end

--Sets up default keymappings for symbol navigation
function M.setup_keymaps()
  vim.keymap.set("n", "<leader>ss", M.show, {
    desc = "Jump to LSP symbol",
    silent = true,
  })
end

return M
