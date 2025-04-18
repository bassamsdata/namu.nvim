--[[ Namu Symbols Implementation
This file contains the actual implementation for LSP symbol navigation.
It is loaded only when required to improve startup performance.
]]

-- Dependencies
local selecta = require("namu.selecta.selecta")
local lsp = require("namu.namu_symbols.lsp")
local ui = require("namu.namu_symbols.ui")
local ext = require("namu.namu_symbols.external_plugins")
local utils = require("namu.namu_symbols.utils")
local symbol_utils = require("namu.core.symbol_utils")
local format_utils = require("namu.core.format_utils")

local M = {}

---@type NamuState
local state = nil
local handlers = nil

local symbol_cache = nil
local symbol_range_cache = {}

local function initialize_state(config)
  -- Create new state
  state = symbol_utils.create_state("namu_symbols_preview")
  state.original_win = vim.api.nvim_get_current_win()
  state.original_buf = vim.api.nvim_get_current_buf()
  state.original_ft = vim.bo.filetype
  state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)

  handlers = symbol_utils.create_keymaps_handlers(config, state, ui, selecta, ext, utils)
  -- Update keymap handlers
  if config.custom_keymaps then
    config.custom_keymaps.yank.handler = handlers.yank
    config.custom_keymaps.delete.handler = handlers.delete
    config.custom_keymaps.vertical_split.handler = handlers.vertical_split
    config.custom_keymaps.horizontal_split.handler = handlers.horizontal_split
    config.custom_keymaps.codecompanion.handler = handlers.codecompanion
    config.custom_keymaps.avante.handler = handlers.avante
  end
end

---Converts LSP symbols to selecta-compatible items with proper formatting
---@param raw_symbols LSPSymbol[]
---@param config table
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols, config)
  local bufnr = vim.api.nvim_get_current_buf()
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  if symbol_cache and symbol_cache.key == cache_key then
    return symbol_cache.items
  end

  local items = {}
  -- [local] function to generate unique signature for symbols
  -- main reason is to allow for keep arent symbols showing
  local function generate_signature(symbol, depth)
    local range = symbol.range or (symbol.location and symbol.location.range)
    if not range then
      return nil
    end

    return string.format("%s:%d:%d:%d", symbol.name, depth, range.start.line, range.start.character)
  end

  ---[local] Recursively processes each symbol and its children into SelectaItem format with proper indentation
  ---@param result LSPSymbol
  ---@param depth number Current depth level
  local function process_symbol_result(result, depth, parent_stack)
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

    -- Generate signature for current item
    local signature = generate_signature(result, depth)

    if not lsp.should_include_symbol(result, config, vim.bo.filetype) then
      if result.children then
        for _, child in ipairs(result.children) do
          process_symbol_result(child, depth, parent_stack)
        end
      end
      return
    end
    -- Get parent signature from the stack based on depth
    local parent_signature = depth > 0 and parent_stack[depth] or nil

    -- Create the item
    local clean_name = result.name:match("^([^%s%(]+)") or result.name
    clean_name = state.original_ft == "markdown" and result.name or clean_name
    local style = tonumber(config.display.style) or 2
    local prefix = ui.get_prefix(depth, style)
    local display_text = prefix .. clean_name

    local kind = lsp.symbol_kind(result.kind)
    local item = {
      value = {
        text = clean_name,
        name = clean_name,
        kind = kind,
        lnum = range.start.line + 1,
        col = range.start.character + 1,
        end_lnum = range["end"].line + 1,
        end_col = range["end"].character + 1,
        signature = signature,
        parent_signature = parent_signature,
      },
      -- PERF: we need this for matcher.
      text = clean_name,
      bufnr = bufnr,
      icon = config.kindIcons[kind] or config.icon,
      kind = kind,
      depth = depth,
    }

    table.insert(items, item)

    -- Store current signature as parent for next depth level
    parent_stack[depth + 1] = signature

    if result.children then
      for _, child in ipairs(result.children) do
        process_symbol_result(child, depth + 1, parent_stack)
      end
    end

    -- Clean up the stack when leaving this depth
    parent_stack[depth + 1] = nil
  end

  for _, symbol in ipairs(raw_symbols) do
    process_symbol_result(symbol, 0, {})
  end

  if config.display.format == "tree_guides" then
    items = format_utils.add_tree_state_to_items(items)
  end

  symbol_cache = { key = cache_key, items = items }
  symbol_utils.update_symbol_ranges_cache(items, symbol_range_cache)

  return items
end

---Main entry point for symbol jumping functionality
---@param config table Configuration settings
---@param opts? {filter_kind?: string} Optional settings to filter specific kinds
function M.show(config, opts)
  opts = opts or {}
  initialize_state(config)
  local notify_opts = { title = "Namu", icon = config.icon }

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
    symbol_utils.show_picker(items, state, config, ui, selecta, "LSP Symbols", notify_opts)
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
    local selectaItems = symbols_to_selecta_items(result, config)

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

    symbol_utils.show_picker(selectaItems, state, config, ui, selecta, "LSP Symbols", notify_opts)
  end)
end

-- Expose test utilities
M._test = {
  symbols_to_selecta_items = function(raw_symbols)
    -- This wrapper ensures compatibility with the original test API
    return symbols_to_selecta_items(raw_symbols, require("namu.namu_symbols.config").values)
  end,
}

return M
