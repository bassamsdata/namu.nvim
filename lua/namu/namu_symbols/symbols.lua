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
local test_patterns = require("namu.namu_symbols.lua_tests")
local logger = require("namu.utils.logger")
local core_utils = require("namu.core.utils")
local treesitter_symbols = require("namu.core.treesitter_symbols")

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
    config.custom_keymaps.quickfix.handler = handlers.quickfix
    config.custom_keymaps.sidebar.handler = handlers.sidebar
  end
end

---Converts LSP symbols to selecta-compatible items with proper formatting
---@param raw_symbols LSPSymbol[]
---@param config table
---@param source? string The source of the symbols ("lsp" or "treesitter")
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols, config, source)
  source = source or "lsp"
  local bufnr = vim.api.nvim_get_current_buf()
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  local is_test_file = buf_name:match("_spec%.lua$")
    or buf_name:match("_test%.lua$")
    or buf_name:match("/tests/.+%.lua$")

  if symbol_cache and symbol_cache.key == cache_key then
    return symbol_cache.items
  end
  local items = {}
  -- Initialize caches needed for Lua test processing
  local first_bracket_counts = {}
  local test_info_cache = {}
  -- First pass: count brackets if hierarchy is enabled for Lua test files
  if is_test_file and config.lua_test_preserve_hierarchy and state.original_ft == "lua" then
    logger.log("Performing first pass to count Lua test brackets for hierarchy.")
    for _, symbol in ipairs(raw_symbols) do
      -- Call the counting function from the test_patterns module
      test_patterns.count_first_brackets(symbol, state, config, test_info_cache, first_bracket_counts)
    end
    -- Log the counts for debugging
    for bracket, count in pairs(first_bracket_counts) do
      logger.log("First bracket count - " .. bracket .. ": " .. count)
    end
  end
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
      logger.log("Skipping symbol processing: result is nil or has no name")
      return
    end
    -- There are two possible schemas for symbols returned by LSP:
    --    SymbolInformation:
    --      { name, kind, location, containerName? }
    --    DocumentSymbol:
    --      { name, kind, range, selectionRange, children? }
    --    In the case of DocumentSymbol, we need to use the `range` field for the symbol position.
    --    In the case of SymbolInformation, we need to use the `location.range` field for the symbol position.
    --    source:
    --      https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.18/language/documentSymbol.md
    -- Get the range from appropriate location based on LSP schema
    local range = result.range or (result.location and result.location.range)
    if not range or not range.start or not range["end"] then
      vim.notify("Symbol '" .. result.name .. "' has invalid structure", vim.log.levels.WARN)
      return
    end

    if
      state.original_ft == "lua"
      and is_test_file
      and config.enhance_lua_test_symbols
      and (result.name == "" or result.name == " " or result.name:match("^function"))
      and range
    then
      -- Call the processing function from the test_patterns module
      local new_depth = test_patterns.process_lua_test_symbol(
        result,
        config,
        state,
        range,
        test_info_cache,
        first_bracket_counts,
        items,
        depth,
        generate_signature,
        lsp.symbol_kind,
        bufnr
      )
      depth = new_depth
    end
    -- Generate signature for current item
    local signature = generate_signature(result, depth)
    if source == "lsp" and not lsp.should_include_symbol(result, config, vim.bo.filetype) then
      if result.children then
        for _, child in ipairs(result.children) do
          process_symbol_result(child, depth, parent_stack)
        end
      end
      return
    end

    -- Get parent signature from the stack based on depth
    local parent_signature = result.parent_signature or (depth > 0 and parent_stack[depth] or nil)

    -- Create the item - Don't use regex for clean_name to prevent truncation
    local clean_name = core_utils.clean_symbol_name(result.name, state.original_ft, is_test_file)

    -- For TreeSitter, we need to map the kind string to a number
    local kind
    if source == "treesitter" then
      kind = lsp.symbol_kind_to_number(result.kind)
    else
      kind = result.kind
    end
    local kind_name = lsp.symbol_kind(kind)

    local item = {
      value = {
        text = clean_name,
        name = clean_name,
        kind = kind_name,
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
      icon = config.kindIcons[kind_name] or config.icon,
      kind = kind_name,
      depth = depth,
      source = source,
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
  if not core_utils.is_big_buffer(bufnr) then
    symbol_cache = {
      key = cache_key,
      items = items,
      source = source,
    }
    symbol_utils.update_symbol_ranges_cache(items, symbol_range_cache)
  end

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
    -- Create prompt info based on source in cache
    local prompt_info = {
      text = symbol_cache.source == "lsp" and "󰿘 " or " ",
      hl_group = "NamuSourceIndicator",
    }
    symbol_utils.show_picker(
      items,
      state,
      config,
      ui,
      selecta,
      "LSP Symbols",
      notify_opts,
      false,
      "buffer",
      prompt_info
    )
    return
  end

  local try_treesitter_first = config.source_priority == "treesitter"
  local ts_attempted = false

  local function try_treesitter()
    ts_attempted = true
    return M.show_treesitter(config, opts, true) -- pass silent as true
  end
  if try_treesitter_first then
    if try_treesitter() then
      return
    end
    logger.log("TreeSitter symbols not available, falling back to LSP")
  end

  lsp.request_symbols(state.original_buf, "textDocument/documentSymbol", function(err, result, _)
    if err or not result or #result == 0 then
      local error_message = err and (type(err) == "table" and err.message or err) or "No results from LSP"
      logger.log("LSP error: " .. error_message)

      -- If LSP failed and we haven't tried TreeSitter yet, try it now
      if not ts_attempted and not try_treesitter_first then
        logger.log("LSP failed, trying TreeSitter")
        if try_treesitter() then
          return
        end
      end
      -- Show a single consolidated error message if both methods failed
      if ts_attempted then
        local ft = vim.bo[state.original_buf].filetype or ""
        local message =
          string.format("No symbol provider for %s buffer (missing LSP/TreeSitter)", ft ~= "" and ft or "this")
        vim.notify(message, vim.log.levels.WARN, notify_opts)
      else
        vim.notify(error_message, vim.log.levels.ERROR, notify_opts)
      end
      return
    end
    local selectaItems = symbols_to_selecta_items(result, config, "lsp")
    -- -- Update cache
    -- symbol_cache = {
    --   key = cache_key,
    --   items = selectaItems,
    --   source = "lsp",
    -- }
    if opts.filter_kind then
      selectaItems = vim.tbl_filter(function(item)
        return item.kind == opts.filter_kind
      end, selectaItems)
    end
    local prompt_info = {
      text = "󰿘 ",
      hl_group = "NamuSourceIndicator",
    }

    symbol_utils.show_picker(
      selectaItems,
      state,
      config,
      ui,
      selecta,
      "LSP Symbols",
      notify_opts,
      false,
      "buffer",
      prompt_info
    )
  end)
end

--- Show symbols from current buffer using TreeSitter
--- @param opts? {filter_kind?: string} Optional settings to filter specific kinds
--- @return boolean True if symbols were found and displayed, false otherwise
function M.show_treesitter(config, opts, silent)
  opts = opts or {}
  initialize_state(config)
  local notify_opts = { title = "Namu", icon = config.icon }

  local bufnr = vim.api.nvim_get_current_buf()
  local ts_symbols = treesitter_symbols.get_symbols(bufnr)
  if not ts_symbols or #ts_symbols == 0 then
    if not silent then
      vim.notify("No TreeSitter symbols found in current buffer", vim.log.levels.WARN, notify_opts)
    else
      logger.log("No TreeSitter symbols found in current buffer")
    end
    return false
  end

  logger.log("Got " .. #ts_symbols .. " TreeSitter symbols")
  local selectaItems = symbols_to_selecta_items(ts_symbols, config, "treesitter")

  if opts and opts.filter_kind then
    selectaItems = vim.tbl_filter(function(item)
      return item.kind == opts.filter_kind
    end, selectaItems)
  end

  if #selectaItems == 0 then
    if not silent then
      vim.notify("No symbols match the specified filter", vim.log.levels.WARN, notify_opts)
    else
      logger.log("No symbols match the specified filter")
    end
    return false
  end

  -- Only cache if not a big buffer
  -- if not core_utils.is_big_buffer(bufnr) then
  -- symbol_cache = {
  --   key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0),
  --   items = selectaItems,
  --   source = "treesitter",
  -- }
  -- symbol_utils.update_symbol_ranges_cache(selectaItems, symbol_range_cache)
  -- end

  local prompt_info = {
    text = " ",
    hl_group = "NamuSourceIndicator",
  }
  symbol_utils.show_picker(
    selectaItems,
    state,
    config,
    ui,
    selecta,
    "TreeSitter Symbols",
    notify_opts,
    false,
    "buffer",
    prompt_info
  )
  return true
end

M._test = {
  symbols_to_selecta_items = function(raw_symbols)
    -- This wrapper ensures compatibility with the original test API
    return symbols_to_selecta_items(raw_symbols, require("namu.namu_symbols.config").values)
  end,
}

return M
