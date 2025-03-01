local M = {}
local logger = require("namu.utils.logger")

-- Factory function to create a state object for a particular module
function M.create_state(namespace)
  return {
    original_win = nil,
    original_buf = nil,
    original_pos = nil,
    original_ft = nil,
    preview_ns = vim.api.nvim_create_namespace(namespace or "namu_preview"),
    current_request = nil,
  }
end

---find_nearest_symbol: Specialized function for CTags data to find symbols by proximity
---@param items table[] Selecta items list
---@return table|nil symbol The nearest symbol if found within threshold
function M.find_nearest_symbol(items)
  -- Cache cursor position
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor_pos[1]
  logger.log("find_nearest_symbol() - Looking for symbol at line " .. cursor_line)
  -- Early exit if no items
  if #items == 0 then
    return nil
  end
  -- First try the standard method - it might work for some CTags entries
  local symbol = M.find_containing_symbol(items)
  if symbol then
    return symbol
  end
  -- Fall back to nearest line method
  local best_symbol = nil
  local smallest_distance = math.huge

  for _, item in ipairs(items) do
    symbol = item.value
    if not symbol.lnum then
      goto continue
    end
    -- Calculate distance (how many lines away)
    local distance = math.abs(cursor_line - symbol.lnum)
    logger.log("find_nearest_symbol() - Symbol at line " .. symbol.lnum)
    logger.log("find_nearest_symbol() - Distance to symbol: " .. distance)
    -- If this symbol is closer than our current best
    if distance < smallest_distance then
      smallest_distance = distance
      best_symbol = item
    end

    ::continue::
  end
  -- Only use nearby symbols (within 10 lines)
  if best_symbol and smallest_distance <= 10 then
    return best_symbol
  end

  return nil
end

