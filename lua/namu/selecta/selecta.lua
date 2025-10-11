--[[ selecta.lua
A minimal, flexible fuzzy finder for Neovim.

Usage:
require('selecta').pick(items, {
   -- options
})

Features:
- Fuzzy finding with real-time filtering
- Live cursor/caret in prompt
- Match highlighting
- Auto-sizing window
- Preview support
- Customizable formatting and filtering

-- Basic usage
require('selecta').pick(items)

-- Advanced usage with all features
require('selecta').pick(items, {
    title = "My Picker",
    fuzzy = true,
    window = {
        auto_size = true,
        border = 'rounded',
        title_prefix = "🔍 ",
    },
    on_select = function(item)
        print("Selected:", item.text)
    end,
    on_move = function(item)
        print("Moved to:", item.text)
    end,
    formatter = function(item)
        return string.format("%s %s", item.icon, item.text)
    end
})
]]

local M = {}
local matcher = require("namu.selecta.matcher")
local logger = require("namu.utils.logger")
local StateManager = require("namu.selecta.state").StateManager
local common = require("namu.selecta.common")
local input_handler = require("namu.selecta.input")
local ui = require("namu.selecta.ui")
local config = require("namu.selecta.selecta_config").values
local notify_opts = { title = "Namu", icon = config.icon }

function M.log(message)
  logger.log(message)
end
M.clear_log = logger.clear_log

-- Hierarchical filtering implementation
---@param state SelectaState
---@param items_to_filter SelectaItem[]
---@param actual_query string
---@param opts SelectaOptions
local function hierarchical_filter(state, items_to_filter, actual_query, opts)
  -- Track special root item if configured
  local root_item = nil
  if opts.always_include_root then
    -- Find the root item based on the provided function
    for _, item in ipairs(items_to_filter) do
      if opts.is_root_item and opts.is_root_item(item) then
        root_item = item
        break
      end
    end
  end

  -- Step 1: Find direct matches with single pass
  local matched_indices = {}
  local match_scores = {}
  local best_score = -math.huge
  local best_index = nil

  for i, item in ipairs(items_to_filter) do
    local match = matcher.get_match_positions(item.text, actual_query)
    if match then
      matched_indices[i] = true
      match_scores[i] = match.score

      if match.score > best_score then
        best_score = match.score
        best_index = i
      end
    end
  end

  -- Step 2: Build a map for parent lookups (optimize with single pass)
  local item_map = {}
  for i, item in ipairs(items_to_filter) do
    -- Create a unique identifier for this item
    local item_id = tostring(item.value or item.text)
    if item.value and item.value.signature then
      item_id = item.value.signature
    end
    item_map[item_id] = { index = i, item = item }
  end

  -- Step 3: Include parents of matched items (build inclusion set)
  local include_indices = {}
  for i in pairs(matched_indices) do
    -- Always include the direct match
    include_indices[i] = true

    -- Trace up through parents
    local current = items_to_filter[i]
    local visited = { [i] = true } -- Prevent cycles

    while current do
      -- Get parent key using the provided function
      local parent_key = opts.parent_key(current)
      if not parent_key or parent_key == "root" then
        break -- Reached the root or no more parents
      end

      -- Find the parent item
      local parent_entry = item_map[parent_key]
      if parent_entry and not visited[parent_entry.index] then
        include_indices[parent_entry.index] = true
        visited[parent_entry.index] = true
        current = parent_entry.item
      else
        break -- Parent not found or cycle detected
      end
    end
  end

  -- Special case: Always include the root item if requested
  if root_item then
    for i, item in ipairs(items_to_filter) do
      if item == root_item then
        include_indices[i] = true
        break
      end
    end
  end

  -- Step 4: Create filtered list preserving original order
  state.filtered_items = {}

  -- If we have a root item and it should be first, add it first
  if root_item and opts.root_item_first then
    for i, item in ipairs(items_to_filter) do
      if item == root_item and include_indices[i] then
        -- Mark if it's a direct match
        item.is_direct_match = matched_indices[i] or nil
        if matched_indices[i] then
          item.match_score = match_scores[i]
        end
        table.insert(state.filtered_items, item)
        include_indices[i] = nil -- Remove so we don't add it again
        break
      end
    end
  end

  -- Add remaining items in order
  for i, item in ipairs(items_to_filter) do
    if include_indices[i] then
      -- Mark direct matches vs contextual items
      item.is_direct_match = matched_indices[i] or nil
      if matched_indices[i] then
        item.match_score = match_scores[i]
      end
      table.insert(state.filtered_items, item)
    end
  end

  -- Step 5: Set best match index for cursor positioning
  if best_index then
    -- Find where the best match ended up in the filtered list
    for i, item in ipairs(state.filtered_items) do
      if item == items_to_filter[best_index] then
        state.best_match_index = i
        break
      end
    end
  end
