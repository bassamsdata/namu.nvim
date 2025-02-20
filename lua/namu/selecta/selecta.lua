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

---@class SelectaState
---@field buf number Buffer handle
---@field win number Window handle
---@field prompt_buf number? Prompt buffer handle
---@field prompt_win number? Prompt window handle
---@field query string[] Current search query
---@field cursor_pos number Cursor position in query
---@field items SelectaItem[] All items
---@field filtered_items SelectaItem[] Filtered items
---@field active boolean Whether picker is active
---@field initial_open boolean First open flag
---@field best_match_index number? Index of best match
---@field cursor_moved boolean Whether cursor has moved
---@field row number Window row position
---@field col number Window column position
---@field width number Window width
---@field height number Window height
---@field selected table<string, boolean> Map of selected item ids
---@field selected_count number Number of items currently selected

---@class SelectaItem
---@field text string Display text
---@field value any Actual value to return
---@field icon? string Optional icon
---@field hl_group? string Optional highlight group for the icon/text

---@class SelectaKeymap
---@field key string The key sequence
---@field handler fun(item: SelectaItem, state: SelectaState, close_fn: fun(state: SelectaState)): boolean? The handler function
---@field desc? string Optional description of what the keymap does

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
---@field show_footer? boolean
---@field auto_resize? boolean
---@field footer_pos? "left"|"center"|"right"
---@field title_pos? "left"|string

---@class SelectaMovementConfig
---@field next string|string[] Key(s) for moving to next item
---@field previous string|string[] Key(s) for moving to previous item
---@field close string|string[] Key(s) for closing picker
---@field select string|string[] Key(s) for selecting item
---@field alternative_next? string @deprecated Use next array instead
---@field alternative_previous? string @deprecated Use previous array instead

---@class SelectaOptions
---@field title? string
---@field formatter? fun(item: SelectaItem): string
---@field filter? fun(item: SelectaItem, query: string): boolean
---@field sorter? fun(items: SelectaItem[], query: string): SelectaItem[]
---@field on_select? fun(item: SelectaItem)
---@field on_cancel? fun()
---@field on_move? fun(item: SelectaItem)
---@field fuzzy? boolean
---@field window? SelectaWindowConfig
---@field preserve_order? boolean
---@field keymaps? SelectaKeymap[]
---@field auto_select? boolean
---@field row_position? "center"|"top10"
---@field multiselect? SelectaMultiselect
---@field display? SelectaDisplay
---@field offset? number
---@field hooks? SelectaHooks
---@field initially_hidden? boolean
---@field initial_index? number
---@field debug? boolean
---@field movement? SelectaMovementConfig
---@field custom_keymaps? table<string, SelectaCustomAction> Custom actions
---@field pre_filter? fun(items: SelectaItem[], query: string): SelectaItem[], string Function to pre-filter items before matcher

---@class SelectaHooks
---@field on_render? fun(buf: number, items: SelectaItem[], opts: SelectaOptions) Called after items are rendered
---@field on_window_create? fun(win_id: number, buf_id: number, opts: SelectaOptions) Called after window creation
---@field before_render? fun(items: SelectaItem[], opts: SelectaOptions) Called before rendering items

---@class SelectaCustomAction
---@field keys string|string[] The key(s) for this action
---@field handler fun(item: SelectaItem|SelectaItem[], state: SelectaState): boolean? The handler function
---@field desc? string Optional description

---@class SelectaMultiselect
---@field enabled boolean Whether multiselect is enabled
---@field indicator string Character to show for selected items
---@field on_select fun(items: SelectaItem[]) Callback for multiselect completion
---@field max_items? number|nil Maximum number of items that can be selected
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
}

---@type CursorCache
local cursor_cache = {
  guicursor = nil,
}

function M.log(message)
  logger.log(message)
end

M.clear_log = logger.clear_log

local ns_id = vim.api.nvim_create_namespace("selecta_highlights")

---Thanks to folke and mini.nvim for this utlity of hiding the cursor
---Hide the cursor by setting guicursor and caching the original value
---@return nil
local function hide_cursor()
  if vim.o.guicursor == "a:MiniPickCursor" then
    return
  end
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

local highlights = {
  SelectaPrefix = { link = "Special" },
  SelectaMatch = { link = "Identifier" }, -- or maybe DiagnosticFloatingOk
  SelectaFilter = { link = "Type" },
  SelectaCursor = { blend = 100, nocombine = true },
  SelectaPrompt = { link = "FloatTitle" },
  SelectaSelected = { link = "Statement" },
  SelectaFooter = { link = "Comment" },
}

