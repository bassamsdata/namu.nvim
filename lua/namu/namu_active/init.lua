local async_module = require("namu.core.async")
local Async = async_module.Async.new({ max_concurrent = 5, default_timeout = 15 })
local Promise = async_module.Promise
local lsp = require("namu.namu_symbols.lsp")
local ui = require("namu.namu_symbols.ui")
local selecta = require("namu.selecta.selecta")
local symbol_utils = require("namu.core.symbol_utils")
local config = require("namu.namu_symbols.config")
local format_utils = require("namu.core.format_utils")

local M = {}

-- For backward compatibility
---@NamuSymbolsConfig
M.config = config.values

---@type NamuState
local state = nil

local function initialize_state()
  if state and state.original_win and state.preview_ns then
    ui.clear_preview_highlight(state.original_win, state.preview_ns)
  end

  state = symbol_utils.create_state("namu_active_symbols_preview")
  state.original_win = vim.api.nvim_get_current_win()
  state.original_buf = vim.api.nvim_get_current_buf()
  state.original_ft = vim.bo.filetype
  state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)
end

--- Convert LSP symbols to selecta items, adding source information
---@param raw_symbols LSPSymbol[]
---@param source string "lsp"
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols, source, bufnr)
  local items = {}
  local function generate_signature(symbol, depth)
    local range = symbol.range or (symbol.location and symbol.location.range)
    if not range then
      return nil
    end

    return string.format("%s:%d:%d:%d", symbol.name, depth, range.start.line, range.start.character)
  end

  local function process_symbol_result(result, depth, parent_stack)
    if not result or not result.name then
      return
    end

    local range = result.range or (result.location and result.location.range)
    if not range or not range.start or not range["end"] then
      vim.notify("Symbol '" .. result.name .. "' has invalid structure", vim.log.levels.WARN)
      return
    end

    local signature = generate_signature(result, depth)

    -- BUG: I noticed this doesn't work for some reason, needs to double check
    if not lsp.should_include_symbol(result, config.values, vim.bo.filetype) then
      if result.children then
        for _, child in ipairs(result.children) do
          process_symbol_result(child, depth, parent_stack)
        end
      end
      return
    end

    local parent_signature = depth > 0 and parent_stack[depth] or nil

    local clean_name = result.name:match("^([^%s%(]+)") or result.name
    clean_name = state.original_ft == "markdown" and result.name or clean_name
    local style = tonumber(config.values.display.style) or 2
    local prefix = ui.get_prefix(depth, style)
    local display_text = prefix .. clean_name

    -- TODO: we need buf name so we can assign it as parent or root to be able to filter later.
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
      icon = config.values.kindIcons[kind] or config.values.icon,
      bufnr = bufnr,
      kind = kind,
      depth = depth,
      source = source,
      text = display_text,
    }

    table.insert(items, item)

    parent_stack[depth + 1] = signature

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

  if config.values.display.format == "tree_guides" then
    items = format_utils.add_tree_state_to_items(items)
  end

  -- TODO: this has to be in format items later maybe
  -- Also, the display name is item.value.name
  for _, item in ipairs(items) do
    item.text = (source == "lsp" and " " or " ") .. format_utils.format_item_for_display(item, config.values)
  end

  return items
end

--- Process a single buffer to get symbols (LSP Only)
---@param bufnr integer
---@return Promise<SelectaItem[], string?>
local function process_buffer(bufnr)
  local promise = Promise.new()

  -- TODO: Needs to check listed first because it eliminates a lot, the loaded, valid, and then has lsp or treesitter
  -- no need for filetype after that, maybe use vim.fn.getbufvar(bufnr, "&buflisted") == 1
  -- and probably this will elimnate the error when we don't have lsp, not totally though
  if
    not vim.fn.getbufvar(bufnr, "&buflisted") == 1
    or vim.bo[bufnr].buftype ~= ""
    or not vim.api.nvim_buf_is_valid(bufnr)
    or not vim.api.nvim_buf_is_loaded(bufnr)
  then
    promise:resolve({}, "Buffer invalid or not loaded")
    return promise
  end

  local method = "textDocument/documentSymbol"
  local params = lsp.make_params(bufnr, method)

  Async:lsp_request(bufnr, method, params):and_then(function(lsp_symbols)
    if lsp_symbols and #lsp_symbols > 0 then
      promise:resolve(symbols_to_selecta_items(lsp_symbols, "lsp", bufnr))
    else
      promise:resolve({}, "No LSP symbols found")
    end
  end, function(err)
    promise:reject("LSP error: " .. err)
  end)

  return promise
end

--- Main function to show active buffer symbols
function M.show()
  initialize_state()

  local bufs = vim.api.nvim_list_bufs()
  local all_items = {}
  local num_processed = 0
  local total_bufs = #bufs

  local function on_buffer_processed(items, err)
    num_processed = num_processed + 1
    if err then
      vim.notify("Error processing buffer: " .. err, vim.log.levels.WARN, { title = "Namu" })
      -- TODO: I need to figure out what to do with sort
    elseif items and #items > 0 then
      for _, item in ipairs(items) do
        table.insert(all_items, item)
      end
    end

    if num_processed == total_bufs then
      if #all_items == 0 then
        vim.notify("No LSP symbols found in active buffers", vim.log.levels.WARN, { title = "Namu" })
      else
        symbol_utils.show_picker(all_items, state, M.config, ui, selecta, "Active Symbols (LSP)", { title = "Namu" })
        -- TODO:
        -- on_move should be somthing like this:
        -- PLEASE: Add eventignore
        -- if not vim.api.nvim_win_is_valid(state.original_win) then
        --   return
        -- end
        -- local start_win = state.original_win
        -- local bufnr = item.bufnr
        -- if vim.api.nvim_buf_is_valid(bufnr) then
        --   pcall(vim.api.nvim_win_call, start_win, function()
        --     vim.api.nvim_win_set_buf(start_win, bufnr)
        --   end)
        -- end
        -- ui.preview_symbol(item.value, state.original_win, state.preview_ns)
      end
    end
  end

  if total_bufs == 0 then
    vim.notify("No active buffers found", vim.log.levels.WARN, { title = "Namu" })
    return
  end

  for _, bufnr in ipairs(bufs) do
    process_buffer(bufnr):and_then(function(items)
      on_buffer_processed(items, nil)
    end, function(err)
      on_buffer_processed(nil, err)
    end)
  end
end

return M
