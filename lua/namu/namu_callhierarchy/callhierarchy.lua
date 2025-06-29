--[[ Namu Call Hierarchy Implementation
This file contains the actual implementation of the call hierarchy module.
It is loaded only when required to improve startup performance.
]]

-- Dependencies are only loaded when the module is actually used
local selecta = require("namu.selecta.selecta")
local navigation = require("namu.namu_callhierarchy.navigation")
local lsp = require("namu.namu_symbols.lsp")
local symbol_utils = require("namu.core.symbol_utils")
local logger = require("namu.utils.logger")
local preview_utils = require("namu.core.preview_utils")
local api = vim.api
local M = {}

---@type NamuState
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = api.nvim_create_namespace("callhierarchy_preview"),
  preview_state = nil,
}

-- We need to store the config when passed in to be used by local functions
M.config = {}
function M.update_config(new_config)
  M.config = vim.tbl_deep_extend("force", {}, new_config)
end

local pending_requests = 0
local calls_cache = {}
local processed_call_signatures = {}

-- Enumeration for call hierarchy direction
local CallDirection = {
  INCOMING = "incoming",
  OUTGOING = "outgoing",
  BOTH = "both",
}

local function preview_callhierarchy_item(item, win_id)
  if not state.preview_state then
    state.preview_state = preview_utils.create_preview_state("callhierarchy_preview")
  end
  preview_utils.preview_symbol(item, win_id, state.preview_state, {
    highlight_group = "NamuPreview",
    -- Assuming callhierarchy lnum is 1-based, offset by -1 for highlight (0-based)
    highlight_line_offset = -1,
    -- No adjustment needed for cursor (already 1-based)
    line_index_offset = 0,
  })
end

-- Basically this fucntion is borrowed from https://github.com/jmacadie/telescope-hierarchy.nvim
-- thanks to @jmacadie for this fucntion and his aswesome plugin
-- Utility function to generate tree guide lines
local function make_tree_guides(tree_state)
  local tree = ""
  for idx, level_last in ipairs(tree_state) do
    if idx == #tree_state then
      if level_last then
        tree = tree .. "└─" -- Last item in the branch
      else
        tree = tree .. "├─" -- Has siblings below
      end
    else
      if level_last then
        tree = tree .. "  " -- Parent was last item, no need for vertical line
      else
        tree = tree .. "┆ " -- Parent has siblings, need vertical line
      end
    end
  end
  return tree
end

-- Helper function to find the parent's position in the items list
local function find_parent_position(items, parent_signature)
  for i = #items, 1, -1 do
    if items[i].value.signature == parent_signature then
      return i
    end
  end
  return nil
end

