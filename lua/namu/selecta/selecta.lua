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

-- Default configuration
M.config = {
  window = {
    relative = "editor",
    border = "none",
    style = "minimal",
    title_prefix = "> ",
    width_ratio = 0.6,
    height_ratio = 0.6,
    auto_size = true, -- Default to fixed size
    min_width = 20, -- Minimum width even when auto-sizing
    max_width = 120, -- Maximum width even when auto-sizing
    padding = 2, -- Extra padding for content
    max_height = 30, -- Maximum height
    min_height = 2, -- Minimum height
    auto_resize = true, -- Enable dynamic resizing
    title_pos = "left",
    show_footer = true, -- Enable/disable footer
    footer_pos = "right",
  },
  display = {
    mode = "icon",
    padding = 1,
  },
  current_highlight = {
    enabled = false, -- Enable custom selection highlight
    hl_group = "CursorLine", -- Default highlight group (could also create a custom one)
    prefix_icon = " ", --▎ ▎󰇙┆Vertical bar icon for current selection
  },
  offset = 0,
  debug = false,
  preserve_order = false, -- Default to false unless the other module handle it
  keymaps = {},
  auto_select = false,
  row_position = "top10", -- options: "center"|"top10",
  right_position = { -- only works when row_position is one of right aligned
    -- If set to false, it plays nicly with initially_hidden option is on
    fixed = false, -- true for percentage-based, false for flexible width-based
    ratio = 0.7, -- percentage of screen width where right-aligned windows start
  },
  movement = {
    next = { "<C-n>", "<DOWN>" }, -- Support multiple keys
    previous = { "<C-p>", "<UP>" }, -- Support multiple keys
    close = { "<ESC>" },
    select = { "<CR>" },
    delete_word = {},
    clear_line = {},
    -- Deprecated mappings (but still working)
    -- alternative_next = "<DOWN>", -- @deprecated: Will be removed in v1.0
    -- alternative_previous = "<UP>", -- @deprecated: Will be removed in v1.0
  },
  multiselect = {
    enabled = false,
    indicator = "●", -- or "✓"◉
    keymaps = {
      toggle = "<Tab>",
      select_all = "<C-a>",
      clear_all = "<C-l>",
      untoggle = "<S-Tab>",
    },
    max_items = nil, -- No limit by default
  },
  custom_keymaps = {},
  loading_indicator = {
    text = "Loading results...",
    icon = "󰇚",
  },
}

---@class SelectaStateManager
local StateManager = {}
StateManager.__index = StateManager

---Create a new picker state
---@param items SelectaItem[] List of items to display
---@param opts SelectaOptions Configuration options
---@return SelectaState
function StateManager.new(items, opts)
  local initial_width, initial_height =
    M.calculate_window_size(opts.initially_hidden and {} or items, opts, opts.formatter, 0)

  local row, col = M.get_window_position(initial_width, opts.row_position)

  local state = {
    -- Window and buffer info
    buf = vim.api.nvim_create_buf(false, true),
    original_buf = vim.api.nvim_get_current_buf(),
    prompt_buf = nil,
    prompt_win = nil,
    win = nil,
    -- Position and size
    row = row,
    col = col,
    width = initial_width,
    height = initial_height,
    -- Item data
    items = items,
    filtered_items = opts.initially_hidden and {} or items,
    filter_metadata = nil,
    -- Selection state
    selected = {},
    selected_count = 0,
    -- Input state
    query = {},
    cursor_pos = 1,
    -- UI state
    active = true,
    initial_open = true,
    best_match_index = nil,
    cursor_moved = false,
    -- Async state
    is_loading = false,
    last_query = nil,
    current_request_id = nil,
    loading_extmark_id = nil,
    last_request_time = nil,
  }

  return setmetatable(state, StateManager)
end

---Check if the state is still valid/active
---@return boolean
function StateManager:is_valid()
  return self.active
    and self.buf
    and vim.api.nvim_buf_is_valid(self.buf)
    and self.win
    and vim.api.nvim_win_is_valid(self.win)
end

---Update query and cursor position
---@param char string|number The character or keycode
---@return boolean Whether the query was changed
function StateManager:update_query(char)
  if type(char) == "number" and char >= 32 and char <= 126 then
    table.insert(self.query, self.cursor_pos, vim.fn.nr2char(char))
    self.cursor_pos = self.cursor_pos + 1
    self.initial_open = false
    self.cursor_moved = false
    return true
  end
  return false
end

