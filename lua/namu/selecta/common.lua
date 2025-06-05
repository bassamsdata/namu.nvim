-- Common utilities and constants for selecta modules
local logger = require("namu.utils.logger")
local config = require("namu.selecta.selecta_config")
local M = {}

M.config = config.values

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
  -- local ok, err = pcall(function()
  --   vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
  --     end_row = line_nr + 1,
  --     end_col = 0,
  --     hl_eol = true,
  --     hl_group = "NamuCurrentItem",
  --     priority = 202,
  --   })
  --
  --   -- Add the prefix icon if enabled
  --   if opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
  --     vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
  --       virt_text = { { opts.current_highlight.prefix_icon, "NamuCurrentItem" } },
  --       virt_text_pos = "overlay",
  --       priority = 202,
  --     })
  --   end
  -- end)

  -- if not ok then
  --   logger.error("Error highlighting current item: " .. err)
  --   return false
  -- end

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

  -- Check if we have any selections
  local has_selections = false
  if opts.multiselect and opts.multiselect.enabled and state.selected then
    for _, _ in pairs(state.selected) do
      has_selections = true
      break
    end
  end

  -- Apply highlight to the whole line
  vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
    line_hl_group = "NamuCurrentItem",
    priority = 202, -- Higher than regular highlights but lower than matches
  })

  -- Add the prefix icon if enabled
  if opts.current_highlight and opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
    -- Position the icon differently based on selection state
    if has_selections then
      -- Place at end of line when selections are active
      vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
        virt_text = { { "", "NamuCurrentItem" } },
        virt_text_pos = "eol",
        priority = 305,
      })
    else
      -- Original behavior (eol) when no selections
      vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
        -- virt_text = { { "❯ ", "NamuCurrentItem" } },
        virt_text = { { opts.current_highlight.prefix_icon, "NamuCurrentItem" } },
        virt_text_pos = "overlay",
        priority = 253,
      })
    end
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

  -- Hardcoded icons for indicators
  local empty_circle = "" -- Empty circle for non-selected items
  local filled_circle = "" -- Filled circle for selected items

  -- Check if we have any selections at all
  local has_selections = false
  if opts.multiselect and opts.multiselect.enabled and state.selected then
    for _, _ in pairs(state.selected) do
      has_selections = true
      break
    end
  end

  -- Apply highlights only if we have at least one selection
  if has_selections then
    for i, item in ipairs(state.filtered_items) do
      local item_id = M.get_item_id(item)
      local is_selected = state.selected[item_id]

      -- Only show indicators when we have at least one selection
      if is_selected then
        -- Show filled circle for selected items
        vim.api.nvim_buf_set_extmark(state.buf, M.selection_ns, i - 1, 0, {
          virt_text = { { filled_circle, "NamuSelected" } },
          virt_text_pos = "overlay",
          priority = 203,
        })
      else
        -- Show empty circle for non-selected items
        vim.api.nvim_buf_set_extmark(state.buf, M.selection_ns, i - 1, 0, {
          virt_text = { { empty_circle, "NamuEmptyIndicator" } },
          virt_text_pos = "overlay",
          priority = 203,
        })
      end
    end
  end
end

-- Logger utilities
M.log = logger.log

return M