---Checks if any attached client supports call hierarchy methods
---@param bufnr number Buffer number
---@return table Support status for call hierarchy methods
local function check_call_hierarchy_support(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  local support = {
    prepare = false,
    incoming = false,
    outgoing = false,
  }

  for _, client in ipairs(clients) do
    -- Check for general call hierarchy support
    if client.server_capabilities.callHierarchyProvider then
      support.prepare = true
      support.incoming = true
      support.outgoing = true
    end

    -- Check for specific method support, which may exist independently
    if client:supports_method("callHierarchy/incomingCalls", bufnr) then
      support.incoming = true
    end

    if client:supports_method("callHierarchy/outgoingCalls", bufnr) then
      support.outgoing = true
    end
  end

  return support
end

---Converts call hierarchy items to selecta-compatible items
---@param calls table[] Call hierarchy items from LSP
---@param direction string "incoming" or "outgoing"
---@param depth number Indentation depth level
---@param parent_tree_state table|nil Parent's tree state for guides
---@param visited table|nil Set of visited symbols to prevent cycles
---@return SelectaItem[]
local function calls_to_selecta_items(calls, direction, depth, parent_tree_state, visited)
  depth = depth or 1 -- Start with depth 1 for first level items
  -- tree_state = tree_state or {}
  visited = visited or {}
  -- Use a map to collect unique items by signature
  local items_map = {}
  for i, call in ipairs(calls) do
    local is_last = (i == #calls)
    -- Create tree state based on parent's state
    local current_tree_state = {}
    if parent_tree_state then
      -- Copy parent's tree state first
      for _, branch_info in ipairs(parent_tree_state) do
        table.insert(current_tree_state, branch_info)
      end
    end
    -- Add the current level's branch info
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
    -- Enhanced signature generation
    local container_name = item_data.containerName or ""
    local detail = item_data.detail or ""

    -- Create a unique signature that better identifies the function
    local signature = string.format(
      "%s:%d:%d:%s:%s:%s",
      uri,
      range.start.line,
      range.start.character,
      item_data.name,
      container_name,
      detail
    )
    -- Check if we've already processed this exact signature
    if items_map[signature] then
      goto continue
    end

    -- Check for cycles
    local is_cycle = visited[signature] ~= nil
    -- Clean name (same as symbols)
    local clean_name = item_data.name:match("^([^%s%(]+)") or item_data.name
    -- Add file location info
    local file_info = string.format(" [%s:%d]", short_path, range.start.line + 1)
    -- For cycles, add an indicator if configured to show them
    if is_cycle and M.config.call_hierarchy.show_cycles then
      file_info = file_info .. " (recursive)"
    end

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
        file_info = file_info,
        signature = signature,
        is_cycle = is_cycle,
      },
      icon = M.config.kindIcons[lsp.symbol_kind(item_data.kind)] or M.config.icon, -- Add icon like in symbols
      kind = item_data.kind and lsp.symbol_kind(item_data.kind) or "Function",
      depth = depth,
      tree_state = current_tree_state, -- Store tree state for highlighting
    }

    -- Store in our map to avoid duplicates
    items_map[signature] = item

    -- Process nested calls if:
    -- 1. Not a cycle
    -- 2. Not reached max depth
    -- 3. The call item has the required fields to make further requests
    if not is_cycle and depth < M.config.call_hierarchy.max_depth and not item.value.is_cycle then
      -- Mark this signature as visited to detect cycles
      visited[signature] = true

      -- We'll process this item's calls in the fetch functions
      item.value.should_expand = true
    end

    ::continue::
  end

  -- Convert the map to an array while preserving insertion order
  local items = {}
  for _, call in ipairs(calls) do
    -- Generate the same signature as above to find the item in our map
    local item_data = direction == CallDirection.INCOMING and call.from or call.to
    if not item_data or not item_data.range then
      goto next_item
    end

    local range = item_data.selectionRange or item_data.range
    if not range or not range.start then
      goto next_item
    end

    local container_name = item_data.containerName or ""
    local detail = item_data.detail or ""

    local signature = string.format(
      "%s:%d:%d:%s:%s:%s",
      item_data.uri,
      range.start.line,
      range.start.character,
      item_data.name,
      container_name,
      detail
    )

    if items_map[signature] then
      table.insert(items, items_map[signature])
      -- Remove from map so we don't add twice
      items_map[signature] = nil
    end

    ::next_item::
  end

  -- Second pass - add any remaining items that weren't matched
  -- (this shouldn't happen with our implementation but just for safety)
  for _, item in pairs(items_map) do
    table.insert(items, item)
  end

  return items
end

---Creates a synthetic call hierarchy item based on the current position
---@return table Call hierarchy item
local function create_synthetic_call_item()
  local current_pos = api.nvim_win_get_cursor(0)
  local current_word = vim.fn.expand("<cword>")
  local uri = vim.uri_from_bufnr(0)

  -- Create a minimal call hierarchy item with the required fields
  local synthetic_item = {
    name = current_word,
    kind = 12, -- Function kind as default
    selectionRange = {
      start = {
        line = current_pos[1] - 1,
        character = current_pos[2],
      },
      ["end"] = {
        line = current_pos[1] - 1,
        character = current_pos[2] + #current_word,
      },
    },
    uri = uri,
  }

  return synthetic_item
end

-- Direct LSP request helper function to replace generic request_symbols
local function make_call_hierarchy_request(method, params, callback)
  local bufnr = api.nvim_get_current_buf()
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
  client:request(method, params, function(err, result, ctx)
    callback(err, result, ctx)
  end, bufnr)
end

---Create a properly formatted LSP call hierarchy item from selecta item
---@param item table The item to convert to LSP format
---@return table LSP call item format
local function create_lsp_call_item(item)
  return {
    name = item.value.name,
    kind = lsp.symbol_kind_to_number(item.value.kind) or 12, -- Default to Function (12)
    uri = item.value.uri,
    range = {
      start = {
        line = item.value.lnum - 1,
        character = item.value.col - 1,
      },
      ["end"] = {
        line = item.value.end_lnum - 1,
        character = item.value.end_col - 1,
      },
    },
    selectionRange = {
      start = {
        line = item.value.lnum - 1,
        character = item.value.col - 1,
      },
      ["end"] = {
        line = item.value.end_lnum - 1,
        character = item.value.end_col - 1,
      },
    },
  }
end

---Format an LSP error response consistently
---@param err any Error from LSP
---@param default_message string|nil Default message if error format is unknown
---@return string Formatted error message
local function format_lsp_error(err, default_message)
  if type(err) == "string" then
    return err
  elseif type(err) == "table" and err.message then
    return err.message
  else
    return default_message or "Unknown error"
  end
end

-- track if we've already shown a notification
local notification_shown = false
local function show_notification(message, level, opts)
  if not notification_shown then
    notification_shown = true
    vim.notify(message, level or vim.log.levels.INFO, opts)
  end
end

---Fetch calls in either direction recursively
---@param item table Call hierarchy item
---@param all_items table Array to append results to
---@param direction string "incoming" or "outgoing"
---@param notify_opts table Notification options
---@param callback function Callback when request completes
---@param depth number Current depth
---@param visited table Set of visited items to prevent cycles
---@param parent_signature string|nil Signature of parent item
local function fetch_calls_recursive(
  item,
  all_items,
  direction,
  notify_opts,
  callback,
  depth,
  visited,
  parent_signature
)
  -- Safety check for max depth
  local max_depth = math.min(M.config.call_hierarchy.max_depth, M.config.call_hierarchy.max_depth_limit)
  if depth > max_depth then
    callback()
    return
  end

  -- Create call item structure for LSP request
  local call_item = create_lsp_call_item(item)
  local method = "callHierarchy/" .. direction .. "Calls"

  make_call_hierarchy_request(method, { item = call_item }, function(err, call_result)
    if err then
      local error_message = format_lsp_error(err, "Unknown error")

      if depth == 1 then
        show_notification(
          "Error fetching "
            .. direction
            .. " calls: "
            .. error_message
            .. ". Ensure the cursor is over a proper symbol.",
          vim.log.levels.ERROR,
          notify_opts
        )
      else
        logger.log("Error fetching nested " .. direction .. " calls: " .. error_message)
      end

      callback()
      return
    end

    -- Process results if we got any
    if call_result and #call_result > 0 then
      -- Clone the visited set so each branch has its own history
      local branch_visited = vim.deepcopy(visited or {})

      -- Find parent position to insert children after
      local insert_pos = nil
      if parent_signature then
        insert_pos = find_parent_position(all_items, parent_signature)
      end

      -- If we found the parent, insert after it, otherwise add at the end
      local insertion_point = insert_pos or #all_items

      -- Create hierarchical tree state based on parent
      local parent_tree_state = nil
      if insert_pos and all_items[insert_pos].tree_state then
        parent_tree_state = vim.deepcopy(all_items[insert_pos].tree_state)
      end

      -- Convert to selecta items
      local items = calls_to_selecta_items(call_result, direction, depth, parent_tree_state, branch_visited)

      -- Process each item to add parent info and correct insertion
      local items_to_process = {}
      for i, new_item in ipairs(items) do
        -- Store the parent signature for hierarchy tracking
        new_item.value.parent_signature = parent_signature or item.value.signature

        -- Check if this signature has already been processed globally
        if not processed_call_signatures[new_item.value.signature] then
          -- Keep track of original position for determining if item is last in group
          new_item.original_index = i
          new_item.original_count = #items

          -- Mark as processed
          processed_call_signatures[new_item.value.signature] = true

          -- Add to list of items to process
          table.insert(items_to_process, new_item)
        end
      end

      -- Insert items at the right positions
      for i, new_item in ipairs(items_to_process) do
        -- If this item should expand, schedule it for processing
        local should_expand = new_item.value.should_expand
        new_item.value.should_expand = nil -- Clear flag

        -- Insert at the right position and increment for next siblings
        table.insert(all_items, insertion_point + i, new_item)

        -- If this item needs expansion, do it right after inserting to maintain hierarchy
        if should_expand then
          -- Add a pending request
          pending_requests = pending_requests + 1

          -- Process recursively
          fetch_calls_recursive(
            new_item,
            all_items,
            direction,
            notify_opts,
            callback,
            depth + 1,
            branch_visited,
            new_item.value.signature
          )
        end
      end
    end

    callback()
  end)
end

---Processes a call hierarchy item and fetches its calls
---@param item table Call hierarchy item
---@param direction string Call direction ("incoming", "outgoing", or "both")
---@param cache_key string Cache key for these results
---@param notify_opts table Notification options
local function process_call_hierarchy_item(item, direction, cache_key, notify_opts)
  -- Store symbol name for display
  state.current_symbol_name = item.name

  -- We'll collect results here
  local all_items = {}
  -- Global counter for pending requests
  pending_requests = 0
  -- Get the current position and file
  local current_pos = api.nvim_win_get_cursor(0)
  local current_file = vim.fn.expand("%:t")
  -- Add the current symbol with file info
  local current_item = {
    text = item.name .. " [" .. current_file .. ":" .. current_pos[1] .. "]",
    value = {
      text = item.name,
      name = item.name,
      kind = item.kind and lsp.symbol_kind(item.kind) or "Function",
      lnum = current_pos[1],
      col = current_pos[2] + 1,
      end_lnum = current_pos[1],
      end_col = current_pos[2] + 1 + #item.name,
      file_path = vim.fn.expand("%:p"),
      uri = vim.uri_from_bufnr(0),
      is_current = true,
      signature = "root", -- Special signature for the root item
    },
    icon = M.config.kindIcons[lsp.symbol_kind(item.kind)] or M.config.icon,
    kind = item.kind and lsp.symbol_kind(item.kind) or "Function",
    depth = 0,
  }
  table.insert(all_items, current_item)

  -- Initial visited set (start with the current item)
  local visited = {}
  visited[current_item.value.signature] = true

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
    fetch_calls_recursive(current_item, all_items, "incoming", notify_opts, handle_completion, 1, visited, "root")
  end

  -- Handle outgoing calls if requested
  if direction == CallDirection.OUTGOING or direction == CallDirection.BOTH then
    pending_requests = pending_requests + 1
    fetch_calls_recursive(current_item, all_items, "outgoing", notify_opts, handle_completion, 1, visited, "root")
  end

  -- If we didn't initiate any requests, show empty results
  if pending_requests == 0 then
    M.show_call_picker(all_items, notify_opts)
  end
end

local function apply_simple_highlights(buf, filtered_items, config)
  local ns_id = api.nvim_create_namespace("namu_callhierarchy_simple")
  api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  for idx, item in ipairs(filtered_items) do
    local line = idx - 1
    local lines = api.nvim_buf_get_lines(buf, line, line + 1, false)
    if #lines == 0 then
      goto continue
    end

    local line_text = lines[1]

    -- Get the kind's highlight group
    local kind = item.kind
    local kind_hl = config.kinds.highlights[kind] or "Identifier"

    -- Find where the file info starts
    local file_pattern = "%[.+:%d+%]"
    local file_start = line_text:find(file_pattern)

    if file_start then
      -- Highlight from beginning to file info with kind highlight
      api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
        end_row = line,
        end_col = file_start - 1, -- Up to file info
        hl_group = kind_hl,
        priority = 110, -- Higher than selecta's default (100)
      })

      -- Highlight the file info
      local file_text = line_text:match(file_pattern)
      api.nvim_buf_set_extmark(buf, ns_id, line, file_start - 1, {
        end_row = line,
        end_col = file_start - 1 + #file_text,
        hl_group = "NamuFileInfo",
        priority = 100, -- Same as selecta's default
      })

      -- Check if there's a recursive marker
      local recursive_text = " %(recursive%)"
      local recursive_start = line_text:find(recursive_text, file_start + #file_text - 1)
      if recursive_start then
        api.nvim_buf_set_extmark(buf, ns_id, line, recursive_start - 1, {
          end_row = line,
          end_col = recursive_start - 1 + #recursive_text,
          hl_group = "WarningMsg",
          priority = 110, -- Higher than file info
        })
      end
    else
      -- If no file info, highlight the entire line
      api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
        end_row = line,
        end_col = #line_text,
        hl_group = kind_hl,
        priority = 110, -- Higher than selecta's default
      })
    end

    ::continue::
  end