end

-- Optimize filtering logic
---@param state SelectaState
---@param query string
---@param opts SelectaOptions
function M.update_filtered_items(state, query, opts)
  -- Skip normal filtering if we're loading
  if state.is_loading then
    return
  end

  local items_to_filter = state.items
  local actual_query = query
  if opts.pre_filter then
    local new_items, new_query, metadata = opts.pre_filter(state.items, query)
    if new_items then
      items_to_filter = new_items
      -- Show the filtered items even if new_query is empty
      state.filtered_items = new_items
    end
    actual_query = new_query or ""
    state.filter_metadata = metadata
  end

  -- Early return if no query
  if actual_query == "" then
    if not opts.pre_filter then
      state.filtered_items = items_to_filter
      state.best_match_index = nil
    end
    return
  end

  -- Use specialized filtering based on options
  if opts.preserve_hierarchy and type(opts.parent_key) == "function" then
    hierarchical_filter(state, items_to_filter, actual_query, opts)
  else
    -- Standard filtering with optimized implementation
    M.standard_filter(state, items_to_filter, actual_query, opts)
  end

  -- Handle auto-select for single result
  if opts.auto_select and #state.filtered_items == 1 and not state.initial_open then
    local selected = state.filtered_items[1]
    if selected and opts.on_select then
      opts.on_select(selected)
      M.close_picker(state)
    end
  end
end

-- Standard filtering with better performance
function M.standard_filter(state, items, query, opts)
  -- Early optimization: pre-allocate matched items array
  local matched_items = {}
  local match_scores = {}

  -- First pass: identify matches and collect scores
  for _, item in ipairs(items) do
    local match = matcher.get_match_positions(item.text, query)
    if match then
      -- Store matched items and scores
      table.insert(matched_items, item)
      match_scores[item] = match.score
    end
  end

  -- Skip sorting if we should preserve order
  if not opts.preserve_order then
    -- Sort matched items by score (higher score first)
    table.sort(matched_items, function(a, b)
      return match_scores[a] > match_scores[b]
    end)

    -- If we have matched items, the first is the best match
    if #matched_items > 0 then
      state.best_match_index = 1
    else
      state.best_match_index = nil
    end
  else
    -- Find best match while preserving order
    local best_score = -math.huge
    local best_index = nil

    for i, item in ipairs(matched_items) do
      local score = match_scores[item]
      if score > best_score then
        best_score = score
        best_index = i
      end
    end

    state.best_match_index = best_index
  end

  state.filtered_items = matched_items
end

function M.create_loading_status_provider(state)
  return function(text)
    if state and state.active and state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
      vim.api.nvim_buf_clear_namespace(state.prompt_buf, common.loading_ns_id, 0, -1)
      state.loading_extmark_id = vim.api.nvim_buf_set_extmark(state.prompt_buf, common.loading_ns_id, 0, 0, {
        virt_text = { { " 󰇚 " .. text, "Comment" } },
        virt_text_pos = "eol",
        priority = 200,
      })
    end
  end
end