---Locates the symbol that contains the current cursor position
---@param items table[] Selecta items list
---@return table|nil symbol The nearest symbol if found within threshold
function M.find_containing_symbol(items)
  -- Cache cursor position
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local cursor_line, cursor_col = cursor_pos[1], cursor_pos[2] + 1

  logger.log("find_containing_symbol() - Looking for symbol at line " .. cursor_line .. ", col " .. cursor_col)
  -- Early exit if no items
  if #items == 0 then
    logger.log("find_containing_symbol() - No items to search")
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
  logger.log("find_containing_symbol() - Binary search returned index " .. start_index)

  -- Search window size
  local WINDOW_SIZE = 10
  local start_pos = math.max(1, start_index - WINDOW_SIZE)
  local end_pos = math.min(#items, start_index + WINDOW_SIZE)
  logger.log("find_containing_symbol() - Searching window from " .. start_pos .. " to " .. end_pos)

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
  logger.log(
    "find_containing_symbol() - Final match: " .. (matching_symbol and matching_symbol.value.name or "none found")
  )

  return matching_symbol
end

---Maintains a cache of symbol ranges for quick lookup
---@param items table[] List of items to cache
---@param symbol_range_cache table Table to store the cache in
function M.update_symbol_ranges_cache(items, symbol_range_cache)
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

---Performs the actual jump to selected symbol location
---@param symbol table LSP symbol
---@param state table State object containing original_win
function M.jump_to_symbol(symbol, state)
  vim.cmd.normal({ "m`", bang = true }) -- set jump mark
  vim.api.nvim_win_set_cursor(state.original_win, { symbol.lnum, symbol.col - 1 })
end

---Parse symbol filter from query string
---@param query string The query string to parse
---@param config table Configuration containing filter_symbol_types
---@return table|nil Filter information or nil if no filter found
function M.parse_symbol_filter(query, config)
  if #query >= 3 and query:sub(1, 1) == "/" then
    local type_code = query:sub(2, 3)
    local symbol_type = config.filter_symbol_types[type_code]

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
---@param selectaItems table[] Items to display
---@param state table State object
---@param config table Configuration
---@param ui table UI module with helper functions
---@param selecta table Selecta module
---@param title string Title for the picker
---@param notify_opts? table Notification options
function M.show_picker(selectaItems, state, config, ui, selecta, title, notify_opts, is_ctags)
  if #selectaItems == 0 then
    vim.notify("Current `kindFilter` doesn't match any symbols.", nil, notify_opts)
    return
  end
  -- Find containing symbol for current cursor position
  local current_symbol
  if is_ctags then
    current_symbol = M.find_nearest_symbol(selectaItems)
  else
    current_symbol = M.find_containing_symbol(selectaItems)
  end

  local picker_opts = {
    title = title or "Symbols",
    fuzzy = false,
    preserve_order = true,
    window = config.window,
    display = config.display,
    auto_select = config.auto_select,
    initially_hidden = config.initially_hidden,
    movement = vim.tbl_deep_extend("force", config.movement, {}),
    row_position = config.row_position,
    debug = config.debug,
    pre_filter = function(items, query)
      local filter = M.parse_symbol_filter(query, config)
      if filter then
        local kinds_lower = vim.tbl_map(string.lower, filter.kinds)
        local filtered = vim.tbl_filter(function(item)
          return item.kind and vim.tbl_contains(kinds_lower, string.lower(item.kind))
        end, items)
        return filtered, filter.remaining
      end
      return items, query
    end,
    hooks = {
      on_render = function(buf, filtered_items)
        ui.apply_kind_highlights(buf, filtered_items, config)
      end,
      on_buffer_clear = function()
        ui.clear_preview_highlight(state.original_win, state.preview_ns)
        if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
          vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
        end
      end,
    },
    custom_keymaps = config.custom_keymaps,
    multiselect = {
      enabled = config.multiselect.enabled,
      indicator = config.multiselect.indicator,
      on_select = function(selected_items)
        if config.preview.highlight_mode == "select" then
          ui.clear_preview_highlight(state.original_win, state.preview_ns)
          if type(selected_items) == "table" and selected_items[1] then
            ui.highlight_symbol(selected_items[1].value, state.original_win, state.preview_ns)
          end
        end
        if type(selected_items) == "table" and selected_items[1] then
          M.jump_to_symbol(selected_items[1].value, state)
        end
      end,
    },
    initial_index = config.focus_current_symbol
        and current_symbol
        and ui.find_symbol_index(
          selectaItems,
          current_symbol,
          is_ctags -- Pass the is_ctags flag here
        )
      or nil,
    on_select = function(item)
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      M.jump_to_symbol(item.value, state)
    end,
    on_cancel = function()
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
        vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
      end
    end,
    on_move = function(item)
      if config.preview.highlight_on_move and config.preview.highlight_mode == "always" then
        if item then
          ui.highlight_symbol(item.value, state.original_win, state.preview_ns)
        end
      end
    end,
  }

  if config.kinds.prefix_kind_colors then
    picker_opts.prefix_highlighter = function(buf, line_nr, item, icon_end, ns_id)
      local kind_hl = config.kinds.highlights[item.kind]
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

  return picker_win
end

-- Create handlers for different actions
function M.create_keymaps_handlers(config, state, ui, selecta, ext, utils)
  local handlers = {}

  handlers.yank = function(items_or_item)
    local success = utils.yank_symbol_text(items_or_item, state)
    if success and config.actions.close_on_yank then
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      return false
    end
  end

  handlers.delete = function(items_or_item)
    local deleted = utils.delete_symbol_text(items_or_item, state)
    if deleted and config.actions.close_on_delete then
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      return false
    end
  end

  handlers.vertical_split = function(item, selecta_state)
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

  handlers.horizontal_split = function(item, selecta_state)
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

  handlers.codecompanion = function(items_or_item)
    ext.codecompanion_handler(items_or_item, state.original_buf)
  end

  handlers.avante = function(items_or_item)
    ext.avante_handler(items_or_item, state.original_buf)
  end

  return handlers
end

return M