end

function M.show_call_picker(selectaItems, notify_opts)
  if #selectaItems <= 1 then
    show_notification("No call hierarchy items found.", vim.log.levels.INFO, notify_opts)
    return
  end
  -- Super simple approach: deduplicate based on name + file
  local unique_map = {}
  local unique_items = {}

  for _, item in ipairs(selectaItems) do
    -- Create a simple key based on name and file (like the other implementation)
    local file_part = item.value.file_path:match("([^/\\]+)$") or item.value.file_path
    local simple_key = item.value.name .. "@" .. file_part

    -- Only keep the first occurrence of each unique key
    if not unique_map[simple_key] then
      unique_map[simple_key] = true
      table.insert(unique_items, item)
    end
  end

  if M.config.sort_by_nesting_depth and navigation.sort_by_nesting_depth then
    unique_items = navigation.sort_by_nesting_depth(unique_items)
  else
    -- Only update tree guides manually if we didn't sort
    if navigation and navigation.update_tree_guides_after_sorting then
      unique_items = navigation.update_tree_guides_after_sorting(unique_items)
    end
  end

  -- Create a custom formatter that properly handles tree guides and icons
  local formatter = function(item)
    -- Handle current highlight prefix padding
    local prefix_padding = ""
    if M.config.current_highlight.enabled and #M.config.current_highlight.prefix_icon > 0 then
      prefix_padding = string.rep(" ", api.nvim_strwidth(M.config.current_highlight.prefix_icon))
    end

    -- Get the tree guides if available
    local guides = ""
    if item.tree_state then
      guides = make_tree_guides(item.tree_state)
    end

    -- Get the appropriate icon based on kind
    local icon = item.icon or M.config.kindIcons[item.kind] or "  "

    local indicator = ""
    if item.value.is_current then
      indicator = "▼ "
    end
    -- Extract the clean name and file info
    local name_and_info = item.text
    -- Visual indicator for parent items that were included but didn't match search
    -- local style = ""
    -- if item.is_parent_match then
    --   style = "dim"
    -- end

    return prefix_padding .. guides .. indicator .. icon .. " " .. name_and_info
  end
  -- Sort items by nesting depth before showing the picker
  -- selectaItems = navigation.sort_by_nesting_depth(selectaItems)

  local picker_opts = {
    title = M.config.title or " Namu Call Hierarchy ",
    fuzzy = false,
    preserve_order = true,
    window = M.config.window,
    display = M.config.display,
    auto_select = M.config.auto_select,
    initially_hidden = M.config.initially_hidden,
    movement = vim.tbl_deep_extend("force", M.config.movement, {}),
    current_highlight = M.config.current_highlight,
    row_position = M.config.row_position,
    debug = M.config.debug,
    custom_keymaps = M.config.custom_keymaps,
    formatter = formatter,
    -- Enable hierarchical filtering
    preserve_hierarchy = M.config.preserve_hierarchy,
    -- Define how to find an item's parent
    parent_key = function(item)
      -- Return the parent signature or "root" if this is the top level
      return item.value and item.value.parent_signature or "root"
    end,
    always_include_root = true, -- Always include the root item in results
    root_item_first = true, -- Make sure the root item appears first
    is_root_item = function(item)
      return item.value and item.value.is_current
    end,
    pre_filter = function(items, query)
      local filter = symbol_utils.parse_symbol_filter(query, M.config)
      if filter then
        local kinds_lower = vim.tbl_map(string.lower, filter.kinds)
        local filtered = vim.tbl_filter(function(item)
          return item.kind and vim.tbl_contains(kinds_lower, string.lower(item.kind))
        end, items)
        return filtered, filter.remaining
      end
      return items, query
    end,
    hooks = {
      on_render = function(buf, filtered_items)
        apply_simple_highlights(buf, filtered_items, M.config)
      end,
      on_buffer_clear = function() end,
    },
    multiselect = {
      enabled = M.config.multiselect.enabled,
      indicator = M.config.multiselect.indicator,
      -- TODO: make logic here
      -- on_select = function(item) end,
    },
    on_select = function(item)
      if not item or not item.value then
        logger.log("Invalid item for selection")
        return
      end
      local cache_eventignore = vim.o.eventignore
      vim.o.eventignore = "BufEnter"

      pcall(function()
        -- Set mark for jumplist
        api.nvim_win_call(state.original_win, function()
          vim.cmd("normal! m'")
        end)

        -- Open file using edit_file function
        local file_path = item.value.file_path
        local buf_id = preview_utils.edit_file(file_path, state.original_win)
        if buf_id then
          api.nvim_win_set_cursor(state.original_win, { item.value.lnum, 0 })
          api.nvim_win_call(state.original_win, function()
            vim.cmd("normal! zz")
          end)
        end
      end)

      vim.o.eventignore = cache_eventignore
    end,
    on_cancel = function()
      -- Clear highlights
      api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
      if
        state.preview_state
        and state.preview_state.scratch_buf
        and api.nvim_buf_is_valid(state.preview_state.scratch_buf)
      then
        api.nvim_buf_clear_namespace(state.preview_state.scratch_buf, state.preview_ns, 0, -1)
      end
      -- Restore original window state
      if state.preview_state then
        preview_utils.restore_window_state(state.original_win, state.preview_state)
      else
        -- Fallback restoration
        if
          state.original_win
          and state.original_pos
          and state.original_buf
          and api.nvim_win_is_valid(state.original_win)
          and api.nvim_buf_is_valid(state.original_buf)
        then
          api.nvim_set_current_win(state.original_win)
          api.nvim_win_set_buf(state.original_win, state.original_buf)
          api.nvim_win_set_cursor(state.original_win, state.original_pos)
        end
      end
    end,
    on_move = function(item)
      if not state.original_win or not api.nvim_win_is_valid(state.original_win) then
        logger.log("Invalid original window")
        return
      end

      preview_callhierarchy_item(item, state.original_win)
    end,
  }

  -- Add custom prefix highlighter if needed
  if M.config.kinds.prefix_kind_colors then
    picker_opts.prefix_highlighter = function(buf, line_nr, item, icon_end, ns_id)
      local kind_hl = M.config.kinds.highlights[item.kind]
      if kind_hl then
        api.nvim_buf_set_extmark(buf, ns_id, line_nr, 0, {
          end_col = icon_end,
          hl_group = kind_hl,
          priority = 100,
          hl_mode = "combine",
        })
      end
    end
  end

  local picker_win = selecta.pick(unique_items, picker_opts)

  if picker_win then
    local augroup = api.nvim_create_augroup("NamuCallHierarchyCleanup", { clear = true })
    api.nvim_create_autocmd("WinClosed", {
      group = augroup,
      pattern = tostring(picker_win),
      callback = function()
        pcall(api.nvim_del_augroup_by_name, "NamuCallHierarchyCleanup")
      end,
      once = true,
    })
  end
