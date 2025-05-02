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
  -- Note: We'll use the main module's calculate_window_size function later
  local row, col = 0, 0
  -- Note: We'll use the main module's get_window_position function later
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

---Handle special key inputs
---@param key string The key that was pressed
---@param opts SelectaOptions Configuration options
---@return boolean was_handled Whether the key was handled
function StateManager:handle_special_key(key, opts)
  -- Handle basic navigation
  if key == common.SPECIAL_KEYS.LEFT then
    self:move_cursor(-1)
    return true
  elseif key == common.SPECIAL_KEYS.RIGHT then
    self:move_cursor(1)
    return true
  elseif key == common.SPECIAL_KEYS.BS then
    if self:backspace() then
      -- Note: process_query will be called by the main module
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
  common.update_current_highlight(self, opts, new_pos - 1) -- 0-indexed for extmarks

  if opts.on_move then
    opts.on_move(self.filtered_items[new_pos])
  end

  -- Mark that user has manually moved cursor
  self.cursor_moved = true
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
  -- Clear loading state
  if self.prompt_buf and vim.api.nvim_buf_is_valid(self.prompt_buf) then
    vim.api.nvim_buf_clear_namespace(self.prompt_buf, common.loading_ns_id, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.prompt_buf, common.prompt_info_ns, 0, -1)
  end

  -- Clean up timer if it exists
  if self._cleanup_timer then
    self._cleanup_timer()
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

-- Export the StateManager
M.StateManager = StateManager

return M