---Move the cursor left/right in the query
---@param direction number Positive for right, negative for left
function StateManager:move_cursor(direction)
  if direction < 0 then
    self.cursor_pos = math.max(1, self.cursor_pos - 1)
  else
    self.cursor_pos = math.min(#self.query + 1, self.cursor_pos + 1)
  end
end

---Delete the character before the cursor
---@return boolean Whether a character was deleted
function StateManager:backspace()
  if self.cursor_pos > 1 then
    table.remove(self.query, self.cursor_pos - 1)
    self.cursor_pos = self.cursor_pos - 1
    self.initial_open = false
    self.cursor_moved = false
    return true
  end
  return false
end

---Get the current query as a string
---@return string
function StateManager:get_query_string()
  return table.concat(self.query)
end

function M.log(message)
  logger.log(message)
end

M.clear_log = logger.clear_log

local ns_id = vim.api.nvim_create_namespace("selecta_highlights")
local current_selection_ns = vim.api.nvim_create_namespace("selecta_current_selection")

-- Add this at the module level
local cursor_manager = {
  guicursor = nil,
  active = false,
  restore_timer = nil,
}

-- Replace the hide_cursor function
function cursor_manager.hide()
  -- Don't hide if already hidden
  if cursor_manager.active then
    return
  end

  -- Store current cursor state
  cursor_manager.guicursor = vim.o.guicursor
  cursor_manager.active = true

  -- Hide cursor
  vim.o.guicursor = "a:NamuCursor"

  -- Set safety timer to restore cursor after 30 seconds if not restored properly
  -- This prevents permanent cursor loss if something goes wrong
  if cursor_manager.restore_timer then
    cursor_manager.restore_timer:stop()
  end
  cursor_manager.restore_timer = vim.defer_fn(function()
    if cursor_manager.active then
      cursor_manager.restore()
      vim.notify("Cursor automatically restored after timeout", vim.log.levels.WARN)
    end
  end, 30000)
end

-- Replace the restore_cursor function
function cursor_manager.restore()
  -- Only restore if we're active
  if not cursor_manager.active then
    return
  end

  -- Stop the safety timer
  if cursor_manager.restore_timer then
    cursor_manager.restore_timer:stop()
    cursor_manager.restore_timer = nil
  end

  -- Handle edge case where guicursor was empty
  if cursor_manager.guicursor == "" then
    vim.o.guicursor = "a:"
  elseif cursor_manager.guicursor then
    vim.o.guicursor = cursor_manager.guicursor
  end

  -- Reset state
  cursor_manager.guicursor = nil
  cursor_manager.active = false
end

-- Add a function to check status
function cursor_manager.is_hidden()
  return cursor_manager.active
end

local function get_prefix_info(item, max_prefix_width)
  local prefix_text = item.kind or ""
  local raw_width = vim.api.nvim_strwidth(prefix_text)
  -- Use max_prefix_width for alignment in text mode
  return {
    text = prefix_text,
    width = max_prefix_width + 1, -- Add padding
    raw_width = raw_width,
    padding = max_prefix_width - raw_width + 1,
    hl_group = item.hl_group or "NamuPrefix", -- Use item's highlight group or default
  }
end

---@param position string|nil
---@return {type: string, ratio: number}
local function parse_position(position)
  if type(position) ~= "string" then
    return {
      type = "top",
      ratio = 0.1,
    }
  end

  -- Match patterns like "top10", "top20_right", "center", etc.
  ---@diagnostic disable-next-line: undefined-field
  local base, percent, right = position:match("^(top)(%d+)(.*)$")

  if base and percent then
    -- Convert percentage to ratio (e.g., 10 -> 0.1)
    return {
      type = base .. (right == "_right" and "_right" or ""),
      ratio = tonumber(percent) / 100,
    }
  end

  local fixed_positions = {
    center = 0.5,
    bottom = 0.8,
  }
  -- Handle fixed positions
  if fixed_positions[position] then
    return {
      type = position,
      ratio = fixed_positions[position],
    }
  end
  return {
    type = "top",
    ratio = 0.1,
  }
end

local function calculate_max_available_height(position_info)
  local lines = vim.o.lines
  if position_info.type:match("^top") then
    -- Handle any top position (top, top_right, with any percentage)
    return lines - math.floor(lines * position_info.ratio) - vim.o.cmdheight - 4
  elseif position_info.type == "bottom" then
    return math.floor(vim.o.lines * 0.2)
  else
    return lines - math.floor(lines / 2) - 4
  end
end

---@param items SelectaItem[]
---@param opts SelectaOptions
---@param formatter fun(item: SelectaItem): string
function M.calculate_window_size(items, opts, formatter, state_col)
  local max_width = opts.window.max_width or M.config.window.max_width
  local min_width = opts.window.min_width or M.config.window.min_width
  local max_height = opts.window.max_height or M.config.window.max_height
  local min_height = opts.window.min_height or M.config.window.min_height
  local padding = opts.window.padding or M.config.window.padding

  -- Calculate content width
  local content_width = min_width
  -- Calculate initial column position
  local row_position = opts.row_position or M.config.row_position or "top10"
  local position_info = parse_position(row_position)

  local initial_col = state_col
  if not initial_col then
    if position_info.type:find("_right$") then
      if M.config.right_position.fixed then
        initial_col = math.floor(vim.o.columns * M.config.right_position.ratio)
        -- Constrain max_width based on available space
        max_width = math.min(max_width, vim.o.columns - initial_col - (padding * 2) - 1)
      else
        -- Constrain max_width based on available space
        max_width = math.min(max_width, vim.o.columns - (padding * 2) - 1)
        initial_col = math.floor((vim.o.columns - max_width) / 2) -- Default to center if not fixed
      end
    else
      -- Constrain max_width based on available space
      max_width = math.min(max_width, vim.o.columns - (padding * 2) - 1)
      initial_col = math.floor((vim.o.columns - max_width) / 2) -- Center position
    end
  end

  -- Calculate available width based on constrained max_width
  local max_available_width = max_width

  if opts.window.auto_size then
    for _, item in ipairs(items) do
      local line = formatter(item)
      local width = vim.api.nvim_strwidth(line)
      if width > content_width then
        content_width = width
      end
    end
    content_width = content_width + padding
    content_width = math.min(math.max(content_width, min_width), max_width, max_available_width)
  else
    -- Use ratio-based width
    content_width = math.floor(vim.o.columns * (opts.window.width_ratio or M.config.window.width_ratio))
    content_width = math.min(content_width, max_available_width) -- Constrain ratio-based width as well
  end

  -- Calculate height based on number of items
  local max_available_height = calculate_max_available_height(position_info)
  local content_height = #items
  -- Constrain height between min and max values
  content_height = math.min(content_height, max_height)
  content_height = math.min(content_height, max_available_height)
  content_height = math.max(content_height, min_height)

  return content_width, content_height
end

local function calculate_max_prefix_width(items, display_mode)
  if display_mode == "raw" then
    return 0 -- No prefix width needed for raw mode
  elseif display_mode == "icon" then
    return 2 -- Fixed width for icons
  end

  local max_width = 0
  for _, item in ipairs(items) do
    local prefix_text = item.kind or ""
    max_width = math.max(max_width, vim.api.nvim_strwidth(prefix_text))
  end
  return max_width
end

---Get border characters configuration
---@param border string|table
---@return string|table
local function get_prompt_border(border)
  -- Handle predefined styles
  if type(border) == "string" then
    if border == "none" then
      return "none"
    end

    local borders = {
      rounded = { "╭", "─", "╮", "│", "", "", "", "│" },
      single = { "┌", "─", "┐", "│", "", "", "", "│" },
      double = { "╔", "═", "╗", "║", "", "", "", "║" },
      solid = { "▛", "▀", "▜", "▌", "", "", "", "▐" },
    }

    -- If it's a predefined style
    if borders[border] then
      return borders[border]
    end

    -- If it's a single character for all borders
    return { border, border, border, border, "", "", "", border }
  elseif type(border) == "table" then
    local config = vim.deepcopy(border)

    -- Handle array of characters
    if #config == 8 and type(config[1]) == "string" then
      config[5] = "" -- bottom-right
      config[6] = "" -- bottom
      config[7] = "" -- bottom-left
      return config
    end

    -- Handle full border spec with highlight groups
    if #config == 8 and type(config[1]) == "table" then
      config[5] = { "", config[5][2] } -- bottom-right
      config[6] = { "", config[6][2] } -- bottom
      config[7] = { "", config[7][2] } -- bottom-left
      return config
    end
  end

  -- Fallback to single border style if input is invalid
  return { "┌", "─", "┐", "│", "", "", "", "│" }
end

local function get_border_with_footer(opts)
  if opts.window.border == "none" then
    -- Create invisible border with single spaces
    -- Each element must be exactly one cell
    return { "", "", "", "", "", " ", "", "" }
  end

  -- For predefined border styles, convert them to array format
  local borders = {
    single = { "┌", "─", "┐", "│", "┘", "─", "└", "│" },
    double = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" },
    rounded = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
  }

  return borders[opts.window.border] or opts.window.border
end

---@thanks to mini.pick @echasnovski for the idea and basically this function as well
---@param state SelectaState
---@param opts SelectaOptions
local function update_prompt(state, opts)
  -- Get the query before and after the cursor
  local before_cursor = table.concat(vim.list_slice(state.query, 1, state.cursor_pos - 1))
  local after_cursor = table.concat(vim.list_slice(state.query, state.cursor_pos))

  -- Build the prompt with cursor indicator
  local raw_prompt = opts.window.title_prefix .. before_cursor .. "│" .. after_cursor

  -- Update the prompt buffer if valid
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
      if vim.api.nvim_buf_is_valid(state.prompt_buf) then
        vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { raw_prompt })
      end
    end
  end
end

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

  -- Run pre-filter hook if available
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
  for i, item in ipairs(items) do
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

---@param state SelectaState
---@param opts SelectaOptions
local function create_prompt_window(state, opts)
  state.prompt_buf = vim.api.nvim_create_buf(false, true)

  local prompt_config = {
    relative = opts.window.relative or M.config.window.relative,
    row = state.row, -- this related to the zindex because this cover main menu
    col = state.col,
    width = state.width,
    height = 1,
    style = "minimal",
    border = get_prompt_border(opts.window.border),
    zindex = 60, -- related to row without rhis, row = row -1
  }

  state.prompt_win = vim.api.nvim_open_win(state.prompt_buf, false, prompt_config)
  -- vim.api.nvim_win_set_option(state.prompt_win, "winhl", "Normal:NamuPrompt")
end

---Generate a unique ID for an item
---@param item SelectaItem
---@return string
local function get_item_id(item)
  if item.id then
    return item.id
  end

  if item.value then
    if item.value.signature then
      return item.value.signature
    elseif item.value.id then
      return item.value.id
    end
  end

  -- Fallback: Create a string from text or other properties
  return tostring(item.value or item.text)
end