end

---Show call hierarchy picker with incoming/outgoing calls
---@param direction? string "incoming", "outgoing", or "both"
function M.show(direction)
  direction = direction or CallDirection.BOTH
  processed_call_signatures = {}
  notification_shown = false

  state.original_win = api.nvim_get_current_win()
  state.original_buf = api.nvim_get_current_buf()
  state.original_pos = api.nvim_win_get_cursor(0)
  if not state.preview_state then
    state.preview_state = preview_utils.create_preview_state("callhierarchy_preview")
  end
  -- Save state on first move
  preview_utils.save_window_state(state.original_win, state.preview_state)
  -- Get the symbol name at cursor for better display
  local cword = vim.fn.expand("<cword>")
  state.current_symbol_name = cword

  -- Set highlight
  api.nvim_set_hl(0, M.config.highlight, {
    link = "Visual",
  })

  local notify_opts = { title = "Namu Call Hierarchy", icon = M.config.icon }

  -- Cache key includes buffer, position, and direction
  local bufnr = api.nvim_get_current_buf()
  local cursor_pos = api.nvim_win_get_cursor(0)
  local cache_key = string.format("%d_%d_%d_%s", bufnr, cursor_pos[1], cursor_pos[2], direction)

  -- Check cache first
  if calls_cache[cache_key] then
    logger.log("Using cached call hierarchy data")
    local selectaItems = calls_cache[cache_key]
    M.show_call_picker(selectaItems, notify_opts)
    return
  end

  -- Check what call hierarchy capabilities are supported
  local support = check_call_hierarchy_support(bufnr)

  -- If standard prepare is supported, use it
  if support.prepare then
    local params = lsp.make_position_params(bufnr)
    make_call_hierarchy_request("textDocument/prepareCallHierarchy", params, function(err, result)
      if err then
        local error_message = format_lsp_error(err, "Unknown error")
        show_notification("Error preparing call hierarchy: " .. error_message, vim.log.levels.ERROR, notify_opts)
        return
      end

      if not result or #result == 0 then
        show_notification(
          "No call hierarchy items found at cursor position.\n Ensure the cursor is over a proper symbol.",
          vim.log.levels.WARN,
          notify_opts
        )

        return
      end

      -- Process the first item (typically there's only one)
      process_call_hierarchy_item(result[1], direction, cache_key, notify_opts)
    end)
    -- If specific methods are supported but not prepare, use a synthetic item
  elseif
    (direction == CallDirection.INCOMING and support.incoming)
    or (direction == CallDirection.OUTGOING and support.outgoing)
    or (direction == CallDirection.BOTH and (support.incoming or support.outgoing))
  then
    local synthetic_item = create_synthetic_call_item()
    process_call_hierarchy_item(synthetic_item, direction, cache_key, notify_opts)
  else
    -- No support for required call hierarchy methods
    show_notification("No LSP client supports the required call hierarchy methods", vim.log.levels.WARN, notify_opts)
  end
end

-- API functions for different call directions with config parameter
function M.show_incoming_calls()
  M.show(CallDirection.INCOMING)
end

function M.show_outgoing_calls()
  M.show(CallDirection.OUTGOING)
end

function M.show_both_calls()
  M.show(CallDirection.BOTH)
end

return M
