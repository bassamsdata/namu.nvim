--[[
Copyright (c) 2025 Bassam Data
This software is licensed under the MIT License.
You must include this notice when using or distributing this code.
Author: Bassam Data
]]

-- Namu Outline V2 Module
-- Same picker as symbols but in a split window with follow cursor support

---@class NamuOutlineModule
---@field open fun(opts?: NamuOutlineOpenOptions) Open the outline
---@field close fun() Close the outline
---@field toggle fun() Toggle the outline
---@field focus fun() Focus the outline window
---@field focus_code fun() Focus the code window
---@field is_open fun(): boolean Check if outline is open
---@field refresh fun() Refresh the outline content
---@field next fun() Move to the next symbol spatially
---@field prev fun() Move to the previous symbol spatially
---@field setup fun(opts?: NamuOutlineConfig) Setup the module

local M = {}

local config_manager = require("namu.core.config_manager")
local api = vim.api
local logger = require("namu.utils.logger")

---@class NamuOutlineOpenOptions
---@field position? "left"|"right"|"above"|"below" Position of the outline split
---@field size? number Size of the split window
---@field close_on_select? boolean Whether to close after selection
---@field normal_mode? boolean Whether to use normal mode in picker
---@field title? string Title for the outline window
---@field movement? SelectaMovementConfig Movement key configuration

-- Module state
---@type NamuOutlineState
local state = {
  picker_state = nil, -- Reference to the selecta picker state
  module_state = nil, -- Reference to the symbol_utils module state (has preview_ns)
  original_win = nil,
  original_buf = nil,
  outline_win = nil,
  outline_buf = nil,
  prompt_win = nil,
  prompt_buf = nil,
  autocmd_group = nil,
  items = nil, -- Cache of symbol items for follow_cursor
  is_open = false,
  is_refreshing = false, -- Flag to prevent recursive refresh
  last_changedtick = nil, -- Track buffer changes
  symbol_source = nil, -- Track whether symbols came from "lsp" or "treesitter"
  fetch_buffer = nil, -- Track which buffer we're fetching symbols for
  -- Display options state (toggled via keymaps)
  show_lines = false, -- Show [N lines] annotations
  show_usages = false, -- Show [N usages] annotations
  preview_on_move = true, -- Preview symbol on cursor movement
  usages_fetched = false, -- Whether usage counts have been fetched
}

-- Flag to track if config has been resolved
local config_resolved = false
local config = {}

---Resolve config from config manager
---@return nil
local function resolve_config()
  if not config_resolved then
    config = config_manager.get_config("namu_outline")
    config_resolved = true
    -- Initialize display state from config
    state.show_lines = config.show_lines or false
    state.show_usages = config.show_usages or false
    state.preview_on_move = config.preview and config.preview.highlight_on_move ~= false or true
  end
end

---Refresh the display after toggling display options
---@return nil
local function refresh_display()
  if not state.is_open or not state.picker_state or not state.picker_state.active then
    return
  end

  local selecta = require("namu.selecta.selecta")
  local ui = require("namu.selecta.ui")

  -- Update the formatter in opts to reflect new display state
  if state.picker_state.original_opts then
    state.picker_state.original_opts.show_lines = state.show_lines
    state.picker_state.original_opts.show_usages = state.show_usages
  end

  -- Re-render the display
  if state.items and #state.items > 0 then
    ui.update_display(state.picker_state, state.picker_state.original_opts)
  end
end

---Fetch usage counts for all symbols via LSP references
---@param callback? fun() Optional callback when complete
local function fetch_usages(callback)
  if not state.items or #state.items == 0 or not state.original_buf then
    if callback then
      callback()
    end
    return
  end

  local lsp = require("namu.namu_symbols.lsp")

  -- Check if LSP supports references
  if not lsp.has_capability("referencesProvider", state.original_buf) then
    vim.notify("LSP does not support references for this buffer", vim.log.levels.WARN)
    if callback then
      callback()
    end
    return
  end

  vim.notify("Fetching usage counts...", vim.log.levels.INFO)

  lsp.fetch_all_references_counts(state.original_buf, state.items, function(index, count)
    -- Update the item with usage count
    if state.items[index] and state.items[index].value then
      state.items[index].value.usage_count = count
    end
  end, function()
    state.usages_fetched = true
    vim.notify("Usage counts fetched", vim.log.levels.INFO)
    refresh_display()
    if callback then
      callback()
    end
  end)