---Set up the highlight groups
---@return nil
local function setup_highlights()
  M.log("Setting up highlights...")
  M.log("Current highlights table: " .. vim.inspect(highlights))
  for name, attrs in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, attrs)
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

local POSITION_RATIOS = {
  top10 = 0.1,
  bottom = 0.8,
  center = 0.5,
  right = 0.7,
}
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
    -- Calculate max available width based on position
    local max_available_width
    local row_position = opts.row_position or M.config.row_position or "top10"
    if row_position:match("_right") then
      if M.config.right_position.fixed then
        -- For right-aligned windows, available width is from right position to screen edge
        local right_col = math.floor(vim.o.columns * M.config.right_position.ratio)
        max_available_width = vim.o.columns - right_col - padding
      else
        -- For flexible position, use full screen width with padding
        max_available_width = vim.o.columns - (padding * 2)
      end
    else
      max_available_width = vim.o.columns - (padding * 2)
    end

    content_width = math.min(math.max(content_width, min_width), max_width, max_available_width)
  else
    -- Use ratio-based width
    content_width = math.floor(vim.o.columns * (opts.window.width_ratio or M.config.window.width_ratio))
  end

  -- Calculate height based on number of items
  local row_position = opts.row_position
  local lines = vim.o.lines
  local max_available_height
  if row_position == "top10" or row_position == "top10_right" then
    max_available_height = lines - math.floor(lines * 0.1) - vim.o.cmdheight - 4
  elseif row_position == "bottom" then
    max_available_height = math.floor(vim.o.lines * 0.2)
  else
    max_available_height = lines - math.floor(lines / 2) - 4
  end
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
  local before_cursor = table.concat(vim.list_slice(state.query, 1, state.cursor_pos - 1))
  local after_cursor = table.concat(vim.list_slice(state.query, state.cursor_pos))
  local raw_prmpt = opts.window.title_prefix .. before_cursor .. "│" .. after_cursor

  if vim.api.nvim_win_is_valid(state.win) then
    if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
      vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { raw_prmpt })
      -- vim.api.nvim_buf_add_highlight(state.prompt_buf, -1, "SelectaPrompt", 0, 0, -1)
      -- else
      --   pcall(vim.api.nvim_win_set_config, state.win, {
      --     title = { { raw_prmpt, "SelectaPrompt" } },
      --     title_pos = opts.window.title_pos or M.config.window.title_pos,
      --   })
    end
  end
end

