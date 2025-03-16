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
local state = nil
local handlers = nil

local function initialize_state()
  -- Clear any existing highlights if state exists
  if state and state.original_win and state.preview_ns then
    ui.clear_preview_highlight(state.original_win, state.preview_ns)
  end

  -- Create new state
  state = symbol_utils.create_state("namu_ctags_preview")
  state.original_win = vim.api.nvim_get_current_win()
  state.original_buf = vim.api.nvim_get_current_buf()
  state.original_ft = vim.bo.filetype
  state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)

  -- FIX: I need to find better way of doing this
  -- If i moved this to setup then it's an issue and intervene with other modules
  -- Recreate handlers with new state
  handlers = symbol_utils.create_keymaps_handlers(M.config, state, ui, selecta, ext, utils)
  -- Update keymap handlers
  if M.config.custom_keymaps then
    M.config.custom_keymaps.yank.handler = handlers.yank
    M.config.custom_keymaps.delete.handler = handlers.delete
    M.config.custom_keymaps.vertical_split.handler = handlers.vertical_split
    M.config.custom_keymaps.horizontal_split.handler = handlers.horizontal_split
    M.config.custom_keymaps.codecompanion.handler = handlers.codecompanion
    M.config.custom_keymaps.avante.handler = handlers.avante
  end
end

-- Symbol cache
local symbol_cache = nil
local symbol_range_cache = {}

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
  local scope_signatures = {}

  -- Calculate depth based on scope
  local function get_scope_depth(scope)
    if not scope then
      return 0
    end
    -- Special handling for Lua
    if state.original_ft == "lua" then
      -- For Lua, we don't count dots as nesting for module patterns
      ---@diagnostic disable-next-line: undefined-global
      if scope and scopeKind == "unknown" then
        return 0 -- Module pattern, don't create artificial nesting
      end
      -- Only count actual nesting (like methods in classes)
      ---@diagnostic disable-next-line: undefined-global
      return scopeKind == "class" and 1 or 0
    end
    -- For other languages, count dots for nesting depth
    return select(2, scope:gsub("%.", "")) + 1
  end

  local function get_display_name(symbol)
    if state.original_ft == "lua" then
      -- For Lua, show full name for module patterns
      if symbol.scope and symbol.scopeKind == "unknown" then
        return symbol.scope .. "." .. symbol.name
      end
    end
    return symbol.name
  end

  local function generate_signature(symbol, depth)
    if not symbol or not symbol.line then
      return nil
    end
    -- For Lua, include full scope in signature for module patterns
    local name = symbol.name
    if state.original_ft == "lua" and symbol.scope and symbol.scopeKind == "unknown" then
      name = symbol.scope .. "." .. symbol.name
    end
    return string.format("%s:%d:%d:1", symbol.name, depth, symbol.line)
  end

  -- First pass: generate signatures for all scopes
  for _, symbol in ipairs(raw_symbols) do
    if symbol.kind == "class" then
      local depth = get_scope_depth(symbol.scope)
      local signature = generate_signature(symbol, depth)
      -- Store with full scope path if it exists
      local full_scope = symbol.scope and (symbol.scope .. "." .. symbol.name) or symbol.name
      scope_signatures[full_scope] = signature
    end
  end

  local function process_symbol_result(result)
    if not result or not result.name then
      return
    end
    logger.log("Processing symbol: " .. vim.inspect(result))
    local depth = get_scope_depth(result.scope)
    local parent_signature = nil
    -- Get parent signature based on scope
    if result.scope then
      parent_signature = scope_signatures[result.scope]
    end
    local kind = lsp.symbol_kind(symbolKindMap[result.kind])
    local signature = generate_signature(result, depth)
    local display_name = get_display_name(result)
    -- If this is a class, store its signature with full scope path
    if result.kind == "class" then
      local full_scope = result.scope and (result.scope .. "." .. result.name) or result.name
      scope_signatures[full_scope] = signature
    end

    local item = {
      value = {
        text = display_name,
        name = display_name,
        kind = kind,
        lnum = result.line,
        col = 1,
        end_lnum = (result["end"] or result.line) + 1,
        end_col = 100,
        signature = signature,
        parent_signature = parent_signature,
      },
      icon = M.config.kindIcons[kind] or M.config.icon,
      kind = kind,
      depth = depth,
    }

    logger.log("ctags_symbols parent: " .. vim.inspect({ item }))
    table.insert(items, item)
  end
  for _, symbol in ipairs(raw_symbols) do
    process_symbol_result(symbol)
  end
  if M.config.display.format == "tree_guides" then
    items = format_utils.add_tree_state_to_items(items)
  end
  for _, item in ipairs(items) do
    item.text = format_utils.format_item_for_display(item, M.config)
  end
  symbol_cache = { key = cache_key, items = items }
  symbol_utils.update_symbol_ranges_cache(items, symbol_range_cache)

  return items
end

-- Add the new request_symbols function
---@param bufnr number
---@param callback fun(err: any, result: any, ctx: any)
local function request_symbols(bufnr, callback)
  -- Cancel any existing request
  if state.current_request then
    local client = state.current_request.client
    client.kill(9)
    state.current_request = nil
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
    state.current_request = {
      client = request,
    }
  else
    -- Handle the case where the request was not successful
    callback("Request failed or request_id was nil", nil, nil)
  end

  return state.current_request
end

---Main entry point for symbol jumping functionality
function M.show(opts)
  opts = opts or {}
  initialize_state()
  -- TODO: Move this to the setup highlights
  vim.api.nvim_set_hl(0, M.config.highlight, {
    link = "Visual",
  })

  local notify_opts = { title = "Namu", icon = M.config.icon }

  -- Use cached symbols if available
  local bufnr = state.original_buf
  local cache_key = string.format("%d_%d", bufnr, vim.b[bufnr].changedtick or 0)

  if symbol_cache and symbol_cache.key == cache_key then
    local items = symbol_cache.items
    -- If filter_kind is specified, filter the cached items
    if opts.filter_kind then
      items = vim.tbl_filter(function(item)
        return item.kind == opts.filter_kind
      end, items)
    end
    symbol_utils.show_picker(items, state, M.config, ui, selecta, "Ctags", notify_opts, true)
    return
  end

  -- Log initial state
  logger.log("CTags show() - Symbol range cache entries: " .. #symbol_range_cache)
  request_symbols(state.original_buf, function(err, result, _)
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

    symbol_utils.show_picker(selectaItems, state, M.config, ui, selecta, "Ctags", notify_opts, true)
  end)
end

M._test = {
  symbols_to_selecta_items = symbols_to_selecta_items,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  logger.log("CTags setup() - Config: " .. vim.inspect(M.config))
end

return M
