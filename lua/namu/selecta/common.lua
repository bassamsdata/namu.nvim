-- Common utilities and constants for selecta modules
local logger = require("namu.utils.logger")
local M = {}

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
-- Pre-compute the special keys once at module level
M.SPECIAL_KEYS = {
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

-- Create namespaces for highlights
M.ns_id = vim.api.nvim_create_namespace("selecta_highlights")
M.current_selection_ns = vim.api.nvim_create_namespace("selecta_current_selection")
M.selection_ns = vim.api.nvim_create_namespace("selecta_selection_highlights")
M.filter_info_ns = vim.api.nvim_create_namespace("selecta_filter_info")
M.prompt_info_ns = vim.api.nvim_create_namespace("selecta_prompt_info")
M.loading_ns_id = vim.api.nvim_create_namespace("selecta_loading_indicator")
M.prompt_icon_ns = vim.api.nvim_create_namespace("selecta_prompt_icon")

M.DEFAULT_POSITIONS = {
  center = 0.5,
  bottom = 0.8,
  top10 = 0.1,
}

function M.calculate_max_available_height(position_info)
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

function M.get_prefix_info(item, max_prefix_width)
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
function M.parse_position(position)
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

---Get border characters configuration
---@param border string|table
---@return string|table
function M.get_prompt_border(border)
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

function M.get_border_with_footer(opts)
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

-- Utility functions
---Generate a unique ID for an item
---@param item SelectaItem
---@return string
function M.get_item_id(item)
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
-- Add proper bounds checking for highlight operations

function M.safe_highlight_current_item(state, opts, line_nr)
  -- Check if state and buffer are valid
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return false
  end

  -- Clear previous highlights
  vim.api.nvim_buf_clear_namespace(state.buf, M.current_selection_ns, 0, -1)

  -- Validate line number
  if line_nr < 0 or line_nr >= vim.api.nvim_buf_line_count(state.buf) then
    return false
  end

  -- Apply highlight safely
  local ok, err = pcall(function()
    vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
      end_row = line_nr + 1,
      end_col = 0,
      hl_eol = true,
      hl_group = "NamuCurrentItem",
      priority = 202,
    })

    -- Add the prefix icon if enabled
    if opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
      vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
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

-- Update the current highlight for the selected item
---@param state SelectaState The current state of the selecta picker
---@param opts SelectaOptions The options for the selecta picker
---@param line_nr number The 0-based line number to highlight
---@return nil
function M.update_current_highlight(state, opts, line_nr)
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  -- Clear previous highlights in this namespace
  vim.api.nvim_buf_clear_namespace(state.buf, M.current_selection_ns, 0, -1)

  -- Get the line content
  local lines = vim.api.nvim_buf_get_lines(state.buf, line_nr, line_nr + 1, false)
  if #lines == 0 then
    return
  end

  -- Apply highlight to the whole line
  vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
    end_row = line_nr + 1,
    end_col = 0,
    hl_eol = true,
    hl_group = "NamuCurrentItem",
    priority = 202, -- Higher than regular highlights but lower than matches
  })

  -- Add the prefix icon if enabled
  if opts.current_highlight and opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
    vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
      virt_text = { { opts.current_highlight.prefix_icon, "NamuCurrentItem" } },
      virt_text_pos = "overlay",
      priority = 202, -- Higher priority than the line highlight
    })
  end
end

-- Function to update all selection highlights at once
function M.update_selection_highlights(state, opts)
  -- Early return if state or buffer is invalid
  if not state or not state.active or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  -- Clear previous selection highlights
  vim.api.nvim_buf_clear_namespace(state.buf, M.selection_ns, 0, -1)

  -- Skip if multiselect is not enabled
  if not (opts.multiselect and opts.multiselect.enabled) then
    return
  end

  -- Get indicator character
  local indicator = opts.multiselect.indicator or M.config.multiselect.indicator -- Use config as fallback

  -- Apply selection highlights to ALL selected items in filtered_items
  for i, item in ipairs(state.filtered_items) do
    local item_id = M.get_item_id(item)
    if state.selected[item_id] then
      -- i-1 because buffer lines are 0-indexed
      vim.api.nvim_buf_set_extmark(state.buf, M.selection_ns, i - 1, 0, {
        -- FIX: fix it please or return the previous behaviour
        sign_text = indicator,
        sign_hl_group = "NamuSelected",
        -- virt_text = { { indicator, "NamuSelected" } },
        -- virt_text_pos = "overlay",
        priority = 203, -- higher than current item highlight
      })
    end
  end
end

-- Logger utilities
M.log = logger.log

return M