local loading_ns_id = common.loading_ns_id
---@param state SelectaState
---@param query string
---@param opts SelectaOptions
---@param callback function
---@return boolean started
function M.start_async_fetch(state, query, opts, callback)
  -- Generate a unique request ID for this specific request
  local request_id = tostring(vim.uv.now()) .. "_" .. vim.fn.rand()
  state.current_request_id = request_id
  state.last_query = query
  state.is_loading = true
  -- Display loading indicator
  if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
    -- Clear any previous loading indicator
    vim.api.nvim_buf_clear_namespace(state.prompt_buf, loading_ns_id, 0, -1)
    -- Get loading indicator text and icon with fallbacks
    local loading_icon = opts.loading_indicator and opts.loading_indicator.icon
      or config.loading_indicator and config.loading_indicator.icon
      or "󰇚"
    local loading_text = opts.loading_indicator and opts.loading_indicator.text
      or config.loading_indicator and config.loading_indicator.text
      or "Loading..."
    state.loading_extmark_id = vim.api.nvim_buf_set_extmark(state.prompt_buf, loading_ns_id, 0, 0, {
      virt_text = { { " " .. loading_icon .. " " .. loading_text, "Comment" } },
      virt_text_pos = "eol",
      priority = 200,
    })
  end

  local process_fn = opts.async_source(query, opts) -- Get the process function
  -- Create a status provider for this state
  local status_provider = M.create_loading_status_provider(state)

  -- Define the callback to handle processed items
  local function handle_items(items)
    -- Schedule the UI update in the main Neovim loop
    vim.schedule(function()
      -- Skip if picker was closed or a newer request has arrived
      if not state.active or state.current_request_id ~= request_id then
        return
      end

      -- Clear loading indicator
      if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
        vim.api.nvim_buf_clear_namespace(state.prompt_buf, loading_ns_id, 0, -1)
        state.loading_extmark_id = nil
      end
      -- Update with results if we have valid data
      if type(items) == "table" then
        state.items = items
        state.filtered_items = items
        -- Apply filtering if needed
        if query ~= "" and #items > 0 then
          -- Apply filtering logic
          M.update_filtered_items(state, query, vim.tbl_deep_extend("force", opts, { async_source = nil }))
        end
      else
        -- Handle error or empty results
        state.filtered_items = { { text = "No matching results found", icon = "󰅚", value = nil } }
      end
      state.is_loading = false -- Clear loading state
      if callback then
        callback()
      end
    end)
  end

  -- Start the process
  process_fn(handle_items, status_provider)

  return true
end

---@param state SelectaState
---@param opts SelectaOptions
function M.process_query(state, opts)
  local query = state:get_query_string()

  if state.initial_open then
    state.initial_open = false
  end
  -- Check if items are fully loaded (e.g., workspace diagnostics completed)
  -- If so, switch to fast sync filtering to avoid unnecessary async operations
  if opts.async_source and opts.items_fully_loaded then
    opts.async_source = nil
  end

  if opts.async_source then
    -- Double-check items_fully_loaded before starting async operation
    if opts.items_fully_loaded then
      M.log("Items already fully loaded, skipping async and using sync filtering")
      opts.async_source = nil
      if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
        vim.api.nvim_buf_clear_namespace(state.prompt_buf, common.loading_ns_id, 0, -1)
        state.loading_extmark_id = nil
        state.is_loading = false
      end
    else
      -- Try to start async fetch, pass callback for display update
      local started_async = M.start_async_fetch(state, query, opts, function()
        -- This callback runs after async operation completes
        M.update_filtered_items(state, query, opts)
        ui.update_display(state, opts)
        common.update_selection_highlights(state, opts)
        -- Handle cursor positioning and on_move callback
        -- state:handle_post_filter_cursor(opts)
        vim.cmd("redraw")
      end)

      -- If async started successfully, return early without updating display
      -- The display update will happen in the callback when async completes
      if started_async then
        return
      end
    end
  end

  M.update_filtered_items(state, query, opts)
  -- Ensure loading state is cleared when doing sync filtering
  state.is_loading = false
  if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
    vim.api.nvim_buf_clear_namespace(state.prompt_buf, common.loading_ns_id, 0, -1)
    state.loading_extmark_id = nil
  end
  ui.update_display(state, opts)
  common.update_selection_highlights(state, opts)
  -- Handle cursor positioning and on_move callback
  -- state:handle_post_filter_cursor(opts)
