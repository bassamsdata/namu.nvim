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
local logger = require("namu.utils.logger")

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

-- Function to extract test information from Lua test patterns
local function extract_lua_test_info(line_content)
  -- Try bracket notation pattern: T["Category"]["TestName"]
  local namespace, parent_name, child_name = line_content:match('(%w+)%["([^"]+)"%]%["([^"]+)"%]%s*=')
  if namespace and parent_name and child_name then
    return {
      namespace = namespace,
      parent_name = parent_name,
      child_name = child_name,
      full_name = namespace .. '["' .. parent_name .. '"]["' .. child_name .. '"]',
      parent_full_name = namespace .. '["' .. parent_name .. '"]',
      child_display = '["' .. child_name .. '"]', -- Just the child part with brackets
    }
  end
  -- Try bracket notation with single quotes
  namespace, parent_name, child_name = line_content:match("(%w+)%['([^']+)'%]%['([^']+)'%]%s*=")
  if namespace and parent_name and child_name then
    return {
      namespace = namespace,
      parent_name = parent_name,
      child_name = child_name,
      full_name = namespace .. "['" .. parent_name .. "']['" .. child_name .. "']",
      parent_full_name = namespace .. "['" .. parent_name .. "']",
      child_display = "['" .. child_name .. "']", -- Just the child part with brackets
    }
  end

  logger.log("No test pattern found in line")
  return nil
end

---Converts LSP symbols to selecta-compatible items with proper formatting
---@param raw_symbols LSPSymbol[]
---@param config table
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols, config)
  local bufnr = vim.api.nvim_get_current_buf()
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  local is_test_file = buf_name:match("_spec%.lua$")
    or buf_name:match("_test%.lua$")
    or buf_name:match("/tests/.+%.lua$")

  logger.log("File detected as test file: " .. tostring(is_test_file))
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

    -- Special handling for Lua test functions with empty or meaningless names
    if
      state.original_ft == "lua"
      and config.enhance_lua_test_symbols
      and (result.name == "" or result.name == " " or result.name:match("^function"))
      and range
    then
      -- Get the line content to extract the test name
      local line = vim.api.nvim_buf_get_lines(state.original_buf, range.start.line, range.start.line + 1, false)[1]
      local test_info = extract_lua_test_info(line)
      if test_info then
        -- If hierarchical organization is enabled
        if config.lua_test_preserve_hierarchy then
          local second_bracket_pos = line:find('%["', line:find('%["') + 3) or line:find("%['", line:find("%['") + 3)
          if second_bracket_pos then
            -- Update the position to the start of the second bracket
            range.start.character = second_bracket_pos - 1
          else
            -- Fallback to beginning of line if pattern not found
            range.start.character = 0
          end
          -- Look for an existing parent node
          local parent_found = false
          local parent_signature = nil
          for _, item in ipairs(items) do
            if item.value and item.value.name == test_info.parent_full_name then
              parent_found = true
              parent_signature = item.value.signature
              break
            end
          end

          -- Create parent node if it doesn't exist
          if not parent_found then
            -- Create parent symbol object
            local parent_symbol = {
              name = test_info.parent_full_name,
              kind = 5, -- Class kind for test suites TODO: might change it to method
              range = {
                start = { line = range.start.line - 1, character = 0 },
                ["end"] = { line = range.start.line, character = 0 },
              },
            }
            -- Generate signature for parent
            local parent_sig = generate_signature(parent_symbol, 0)
            if parent_sig then
              -- Store the parent's signature for child reference
              parent_signature = parent_sig
              -- Directly create parent item without recursion to avoid loops
              local style = tonumber(config.display.style) or 2
              local prefix = ui.get_prefix(0, style)
              local kind = lsp.symbol_kind(parent_symbol.kind)

              local parent_item = {
                value = {
                  text = test_info.parent_full_name,
                  name = test_info.parent_full_name,
                  kind = kind,
                  lnum = range.start.line,
                  col = 1,
                  end_lnum = range.start.line + 1,
                  end_col = 1,
                  signature = parent_sig,
                },
                text = test_info.parent_full_name,
                bufnr = bufnr,
                icon = config.kindIcons[kind] or config.icon,
                kind = kind,
                depth = 0,
              }

              table.insert(items, parent_item)
            end
          end

          -- Set this test as a child of the parent
          if parent_signature then
            result.parent_signature = parent_signature
            -- For children in hierarchy mode, only use the child part for display
            result.name = test_info.child_display
            depth = 1 -- Explicitly set depth for test children
          end
        else
          -- Not in hierarchy mode - use full name
          result.name = test_info.full_name
          range.start.character = 0
        end

        -- Truncate if configured (after setting the appropriate name)
        if config.lua_test_truncate_length and #result.name > config.lua_test_truncate_length then
          result.name = result.name:sub(1, config.lua_test_truncate_length) .. "..."
        end
      end
    end
    -- Generate signature for current item
    local signature = generate_signature(result, depth)
    if not lsp.should_include_symbol(result, config, vim.bo.filetype) then
      logger.log("Symbol should not be included, checking for children")
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
    local clean_name = result.name
    if not is_test_file then
      clean_name = result.name:match("^([^%s%(]+)") or result.name
    end
    clean_name = state.original_ft == "markdown" and result.name or clean_name

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
    symbol_utils.show_picker(items, state, config, ui, selecta, "LSP Symbols", notify_opts, false, "buffer")
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

    symbol_utils.show_picker(selectaItems, state, config, ui, selecta, "LSP Symbols", notify_opts, false, "buffer")
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
