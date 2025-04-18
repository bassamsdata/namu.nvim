local M = {}
local logger = require("namu.utils.logger")
local format_utils = require("namu.core.format_utils")
local config = require("namu.namu_symbols.config")
local api = vim.api

-- Factory function to create a state object for a particular module
function M.create_state(namespace)
  return {
    original_win = nil,
    original_buf = nil,
    original_pos = nil,
    original_ft = nil,
    preview_ns = api.nvim_create_namespace(namespace or "namu_preview"),
    current_request = nil,
  }
end

---find_nearest_symbol: Specialized function for CTags data to find symbols by proximity
---@param items table[] Selecta items list
---@return table|nil symbol The nearest symbol if found within threshold
function M.find_nearest_symbol(items)
  -- Cache cursor position
  local cursor_pos = api.nvim_win_get_cursor(0)
  local cursor_line = cursor_pos[1]
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
  local cursor_pos = api.nvim_win_get_cursor(0)
  local cursor_line, cursor_col = cursor_pos[1], cursor_pos[2] + 1

  -- Early exit if no items
  if #items == 0 then
    logger.log("find_containing_symbol() - No items to search")
    return nil
  end

  -- Filter out root/buffer items before binary search to avoid nil errors
  local symbol_items = {}
  for _, item in ipairs(items) do
    if not item.is_root and item.value and item.value.lnum and item.value.end_lnum then
      table.insert(symbol_items, item)
    end
  end
  -- If no valid symbol items, return nil
  if #symbol_items == 0 then
    return nil
  end

  ---[local] Helper function to efficiently search through symbol ranges
  ---@diagnostic disable-next-line: redefined-local
  local function binary_search_range(items, target_line)
    local left, right = 1, #items
    while left <= right do
      local mid = math.floor((left + right) / 2)
      local symbol = items[mid].value

      -- Safety check
      if not symbol or not symbol.lnum or not symbol.end_lnum then
        -- Skip this item
        left = mid + 1
      elseif symbol.lnum <= target_line and symbol.end_lnum >= target_line then
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
  api.nvim_win_set_cursor(state.original_win, { symbol.lnum, symbol.col - 1 })
end

---Parse symbol filter from query string
---@param query string The query string to parse
---@param config table Configuration containing filter_symbol_types
---@return table|nil Filter information or nil if no filter found
function M.parse_symbol_filter(query, config)
  -- First check for buffer filter syntax with possible chained search
  local buffer_pattern, remaining_search = query:match("^/bf:([^:]+):?(.*)")

  if buffer_pattern then
    -- Special case for "current" buffer
    if buffer_pattern == "current" then
      return {
        buffer_filter = true,
        buffer_pattern = "current",
        current_buffer = vim.api.nvim_get_current_buf(),
        remaining = remaining_search, -- Keep any text after the colon
        description = "current buffer",
        filter_type = "buffer",
      }
    end

    return {
      buffer_filter = true,
      buffer_pattern = buffer_pattern,
      remaining = remaining_search, -- Keep any text after the colon
      description = buffer_pattern,
      filter_type = "buffer",
    }
  end

  -- Then check for standard symbol type filters: /fn, /cl, etc.
  -- (existing code unchanged)
  if #query >= 3 and query:sub(1, 1) == "/" then
    local type_code = query:sub(2, 3)
    local symbol_type = config.filter_symbol_types[type_code]

    if symbol_type then
      return {
        kinds = symbol_type.kinds,
        remaining = query:sub(4),
        description = symbol_type.description,
        filter_type = "symbol",
      }
    end
  end

  return nil
end

---Extract buffer information from an item
---@param item table The item to extract buffer info from
---@return number|nil bufnr The buffer number
---@return string short_name The short buffer name
---@return string full_path The full buffer path
local function get_buffer_info(item)
  local item_bufnr = item.bufnr or (item.value and item.value.bufnr)
  if not item_bufnr then
    return nil, "", ""
  end

  local buf_name = vim.api.nvim_buf_is_valid(item_bufnr) and vim.api.nvim_buf_get_name(item_bufnr) or ""
  local short_name = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":t") or ""

  return item_bufnr, short_name, buf_name
end