end

---Close the picker and restore cursor
---@param state SelectaState
---@return nil
function M.close_picker(state)
  if not state then
    return
  end
  state.active = false
  -- No need to explicitly terminate coroutines - just mark as inactive
  state.async_co = nil
  state.is_loading = false
  if state.cleanup then
    state:cleanup()
  else
    -- Clear loading indicator if exists
    if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) and state.loading_extmark_id then
      vim.api.nvim_buf_clear_namespace(state.prompt_buf, loading_ns_id, 0, -1)
      state.loading_extmark_id = nil
      vim.api.nvim_buf_clear_namespace(state.prompt_buf, common.prompt_info_ns, 0, -1)
    end
    if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
      vim.api.nvim_win_close(state.prompt_win, true)
    end
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
    end
  end
  ui.clear_original_dimensions(state.picker_id)
  vim.cmd("stopinsert!")
end

---Set up the prompt buffer with event handling and keymaps
---@param state SelectaState
---@param opts SelectaOptions
---@return nil
function M.setup_prompt_buffer(state, opts)
  -- Early return if buffer is not valid
  if not state.prompt_buf or not vim.api.nvim_buf_is_valid(state.prompt_buf) then
    return
  end

  -- Set up buffer change tracking using nvim_buf_attach
  vim.api.nvim_buf_attach(state.prompt_buf, false, {
    on_lines = function(_, bufnr, _, _, _, _, _)
      if bufnr ~= state.prompt_buf or not state.active then
        return false
      end

      -- Update query from buffer content - but don't process yet
      if state:update_query_from_buffer() and state.active then
        -- Instead of calling process_query directly, set a flag and trigger it
        -- on the next UI event via vim.schedule
        state.query_changed = true
        vim.schedule(function()
          if state.active and state.query_changed then
            state.query_changed = nil
            -- Process query outside the callback context
            M.process_query(state, opts)
            -- Handle cursor positioning and on_move callback after filtering
            -- state:handle_post_filter_cursor(opts)
          end
        end)
      end

      -- Keep attachment
      return false
    end,
  })

  input_handler.setup_keymaps(state, opts, M.close_picker, M.process_query)
  ui.update_prompt_prefix(state, opts, state:get_query_string())
  vim.cmd("startinsert")
end