---@param buf number
---@param line_nr number
---@param item SelectaItem
---@param opts SelectaOptions
---@param query string
local function apply_highlights(buf, line_nr, item, opts, query, line_length, state)
  -- Skip if line is not visible (extra safety check)
  local win_info = vim.fn.getwininfo(state.win)[1]
  local topline = win_info.topline - 1
  local botline = win_info.botline - 1

  -- TODO: make text = item.text or item.value.text pleeeeeese
  if line_nr < topline or line_nr > botline then
    return
  end
  local display_str = opts.formatter(item)

  local padding_width = 0
  if opts.current_highlight and opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
    padding_width = vim.api.nvim_strwidth(opts.current_highlight.prefix_icon)
  end
  -- First, check if this is a symbol filter query
  -- local filter = query:match("^%%%w%w(.*)$")
  -- local actual_query = filter and query:sub(4) or query -- Use everything after %xx if filter exists
  local filter, remaining = query:match("^(/[%w][%w])(.*)$")
  local actual_query = remaining or query

  -- Highlight title prefix in prompt buffer
  if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
    -- Highlight the title prefix
    local prefix = opts.window.title_prefix
    if prefix then
      vim.api.nvim_buf_set_extmark(state.prompt_buf, ns_id, 0, 0, {
        end_col = #prefix,
        hl_group = "NamuFilter",
        priority = 200,
      })
    end
    -- If there's a filter, highlight it in the prompt buffer
    if filter then
      local prefix_len = #(opts.window.title_prefix or "")
      vim.api.nvim_buf_set_extmark(state.prompt_buf, ns_id, 0, prefix_len, {
        end_col = prefix_len + 3, -- Length of %xx is 3
        hl_group = "NamuFilter",
        priority = 200,
      })
    end
  end
  -- Get the formatted display string
  if opts.display.mode == "raw" then
    local offset = opts.offset and opts.offset(item) or 0
    offset = offset + padding_width -- Add the padding width to the offset
    if query ~= "" then
      local match = matcher.get_match_positions(item.text, query)
      if match then
        for _, pos in ipairs(match.positions) do
          local start_col = offset + pos[1] - 1
          local end_col = offset + pos[2]

          -- Ensure we don't exceed line length
          end_col = math.min(end_col, line_length)

          if end_col > start_col then
            vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, start_col, {
              end_col = end_col,
              hl_group = "NamuMatch",
              priority = 200,
              hl_mode = "combine",
            })
          end
        end
      end
    end
  else
    -- Find the actual icon boundary by looking for the padding
    local _, icon_end = display_str:find("^" .. string.rep(" ", padding_width) .. "[^%s]+%s+")
    -- local _, icon_end = display_str:find("^[^%s]+%s+")
    if not icon_end then
      icon_end = padding_width + 2 -- fallback if pattern not found, accounting for padding
    end

    -- Allow modules to customize prefix highlighting
    if opts.prefix_highlighter then
      opts.prefix_highlighter(buf, line_nr, item, icon_end, ns_id)
    else
      -- TODO: this is plays with icons highlights
      -- Highlight prefix/icon
      vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, padding_width, {
        end_col = icon_end,
        hl_group = get_prefix_info(item, opts.display.prefix_width).hl_group,
        priority = 100,
        hl_mode = "combine",
      })
    end

    -- Calculate base offset for query highlights (icon + space)
    -- local base_offset = item.icon and (vim.api.nvim_strwidth(item.icon) + 1) or 0

    -- Highlight matches in the text using actual_query
    if actual_query ~= "" then
      local match = matcher.get_match_positions(item.text, actual_query)
      if match then
        for _, pos in ipairs(match.positions) do
          -- Get the matched text
          local match_text = item.text:sub(pos[1], pos[2])

          -- Find this text in the display string after the icon
          local display_content = display_str:sub(icon_end + 1)
          local match_in_display = display_content:find(vim.pesc(match_text), 1, true)
          if match_in_display then
            local start_col = icon_end + match_in_display - 1
            local end_col = start_col + #match_text
            -- local highlight_text = display_str:sub(start_col + 1, end_col)
            vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, start_col, {
              end_col = end_col,
              hl_group = "NamuMatch",
              priority = 200,
              hl_mode = "combine",
            })
          end
        end
      end
    end
  end

  local indicator = opts.multiselect and opts.multiselect.indicator or M.config.multiselect.indicator
  -- Add selection indicator if item is selected
  if opts.multiselect and opts.multiselect.enabled then
    local item_id = get_item_id(item)
    if state.selected[item_id] then
      vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, 0, {
        virt_text = { { indicator, "NamuSelected" } },
        virt_text_pos = "overlay",
        priority = 200,
      })
    end
  end
end

---@param state SelectaState The current state of the selecta picker
---@param opts SelectaOptions The options for the selecta picker
---@param line_nr number The 0-based line number to highlight
---@return nil
local function update_current_highlight(state, opts, line_nr)
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  -- Clear previous highlights in this namespace
  vim.api.nvim_buf_clear_namespace(state.buf, current_selection_ns, 0, -1)

  -- Get the line content
  local lines = vim.api.nvim_buf_get_lines(state.buf, line_nr, line_nr + 1, false)
  if #lines == 0 then
    return
  end

  -- Apply highlight to the whole line
  vim.api.nvim_buf_set_extmark(state.buf, current_selection_ns, line_nr, 0, {
    end_row = line_nr + 1,
    end_col = 0,
    hl_eol = true,
    hl_group = "NamuCurrentItem",
    priority = 202, -- Higher than regular highlights but lower than matches
  })

  -- Add the prefix icon if enabled
  if opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
    vim.api.nvim_buf_set_extmark(state.buf, current_selection_ns, line_nr, 0, {
      virt_text = { { opts.current_highlight.prefix_icon, "NamuCurrentItem" } },
      virt_text_pos = "overlay",
      priority = 202, -- Higher priority than the line highlight
    })
  end
end

