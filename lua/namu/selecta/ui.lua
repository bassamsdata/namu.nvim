-- UI handling functionality for selecta

local M = {}
local common = require("namu.selecta.common")
local matcher = require("namu.selecta.matcher")
local config = require("namu.selecta.selecta_config").values
local log = require("namu.utils.logger").log

-- Local references for optimization
local ns_id = common.ns_id
local current_selection_ns = common.current_selection_ns
local selection_ns = common.selection_ns
local filter_info_ns = common.filter_info_ns
local prompt_info_ns = common.prompt_info_ns

-- cache for original window dimensions
local original_dimensions_cache = {}
---fucntion to get container dimensions
---@param opts SelectaOptions
---@param picker_id string
---@return table
function M.get_container_dimensions(opts, picker_id)
  -- Check if we have cached dimensions for this picker
  if picker_id and original_dimensions_cache[picker_id] then
    local cached = original_dimensions_cache[picker_id]
    return cached
  end

  -- Otherwise calculate dimensions
  if opts.window.relative == "win" then
    -- Get current window dimensions
    local original_win = vim.api.nvim_get_current_win()
    local win_width = vim.api.nvim_win_get_width(original_win)
    local win_height = vim.api.nvim_win_get_height(original_win)
    local dimensions = {
      width = win_width,
      height = win_height,
      win = original_win,
    }
    -- Cache these dimensions if we have a picker_id
    if picker_id then
      original_dimensions_cache[picker_id] = dimensions
    end

    return dimensions
  else
    -- Default to editor dimensions
    local dimensions = {
      width = vim.o.columns,
      height = vim.o.lines - vim.o.cmdheight - 2,
      win = nil,
    }
    -- Cache these dimensions if we have a picker_id
    if picker_id then
      -- print(string.format("[DEBUG] Caching editor dimensions for picker_id=%s", picker_id))
      original_dimensions_cache[picker_id] = dimensions
    end

    return dimensions
  end
end

-- helper to set dimensions for a specific picker id
function M.set_original_dimensions(picker_id, dimensions)
  original_dimensions_cache[picker_id] = dimensions
end

-- helper to get dimensions for a specific picker id
function M.get_original_dimensions(picker_id)
  return original_dimensions_cache[picker_id]
end

-- helper to clear dimensions when picker is closed
function M.clear_original_dimensions(picker_id)
  if original_dimensions_cache[picker_id] then
    original_dimensions_cache[picker_id] = nil
  end
end

function M.calculate_max_available_height(position_info, opts, picker_id)
  -- Get container dimensions using our existing caching system
  local container = M.get_original_dimensions(picker_id) or M.get_container_dimensions(opts, picker_id)

  -- Calculate height based on container dimensions and position
  if position_info.type:match("^top") then
    -- Handle any top position (top, top_right, with any percentage)
    return container.height - math.floor(container.height * position_info.ratio) - 3
  elseif position_info.type == "bottom" then
    return math.floor(container.height * 0.2)
  else
    return container.height - math.floor(container.height / 2) - 4
  end
end

-- Calculate maximum prefix width for all items
---@param items SelectaItem[]
---@param display_mode string
---@return number
function M.calculate_max_prefix_width(items, display_mode)
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

---@param opts SelectaOptions
---@return string|table
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

---Create the prompt window for input
---@param state SelectaState
---@param opts SelectaOptions
---@return number win_id The window id
---@return number buf_id The buffer id
function M.create_prompt_window(state, opts)
  state.prompt_buf = vim.api.nvim_create_buf(false, true)
  -- Set buffer options for editing
  vim.api.nvim_buf_set_option(state.prompt_buf, "filetype", "namu_prompt")
  vim.b[state.prompt_buf].completion = false

  -- vim.bo[state.prompt_buf].buftype = "prompt" -- Setting buffer type to "prompt"
  -- Initialize with empty content
  -- vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { "" })

  -- Get container dimensions to determine if we need a win parameter
  local container = M.get_original_dimensions(state.picker_id) or M.get_container_dimensions(opts, state.picker_id)
  -- Create window with prompt buffer
  local prompt_config = {
    relative = opts.window.relative or config.window.relative,
    row = state.row,
    col = state.col,
    width = state.width,
    height = 1,
    style = "minimal",
    border = get_prompt_border(opts.window.border),
    zindex = 60,
  }

  -- Add win parameter if relative is "window"
  if opts.window.relative == "win" then
    prompt_config.win = container.win or vim.api.nvim_get_current_win()
  end

  state.prompt_win = vim.api.nvim_open_win(state.prompt_buf, false, prompt_config)

  -- -- Set window options
  -- vim.api.nvim_win_set_option(state.prompt_win, "wrap", false)
  -- vim.api.nvim_win_set_option(state.prompt_win, "cursorline", false)

  -- Return the created window and buffer
  return state.prompt_win, state.prompt_buf
