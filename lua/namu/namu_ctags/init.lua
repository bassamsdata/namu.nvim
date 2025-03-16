local selecta = require("namu.selecta.selecta")
local logger = require("namu.utils.logger")
local lsp = require("namu.namu_symbols.lsp")
local symbolKindMap = require("namu.namu_ctags.kindmap").symbolKindMap
local ui = require("namu.namu_symbols.ui")
local ext = require("namu.namu_symbols.external_plugins")
local utils = require("namu.namu_symbols.utils")
local symbol_utils = require("namu.core.symbol_utils")
local format_utils = require("namu.core.format_utils")
local M = {}

---@type NamuCoreConfig
M.config = require("namu.namu_symbols.config").values

---@type NamuState
local state_ctags = symbol_utils.create_state("namu_ctags_preview")
if M.config.custom_keymaps then
  local handlers = symbol_utils.create_keymaps_handlers(M.config, state_ctags, ui, selecta, ext, utils)
  M.config.custom_keymaps.yank.handler = handlers.yank
  M.config.custom_keymaps.delete.handler = handlers.delete
  M.config.custom_keymaps.vertical_split.handler = function(item)
    return handlers.vertical_split(item)
  end
  M.config.custom_keymaps.horizontal_split.handler = handlers.horizontal_split
  M.config.custom_keymaps.codecompanion.handler = handlers.codecompanion
  M.config.custom_keymaps.avante.handler = handlers.avante
end

-- Symbol cache
local symbol_cache = nil
local symbol_range_cache = {}

-- Cache for symbol kinds
local symbol_kinds = nil

