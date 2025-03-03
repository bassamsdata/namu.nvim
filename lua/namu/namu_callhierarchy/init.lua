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

-- Utility function to generate tree guide lines
local function make_tree_guides(tree_state)
  local tree = ""
  for idx, level_last in ipairs(tree_state) do
    if idx == #tree_state then
      if level_last then
        tree = tree .. "└╴"
      else
        tree = tree .. "├╴"
      end
    else
      if level_last then
        tree = tree .. "  "
      else
        tree = tree .. "┆ "
      end
    end
  end
  return tree
end

local function update_preview(item, win, ns_id)
  if not item or item.value.is_section then
    return nil
  end

  local value = item.value
  local original_buf = vim.api.nvim_win_get_buf(win)
  local target_buf

  -- If it's in a different file, we need to load that file
  if value.uri and value.uri ~= vim.uri_from_bufnr(original_buf) then
    -- Check if buffer is already loaded
    local filepath = value.file_path
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local bufpath = vim.api.nvim_buf_get_name(buf)
      if bufpath == filepath then
        target_buf = buf
        break
      end
    end

    -- If not found, create a new buffer and load the file
    if not target_buf then
      target_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(target_buf, filepath)

      -- Load the file content into the buffer
      local file_content = vim.fn.readfile(filepath)
      vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, file_content)

      -- Set the filetype for proper syntax highlighting
      local ft = vim.filetype.match({ filename = filepath })
      if ft then
        vim.api.nvim_buf_set_option(target_buf, "filetype", ft)
      end
    end

    -- Switch the window to the new buffer temporarily
    vim.api.nvim_win_set_buf(win, target_buf)

    -- After preview, we'll return to the original buffer
    vim.api.nvim_create_autocmd("CursorMoved", {
      once = true,
      callback = function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_set_buf(win, original_buf)
        end
      end,
    })
  else
    target_buf = original_buf
  end

  -- Now highlight the function in this buffer
  if target_buf and vim.api.nvim_buf_is_valid(target_buf) then
    -- Clear any existing highlights
    vim.api.nvim_buf_clear_namespace(target_buf, ns_id, 0, -1)

    -- Set cursor to the function position
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { value.lnum, value.col - 1 })

      -- Try to use treesitter for better highlighting if available
      local node = vim.treesitter.get_node({
        bufnr = target_buf,
        pos = { value.lnum - 1, value.col - 1 },
      })

      if node then
        node = ui.find_meaningful_node(node, value.lnum - 1)
      end

      if node then
        local srow, scol, erow, ecol = node:range()
        vim.api.nvim_buf_set_extmark(target_buf, ns_id, srow, 0, {
          end_row = erow,
          end_col = ecol,
          hl_group = M.config.highlight,
          hl_eol = true,
          priority = 1,
          strict = false,
        })

        -- Center the view on the highlighted area
        vim.api.nvim_win_set_cursor(win, { srow + 1, scol })
        vim.cmd("normal! zz")
      else
        -- Fallback: just highlight the line
        vim.api.nvim_buf_set_extmark(target_buf, ns_id, value.lnum - 1, 0, {
          end_line = value.lnum,
          hl_group = M.config.highlight,
          hl_eol = true,
          priority = 1,
        })
      end
    end
  end

  return target_buf
end