---@param state SelectaState
---@param opts SelectaOptions
local function update_cursor_position(state, opts)
  if #state.filtered_items > 0 then
    local new_pos

    -- Check if we're in hierarchical mode and have direct matches
    local has_hierarchical_results = false

    if opts.preserve_hierarchy then
      -- Find the first direct match in the filtered items
      for _, item in ipairs(state.filtered_items) do
        if item.is_direct_match then
          has_hierarchical_results = true
          break
        end
      end
    end

    -- Determine cursor position based on various factors
    if has_hierarchical_results and state.best_match_index and not state.cursor_moved then
      -- Use the best match index we calculated during hierarchical filtering
      new_pos = { state.best_match_index, 0 }
      -- Only use best_match_index if we haven't moved the cursor manually
      -- and we're not in initial state
    elseif opts.preserve_order and state.best_match_index and not state.initial_open and not state.cursor_moved then
      new_pos = { state.best_match_index, 0 }
    else
      -- When not preserving order, always start at first item (best match)
      -- unless cursor has been manually moved
      if not opts.preserve_order and not state.cursor_moved then
        new_pos = { 1, 0 }
      else
        -- Use current cursor position
        local cur_pos = vim.api.nvim_win_get_cursor(state.win)
        new_pos = { math.min(cur_pos[1], #state.filtered_items), 0 }
      end
    end
    -- SAFETY CHECK: Ensure new_pos[1] is valid before setting the cursor
    new_pos[1] = math.min(new_pos[1], #state.filtered_items)
    new_pos[1] = math.max(new_pos[1], 1) -- Ensure at least 1
    vim.api.nvim_win_set_cursor(state.win, new_pos)
    update_current_highlight(state, opts, new_pos[1] - 1) -- 0-indexed for extmarks

    -- Only trigger on_move if not in initial state
    if opts.on_move and not state.initial_open then
      opts.on_move(state.filtered_items[new_pos[1]])
    end
  end
end

-- Add proper bounds checking for highlight operations
local function safe_highlight_current_item(state, opts, line_nr)
  -- Check if state and buffer are valid
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end

  -- Clear previous highlights
  vim.api.nvim_buf_clear_namespace(state.buf, current_selection_ns, 0, -1)

  -- Validate line number
  if line_nr < 0 or line_nr >= vim.api.nvim_buf_line_count(state.buf) then
    return false
  end

  -- Apply highlight safely
  local ok, err = pcall(function()
    vim.api.nvim_buf_set_extmark(state.buf, current_selection_ns, line_nr, 0, {
      end_row = line_nr + 1,
      end_col = 0,
      hl_eol = true,
      hl_group = "NamuCurrentItem",
      priority = 202,
    })

    -- Add the prefix icon if enabled
    if opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
      vim.api.nvim_buf_set_extmark(state.buf, current_selection_ns, line_nr, 0, {
        virt_text = { { opts.current_highlight.prefix_icon, "NamuCurrentItem" } },
        virt_text_pos = "overlay",
        priority = 202,
      })
    end
  end)

  if not ok then
    logger.error("Error highlighting current item: " .. err)
    return false
  end

  return true
end

-- Add this function to render only visible items
---@param state SelectaState
---@param opts SelectaOptions
local function render_visible_items(state, opts)
  -- Early return if not valid
  if not state:is_valid() then
    return
  end

  -- Get window info for visibility determination
  local win_info = vim.fn.getwininfo(state.win)[1]
  if not win_info then
    return
  end

  -- Format ALL lines (not just visible ones) to maintain consistent buffer state
  local lines = {}
  for i, item in ipairs(state.filtered_items) do
    lines[i] = opts.formatter(item)
  end

  -- Update the buffer with all formatted lines
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(state.buf, ns_id, 0, -1)

  -- Get visible range for optimization
  local topline = win_info.topline - 1
  local botline = math.min(win_info.botline - 1, #state.filtered_items - 1)

  -- Apply highlights only to visible items for performance optimization
  local query = state:get_query_string()
  for i = topline, botline do
    local line_nr = i -- 0-indexed for extmarks
    local item = state.filtered_items[i + 1] -- 1-indexed for items
    if item then
      local line = lines[i + 1]
      local line_length = vim.api.nvim_strwidth(line)
      apply_highlights(state.buf, line_nr, item, opts, query, line_length, state)
    end
  end

  -- Call render hook after highlights are applied
  if opts.hooks and opts.hooks.on_render then
    opts.hooks.on_render(state.buf, state.filtered_items, opts)
  end

  -- Update current line highlight
  local cursor_pos = vim.api.nvim_win_get_cursor(state.win)
  if cursor_pos and cursor_pos[1] > 0 and cursor_pos[1] <= #state.filtered_items then
    safe_highlight_current_item(state, opts, cursor_pos[1] - 1)
  end
end

---@param state SelectaState
---@param opts SelectaOptions
local function resize_window(state, opts)
  if not (state.active and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  -- Calculate new dimensions based on filtered items
  -- BUG: we need to limit the new_width to the available space on the screen so
  -- it doesn't push the col to go left
  local new_width, new_height = M.calculate_window_size(state.filtered_items, opts, opts.formatter)
  local current_config = vim.api.nvim_win_get_config(state.win)
  -- Calculate maximum height based on available space below the initial row
  local max_available_height = calculate_max_available_height(parse_position(opts.row_position))
  new_height = math.min(new_height, max_available_height)
  -- print(
  --   string.format(
  --     "Resizing window: row=%d, col=%d, width=%d, height=%d, max_available_height=%d, num_items=%d",
  --     state.row,
  --     state.col,
  --     new_width,
  --     new_height,
  --     max_available_height,
  --     #state.filtered_items
  --   )
  -- )
  -- Main window config
  local initial_col = state.col
  local max_width = opts.window.max_width or M.config.window.max_width
  local padding = opts.window.padding or M.config.window.padding
  local max_available_width = vim.o.columns - initial_col - (padding * 2) - 1
  new_width = math.min(new_width, max_available_width, max_width)
  local win_config = {
    relative = current_config.relative,
    row = current_config.row, -- or state.row
    col = state.col, -- or state.col
    width = new_width,
    height = new_height,
    style = current_config.style,
    border = opts.window.border,
  }

  -- Prompt window config
  local prompt_config = {
    relative = current_config.relative,
    row = state.row,
    col = state.col,
    width = new_width,
    height = 1,
    style = "minimal",
    border = get_prompt_border(opts.window.border),
    zindex = 60,
  }

  vim.api.nvim_win_set_config(state.win, win_config)
  if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
    vim.api.nvim_win_set_config(state.prompt_win, prompt_config)
  end

  -- Simple fix: if filtered items are less than window height,
  -- ensure we're viewing from the top
  if #state.filtered_items <= new_height then
    vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
    vim.cmd("normal! zt")
  end
end

-- Update the footer whenever filtered items change
local function update_footer(state, win, opts)
  if not vim.api.nvim_win_is_valid(win) or not opts.window.show_footer then
    return
  end

  local footer_text = string.format(" %d/%d ", #state.filtered_items, #state.items)
  local footer_pos = opts.window.footer_pos or "right"

  -- Now we update the footer separately using win_set_config with footer option
  pcall(vim.api.nvim_win_set_config, win, {
    footer = {
      { footer_text, "NamuFooter" },
    },
    footer_pos = footer_pos,
  })
end

-- Create a namespace for the filter info display
local filter_info_ns = vim.api.nvim_create_namespace("selecta_filter_info")

-- Function to update the filter info display
local function update_filter_info(state, filter_metadata)
  -- Clear previous extmarks
  if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
    vim.api.nvim_buf_clear_namespace(state.prompt_buf, filter_info_ns, 0, -1)

    -- If we have filter metadata and no extra text after the filter, show it
    if filter_metadata and filter_metadata.is_symbol_filter then
      -- Only show info if there's no additional text after the filter code
      local remaining = filter_metadata.remaining or ""

      if remaining == "" then -- Only show if no extra text after the filter
        local direct_count = filter_metadata.direct_match_count or 0
        local description = filter_metadata.filter_type or "items"

        -- Format: "14 fn"
        local info_text = string.format("%d %s", direct_count, description)

        -- Set the extmark with the filter info - right aligned
        vim.api.nvim_buf_set_extmark(
          state.prompt_buf,
          filter_info_ns,
          0, -- Line 0
          0, -- Column position (will be ignored with right_align)
          {
            virt_text = { { info_text, "Comment" } },
            virt_text_pos = "right_align",
          }
        )
      end
    end
  end
end

local prompt_info_ns = vim.api.nvim_create_namespace("selecta_prompt_info")
---@param state SelectaState
---@param opts SelectaOptions
---@param show_info boolean Whether to show the info
local function update_prompt_info(state, opts, show_info)
  if not state.prompt_buf or not vim.api.nvim_buf_is_valid(state.prompt_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.prompt_buf, prompt_info_ns, 0, -1)
  if show_info and opts.initial_prompt_info and opts.initial_prompt_info.text then
    vim.api.nvim_buf_set_extmark(state.prompt_buf, prompt_info_ns, 0, 0, {
      virt_text = { { opts.initial_prompt_info.text, opts.initial_prompt_info.hl_group or "Comment" } },
      virt_text_pos = opts.initial_prompt_info.pos or "right_align",
      priority = 201,
    })
  end
end

-- Main update_display function using the split functions
---@param state SelectaState
---@param opts SelectaOptions
function M.update_display(state, opts)
  if not state.active then
    return
  end

  local query = state:get_query_string()
  update_prompt(state, opts)
  update_prompt_info(state, opts, #query == 0) -- Show only if query is empty

  -- Special handling for loading state
  if state.is_loading then
    if vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_clear_namespace(state.buf, ns_id, 0, -1)

      local loading_text = "Loading results..."
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { loading_text })

      -- Apply loading highlight
      vim.api.nvim_buf_set_extmark(state.buf, ns_id, 0, 0, {
        end_col = #loading_text,
        hl_group = "Comment",
        priority = 100,
      })
    end

    -- Update window size if needed
    if opts.window.auto_resize then
      resize_window(state, opts)
    end

    -- Update filter info display
    update_filter_info(state, state.filter_metadata)

    return
  end

  if query ~= "" or not opts.initially_hidden then
    -- Call before render hook
    if opts.hooks and opts.hooks.before_render then
      opts.hooks.before_render(state.filtered_items, opts)
    end

    -- Update footer after filtered items are updated
    if opts.window.show_footer then
      update_footer(state, state.win, opts)
    end

    -- Resize window if needed
    if opts.window.auto_resize then
      resize_window(state, opts)
    end

    -- Use virtualized rendering for better performance
    render_visible_items(state, opts)

    -- Update filter info display
    update_filter_info(state, state.filter_metadata)

    -- Update cursor position
    update_cursor_position(state, opts)
  else
    -- Handle case when initially hidden with no query
    if vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_clear_namespace(state.buf, ns_id, 0, -1)
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
      if opts.hooks and opts.hooks.on_buffer_clear then
        opts.hooks.on_buffer_clear()
      end
    end

    update_prompt_info(state, opts, #state.query == 0)

    -- Resize window to minimum dimensions
    if opts.window.auto_resize then
      local original_filtered_items = state.filtered_items
      state.filtered_items = {}
      resize_window(state, opts)
      state.filtered_items = original_filtered_items
    end
  end
end

local loading_ns_id = vim.api.nvim_create_namespace("selecta_loading_indicator")
---@param state SelectaState
---@param query string
---@param opts SelectaOptions
---@param callback function
---@return boolean started
function M.start_async_fetch(state, query, opts, callback)
  -- Generate a unique request ID for this specific request
  local request_id = tostring(vim.uv.now()) .. "_" .. vim.fn.rand()
  state.current_request_id = request_id
  -- Store the current query
  state.last_query = query
  -- Set loading state
  state.is_loading = true
  -- Display loading indicator
  if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
    -- Clear any previous loading indicator
    vim.api.nvim_buf_clear_namespace(state.prompt_buf, loading_ns_id, 0, -1)

    -- Get loading indicator text and icon with fallbacks
    local loading_icon = opts.loading_indicator and opts.loading_indicator.icon
      or M.config.loading_indicator and M.config.loading_indicator.icon
      or "󰇚"

    local loading_text = opts.loading_indicator and opts.loading_indicator.text
      or M.config.loading_indicator and M.config.loading_indicator.text
      or "Loading..."

    state.loading_extmark_id = vim.api.nvim_buf_set_extmark(state.prompt_buf, loading_ns_id, 0, 0, {
      virt_text = { { " " .. loading_icon .. " " .. loading_text, "Comment" } },
      virt_text_pos = "eol",
      priority = 200,
    })
  end

  -- Get the process function
  local process_fn = opts.async_source(query)

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

      -- Clear loading state
      state.is_loading = false

      -- Execute the callback
      if callback then
        callback()
      end
    end)
  end

  -- Start the process
  process_fn(handle_items)

  return true
end

---@param state SelectaState
---@param opts SelectaOptions
function M.process_query(state, opts)
  local query = table.concat(state.query)

  -- Step 1: Try async fetch if configured
  if opts.async_source then
    -- Try to start async fetch, pass callback for display update
    local started_async = M.start_async_fetch(state, query, opts, function()
      -- This callback runs after async operation completes
      M.update_filtered_items(state, query, opts)
      M.update_display(state, opts)
      vim.cmd("redraw")
    end)

    -- If async started successfully, return early without updating display
    -- The display update will happen in the callback when async completes
    if started_async then
      return
    end
  end

  -- Step 2: If we didn't start an async operation, filter and update normally
  M.update_filtered_items(state, query, opts)
  M.update_display(state, opts)
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
  -- Clear loading indicator if exists
  if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) and state.loading_extmark_id then
    vim.api.nvim_buf_clear_namespace(state.prompt_buf, loading_ns_id, 0, -1)
    state.loading_extmark_id = nil
    vim.api.nvim_buf_clear_namespace(state.prompt_buf, prompt_info_ns, 0, -1)
  end
  if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
    vim.api.nvim_win_close(state.prompt_win, true)
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  cursor_manager.restore()
end

---Toggle selection of the current item
---@param item SelectaItem The item to toggle
---@param opts SelectaOptions The current options
---@return boolean Whether the selection was changed
function StateManager:toggle_selection(item, opts)
  if not opts.multiselect or not opts.multiselect.enabled then
    return false
  end

  local item_id = get_item_id(item)
  if self.selected[item_id] then
    self.selected[item_id] = nil
    self.selected_count = self.selected_count - 1
    return true
  else
    if opts.multiselect.max_items and self.selected_count >= opts.multiselect.max_items then
      return false
    end
    self.selected[item_id] = true
    self.selected_count = self.selected_count + 1
    return true
  end
end

---Get the list of selected items
---@return SelectaItem[]
function StateManager:get_selected_items()
  local result = {}
  for _, item in ipairs(self.items) do
    if self.selected[get_item_id(item)] then
      table.insert(result, item)
    end
  end
  return result
end

---Clean up resources when closing the picker
function StateManager:cleanup()
  -- Clear loading state
  if self.prompt_buf and vim.api.nvim_buf_is_valid(self.prompt_buf) then
    vim.api.nvim_buf_clear_namespace(self.prompt_buf, loading_ns_id, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.prompt_buf, prompt_info_ns, 0, -1)
  end

  -- Close windows
  if self.prompt_win and vim.api.nvim_win_is_valid(self.prompt_win) then
    vim.api.nvim_win_close(self.prompt_win, true)
  end

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end

  -- Mark as inactive
  self.active = false
end

---Select or deselect all visible items
---@param state SelectaState
---@param opts SelectaOptions
---@param select boolean Whether to select or deselect
local function bulk_selection(state, opts, select)
  if not opts.multiselect or not opts.multiselect.enabled then
    return
  end

  if select and opts.multiselect.max_items and #state.filtered_items > opts.multiselect.max_items then
    return
  end

  local new_count = select and #state.filtered_items or 0

  -- Reset selection state
  state.selected = {}
  state.selected_count = 0

  if select then
    for _, item in ipairs(state.filtered_items) do
      state.selected[get_item_id(item)] = true
    end
    state.selected_count = new_count
  end
end

---Calculate window position based on preset
---@param row_position? "center"|"top10"|"top10_right"|"center_right"|"bottom"
---@param width number
---@return number row
---@return number col
function M.get_window_position(width, row_position)
  local lines = vim.o.lines
  local columns = vim.o.columns
  local cmdheight = vim.o.cmdheight
  local available_lines = lines - cmdheight - 2

  -- Parse the position
  local pos_info = parse_position(row_position)
  -- this will never return nil. I did tis to satisfy lua annotations
  if not pos_info then
    return 0, 0
  end

  -- Calculate column position once
  local col
  if pos_info.type:find("_right$") then -- Changed from row_position:match
    if M.config.right_position.fixed then
      -- Fixed right position regardless of width
      col = math.floor(columns * M.config.right_position.ratio)
    else
      -- Center position
      col = columns - width - 4
    end
  else
    -- Center position remains unchanged
    col = math.floor((columns - width) / 2)
  end

  -- Calculate row position
  local row
  if pos_info.type:match("^top") then
    row = math.floor(lines * pos_info.ratio)
  elseif pos_info.type == "bottom" then
    row = math.floor(lines * pos_info.ratio) - 4
  else -- center positions
    row = math.max(1, math.floor(available_lines * pos_info.ratio))
  end

  return row, col
end

---@param items SelectaItem[]
---@param opts SelectaOptions
local function create_picker(items, opts)
  local state = {
    buf = vim.api.nvim_create_buf(false, true),
    original_buf = vim.api.nvim_get_current_buf(),
    query = {},
    cursor_pos = 1,
    items = items,
    filtered_items = opts.initially_hidden and {} or items, -- Initialize filtered_items conditionally
    active = true,
    initial_open = true,
    best_match_index = nil,
    cursor_moved = false,
    selected = {},
    selected_count = 0,
    async_co = nil,
    is_loading = false,
    last_query = nil, -- Initialize last_query for async tracking
    loading_extmark_id = nil,
    last_request_time = nil,
  }
  local width, height
  if opts.initially_hidden then
    -- Use minimum width and height when initially hidden
    width = opts.window.min_width or M.config.window.min_width
    height = opts.window.min_height or M.config.window.min_height
  else
    width, height = M.calculate_window_size(items, opts, opts.formatter, 0)
  end

  local row, col = M.get_window_position(width, opts.row_position)

  -- print(string.format(
  --   "Initial position:  row=%d, column=%d, height=%d, position=%s, total_lines=%d, scrolloff=%d",
  --   -- available_lines,
  --   row,
  --   col,
  --   height,
  --   opts.row_position,
  --   vim.o.lines,
  --   vim.opt.scrolloff._value
  -- ))

  -- Store position info in state
  state.row = row
  state.col = col
  state.width = width
  state.height = height

  local win_config = vim.tbl_deep_extend("force", {
    relative = opts.window.relative or M.config.window.relative,
    row = row + 1, -- Shift main window down by 1 to make room for prompt
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = get_border_with_footer(opts),
  }, opts.window.override or {})

  if opts.window.show_footer then
    win_config.footer = {
      { string.format(" %d/%d ", #items, #items), "NamuFooter" },
    }
    win_config.footer_pos = opts.window.footer_pos or "right"
  end

  -- Create windows and setup
  state.win = vim.api.nvim_open_win(state.buf, true, win_config)

  -- Call window create hook
  if opts.hooks and opts.hooks.on_window_create then
    opts.hooks.on_window_create(state.win, state.buf, opts)
  end

  create_prompt_window(state, opts)
  update_prompt_info(state, opts, true)

  vim.wo[state.win].cursorline = true
  vim.wo[state.win].cursorlineopt = "both"
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.buf })
  -- TODO: this is for later to apply the same highlight of the filtype
  -- to the text for better highlighting.
  -- vim.api.nvim_buf_set_name(state.buf, "Namu_items")
  -- vim.api.nvim_buf_set_option(state.buf, "filetype", "match")

  -- Handle initial cursor position if specified
  if opts.initial_index and opts.initial_index <= #items then
    local target_pos = math.min(opts.initial_index, #state.filtered_items)
    if target_pos > 0 then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(state.win) then
          -- Set cursor position
          pcall(vim.api.nvim_win_set_cursor, state.win, { target_pos, 0 })
          -- Force redraw to update highlight
          vim.cmd("redraw")
          -- Ensure cursorline is enabled and visible
          vim.wo[state.win].cursorline = true
          -- Trigger a manual cursor move to ensure everything is updated
          if opts.on_move then
            opts.on_move(state.filtered_items[target_pos])
          end
        end
      end)
    end
  end

  return state
end

-- Pre-compute the special keys once at module level
local SPECIAL_KEYS = {
  UP = vim.api.nvim_replace_termcodes("<Up>", true, true, true),
  DOWN = vim.api.nvim_replace_termcodes("<Down>", true, true, true),
  CTRL_P = vim.api.nvim_replace_termcodes("<C-p>", true, true, true),
  CTRL_N = vim.api.nvim_replace_termcodes("<C-n>", true, true, true),
  TAB = vim.api.nvim_replace_termcodes("<Tab>", true, true, true),
  S_TAB = vim.api.nvim_replace_termcodes("<S-Tab>", true, true, true),
  LEFT = vim.api.nvim_replace_termcodes("<Left>", true, true, true),
  RIGHT = vim.api.nvim_replace_termcodes("<Right>", true, true, true),
  CR = vim.api.nvim_replace_termcodes("<CR>", true, true, true),
  ESC = vim.api.nvim_replace_termcodes("<ESC>", true, true, true),
  BS = vim.api.nvim_replace_termcodes("<BS>", true, true, true),
  MOUSE = vim.api.nvim_replace_termcodes("<LeftMouse>", true, true, true),
}

---Delete the word before the cursor
---@return boolean Whether a word was deleted
function StateManager:delete_word()
  -- If we're at the start, nothing to delete
  if self.cursor_pos <= 1 then
    return false
  end

  -- Find the last non-space character before cursor
  local last_char_pos = self.cursor_pos - 1
  while last_char_pos > 1 and self.query[last_char_pos] == " " do
    last_char_pos = last_char_pos - 1
  end

  -- Find the start of the word
  local word_start = last_char_pos
  while word_start > 1 and self.query[word_start - 1] ~= " " do
    word_start = word_start - 1
  end

  -- Remove characters from word_start to last_char_pos
  for _ = word_start, last_char_pos do
    table.remove(self.query, word_start)
  end

  -- Update cursor position
  self.cursor_pos = word_start
  self.initial_open = false
  self.cursor_moved = false

  return true
end

---Clear the entire query
---@return nil
function StateManager:clear_query()
  self.query = {}
  self.cursor_pos = 1
  self.initial_open = false
  self.cursor_moved = false
end

-- Pre-compute the movement keys
---@param opts SelectaOptions
---@return table<string, string[]>
local function get_movement_keys(opts)
  local movement_config = opts.movement or M.config.movement
  local keys = {
    next = {},
    previous = {},
    close = {},
    select = {},
    delete_word = {},
    clear_line = {},
  }

  -- Handle arrays of keys
  for action, mapping in pairs(movement_config) do
    if action ~= "alternative_next" and action ~= "alternative_previous" then
      if type(mapping) == "table" then
        -- Handle array of keys
        for _, key in ipairs(mapping) do
          table.insert(keys[action], vim.api.nvim_replace_termcodes(key, true, true, true))
        end
      elseif type(mapping) == "string" then
        -- Handle single key as string
        table.insert(keys[action], vim.api.nvim_replace_termcodes(mapping, true, true, true))
      end
    end
  end

  -- Handle deprecated alternative mappings
  if movement_config.alternative_next then
    -- TODO: version 0.6.0 will start sending this message
    -- vim.notify_once(
    --   "alternative_next/previous are deprecated and will be removed in v1.0. "
    --     .. "Use movement.next/previous arrays instead.",
    --   vim.log.levels.WARN
    -- )
    table.insert(keys.next, vim.api.nvim_replace_termcodes(movement_config.alternative_next, true, true, true))
  end
  if movement_config.alternative_previous then
    table.insert(keys.previous, vim.api.nvim_replace_termcodes(movement_config.alternative_previous, true, true, true))
  end

  return keys
end

---Handle special key inputs
---@param key string The key that was pressed
---@param opts SelectaOptions Configuration options
---@return boolean was_handled Whether the key was handled
function StateManager:handle_special_key(key, opts)
  -- Handle basic navigation
  if key == SPECIAL_KEYS.LEFT then
    self:move_cursor(-1)
    return true
  elseif key == SPECIAL_KEYS.RIGHT then
    self:move_cursor(1)
    return true
  elseif key == SPECIAL_KEYS.BS then
    if self:backspace() then
      M.process_query(self, opts)
      return true
    end
  end
  return false
end

---Handle movement keys (up/down navigation)
---@param direction number Direction of movement (1 for down, -1 for up)
---@param opts SelectaOptions Configuration options
---@return boolean was_handled Whether the movement was handled
function StateManager:handle_movement(direction, opts)
  -- Early return if there are no items or initially hidden with empty query
  if #self.filtered_items == 0 or (opts.initially_hidden and #self:get_query_string() == 0) then
    return false
  end

  -- Make sure the window is still valid before attempting to get/set cursor
  if not vim.api.nvim_win_is_valid(self.win) then
    return false
  end

  local cursor = vim.api.nvim_win_get_cursor(self.win)
  local current_pos = cursor[1]
  local total_items = #self.filtered_items

  -- Simple cycling calculation
  local new_pos = current_pos + direction
  if new_pos < 1 then
    new_pos = total_items
  elseif new_pos > total_items then
    new_pos = 1
  end

  pcall(vim.api.nvim_win_set_cursor, self.win, { new_pos, 0 })
  update_current_highlight(self, opts, new_pos - 1) -- 0-indexed for extmarks

  if opts.on_move then
    opts.on_move(self.filtered_items[new_pos])
  end

  -- Mark that user has manually moved cursor
  self.cursor_moved = true
  self.initial_open = false

  return true
end

---Toggle selection of an item (compatibility layer)
---@param state SelectaState The state object
---@param item SelectaItem The item to toggle
---@param opts SelectaOptions Configuration options
---@return boolean Whether the selection was changed
local function toggle_selection(state, item, opts)
  -- Check if this is a StateManager instance
  if type(state) == "table" and state.toggle_selection then
    -- Use the state method directly
    return state:toggle_selection(item, opts)
  else
    -- Fallback for backward compatibility
    logger.debug("Using legacy toggle_selection - consider updating your code")

    if not opts.multiselect or not opts.multiselect.enabled then
      return false
    end

    local item_id = get_item_id(item)
    if state.selected[item_id] then
      state.selected[item_id] = nil
      state.selected_count = state.selected_count - 1
      return true
    else
      if opts.multiselect.max_items and state.selected_count >= opts.multiselect.max_items then
        return false
      end
      state.selected[item_id] = true
      state.selected_count = state.selected_count + 1
      return true
    end
  end
end

---Handle item selection toggle
---@param state SelectaState
---@param opts SelectaOptions
---@param direction number 1 for forward, -1 for backward
---@return boolean handled Whether the toggle was handled
local function handle_toggle(state, opts, direction)
  local cursor_pos = vim.api.nvim_win_get_cursor(state.win)[1]
  M.log(string.format("Toggle pressed - cursor_pos: %d, total items: %d", cursor_pos, #state.filtered_items))

  local current_item = state.filtered_items[cursor_pos]
  if current_item then
    M.log(string.format("Current item: %s", current_item.text))
    local was_toggled = state:toggle_selection(current_item, opts)
    M.log(string.format("Item toggled: %s", tostring(was_toggled)))

    -- Only move if toggle was successful
    if was_toggled then
      -- Update display first
      M.process_query(state, opts)

      -- Calculate next position with wrapping
      local next_pos
      if direction > 0 then
        next_pos = cursor_pos < #state.filtered_items and cursor_pos + 1 or 1
      else
        next_pos = cursor_pos > 1 and cursor_pos - 1 or #state.filtered_items
      end

      M.log(string.format("Moving to position: %d", next_pos))

      -- Set new cursor position
      pcall(vim.api.nvim_win_set_cursor, state.win, { next_pos, 0 })
      update_current_highlight(state, opts, next_pos - 1)

      -- Trigger move callback if exists
      if opts.on_move then
        local new_item = state.filtered_items[next_pos]
        if new_item then
          M.log(string.format("Triggering on_move with item: %s", new_item.text))
          opts.on_move(new_item)
        end
      end

      vim.cmd("redraw")
    end

    return true
  end

  M.log("No current item found at cursor position")
  return false
end

---Handle item unselection
---@param state SelectaState
---@param opts SelectaOptions
---@return boolean handled Whether the untoggle was handled
local function handle_untoggle(state, opts)
  local cursor_pos = vim.api.nvim_win_get_cursor(state.win)[1]
  M.log(string.format("Untoggle pressed - current cursor_pos: %d", cursor_pos))

  -- Find the previous selected item position
  local prev_selected_pos = nil
  for i = cursor_pos - 1, 1, -1 do
    local item = state.filtered_items[i]
    if item and state.selected[get_item_id(item)] then
      prev_selected_pos = i
      break
    end
  end

  -- If no selected item found before current position, wrap around to end
  if not prev_selected_pos then
    for i = #state.filtered_items, cursor_pos, -1 do
      local item = state.filtered_items[i]
      if item and state.selected[get_item_id(item)] then
        prev_selected_pos = i
        break
      end
    end
  end

  M.log(string.format("Previous selected item position: %s", prev_selected_pos or "none found"))

  if prev_selected_pos then
    local prev_item = state.filtered_items[prev_selected_pos]
    M.log(string.format("Moving to and unselecting item: %s at position %d", prev_item.text, prev_selected_pos))

    -- Move to the selected item
    pcall(vim.api.nvim_win_set_cursor, state.win, { prev_selected_pos, 0 })

    -- Unselect the item
    local item_id = get_item_id(prev_item)
    state.selected[item_id] = nil
    state.selected_count = state.selected_count - 1

    -- Update display
    M.process_query(state, opts)

    -- Ensure cursor stays at the correct position
    pcall(vim.api.nvim_win_set_cursor, state.win, { prev_selected_pos, 0 })
    update_current_highlight(state, opts, prev_selected_pos - 1)

    -- Trigger move callback if exists
    if opts.on_move then
      M.log(string.format("Triggering on_move with item: %s", prev_item.text))
      opts.on_move(prev_item)
    end

    vim.cmd("redraw")
    return true
  else
    M.log("No previously selected item found")
    return false
  end
end

-- Helper function to handle custom keymaps
local function handle_custom_keymaps(state, char_key, opts)
  if opts.custom_keymaps and type(opts.custom_keymaps) == "table" then
    for _, action in pairs(opts.custom_keymaps) do
      -- Check if action is properly formatted
      if action and action.keys then
        local keys = action.keys
        if type(keys) == "string" then
          keys = { keys } -- Convert to table if it's a single string
        end
        if type(keys) == "table" then
          for _, key in ipairs(keys) do
            if type(key) == "string" and char_key == vim.api.nvim_replace_termcodes(key, true, true, true) then
              local selected = state.filtered_items[vim.api.nvim_win_get_cursor(state.win)[1]]
              if selected and action.handler then
                if opts.multiselect and opts.multiselect.enabled and state.selected_count > 0 then
                  -- Handle multiselect case
                  local selected_items = state:get_selected_items()
                  local should_close = action.handler(selected_items, state)
                  if should_close == false then
                    M.close_picker(state)
                    return true
                  end
                else
                  -- Handle single item case
                  local should_close = action.handler(selected, state)
                  if should_close == false then
                    M.close_picker(state)
                    return true
                  end
                end
              end
              return true
            end
          end
        end
      end
    end
  end
  return false
end

-- Helper function to handle multiselect keymaps
local function handle_multiselect_keymaps(state, char_key, opts)
  if opts.multiselect and opts.multiselect.enabled then
    local multiselect_keys = opts.multiselect.keymaps or M.config.multiselect.keymaps
    if char_key == vim.api.nvim_replace_termcodes(multiselect_keys.toggle, true, true, true) then
      if handle_toggle(state, opts, 1) then
        return true
      end
    elseif char_key == vim.api.nvim_replace_termcodes(multiselect_keys.untoggle, true, true, true) then
      if handle_untoggle(state, opts) then
        return true
      end
    elseif char_key == vim.api.nvim_replace_termcodes(multiselect_keys.select_all, true, true, true) then
      bulk_selection(state, opts, true)
      M.process_query(state, opts)
      return true
    elseif char_key == vim.api.nvim_replace_termcodes(multiselect_keys.clear_all, true, true, true) then
      bulk_selection(state, opts, false)
      M.process_query(state, opts)
      return true
    end
  end
  return false
end

-- Helper function to handle selection
local function handle_selection(state, opts)
  if opts.multiselect and opts.multiselect.enabled then
    local selected_items = state:get_selected_items()
    if #selected_items > 0 and opts.multiselect.on_select then
      opts.multiselect.on_select(selected_items)
    elseif #selected_items == 0 then
      local current = state.filtered_items[vim.api.nvim_win_get_cursor(state.win)[1]]
      if current and opts.on_select then
        opts.on_select(current)
      end
    end
  else
    local selected = state.filtered_items[vim.api.nvim_win_get_cursor(state.win)[1]]
    if selected and opts.on_select then
      opts.on_select(selected)
    end
  end
end

---Handle character input in the picker
---@param state SelectaState The current state of the picker
---@param char string|number The character input
---@param opts SelectaOptions The options for the picker
---@return nil
local function handle_char(state, char, opts)
  if not state.active then
    return nil
  end

  local char_key = type(char) == "number" and vim.fn.nr2char(char) or char
  local movement_keys = get_movement_keys(opts)

  -- Handle custom keymaps first
  if handle_custom_keymaps(state, char_key, opts) then
    return nil
  end

  -- Handle multiselect keymaps
  if handle_multiselect_keymaps(state, char_key, opts) then
    return nil
  end

  -- Handle special keys using StateManager methods when possible
  if
    state.handle_special_key
    and (char_key == SPECIAL_KEYS.LEFT or char_key == SPECIAL_KEYS.RIGHT or char_key == SPECIAL_KEYS.BS)
  then
    state:handle_special_key(char_key, opts)
    M.process_query(state, opts) -- Make sure this happens after all key handling
    return nil
  end

  -- Handle movement keys
  if vim.tbl_contains(movement_keys.previous, char_key) then
    if state.handle_movement then
      state:handle_movement(-1, opts)
    else
      state.cursor_moved = true
      state.initial_open = false
      handle_movement(state, -1, opts)
    end
    return nil
  elseif vim.tbl_contains(movement_keys.next, char_key) then
    if state.handle_movement then
      state:handle_movement(1, opts)
    else
      state.cursor_moved = true
      state.initial_open = false
      handle_movement(state, 1, opts)
    end
    return nil
  elseif vim.tbl_contains(movement_keys.close, char_key) then
    if opts.on_cancel then
      opts.on_cancel()
    end
    M.close_picker(state)
    return nil
  elseif vim.tbl_contains(movement_keys.select, char_key) then
    handle_selection(state, opts)
    M.close_picker(state)
    return nil
  elseif vim.tbl_contains(movement_keys.delete_word, char_key) then
    if state.delete_word then
      if state:delete_word() then
        M.process_query(state, opts)
      end
    else
      delete_last_word(state)
      M.process_query(state, opts)
    end
    return nil
  elseif vim.tbl_contains(movement_keys.clear_line, char_key) then
    if state.clear_query then
      state:clear_query()
    else
      state.query = {}
      state.cursor_pos = 1
      state.initial_open = false
      state.cursor_moved = false
    end
    M.process_query(state, opts)
    return nil
  elseif char_key == SPECIAL_KEYS.MOUSE and vim.v.mouse_win ~= state.win and vim.v.mouse_win ~= state.prompt_win then
    if opts.on_cancel then
      opts.on_cancel()
    end
    M.close_picker(state)
    return nil
  elseif char_key == SPECIAL_KEYS.LEFT and not state.handle_special_key then
    state:move_cursor(-1)
  elseif char_key == SPECIAL_KEYS.RIGHT and not state.handle_special_key then
    state:move_cursor(1)
  elseif char_key == SPECIAL_KEYS.BS and not state.handle_special_key then
    if state:backspace() then
      M.process_query(state, opts)
    end
  else
    -- Handle regular character input
    if state:update_query(char) then
      M.process_query(state, opts)
    end
  end

  return nil
end

---Create the picker windows
---@param state SelectaState
---@param opts SelectaOptions
local function create_windows(state, opts)
  -- Handle initially_hidden option
  if opts.initially_hidden then
    -- When initially hidden, set minimal dimensions
    state.filtered_items = {}
    state.width = opts.window.min_width or M.config.window.min_width
    state.height = opts.window.min_height or M.config.window.min_height
  end

  -- Create main window
  local win_config = vim.tbl_deep_extend("force", {
    relative = opts.window.relative or M.config.window.relative,
    row = state.row + 1, -- Shift main window down by 1 to make room for prompt
    col = state.col,
    width = state.width,
    height = state.height,
    style = "minimal",
    border = get_border_with_footer(opts),
  }, opts.window.override or {})

  -- Set footer if needed
  if opts.window.show_footer then
    win_config.footer = {
      { string.format(" %d/%d ", #state.filtered_items, #state.items), "NamuFooter" },
    }
    win_config.footer_pos = opts.window.footer_pos or "right"
  end

  -- Create windows and setup
  state.win = vim.api.nvim_open_win(state.buf, true, win_config)

  -- Call window create hook
  if opts.hooks and opts.hooks.on_window_create then
    opts.hooks.on_window_create(state.win, state.buf, opts)
  end

  -- Create prompt window
  create_prompt_window(state, opts)
  update_prompt_info(state, opts, true)

  -- Configure window options
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].cursorlineopt = "both"
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.buf })

  -- Handle initially_hidden option post-creation
  if opts.initially_hidden then
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
  end

  -- Handle initial cursor position if specified
  if opts.initial_index and opts.initial_index <= #state.items then
    local target_pos = math.min(opts.initial_index, #state.filtered_items)
    if target_pos > 0 then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(state.win) then
          -- Set cursor position
          pcall(vim.api.nvim_win_set_cursor, state.win, { target_pos, 0 })
          -- Force redraw to update highlight
          vim.cmd("redraw")
          -- Ensure cursorline is enabled and visible
          vim.wo[state.win].cursorline = true
          -- Trigger a manual cursor move to ensure everything is updated
          if opts.on_move then
            opts.on_move(state.filtered_items[target_pos])
          end
        end
      end)
    end
  end
end

---Pick an item from the list with cursor management
---@param items SelectaItem[]
---@param opts? SelectaOptions
---@return SelectaItem|nil
function M.pick(items, opts)
  opts = opts or {}
  logger.log("Picking item - first thing")
  -- Merge options with defaults
  opts = vim.tbl_deep_extend("force", {
    title = "Select",
    display = vim.tbl_deep_extend("force", M.config.display, {}),
    filter = function(item, query)
      return query == "" or string.find(string.lower(item.text), string.lower(query))
    end,
    fuzzy = false,
    offnet = 0,
    custom_keymaps = opts.custom_keymaps,
    movement = vim.tbl_deep_extend("force", M.config.movement, {}),
    current_highlight = opts.current_highlight,
    auto_select = M.config.auto_select,
    window = vim.tbl_deep_extend("force", M.config.window, {}),
    pre_filter = nil,
    row_position = M.config.row_position,
    debug = M.config.debug,
  }, opts or {})

  -- Calculate max_prefix_width before creating formatter
  local max_prefix_width = calculate_max_prefix_width(items, opts.display.mode)
  opts.display.prefix_width = max_prefix_width

  -- Set up formatter
  opts.formatter = opts.formatter
    or function(item)
      local prefix_padding = ""
      if opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
        prefix_padding = string.rep(" ", vim.api.nvim_strwidth(opts.current_highlight.prefix_icon))
      end
      if opts.display.mode == "raw" then
        return prefix_padding .. item.text
      elseif opts.display.mode == "icon" then
        local icon = item.icon or "  "
        return prefix_padding .. icon .. string.rep(" ", opts.display.padding or 1) .. item.text
      else
        local prefix_info = get_prefix_info(item, opts.display.prefix_width)
        local padding = string.rep(" ", prefix_info.padding)
        return prefix_padding .. prefix_info.text .. padding .. item.text
      end
    end

  local state = StateManager.new(items, opts)
  -- Create the UI
  create_windows(state, opts)
  M.process_query(state, opts)
  vim.cmd("redraw")
  cursor_manager.hide()

  -- Handle initial cursor position
  if opts.initial_index and opts.initial_index <= #items then
    local target_pos = math.min(opts.initial_index, #state.filtered_items)
    if target_pos > 0 then
      vim.api.nvim_win_set_cursor(state.win, { target_pos, 0 })
      update_current_highlight(state, opts, target_pos - 1)
      if opts.on_move then
        opts.on_move(state.filtered_items[target_pos])
      end
    end
  end

  -- Main input loop
  local ok, result = pcall(function()
    while state.active do
      local char = vim.fn.getchar()
      local result = handle_char(state, char, opts)
      if result ~= nil then
        return result
      end
      vim.cmd("redraw")
    end
  end)

  vim.schedule(function()
    cursor_manager.restore()
  end)
  if state and state.active then
    state:cleanup()
  end

  -- Ensure cursor is restored even if there was an error
  if not ok then
    error(result)
  end

  return result
end

M._test = {
  get_match_positions = matcher.get_match_positions,
  is_word_boundary = matcher.is_word_boundary,
  update_filtered_items = M.update_filtered_items,
  calculate_window_size = M.calculate_window_size,
  validate_input = matcher.validate_input,
  apply_highlights = apply_highlights,
  get_window_position = M.get_window_position,
  parse_position = parse_position,
}

---@param opts? table
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  logger.setup(opts)
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
  local target_bufnr = item.value.bufnr or item.bufnr -- fallback hierarchy: buffer_symbols -> item bufnr -> original buf
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

return M
