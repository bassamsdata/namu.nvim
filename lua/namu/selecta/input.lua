-- Input handling functionality for selecta
local M = {}

local common = require("namu.selecta.common")
local config = require("namu.selecta.selecta_config").values
local log = require("namu.utils.logger").log

-- Pre-compute the movement keys
---@param opts SelectaOptions
---@return table<string, string[]>
local function get_movement_keys(opts)
  local movement_config = opts.movement or config.movement
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

  local current_item = state.filtered_items[cursor_pos]
  if current_item then
    local was_toggled = state:toggle_selection(current_item, opts)

    -- Only move if toggle was successful
    if was_toggled then
      local next_pos

      -- Use grouped navigation if enabled (like for diagnostics)
      if opts.grouped_navigation then
        next_pos = state:find_next_group_item(cursor_pos, direction)
      else
        -- Original logic for non-grouped items
        if direction > 0 then
          next_pos = cursor_pos < #state.filtered_items and cursor_pos + 1 or 1
        else
          next_pos = cursor_pos > 1 and cursor_pos - 1 or #state.filtered_items
        end
      end

      -- Set new cursor position
      pcall(vim.api.nvim_win_set_cursor, state.win, { next_pos, 0 })
      common.update_current_highlight(state, opts, next_pos - 1)

      -- Trigger move callback if exists
      if opts.on_move then
        local new_item = state.filtered_items[next_pos]
        if new_item then
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

  -- Find the previous selected item position
  local prev_selected_pos = nil

  if opts.grouped_navigation then
    -- For grouped navigation, look for main diagnostic items only
    for i = cursor_pos - 1, 1, -1 do
      local item = state.filtered_items[i]
      if item and item.group_type == "diagnostic_main" and state.selected[common.get_item_id(item)] then
        prev_selected_pos = i
        break
      end
    end

    -- If no selected item found before current position, wrap around to end
    if not prev_selected_pos then
      for i = #state.filtered_items, cursor_pos, -1 do
        local item = state.filtered_items[i]
        if item and item.group_type == "diagnostic_main" and state.selected[common.get_item_id(item)] then
          prev_selected_pos = i
          break
        end
      end
    end
  else
    -- Original logic for non-grouped items
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
  end

  if prev_selected_pos then
    local prev_item = state.filtered_items[prev_selected_pos]

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
      opts.on_move(prev_item)
    end

    vim.cmd("redraw")
    return true
  else
    log("No previously selected item found")
    return false
  end
end

---Select or deselect all items in the current filtered list
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

  -- Mark that we're doing a bulk selection change to preserve cursor position
  state.bulk_selection_change = true

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

  -- Clear the flag after a short delay to allow the display update to complete
  vim.schedule(function()
    state.bulk_selection_change = false
  end)
end

---Helper function to handle selection
---@param state SelectaState
---@param opts SelectaOptions
local function handle_selection(state, opts)
  if not state or not state.active then
    return
  end
  if #state.filtered_items == 0 then
    return
  end
  local ok, cursor_pos = pcall(function()
    return vim.api.nvim_win_get_cursor(state.win)[1]
  end)
  if not ok or not cursor_pos or cursor_pos < 1 or cursor_pos > #state.filtered_items then
    -- Invalid cursor position, try to use first item
    cursor_pos = #state.filtered_items > 0 and 1 or nil
  end
  if opts.multiselect and opts.multiselect.enabled then
    local selected_items = state:get_selected_items()
    if #selected_items > 0 and opts.multiselect.on_select then
      opts.multiselect.on_select(selected_items)
    elseif #selected_items == 0 and cursor_pos then
      local current = state.filtered_items[cursor_pos]
      if current and opts.on_select then
        opts.on_select(current)
      end
    end
  else
    if cursor_pos then
      local selected = state.filtered_items[cursor_pos]
      if selected and opts.on_select then
        opts.on_select(selected)
      end
    end
  end
end

local function _set_picker_keymap(prompt_buf_id, is_normal_mode_active, key_lhs, callback_fn, force_modes_list)
  local modes_to_set
  if force_modes_list then
    modes_to_set = force_modes_list
  elseif is_normal_mode_active then
    modes_to_set = { "i", "n" } -- Map for both insert and normal if normal_mode is enabled
  else
    modes_to_set = { "i" } -- Default to insert mode only
  end

  vim.keymap.set(modes_to_set, key_lhs, callback_fn, {
    buffer = prompt_buf_id,
    nowait = true,
    silent = true, -- Keep picker mappings silent by default
    desc = "Namu: " .. key_lhs,
  })
end