end

---Toggle show_lines display option
function M.toggle_lines()
  state.show_lines = not state.show_lines
  vim.notify("Show lines: " .. (state.show_lines and "ON" or "OFF"), vim.log.levels.INFO)
  refresh_display()
end

---Toggle show_usages display option
function M.toggle_usages()
  state.show_usages = not state.show_usages
  vim.notify("Show usages: " .. (state.show_usages and "ON" or "OFF"), vim.log.levels.INFO)

  -- Fetch usages if turning on and not yet fetched
  if state.show_usages and not state.usages_fetched then
    fetch_usages()
  else
    refresh_display()
  end
end

---Toggle preview on move option
function M.toggle_preview()
  state.preview_on_move = not state.preview_on_move
  vim.notify("Preview on move: " .. (state.preview_on_move and "ON" or "OFF"), vim.log.levels.INFO)

  -- Update the original_opts so on_move respects the new setting
  if state.picker_state and state.picker_state.original_opts then
    if not state.picker_state.original_opts.preview then
      state.picker_state.original_opts.preview = {}
    end
    state.picker_state.original_opts.preview.highlight_on_move = state.preview_on_move
  end
end

---Find the index of the symbol containing the cursor position
---@param items table[] List of symbol items
---@param cursor_line number Current cursor line (1-indexed)
---@param cursor_col number Current cursor column (1-indexed)
---@return number|nil index The index of the containing symbol
local function find_containing_symbol_index(items, cursor_line, cursor_col)
  if not items or #items == 0 then
    return nil
  end

  local best_match_index = nil
  local smallest_area = math.huge

  for i, item in ipairs(items) do
    local symbol = item.value
    if not symbol or not symbol.lnum or not symbol.end_lnum then
      goto continue
    end

    -- Check if cursor is within symbol range
    local in_range = cursor_line >= symbol.lnum and cursor_line <= symbol.end_lnum

    -- More precise check for single-line symbols
    if in_range and symbol.lnum == symbol.end_lnum then
      in_range = cursor_col >= (symbol.col or 1) and cursor_col <= (symbol.end_col or 999)
    end

    if in_range then
      -- Calculate area to find most specific (smallest) symbol
      local area = (symbol.end_lnum - symbol.lnum + 1) * 1000 + ((symbol.end_col or 0) - (symbol.col or 0))
      if area < smallest_area then
        smallest_area = area
        best_match_index = i
      end
    end

    ::continue::
  end

  return best_match_index
end

