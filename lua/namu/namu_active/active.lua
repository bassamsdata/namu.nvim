--[[ Namu Active Buffers Implementation
This file contains the actual implementation for displaying symbols from active buffers.
It is loaded only when required to improve startup performance.
]]

---@diagnostic disable: unused-local
local async_module = require("namu.core.async")
---@diagnostic disable-next-line: missing-fields
local Async = async_module.Async.new({ max_concurrent = 5, default_timeout = 15 })
local Promise = async_module.Promise
local lsp = require("namu.namu_symbols.lsp")
local ui = require("namu.namu_symbols.ui")
local selecta = require("namu.selecta.selecta")
local symbol_utils = require("namu.core.symbol_utils")
local format_utils = require("namu.core.format_utils")
local treesitter_symbols = require("namu.core.treesitter_symbols")
local utils = require("namu.core.utils")
local logger = require("namu.utils.logger")
local api = vim.api

local M = {}

---@type NamuState
local state = nil

local function initialize_state()
  if state and state.original_win and state.preview_ns then
    ui.clear_preview_highlight(state.original_win, state.preview_ns)
    state.original_win = nil
    state.original_buf = nil
    state.original_ft = nil
    state.original_pos = nil
  end

  state = symbol_utils.create_state("namu_active_symbols_preview")
  state.original_win = api.nvim_get_current_win()
  state.original_buf = api.nvim_get_current_buf()
  state.original_ft = vim.bo.filetype
  state.original_pos = api.nvim_win_get_cursor(state.original_win)
end

---Open diagnostic in vertical split
---@param config table
---@param items_or_item table|table[]
---@param module_state table
function M.open_in_vertical_split(config, items_or_item, module_state)
  local item = vim.islist(items_or_item) and items_or_item[1] or items_or_item
  selecta.open_in_split(item, "vertical", state)
  -- TODO: Refactor clearning namespaces
  api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
  api.nvim_buf_clear_namespace(item.bufnr, state.preview_ns, 0, -1)
  return false
end

---Open diagnostic in horizontal split
---@param config table
---@param items_or_item table|table[]
---@param module_state table
function M.open_in_horizontal_split(config, items_or_item, module_state)
  local item = vim.islist(items_or_item) and items_or_item[1] or items_or_item
  selecta.open_in_split(item, "horizontal", state)
  -- TODO: Refactor clearning namespaces
  api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
  api.nvim_buf_clear_namespace(item.bufnr, state.preview_ns, 0, -1)
  return false
end