end

---@param state SelectaState
---@param opts SelectaOptions
---@param show_info boolean Whether to show the info
function M.update_prompt_info(state, opts, show_info)
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

-- Function to update the filter info display
---@param state SelectaState
---@param filter_metadata table|nil
function M.update_filter_info(state, filter_metadata)
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

-- Update the footer whenever filtered items change
---@param state SelectaState
---@param win number
---@param opts SelectaOptions
function M.update_footer(state, win, opts)
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

---@param items SelectaItem[]
---@param opts SelectaOptions
---@param formatter fun(item: SelectaItem): string
---@param state_col number
---@param picker_id string
function M.calculate_window_size(items, opts, formatter, state_col, picker_id)
  local max_width = opts.window.max_width or config.window.max_width
  local min_width = opts.window.min_width or config.window.min_width
  local max_height = opts.window.max_height or config.window.max_height
  local min_height = opts.window.min_height or config.window.min_height
  local padding = opts.window.padding or config.window.padding
  log(
    string.format(
      "[DEBUG] calculate_window_size: max_width=%d min_width=%d max_height=%d min_height=%d padding=%d",
      max_width,
      min_width,
      max_height,
      min_height,
      padding
    )
  )
  -- Get container dimensions based on relative setting
  local container = picker_id and M.get_original_dimensions(picker_id) or M.get_container_dimensions(opts, picker_id)
  log(
    string.format(
      "[DEBUG] calculate_window_size: Container dimensions: win=%s width=%d height=%d",
      container.win or "nil",
      container.width,
      container.height
    )
  )
  -- Calculate content width
  local content_width = min_width
  -- Calculate position and initial column
  local row_position = opts.row_position or config.row_position or "top10"
  local position_info = common.parse_position(row_position)
  local initial_col = state_col
  local absolute_max_width = container.width - (2 * padding)
  max_width = math.min(max_width, absolute_max_width)
  if not initial_col then
    if position_info.type:find("_right$") then
      if config.right_position.fixed then
        initial_col = math.floor(container.width * config.right_position.ratio)
        -- Constrain max_width based on available space
        max_width = math.min(max_width, container.width - initial_col - (padding * 2) - 1)
      else
        -- Constrain max_width based on available space
        max_width = math.min(max_width, container.width - (padding * 2) - 1)
        initial_col = math.floor((container.width - max_width) / 2) -- Default to center if not fixed
      end
    else
      -- Constrain max_width based on available space
      max_width = math.min(max_width, container.width - (padding * 2) - 1)
      initial_col = math.floor((container.width - max_width) / 2) -- Center position
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
    content_width = math.floor(container.width * (opts.window.width_ratio or config.window.width_ratio))
    content_width = math.min(content_width, max_available_width) -- Constrain ratio-based width as well
  end
  -- Calculate height based on number of items
  local max_available_height = M.calculate_max_available_height(position_info, opts, picker_id)
  log(
    string.format(
      "[DEBUG] calculate_window_size: max_available_height=%d position_info.type=%s",
      max_available_height,
      position_info.type
    )
  )
  local content_height = #items
  log(string.format("[DEBUG] calculate_window_size: content_height=%d", content_height))
  -- Constrain height between min and max values
  content_height = math.min(content_height, max_height)
  content_height = math.min(content_height, max_available_height)
  content_height = math.max(content_height, min_height)
  log(string.format("[DEBUG] calculate_window_size: Final content_height=%d", content_height))

  return content_width, content_height
end

