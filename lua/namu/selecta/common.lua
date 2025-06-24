-- Credit to @folke snacks.nvim for selection icons and the selection style
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

-- Update the current highlight for the selected item
---@param state SelectaState The current state of the selecta picker
---@param opts SelectaOptions The options for the selecta picker
---@param line_nr number The 0-based line number to highlight
---@return nil
function M.update_current_highlight(state, opts, line_nr)
  if not state or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.buf, M.current_selection_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(state.buf, line_nr, line_nr + 1, false)
  if #lines == 0 then
    return
  end
  local has_selections = false
  if opts.multiselect and opts.multiselect.enabled and state.selected then
    has_selections = next(state.selected) ~= nil
  end
  -- Apply highlight to the whole line
  vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
    line_hl_group = "NamuCurrentItem",
    priority = 202,
  })
  if opts.current_highlight and opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
    if has_selections then
      -- Place at end of line when selections are active
      vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
        virt_text = { { "", "NamuCurrentItemIconSelection" } },
        virt_text_pos = "eol",
        priority = 305,
      })
    else
      vim.api.nvim_buf_set_extmark(state.buf, M.current_selection_ns, line_nr, 0, {
        -- virt_text = { { "❯ ", "NamuCurrentItem" } },
        virt_text = { { opts.current_highlight.prefix_icon, "NamuCurrentItemIcon" } },
        virt_text_pos = "overlay",
        priority = 253,
      })
    end
  end
end

function M.update_selection_highlights(state, opts)
  if not state or not state.active or not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.buf, M.selection_ns, 0, -1)
  if not (opts.multiselect and opts.multiselect.enabled) then
    return
  end
  -- Credit to @folke snacks.nvim for those icons and the style
  local empty_circle = opts.multiselect.unselected_icon
  local filled_circle = opts.multiselect.selected_icon
  local has_selections = false
  if opts.multiselect and opts.multiselect.enabled and state.selected then
    has_selections = next(state.selected) ~= nil
  end
  if has_selections then
    for i, item in ipairs(state.filtered_items) do
      local item_id = M.get_item_id(item)
      local is_selected = state.selected[item_id]

      -- For diagnostics with grouped items, only show indicators on main items
      local should_show_indicator = true
      if item.group_type and item.group_type == "diagnostic_aux" then
        should_show_indicator = false
      end
      if should_show_indicator and is_selected then
        vim.api.nvim_buf_set_extmark(state.buf, M.selection_ns, i - 1, 0, {
          virt_text = { { filled_circle, "NamuSelected" } },
          virt_text_pos = "overlay",
          priority = 203,
        })
      elseif should_show_indicator then
        vim.api.nvim_buf_set_extmark(state.buf, M.selection_ns, i - 1, 0, {
          virt_text = { { empty_circle, "NamuEmptyIndicator" } },
          virt_text_pos = "overlay",
          priority = 203,
        })
      end
    end
  end
end

---Close the picker with proper callback handling
---@param state SelectaState
---@param opts SelectaOptions
---@param close_picker_fn function Function to close the picker
---@param is_cancellation boolean Whether this is a cancellation (escape/close key) vs selection/custom action
---@return nil
function M.close_picker_with_cleanup(state, opts, close_picker_fn, is_cancellation)
  -- Call cancellation-specific callback only if this is a cancellation
  if is_cancellation and opts.on_cancel then
    opts.on_cancel()
  end
  if opts.on_close then
    opts.on_close()
  end
  close_picker_fn(state)
end

return M