---Update the outline cursor to match the code cursor position
---@return nil
local function update_outline_cursor()
  logger.log("[DEBUG] outline: update_outline_cursor called", "DEBUG")

  if not state.is_open then
    logger.log("[DEBUG] outline: not open, returning", "DEBUG")
    return
  end

  if not state.picker_state then
    logger.log("[DEBUG] outline: no picker_state, returning", "DEBUG")
    return
  end

  if not state.picker_state.active then
    logger.log("[DEBUG] outline: picker_state not active, returning", "DEBUG")
    return
  end

  if not state.outline_win or not api.nvim_win_is_valid(state.outline_win) then
    logger.log("[DEBUG] outline: outline_win invalid, returning", "DEBUG")
    return
  end

  if not state.original_win or not api.nvim_win_is_valid(state.original_win) then
    logger.log("[DEBUG] outline: original_win invalid, returning", "DEBUG")
    return
  end

  -- Only update if we're in the original window
  local current_win = api.nvim_get_current_win()
  if current_win ~= state.original_win then
    logger.log("[DEBUG] outline: not in original_win, returning", "DEBUG")
    return
  end

  -- Get cursor position in the code buffer
  local cursor = api.nvim_win_get_cursor(state.original_win)
  local cursor_line, cursor_col = cursor[1], cursor[2] + 1
  logger.log("[DEBUG] outline: cursor at line=" .. cursor_line .. ", col=" .. cursor_col, "DEBUG")

  -- Find the containing symbol
  local items = state.picker_state.filtered_items or state.items
  logger.log("[DEBUG] outline: searching in " .. tostring(items and #items or 0) .. " items", "DEBUG")
  local symbol_index = find_containing_symbol_index(items, cursor_line, cursor_col)

  if symbol_index then
    logger.log("[DEBUG] outline: found symbol at index " .. symbol_index, "DEBUG")
    -- Update the outline cursor position
    api.nvim_win_call(state.outline_win, function()
      pcall(api.nvim_win_set_cursor, state.outline_win, { symbol_index, 0 })

      -- Update the highlight
      local common = require("namu.selecta.common")
      common.update_current_highlight(state.picker_state, state.picker_state.original_opts, symbol_index - 1)
    end)
  else
    logger.log("[DEBUG] outline: no symbol found for cursor position", "DEBUG")
  end
end

---Setup autocmds for follow cursor feature
---@return nil
local function setup_follow_cursor_autocmds()
  logger.log("[DEBUG] outline: setup_follow_cursor_autocmds called", "DEBUG")

  if state.autocmd_group then
    pcall(api.nvim_del_augroup_by_id, state.autocmd_group)
  end

  state.autocmd_group = api.nvim_create_augroup("NamuOutlineFollowCursor", { clear = true })
  logger.log("[DEBUG] outline: created augroup, original_buf=" .. tostring(state.original_buf), "DEBUG")

  -- Update outline when cursor moves in the original buffer
  if config.follow_cursor ~= false then
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = state.autocmd_group,
      callback = function(args)
        if args.buf == state.original_buf then
          -- Debounce using vim.schedule to avoid too frequent updates
          vim.schedule(update_outline_cursor)
        end
      end,
      desc = "Update outline cursor on code cursor movement",
    })

    -- Refresh outline when buffer content changes (using changedtick to prevent flicker)
    api.nvim_create_autocmd({ "TextChanged" }, {
      group = state.autocmd_group,
      callback = function(args)
        if args.buf == state.original_buf then
          local current_changedtick = vim.b[state.original_buf].changedtick
          if current_changedtick and current_changedtick ~= state.last_changedtick then
            state.last_changedtick = current_changedtick
            -- Debounce refresh to avoid too frequent updates during typing
            vim.schedule(function()
              if state.is_open and not state.is_refreshing then
                M.refresh()
              end
            end)
          end
        end
      end,
      desc = "Refresh outline when buffer content changes",
    })
  end

  -- Clear preview highlights when focus leaves to a non-picker, non-original window
  api.nvim_create_autocmd("WinLeave", {
    group = state.autocmd_group,
    callback = function(args)
      -- Only care about leaving the outline or prompt windows
      if args.buf ~= state.outline_buf and state.picker_state and args.buf ~= state.picker_state.prompt_buf then
        return
      end

      vim.schedule(function()
        if not state.is_open or not state.picker_state then
          return
        end

        local current_win = api.nvim_get_current_win()
        -- If we're still in picker windows or original window, don't clear
        if
          current_win == state.outline_win
          or (state.picker_state.prompt_win and current_win == state.picker_state.prompt_win)
          or current_win == state.original_win
        then
          return
        end

        -- Clear preview highlights when focus goes elsewhere
        logger.log("[DEBUG] outline: WinLeave - clearing preview highlights", "DEBUG")
        local ui = require("namu.namu_symbols.ui")
        if state.module_state and state.module_state.preview_ns then
          ui.clear_preview_highlight(state.original_win, state.module_state.preview_ns, state.module_state)
        end
      end)
    end,
    desc = "Clear preview highlights when leaving outline windows",
  })

  -- Also handle when user presses Esc to go to code buffer - clear highlights
  api.nvim_create_autocmd("WinEnter", {
    group = state.autocmd_group,
    callback = function()
      local current_win = api.nvim_get_current_win()
      -- When entering the original window, clear any preview highlights
      if current_win == state.original_win and state.is_open then
        vim.schedule(function()
          if state.module_state and state.module_state.preview_ns then
            local ui = require("namu.namu_symbols.ui")
            ui.clear_preview_highlight(state.original_win, state.module_state.preview_ns, state.module_state)
          end
        end)
      end
    end,
    desc = "Clear preview highlights when entering original window",
  })

  -- Clean up when outline window or prompt window is closed
  api.nvim_create_autocmd("WinClosed", {
    group = state.autocmd_group,
    callback = function(args)
      -- Don't trigger close if we're in the middle of a refresh
      if state.is_refreshing then
        return
      end
      local closed_win = tonumber(args.match)
      -- Handle both outline window and prompt window closure
      if closed_win == state.outline_win or closed_win == state.prompt_win then
        M.close()
      end
    end,
    desc = "Clean up outline state when window is closed",
  })

  -- Clean up when original buffer is deleted
  api.nvim_create_autocmd("BufDelete", {
    group = state.autocmd_group,
    callback = function(args)
      if args.buf == state.original_buf then
        M.close()
      end
    end,
    desc = "Close outline when original buffer is deleted",
  })

  -- Refresh outline when buffer changes (e.g., switching to different file)
  api.nvim_create_autocmd("BufEnter", {
    group = state.autocmd_group,
    callback = function(args)
      -- Only trigger if we're entering the original window with a different buffer
      local current_win = api.nvim_get_current_win()
      logger.log(
        "[DEBUG] outline: BufEnter - current_win="
          .. tostring(current_win)
          .. ", original_win="
          .. tostring(state.original_win)
          .. ", args.buf="
          .. tostring(args.buf)
          .. ", original_buf="
          .. tostring(state.original_buf),
        "DEBUG"
      )
      if current_win == state.original_win and args.buf ~= state.original_buf then
        local new_buf = args.buf
        logger.log(
          "[DEBUG] outline: BufEnter - buffer different, new_buf="
            .. tostring(new_buf)
            .. ", buftype="
            .. tostring(vim.bo[new_buf].buftype)
            .. ", is_refreshing="
            .. tostring(state.is_refreshing),
          "DEBUG"
        )
        -- Only refresh for normal file buffers
        if vim.bo[new_buf].buftype == "" then
          -- Check if the buffer has LSP clients that support documentSymbol
          local clients = vim.lsp.get_clients({ bufnr = new_buf })
          local has_symbol_support = false
          for _, client in ipairs(clients) do
            if client:supports_method("textDocument/documentSymbol") then
              has_symbol_support = true
              break
            end
          end

          -- Also check for TreeSitter parser as fallback
          local has_treesitter = pcall(vim.treesitter.get_parser, new_buf)

          if has_symbol_support or has_treesitter then
            logger.log("[DEBUG] outline: BufEnter - buffer changed, refreshing outline", "DEBUG")
            -- Update buffer tracking
            state.original_buf = new_buf
            state.last_changedtick = vim.b[new_buf].changedtick
            state.fetch_buffer = new_buf
            -- Refresh the outline content by updating in place
            vim.schedule(function()
              if state.is_open and state.outline_win and api.nvim_win_is_valid(state.outline_win) then
                M.refresh()
              end
            end)
          else
            logger.log("[DEBUG] outline: BufEnter - buffer has no symbol support, not refreshing", "DEBUG")
          end
        end
      end
    end,
    desc = "Refresh outline when switching buffers",
  })
