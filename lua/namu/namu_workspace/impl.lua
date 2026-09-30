-- Dependencies are only loaded when the module is actually used
local impl = {}
local selecta
local api = vim.api
-- These get loaded only when needed
local function load_deps()
  impl.selecta = require("namu.selecta.selecta")
  impl.lsp = require("namu.namu_symbols.lsp")
  impl.symbol_utils = require("namu.core.symbol_utils")
  impl.preview_utils = require("namu.core.preview_utils")
  impl.logger = require("namu.utils.logger")
  impl.format_utils = require("namu.core.format_utils")
  impl.highlights = require("namu.core.highlights")
  impl.utils = require("namu.core.utils")
end
local symbol_utils = require("namu.core.symbol_utils")
local ui = require("namu.namu_symbols.ui")
local ext = require("namu.namu_symbols.external_plugins")
local utils = require("namu.namu_symbols.utils")

-- Create state for storing data between functions
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = api.nvim_create_namespace("workspace_preview"),
  preview_state = nil,
  symbols = {},
  current_request = nil,
}

---Open diagnostic in vertical split
---@param config table
---@param items_or_item table|table[]
---@param module_state table
function impl.open_in_vertical_split(config, items_or_item, module_state)
  local item = vim.islist(items_or_item) and items_or_item[1] or items_or_item
  impl.selecta.open_in_split(item, "vertical", state)
  return false
end

---Open diagnostic in horizontal split
---@param config table
---@param items_or_item table|table[]
---@param module_state table
function impl.open_in_horizontal_split(config, items_or_item, module_state)
  local item = vim.islist(items_or_item) and items_or_item[1] or items_or_item
  impl.selecta.open_in_split(item, "horizontal", state)
  return false
end

