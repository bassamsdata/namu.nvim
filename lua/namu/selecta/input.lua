-- Input handling functionality for selecta
local M = {}

local common = require("namu.selecta.common")
local logger = require("namu.utils.logger")

-- Local references to reduce table lookups
local SPECIAL_KEYS = common.SPECIAL_KEYS
local log = common.log

-- Pre-compute the movement keys
---@param opts SelectaOptions
---@return table<string, string[]>
local function get_movement_keys(opts)
  local movement_config = opts.movement or {}
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
      if action == "delete_word" or action == "clear_line" then
        print("Action: " .. action .. ", Mapping: " .. vim.inspect(mapping))
        if vim.tbl_isempty(mapping) then
          print("Warning: " .. action .. " has empty mapping")
        end
      end
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
    table.insert(keys.next, vim.api.nvim_replace_termcodes(movement_config.alternative_next, true, true, true))
  end
  if movement_config.alternative_previous then
    table.insert(keys.previous, vim.api.nvim_replace_termcodes(movement_config.alternative_previous, true, true, true))
  end

  return keys
end

---Handle item selection toggle
---@param state SelectaState
---@param opts SelectaOptions
---@param direction number 1 for forward, -1 for backward
---@return boolean handled Whether the toggle was handled
local function handle_toggle(state, opts, direction)
  local cursor_pos = vim.api.nvim_win_get_cursor(state.win)[1]
  log(string.format("Toggle pressed - cursor_pos: %d, total items: %d", cursor_pos, #state.filtered_items))

  local current_item = state.filtered_items[cursor_pos]
  if current_item then
    log(string.format("Current item: %s", current_item.text))
    local was_toggled = state:toggle_selection(current_item, opts)
    log(string.format("Item toggled: %s", tostring(was_toggled)))

    -- Only move if toggle was successful
    if was_toggled then
      -- main module will handle process_query

      -- Calculate next position with wrapping
      local next_pos
      if direction > 0 then
        next_pos = cursor_pos < #state.filtered_items and cursor_pos + 1 or 1
      else
        next_pos = cursor_pos > 1 and cursor_pos - 1 or #state.filtered_items
      end

      log(string.format("Moving to position: %d", next_pos))

      -- Set new cursor position
      pcall(vim.api.nvim_win_set_cursor, state.win, { next_pos, 0 })
      common.update_current_highlight(state, opts, next_pos - 1)

      -- Trigger move callback if exists
      if opts.on_move then
        local new_item = state.filtered_items[next_pos]
        if new_item then
          log(string.format("Triggering on_move with item: %s", new_item.text))
          opts.on_move(new_item)
        end
      end

      vim.cmd("redraw")
    end

    return true
  end

  log("No current item found at cursor position")
  return false
end

---Handle item unselection
---@param state SelectaState
---@param opts SelectaOptions
---@return boolean handled Whether the untoggle was handled
local function handle_untoggle(state, opts)
  local cursor_pos = vim.api.nvim_win_get_cursor(state.win)[1]
  log(string.format("Untoggle pressed - current cursor_pos: %d", cursor_pos))

  -- Find the previous selected item position
  local prev_selected_pos = nil
  for i = cursor_pos - 1, 1, -1 do
    local item = state.filtered_items[i]
    if item and state.selected[common.get_item_id(item)] then
      prev_selected_pos = i
      break
    end
  end

  -- If no selected item found before current position, wrap around to end
  if not prev_selected_pos then
    for i = #state.filtered_items, cursor_pos, -1 do
      local item = state.filtered_items[i]
      if item and state.selected[common.get_item_id(item)] then
        prev_selected_pos = i
        break
      end
    end
  end

  log(string.format("Previous selected item position: %s", prev_selected_pos or "none found"))

  if prev_selected_pos then
    local prev_item = state.filtered_items[prev_selected_pos]
    log(string.format("Moving to and unselecting item: %s at position %d", prev_item.text, prev_selected_pos))

    -- Move to the selected item
    pcall(vim.api.nvim_win_set_cursor, state.win, { prev_selected_pos, 0 })

    -- Unselect the item
    local item_id = common.get_item_id(prev_item)
    state.selected[item_id] = nil
    state.selected_count = state.selected_count - 1

    -- Update selection highlights
    common.update_selection_highlights(state, opts)

    -- Ensure cursor stays at the correct position
    pcall(vim.api.nvim_win_set_cursor, state.win, { prev_selected_pos, 0 })
    common.update_current_highlight(state, opts, prev_selected_pos - 1)

    -- Trigger move callback if exists
    if opts.on_move then
      log(string.format("Triggering on_move with item: %s", prev_item.text))
      opts.on_move(prev_item)
    end

    vim.cmd("redraw")
    return true
  else
    log("No previously selected item found")
    return false
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
      state.selected[common.get_item_id(item)] = true
    end
    state.selected_count = new_count
  end

  -- Update all selection highlights after bulk selection change
  common.update_selection_highlights(state, opts)
end

-- Helper function to handle custom keymaps
local function handle_custom_keymaps(state, char_key, opts, close_picker_fn)
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
                    -- Main module will handle closing
                    close_picker_fn(state)
                    return true
                  end
                else
                  -- Handle single item case
                  local should_close = action.handler(selected, state)
                  if should_close == false then
                    -- Main module will handle closing
                    close_picker_fn(state)
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

---Helper function to handle multiselect keymaps
---@param state SelectaState
---@param char_key string
---@param opts SelectaOptions
---@param process_query_fn function
---@return boolean handled
local function handle_multiselect_keymaps(state, char_key, opts, process_query_fn)
  if opts.multiselect and opts.multiselect.enabled then
    local multiselect_keys = opts.multiselect.keymaps or common.config.multiselect.keymaps
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
      process_query_fn(state, opts)
      return true
    elseif char_key == vim.api.nvim_replace_termcodes(multiselect_keys.clear_all, true, true, true) then
      bulk_selection(state, opts, false)
      process_query_fn(state, opts)
      return true
    end
  end
  return false
end

---Helper function to handle selection
---@param state SelectaState
---@param opts SelectaOptions
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

-- Delete last word
local function delete_last_word(state)
  -- Legacy method for compatibility
  if state.delete_word then
    state:delete_word()
    return
  end
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
  for _ = word_start, last_char_pos do
    table.remove(state.query, word_start)
  end
  -- Update cursor position
  state.cursor_pos = word_start
  state.initial_open = false
  state.cursor_moved = false
end

---Handle character input in the picker
---@param state SelectaState The current state of the picker
---@param char string|number The character input
---@param opts SelectaOptions The options for the picker
---@param process_query_fn function Function to process query changes
---@param close_picker_fn function Function to close the picker
---@return nil
function M.handle_char(state, char, opts, process_query_fn, close_picker_fn)
  if not state.active then
    return nil
  end
  local char_key = type(char) == "number" and vim.fn.nr2char(char) or char
  local movement_keys = get_movement_keys(opts)
  -- Handle custom keymaps first
  if handle_custom_keymaps(state, char_key, opts, close_picker_fn) then
    if state.active == false then
      return nil
    end
    process_query_fn(state, opts)
    return nil
  end
  -- Handle multiselect keymaps
  if handle_multiselect_keymaps(state, char_key, opts, process_query_fn) then
    return nil
  end
  -- Handle special keys using StateManager methods when possible
  if
    state.handle_special_key
    and (char_key == SPECIAL_KEYS.LEFT or char_key == SPECIAL_KEYS.RIGHT or char_key == SPECIAL_KEYS.BS)
  then
    if state:handle_special_key(char_key, opts) then
      process_query_fn(state, opts)
      return nil
    end
  end
  -- Handle movement keys
  if vim.tbl_contains(movement_keys.previous, char_key) then
    if state.handle_movement then
      state:handle_movement(-1, opts)
    else
      state.cursor_moved = true
      state.initial_open = false
      -- Legacy method for compatibility
      -- handle_movement(state, -1, opts)
    end
    return nil
  elseif vim.tbl_contains(movement_keys.next, char_key) then
    if state.handle_movement then
      state:handle_movement(1, opts)
    else
      state.cursor_moved = true
      state.initial_open = false
      -- Legacy method for compatibility
      -- handle_movement(state, 1, opts)
    end
    return nil
  elseif vim.tbl_contains(movement_keys.close, char_key) then
    if opts.on_cancel then
      opts.on_cancel()
    end
    close_picker_fn(state)
    return nil
  elseif vim.tbl_contains(movement_keys.select, char_key) then
    handle_selection(state, opts)
    close_picker_fn(state)
    return nil
  elseif vim.tbl_contains(movement_keys.delete_word, char_key) then
    print("state.delete_word exists: " .. tostring(state.delete_word ~= nil))
    if state.delete_word then
      if state:delete_word() then
        process_query_fn(state, opts)
      end
    else
      -- delete_last_word(state)
      state:delete_word()
      process_query_fn(state, opts)
    end
    return nil
  elseif vim.tbl_contains(movement_keys.clear_line, char_key) then
    print("state.clear_query exists: " .. tostring(state.clear_query ~= nil))
    if state.clear_query then
      state:clear_query()
    else
      state.query = {}
      state.cursor_pos = 1
      state.initial_open = false
      state.cursor_moved = false
    end
    process_query_fn(state, opts)
    return nil
  elseif char_key == SPECIAL_KEYS.MOUSE and vim.v.mouse_win ~= state.win and vim.v.mouse_win ~= state.prompt_win then
    if opts.on_cancel then
      opts.on_cancel()
    end
    close_picker_fn(state)
    return nil
  elseif char_key == SPECIAL_KEYS.LEFT and not state.handle_special_key then
    state:move_cursor(-1)
  elseif char_key == SPECIAL_KEYS.RIGHT and not state.handle_special_key then
    state:move_cursor(1)
  elseif char_key == SPECIAL_KEYS.BS and not state.handle_special_key then
    if state:backspace() then
      process_query_fn(state, opts)
    end
  else
    -- Handle regular character input
    if state:update_query(char) then
      process_query_fn(state, opts)
    end
  end

  return nil
end

-- Make bulk_selection available to other modules
M.bulk_selection = bulk_selection
M.get_movement_keys = get_movement_keys
M.handle_selection = handle_selection
M.handle_toggle = handle_toggle
M.handle_untoggle = handle_untoggle

return M