---Check if a buffer matches the filter pattern
---@param bufnr number Buffer number to check
---@param short_name string Short buffer name
---@param filter table Filter configuration
---@return boolean True if buffer matches
local function buffer_matches_filter(bufnr, short_name, filter)
  if filter.buffer_pattern == "current" and bufnr == filter.current_buffer then
    return true
  elseif short_name:lower():find(filter.buffer_pattern:lower(), 1, true) then
    return true
  end
  return false
end

---Find all matching buffer IDs from the items list
---@param items table[] List of items to search
---@param filter table Filter configuration
---@param config table Module configuration
---@param result table Table to store matching buffer items
---@return table matching_buffers Table of matching buffer IDs
---@return number count Number of matching buffers
local function find_matching_buffers(items, filter, config, result)
  local matching_buffers = {}
  local count = 0

  for _, item in ipairs(items) do
    -- Only process buffer-type items
    if item.kind ~= "buffer" then
      goto continue
    end

    local bufnr, short_name = get_buffer_info(item)
    if not bufnr then
      goto continue
    end

    if buffer_matches_filter(bufnr, short_name, filter) then
      -- Mark this buffer as a direct match
      local buffer_key = tostring(bufnr)
      matching_buffers[buffer_key] = true

      -- Add the buffer item to results
      item.is_direct_match = true
      count = count + 1
      table.insert(result, item)

      if config.debug then
        logger.log("Added buffer item to results: " .. item.text)
      end
    end

    ::continue::
  end

  return matching_buffers, count
end

---Add all symbols belonging to matching buffers
---@param items table[] List of all items
---@param matching_buffers table Table of buffer IDs that matched
---@param config table Module configuration
---@param result table Table to store matching items
local function add_buffer_symbols(items, matching_buffers, config, result)
  for _, item in ipairs(items) do
    -- Skip buffer items (already processed)
    if item.kind == "buffer" then
      goto continue
    end

    -- Get buffer information from the item
    local bufnr = item.bufnr or (item.value and item.value.bufnr)
    if not bufnr then
      goto continue
    end

    -- If this item belongs to a matching buffer, include it
    if matching_buffers[tostring(bufnr)] then
      table.insert(result, item)
      if config.debug then
        logger.log("Including item from matching buffer: " .. tostring(bufnr))
      end
    end

    ::continue::
  end
end

