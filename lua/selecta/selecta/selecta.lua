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

---@class SelectaItem
---@field text string Display text
---@field value any Actual value to return
---@field icon? string Optional icon
---@field hl_group? string Optional highlight group for the icon/text

---@class SelectaKeymap
---@field key string The key sequence
---@field handler fun(item: SelectaItem, state: SelectaState, close_fn: fun(state: SelectaState)): boolean? The handler function
---@field desc? string Optional description of what the keymap does
---@field children? LSPSymbol[] Child symbols
---@class SelectaWindowConfig
---@field relative? string
---@field border? string|table
---@field style? string
---@field title_prefix? string
---@field width_ratio? number
---@field height_ratio? number
---@field auto_size? boolean
---@field min_width? number
---@field max_width? number
---@field max_height? number
---@field min_height? number
---@field padding? number
---@field override? table

---@class SelectaOptions
---@field title? string
---@field formatter? fun(item: SelectaItem): string
---@field on_render? fun(buf: number, items: SelectaItem[], opts: table) Function called after rendering items
---@field filter? fun(item: SelectaItem, query: string): boolean
---@field sorter? fun(items: SelectaItem[], query: string): SelectaItem[]
---@field on_select? fun(item: SelectaItem)
---@field on_cancel? fun()
---@field on_move? fun(item: SelectaItem)
---@field fuzzy? boolean
---@field window? SelectaWindowConfig
---@field preserve_order? boolean -- Whether to preserve original item order
---@field keymaps? SelectaKeymap[] List of custom keymaps
---@field auto_select? boolean -- Whether to auto-select when only one match remains
---@field row_position? "center"|"top10" -- Row position preset
---@field multiselect? SelectaMultiselect Configuration for multiselect feature
---@field display? SelectaDisplay Configuration for display
---@field offset number Offset of the picker

---@class SelectaHooks
---@field on_render? fun(buf: number, items: SelectaItem[], opts: SelectaOptions) Called after items are rendered
---@field on_window_create? fun(win_id: number, buf_id: number, opts: SelectaOptions) Called after window creation
---@field before_render? fun(items: SelectaItem[], opts: SelectaOptions) Called before rendering items

-- Add new class definition after SelectaOptions
---@class SelectaMultiselect
---@field enabled boolean Whether multiselect is enabled
---@field indicator string Character to show for selected items
---@field on_select fun(items: SelectaItem[]) Callback for multiselect completion
---@field max_items? number Maximum number of items that can be selected
---@field keymaps? table<string, string> Custom keymaps for multiselect operations

---@class SelectaDisplay
---@field mode? "icon"|"text"|"raw" -- Mode of display
---@field padding? number -- Padding after prefix
---@field prefix_width? number -- Fixed width for prefixes

---@class MatchResult
---@field positions number[][] Match positions
---@field score number Priority score (higher is better)
---@field type string "prefix"|"contains"|"fuzzy"
---@field matched_chars number Number of matched characters
---@field gaps number Number of gaps in fuzzy match

---@class CursorCache
---@field guicursor string|nil The cached guicursor value