---@param state SelectaState
---@param query string
---@param opts SelectaOptions
function M.update_filtered_items(state, query, opts)
  local items_to_filter = state.items
  local actual_query = query

  if opts.pre_filter then
    local new_items, new_query = opts.pre_filter(state.items, query)
    if new_items then
      items_to_filter = new_items
      -- Show the filtered items even if new_query is empty
      state.filtered_items = new_items
    end
    actual_query = new_query or ""
  end

  -- Only proceed with further filtering if there's an actual query
  if actual_query ~= "" then
    state.filtered_items = {}
    for _, item in ipairs(items_to_filter) do
      local match = matcher.get_match_positions(item.text, actual_query)
      if match then
        table.insert(state.filtered_items, item)
      end
    end

    local best_index
    state.filtered_items, best_index = matcher.sort_items(state.filtered_items, actual_query, opts.preserve_order)
    state.best_match_index = best_index

    if opts.auto_select and #state.filtered_items == 1 and not state.initial_open then
      local selected = state.filtered_items[1]
      if selected and opts.on_select then
        opts.on_select(selected)
        M.close_picker(state)
      end
    end
  elseif not opts.pre_filter then
    -- Only set to all items if there's no pre_filter
    state.filtered_items = items_to_filter
    state.best_match_index = nil
  end
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
  -- vim.api.nvim_win_set_option(state.prompt_win, "winhl", "Normal:SelectaPrompt")
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
  local display_str = opts.formatter(item)

  -- First, check if this is a symbol filter query
  -- local filter = query:match("^%%%w%w(.*)$")
  -- local actual_query = filter and query:sub(4) or query -- Use everything after %xx if filter exists
  local filter, remaining = query:match("^(%%%w%w)(.*)$")
  local actual_query = remaining or query

  -- Highlight title prefix in prompt buffer
  if state.prompt_buf and vim.api.nvim_buf_is_valid(state.prompt_buf) then
    -- Highlight the title prefix
    local prefix = opts.window.title_prefix
    if prefix then
      vim.api.nvim_buf_set_extmark(state.prompt_buf, ns_id, 0, 0, {
        end_col = #prefix,
        hl_group = "SelectaFilter",
        priority = 200,
      })
    end
    -- If there's a filter, highlight it in the prompt buffer
    if filter then
      local prefix_len = #(opts.window.title_prefix or "")
      vim.api.nvim_buf_set_extmark(state.prompt_buf, ns_id, 0, prefix_len, {
        end_col = prefix_len + 3, -- Length of %xx is 3
        hl_group = "SelectaFilter",
        priority = 200,
      })
    end
  end
  -- Get the formatted display string
  if opts.display.mode == "raw" then
    local offset = opts.offset and opts.offset(item) or 0
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

    -- Allow modules to customize prefix highlighting
    if opts.prefix_highlighter then
      opts.prefix_highlighter(buf, line_nr, item, icon_end, ns_id)
    else
      -- Highlight prefix/icon
      vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, 0, {
        end_col = icon_end,
        hl_group = get_prefix_info(item, opts.display.prefix_width).hl_group,
        priority = 100,
        hl_mode = "combine",
      })
    end

    -- Debug log
    -- M.log(
    --   string.format(
    --     "Highlighting item: %s\nFull display: '%s'\nIcon boundary: %d\nQuery: '%s'",
    --     item.text,
    --     display_str,
    --     icon_end,
    --     query
    --   )
    -- )
    -- Calculate base offset for query highlights (icon + space)
    local base_offset = item.icon and (vim.api.nvim_strwidth(item.icon) + 1) or 0

    -- Highlight matches in the text using actual_query
    if actual_query ~= "" then -- Use actual_query instead of query
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
            local highlight_text = display_str:sub(start_col + 1, end_col)

            -- Debug log
            -- M.log(
            --   string.format("Match position: [%d, %d]\nFinal position: [%d, %d]", pos[1], pos[2], start_col, end_col)
            -- )

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

  local indicator = opts.multiselect and opts.multiselect.indicator or M.config.multiselect.indicator
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
    local new_pos
    -- Only use best_match_index if we haven't moved the cursor manually
    -- and we're not in initial state
    if opts.preserve_order and state.best_match_index and not state.initial_open and not state.cursor_moved then
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
    vim.api.nvim_win_set_cursor(state.win, new_pos)

    -- Only trigger on_move if not in initial state
    if opts.on_move and not state.initial_open then
      opts.on_move(state.filtered_items[new_pos[1]])
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

  -- Calculate maximum height based on available space below the initial row
  local max_available_height
  if opts.row_position == "top10" or M.config.row_position == "top10" then
    max_available_height = vim.o.lines - math.floor(vim.o.lines * 0.1) - vim.o.cmdheight - 4 -- Leave some space for status line
  else
    max_available_height = vim.o.lines - state.row - vim.o.cmdheight - 4 -- Leave some space for status line
  end
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
  local win_config = {
    relative = current_config.relative,
    row = current_config.row, -- or state.row
    col = current_config.col, -- or state.col
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
      { footer_text, "SelectaFooter" },
    },
    footer_pos = footer_pos,
  })
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

  if query ~= "" or not opts.initially_hidden then
    M.update_filtered_items(state, query, opts)

    -- Call before render hook
    if opts.hooks and opts.hooks.before_render then
      opts.hooks.before_render(state.filtered_items, opts)
    end

    -- Update footer after filtered items are updated
    if opts.window.show_footer then
      update_footer(state, state.win, opts)
    end

    if opts.window.auto_resize then
      resize_window(state, opts)

      -- Update prompt window size if it exists
      if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
        local main_win_config = vim.api.nvim_win_get_config(state.win)
        pcall(vim.api.nvim_win_set_config, state.prompt_win, {
          width = main_win_config.width,
          col = main_win_config.col,
        })
      end
    end

    -- Update buffer content
    if vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_clear_namespace(state.buf, ns_id, 0, -1)

      local lines = {}
      for i, item in ipairs(state.filtered_items) do
        lines[i] = opts.formatter and opts.formatter(item) or item.text
      end

      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)

      -- Apply highlights
      for i, item in ipairs(state.filtered_items) do
        local line_nr = i - 1
        local line = lines[i]
        local line_length = vim.api.nvim_strwidth(line)
        apply_highlights(state.buf, line_nr, item, opts, query, line_length, state)
      end
      -- Call render hook after highlights are applied
      if opts.hooks and opts.hooks.on_render then
        opts.hooks.on_render(state.buf, state.filtered_items, opts)
      end

      update_cursor_position(state, opts)
    end
  else
    if vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_clear_namespace(state.buf, ns_id, 0, -1)
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
      if opts.hooks and opts.hooks.on_buffer_clear then
        opts.hooks.on_buffer_clear()
      end
    end

    -- Resize window to minimum dimensions using resize_window function
    if opts.window.auto_resize then
      -- Temporarily set filtered_items to an empty table to calculate minimum size
      local original_filtered_items = state.filtered_items
      state.filtered_items = {}
      resize_window(state, opts)
      -- Restore original filtered_items
      state.filtered_items = original_filtered_items
    end
  end