---Converts call hierarchy items to selecta-compatible items
---@param calls table[] Call hierarchy items from LSP
---@param direction string "incoming" or "outgoing"
---@param depth number Indentation depth level
---@return SelectaItem[]
local function calls_to_selecta_items(calls, direction, depth, tree_state)
  depth = depth or 1 -- Start with depth 1 for first level items
  tree_state = tree_state or {}
  local items = {}

  for i, call in ipairs(calls) do
    local is_last = (i == #calls)
    local current_tree_state = vim.deepcopy(tree_state)
    table.insert(current_tree_state, is_last)

    local item_data
    local call_type = direction

    if direction == CallDirection.INCOMING then
      -- For incoming calls, we want the "from" information
      item_data = call.from
    else
      -- For outgoing calls, we want the "to" information
      item_data = call.to
    end

    if not item_data then
      goto continue
    end

    -- Get range information from the item
    local range = item_data.selectionRange or item_data.range

    if not range or not range.start then
      goto continue
    end

    -- Extract the file URI for this call
    local uri = item_data.uri
    local file_path = vim.uri_to_fname(uri)
    local short_path = file_path:match("([^/\\]+)$") or file_path
    -- Clean name (same as symbols)
    local clean_name = item_data.name:match("^([^%s%(]+)") or item_data.name
    -- Add file location info
    local file_info = string.format(" [%s:%d]", short_path, range.start.line + 1)
    local display_text = clean_name .. file_info

    -- Create the selecta item
    local item = {
      text = display_text,
      value = {
        text = display_text,
        -- text = clean_name .. file_info, -- Include file info in the value.text too
        name = clean_name,
        kind = item_data.kind and lsp.symbol_kind(item_data.kind) or "Function",
        lnum = range.start.line + 1,
        col = range.start.character + 1,
        end_lnum = range["end"] and range["end"].line + 1 or range.start.line + 1,
        end_col = range["end"] and range["end"].character + 1 or range.start.character + 1,
        uri = uri,
        file_path = file_path,
        call_item = call,
        call_type = call_type,
        file_info = file_info, -- Store file info separately
      },
      icon = M.config.kindIcons[lsp.symbol_kind(item_data.kind)] or M.config.icon, -- Add icon like in symbols
      kind = item_data.kind and lsp.symbol_kind(item_data.kind) or "Function",
      depth = depth,
      tree_state = current_tree_state, -- Store tree state for highlighting
    }

    table.insert(items, item)

    -- Process nested calls if available
    if call.children and #call.children > 0 then
      local nested_items = calls_to_selecta_items(call.children, direction, depth + 1, current_tree_state)
      for _, nested_item in ipairs(nested_items) do
        table.insert(items, nested_item)
      end
    end

    ::continue::
  end

  return items
end

-- Apply tree guide highlighting and file info highlighting
local function apply_tree_guide_highlights(buf, items, config)
  local ns_id = vim.api.nvim_create_namespace("namu_callhierarchy_tree_guides")
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  for idx, item in ipairs(items) do
    local line = idx - 1
    local lines = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)
    if #lines == 0 then
      goto continue
    end

    local line_text = lines[1]

    -- Apply tree guide highlighting if available
    if item.tree_state then
      -- Calculate the position of tree guides
      local guide_len = #item.tree_state * 2 -- Each level is 2 chars wide

      -- Apply highlight to the tree guides using extmark
      vim.api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
        end_col = guide_len,
        hl_group = "NamuTreeGuides",
        priority = 100,
      })
    end

    -- Find and highlight file information using regex pattern
    local file_pattern = "%[.+:%d+%]"
    local file_start = line_text:find(file_pattern)

    if file_start then
      -- Find how long the match is
      local file_text = line_text:match(file_pattern)
      local file_len = #file_text

      -- Apply highlight to file info using extmark
      vim.api.nvim_buf_set_extmark(buf, ns_id, line, file_start - 1, {
        end_col = file_start + file_len - 1,
        hl_group = "NamuFileInfo",
        priority = 101, -- Higher priority than tree guides
      })
    end

    ::continue::
  end
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
    local current_file = vim.fn.expand("%:t")
    local current_pos = vim.api.nvim_win_get_cursor(0)
    local file_info = string.format(" [%s:%d]", current_file, current_pos[1])

    -- We'll collect results here
    local all_items = {}

    -- Add the current symbol with file info - format it like a regular symbol
    table.insert(all_items, {
      text = item.name .. file_info,
      value = {
        text = item.name .. file_info,
        name = item.name,
        kind = item.kind and lsp.symbol_kind(item.kind) or "Function",
        lnum = current_pos[1],
        col = current_pos[2] + 1,
        end_lnum = current_pos[1],
        end_col = current_pos[2] + 1 + #item.name,
        file_path = vim.fn.expand("%:p"),
        uri = vim.uri_from_bufnr(0),
        is_current = true,
      },
      icon = M.config.kindIcons[lsp.symbol_kind(item.kind)] or M.config.icon,
      kind = item.kind and lsp.symbol_kind(item.kind) or "Function",
      depth = 0,
    })

    -- Determine which calls to fetch
    local pending_requests = 0

    -- Function to handle completed requests
    local function handle_completion()
      pending_requests = pending_requests - 1
      if pending_requests == 0 then
        -- Cache the results
        calls_cache[cache_key] = all_items

        -- Show picker
        M.show_call_picker(all_items, notify_opts)
      end
    end

    -- Handle incoming calls if requested
    if direction == CallDirection.INCOMING or direction == CallDirection.BOTH then
      pending_requests = pending_requests + 1

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
          local items = calls_to_selecta_items(call_result, CallDirection.INCOMING)
          for _, item in ipairs(items) do
            table.insert(all_items, item)
          end
        end

        handle_completion()
      end)
    end

    -- Handle outgoing calls if requested
    if direction == CallDirection.OUTGOING or direction == CallDirection.BOTH then
      pending_requests = pending_requests + 1

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
          local items = calls_to_selecta_items(call_result, CallDirection.OUTGOING)
          for _, item in ipairs(items) do
            table.insert(all_items, item)
          end
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