-- Default configuration
-- Default configuration
M.config = {
  window = {
    relative = "editor",
    border = "none",
    style = "minimal",
    title_prefix = "> ",
    width_ratio = 0.6,
    height_ratio = 0.6,
    auto_size = false, -- Default to fixed size
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
  offset = 0,
  debug = false, -- Debug logging flag
  preserve_order = false, -- Default to false unless the other module handle it
  keymaps = {},
  auto_select = false,
  row_position = "center", -- options: "center"|"top10",
  multiselect = {
    enabled = false,
    indicator = "●", -- or "✓"
    keymaps = {
      toggle = "<Tab>",
      select_all = "<C-a>",
      clear_all = "<C-l>",
      untoggle = "<S-Tab>",
    },
    max_items = nil, -- No limit by default
  },
}

---@type CursorCache
local cursor_cache = {
  guicursor = nil,
}

-- Scoring constants (now properly localized)
local MATCH_SCORES = {
  prefix = 100, -- Starts with the query
  contains = 60, -- Contains the query somewhere
  fuzzy = 25, -- Fuzzy match
}

local SCORE_ADJUSTMENTS = {
  gap_penalty = -3, -- Penalty for each gap in fuzzy match
  consecutive_bonus = 7, -- Bonus for consecutive matches
  start_bonus = 9, -- Bonus for matching at word start
  word_boundary_bonus = 20, -- Bonus for matching at word boundaries
  position_weight = 0.5, -- 0.5 points per position closer to start
  length_weight = 1.5, -- 1.5 points per character shorter
  max_gap_penalty = -20, -- Cap on total gap penalty
  exact_match_bonus = 25, -- bonus for exact substring matches
}

-- At module level
local ns_id = vim.api.nvim_create_namespace("selecta_highlights")

---Thanks to folke and mini.nvim for this utlity of hiding the cursor
---Hide the cursor by setting guicursor and caching the original value
---@return nil
local function hide_cursor()
  cursor_cache.guicursor = vim.o.guicursor
  vim.o.guicursor = "a:SelectaCursor"
end

---Restore the cursor to its original state
---@return nil
local function restore_cursor()
  -- Handle edge case where guicursor was empty
  if cursor_cache.guicursor == "" then
    vim.o.guicursor = "a:"
    cursor_cache.guicursor = nil -- Prevent second block from executing
    vim.cmd("redraw")
    return
  end

  -- Restore original guicursor
  if cursor_cache.guicursor then
    vim.o.guicursor = cursor_cache.guicursor
    cursor_cache.guicursor = nil
  end
end

---TODO: add it later to the config
local highlights = {
  SelectaPrefix = {
    fg = "#89b4fa",
    bold = true,
  },
  SelectaMatch = {
    fg = "#89dceb",
    bold = true,
  },
  SelectaCursor = {
    blend = 100,
    nocombine = true,
  },
  SelectaPrompt = {
    link = "FloatTitle",
  },
  SelectaSelected = {
    fg = "#b5581a",
    bold = true,
  },
  SelectaFooter = {
    fg = "#6c7086",
    italic = true,
  },
}

---Set up the highlight groups
---@return nil
local function setup_highlights()
  for group, opts in pairs(highlights) do
    vim.api.nvim_set_hl(0, group, opts)
  end
end

-- Input validation functions
---@param text string
---@param query string
---@return boolean, string?
local function validate_input(text, query)
  if type(text) ~= "string" then
    return false, "text must be a string"
  end
  if type(query) ~= "string" then
    return false, "query must be a string"
  end
  if #text == 0 then
    return false, "text cannot be empty"
  end
  if #query == 0 then
    return false, "query cannot be empty"
  end
  return true
end

---@param message string
---@return nil
function M.log(message)
  if not M.config.debug then
    return
  end
  local log_file = vim.fn.stdpath("data") .. "/selecta.log"

  -- Create a temporary file handle
  local tmp_file = io.open(log_file, "a")
  if tmp_file then
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    tmp_file:write(string.format("\n[%s] [%s] %s", timestamp, message))
    tmp_file:close()

    -- Schedule file writing
    vim.schedule(function()
      local lines = vim.fn.readfile(log_file)
      if #lines > 1000 then
        vim.fn.writefile(vim.list_slice(lines, -1000), log_file)
      end
    end)
  end
end

---@class PrefixInfo
---@field text string The prefix text (icon or kind text)
---@field width number Total width including padding
---@field raw_width number Width without padding
---@field padding number Padding after prefix
---@field hl_group string Highlight group to use
local function get_prefix_info(item, max_prefix_width)
  local prefix_text = item.kind or ""
  local raw_width = vim.api.nvim_strwidth(prefix_text)
  -- Use max_prefix_width for alignment in text mode
  return {
    text = prefix_text,
    width = max_prefix_width + 1, -- Add padding
    raw_width = raw_width,
    padding = max_prefix_width - raw_width + 1,
    hl_group = item.hl_group or "SelectaPrefix", -- Use item's highlight group or default
  }
end

---@param items SelectaItem[]
---@param opts SelectaOptions
---@param formatter fun(item: SelectaItem): string
local function calculate_window_size(items, opts, formatter)
  local max_width = opts.window.max_width or M.config.window.max_width
  local min_width = opts.window.min_width or M.config.window.min_width
  local max_height = opts.window.max_height or M.config.window.max_height
  local min_height = opts.window.min_height or M.config.window.min_height
  local padding = opts.window.padding or M.config.window.padding

  -- Calculate content width
  local content_width = min_width
  if opts.window.auto_size then
    for _, item in ipairs(items) do
      local line = formatter(item)
      local width = vim.api.nvim_strwidth(line)
      content_width = math.max(content_width, width)
    end
    content_width = content_width + padding
    content_width = math.min(math.max(content_width, min_width), max_width)
  else
    -- Use ratio-based width
    content_width = math.floor(vim.o.columns * (opts.window.width_ratio or M.config.window.width_ratio))
  end

  -- Calculate height based on number of items
  local max_available_height = vim.o.lines - vim.o.cmdheight - 4 -- Leave some space for status line
  local content_height = #items

  -- Constrain height between min and max values
  content_height = math.min(content_height, max_height)
  content_height = math.min(content_height, max_available_height)
  content_height = math.max(content_height, min_height)

  return content_width, content_height
end

---@param text string
---@param query string
---@return number[][]|nil positions, number score, number gaps
local function find_fuzzy_match(text, query)
  -- Validate input
  local is_valid, error_msg = validate_input(text, query)
  if not is_valid then
    M.async_log("Fuzzy match error: " .. error_msg)
    return nil, 0, 0
  end
  if #query > 3 then -- Only log for longer queries to reduce noise
    M.async_log(string.format("Fuzzy: '%s' → '%s'", text, query))
  end

  -- Initialize variables
  local positions = {}
  local last_match_pos = nil
  local current_range = nil
  local score = MATCH_SCORES.fuzzy
  local gaps = 0

  local lower_text = text:lower()
  local lower_query = query:lower()

  local text_pos = 1
  local query_pos = 1

  while query_pos <= #query and text_pos <= #text do
    local query_char = lower_query:sub(query_pos, query_pos)
    local text_char = lower_text:sub(text_pos, text_pos)

    if text_char == query_char then
      -- If this is consecutive with last match
      if last_match_pos and text_pos == last_match_pos + 1 then
        score = score + SCORE_ADJUSTMENTS.consecutive_bonus
        if current_range then
          current_range[2] = text_pos
        else
          current_range = { text_pos, text_pos }
        end
      else
        if last_match_pos then
          gaps = gaps + (text_pos - last_match_pos - 1)
          score = score + SCORE_ADJUSTMENTS.gap_penalty
          if current_range then
            table.insert(positions, current_range)
          end
        end
        current_range = { text_pos, text_pos }
      end

      -- Bonus for matching at word boundary
      if text_pos == 1 or text:sub(text_pos - 1, text_pos - 1):match("[^%w]") then
        score = score + SCORE_ADJUSTMENTS.start_bonus
      end

      last_match_pos = text_pos
      query_pos = query_pos + 1
    end
    text_pos = text_pos + 1
  end

  -- Add final range if exists
  if current_range then
    table.insert(positions, current_range)
  end

  -- Return nil if we didn't match all characters
  if query_pos <= #query then
    return nil, 0, 0
  end

  return positions, score, gaps
end

local function is_word_boundary(text, pos)
  -- Start of string is always a boundary
  if pos == 1 then
    return true
  end

  local prev_char = text:sub(pos - 1, pos - 1)
  local curr_char = text:sub(pos, pos)

  -- Check for traditional word boundaries (spaces, underscores, etc.)
  if prev_char:match("[^%w]") ~= nil or prev_char == "_" then
    return true
  end

  -- Check for camelCase and PascalCase boundaries
  -- Current char is uppercase and previous char is lowercase
  if curr_char:match("[A-Z]") and prev_char:match("[a-z]") then
    return true
  end

  return false
end

---@param text string The text to search in
---@param query string The query to search for
---@return MatchResult|nil
local function get_match_positions(text, query)
  -- Work with raw text, no formatting adjustments here
  if query == "" then
    return nil
  end

  -- Check for prefix match
  if text:lower():sub(1, #query) == query:lower() then
    return {
      positions = { { 1, #query } }, -- Raw positions in the text
      score = MATCH_SCORES.prefix,
      type = "prefix",
      matched_chars = #query,
      gaps = 0,
    }
  end

  -- Enhanced substring match with word boundary detection
  local function find_best_substring_match()
    local best_start = nil
    local best_score = -1
    local curr_pos = 1

    while true do
      local start_idx
      if has_uppercase then
        start_idx = text:find(query, curr_pos, true) -- Case-sensitive
      else
        start_idx = text:lower():find(query:lower(), curr_pos, true) -- Case-insensitive
      end

      if not start_idx then
        break
      end

      -- Calculate score for this match position
      local curr_score = MATCH_SCORES.contains

      -- Add exact match bonus
      if #query > 1 then -- Only for queries longer than 1 char
        curr_score = curr_score + SCORE_ADJUSTMENTS.exact_match_bonus
      end

      -- Add word boundary bonus with improved detection
      if is_word_boundary(text, start_idx) then
        curr_score = curr_score + SCORE_ADJUSTMENTS.word_boundary_bonus
        -- Extra bonus if it matches at a word after a separator
        if start_idx > 1 and text:sub(start_idx - 1, start_idx - 1):match("[:/_%-%.]") then
          curr_score = curr_score + SCORE_ADJUSTMENTS.word_boundary_bonus * 0.5
        end
      end

      -- Position bonus relative to start
      curr_score = curr_score + (1 / start_idx) * SCORE_ADJUSTMENTS.position_weight * 100

      if curr_score > best_score then
        best_score = curr_score
        best_start = start_idx
      end

      curr_pos = start_idx + 1
    end

    return best_start, best_score
  end

  -- Find best substring match
  local start_idx, substring_score = find_best_substring_match()
  if start_idx then
    position_bonus = (1 / start_idx) * SCORE_ADJUSTMENTS.position_weight * 100 -- Recalculate for non-prefix position

    return {
      positions = { { start_idx, start_idx + #query - 1 } },
      score = substring_score + position_bonus + length_bonus,
      type = "contains",
      matched_chars = #query,
      gaps = 0,
    }
  end

  -- Fuzzy match
  local fuzzy_positions, fuzzy_score, fuzzy_gaps = M.find_fuzzy_match(text, query, has_uppercase)
  if fuzzy_positions then
    -- Get position of first match from fuzzy_positions
    local first_match_pos = fuzzy_positions[1][1]
    position_bonus = (1 / first_match_pos) * SCORE_ADJUSTMENTS.position_weight * 100
    length_bonus = (1 / #text) * SCORE_ADJUSTMENTS.length_weight * 100

    return {
      positions = fuzzy_positions,
      score = fuzzy_score + position_bonus + length_bonus,
      type = "fuzzy",
      matched_chars = #query,
      gaps = fuzzy_gaps,
    }
  end

  return nil
end

---sorter function
---@param items SelectaItem[]
---@param query string
local function sort_items(items, query)
  -- Store match results for each item
  local item_matches = {}

  -- Get match results for all items
  for _, item in ipairs(items) do
    local match = get_match_positions(item.text, query)
    if match then
      table.insert(item_matches, {
        item = item,
        match = match,
      })
    end
  end

  -- Sort based on match score and additional factors
  table.sort(item_matches, function(a, b)
    -- First compare by match type/score
    if a.match.score ~= b.match.score then
      return a.match.score > b.match.score
    end

    -- Then by number of gaps (fewer is better)
    if a.match.gaps ~= b.match.gaps then
      return a.match.gaps < b.match.gaps
    end

    -- Finally by text length (shorter is better)
    return #a.item.text < #b.item.text
  end)

  -- Extract sorted items
  local sorted_items = {}
  for _, match in ipairs(item_matches) do
    table.insert(sorted_items, match.item)
  end

  return sorted_items
end

local function calculate_max_prefix_width(items, display_mode)
  if display_mode == "icon" then
    return 2 -- Fixed width for icons
  end

  local max_width = 0
  for _, item in ipairs(items) do
    local prefix_text = item.kind or ""
    max_width = math.max(max_width, vim.api.nvim_strwidth(prefix_text))
  end
  return max_width
end

---@param state SelectaState
---@param opts SelectaOptions
local function update_prompt(state, opts)
  local before_cursor = table.concat(vim.list_slice(state.query, 1, state.cursor_pos - 1))
  local after_cursor = table.concat(vim.list_slice(state.query, state.cursor_pos))
  local prompt_text = opts.window.title_prefix .. before_cursor .. "│" .. after_cursor

  if vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_set_config, state.win, {
      title = { { prompt_text, "SelectaPrompt" } },
    })
  end
end

---@param state SelectaState
---@param query string
---@param opts SelectaOptions
function M.update_filtered_items(state, query, opts)
  if query ~= "" then
    state.filtered_items = {}
    for _, item in ipairs(state.items) do
      local match = M.get_match_positions(item.text, query)
      if match then
        table.insert(state.filtered_items, item)
      end
    end
    local best_index
    state.filtered_items, best_index = M.sort_items(state.filtered_items, query, opts.preserve_order)
    -- Store best match index for cursor positioning
    state.best_match_index = best_index

    -- Handle auto-select here
    if opts.auto_select and #state.filtered_items == 1 and not state.initial_open then
      local selected = state.filtered_items[1]
      if selected and opts.on_select then
        opts.on_select(selected) -- Call directly without scheduling
        M.close_picker(state)
      end
    end
  else
    state.filtered_items = state.items
    state.best_match_index = nil
  end
end

---Generate a unique ID for an item
---@param item SelectaItem
---@return string
local function get_item_id(item)
  return tostring(item.value or item.text)
end

---@param buf number
---@param line_nr number
---@param item SelectaItem
---@param opts SelectaOptions
---@param query string
local function apply_highlights(buf, line_nr, item, opts, query, line_length, state)
  -- Get the formatted display string
  local display_str = opts.formatter(item)
  if opts.display.mode == "raw" then
    local offset = opts.offset and opts.offset(item) or 0
    if query ~= "" then
      local match = M.get_match_positions(item.text, query)
      if match then
        for _, pos in ipairs(match.positions) do
          local start_col = offset + pos[1] - 1
          local end_col = offset + pos[2]

          -- Ensure we don't exceed line length
          end_col = math.min(end_col, line_length)

          if end_col > start_col then
            vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, start_col, {
              end_col = end_col,
              hl_group = "SelectaMatch",
              priority = 200,
              hl_mode = "combine",
            })
          end
        end
      end
    end
  else
    -- Find the actual icon boundary by looking for the padding
    local _, icon_end = display_str:find("^[^%s]+%s+")
    if not icon_end then
      icon_end = 2 -- fallback if pattern not found
    end

    -- Highlight prefix/icon
    vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, 0, {
      end_col = icon_end,
      hl_group = get_prefix_info(item, opts.display.prefix_width).hl_group,
      priority = 100,
      hl_mode = "combine",
    })

    -- Debug log
    M.log(
      string.format(
        "Highlighting item: %s\nFull display: '%s'\nIcon boundary: %d\nQuery: '%s'",
        item.text,
        display_str,
        icon_end,
        query
      )
    )
    -- Calculate base offset for query highlights (icon + space)
    local base_offset = item.icon and (vim.api.nvim_strwidth(item.icon) + 1) or 0

    -- Highlight matches in the text
    if query ~= "" then
      local match = M.get_match_positions(item.text, query)
      if match then
        for _, pos in ipairs(match.positions) do
          local start_col = icon_end + pos[1] - 1
          local end_col = icon_end + pos[2]
          -- BUG: after magnet update, end_col sometimes out of range when typing specific char like
          -- "m" in the python file so this is temp solution.
          if opts.display.mode == "text" then
            end_col = math.min(end_col, line_length)
          end

          -- Debug log
          M.log(string.format("Match position: [%d, %d]\nFinal position: [%d, %d]", pos[1], pos[2], start_col, end_col))

          if end_col > start_col then
            vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, start_col, {
              end_col = end_col,
              hl_group = "SelectaMatch",
              priority = 200,
              hl_mode = "combine",
            })
          end
        end
      end
    end
  end

  local indicator = opts.display.mode == "text" and "• " or "●"
  -- Add selection indicator if item is selected
  if opts.multiselect and opts.multiselect.enabled then
    local item_id = get_item_id(item)
    if state.selected[item_id] then
      vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, 0, {
        virt_text = { { indicator, "SelectaSelected" } },
        virt_text_pos = "inline",
        priority = 300,
      })
    end
  end
end

---@param state SelectaState
---@param opts SelectaOptions
local function update_cursor_position(state, opts)
  if #state.filtered_items > 0 then
    local cur_pos = vim.api.nvim_win_get_cursor(state.win)
    if cur_pos[1] > #state.filtered_items then
      cur_pos = { 1, 0 }
    end
    vim.api.nvim_win_set_cursor(state.win, cur_pos)

    -- Only trigger on_move if not in initial state
    if opts.on_move and not state.initial_open then
      opts.on_move(state.filtered_items[cur_pos[1]])
    end
  end
end

---@param state SelectaState
---@param opts SelectaOptions
local function resize_window(state, opts)
  if not (state.active and vim.api.nvim_win_is_valid(state.win)) then
    return
  end

  -- Calculate new dimensions based on filtered items
  local new_width, new_height = calculate_window_size(state.filtered_items, opts, opts.formatter)

  -- Get current window config
  local current_config = vim.api.nvim_win_get_config(state.win)

  -- Keep the same row (top position) from the current config
  local win_config = {
    relative = current_config.relative,
    row = current_config.row, -- Keep the same top position
    col = current_config.col, -- Keep the same left position
    width = new_width,
    height = new_height,
    style = current_config.style,
    border = opts.window.border or M.config.window.border,
  }

  vim.api.nvim_win_set_config(state.win, win_config)
end

-- Main update_display function using the split functions
---@param state SelectaState
---@param opts SelectaOptions
local function update_display(state, opts)
  if not state.active then
    return
  end

  local query = table.concat(state.query)
  update_prompt(state, opts)
  update_filtered_items(state, query)

  -- Resize window if auto_resize is enabled
  if opts.window.auto_resize then
    resize_window(state, opts)
  end

  -- Update buffer content
  if vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, ns_id, 0, -1)

    local lines = {}
    for i, item in ipairs(state.filtered_items) do
      lines[i] = opts.formatter(item)
    end

    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

    -- Apply highlights
    for i, item in ipairs(state.filtered_items) do
      local line_nr = i - 1
      local line = lines[i]
      local line_length = vim.api.nvim_strwidth(line)
      apply_highlights(state.buf, line_nr, item, opts, query, line_length)
    end

    update_cursor_position(state, opts)
  end
end

---Close the picker and restore cursor
---@param state SelectaState
---@return nil
local function close_picker(state)
  if state.active and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_buf_clear_namespace(state.buf, ns_id, 0, -1)
    vim.api.nvim_win_close(state.win, true)
    state.active = false
    -- Restore cursor after closing window
    restore_cursor()
  end
end

---@param items SelectaItem[]
---@param opts SelectaOptions
local function create_picker(items, opts)
  local state = {
    buf = vim.api.nvim_create_buf(false, true),
    query = {},
    cursor_pos = 1,
    items = items,
    filtered_items = items,
    active = true,
    initial_open = true,
  }

  local width, height = calculate_window_size(items, opts, opts.formatter)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win_config = vim.tbl_deep_extend("force", {
    relative = opts.window.relative or M.config.window.relative,
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = opts.window.border or M.config.window.border,
    title = {
      { opts.window.title_prefix or M.config.window.title_prefix, "SelectaPrompt" },
    },
  }, opts.window.override or {})

  -- Hide cursor before creating window
  hide_cursor()
  state.win = vim.api.nvim_open_win(state.buf, true, win_config)

  vim.api.nvim_buf_set_option(state.buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(state.buf, "buftype", "nofile")
  vim.wo[state.win].cursorline = true

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

-- Simplified movement handler
local function handle_movement(state, direction, opts)
  -- Don't attempt movement if there are no items
  if #state.filtered_items == 0 then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local current_pos = cursor[1]
  local total_items = #state.filtered_items

  -- Simple cycling calculation
  local new_pos = current_pos + direction
  if new_pos < 1 then
    new_pos = total_items
  elseif new_pos > total_items then
    new_pos = 1
  end

  vim.api.nvim_win_set_cursor(state.win, { new_pos, 0 })

  if opts.on_move then
    opts.on_move(state.filtered_items[new_pos])
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

  if opts.keymaps then
    for _, keymap in ipairs(opts.keymaps) do
      if char_key == vim.api.nvim_replace_termcodes(keymap.key, true, true, true) then
        local selected = state.filtered_items[vim.api.nvim_win_get_cursor(state.win)[1]]
        if selected then
          -- Check for multiselect state
          if opts.multiselect and opts.multiselect.enabled and state.selected_count > 0 then
            -- Collect selected items
            local selected_items = {}
            for _, item in ipairs(state.filtered_items) do
              if state.selected[tostring(item.value or item.text)] then
                table.insert(selected_items, item)
              end
            end
            -- Pass all selected items to handler if there are any
            local should_close = keymap.handler(selected_items, state, M.close_picker)
            if should_close == false then
              M.close_picker(state)
              return nil
            end
          else
            -- Original single-item behavior
            local should_close = keymap.handler(selected, state, M.close_picker)
            if should_close == false then
              M.close_picker(state)
              return nil
            end
          end
        end
        return nil
      end
    end
  end

  if opts.multiselect and opts.multiselect.enabled then
    local multiselect_keys = opts.multiselect.keymaps or M.config.multiselect.keymaps

    -- Handle multiselect keymaps
    if char_key == vim.api.nvim_replace_termcodes(multiselect_keys.toggle, true, true, true) then
      local current_item = state.filtered_items[vim.api.nvim_win_get_cursor(state.win)[1]]
      if current_item then
        if toggle_selection(state, current_item, opts) then
          handle_movement(state, 1, opts) -- Move to next item after selection
          update_display(state, opts)
        end
      end
      return nil
    elseif char_key == vim.api.nvim_replace_termcodes(multiselect_keys.untoggle, true, true, true) then
      local current_item = state.filtered_items[vim.api.nvim_win_get_cursor(state.win)[1]]
      if current_item then
        local item_id = get_item_id(current_item)
        if state.selected[item_id] then
          state.selected[item_id] = nil
          state.selected_count = state.selected_count - 1
          handle_movement(state, -1, opts) -- Move to next item after unselection
          update_display(state, opts)
        end
      end
      return nil
    elseif char_key == vim.api.nvim_replace_termcodes(multiselect_keys.select_all, true, true, true) then
      bulk_selection(state, opts, true)
      update_display(state, opts)
      return nil
    elseif char_key == vim.api.nvim_replace_termcodes(multiselect_keys.clear_all, true, true, true) then
      bulk_selection(state, opts, false)
      update_display(state, opts)
      return nil
    end
  end
  -- Handle mouse clicks
  if char_key == SPECIAL_KEYS.MOUSE and vim.v.mouse_win ~= state.win and vim.v.mouse_win ~= state.prompt_win then
    if opts.on_cancel then
      opts.on_cancel()
    end
    M.close_picker(state)
    return nil
  end

  -- Movement keys lookup
  local movement = ({
    [SPECIAL_KEYS.UP] = -1,
    [SPECIAL_KEYS.CTRL_P] = -1,
    [SPECIAL_KEYS.S_TAB] = -1,
    [SPECIAL_KEYS.DOWN] = 1,
    [SPECIAL_KEYS.CTRL_N] = 1,
    -- [SPECIAL_KEYS.TAB] = 1,
  })[char_key]

  if movement then
    state.cursor_moved = true
    state.initial_open = false
    handle_movement(state, movement, opts)
  elseif char_key == SPECIAL_KEYS.LEFT then
    state.cursor_pos = math.max(1, state.cursor_pos - 1)
  elseif char_key == SPECIAL_KEYS.RIGHT then
    state.cursor_pos = math.min(#state.query + 1, state.cursor_pos + 1)
  elseif char_key == SPECIAL_KEYS.BS then
    if state.cursor_pos > 1 then
      table.remove(state.query, state.cursor_pos - 1)
      state.cursor_pos = state.cursor_pos - 1
      state.initial_open = false
      state.cursor_moved = false
    end
  elseif char_key == SPECIAL_KEYS.CR then
    if opts.multiselect and opts.multiselect.enabled then
      local selected_items = {}
      for _, item in ipairs(state.items) do
        if state.selected[get_item_id(item)] then
          table.insert(selected_items, item)
        end
      end
      if #selected_items > 0 and opts.multiselect.on_select then
        opts.multiselect.on_select(selected_items)
      elseif #selected_items == 0 then
        -- If no items selected, treat as single select
        local current = state.filtered_items[vim.api.nvim_win_get_cursor(state.win)[1]]
        if current and opts.on_select then
          opts.on_select(current)
        end
      end
    else
      -- Existing single-select behavior
      local selected = state.filtered_items[vim.api.nvim_win_get_cursor(state.win)[1]]
      if selected and opts.on_select then
        opts.on_select(selected)
      end
    end
    M.close_picker(state)
    return nil
  elseif char_key == SPECIAL_KEYS.ESC then
    if opts.on_cancel then
      opts.on_cancel()
    end
    M.close_picker(state)
    return nil
  elseif type(char) == "number" and char >= 32 and char <= 126 then
    table.insert(state.query, state.cursor_pos, vim.fn.nr2char(char))
    state.cursor_pos = state.cursor_pos + 1
    state.initial_open = false
    state.cursor_moved = false
  end

  update_display(state, opts)
  return nil
end

---Pick an item from the list with cursor management
---@param items SelectaItem[]
---@param opts? SelectaOptions
---@return SelectaItem|nil
function M.pick(items, opts)
  opts = vim.tbl_deep_extend("force", {
    title = "Select",
    display = vim.tbl_deep_extend("force", M.config.display, {}),
    filter = function(item, query)
      return query == "" or string.find(string.lower(item.text), string.lower(query))
    end,
    fuzzy = false,
    window = vim.tbl_deep_extend("force", M.config.window, {}),
  }, opts or {})

  -- Calculate max_prefix_width before creating formatter
  local max_prefix_width = calculate_max_prefix_width(items, opts.display.mode)
  opts.display.prefix_width = max_prefix_width

  -- Now create formatter with access to max_prefix_width
  opts.formatter = opts.formatter
    or function(item)
      if opts.display.mode == "icon" then
        local icon = item.icon or "  "
        return icon .. string.rep(" ", opts.display.padding or 1) .. item.text
      else
        local prefix_info = get_prefix_info(item, opts.display.prefix_width)
        local padding = string.rep(" ", prefix_info.padding)
        return prefix_info.text .. padding .. item.text
      end
    end

  setup_highlights()

  local state = create_picker(items, opts)
  update_display(state, opts)
  vim.cmd("redraw")

  local ok, result = pcall(function()
    while state.active do
      local ok, char = pcall(vim.fn.getchar)
      if not ok then
        close_picker(state)
        return nil
      end

      char = type(char) == "number" and vim.fn.nr2char(char) or char
      local result = handle_char(state, char, opts)
      if result ~= nil then
        return result
      end

      vim.cmd("redraw")
    end
  end)

  -- Ensure cursor is restored even if there was an error
  if not ok then
    restore_cursor()
    error(result)
  end

  return ok and result or nil
end

---@param opts? table
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

return M