end

---Close the picker and restore cursor
---@param state SelectaState
---@return nil
function M.close_picker(state)
  if not state then
    return
  end
  state.active = false
  if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
    vim.api.nvim_win_close(state.prompt_win, true)
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  restore_cursor()
end

---Toggle selection of an item
---@param state SelectaState
---@param item SelectaItem
---@param opts SelectaOptions
---@return boolean Whether the operation was successful
local function toggle_selection(state, item, opts)
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
local function get_window_position(width, row_position)
  local lines = vim.o.lines
  local columns = vim.o.columns
  local cmdheight = vim.o.cmdheight
  local available_lines = lines - cmdheight - 2

  -- Calculate column position once
  local is_right = row_position:match("_right")
  local col
  if is_right then
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
  if row_position:match("top") then
    row = math.floor(lines * POSITION_RATIOS.top10)
  elseif row_position == "bottom" then
    row = math.floor(lines * POSITION_RATIOS.bottom) - 4
  else -- center positions
    row = math.max(1, math.floor(available_lines * POSITION_RATIOS.center))
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
  }

  local width, height
  if opts.initially_hidden then
    -- Use minimum width and height when initially hidden
    width = opts.window.min_width or M.config.window.min_width
    height = opts.window.min_height or M.config.window.min_height
  else
    width, height = calculate_window_size(items, opts, opts.formatter)
  end

  local row, col = get_window_position(width, opts.row_position)

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
    -- title = { -- this for one window module
    --   { opts.window.title_prefix or M.config.window.title_prefix, "SelectaPrompt" },
    -- },
    -- title_pos = "center",
  }, opts.window.override or {})

  if opts.window.show_footer then
    win_config.footer = {
      { string.format(" %d/%d ", #items, #items), "SelectaFooter" },
    }
    win_config.footer_pos = opts.window.footer_pos or "right"
  end

  -- Hide cursor before creating window
  hide_cursor()
  -- Create windows and setup
  state.win = vim.api.nvim_open_win(state.buf, true, win_config)

  -- Call window create hook
  if opts.hooks and opts.hooks.on_window_create then
    opts.hooks.on_window_create(state.win, state.buf, opts)
  end

  create_prompt_window(state, opts)

  vim.wo[state.win].cursorline = true
  vim.wo[state.win].cursorlineopt = "both"
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = state.buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.buf })

  -- First update the display
  update_display(state, opts)

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

---Delete last word from query
---@param state SelectaState
local function delete_last_word(state)
  -- If we're at the start, nothing to delete
  if state.cursor_pos <= 1 then
    return
  end

  -- Find the last non-space character before cursor
  local last_char_pos = state.cursor_pos - 1
  while last_char_pos > 1 and state.query[last_char_pos] == " " do
    last_char_pos = last_char_pos - 1
  end

  -- Find the start of the word
  local word_start = last_char_pos
  while word_start > 1 and state.query[word_start - 1] ~= " " do
    word_start = word_start - 1
  end

  -- Remove characters from word_start to last_char_pos
  for i = word_start, last_char_pos do
    table.remove(state.query, word_start)
  end

  -- Update cursor position
  state.cursor_pos = word_start
  state.initial_open = false
  state.cursor_moved = false
end

---Clear the entire query line
---@param state SelectaState
local function clear_query_line(state)
  state.query = {}
  state.cursor_pos = 1
  state.initial_open = false
  state.cursor_moved = false
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