---Set up keymaps for the picker
---@param state SelectaState
---@param opts SelectaOptions
---@param close_picker_fn function
---@param process_query_fn function
function M.setup_keymaps(state, opts, close_picker_fn, process_query_fn)
  if not state.prompt_buf or not vim.api.nvim_buf_is_valid(state.prompt_buf) then
    return
  end
  local movement_keys = opts.movement or config.movement

  local function map_key_adapter(key_lhs, callback_fn, force_modes_list)
    _set_picker_keymap(state.prompt_buf, opts.normal_mode, key_lhs, callback_fn, force_modes_list)
  end

  local augroup_name = "NamuFocus_" .. vim.api.nvim_get_current_buf() .. "_" .. state.prompt_buf
  local augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = augroup,
    pattern = "*",
    callback = function(args)
      if args.buf ~= state.prompt_buf and args.buf ~= state.buf then
        return
      end
      vim.schedule(function()
        if not state.active then
          return
        end
        local current_win = vim.api.nvim_get_current_win()
        if current_win ~= state.win and current_win ~= state.prompt_win then
          if not state.in_custom_action then
            -- Use the new callback-aware close function for auto-close (treat as cancellation)
            common.close_picker_with_cleanup(state, opts, close_picker_fn, true) -- true = is a cancellation
          end
        end
      end)
    end,
  })

  local original_cleanup = state.cleanup
  state.cleanup = function(...)
    pcall(vim.api.nvim_del_augroup_by_name, augroup_name)
    if original_cleanup then
      return original_cleanup(...)
    end
  end

  -- Specific Normal Mode Mappings (if opts.normal_mode is true)
  if opts.normal_mode then
    for _, key in ipairs(movement_keys.next) do
      vim.keymap.set("n", key, function()
        if state.active then
          state:handle_movement(1, opts)
        end
      end, { buffer = state.prompt_buf, nowait = true, silent = true, desc = "Namu: Next" })
    end
    for _, key in ipairs(movement_keys.previous) do
      vim.keymap.set("n", key, function()
        if state.active then
          state:handle_movement(-1, opts)
        end
      end, { buffer = state.prompt_buf, nowait = true, silent = true, desc = "Namu: Previous" })
    end
    vim.keymap.set("n", "j", function()
      if state.active then
        state:handle_movement(1, opts)
      end
    end, { buffer = state.prompt_buf, nowait = true, silent = true, desc = "Namu: next" })
    vim.keymap.set("n", "k", function()
      if state.active then
        state:handle_movement(-1, opts)
      end
    end, { buffer = state.prompt_buf, nowait = true, silent = true, desc = "Namu: previous" })

    vim.keymap.set("n", "<esc>", function()
      if state.active then
        common.close_picker_with_cleanup(state, opts, close_picker_fn, true) -- true = is a cancellation
      end
    end, { buffer = state.prompt_buf, nowait = true, silent = true, desc = "Namu: Esc Close" })
  end

  -- Process movement_keys from config
  -- Previous item navigation
  for _, key_code in ipairs(movement_keys.previous) do
    local callback = function()
      if state.active then
        state:handle_movement(-1, opts)
      end
    end
    -- local key_termcodes = vim.api.nvim_replace_termcodes(key_code, true, true, true)
    -- if opts.normal_mode and key_termcodes == common.SPECIAL_KEYS.CTRL_P then
    -- _set_picker_keymap_on_buf(state.prompt_buf, opts.normal_mode, key_code, callback, { "i" })
    -- else
    _set_picker_keymap(state.prompt_buf, opts.normal_mode, key_code, callback)
    -- end
  end

  -- Next item navigation
  for _, key_code in ipairs(movement_keys.next) do
    local callback = function()
      if state.active then
        state:handle_movement(1, opts)
      end
    end
    -- if opts.normal_mode and key_termcodes == common.SPECIAL_KEYS.CTRL_N then
    --   _set_picker_keymap_on_buf(state.prompt_buf, opts.normal_mode, key_termcodes, callback, { "i" })
    -- else
    _set_picker_keymap(state.prompt_buf, opts.normal_mode, key_code, callback)
    -- end
  end

  -- Close keys
  if movement_keys.close then
    local close_callback = function()
      if state.active then
        common.close_picker_with_cleanup(state, opts, close_picker_fn, true) -- true = is a cancellation
      end
    end

    if opts.normal_mode then
      -- If normal_mode is true, map close keys (EXCEPT <Esc>) only for insert mode.
      -- Normal mode <Esc> is handled directly above.
      for _, key_code in ipairs(movement_keys.close) do
        if key_code ~= "<ESC>" then
          _set_picker_keymap(state.prompt_buf, true, key_code, close_callback, { "i" })
        end
        -- <Esc> in insert mode is intentionally NOT mapped to close_callback here
        -- when opts.normal_mode is true, allowing it to switch to normal mode.
      end
    else
      -- If not normal_mode, map all close keys (including <Esc> if present) for insert mode.
      for _, key_code in ipairs(movement_keys.close) do
        _set_picker_keymap(state.prompt_buf, false, key_code, close_callback, { "i" })
      end
    end
  end

  -- Selection
  for _, key_code in ipairs(movement_keys.select) do
    _set_picker_keymap(state.prompt_buf, opts.normal_mode, key_code, function()
      if not state.active then
        return
      end
      if #state.filtered_items == 0 then
        common.close_picker_with_cleanup(state, opts, close_picker_fn, true) -- true = is a cancellation (no items to select)
      else
        M.handle_selection(state, opts)
        -- Use the new callback-aware close function for selection
        common.close_picker_with_cleanup(state, opts, close_picker_fn, false) -- false = not a cancellation (successful selection)
      end
    end)
  end

  if opts.multiselect and opts.multiselect.enabled then
    M.setup_multiselect_keymaps(state, opts, close_picker_fn, process_query_fn, map_key_adapter)
  end
  if opts.custom_keymaps and type(opts.custom_keymaps) == "table" then
    M.setup_custom_keymaps(state, opts, close_picker_fn, map_key_adapter)
  end
