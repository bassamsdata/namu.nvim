local selecta = require("namu.selecta.selecta")
local symbolKindMap = require("namu.namu_ctags.kindmap").symbolKindMap
local ui = require("namu.namu_symbols.ui")
local ext = require("namu.namu_symbols.external_plugins")
local utils = require("namu.namu_symbols.utils")
local config = require("namu.namu_symbols.config")
local M = {}
-- Reference the shared config
M.config = config.values

---@class TagEntry
---@field _type string
---@field name string
---@field kind string
---@field line number
---@field end number
---@field scope string

-- Store original window and position for preview
---@type NamuState
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = vim.api.nvim_create_namespace("namu_preview"),
  current_request = nil,
}

local ns_id = vim.api.nvim_create_namespace("namu_ctags")

---@type NamuConfig
M.config = require("namu.namu_symbols").config

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
    local prefix = ui.get_prefix(depth, M.config.display.style or 2)
    local display_text = prefix .. clean_name

    local kind = M.symbol_kind(symbolKindMap[result.kind])

    local item = {
      text = display_text,
      value = {
        text = clean_name,
        name = clean_name,
        kind = kind,
        lnum = result.line,
        col = 1,
        end_lnum = (result["end"] or result.line) + 1,
        end_col = 2,
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

  M.symbol_cache = { key = cache_key, items = items }
  update_symbol_ranges_cache(items)
  return items
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

---Performs the actual jump to selected symbol location
---@param symbol table LSP symbol
local function jump_to_symbol(symbol)
  vim.cmd.normal({ "m`", bang = true }) -- set jump mark
  vim.api.nvim_win_set_cursor(state.original_win, { symbol.lnum, symbol.col - 1 })
end

---@class SymbolTypeFilter
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
    title = "Ctags",
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
    show_picker(items, notify_opts)
    return
  end

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
  config.setup(opts or {})
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  -- Initialize all the handlers properly with access to the correct state
  if M.config.custom_keymaps then
    M.config.custom_keymaps.yank.handler = function(items_or_item)
      local success = utils.yank_symbol_text(items_or_item, state)
      if success and M.config.actions.close_on_yank then
        ui.clear_preview_highlight(state.original_win, state.preview_ns)
        return false
      end
    end
    M.config.custom_keymaps.delete.handler = function(items_or_item)
      local deleted = utils.delete_symbol_text(items_or_item, state)
      if deleted and M.config.actions.close_on_delete then
        ui.clear_preview_highlight(state.original_win, state.preview_ns)
        return false
      end
    end
    M.config.custom_keymaps.vertical_split.handler = function(item, selecta_state)
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
    end
    M.config.custom_keymaps.horizontal_split.handler = function(item, selecta_state)
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
    end
    M.config.custom_keymaps.codecompanion.handler = function(items_or_item)
      ext.codecompanion_handler(items_or_item, state.original_buf)
    end
    M.config.custom_keymaps.avante.handler = function(items_or_item)
      ext.avante_handler(items_or_item, state.original_buf)
    end
  end
end

return M