end

---Cleanup autocmds
---@return nil
local function cleanup_autocmds()
  if state.autocmd_group then
    pcall(api.nvim_del_augroup_by_id, state.autocmd_group)
    state.autocmd_group = nil
  end
end

---Reset module state
---@return nil
local function reset_state()
  cleanup_autocmds()
  state.picker_state = nil
  state.module_state = nil
  state.original_win = nil
  state.original_buf = nil
  state.outline_win = nil
  state.outline_buf = nil
  state.prompt_win = nil
  state.prompt_buf = nil
  state.autocmd_group = nil
  state.items = nil
  state.is_open = false
  state.is_refreshing = false
  state.last_changedtick = nil
  state.usages_fetched = false
  -- Note: Don't reset show_lines, show_usages, preview_on_move - preserve user's toggle state
end

---Open the outline using the symbols picker in split mode
---@param opts? NamuOutlineOpenOptions Options for opening the outline
---@return nil
function M.open(opts)
  opts = opts or {}
  resolve_config()

  -- If already open, just focus the outline
  if state.is_open and state.outline_win and api.nvim_win_is_valid(state.outline_win) then
    api.nvim_set_current_win(state.outline_win)
    return
  end

  -- Reset any stale state
  reset_state()

  state.original_win = api.nvim_get_current_win()
  state.original_buf = api.nvim_get_current_buf()
  state.last_changedtick = vim.b[state.original_buf].changedtick

  -- Get required modules
  local symbols = require("namu.namu_symbols")
  local symbol_utils = require("namu.core.symbol_utils")
  local ui = require("namu.namu_symbols.ui")
  local selecta = require("namu.selecta.selecta")

  -- Get symbols config (has all necessary fields like icon, kindIcons, etc.)
  local symbols_config = config_manager.get_config("namu_symbols")

  -- Build movement config for outline
  -- IMPORTANT: Force close = { "q" } for outline regardless of user global config
  -- This ensures Esc doesn't close the outline (it should switch to normal mode instead)
  local base_movement = config.movement or {}
  local opts_movement = opts.movement or {}
  local movement = vim.tbl_deep_extend("force", base_movement, opts_movement)
  -- Force close key to be 'q' unless explicitly set in opts
  if not opts.movement or not opts.movement.close then
    movement.close = { "q" }
  end
  logger.log("[DEBUG] outline: config.movement=" .. vim.inspect(config.movement), "DEBUG")
  logger.log("[DEBUG] outline: forced movement=" .. vim.inspect(movement), "DEBUG")

  -- Merge config with split options (same pattern as bookmarks)
  local picker_config = vim.tbl_deep_extend("force", symbols_config, {
    split = {
      position = opts.position or config.position,
      size = opts.size or config.size,
      original_win = state.original_win,
    },
    close_on_select = opts.close_on_select ~= nil and opts.close_on_select or config.close_on_select,
    normal_mode = opts.normal_mode ~= nil and opts.normal_mode or config.normal_mode,
    title = opts.title or config.title or "  Outline",
    movement = movement,
    -- Display annotation options
    show_lines = state.show_lines,
    show_usages = state.show_usages,
    -- Hooks to capture picker state and window after creation
    hooks = {
      on_state_init = function(picker_state, picker_opts_inner)
        -- Capture the picker state for follow_cursor feature
        logger.log("[DEBUG] outline: on_state_init called, capturing picker_state", "DEBUG")
        state.picker_state = picker_state
        state.items = picker_state.items
        state.prompt_win = picker_state.prompt_win
        state.prompt_buf = picker_state.prompt_buf
        logger.log("[DEBUG] outline: captured " .. tostring(state.items and #state.items or 0) .. " items", "DEBUG")
      end,
      -- Capture module_state which has preview_ns for highlight clearing
      on_module_state = function(module_state_ref)
        logger.log("[DEBUG] outline: on_module_state called, capturing module_state", "DEBUG")
        state.module_state = module_state_ref
      end,
      on_window_create = function(win, buf, picker_opts_inner)
        logger.log("[DEBUG] outline: on_window_create called, win=" .. tostring(win), "DEBUG")
        state.outline_win = win
        state.outline_buf = buf
        state.is_open = true
        state.is_refreshing = false

        -- Setup autocmds
        vim.schedule(function()
          setup_follow_cursor_autocmds()
          -- Initial sync
          update_outline_cursor()
        end)
      end,
      -- Capture the source of symbols (lsp or treesitter) via prompt_info
      on_prompt_info = function(prompt_info)
        if prompt_info and prompt_info.text then
          state.symbol_source = prompt_info.text:match("󰿘") and "lsp" or "treesitter"
        end
      end,
    },
  })

  -- Call symbols.show with merged config (same as bookmarks pattern)
  symbols.show(picker_config)

  -- Setup toggle keymaps on outline buffer after picker is created
  vim.schedule(function()
    if state.outline_buf and api.nvim_buf_is_valid(state.outline_buf) then
      local keymaps = config.keymaps or {}

      -- Toggle lines display
      if keymaps.toggle_lines then
        vim.keymap.set("n", keymaps.toggle_lines, M.toggle_lines, {
          buffer = state.outline_buf,
          desc = "Toggle lines count display",
        })
      end

      -- Toggle usages display
      if keymaps.toggle_usages then
        vim.keymap.set("n", keymaps.toggle_usages, M.toggle_usages, {
          buffer = state.outline_buf,
          desc = "Toggle usages count display",
        })
      end

      -- Toggle preview on move
      if keymaps.toggle_preview then
        vim.keymap.set("n", keymaps.toggle_preview, M.toggle_preview, {
          buffer = state.outline_buf,
          desc = "Toggle preview on cursor move",
        })
      end
    end
  end)
end

---Refresh the outline content for the current buffer
---This updates the picker content in-place without recreating windows
---@return nil
function M.refresh()
  if not state.is_open then
    logger.log("[DEBUG] outline: refresh - not open", "DEBUG")
    return
  end

  -- Check if we have valid picker state for in-place update
  if not state.picker_state or not state.picker_state.active then
    logger.log("[DEBUG] outline: refresh - no valid picker_state, cannot update in-place", "DEBUG")
    state.is_refreshing = false
    return
  end

  if not state.outline_win or not api.nvim_win_is_valid(state.outline_win) then
    logger.log("[DEBUG] outline: refresh - outline window invalid", "DEBUG")
    state.is_refreshing = false
    return
  end

  logger.log("[DEBUG] outline: refresh - fetching symbols for new buffer (in-place update)", "DEBUG")
  -- is_refreshing is already set to true by BufEnter before scheduling this

  resolve_config()

  -- Fetch new symbols for the current buffer
  local symbols = require("namu.namu_symbols")
  local selecta = require("namu.selecta.selecta")

  local fetch_buf = state.original_buf
  symbols.fetch_symbols(fetch_buf, function(new_items, source, err)
    -- Ignore stale callbacks - only process if we're still on the same buffer
    if fetch_buf ~= state.fetch_buffer then
      logger.log(
        "[DEBUG] outline: refresh - ignoring stale callback for buffer "
          .. tostring(fetch_buf)
          .. ", current is "
          .. tostring(state.fetch_buffer),
        "DEBUG"
      )
      return
    end

    -- Handle empty symbols case - show empty state message
    if err or not new_items or #new_items == 0 then
      logger.log("[DEBUG] outline: refresh - no symbols found: " .. tostring(err), "DEBUG")

      -- Clear the outline buffer and show empty message
      if state.outline_buf and api.nvim_buf_is_valid(state.outline_buf) then
        vim.bo[state.outline_buf].modifiable = true
        api.nvim_buf_set_lines(state.outline_buf, 0, -1, false, { "  No symbols in this buffer" })
        vim.bo[state.outline_buf].modifiable = false

        -- Clear any highlights
        local namu_ns = api.nvim_create_namespace("namu_formatted_highlights")
        api.nvim_buf_clear_namespace(state.outline_buf, namu_ns, 0, -1)

        -- Apply a dim highlight to the message
        api.nvim_buf_set_extmark(state.outline_buf, namu_ns, 0, 0, {
          end_row = 0,
          end_col = -1,
          hl_group = "Comment",
          priority = 200,
        })
      end

      -- Clear cached items
      state.items = {}
      state.usages_fetched = false

      return
    end

    logger.log("[DEBUG] outline: refresh - got " .. #new_items .. " items from " .. tostring(source), "DEBUG")

    -- Update the symbol source
    state.symbol_source = source

    -- Find initial index based on cursor position
    local initial_index = nil
    if state.original_win and api.nvim_win_is_valid(state.original_win) then
      local cursor = api.nvim_win_get_cursor(state.original_win)
      local cursor_line, cursor_col = cursor[1], cursor[2] + 1
      initial_index = find_containing_symbol_index(new_items, cursor_line, cursor_col)
    end

    -- Create prompt info for source indicator
    local prompt_info = {
      text = source == "lsp" and "󰿘 " or " ",
      hl_group = "NamuSourceIndicator",
    }

    -- Update items in-place using selecta's update_items function
    -- skip_on_move prevents preview highlighting during refresh (we're just updating content)
    local success = selecta.update_items(
      state.picker_state,
      new_items,
      state.picker_state.original_opts,
      { initial_index = initial_index, skip_on_move = true, initial_prompt_info = prompt_info }
    )

    if success then
      -- Update our cached items reference
      state.items = new_items
      logger.log("[DEBUG] outline: refresh - in-place update successful", "DEBUG")
    else
      logger.log("[DEBUG] outline: refresh - in-place update failed", "DEBUG")
    end

    -- TODO: reasses this one, we might not needed.
    -- Ensure focus stays on original window
    -- vim.schedule(function()
    --   if state.original_win and api.nvim_win_is_valid(state.original_win) then
    --     local current_win = api.nvim_get_current_win()
    --     if current_win ~= state.original_win then
    --       api.nvim_set_current_win(state.original_win)
    --     end
    --   end
    -- end)
  end)
end

---Close the outline
---@return nil
function M.close()
  -- Guard against re-entrant closure
  if not state.is_open then
    return
  end

  -- Mark as closed early to prevent re-entrant calls from WinClosed autocmd
  state.is_open = false

  -- Clear preview highlights before closing
  if state.module_state and state.module_state.preview_ns then
    local ui = require("namu.namu_symbols.ui")
    if state.original_win and api.nvim_win_is_valid(state.original_win) then
      ui.clear_preview_highlight(state.original_win, state.module_state.preview_ns, state.module_state)
    end
  end

  -- Close prompt window if it exists
  if state.prompt_win and api.nvim_win_is_valid(state.prompt_win) then
    pcall(api.nvim_win_close, state.prompt_win, true)
  end

  -- Close outline window
  if state.outline_win and api.nvim_win_is_valid(state.outline_win) then
    pcall(api.nvim_win_close, state.outline_win, true)
  end

  reset_state()
end

---Toggle the outline
---@return nil
function M.toggle()
  if state.is_open and state.outline_win and api.nvim_win_is_valid(state.outline_win) then
    M.close()
  else
    M.open()
  end
end

---Move to the next or previous symbol spatially in the current buffer
---@param direction 1|-1
local function move_to_symbol(direction)
  local bufnr = api.nvim_get_current_buf()
  local win = api.nvim_get_current_win()

  -- If outline is open and for the same buffer, use its items
  local items = (state.is_open and state.original_buf == bufnr) and state.items or nil

  local function do_move(symbol_items)
    if not symbol_items or #symbol_items == 0 then
      return
    end

    -- Filter out root items and sort by line number
    local sorted = {}
    for _, item in ipairs(symbol_items) do
      if not item.is_root and item.value and item.value.lnum then
        table.insert(sorted, item)
      end
    end

    table.sort(sorted, function(a, b)
      return a.value.lnum < b.value.lnum
    end)

    if #sorted == 0 then
      return
    end

    local cursor = api.nvim_win_get_cursor(win)
    local cur_line = cursor[1]
    local target_idx = nil

    if direction > 0 then
      for i, item in ipairs(sorted) do
        if item.value.lnum > cur_line then
          target_idx = i
          break
        end
      end
      target_idx = target_idx or 1
    else
      for i = #sorted, 1, -1 do
        if sorted[i].value.lnum < cur_line then
          target_idx = i
          break
        end
      end
      target_idx = target_idx or #sorted
    end

    local target = sorted[target_idx]
    if target and target.value then
      local lnum = target.value.lnum
      local col = math.max(0, (target.value.col or 1) - 1)
      pcall(api.nvim_win_set_cursor, win, { lnum, col })
      vim.cmd("normal! zz")

      -- If outline is open, update its cursor
      if state.is_open and state.original_win == win then
        vim.schedule(update_outline_cursor)
      end
    end
  end

  if items then
    do_move(items)
  else
    -- Fetch symbols if not available
    local symbols = require("namu.namu_symbols")
    symbols.fetch_symbols(bufnr, function(new_items, _, err)
      if not err and new_items then
        do_move(new_items)
      end
    end)
  end
end

---Move to the next symbol spatially
---@return nil
function M.next()
  move_to_symbol(1)
end

---Move to the previous symbol spatially
---@return nil
function M.prev()
  move_to_symbol(-1)
end

---Focus the outline window
---@return nil
function M.focus()
  if state.outline_win and api.nvim_win_is_valid(state.outline_win) then
    api.nvim_set_current_win(state.outline_win)
  end
end

---Focus the original code window
---@return nil
function M.focus_code()
  if state.original_win and api.nvim_win_is_valid(state.original_win) then
    api.nvim_set_current_win(state.original_win)
  end
end

---Check if outline is open
---@return boolean
function M.is_open()
  return state.is_open and state.outline_win ~= nil and api.nvim_win_is_valid(state.outline_win)
end

---Setup the module
---@param opts? NamuOutlineConfig Configuration options
---@return nil
function M.setup(opts)
  if opts then
    -- Direct setup with options
    resolve_config()
    config = vim.tbl_deep_extend("force", config, opts)
  else
    -- Config comes from config manager
    resolve_config()
  end
end

return M