function M.show_call_picker(selectaItems, notify_opts)
  if #selectaItems == 0 then
    vim.notify("No call hierarchy items found.", nil, notify_opts)
    return
  end
  -- Create a custom formatter that properly handles tree guides and icons
  local formatter = function(item)
    -- Handle current highlight prefix padding
    local prefix_padding = ""
    if M.config.current_highlight.enabled and #M.config.current_highlight.prefix_icon > 0 then
      prefix_padding = string.rep(" ", vim.api.nvim_strwidth(M.config.current_highlight.prefix_icon))
    end

    -- Get the tree guides if available
    local guides = ""
    if item.tree_state then
      guides = make_tree_guides(item.tree_state)
    end

    -- Get the appropriate icon
    local icon = item.icon or "  "
    -- local icon = item.icon or M.config.kindIcons[item.kind] or "  "

    local indicator = ""
    if item.value.is_current then
      indicator = "▼ "
    end
    -- Extract the clean name and file info
    local name_and_info = item.text

    -- Put it all together: prefix padding + tree guides + icon + content
    return prefix_padding .. guides .. indicator .. icon .. " " .. name_and_info
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
    formatter = formatter, -- Add our custom formatter
    hooks = {
      on_render = function(buf, filtered_items)
        ui.apply_kind_highlights(buf, filtered_items, M.config)
        apply_tree_guide_highlights(buf, filtered_items, M.config) -- Add this line
      end,
      on_buffer_clear = function()
        ui.clear_preview_highlight(state.original_win, state.preview_ns)
        if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
          vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
        end

        -- Restore original buffer if we switched to another buffer for preview
        if state.original_win and state.original_buf and vim.api.nvim_win_is_valid(state.original_win) then
          vim.api.nvim_win_set_buf(state.original_win, state.original_buf)
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
      pcall(ui.clear_preview_highlight, state.original_win, state.preview_ns)

      -- Restore original buffer if we switched to another buffer for preview
      if
        state.original_win
        and state.original_buf
        and pcall(vim.api.nvim_win_is_valid, state.original_win)
        and pcall(vim.api.nvim_buf_is_valid, state.original_buf)
      then
        pcall(vim.api.nvim_win_set_buf, state.original_win, state.original_buf)
      end

      M.jump_to_call(item)
    end,
    on_cancel = function()
      ui.clear_preview_highlight(state.original_win, state.preview_ns)

      -- Restore original buffer if we switched to another buffer for preview
      if state.original_win and state.original_buf and vim.api.nvim_win_is_valid(state.original_win) then
        vim.api.nvim_win_set_buf(state.original_win, state.original_buf)
      end

      if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
        vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
      end
    end,
    on_move = function(item)
      if M.config.preview.highlight_on_move and M.config.preview.highlight_mode == "always" then
        if item and not item.value.is_header then
          -- Update the preview with the currently selected item
          ui.highlight_symbol(item.value, state.original_win, state.preview_ns)
        end
      end
    end,
  }

  -- Add custom prefix highlighter if needed
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

        if
          state.original_win
          and state.original_buf
          and pcall(vim.api.nvim_win_is_valid, state.original_win)
          and pcall(vim.api.nvim_buf_is_valid, state.original_buf)
        then
          pcall(vim.api.nvim_win_set_buf, state.original_win, state.original_buf)
        end

        pcall(vim.api.nvim_del_augroup_by_name, "NamuCallHierarchyCleanup")
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

  -- Return to the original window if we're in the picker window
  if state.original_win and vim.api.nvim_win_is_valid(state.original_win) then
    vim.api.nvim_set_current_win(state.original_win)
  end

  -- Clean up any highlight that might be leftover
  if state.preview_ns then
    ui.clear_preview_highlight(0, state.preview_ns)
  end

  -- Record the current position in jumplist
  vim.cmd.normal({ "m`", bang = true })

  -- If it's a different file, open it
  if value.uri and value.file_path then
    local current_uri = vim.uri_from_bufnr(vim.api.nvim_get_current_buf())

    if value.uri ~= current_uri then
      -- Use edit command to open the file in the current window
      local cmd = "edit " .. vim.fn.fnameescape(value.file_path)

      -- If the file is already open in another window, consider using that window
      local bufnr = vim.fn.bufnr(value.file_path)
      if bufnr ~= -1 then
        -- Check if this buffer is visible in any window
        local win_id = vim.fn.bufwinid(bufnr)
        if win_id ~= -1 then
          -- If the buffer is already visible in a window, switch to that window
          vim.api.nvim_set_current_win(win_id)
        else
          -- Buffer exists but not visible, switch to it in current window
          vim.api.nvim_set_current_buf(bufnr)
          vim.api.nvim_buf_set_option(bufnr, "buflisted", true)
        end
      else
        -- Open the file
        vim.cmd(cmd)
        -- Get the new buffer number
        bufnr = vim.api.nvim_get_current_buf()

        -- Ensure it's listed
        vim.api.nvim_buf_set_option(bufnr, "buflisted", true)
      end
    end
  end

  -- Jump to position
  if value.lnum and value.col then
    vim.api.nvim_win_set_cursor(0, { value.lnum, value.col - 1 })

    -- Center the view on the line
    vim.cmd("normal! zz")

    -- Optionally flash the line to make it more obvious
    if M.config.flash_line_on_jump then
      local ns_id = vim.api.nvim_create_namespace("namu_callhierarchy_jump")
      vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

      local flash_hl_group = M.config.flash_highlight or "IncSearch"

      -- Add highlight
      vim.api.nvim_buf_add_highlight(0, ns_id, flash_hl_group, value.lnum - 1, 0, -1)

      -- Remove highlight after a short delay
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(0) then
          vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
        end
      end, 300)
    end
  end
  -- Make sure the current buffer is in the buffer list
  local current_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_option(current_buf, "buflisted", true)

  -- Return true to indicate successful navigation
  return true
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
  -- Add tree guide highlight
  vim.api.nvim_set_hl(0, "NamuTreeGuides", {
    link = "Comment", -- Link to Comment by default
    default = true,
  })
  vim.api.nvim_set_hl(0, "NamuFileInfo", {
    link = "Comment", -- More visible color for file paths
    default = true,
  })
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