---@param state SelectaState
---@param opts SelectaOptions
function M.resize_window(state, opts)
  if not (state.active and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  local container = M.get_original_dimensions(state.picker_id) or M.get_container_dimensions(opts, state.picker_id)
  log(
    string.format(
      "[DEBUG] Container dimensions: win=%s width=%d height=%d",
      container.win or "nil",
      container.width,
      container.height
    )
  )
  -- BUG: we need to limit the new_width to the available space on the screen so
  -- it doesn't push the col to go left
  local new_width, new_height =
    M.calculate_window_size(state.filtered_items, opts, opts.formatter, state.col, state.picker_id)
  log(string.format("[DEBUG] Initial calculated dimensions: width=%d height=%d", new_width, new_height))
  log("[DEBUG]: number if items: " .. #state.filtered_items)
  -- print(string.format("[DEBUG] Initial calculated dimensions: width=%d height=%d", new_width, new_height))
  local current_config = vim.api.nvim_win_get_config(state.win)
  log(
    string.format(
      "[DEBUG] Current config: relative=%s row=%s col=%s",
      current_config.relative or "nil",
      current_config.row or "nil",
      current_config.col or "nil"
    )
  )
  -- Calculate maximum height based on available space below the initial row
  local max_available_height =
    M.calculate_max_available_height(common.parse_position(opts.row_position), opts, state.picker_id)
  new_height = math.min(new_height, max_available_height)
  -- Main window config
  local initial_col = state.col
  log(string.format("[DEBUG] Initial column: %d ", initial_col))
  local max_width = opts.window.max_width or config.window.max_width
  log(string.format("[DEBUG] Max width: %d ", max_width))
  local padding = opts.window.padding or config.window.padding
  log(string.format("[DEBUG] Padding: %d ", padding))
  local max_available_width = container.width - initial_col - (padding * 2) - 1
  log(string.format("[DEBUG] Max available width: %d ", max_available_width))
  log(
    string.format(
      "[DEBUG] Width calculation: container.width=%d - initial_col=%d - padding*2=%d - 1 = %d",
      container.width,
      initial_col,
      padding * 2,
      max_available_width
    )
  )

  -- Safety check - ensure width is positive
  max_available_width = math.max(1, max_available_width)
  log(string.format("[DEBUG] After safety check: max_available_width=%d", max_available_width))
  -- print(string.format("[DEBUG] After safety check: max_available_width=%d", max_available_width))
  new_width = math.min(new_width, max_available_width, max_width)
  log(
    string.format(
      "[DEBUG] Final width=%d (min of new_width=%d, max_available_width=%d, max_width=%d)",
      new_width,
      new_width,
      max_available_width,
      max_width
    )
  )
  new_width = math.max(1, new_width)
  log(string.format("[DEBUG] Final width: %d", new_width))
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
  -- Add win parameter if using window-relative positioning
  if opts.window.relative == "win" then
    win_config.win = container.win or vim.api.nvim_get_current_win()
  end
  if opts.window.relative == "win" then
    prompt_config.win = container.win or vim.api.nvim_get_current_win()
  end

  vim.api.nvim_win_set_config(state.win, win_config)
  if state.prompt_win and vim.api.nvim_win_is_valid(state.prompt_win) then
    vim.api.nvim_win_set_config(state.prompt_win, prompt_config)
  end

  -- Simple fix: if filtered items are less than window height,
  -- ensure we're viewing from the top
  if #state.filtered_items <= new_height then
    vim.api.nvim_win_call(state.win, function()
      vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
      vim.cmd("normal! zt")
    end)
  end
end

-- Add proper bounds checking for highlight operations
---@param state SelectaState
---@param opts SelectaOptions
---@param line_nr number
---@return boolean
function M.safe_highlight_current_item(state, opts, line_nr)
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
    if opts.current_highlight and opts.current_highlight.enabled and #opts.current_highlight.prefix_icon > 0 then
      vim.api.nvim_buf_set_extmark(state.buf, current_selection_ns, line_nr, 0, {
        sign_text = opts.current_highlight.prefix_icon,
        sign_hl_group = "NamuCurrentItem",
        -- virt_text_pos = "overlay",
        priority = 202,
      })
    end
  end)

  if not ok then
    common.log("Error highlighting current item: " .. err)
    return false
  end

  return true
end

---Add or update prefix in the signcolumn for the prompt with correct highlighting
---@param state SelectaState
---@param opts SelectaOptions
---@param query string Current query string
function M.update_prompt_prefix(state, opts, query)
  if not state.prompt_buf or not vim.api.nvim_buf_is_valid(state.prompt_buf) then
    return
  end

  -- Clear previous extmarks
  vim.api.nvim_buf_clear_namespace(state.prompt_buf, common.prompt_icon_ns, 0, -1)
  local prefix = opts.window.title_prefix
  if not prefix or prefix == "" then
    return
  end
  -- Enable signcolumn in the prompt buffer
  vim.api.nvim_buf_set_option(state.prompt_buf, "signcolumn", "yes")
  -- Determine highlight group based on filter status
  local highlight_group = "NamuFilter"
  -- Check if this is a symbol filter query
  local filter, remaining = query:match("^(/[%w][%w])(.*)$")
  if filter then
    -- Use different highlight for active filter
    highlight_group = "Statement"
  end
  if #state.filtered_items == 0 then
    highlight_group = "NamuFooter"
  end

  -- Add the prefix as a sign
  vim.api.nvim_buf_set_extmark(state.prompt_buf, common.prompt_icon_ns, 0, 0, {
    sign_text = prefix,
    sign_hl_group = highlight_group,
    priority = 100,
  })
end

---@param buf number
---@param line_nr number
---@param item SelectaItem
---@param opts SelectaOptions
---@param query string
---@param line_length number
---@param state SelectaState
function M.apply_highlights(buf, line_nr, item, opts, query, line_length, state)
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

  -- If there's a filter, highlight it in the prompt buffer
  if filter then
    vim.api.nvim_buf_set_extmark(state.prompt_buf, ns_id, 0, 0, {
      end_col = 3, -- Length of %xx is 3
      hl_group = "Statement",
      priority = 200,
    })
  end
  -- end
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
        hl_group = common.get_prefix_info(item, opts.display.prefix_width).hl_group,
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
end

-- Add this function to render only visible items
---@param state SelectaState
---@param opts SelectaOptions
function M.render_visible_items(state, opts)
  -- Early return if not valid
  if not state.is_valid or not state:is_valid() then
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
      M.apply_highlights(state.buf, line_nr, item, opts, query, line_length, state)
    end
  end
  M.update_prompt_prefix(state, opts, state:get_query_string())

  -- Call render hook after highlights are applied
  if opts.hooks and opts.hooks.on_render then
    opts.hooks.on_render(state.buf, state.filtered_items, opts)
  end

  -- Update current line highlight
  local cursor_pos = vim.api.nvim_win_get_cursor(state.win)
  if cursor_pos and cursor_pos[1] > 0 and cursor_pos[1] <= #state.filtered_items then
    M.safe_highlight_current_item(state, opts, cursor_pos[1] - 1)
  end

  -- Update selection highlights
  common.update_selection_highlights(state, opts)
end

---@param state SelectaState
---@param opts SelectaOptions
function M.update_cursor_position(state, opts)
  -- Early return if there are no items to position the cursor on
  if #state.filtered_items == 0 then
    return
  end

  local new_pos = nil

  -- Handle hierarchical results differently if configured
  local has_hierarchical_results = false
  if opts.preserve_hierarchy then
    -- Check if we have any direct matches in hierarchical mode
    for _, item in ipairs(state.filtered_items) do
      if item.is_direct_match then
        has_hierarchical_results = true
        break
      end
    end
  end

  -- Decision tree for cursor positioning:
  -- 1. If user manually navigated: respect their position
  -- 2. If we have hierarchical results with a best match: use that
  -- 3. If preserve_order is enabled and we have a best match: use that
  -- 4. Default to first item for normal searches or row 1

  if state.user_navigated then
    -- Keep current position, just ensure it's within bounds
    local cur_pos = vim.api.nvim_win_get_cursor(state.win)
    new_pos = { math.min(cur_pos[1], #state.filtered_items), 0 }
  elseif has_hierarchical_results and state.best_match_index then
    -- For hierarchical data, use calculated best match
    new_pos = { state.best_match_index, 0 }
  elseif opts.preserve_order and state.best_match_index and not state.initial_open then
    -- When preserving order but still want to highlight best match
    new_pos = { state.best_match_index, 0 }
  else
    -- Default behavior: first item or current position
    if not opts.preserve_order and not state.initial_open then
      -- Always position at top item (best match) for non-preserve_order
      new_pos = { 1, 0 }
    else
      -- Try to maintain current position or default to first
      local cur_pos = pcall(vim.api.nvim_win_get_cursor, state.win) and vim.api.nvim_win_get_cursor(state.win)[1] or 1
      new_pos = { math.min(cur_pos, #state.filtered_items), 0 }
    end
  end

  -- Safety checks: ensure position is valid
  new_pos[1] = math.max(1, math.min(new_pos[1], #state.filtered_items))

  -- Set cursor position and update highlights
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_set_cursor, state.win, new_pos)
    common.update_current_highlight(state, opts, new_pos[1] - 1) -- 0-indexed for extmarks

    -- Trigger on_move callback if configured
    if opts.on_move and not state.initial_open then
      local item = state.filtered_items[new_pos[1]]
      if item then
        opts.on_move(item)
      end
    end
  end
end

---@param state SelectaState
---@param opts SelectaOptions
function M.update_display(state, opts)
  if not state.active then
    return
  end

  local query = state:get_query_string()
  -- M.update_prompt(state, opts)
  M.update_prompt_info(state, opts, #query == 0) -- Show only if query is empty

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
      M.resize_window(state, opts)
    end

    -- Update filter info display
    M.update_filter_info(state, state.filter_metadata)

    return
  end

  if query ~= "" or not opts.initially_hidden then
    -- Call before render hook
    if opts.hooks and opts.hooks.before_render then
      opts.hooks.before_render(state.filtered_items, opts)
    end

    -- Update footer after filtered items are updated
    if opts.window.show_footer then
      M.update_footer(state, state.win, opts)
    end

    -- Resize window if needed
    if opts.window.auto_resize then
      M.resize_window(state, opts)
    end

    -- Use virtualized rendering for better performance
    M.render_visible_items(state, opts)

    -- Update filter info display
    M.update_filter_info(state, state.filter_metadata)

    -- Update cursor position
    M.update_cursor_position(state, opts)
  else
    -- Handle case when initially hidden with no query
    if vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_clear_namespace(state.buf, ns_id, 0, -1)
      vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})
      if opts.hooks and opts.hooks.on_buffer_clear then
        opts.hooks.on_buffer_clear()
      end
    end

    M.update_prompt_info(state, opts, #state.query == 0)

    -- Resize window to minimum dimensions
    if opts.window.auto_resize then
      local original_filtered_items = state.filtered_items
      state.filtered_items = {}
      M.resize_window(state, opts)
      state.filtered_items = original_filtered_items
    end
  end
end

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

-- Enhanced get_window_position function that respects relative setting
function M.get_window_position(width, row_position, opts, state_win, picker_id)
  local container = picker_id and M.get_original_dimensions(picker_id) or M.get_container_dimensions(opts, picker_id)
  local available_width = container.width
  local available_height = container.height
  local cmdheight = vim.o.cmdheight

  -- Parse the position
  local pos_info = common.parse_position(row_position)
  if not pos_info then
    return 0, 0
  end

  -- Calculate column position based on container
  local col
  if pos_info.type:find("_right$") then
    if config.right_position.fixed then
      col = math.floor(available_width * config.right_position.ratio)
    else
      col = available_width - width - 4
    end
  else
    -- Center position
    col = math.floor((available_width - width) / 2)
  end

  -- Calculate row position based on container
  local row
  if pos_info.type:match("^top") then
    row = math.floor(available_height * pos_info.ratio)
  elseif pos_info.type == "bottom" then
    row = math.floor(available_height * pos_info.ratio) - 4
  else -- center positions
    row = math.max(1, math.floor(available_height * pos_info.ratio))
  end

  return row, col
end

---Create the picker windows
---@param state SelectaState
---@param opts SelectaOptions
function M.create_windows(state, opts)
  -- Handle initially_hidden option
  if opts.initially_hidden then
    -- When initially hidden, set minimal dimensions
    state.filtered_items = {}
    state.width = opts.window.min_width or config.window.min_width
    state.height = opts.window.min_height or config.window.min_height
  end
  -- Get container dimensions to determine if we need a win parameter
  local container = M.get_original_dimensions(state.picker_id) or M.get_container_dimensions(opts, state.picker_id)

  -- Create main window config
  local win_config = {
    relative = opts.window.relative or config.window.relative,
    row = state.row + 1, -- Shift main window down by 1 to make room for prompt
    col = state.col,
    width = state.width,
    height = state.height,
    style = "minimal",
    border = get_border_with_footer(opts),
  }

  -- Add win parameter if relative is "window"
  if opts.window.relative == "win" then
    win_config.win = container.win or vim.api.nvim_get_current_win()
  end

  -- Merge any user-provided overrides
  win_config = vim.tbl_deep_extend("force", win_config, opts.window.override or {})

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
  M.create_prompt_window(state, opts)
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

return M