-- Format symbol text for display
local function format_symbol_text(symbol, file_path)
  local name = symbol.name
  local kind = impl.lsp.symbol_kind(symbol.kind)
  local range = symbol.location.range
  local line = range.start.line + 1
  local col = range.start.character + 1
  -- Get the workspace root
  local workspace_root = vim.uv.cwd()
  -- Get filename relative to workspace root
  local rel_path = file_path
  if workspace_root and vim.startswith(file_path, workspace_root) then
    rel_path = file_path:sub(#workspace_root + 2) -- +2 to remove the trailing slash
  else
    -- Fallback to just the filename if not in workspace
    rel_path = vim.fn.fnamemodify(file_path, ":t")
  end
  -- Get file icon for the path
  local file_icon, _ = impl.utils.get_file_icon(file_path)
  local icon_str = file_icon and (file_icon .. " ") or ""
  -- Use the relative path in the formatted string with icon
  return string.format("%s [%s] - %s%s:%d", name, kind, icon_str, rel_path, line)
end

-- Convert LSP workspace symbols to selecta items
local function symbols_to_selecta_items(symbols, config)
  local items = {}

  for _, symbol in ipairs(symbols) do
    -- Get symbol information
    local kind = impl.lsp.symbol_kind(symbol.kind)
    local icon = config.kindIcons[kind] or "󰉻"

    -- Extract file information
    local file_path = symbol.location.uri:gsub("file://", "")
    -- TODO: why we need bufadd???????
    -- local bufnr = vim.fn.bufadd(file_path)

    -- Create range information
    local range = symbol.location.range
    local row = range.start.line
    local col = range.start.character
    local end_row = range["end"].line
    local end_col = range["end"].character

    -- Create selecta item
    local item = {
      text = format_symbol_text(symbol, file_path),
      value = {
        name = symbol.name,
        kind = kind,
        lnum = row,
        col = col,
        end_lnum = end_row,
        end_col = end_col,
        -- bufnr = bufnr,
        file_path = file_path,
        symbol = symbol,
      },
      icon = icon,
      kind = kind,
    }

    table.insert(items, item)
  end

  return items
end

local function preview_workspace_item(item, win_id)
  if not state.preview_state then
    state.preview_state = impl.preview_utils.create_preview_state("workspace_preview")
    state.preview_state.original_win = win_id
  end
  impl.preview_utils.preview_symbol(item, win_id, state.preview_state, {
    -- TODO: decide on this one later
    -- highlight_group = impl.highlights.get_bg_highlight(state.config.highlight),
    -- highlight_fn = function(buf, ns, item)
    --   -- Add custom highlighting for workspace items
    --   local value = item.value
    --   pcall(api.nvim_buf_set_extmark, buf, ns, value.lnum, value.col, {
    --     end_row = value.end_lnum,
    --     end_col = value.end_col,
    --     hl_group = state.config.highlight,
    --     priority = 200,
    --   })
    -- end
  })
end

-- Track last highlight time to debounce rapid updates
local last_highlight_time = 0

local function apply_workspace_highlights(buf, filtered_items, config)
  -- Debounce highlights during rapid updates (e.g., during typing)
  local current_time = vim.uv.hrtime()
  if (current_time - last_highlight_time) < 50 then -- 50ms debounce
    impl.logger.log("Debouncing highlight - skipping this update")
    return
  end
  last_highlight_time = current_time

  local ns_id = api.nvim_create_namespace("namu_workspace_picker")
  api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  -- Early exit if no valid buffer or items
  if not api.nvim_buf_is_valid(buf) or not filtered_items or #filtered_items == 0 then
    impl.logger.log("apply_workspace_highlights: early exit - invalid buffer or no items")
    return
  end
  -- Get visible range information
  local first_visible = 0
  local last_visible = #filtered_items - 1 -- Default to all items
  -- Cache the line count for efficiency
  local line_count = api.nvim_buf_line_count(buf)
  first_visible = math.max(0, first_visible)
  last_visible = math.min(line_count - 1, last_visible)
  -- Get all visible lines at once for efficiency
  local visible_lines = {}
  if last_visible >= first_visible then
    visible_lines = api.nvim_buf_get_lines(buf, first_visible, last_visible + 1, false)
  end
  -- Process only the visible lines
  for i, line_text in ipairs(visible_lines) do
    local line_idx = first_visible + i - 1
    local item_idx = line_idx + 1 -- Convert back to 1-based for item lookup

    -- Ensure we're within bounds of filtered_items
    if item_idx > #filtered_items then
      break
    end

    local item = filtered_items[item_idx]
    if not item or not item.value then
      goto continue
    end

    local value = item.value
    local kind = value.kind
    local kind_hl = config.kinds.highlights[kind] or "Identifier"

    -- Find parts to highlight
    local name_end = line_text:find("%[")
    if not name_end then
      goto continue
    end
    name_end = name_end - 2

    local kind_start = name_end + 2
    local kind_end = line_text:find("%]", kind_start)
    if not kind_end then
      goto continue
    end

    local file_start = line_text:find("-")
    if not file_start then
      goto continue
    end
    file_start = file_start + 2

    -- Highlight symbol name
    api.nvim_buf_set_extmark(buf, ns_id, line_idx, 0, {
      end_row = line_idx,
      end_col = name_end,
      hl_group = kind_hl,
      priority = 110,
    })

    -- Highlight kind with the same highlight group as the symbol name
    api.nvim_buf_set_extmark(buf, ns_id, line_idx, kind_start - 1, {
      end_row = line_idx,
      end_col = kind_end,
      hl_group = kind_hl, -- Now using same highlight as symbol name
      priority = 110,
    })

    -- Split file path and filename for separate highlighting
    local file_path_text = line_text:sub(file_start)
    local last_slash_pos = file_path_text:match(".*/()")

    -- Find the icon part of the text if it exists
    local icon_end = file_start
    local icon_match = file_path_text:match("^(.-) ")

    -- Only consider it an icon if it's reasonably short (icons are typically 1-2 chars)
    if icon_match and vim.fn.strwidth(icon_match) <= 2 then
      local _, icon_hl = impl.utils.get_file_icon(value.file_path)
      -- Highlight the icon with icon_hl (use the same highlight as the symbol)
      api.nvim_buf_set_extmark(buf, ns_id, line_idx, file_start - 1, {
        end_row = line_idx,
        end_col = file_start + #icon_match,
        hl_group = icon_hl, -- Use same highlight as the symbol name and kind
        priority = 120,
      })

      -- Skip the icon and space for highlighting the rest of the path
      icon_end = file_start + #icon_match + 1
    end

    if last_slash_pos then
      -- We have a path and filename to separate
      local path_end = file_start + last_slash_pos - 2

      -- Highlight directory path as Comment
      api.nvim_buf_set_extmark(buf, ns_id, line_idx, icon_end - 1, {
        end_row = line_idx,
        end_col = path_end,
        hl_group = "Comment",
        priority = 110,
      })

      -- Highlight filename with same highlight as symbol
      api.nvim_buf_set_extmark(buf, ns_id, line_idx, path_end, {
        end_row = line_idx,
        end_col = #line_text,
        hl_group = kind_hl,
        priority = 110,
      })
    else
      -- No path separator, just a filename - highlight with symbol highlight
      api.nvim_buf_set_extmark(buf, ns_id, line_idx, icon_end - 1, {
        end_row = line_idx,
        end_col = #line_text,
        hl_group = kind_hl,
        priority = 110,
      })
    end
    ::continue::
  end
end

local function create_async_symbol_source(original_buf, config)
  return function(query)
    -- Return a function that will handle the async processing
    local process_fn = function(callback)
      -- Make the LSP request directly
      impl.lsp.request_symbols(original_buf, "workspace/symbol", function(err, symbols, ctx)
        if err then
          impl.logger.log("❌ LSP error: " .. tostring(err))
          callback({}) -- Empty results on error
          return
        end
        if not symbols or #symbols == 0 then
          impl.logger.log("⚠️ No symbols returned from LSP")
          callback({}) -- Empty results when no symbols
          return
        end
        -- Process the symbols into selecta items
        local items = symbols_to_selecta_items(symbols, config)
        -- Return the processed items via callback
        callback(items)
      end, { query = query or "" })
    end
    return process_fn
  end
end

-- Show workspace symbols picker with optional query
function impl.show_with_query(config, query, opts)
  load_deps()
  local notify_opts = { title = "Namu", icon = config.icon }
  -- Check LSP availability first
  if not impl.lsp.has_capability("workspaceSymbolProvider") then
    vim.notify("No LSP server with workspace symbol support found", vim.log.levels.WARN, notify_opts)
    return
  end
  state.config = config
  state.original_win = api.nvim_get_current_win()
  state.original_buf = api.nvim_get_current_buf()
  state.original_pos = api.nvim_win_get_cursor(state.original_win)

  local handlers = nil
  handlers = symbol_utils.create_keymaps_handlers(config, state, ui, impl.selecta, ext, utils)
  -- Update keymap handlers
  config.custom_keymaps.vertical_split.handler = handlers.vertical_split
  config.custom_keymaps.horizontal_split.handler = handlers.horizontal_split
  config.custom_keymaps.quickfix.handler = handlers.quickfix
  config.custom_keymaps.sidebar.handler = handlers.sidebar

  -- Save window state for potential restoration
  if not state.preview_state then
    state.preview_state = impl.preview_utils.create_preview_state("workspace_preview")
  end
  impl.preview_utils.save_window_state(state.original_win, state.preview_state)
  opts = opts or {}
  -- Create placeholder items to show even when no initial symbols
  local placeholder_items = {
    {
      text = query and query ~= "" and "Searching for symbols matching '" .. query .. "'..."
        or "Type to search for workspace symbols...",
      icon = "󰍉",
      value = nil,
      is_placeholder = true,
    },
  }
  -- Make LSP request
  impl.lsp.request_symbols(state.original_buf, "workspace/symbol", function(err, symbols, ctx)
    local initial_items = placeholder_items

    if err then
      vim.notify("Error fetching workspace symbols: " .. tostring(err), vim.log.levels.WARN, notify_opts)
      return
    elseif symbols and #symbols > 0 then
      -- If we got actual symbols, use them
      initial_items = symbols_to_selecta_items(symbols, config)
    end

    -- Always show picker, even with placeholder items
    local prompt_info = {
      text = " type to search",
      -- pos = "eol",
      hl_group = "Comment",
    }
    impl.selecta.pick(
      initial_items,
      vim.tbl_deep_extend("force", config, {
        title = config.title or " Workspace Symbols ",
        initial_prompt_info = prompt_info,
        config,
        async_source = create_async_symbol_source(state.original_buf, config),
        pre_filter = function(items, input_query)
          local filter = impl.symbol_utils.parse_symbol_filter(input_query, config)
          if filter then
            local filtered = vim.tbl_filter(function(item)
              return vim.tbl_contains(filter.kinds, item.kind)
            end, items)
            return filtered, filter.remaining
          end
          return items, input_query
        end,

        hooks = {
          on_render = function(buf, filtered_items)
            -- The context from selecta contains information about visible lines
            -- which our improved apply_workspace_highlights will use
            apply_workspace_highlights(buf, filtered_items, config)
          end,
        },

        on_move = function(item)
          if item and item.value then
            -- preview_symbol(item, state.original_win)
            preview_workspace_item(item, state.original_win)
          end
        end,

        on_select = function(item)
          if not item or not item.value then
            impl.logger.log("Invalid item for selection")
            return
          end
          local cache_eventignore = vim.o.eventignore
          vim.o.eventignore = "BufEnter"
          pcall(function()
            api.nvim_win_call(state.original_win, function()
              vim.cmd("normal! m'")
            end)
            local value = item.value
            local buf_id = impl.preview_utils.edit_file(value.file_path, state.original_win)
            if buf_id then
              api.nvim_win_set_cursor(state.original_win, {
                value.lnum + 1,
                value.col,
              })
              api.nvim_win_call(state.original_win, function()
                vim.cmd("normal! zz")
                -- Set alternate buffer
                vim.fn.setreg("#", state.original_buf)
              end)
            end
          end)
          vim.o.eventignore = cache_eventignore
        end,

        on_cancel = function()
          if api.nvim_buf_is_valid(state.original_buf) then
            api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
          end
          if
            state.preview_state
            and state.preview_state.scratch_buf
            and api.nvim_buf_is_valid(state.preview_state.scratch_buf)
          then
            api.nvim_buf_clear_namespace(state.preview_state.scratch_buf, state.preview_ns, 0, -1)
          end

          if state.preview_state then
            impl.preview_utils.restore_window_state(state.original_win, state.preview_state)
          else
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
      })
    )
  end, { query = query or "" })
end

function impl.show(config, opts)
  return impl.show_with_query(config, "", opts)
end

return impl