--- Convert LSP symbols to selecta items, adding source information
---@param raw_symbols LSPSymbol[]
---@param source string "lsp"
---@param bufnr number
---@param config_values table
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols, source, bufnr, config_values)
  local items = {}
  local buffer_filetype = api.nvim_get_option_value("filetype", { buf = bufnr })

  local function generate_signature(symbol, depth)
    local range = symbol.range or (symbol.location and symbol.location.range)
    if not range then
      return nil
    end
    return string.format("%s:%d:%d:%d", symbol.name, depth, range.start.line, range.start.character)
  end

  local function process_symbol_result(result, depth, parent_stack)
    if not result or not result.name then
      logger.log("Active: Skipping symbol with no name")
      return
    end

    local range = result.range or (result.location and result.location.range)
    if not range or not range.start or not range["end"] then
      return
    end
    local signature = generate_signature(result, depth)

    -- Only do filtering for LSP symbols - TreeSitter symbols are already filtered
    if source == "lsp" and not lsp.should_include_symbol(result, config_values, buffer_filetype) then
      if result.children then
        for _, child in ipairs(result.children) do
          process_symbol_result(child, depth, parent_stack)
        end
      end
      return
    end

    local parent_signature = depth > 0 and parent_stack[depth] or "buffer:" .. bufnr
    local clean_name = result.name:match("^([^%s%(]+)") or result.name
    clean_name = state.original_ft == "markdown" and result.name or clean_name
    local style = tonumber(config_values.display.style) or 2
    local prefix = ui.get_prefix(depth, style)
    local display_text = prefix .. clean_name

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
      icon = config_values.kindIcons[kind_name] or config_values.icon,
      bufnr = bufnr,
      kind = kind_name,
      depth = depth,
      source = source,
      text = display_text,
    }
    table.insert(items, item)
    parent_stack[depth + 1] = signature
    -- Process children
    if result.children then
      for _, child in ipairs(result.children) do
        process_symbol_result(child, depth + 1, parent_stack)
      end
    end
    parent_stack[depth + 1] = nil
  end

  for _, symbol in ipairs(raw_symbols) do
    process_symbol_result(symbol, 0, {})
  end
  if config_values.display and config_values.display.format == "tree_guides" then
    items = format_utils.add_tree_state_to_items(items)
  end

  -- for _, item in ipairs(items) do
  --   -- Add visual indicator of the source (LSP or TreeSitter)
  --   local source_prefix = source == "lsp" and " " or " "
  --   item.text = source_prefix .. format_utils.format_item_for_display(item, config_values)
  -- end

  logger.log("Active: Converted to " .. #items .. " items for display")
  return items
end

-- Function to process buffer with TreeSitter
local function process_with_treesitter(bufnr, config, promise)
  local ts_symbols = treesitter_symbols.get_symbols(bufnr)
  if ts_symbols and #ts_symbols > 0 then
    logger.log("Active: Got " .. #ts_symbols .. " TreeSitter symbols for buffer " .. bufnr)
    promise:resolve(symbols_to_selecta_items(ts_symbols, "treesitter", bufnr, config))
  else
    logger.log("Active: No TreeSitter symbols for buffer " .. bufnr)
    promise:resolve({}, "No symbols available")
  end
end

--- Process a single buffer to get symbols (LSP Only)
---@param bufnr integer
---@param config table
---@return Promise<SelectaItem[], string?>
local function process_buffer(bufnr, config)
  local promise = Promise.new()
  logger.log("Active: Processing buffer " .. bufnr)
  if
    not vim.fn.getbufvar(bufnr, "&buflisted") == 1
    or vim.bo[bufnr].buftype ~= ""
    or not api.nvim_buf_is_valid(bufnr)
    or not api.nvim_buf_is_loaded(bufnr)
    -- or utils.is_big_buffer(bufnr)
  then
    promise:resolve({}, "Buffer invalid or not loaded")
    return promise
  end
  local method = "textDocument/documentSymbol"
  local params = lsp.make_params(bufnr, method)
  -- Check if we have an LSP client with the documentSymbol method
  local lsp_client = lsp.get_client_with_method(bufnr, method)
  local has_lsp = lsp_client ~= nil
  if has_lsp then
    -- Use LSP if available
    logger.log("Active: Requesting LSP symbols for buffer " .. bufnr)
    Async:lsp_request(bufnr, method, params):and_then(function(lsp_symbols)
      if lsp_symbols and #lsp_symbols > 0 then
        logger.log("Active: Got " .. #lsp_symbols .. " LSP symbols for buffer " .. bufnr)
        promise:resolve(symbols_to_selecta_items(lsp_symbols, "lsp", bufnr, config))
      else
        process_with_treesitter(bufnr, config, promise)
      end
    end, function(err)
      -- LSP error, try TreeSitter
      process_with_treesitter(bufnr, config, promise)
    end)
  else
    -- No LSP, directly use TreeSitter
    logger.log("Active: No LSP for buffer " .. bufnr .. ", trying TreeSitter")
    process_with_treesitter(bufnr, config, promise)
  end

  return promise
end

--- Main function to show active buffer symbols
---@param config table
function M.show(config)
  initialize_state()

  local bufs = api.nvim_list_bufs()
  local buffer_results = {}
  local num_processed = 0
  local total_bufs = #bufs
  local current_bufnr = api.nvim_get_current_buf()

  local function on_buffer_processed(items, bufnr, err)
    num_processed = num_processed + 1
    if err then
      vim.notify("Error processing buffer: " .. err, vim.log.levels.WARN, { title = "Namu" })
    elseif items and #items > 0 then
      -- Store results for this buffer
      buffer_results[bufnr] = items
    end
    if num_processed == total_bufs then
      local all_items = {}
      -- Process buffers in desired order
      local ordered_bufs = {}
      -- Current buffer first
      table.insert(ordered_bufs, current_bufnr)
      -- Then other buffers
      for _, buf in ipairs(bufs) do
        if buf ~= current_bufnr then
          table.insert(ordered_bufs, buf)
        end
      end
      -- Track buffer positions when building the item list
      -- TODO: those for future navigations between buffers
      local buffer_positions = {}
      local current_buffer_index = 1
      local buffer_count = 0
      -- Add items in proper hierarchy
      for _, bufnr in ipairs(ordered_bufs) do
        local items = buffer_results[bufnr]
        if items and #items > 0 then
          buffer_count = buffer_count + 1
          -- Record the position where this buffer starts in the item list
          buffer_positions[buffer_count] = {
            index = #all_items + 1, -- +1 because we're about to add the buffer item
            bufnr = bufnr,
            name = vim.fn.bufname(bufnr) ~= "" and vim.fn.fnamemodify(vim.fn.bufname(bufnr), ":t")
              or "[Buffer " .. bufnr .. "]",
          }
          -- Mark the current buffer's position
          if bufnr == current_bufnr then
            current_buffer_index = buffer_count
          end
          -- Add buffer header
          local buf_name = vim.fn.bufname(bufnr) or ""
          local display_name = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":t") or "[Buffer " .. bufnr .. "]"
          -- Get file icon and highlight for the buffer
          local icon, icon_hl = "󰈙", "Normal" -- Default icon
          if buf_name and buf_name ~= "" then
            icon, icon_hl = utils.get_file_icon(buf_name)
          end
          local source_indicator = ""
          if #items > 0 then
            source_indicator = " [" .. (items[1].source == "lsp" and "󰿘 " or " ") .. "]"
            logger.log("Active: Buffer " .. bufnr .. " using " .. items[1].source .. " symbols")
          end
          local buffer_item = {
            text = display_name .. source_indicator,
            icon = icon,
            icon_hl = icon_hl,
            kind = "buffer",
            is_root = true, -- TODO: need to remove later, if no use in navigation
            depth = 0,
            value = {
              bufnr = bufnr,
              name = display_name .. source_indicator,
              full_path = buf_name,
              signature = "buffer:" .. bufnr,
              lnum = 0,
              end_lnum = math.huge,
              col = 0,
              end_col = math.huge,
            },
          }
          -- Mark current buffer
          if bufnr == current_bufnr then
            buffer_item.text = buffer_item.text .. " (current)"
          end
          -- Add buffer header
          table.insert(all_items, buffer_item)
          for _, item in ipairs(items) do
            table.insert(all_items, item)
          end
        end
      end
      if #all_items == 0 then
        vim.notify("No LSP symbols found in active buffers", vim.log.levels.WARN, { title = "Namu" })
      else
        symbol_utils.show_picker(all_items, state, config, ui, selecta, "Active Symbols (LSP)", { title = "Namu" })
      end
    end
  end
  if total_bufs == 0 then
    vim.notify("No active buffers found", vim.log.levels.WARN, { title = "Namu" })
    return
  end

  for _, bufnr in ipairs(bufs) do
    process_buffer(bufnr, config):and_then(function(items)
      on_buffer_processed(items, bufnr, nil)
    end, function(err)
      on_buffer_processed(nil, bufnr, err)
    end)
  end
end

return M