---Main buffer filtering function that combines the helper functions
---@param items table[] All items to filter
---@param filter table Filter configuration
---@param config table Module configuration
---@param metadata table Metadata to update
---@return table filtered_items Filtered items
---@return string remaining Remaining filter text
---@return table metadata Updated metadata
local function filter_by_buffer(items, filter, config, metadata)
  local buffer_filtered = {}

  if config.debug then
    logger.log("Buffer filtering for pattern: " .. filter.buffer_pattern)
  end

  -- Step 1: Find all matching buffer headers
  local matching_buffers, direct_match_count = find_matching_buffers(items, filter, config, buffer_filtered)

  if config.debug then
    logger.log("Matching buffers found: " .. vim.inspect(matching_buffers))
    logger.log("Buffer filtered items after first pass: " .. #buffer_filtered)
  end

  -- Step 2: Add all symbols from matching buffers
  add_buffer_symbols(items, matching_buffers, config, buffer_filtered)

  -- Step 3: Update metadata
  metadata.filter_type = "Buffer: " .. filter.buffer_pattern
  metadata.description = filter.description
  metadata.direct_match_count = direct_match_count

  if config.debug then
    logger.log("Final filtered items count: " .. #buffer_filtered)
  end

  return buffer_filtered, filter.remaining, metadata
end

---Helper function for simple symbol filtering without hierarchy
---@param items table[] List of items to filter
---@param kinds_lookup table Lookup table of symbol kinds to match
---@return table filtered_items Filtered items
---@return number count Number of matches
local function filter_symbols_simple(items, kinds_lookup)
  local filtered = {}
  local count = 0

  for _, item in ipairs(items) do
    if item.kind and kinds_lookup[string.lower(item.kind)] then
      count = count + 1
      filtered[count] = item
      item.is_direct_match = true
    end
  end

  return filtered, count
end

---Build a map of all items by signature for parent lookup
---@param items table[] List of items
---@return table item_map Map of items by signature
local function build_item_signature_map(items)
  local item_map = {}
  for i, item in ipairs(items) do
    if item.value and item.value.signature then
      item_map[item.value.signature] = { index = i, item = item }
    end
  end
  return item_map
end

---Filter symbols hierarchically, preserving parent-child relationships
---@param items table[] List of items to filter
---@param kinds_lookup table Lookup table of symbol kinds to match
---@param config table Module configuration
---@return table result_items Filtered items
---@return number direct_matches Number of direct matches
---@return number parent_count Number of parent items included
local function filter_symbols_hierarchy(items, kinds_lookup, config)
  -- First identify direct matches
  local direct_match_indices = {}
  local direct_match_count = 0

  for i, item in ipairs(items) do
    item.is_direct_match = nil -- Reset
    if item.kind and kinds_lookup[string.lower(item.kind)] then
      item.is_direct_match = true
      direct_match_count = direct_match_count + 1
      direct_match_indices[direct_match_count] = i
    end
  end

  -- Build a map of all items by signature
  local item_map = build_item_signature_map(items)

  -- Build the include set with direct matches and parents
  local include_indices = {}
  local parent_count = 0

  for i = 1, direct_match_count do
    local idx = direct_match_indices[i]
    local item = items[idx]
    include_indices[idx] = true

    -- Trace parents
    local current = item
    local visited = { [idx] = true }

    while current and current.value and current.value.parent_signature do
      local parent_key = current.value.parent_signature
      local parent_entry = item_map[parent_key]

      if parent_entry and not visited[parent_entry.index] then
        include_indices[parent_entry.index] = true
        visited[parent_entry.index] = true
        parent_entry.item.is_direct_match = false
        current = parent_entry.item
        parent_count = parent_count + 1
      else
        break
      end
    end
  end

  -- Build result list while preserving order
  local result_count = 0
  local result_items = {}

  for i, item in ipairs(items) do
    if include_indices[i] then
      result_count = result_count + 1
      result_items[result_count] = item
    end
  end

  return result_items, direct_match_count, parent_count
end

---Main symbol filtering function
---@param items table[] All items to filter
---@param filter table Filter configuration
---@param config table Module configuration
---@param metadata table Metadata to update
---@return table filtered_items Filtered items
---@return string remaining Remaining filter text
---@return table metadata Updated metadata
local function filter_by_symbol(items, filter, config, metadata)
  -- Create a lookup table for faster kind matching
  local kinds_lookup = {}
  for _, kind in ipairs(filter.kinds) do
    kinds_lookup[string.lower(kind)] = true
  end

  -- If not preserving hierarchy, use a simple optimized filter
  if not config.preserve_hierarchy then
    local filtered, count = filter_symbols_simple(items, kinds_lookup)

    -- Update metadata
    metadata.filter_type = filter.filter_type
    metadata.description = filter.description
    metadata.direct_match_count = count

    return filtered, filter.remaining, metadata
  end

  -- For preserving hierarchy, use the hierarchical filter
  local result_items, direct_match_count, parent_count = filter_symbols_hierarchy(items, kinds_lookup, config)

  -- Conditionally log only when debugging is enabled
  if config.debug then
    logger.log(
      string.format(
        "Filter results: %d items (%d direct + %d parents)",
        #result_items,
        direct_match_count,
        parent_count
      )
    )
  end

  -- Update metadata
  metadata.filter_type = filter.filter_type
  metadata.description = filter.description
  metadata.direct_match_count = direct_match_count
  metadata.parent_count = parent_count

  return result_items, filter.remaining, metadata
end

-- Main pre_filter function with all functionality
local function pre_filter(items, query, config)
  -- First check if there's a filter
  local filter = M.parse_symbol_filter(query, config)

  -- If no filter, return items unchanged
  if not filter then
    return items, query
  end

  local metadata = {
    is_symbol_filter = true,
    remaining = filter.remaining,
  }

  -- Handle buffer filtering
  if filter.buffer_filter then
    return filter_by_buffer(items, filter, config, metadata)
  end

  -- Handle symbol type filtering
  if filter.kinds then
    return filter_by_symbol(items, filter, config, metadata)
  end

  return items, query
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
    current_highlight = config.current_highlight,
    row_position = config.row_position,
    custom_keymaps = vim.tbl_deep_extend("force", config.custom_keymaps, {}),
    debug = config.debug,
    preserve_hierarchy = config.preserve_hierarchy or false,
    -- root_item_first = true,
    -- always_include_root = true,
    is_root_item = function(item)
      return item.is_root == true
    end,
    parent_key = function(item)
      return item.value and item.value.parent_signature
    end,
    formatter = function(item)
      return format_utils.format_item_for_display(item, config)
    end,
    pre_filter = function(items, query)
      -- First check if there's a filter
      local filter = M.parse_symbol_filter(query, config)
      -- If no filter, return items unchanged
      if not filter then
        return items, query
      end
      local metadata = {
        is_symbol_filter = true,
        remaining = filter.remaining,
      }
      -- Handle buffer filtering
      if filter.buffer_filter then
        return filter_by_buffer(items, filter, config, metadata)
      end
      -- Handle symbol type filtering
      if filter.kinds then
        return filter_by_symbol(items, filter, config, metadata)
      end

      return items, query
    end,
    -- TODO: refactor please to be maintainble and readable
    -- pre_filter = function(items, query)
    --   -- First check if there's a filter
    --   local filter = M.parse_symbol_filter(query, config)
    --
    --   -- If no filter, return items unchanged
    --   if not filter then
    --     return items, query
    --   end
    --
    --   local metadata = {
    --     is_symbol_filter = true,
    --     remaining = filter.remaining,
    --   }
    --
    --   -- Handle buffer filtering
    --
    --   if filter.buffer_filter then
    --     local buffer_filtered = {}
    --     local direct_match_count = 0
    --     local matching_buffers = {} -- Track matching buffer IDs
    --
    --     logger.log("Buffer filtering for pattern: " .. filter.buffer_pattern)
    --
    --     -- First pass: Find all matching buffers
    --     for _, item in ipairs(items) do
    --       -- Get buffer information from the item
    --       local item_bufnr = item.bufnr or (item.value and item.value.bufnr)
    --       if not item_bufnr then
    --         goto continue_buffer_first_pass
    --       end
    --
    --       local buf_name = vim.api.nvim_buf_is_valid(item_bufnr) and vim.api.nvim_buf_get_name(item_bufnr) or ""
    --       local short_name = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":t") or ""
    --
    --       -- Only process buffer-type items in first pass
    --       if item.kind ~= "buffer" then
    --         goto continue_buffer_first_pass
    --       end
    --
    --       -- Match logic for buffer filters - only match the short name by default
    --       local matches = false
    --
    --       if filter.buffer_pattern == "current" and item_bufnr == filter.current_buffer then
    --         matches = true
    --         logger.log("Matched current buffer")
    --       elseif short_name:lower():find(filter.buffer_pattern:lower(), 1, true) then
    --         -- Direct match on filename (short name)
    --         matches = true
    --         logger.log("Matched short name: " .. short_name)
    --       end
    --
    --       if matches then
    --         -- Mark this buffer as a direct match
    --         matching_buffers[tostring(item_bufnr)] = true
    --
    --         -- Add the buffer item to results
    --         item.is_direct_match = true
    --         direct_match_count = direct_match_count + 1
    --         table.insert(buffer_filtered, item)
    --         logger.log("Added buffer item to results: " .. item.text)
    --       end
    --
    --       ::continue_buffer_first_pass::
    --     end
    --
    --     logger.log("Matching buffers found: " .. vim.inspect(matching_buffers))
    --
    --     -- Second pass: Include all items from matching buffers
    --     for _, item in ipairs(items) do
    --       -- Skip buffer items (already processed)
    --       if item.kind == "buffer" then
    --         goto continue_buffer_second_pass
    --       end
    --
    --       -- Get buffer information from the item
    --       local item_bufnr = item.bufnr or (item.value and item.value.bufnr)
    --       if not item_bufnr then
    --         goto continue_buffer_second_pass
    --       end
    --
    --       -- If this item belongs to a matching buffer, include it
    --       local buffer_key = tostring(item_bufnr)
    --       if matching_buffers[buffer_key] then
    --         table.insert(buffer_filtered, item)
    --         logger.log("Including item from matching buffer: " .. buffer_key)
    --       end
    --
    --       ::continue_buffer_second_pass::
    --     end
    --
    --     -- Update metadata for buffer filtering
    --     metadata.filter_type = "Buffer: " .. filter.buffer_pattern
    --     metadata.description = filter.description
    --     metadata.direct_match_count = direct_match_count
    --
    --     logger.log("Final filtered items count: " .. #buffer_filtered)
    --     return buffer_filtered, filter.remaining, metadata
    --   end
    --
    --   -- Handle symbol type filtering
    --   if filter.kinds then
    --     -- Create a lookup table for faster kind matching
    --     local kinds_lookup = {}
    --     for _, kind in ipairs(filter.kinds) do
    --       kinds_lookup[string.lower(kind)] = true
    --     end
    --
    --     -- If not preserving hierarchy, use a simple optimized filter
    --     if not config.preserve_hierarchy then
    --       local filtered = {}
    --       local count = 0
    --       for _, item in ipairs(items) do
    --         if item.kind and kinds_lookup[string.lower(item.kind)] then
    --           count = count + 1
    --           filtered[count] = item
    --           item.is_direct_match = true
    --         end
    --       end
    --
    --       return filtered,
    --         filter.remaining,
    --         {
    --           is_symbol_filter = true,
    --           filter_type = filter.filter_type,
    --           description = filter.description,
    --           direct_match_count = count,
    --           remaining = filter.remaining,
    --         }
    --     end
    --
    --     -- For preserving hierarchy, optimize the multiple passes
    --
    --     -- First identify direct matches
    --     local direct_match_indices = {}
    --     local direct_match_count = 0
    --
    --     for i, item in ipairs(items) do
    --       item.is_direct_match = nil -- Reset
    --       if item.kind and kinds_lookup[string.lower(item.kind)] then
    --         item.is_direct_match = true
    --         direct_match_count = direct_match_count + 1
    --         direct_match_indices[direct_match_count] = i
    --       end
    --     end
    --
    --     -- Build a map of all items by signature - only once
    --     local item_map = {}
    --     for i, item in ipairs(items) do
    --       if item.value and item.value.signature then
    --         item_map[item.value.signature] = { index = i, item = item }
    --       end
    --     end
    --
    --     -- Build the include set with direct matches and parents
    --     local include_indices = {}
    --     local parent_count = 0
    --
    --     for i = 1, direct_match_count do
    --       local idx = direct_match_indices[i]
    --       local item = items[idx]
    --       include_indices[idx] = true
    --
    --       -- Trace parents
    --       local current = item
    --       local visited = { [idx] = true }
    --
    --       while current and current.value and current.value.parent_signature do
    --         local parent_key = current.value.parent_signature
    --         local parent_entry = item_map[parent_key]
    --
    --         if parent_entry and not visited[parent_entry.index] then
    --           include_indices[parent_entry.index] = true
    --           visited[parent_entry.index] = true
    --           parent_entry.item.is_direct_match = false
    --           current = parent_entry.item
    --           parent_count = parent_count + 1
    --         else
    --           break
    --         end
    --       end
    --     end
    --
    --     -- Build result list while preserving order
    --     local result_count = 0
    --     local result_items = {}
    --
    --     for i, item in ipairs(items) do
    --       if include_indices[i] then
    --         result_count = result_count + 1
    --         result_items[result_count] = item
    --       end
    --     end
    --
    --     -- Conditionally log only when debugging is enabled
    --     if config.debug then
    --       logger.log(
    --         string.format(
    --           "Filter results: %d items (%d direct + %d parents)",
    --           result_count,
    --           direct_match_count,
    --           parent_count
    --         )
    --       )
    --     end
    --
    --     return result_items,
    --       filter.remaining,
    --       {
    --         is_symbol_filter = true,
    --         filter_type = filter.filter_type,
    --         description = filter.description,
    --         direct_match_count = direct_match_count,
    --         parent_count = parent_count,
    --         remaining = filter.remaining,
    --       }
    --   end
    --
    --   return items, query
    -- end,
    hooks = {
      on_render = function(buf, filtered_items)
        ui.apply_highlights(buf, filtered_items, config)
      end,
      on_buffer_clear = function()
        ui.clear_preview_highlight(state.original_win, state.preview_ns)
        if state.original_win and state.original_pos and api.nvim_win_is_valid(state.original_win) then
          api.nvim_win_set_cursor(state.original_win, state.original_pos)
        end
        state.original_buf = nil
        state.original_pos = nil
        state.original_win = nil
      end,
    },
    multiselect = {
      enabled = config.multiselect.enabled,
      indicator = config.multiselect.indicator,
      on_select = function(selected_items)
        if config.preview.highlight_mode == "select" then
          ui.clear_preview_highlight(state.original_win, state.preview_ns)
          if type(selected_items) == "table" and selected_items[1] then
            ui.preview_symbol(selected_items[1].value, state.original_win, state.preview_ns, state, config.highlight)
          end
        end
        if type(selected_items) == "table" and selected_items[1] then
          M.jump_to_symbol(selected_items[1].value, state)
        end
      end,
    },
    -- FIX: with active module, not working great
    initial_index = config.focus_current_symbol
        and current_symbol
        and ui.find_symbol_index(selectaItems, current_symbol, is_ctags)
      or nil,
    on_select = function(item)
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      M.jump_to_symbol(item.value, state)
    end,
    -- FIX: we need to move the oroiginal buffer first for active symbols
    -- check preview_symbol first if we're doing that there first, but don't think so
    on_cancel = function()
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      local buf = api.nvim_get_current_buf()
      if buf ~= state.original_buf then
        api.nvim_win_call(state.original_win, function()
          api.nvim_win_set_buf(state.original_win, state.original_buf)
        end)
      end
      if state.original_win and state.original_pos and api.nvim_win_is_valid(state.original_win) then
        vim.schedule(function()
          api.nvim_win_set_cursor(state.original_win, state.original_pos)
        end)
      end
    end,
    -- BUG: cursor position outside
    -- Error /namu.nvim/lua/namu/core/symbol_utils.lua:889: Cursor position outside buffer
    -- it looks like if we're moving very fast, and pressed esc to _on_cancel then I have the error:
    -- not sure if we wrapped on_cancel fucntion with vim.schedule will affect performance
    on_move = function(item)
      if config.preview.highlight_on_move and config.preview.highlight_mode == "always" then
        if item then
          ui.preview_symbol(item, state.original_win, state.preview_ns, state, config.highlight)
        end
      end
    end,
  }

  -- if config.kinds.prefix_kind_colors then
  --   picker_opts.prefix_highlighter = function(buf, line_nr, item, icon_end, ns_id)
  --     local kind_hl = config.kinds.highlights[item.kind]
  --     if kind_hl then
  --       api.nvim_buf_set_extmark(buf, ns_id, line_nr, 0, {
  --         end_col = icon_end,
  --         hl_group = kind_hl,
  --         priority = 100,
  --         hl_mode = "combine",
  --       })
  --     end
  --   end
  -- end
  --
  local picker_win = selecta.pick(selectaItems, picker_opts)

  -- Add cleanup autocmd after picker is created
  if picker_win then
    local augroup = api.nvim_create_augroup("NamuCleanup", { clear = true })
    api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = tostring(picker_win),
      callback = function()
        ui.clear_preview_highlight(state.original_win, state.preview_ns)
        api.nvim_del_augroup_by_name("NamuCleanup")
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

  handlers.vertical_split = function(item)
    if not state.original_buf then
      vim.notify("No original buffer available", vim.log.levels.ERROR)
      return
    end
    -- Replace selecta.open_in_split with your new utility function
    local new_win = selecta.open_in_split(item, "vertical", state)
    if new_win then
      -- Most of this is now handled in open_in_split, so we can simplify
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      return false
    end
  end

  handlers.horizontal_split = function(item)
    if not state.original_buf then
      vim.notify("No original buffer available", vim.log.levels.ERROR)
      return
    end
    -- Replace selecta.open_in_split with your new utility function
    local new_win = selecta.open_in_split(item, "horizontal", state)
    if new_win then
      -- Most of this is now handled in open_in_split, so we can simplify
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
