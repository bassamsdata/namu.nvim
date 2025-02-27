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
local lsp = require("namu.namu_symbols.lsp")
local ui = require("namu.namu_symbols.ui")
local ext = require("namu.namu_symbols.external_plugins")
local utils = require("namu.namu_symbols.utils")
local M = {}

-- Store original window and position for preview
---@type NamuState
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = vim.api.nvim_create_namespace("namu_preview"),
}

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
  filter_symbol_types = {
    -- Functions
    fn = {
      kinds = { "Function", "Constructor" },
      description = "Functions, methods and constructors",
    },
    -- Methods:
    me = {
      kinds = { "Method", "Accessor" },
      description = "Methods",
    },
    -- Variables
    va = {
      kinds = { "Variable", "Parameter", "TypeParameter" },
      description = "Variables and parameters",
    },
    -- Classes
    cl = {
      kinds = { "Class", "Interface", "Struct" },
      description = "Classes, interfaces and structures",
    },
    -- Constants
    co = {
      kinds = { "Constant", "Boolean", "Number", "String" },
      description = "Constants and literal values",
    },
    -- Fields
    fi = {
      kinds = { "Field", "Property", "EnumMember" },
      description = "Object fields and properties",
    },
    -- Modules
    mo = {
      kinds = { "Module", "Package", "Namespace" },
      description = "Modules and packages",
    },
    -- Arrays
    ar = {
      kinds = { "Array", "List", "Sequence" },
      description = "Arrays, lists and sequences",
    },
    -- Objects
    ob = {
      kinds = { "Object", "Class", "Instance" },
      description = "Objects and class instances",
    },
  },
  custom_keymaps = {
    yank = {
      keys = { "<C-y>" },
      handler = function(items_or_item)
        local success = utils.yank_symbol_text(items_or_item, state)
        if success and M.config.actions.close_on_yank then
          ui.clear_preview_highlight(state.original_win, state.preview_ns)
          return false
        end
      end,
      desc = "Yank symbol text",
    },
    delete = {
      keys = { "<C-d>" },
      handler = function(items_or_item)
        local deleted = utils.delete_symbol_text(items_or_item, state)
        if deleted and M.config.actions.close_on_delete then
          ui.clear_preview_highlight(state.original_win, state.preview_ns)
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
          ui.clear_preview_highlight(state.original_win, state.preview_ns)
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
          ui.clear_preview_highlight(state.original_win, state.preview_ns)
          return false
        end
      end,
      desc = "Open in horizontal split",
    },
    codecompanion = {
      keys = "<C-o>",
      handler = function(items_or_item)
        ext.codecompanion_handler(items_or_item, state.original_buf)
      end,
      desc = "Add symbol to CodeCompanion",
    },
    avante = {
      keys = "<C-t>",
      handler = function(items_or_item)
        ext.avante_handler(items_or_item, state.original_buf)
      end,
      desc = "Add symbol to Avante",
    },
  },
}

-- Symbol cache
local symbol_cache = nil

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

-- Choose your style here: 1, 2, or 3
local STYLE = 2 -- TODO: move it to config later

---Converts LSP symbols to selecta-compatible items with proper formatting
---@param raw_symbols LSPSymbol[]
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols)
  local bufnr = vim.api.nvim_get_current_buf()
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  if symbol_cache and symbol_cache.key == cache_key then
    return symbol_cache.items
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

    if not lsp.should_include_symbol(result, M.config, vim.bo.filetype) then
      if result.children then
        for _, child in ipairs(result.children) do
          process_symbol_result(child, depth)
        end
      end
      return
    end

    local clean_name = result.name:match("^([^%s%(]+)") or result.name
    clean_name = state.original_ft == "markdown" and result.name or clean_name
    local prefix = ui.get_prefix(depth, M.config.display.style or 2)
    local display_text = prefix .. clean_name

    local kind = lsp.symbol_kind(result.kind)
    local item = {
      text = display_text,
      value = {
        text = clean_name,
        name = clean_name,
        kind = kind,
        lnum = range.start.line + 1,
        col = range.start.character + 1,
        end_lnum = range["end"].line + 1,
        end_col = range["end"].character + 1,
      },
      icon = M.config.kindIcons[kind] or M.config.icon,
      kind = kind,
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

  symbol_cache = { key = cache_key, items = items }
  update_symbol_ranges_cache(items)
  return items
end

---@class SymbolTypeFilter
---@field type string The type of symbol to filter
---@field remaining string The remaining query to match
local function parse_symbol_filter(query)
  if #query >= 3 and query:sub(1, 1) == "/" then
    local type_code = query:sub(2, 3)
    local symbol_type = M.config.filter_symbol_types[type_code]

    if symbol_type then
      return {
        kinds = symbol_type.kinds,
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
        local kinds_lower = vim.tbl_map(string.lower, filter.kinds)
        local filtered = vim.tbl_filter(function(item)
          return item.kind and vim.tbl_contains(kinds_lower, string.lower(item.kind))
        end, items)

        -- TODO: make this notifications configureable
        -- if #filtered == 0 then
        --   vim.notify(string.format("No symbols of type '%s' found", filter.type), vim.log.levels.INFO)
        -- end

        return filtered, filter.remaining
      end
      return items, query
    end,
    hooks = {
      on_render = function(buf, filtered_items)
        ui.apply_kind_highlights(buf, filtered_items, M.config)
      end,
      on_buffer_clear = function()
        ui.clear_preview_highlight(state.original_win, state.preview_ns)
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
          ui.clear_preview_highlight(state.original_win, state.preview_ns)
          if type(selected_items) == "table" and selected_items[1] then
            ui.highlight_symbol(selected_items[1].value, state.original_win, state.preview_ns)
          end
        end
        if type(selected_items) == "table" and selected_items[1] then
          jump_to_symbol(selected_items[1].value)
        end
      end,
    },
    initial_index = M.config.focus_current_symbol and current_symbol and ui.find_symbol_index(
      selectaItems,
      current_symbol
    ) or nil,
    on_select = function(item)
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      jump_to_symbol(item.value)
    end,
    on_cancel = function()
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
        vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
      end
    end,
    on_move = function(item)
      if M.config.preview.highlight_on_move and M.config.preview.highlight_mode == "always" then
        if item then
          ui.highlight_symbol(item.value, state.original_win, state.preview_ns)
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

  -- Add cleanup autocmd after picker is created
  if picker_win then
    local augroup = vim.api.nvim_create_augroup("NamuCleanup", { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = tostring(picker_win),
      callback = function()
        ui.clear_preview_highlight(state.original_win, state.preview_ns)
        vim.api.nvim_del_augroup_by_name("NamuCleanup")
      end,
      once = true,
    })
  end
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

  if symbol_cache and symbol_cache.key == cache_key then
    local items = symbol_cache.items
    -- If filter_kind is specified, filter the cached items
    if opts.filter_kind then
      items = vim.tbl_filter(function(item)
        return item.kind == opts.filter_kind
      end, items)
    end
    show_picker(items, notify_opts)
    return
  end

  lsp.request_symbols(state.original_buf, "textDocument/documentSymbol", function(err, result, _)
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
    symbol_cache = {
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
  ui.setup(M.config)

  if M.config.kinds and M.config.kinds.enable_highlights then
    vim.schedule(function()
      ui.setup_highlights()
    end)
  end

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("namuHighlights", { clear = true }),
    callback = function()
      ui.setup_highlights()
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
