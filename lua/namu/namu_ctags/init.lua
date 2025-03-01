local selecta = require("namu.selecta.selecta")
local logger = require("namu.utils.logger")
local lsp = require("namu.namu_symbols.lsp")
local symbolKindMap = require("namu.namu_ctags.kindmap").symbolKindMap
local ui = require("namu.namu_symbols.ui")
local ext = require("namu.namu_symbols.external_plugins")
local utils = require("namu.namu_symbols.utils")
local symbol_utils = require("namu.core.symbol_utils")
local M = {}

---@type NamuConfig
M.config = require("namu.namu_symbols").config

---@type NamuState
local state = symbol_utils.create_state("namu_ctags_preview")

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
  local tree = {}

  ---[local] Recursively processes each symbol and its children into SelectaItem format with proper indentation
  ---@param result TagEntry
  local function process_symbol_result(result)
    if not result or not result.name then
      return
    end

    local depth = 0

    if result.scope then
      depth = tree[result.scope] or -1
      depth = depth + 1
      tree[result.name] = depth
    else
      tree[result.name] = depth
    end
    local clean_name = result.name:match("^([^%s%(]+)") or result.name
    clean_name = state.original_ft == "markdown" and result.name or clean_name
    local style = tonumber(M.config.display.style) or 2
    local prefix = ui.get_prefix(depth, style)
    local display_text = prefix .. clean_name

    local kind = lsp.symbol_kind(symbolKindMap[result.kind])

    local item = {
      text = display_text,
      value = {
        text = clean_name,
        name = clean_name,
        kind = kind,
        lnum = result.line,
        col = 1,
        end_lnum = (result["end"] or result.line) + 1,
        end_col = 100,
      },
      icon = M.config.kindIcons[kind] or M.config.icon,
      kind = kind,
      depth = depth,
    }

    table.insert(items, item)
  end

  for _, symbol in ipairs(raw_symbols) do
    process_symbol_result(symbol)
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

---Initializes the module with user configuration
function M.setup(opts)
  -- config.setup(opts or {})
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  -- Initialize all the handlers properly
  if M.config.custom_keymaps then
    local handlers = symbol_utils.create_keymaps_handlers(M.config, state, ui, selecta, ext, utils)
    M.config.custom_keymaps.yank.handler = handlers.yank
    M.config.custom_keymaps.delete.handler = handlers.delete
    M.config.custom_keymaps.vertical_split.handler = handlers.vertical_split
    M.config.custom_keymaps.horizontal_split.handler = handlers.horizontal_split
    M.config.custom_keymaps.codecompanion.handler = handlers.codecompanion
    M.config.custom_keymaps.avante.handler = handlers.avante
  end
end

return M
