local selecta = require("namu.selecta.selecta")
local lsp = require("namu.namu_symbols.lsp")
local ui = require("namu.namu_symbols.ui")
local ext = require("namu.namu_symbols.external_plugins")
local utils = require("namu.namu_symbols.utils")
local symbol_utils = require("namu.core.symbol_utils")
local logger = require("namu.utils.logger")
local M = {}

---@type NamuConfig
M.config = require("namu.namu_symbols").config

---@type NamuState
local state = symbol_utils.create_state("namu_callhierarchy_preview")

-- Cache for calls
local calls_cache = {}

-- Enumeration for call hierarchy direction
local CallDirection = {
  INCOMING = "incoming",
  OUTGOING = "outgoing",
  BOTH = "both",
}

---Converts call hierarchy items to selecta-compatible items
---@param calls table[] Call hierarchy items from LSP
---@param direction string "incoming" or "outgoing"
---@return SelectaItem[]
local function calls_to_selecta_items(calls, direction, depth)
  depth = depth or 0
  local items = {}

  for _, call in ipairs(calls) do
    local item_data
    local name
    local call_type = direction

    if direction == CallDirection.INCOMING then
      -- For incoming calls, we want the "from" information
      item_data = call.from
      name = item_data.name .. " → " .. (state.current_symbol_name or "current")
    else
      -- For outgoing calls, we want the "to" information
      item_data = call.to
      name = (state.current_symbol_name or "current") .. " → " .. item_data.name
    end

    -- Get range information from the item
    local range = item_data.selectionRange or item_data.range

    if not range or not range.start or not range["end"] then
      logger.log("Call item '" .. item_data.name .. "' has invalid range structure")
      goto continue
    end

    -- Extract the file URI for this call
    local uri = item_data.uri

    -- Create the selecta item
    local item = {
      text = name,
      value = {
        text = name,
        name = item_data.name,
        kind = item_data.kind and lsp.symbol_kind(item_data.kind) or "Function",
        lnum = range.start.line + 1,
        col = range.start.character + 1,
        end_lnum = range["end"].line + 1,
        end_col = range["end"].character + 1,
        uri = uri,
        file_path = vim.uri_to_fname(uri),
        call_item = call, -- Store the original call item for reference
        call_type = call_type, -- Store whether this is incoming or outgoing
      },
      icon = direction == CallDirection.INCOMING and "↓" or "↑", -- Use different icons for incoming vs outgoing
      kind = item_data.kind and lsp.symbol_kind(item_data.kind) or "Function",
      depth = depth,
    }

    -- Add from/to ranges for detailed location information
    if call.fromRanges and #call.fromRanges > 0 then
      item.value.fromRanges = call.fromRanges
    end

    table.insert(items, item)

    ::continue::
  end

  return items
end

-- Direct LSP request helper function to replace generic request_symbols
local function make_call_hierarchy_request(method, params, callback)
  local bufnr = vim.api.nvim_get_current_buf()

  -- Check if the current language server supports call hierarchy
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local client

  for _, c in ipairs(clients) do
    -- Check for the specific capability based on method
    local has_capability = false
    if method == "textDocument/prepareCallHierarchy" then
      has_capability = c.server_capabilities.callHierarchyProvider
    elseif method:find("callHierarchy/") == 1 then
      has_capability = c.server_capabilities.callHierarchyProvider
    end

    if has_capability then
      client = c
      break
    end
  end

  if not client then
    logger.log("No client supporting " .. method .. " found")
    callback("No LSP client supports call hierarchy", nil)
    return
  end

  -- Make the request directly
  logger.log("Making direct request: " .. method)
  logger.log("Params: " .. vim.inspect(params))

  client.request(method, params, function(err, result, ctx)
    logger.log("Response received for: " .. method)
    logger.log("Error: " .. vim.inspect(err))
    logger.log("Result: " .. vim.inspect(result))

    callback(err, result, ctx)
  end, bufnr)
end