-- Simplified movement handler
local function handle_movement(state, direction, opts)
  -- Early return if there are no items or initially hidden with empty query
  if #state.filtered_items == 0 or (opts.initially_hidden and #table.concat(state.query) == 0) then
    return
  end

  -- Make sure the window is still valid before attempting to get/set cursor
  if not vim.api.nvim_win_is_valid(state.win) then
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

  pcall(vim.api.nvim_win_set_cursor, state.win, { new_pos, 0 })

  if opts.on_move then
    opts.on_move(state.filtered_items[new_pos])
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
    local was_toggled = toggle_selection(state, current_item, opts)
    M.log(string.format("Item toggled: %s", tostring(was_toggled)))

    -- Only move if toggle was successful
    if was_toggled then
      -- Update display first
      update_display(state, opts)

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
    update_display(state, opts)

    -- Ensure cursor stays at the correct position
    pcall(vim.api.nvim_win_set_cursor, state.win, { prev_selected_pos, 0 })

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
  if opts.custom_keymaps and type(opts.custom_keymaps) == "table" then
    for action_name, action in pairs(opts.custom_keymaps) do
      -- Check if action is properly formatted
      if action and action.keys then
        local keys = type(action.keys) == "string" and { action.keys } or action.keys
        for _, key in ipairs(keys) do
          if char_key == vim.api.nvim_replace_termcodes(key, true, true, true) then
            local selected = state.filtered_items[vim.api.nvim_win_get_cursor(state.win)[1]]
            if selected and action.handler then
              if opts.multiselect and opts.multiselect.enabled and state.selected_count > 0 then
                -- Handle multiselect case
                local selected_items = {}
                for _, item in ipairs(state.filtered_items) do
                  if state.selected[get_item_id(item)] then
                    table.insert(selected_items, item)
                  end
                end
                local should_close = action.handler(selected_items, state)
                if should_close == false then
                  M.close_picker(state)
                  return nil
                end
              else
                -- Handle single item case
                local should_close = action.handler(selected, state)
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
    end
  end

  -- Handle multiselect keymaps
  if opts.multiselect and opts.multiselect.enabled then
    local multiselect_keys = opts.multiselect.keymaps or M.config.multiselect.keymaps
    if char_key == vim.api.nvim_replace_termcodes(multiselect_keys.toggle, true, true, true) then
      if handle_toggle(state, opts, 1) then
        return nil
      end
    elseif char_key == vim.api.nvim_replace_termcodes(multiselect_keys.untoggle, true, true, true) then
      if handle_untoggle(state, opts) then
        return nil
      end
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

  -- Handle movement and control keys
  if vim.tbl_contains(movement_keys.previous, char_key) then
    state.cursor_moved = true
    state.initial_open = false
    handle_movement(state, -1, opts)
    return nil
  elseif vim.tbl_contains(movement_keys.next, char_key) then
    state.cursor_moved = true
    state.initial_open = false
    handle_movement(state, 1, opts)
    return nil
  elseif vim.tbl_contains(movement_keys.close, char_key) then
    if opts.on_cancel then
      opts.on_cancel()
    end
    M.close_picker(state)
    return nil
  elseif vim.tbl_contains(movement_keys.select, char_key) then
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
    M.close_picker(state)
    return nil
  elseif vim.tbl_contains(movement_keys.delete_word, char_key) then
    delete_last_word(state)
    update_display(state, opts)
    return nil
  elseif vim.tbl_contains(movement_keys.clear_line, char_key) then
    clear_query_line(state)
    update_display(state, opts)
    return nil
  elseif char_key == SPECIAL_KEYS.MOUSE and vim.v.mouse_win ~= state.win and vim.v.mouse_win ~= state.prompt_win then
    if opts.on_cancel then
      opts.on_cancel()
    end
    M.close_picker(state)
    return nil
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
  M.log("pick called with " .. #items .. " items")
  for group, _ in pairs(highlights) do
    local hl = vim.api.nvim_get_hl(0, { name = group })
    M.log(string.format("Current highlight for %s: %s", group, vim.inspect(hl)))
  end
  -- Merge options with defaults
  opts = vim.tbl_deep_extend("force", {
    title = "Select",
    display = vim.tbl_deep_extend("force", M.config.display, {}),
    filter = function(item, query)
      return query == "" or string.find(string.lower(item.text), string.lower(query))
    end,
    fuzzy = false,
    offnet = 0,
    custom_keymaps = vim.tbl_deep_extend("force", M.config.custom_keymaps, {}),
    movement = vim.tbl_deep_extend("force", M.config.movement, {}),
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
      if opts.display.mode == "raw" then
        return item.text
      elseif opts.display.mode == "icon" then
        local icon = item.icon or "  "
        return icon .. string.rep(" ", opts.display.padding or 1) .. item.text
      else
        local prefix_info = get_prefix_info(item, opts.display.prefix_width)
        local padding = string.rep(" ", prefix_info.padding)
        return prefix_info.text .. padding .. item.text
      end
    end

  local state = create_picker(items, opts)
  update_display(state, opts)
  vim.cmd("redraw")

  -- Handle initial cursor position
  if opts.initial_index and opts.initial_index <= #items then
    local target_pos = math.min(opts.initial_index, #state.filtered_items)
    if target_pos > 0 then
      vim.api.nvim_win_set_cursor(state.win, { target_pos, 0 })
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
    restore_cursor()
  end)
  if state and state.active then
    M.close_picker(state)
  end

  -- Ensure cursor is restored even if there was an error
  if not ok then
    vim.schedule(function()
      restore_cursor()
    end)
    error(result)
  end

  return result
end

M._test = {
  get_match_positions = matcher.get_match_positions,
  is_word_boundary = matcher.is_word_boundary,
  update_filtered_items = M.update_filtered_items,
  calculate_window_size = calculate_window_size,
  validate_input = matcher.validate_input,
  apply_highlights = apply_highlights,
  setup_highlights = setup_highlights,
}

---Show picker without using internal defaults
---@param items SelectaItem[] Items to display
---@param display_opts {window: table, display: table, position: string, title: string?, on_select: function?, on_cancel: function?, on_move: function?}
---@return number|nil window_id Returns the window ID if created successfully
function M.show_picker(items, display_opts)
  -- No merging with defaults, use options directly
  local picker_opts = {
    title = display_opts.title or "Select",
    window = display_opts.window,
    display = display_opts.display,
    row_position = display_opts.position,
    -- Core callbacks
    on_select = display_opts.on_select,
    on_cancel = display_opts.on_cancel,
    on_move = display_opts.on_move,
    -- Essential options that shouldn't be configurable
    fuzzy = false,
    preserve_order = true,
  }

  -- Use existing picker creation but with direct options
  local state = create_picker(items, picker_opts)
  update_display(state, picker_opts)
  vim.cmd("redraw")

  -- Main input loop
  local ok, result = pcall(function()
    while state.active do
      local char = vim.fn.getchar()
      local result = handle_char(state, char, picker_opts)
      if result ~= nil then
        return result
      end
      vim.cmd("redraw")
    end
  end)

  if not ok then
    vim.schedule(function()
      restore_cursor()
    end)
    error(result)
  end

  return state.win
end

---@param opts? table
function M.setup(opts)
  opts = opts or {}
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  -- Set up initial highlights
  logger.setup(opts)
  M.log("Calling setup_highlights from M.setup")
  vim.schedule(function()
    setup_highlights()
  end)

  -- Create autocmd for ColorScheme event
  M.log("Creating ColorScheme autocmd")
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("SelectaHighlights", { clear = true }),
    callback = function()
      M.log("ColorScheme autocmd triggered")
      setup_highlights()
    end,
  })
end

---Open current buffer in a split and jump to the selected symbol's location
---@param state SelectaState The current picker state
---@param item SelectaItem The LSP symbol item to jump to
---@param split_type? "vertical"|"horizontal" The type of split to create (defaults to horizontal)
---@param module_state NamuState The state from the calling module
---@return number|nil window_id The new window ID if successful
function M.open_in_split(state, item, split_type, module_state)
  if not item then
    return nil
  end

  -- Use module_state for original window and position if available
  local original_win = module_state.original_win and module_state.original_win or vim.api.nvim_get_current_win()
  local original_pos = module_state.original_pos and module_state.original_pos or vim.api.nvim_win_get_cursor(0)
  local current_buf = module_state.original_buf and module_state.original_buf or vim.api.nvim_get_current_buf()

  -- Close the picker
  M.close_picker(state)

  -- First focus the original window and restore cursor position
  if original_win and vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
    pcall(vim.api.nvim_win_set_cursor, original_win, original_pos)
  end

  -- Create the split
  local split_cmd = split_type == "vertical" and "vsplit" or "split"
  vim.cmd(split_cmd)

  -- Get the new window ID
  local new_win = vim.api.nvim_get_current_win()

  -- Set up the new window
  vim.api.nvim_win_set_buf(new_win, current_buf)

  return new_win
end

return M