---Converts LSP symbols to selecta-compatible items with proper formatting
---@param raw_symbols TagEntry[]
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols)
  local bufnr = vim.api.nvim_get_current_buf()
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  if symbol_cache and symbol_cache.key == cache_key then
    return symbol_cache.items
  end

  local items = {}
  local parent_stack = {}
  local scope_to_signature = {}
  local class_depth_map = {} -- Track class depths

  -- Generate a unique signature for a symbol
  local function generate_signature(symbol, depth)
    if not symbol or not symbol.line then
      return nil
    end
    -- Include full scope path in signature to maintain hierarchy
    local scope_part = symbol.scope and ("." .. symbol.scope) or ""
    return string.format("%s%s:%d:%d:1", symbol.name, scope_part, depth, symbol.line)
  end

  -- Calculate symbol depth based on scope
  local function get_symbol_depth(symbol)
    if not symbol.scope then
      return 0
    end

    -- Count the number of dots in scope to determine depth
    local dots = symbol.scope:gsub("[^%.]+", "")
    return #dots + 1
  end

  local function process_symbol_result(result)
    if not result or not result.name then
      return
    end

    logger.log("Processing symbol: " .. vim.inspect({
      name = result.name,
      kind = result.kind,
      scope = result.scope,
      scopeKind = result.scopeKind,
    }))

    -- Calculate depth based on scope nesting
    local depth = get_symbol_depth(result)
    logger.log("ctags_symbols depth: " .. vim.inspect({ depth }))

    -- Track class depths for nested classes
    if result.kind == "class" then
      class_depth_map[result.name] = depth
      if result.scope then
        class_depth_map[result.scope .. "." .. result.name] = depth
      end
    end

    -- Determine parent signature based on scope
    local parent_signature = nil
    if result.scope then
      parent_signature = scope_to_signature[result.scope]
    end

    -- Generate signature for current symbol
    local signature = generate_signature(result, depth)
    if signature then
      scope_to_signature[result.name] = signature
      if result.scope then
        scope_to_signature[result.scope .. "." .. result.name] = signature
      end
    end

    local clean_name = result.name:match("^([^%s%(]+)") or result.name
    clean_name = state_ctags.original_ft == "markdown" and result.name or clean_name

    -- Get symbol kind with proper mapping
    local kind = lsp.symbol_kind(symbolKindMap[result.kind] or vim.lsp.protocol.SymbolKind.Function)

    local item = {
      value = {
        text = clean_name,
        name = clean_name,
        kind = kind,
        lnum = result.line,
        col = 1,
        end_lnum = (result["end"] or result.line) + 1,
        end_col = 100,
        signature = signature,
        parent_signature = parent_signature,
        scope = result.scope, -- Store scope for debugging
      },
      icon = M.config.kindIcons[kind] or M.config.icon,
      kind = kind,
      depth = depth,
    }

    table.insert(items, item)
  end

  -- First pass: process all symbols
  for _, symbol in ipairs(raw_symbols) do
    process_symbol_result(symbol)
  end

  -- Sort items by line number to maintain proper order
  table.sort(items, function(a, b)
    return a.value.lnum < b.value.lnum
  end)

  -- Add tree guides if configured
  if M.config.display.format == "tree_guides" then
    logger.log("ctags_symbols before tree: " .. vim.inspect(items))
    items = format_utils.add_tree_state_to_items(items)
  end

  -- Set display text for all items based on format
  for _, item in ipairs(items) do
    item.text = format_utils.format_item_for_display(item, M.config)
  end

  symbol_cache = { key = cache_key, items = items }
  logger.log("symbols_to_selecta_items() - Created " .. #items .. " items")
  logger.log("symbols_to_selecta_items() - Symbol range cache size before: " .. #symbol_range_cache)
  symbol_utils.update_symbol_ranges_cache(items, symbol_range_cache)

  return items
end

-- Add the new request_symbols function
---@param bufnr number
---@param callback fun(err: any, result: any, ctx: any)
local function request_symbols(bufnr, callback)
  -- Cancel any existing request
  if state_ctags.current_request then
    local client = state_ctags.current_request.client
    client.kill(9)
    state_ctags.current_request = nil
  end

  local path = vim.api.nvim_buf_get_name(bufnr)

  -- parse ctags
  local request = vim.system(
    { "ctags", "--output-format=json", "--sort=no", "--fields='{scope}{name}{line}{end}{kind}{scopeKind}'", path },
    { text = true },
    function(obj)
      local result = nil
      local request_err = nil
      if obj.code ~= 0 then
        request_err = obj
      else
        local lines = vim.split(obj.stdout, "[\r]?\n")
        result = {}
        for _, line in ipairs(lines) do
          local ok, dec = pcall(vim.json.decode, line)
          if ok then
            table.insert(result, dec)
          end
        end
      end
      vim.schedule(function()
        callback(request_err, result, ctx)
      end)
    end
  )
  -- Check if the request was successful
  local ok, closed = pcall(request.is_closing)
  if not ok then
    -- request ended
    return nil
  end
  if not closed and request.pid then
    -- Store the client and request_id
    state_ctags.current_request = {
      client = request,
    }
  else
    -- Handle the case where the request was not successful
    callback("Request failed or request_id was nil", nil, nil)
  end

  return state_ctags.current_request
end

---Main entry point for symbol jumping functionality
function M.show(opts)
  opts = opts or {}
  -- Store current window and position
  state_ctags.original_win = vim.api.nvim_get_current_win()
  state_ctags.original_buf = vim.api.nvim_get_current_buf()
  state_ctags.original_ft = vim.bo.filetype
  state_ctags.original_pos = vim.api.nvim_win_get_cursor(state_ctags.original_win)

  -- TODO: Move this to the setup highlights
  vim.api.nvim_set_hl(0, M.config.highlight, {
    link = "Visual",
  })

  local notify_opts = { title = "Namu", icon = M.config.icon }

  -- Use cached symbols if available
  local bufnr = state_ctags.original_buf
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  if symbol_cache and symbol_cache.key == cache_key then
    local items = symbol_cache.items
    -- If filter_kind is specified, filter the cached items
    if opts.filter_kind then
      items = vim.tbl_filter(function(item)
        return item.kind == opts.filter_kind
      end, items)
    end
    symbol_utils.show_picker(items, state_ctags, M.config, ui, selecta, "Ctags", notify_opts, true)
    return
  end

  -- Log initial state
  logger.log("CTags show() - Symbol range cache entries: " .. #symbol_range_cache)
  request_symbols(state_ctags.original_buf, function(err, result, _)
    if err ~= nil then
      local error_message = err
      if type(err) == "table" then
        error_message = err.stderr or err.stderr
      end
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
    -- Log information about the items
    logger.log("CTags show() - Created " .. #selectaItems .. " selecta items")
    logger.log("CTags show() - Symbol range cache after update: " .. #symbol_range_cache)

    -- Apply filter if specified
    if opts.filter_kind then
      selectaItems = vim.tbl_filter(function(item)
        return item.kind == opts.filter_kind
      end, selectaItems)
    end

    symbol_utils.show_picker(selectaItems, state_ctags, M.config, ui, selecta, "Ctags", notify_opts, true)
  end)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

return M
