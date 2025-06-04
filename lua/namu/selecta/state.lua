-- State management for selecta

local M = {}
local common = require("namu.selecta.common")

---@class SelectaState
local StateManager = {}
StateManager.__index = StateManager

---Create a new picker state
---@param items SelectaItem[] List of items to display
---@param opts SelectaOptions Configuration options
---@return SelectaState
function StateManager.new(items, opts)
  local initial_width, initial_height = 0, 0
  -- NOTE: We'll use the main module's calculate_window_size function later
  -- We'll use the main module's get_window_position function later
  local row, col = 0, 0
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
    query_string = "",
    cursor_pos = 0,
    query_changed = nil,
    -- UI state
    active = true,
    initial_open = true,
    best_match_index = nil,
    user_navigated = false,
    -- Mode state
    normal_mode = opts.normal_mode or false,
    current_mode = "insert",
    -- Async state
    is_loading = false,
    last_query = nil,
    current_request_id = nil,
    loading_extmark_id = nil,
    last_request_time = nil,
    original_window = vim.api.nvim_get_current_win(),
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

---Update query from buffer content
---@return boolean changed Whether the query was changed
function StateManager:update_query_from_buffer()
  if not self.prompt_buf or not vim.api.nvim_buf_is_valid(self.prompt_buf) then
    return false
  end

  -- Get buffer content
  local lines = vim.api.nvim_buf_get_lines(self.prompt_buf, 0, 1, false)
  local new_query = lines[1] or ""

  -- Update the query string
  local changed = new_query ~= self.query_string
  self.query_string = new_query

  -- Update the character array for compatibility
  self.query = {}
  for i = 1, #new_query do
    self.query[i] = new_query:sub(i, i)
  end

  -- Update cursor position based on buffer cursor
  if vim.api.nvim_win_is_valid(self.prompt_win) then
    local cursor = vim.api.nvim_win_get_cursor(self.prompt_win)
    -- The cursor position should match where we are in the buffer
    self.cursor_pos = cursor[2] + 1
  else
    -- Default to end of query if window is not valid
    self.cursor_pos = #self.query + 1
  end

  if changed then
    self.user_navigated = false
    self.initial_open = false
  end
  return changed
end

---Handle cursor position after filtering results
---@param opts SelectaOptions Configuration options
---@return nil
---FIX: probably we don't need this fucntion
function StateManager:handle_post_filter_cursor(opts)
  if #self.filtered_items == 0 then
    return
  end

  -- FIX: the code here is a little problematic
  -- it looks like the user_navigated is always false until we do the handle_movement when trigger the movement manually
  -- why this cursor_pos logic is sometimes not correct so it falls back to 1
  -- not sure what the logic is here do we need to check if user_navigated?
  local cursor_pos
  -- Choose position based on best match, prior position, or first item
  if self.best_match_index and self.user_navigated then
    cursor_pos = self.best_match_index
  else
    -- Try to maintain current position or use first item
    local current_pos = pcall(vim.api.nvim_win_get_cursor, self.win) and vim.api.nvim_win_get_cursor(self.win)[1] or 1
    cursor_pos = math.min(current_pos, #self.filtered_items)
  end

  -- Set cursor and update highlights
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_set_cursor, self.win, { cursor_pos, 0 })
    common.update_current_highlight(self, opts, cursor_pos - 1)

    -- Trigger on_move callback
    if opts.on_move then
      local item = self.filtered_items[cursor_pos]
      if item then
        opts.on_move(item)
      end
    end
  end
end

---Get the current query as a string
---@return string
function StateManager:get_query_string()
  return self.query_string
end

function StateManager:find_next_group_item(current_pos, direction, opts)
  local total_items = #self.filtered_items
  local new_pos = current_pos

  -- For diagnostics, we need to move by 2 lines (since each diagnostic takes 2 lines)
  if direction > 0 then
    -- Moving down
    new_pos = current_pos + 2
    if new_pos > total_items then
      new_pos = 1 -- Wrap to first item
    end
  else
    -- Moving up
    new_pos = current_pos - 2
    if new_pos < 1 then
      -- Find the last diagnostic (should be an odd-numbered line)
      new_pos = total_items % 2 == 1 and total_items or total_items - 1
    end
  end

  return new_pos
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

  local new_pos

  -- Handle grouped navigation for multi-line items
  if opts.grouped_navigation then
    new_pos = self:find_next_group_item(current_pos, direction, opts)
  else
    -- Simple cycling calculation
    new_pos = current_pos + direction
    if new_pos < 1 then
      new_pos = total_items
    elseif new_pos > total_items then
      new_pos = 1
    end
  end

  pcall(vim.api.nvim_win_set_cursor, self.win, { new_pos, 0 })
  common.update_current_highlight(self, opts, new_pos - 1) -- 0-indexed for extmarks

  if opts.on_move then
    opts.on_move(self.filtered_items[new_pos])
  end

  -- Mark that user has manually moved cursor
  self.user_navigated = true
  self.initial_open = false

  return true
end

---Toggle selection of the current item
---@param item SelectaItem The item to toggle
---@param opts SelectaOptions The current options
---@return boolean Whether the selection was changed
function StateManager:toggle_selection(item, opts)
  if not opts.multiselect or not opts.multiselect.enabled then
    return false
  end

  local item_id = common.get_item_id(item)
  local changed = false

  if self.selected[item_id] then
    self.selected[item_id] = nil
    self.selected_count = self.selected_count - 1
    changed = true
  else
    if opts.multiselect.max_items and self.selected_count >= opts.multiselect.max_items then
      return false
    end
    self.selected[item_id] = true
    self.selected_count = self.selected_count + 1
    changed = true
  end

  -- If selection state changed, update all selection highlights
  if changed then
    common.update_selection_highlights(self, opts)
  end

  return changed
end

---Get the list of selected items
---@return SelectaItem[]
function StateManager:get_selected_items()
  local result = {}
  for _, item in ipairs(self.items) do
    if self.selected[common.get_item_id(item)] then
      table.insert(result, item)
    end
  end
  return result
end

---Clean up resources when closing the picker
function StateManager:cleanup()
  -- Clear all highlights in all namespaces
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_clear_namespace(self.buf, common.ns_id, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, common.current_selection_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, common.selection_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, common.filter_info_ns, 0, -1)
  end
  -- Clear loading state
  if self.prompt_buf and vim.api.nvim_buf_is_valid(self.prompt_buf) then
    vim.api.nvim_buf_clear_namespace(self.prompt_buf, common.loading_ns_id, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.prompt_buf, common.prompt_info_ns, 0, -1)
  end

  -- Clean up timer if it exists
  if self._cleanup_timer then
    self._cleanup_timer()
  end

  -- vim.cmd("noautocmd")
  -- Close windows
  if self.prompt_win and vim.api.nvim_win_is_valid(self.prompt_win) then
    vim.api.nvim_win_close(self.prompt_win, true)
  end

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  -- vim.cmd("doautocmd WinEnter")

  if self.original_buf and vim.api.nvim_buf_is_valid(self.original_buf) then
    vim.api.nvim_buf_clear_namespace(self.original_buf, common.ns_id, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.original_buf, common.current_selection_ns, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.original_buf, common.selection_ns, 0, -1)
  end

  -- Mark as inactive
  self.active = false
end

-- Export the StateManager
M.StateManager = StateManager

return M