---Pick an item from the list with cursor management
---@param items SelectaItem[]
---@param opts? SelectaOptions
---@return nil
function M.pick(items, opts)
  local base_opts = {
    title = "Select",
    display = config.display,
    filter = function(item, query)
      return query == "" or string.find(string.lower(item.text), string.lower(query))
    end,
    fuzzy = false,
    offset = function()
      return 0
    end,
    movement = vim.tbl_deep_extend("force", config.movement, {}),
    auto_select = config.auto_select,
    window = config.window,
    pre_filter = nil,
    row_position = config.row_position,
    debug = config.debug,
    normal_mode = false,
  }
  opts = vim.tbl_deep_extend("force", base_opts, opts or {})

  -- Calculate max_prefix_width before creating formatter
  local max_prefix_width = ui.calculate_max_prefix_width(items, opts.display.mode)
  opts.display.prefix_width = max_prefix_width

  -- Set up formatter
  opts.formatter = opts.formatter
    or function(item)
      local prefix_padding = ""
      if opts.current_highlight and opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
        prefix_padding = string.rep(" ", vim.api.nvim_strwidth(opts.current_highlight.prefix_icon))
      end
      if opts.display.mode == "raw" then
        return prefix_padding .. item.text
      elseif opts.display.mode == "icon" then
        local icon = item.icon or "  "
        return prefix_padding .. icon .. string.rep(" ", opts.display.padding or 1) .. item.text
      else
        local prefix_info = common.get_prefix_info(item, opts.display.prefix_width)
        local padding = string.rep(" ", prefix_info.padding)
        return prefix_padding .. prefix_info.text .. padding .. item.text
      end
    end

  -- Create state
  local state = StateManager.new(items, opts)
  state.picker_id = tostring(vim.uv.hrtime())

  local _ = ui.get_container_dimensions(opts, state.picker_id)
  -- Calculate dimensions and position for the state
  local width, height =
    ui.calculate_window_size(opts.initially_hidden and {} or items, opts, opts.formatter, 0, state.picker_id)
  local row, col = ui.get_window_position(width, opts.row_position, opts, state.picker_id)

  -- Update state with calculated values
  state.row = row
  state.col = col
  state.width = width
  state.height = height
  -- Create the UI
  ui.create_windows(state, opts)
  -- Set up the prompt buffer with event handling
  M.setup_prompt_buffer(state, opts)
  -- Initial processing
  M.process_query(state, opts)
  vim.cmd("redraw")

  -- Handle initial cursor position
  if opts.initial_index and opts.initial_index <= #items then
    local target_pos = math.min(opts.initial_index, #state.filtered_items)
    if target_pos > 0 then
      vim.api.nvim_win_set_cursor(state.win, { target_pos, 0 })
      common.update_current_highlight(state, opts, target_pos - 1)
      if opts.on_move then
        opts.on_move(state.filtered_items[target_pos])
      end
    end
  end

  -- Focus the prompt window and start in insert mode
  if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
    vim.api.nvim_set_current_win(state.prompt_win)
  end
end

M._test = {
  get_match_positions = matcher.get_match_positions,
  is_word_boundary = matcher.is_word_boundary,
  update_filtered_items = M.update_filtered_items,
  parse_position = common.parse_position,
  calculate_window_size = ui.calculate_window_size,
  validate_input = matcher.validate_input,
  get_window_position = ui.get_window_position,
}

---@param opts? table
function M.setup(opts)
  opts = opts or {}
  -- Update the config module values
  local selecta_config = require("namu.selecta.selecta_config")
  selecta_config.values = vim.tbl_deep_extend("force", selecta_config.defaults, opts)
  logger.setup(opts)
end

-- Expose config for testing
M.get_config = function()
  return require("namu.selecta.selecta_config").values
end

-- Add to a core utility module (e.g., namu.core.split_utils)
-- Function to find a loaded buffer by file path
---@param path string The file path to search for
---@return number|nil The buffer number if found, nil otherwise
local function find_buf_by_path(path)
  if not path or path == "" then
    return nil
  end

  -- Normalize path for comparison
  local normalized_path = vim.fn.fnamemodify(path, ":p")

  -- Check all buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local buf_path = vim.api.nvim_buf_get_name(bufnr)
      if buf_path and buf_path ~= "" then
        if vim.fn.fnamemodify(buf_path, ":p") == normalized_path then
          return bufnr
        end
      end
    end
  end

  return nil
end

---Open current buffer in a split and jump to the selected symbol's location
---@param item SelectaItem The LSP symbol item to jump to
---@param split_type? "vertical"|"horizontal" The type of split to create (defaults to horizontal)
---@param module_state NamuState The state from the calling module
---@return number|nil window_id The new window ID if successful
function M.open_in_split(item, split_type, module_state)
  if not item or not item.value then
    return nil
  end

  -- Capture original module_state
  local original_win = module_state.original_win or vim.api.nvim_get_current_win()
  local original_buf = module_state.original_buf or vim.api.nvim_get_current_buf()
  local original_pos = module_state.original_pos or vim.api.nvim_win_get_cursor(original_win)

  -- Get target info
  -- fallback hierarchy: buffer_symbols -> item bufnr -> original buf
  local target_bufnr = item.value.bufnr or item.bufnr
  local target_path = nil
  -- Try to get path from multiple possible sources
  if item.value.file_path then
    target_path = item.value.file_path
  elseif item.value.uri then
    target_path = vim.uri_to_fname(item.value.uri)
  elseif item.value.filename then
    target_path = item.value.filename
  end

  -- If we have a path but no valid bufnr, try to find an existing buffer
  if (not target_bufnr or not vim.api.nvim_buf_is_valid(target_bufnr)) and target_path then
    target_bufnr = find_buf_by_path(target_path)
  end
  local target_lnum = item.value.lnum or (item.value.range and item.value.range.start.line)
  local target_col = item.value.col or (item.value.range and item.value.range.start.character) or 0
  local split_config = {
    win = original_win,
    split = split_type == "vertical" and "right" or "below",
    noautocmd = true, -- Performance optimization
  }
  -- Create split window
  local new_win
  vim.api.nvim_win_call(original_win, function()
    new_win = vim.api.nvim_open_win(0, true, split_config)
  end)
  if not new_win then
    return nil
  end
  -- Set up buffer in the new window
  if target_bufnr and vim.api.nvim_buf_is_valid(target_bufnr) then
    -- Use existing buffer
    vim.api.nvim_win_set_buf(new_win, target_bufnr)
  elseif target_path then
    -- Try to load the file into a new buffer
    local buf_id = vim.fn.bufadd(target_path)
    vim.bo[buf_id].buflisted = true
    vim.api.nvim_win_set_buf(new_win, buf_id)
    -- Ensure the buffer is loaded (important for LSP features)
    if not vim.api.nvim_buf_is_loaded(buf_id) then
      vim.fn.bufload(buf_id)
    end
  end
  -- Set cursor position and center
  if target_lnum then
    -- Handle different indexing conventions (0-based vs 1-based)
    local line = type(target_lnum) == "number" and target_lnum or tonumber(target_lnum)
    if line then
      -- Adjust for 1-based line numbers if needed
      local buf_type = vim.api.nvim_get_option_value("buftype", { buf = vim.api.nvim_win_get_buf(new_win) })
      if buf_type ~= "terminal" then
        line = line > 0 and line or 1
      end
      local col = (type(target_col) == "number" and target_col >= 0) and target_col or 0
      pcall(vim.api.nvim_win_set_cursor, new_win, { line, col })
      -- Center view
      vim.api.nvim_win_call(new_win, function()
        vim.cmd("normal! zz")
      end)
    end
  end
  local function is_valid_win(win_id)
    return win_id and vim.api.nvim_win_is_valid(win_id)
  end
  local function is_valid_buf(buf_id)
    return buf_id and vim.api.nvim_buf_is_valid(buf_id)
  end
  -- Restore original window
  if is_valid_win(original_win) and is_valid_buf(original_buf) then
    pcall(vim.api.nvim_win_set_buf, original_win, original_buf)
    pcall(vim.api.nvim_win_set_cursor, original_win, original_pos)
  end
  -- Focus new window
  pcall(vim.api.nvim_set_current_win, new_win)

  return new_win
end

---Convert selecta items to quickfix format and add to quickfix list
---@param items_or_state SelectaItem|SelectaItem[]|SelectaState Items to add or picker state
---@param module_state? NamuState Optional state from calling module
---@return boolean success Whether items were successfully added to quickfix
function M.add_to_quickfix(items_or_state, module_state)
  local items_to_process
  -- Smart detection of what we received
  if items_or_state and items_or_state.filtered_items then
    local picker_state = items_or_state
    if picker_state.selected_count and picker_state.selected_count > 0 then
      items_to_process = picker_state:get_selected_items()
    else
      items_to_process = picker_state.filtered_items
    end
  elseif type(items_or_state) == "table" and items_or_state.text then
    items_to_process = { items_or_state }
  elseif type(items_or_state) == "table" and #items_or_state > 0 then
    items_to_process = items_or_state
  else
    vim.notify("No valid items to add to quickfix", vim.log.levels.WARN, notify_opts)
    return false
  end

  if #items_to_process == 0 then
    vim.notify("No items to add to quickfix", vim.log.levels.WARN, notify_opts)
    return false
  end
  local qf_items = {}
  local current_buf = module_state and module_state.original_buf or vim.api.nvim_get_current_buf()
  for _, item in ipairs(items_to_process) do
    if not item or not item.value then
      goto continue
    end
    local symbol = item.value
    local bufnr = symbol.bufnr or item.bufnr or current_buf
    local filename = ""
    -- Try to get filename from multiple sources
    if symbol.file_path then
      filename = symbol.file_path
    elseif symbol.uri then
      filename = vim.uri_to_fname(symbol.uri)
    elseif symbol.filename then
      filename = symbol.filename
    elseif bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      filename = vim.api.nvim_buf_get_name(bufnr)
    end
    -- Handle different line number conventions
    local lnum
    if symbol.diagnostic then
      -- Diagnostics use 0-based line numbers, convert to 1-based for quickfix
      lnum = (symbol.lnum and symbol.lnum + 1) or 1
    else
      -- Other symbols (LSP, etc.) may already be 1-based or use range
      lnum = symbol.lnum or (symbol.range and symbol.range.start.line + 1) or 1
    end
    local col = symbol.col or (symbol.range and symbol.range.start.character + 1) or 1
    local qf_entry = {
      filename = filename,
      lnum = lnum,
      col = col,
      text = item.text or symbol.name or "",
      type = symbol.kind and string.sub(symbol.kind, 1, 1):upper() or "I", -- First letter of kind or "I" for Info
    }
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      qf_entry.bufnr = bufnr
    end

    table.insert(qf_items, qf_entry)

    ::continue::
  end

  if #qf_items == 0 then
    vim.notify("No valid quickfix entries created", vim.log.levels.WARN, notify_opts)
    return false
  end
  vim.fn.setqflist(qf_items)
  vim.cmd("copen")
  local qf_win = vim.fn.getqflist({ winid = 0 }).winid
  if qf_win and qf_win ~= 0 and vim.api.nvim_win_is_valid(qf_win) then
    vim.defer_fn(function()
      pcall(vim.api.nvim_set_current_win, qf_win)
    end, 0)
  end
  local count = #qf_items
  local message = count == 1 and "Added 1 item to quickfix" or string.format("Added %d items to quickfix", count)
  vim.notify(message, vim.log.levels.INFO, notify_opts)

  return true
end

function M.create_sidebar(items, opts, module_state)
  opts = opts or {}
  -- Create sidebar state with complete options
  local sidebar_state = StateManager.new(items, opts)
  sidebar_state.filtered_items = items
  -- Create split window config
  local win_config = {
    split = opts.position or "right",
    win = module_state.original_win,
  }
  if opts.position == "left" or opts.position == "right" then
    win_config.width = opts.width or 40
  end
  -- Create the split window
  sidebar_state.win = vim.api.nvim_open_win(sidebar_state.buf, true, win_config)
  local win_opts = {
    cursorline = true,
    cursorlineopt = "both",
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    wrap = false,
    spell = false,
    list = false,
    colorcolumn = "",
  }
  for option, value in pairs(win_opts) do
    vim.wo[sidebar_state.win][option] = value
  end
  local buf_opts = {
    buftype = "nofile",
    bufhidden = "wipe",
    filetype = "namu_sidebar",
  }
  for option, value in pairs(buf_opts) do
    vim.api.nvim_set_option_value(option, value, { buf = sidebar_state.buf })
  end

  input_handler.setup_sidebar_keymaps(sidebar_state, opts)
  ui.render_visible_items(sidebar_state, opts)
  vim.api.nvim_set_option_value("modifiable", false, { buf = sidebar_state.buf })
  -- Update highlights
  common.update_current_highlight(sidebar_state, opts, 0)
  common.update_selection_highlights(sidebar_state, opts)

  return sidebar_state.win
end

return M