---Show call hierarchy picker with incoming/outgoing calls
---@param direction? string "incoming", "outgoing", or "both"
function M.show(direction)
  direction = direction or CallDirection.BOTH

  -- Store current position and buffer
  state.original_win = vim.api.nvim_get_current_win()
  state.original_buf = vim.api.nvim_get_current_buf()
  state.original_ft = vim.bo.filetype
  state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)

  -- Get the symbol name at cursor for better display
  local cword = vim.fn.expand("<cword>")
  state.current_symbol_name = cword

  -- Set highlight
  vim.api.nvim_set_hl(0, M.config.highlight, {
    link = "Visual",
  })

  local notify_opts = { title = "Namu Call Hierarchy", icon = M.config.icon }

  -- Cache key includes buffer, position, and direction
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local cache_key = string.format("%d_%d_%d_%s", bufnr, cursor_pos[1], cursor_pos[2], direction)

  -- Check cache first
  if calls_cache[cache_key] then
    logger.log("Using cached call hierarchy data")
    local selectaItems = calls_cache[cache_key]
    M.show_call_picker(selectaItems, notify_opts)
    return
  end

  -- Prepare position params
  local params = vim.lsp.util.make_position_params()

  logger.log("Requesting call hierarchy at position " .. vim.inspect(params.position))

  -- Step 1: Get call hierarchy items
  make_call_hierarchy_request("textDocument/prepareCallHierarchy", params, function(err, result)
    if err then
      local error_message = type(err) == "string" and err or (type(err) == "table" and err.message) or "Unknown error"
      vim.notify("Error preparing call hierarchy: " .. error_message, vim.log.levels.ERROR, notify_opts)
      return
    end

    if not result or #result == 0 then
      vim.notify("No call hierarchy items found at cursor position.", vim.log.levels.WARN, notify_opts)
      return
    end

    logger.log("Got call hierarchy items: " .. vim.inspect(result))

    -- Use the first item (typically there's only one)
    local item = result[1]

    -- Store symbol name for display
    state.current_symbol_name = item.name

    -- We'll collect results here
    local all_items = {}

    -- Add a section header for the current symbol
    table.insert(all_items, {
      text = "Current Symbol: " .. item.name,
      value = {
        text = "Current Symbol: " .. item.name,
        name = item.name,
        kind = "Header",
        lnum = 1,
        col = 1,
        is_header = true,
        -- Add placeholder range to avoid nil errors in binary search
        end_lnum = 1,
        end_col = 1,
      },
      icon = "📍", -- Marker icon
      kind = "Header",
      depth = 0,
    })

    -- Determine which calls to fetch
    local pending_requests = 0

    -- Function to handle completed requests
    local function handle_completion()
      pending_requests = pending_requests - 1
      if pending_requests == 0 then
        -- Sort items by direction (incoming first) and then by name
        table.sort(all_items, function(a, b)
          if a.value.is_header then
            return true
          end
          if b.value.is_header then
            return false
          end

          if a.value.call_type ~= b.value.call_type then
            return a.value.call_type == CallDirection.INCOMING
          end
          return a.value.name < b.value.name
        end)

        -- Cache the results
        calls_cache[cache_key] = all_items

        -- Show picker
        M.show_call_picker(all_items, notify_opts)
      end
    end

    -- Handle incoming calls if requested
    if direction == CallDirection.INCOMING or direction == CallDirection.BOTH then
      pending_requests = pending_requests + 1

      -- Add header for incoming calls section
      if direction == CallDirection.BOTH then
        table.insert(all_items, {
          text = "Incoming Calls",
          value = {
            text = "Incoming Calls",
            name = "Incoming Calls",
            kind = "Section",
            lnum = 1,
            col = 1,
            is_section = true,
            -- Add placeholder range to avoid nil errors
            end_lnum = 1,
            end_col = 1,
          },
          icon = "↓",
          kind = "Section",
          depth = 0,
        })
      end

      -- Make the request for incoming calls
      make_call_hierarchy_request("callHierarchy/incomingCalls", { item = item }, function(call_err, call_result)
        if call_err then
          local error_message = type(call_err) == "string" and call_err
            or (type(call_err) == "table" and call_err.message)
            or "Unknown error"
          vim.notify("Error fetching incoming calls: " .. error_message, vim.log.levels.ERROR, notify_opts)
          handle_completion()
          return
        end

        if call_result and #call_result > 0 then
          -- Convert to selecta items and add to our collection
          local items = calls_to_selecta_items(call_result, CallDirection.INCOMING, 1)
          for _, item in ipairs(items) do
            table.insert(all_items, item)
          end
        else
          vim.notify("No incoming calls found.", vim.log.levels.WARN, notify_opts)
        end

        handle_completion()
      end)
    end

    -- Handle outgoing calls if requested
    if direction == CallDirection.OUTGOING or direction == CallDirection.BOTH then
      pending_requests = pending_requests + 1

      -- Add header for outgoing calls section
      if direction == CallDirection.BOTH then
        table.insert(all_items, {
          text = "Outgoing Calls",
          value = {
            text = "Outgoing Calls",
            name = "Outgoing Calls",
            kind = "Section",
            lnum = 1,
            col = 1,
            is_section = true,
            -- Add placeholder range to avoid nil errors
            end_lnum = 1,
            end_col = 1,
          },
          icon = "↑",
          kind = "Section",
          depth = 0,
        })
      end

      -- Make the request for outgoing calls
      make_call_hierarchy_request("callHierarchy/outgoingCalls", { item = item }, function(call_err, call_result)
        if call_err then
          local error_message = type(call_err) == "string" and call_err
            or (type(call_err) == "table" and call_err.message)
            or "Unknown error"
          vim.notify("Error fetching outgoing calls: " .. error_message, vim.log.levels.ERROR, notify_opts)
          handle_completion()
          return
        end

        if call_result and #call_result > 0 then
          -- Convert to selecta items and add to our collection
          local items = calls_to_selecta_items(call_result, CallDirection.OUTGOING, 1)
          for _, item in ipairs(items) do
            table.insert(all_items, item)
          end
        else
          vim.notify("No outgoing calls found.", vim.log.levels.WARN, notify_opts)
        end

        handle_completion()
      end)
    end

    -- If we didn't initiate any requests, show empty results
    if pending_requests == 0 then
      M.show_call_picker(all_items, notify_opts)
    end
  end)
end

-- Custom show_picker function for call hierarchy items
function M.show_call_picker(selectaItems, notify_opts)
  if #selectaItems == 0 then
    vim.notify("No call hierarchy items found.", nil, notify_opts)
    return
  end

  local picker_opts = {
    title = "Call Hierarchy",
    fuzzy = false,
    preserve_order = true,
    window = M.config.window,
    display = M.config.display,
    auto_select = M.config.auto_select,
    initially_hidden = M.config.initially_hidden,
    movement = vim.tbl_deep_extend("force", M.config.movement, {}),
    current_highlight = vim.tbl_deep_extend("force", M.config.current_highlight, {}),
    row_position = M.config.row_position,
    debug = M.config.debug,
    hooks = {
      on_render = function(buf, filtered_items)
        ui.apply_kind_highlights(buf, filtered_items, M.config)
      end,
      on_buffer_clear = function()
        ui.clear_preview_highlight(state.original_win, state.preview_ns)
        if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
          vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
        end
      end,
    },
    custom_keymaps = M.config.custom_keymaps,
    multiselect = {
      enabled = M.config.multiselect.enabled,
      indicator = M.config.multiselect.indicator,
      on_select = function(selected_items)
        if M.config.preview.highlight_mode == "select" then
          ui.clear_preview_highlight(state.original_win, state.preview_ns)
          if type(selected_items) == "table" and selected_items[1] then
            ui.highlight_symbol(selected_items[1].value, state.original_win, state.preview_ns)
          end
        end
        if type(selected_items) == "table" and selected_items[1] then
          M.jump_to_call(selected_items[1])
        end
      end,
    },
    on_select = function(item)
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      M.jump_to_call(item)
    end,
    on_cancel = function()
      ui.clear_preview_highlight(state.original_win, state.preview_ns)
      if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
        vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
      end
    end,
    on_move = function(item)
      if M.config.preview.highlight_on_move and M.config.preview.highlight_mode == "always" then
        if item and not item.value.is_header and not item.value.is_section then
          ui.highlight_symbol(item.value, state.original_win, state.preview_ns)
        end
      end
    end,
  }

  if M.config.kinds.prefix_kind_colors then
    picker_opts.prefix_highlighter = function(buf, line_nr, item, icon_end, ns_id)
      local kind_hl = M.config.kinds.highlights[item.kind]
      if kind_hl then
        vim.api.nvim_buf_set_extmark(buf, ns_id, line_nr, 0, {
          end_col = icon_end,
          hl_group = kind_hl,
          priority = 100,
          hl_mode = "combine",
        })
      end
    end
  end

  local picker_win = selecta.pick(selectaItems, picker_opts)

  -- Add cleanup autocmd after picker is created
  if picker_win then
    local augroup = vim.api.nvim_create_augroup("NamuCallHierarchyCleanup", { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = tostring(picker_win),
      callback = function()
        ui.clear_preview_highlight(state.original_win, state.preview_ns)
        vim.api.nvim_del_augroup_by_name("NamuCallHierarchyCleanup")
      end,
      once = true,
    })
  end
end

---Jump to the location of a call
---@param item table The selected item
function M.jump_to_call(item)
  if not item or not item.value then
    vim.notify("Invalid call item", vim.log.levels.ERROR)
    return
  end

  local value = item.value

  -- Skip headers and sections
  if value.is_header or value.is_section then
    return
  end

  -- If it's a different file, open it
  if value.uri and value.uri ~= vim.uri_from_bufnr(state.original_buf) then
    vim.cmd("edit " .. vim.fn.fnameescape(value.file_path))
  end

  -- Jump to position
  vim.api.nvim_win_set_cursor(0, { value.lnum, value.col - 1 })
  vim.cmd("normal! zz")
end

---Show incoming calls for symbol at cursor
function M.show_incoming_calls()
  M.show(CallDirection.INCOMING)
end

---Show outgoing calls for symbol at cursor
function M.show_outgoing_calls()
  M.show(CallDirection.OUTGOING)
end

---Show both incoming and outgoing calls
function M.show_both_calls()
  M.show(CallDirection.BOTH)
end

---Initialize the module with user configuration
---@param opts table|nil User config options
function M.setup(opts)
  -- Make sure we import lsp here to avoid circular dependencies

  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  if M.config.custom_keymaps then
    local handlers = symbol_utils.create_keymaps_handlers(M.config, state, ui, selecta, ext, utils)
    M.config.custom_keymaps.yank.handler = handlers.yank
    M.config.custom_keymaps.delete.handler = handlers.delete
    M.config.custom_keymaps.vertical_split.handler = handlers.vertical_split
    M.config.custom_keymaps.horizontal_split.handler = handlers.horizontal_split
    M.config.custom_keymaps.codecompanion.handler = handlers.codecompanion
    M.config.custom_keymaps.avante.handler = handlers.avante
  end

  -- Add special handler for call items
  if M.config.on_select == nil then
    M.config.on_select = M.jump_to_call
  end
end

---Setup default keymaps
function M.setup_keymaps()
  vim.keymap.set("n", "<leader>ci", M.show_incoming_calls, {
    desc = "Show incoming calls",
    silent = true,
  })

  vim.keymap.set("n", "<leader>co", M.show_outgoing_calls, {
    desc = "Show outgoing calls",
    silent = true,
  })

  vim.keymap.set("n", "<leader>cc", M.show_both_calls, {
    desc = "Show call hierarchy (both directions)",
    silent = true,
  })
end

return M