end

---Setup multiselect keymaps
---@param state SelectaState
---@param opts SelectaOptions
---@param close_picker_fn function Function to close the picker
---@param process_query_fn function Function to process queries
---@param map_key function Helper function to map keys
---@return nil
function M.setup_multiselect_keymaps(state, opts, close_picker_fn, process_query_fn, map_key)
  local multiselect_keys = opts.multiselect.keymaps or config.multiselect.keymaps

  -- Toggle selection
  if multiselect_keys.toggle then
    map_key(multiselect_keys.toggle, function()
      handle_toggle(state, opts, 1)
    end)
  end

  -- Untoggle selection
  if multiselect_keys.untoggle then
    map_key(multiselect_keys.untoggle, function()
      handle_untoggle(state, opts)
    end)
  end

  -- Select all
  if multiselect_keys.select_all then
    map_key(multiselect_keys.select_all, function()
      bulk_selection(state, opts, true)
      process_query_fn(state, opts)
    end)
  end

  -- Clear all selections
  if multiselect_keys.clear_all then
    map_key(multiselect_keys.clear_all, function()
      bulk_selection(state, opts, false)
      process_query_fn(state, opts)
    end)
  end
end

---Setup custom keymaps defined by the user
---@param state SelectaState
---@param opts SelectaOptions
---@param close_picker_fn function Function to close the picker
---@param map_key function Helper function to map keys
---@return nil
function M.setup_custom_keymaps(state, opts, close_picker_fn, map_key)
  for _, action in pairs(opts.custom_keymaps) do
    if action and action.keys then
      local keys = type(action.keys) == "string" and { action.keys } or action.keys

      for _, key_raw in ipairs(keys) do
        -- We use the raw keymap.set for custom keymaps since they might need special handling
        local custom_handler = function()
          if not action.handler then
            return
          end

          -- Mark that we're in a custom action to prevent auto-closing
          state.in_custom_action = true

          local current_pos = vim.api.nvim_win_get_cursor(state.win)[1]
          local current_item = state.filtered_items[current_pos]
          local should_close

          if opts.multiselect and opts.multiselect.enabled and state.selected_count > 0 then
            local selected_items = state:get_selected_items()
            should_close = action.handler(selected_items, state)
          else
            should_close = action.handler(current_item, state)
          end
          state.in_custom_action = false
          if should_close then
            -- Use the new callback-aware close function
            common.close_picker_with_cleanup(state, opts, close_picker_fn, false) -- false = not a cancellation
          end
        end

        map_key(key_raw, custom_handler)
      end
    end
  end
end

function M.setup_sidebar_keymaps(state, opts)
  -- Close on 'q'
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
      if opts.on_move then
        opts.on_cancel()
      end
    end
  end, { buffer = state.buf, silent = true })

  -- Navigation (j/k work automatically as normal buffer)
  -- But we need to trigger on_move callback
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = state.buf,
    callback = function()
      local cursor_pos = vim.api.nvim_win_get_cursor(state.win)[1]
      local item = state.filtered_items[cursor_pos]
      if item and opts.on_move then
        opts.on_move(item)
      end
      common.update_current_highlight(state, opts, cursor_pos - 1)
    end,
  })

  -- Enter to select
  vim.keymap.set("n", "<CR>", function()
    local cursor_pos = vim.api.nvim_win_get_cursor(state.win)[1]
    local item = state.filtered_items[cursor_pos]
    if item and opts.on_select then
      opts.on_select(item)
    end
  end, { buffer = state.buf, silent = true })

  -- Reuse custom keymaps (yank, delete, split, quickfix, etc.)
  if opts.custom_keymaps then
    for _, action in pairs(opts.custom_keymaps) do
      if action and action.keys then
        local keys = type(action.keys) == "string" and { action.keys } or action.keys
        for _, key in ipairs(keys) do
          vim.keymap.set("n", key, function()
            local cursor_pos = vim.api.nvim_win_get_cursor(state.win)[1]
            local current_item = state.filtered_items[cursor_pos]
            if action.handler then
              action.handler(current_item, state)
            end
          end, { buffer = state.buf, silent = true })
        end
      end
    end
  end
end

-- Make bulk_selection available to other modules
M.bulk_selection = bulk_selection
M.get_movement_keys = get_movement_keys
M.handle_selection = handle_selection
M.handle_toggle = handle_toggle
M.handle_untoggle = handle_untoggle

return M
