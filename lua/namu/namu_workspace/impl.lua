-- Dependencies are only loaded when the module is actually used
local impl = {}

-- These get loaded only when needed
local function load_deps()
  impl.selecta = require("namu.selecta.selecta").pick
  impl.lsp = require("namu.namu_symbols.lsp")
  impl.symbol_utils = require("namu.core.symbol_utils")
  impl.preview_utils = require("namu.core.preview_utils")
  impl.logger = require("namu.utils.logger")
  impl.format_utils = require("namu.core.format_utils")
  impl.highlights = require("namu.core.highlights")
end

-- Create state for storing data between functions
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = vim.api.nvim_create_namespace("workspace_preview"),
  preview_state = nil,
  symbols = {},
  current_request = nil,
}

-- Get file icon for the file path
local function get_file_icon(file_path)
  -- Extract the file name from the path
  local filename = vim.fs.basename(file_path)
  local extension = filename:match("%.([^%.]+)$")

  -- Try to get icon from mini.icons
  local icon, icon_hl, is_default
  local mini_icons_ok, mini_icons = pcall(require, "mini.icons")
  if mini_icons_ok then
    -- First try with exact filename
    icon, icon_hl, is_default = mini_icons.get("file", filename)

    -- If it's a default icon and we have an extension, try by extension
    if is_default and extension then
      local ext_icon, ext_hl, ext_is_default = mini_icons.get("extension", extension)
      if not ext_is_default then
        icon, icon_hl = ext_icon, ext_hl
      end
    end
  else
    -- Fall back to nvim-web-devicons
    local devicons_ok, devicons = pcall(require, "nvim-web-devicons")
    if devicons_ok then
      local dev_icon, dev_hl = devicons.get_icon(filename, extension, { default = true })
      if dev_icon then
        icon, icon_hl = dev_icon, dev_hl
      end
    end
  end

  -- If we still don't have an icon, provide a safe default
  if not icon then
    icon = "󰈔" -- Default file icon
    icon_hl = "Normal"
  end

  return icon, icon_hl
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
  local file_icon, _ = get_file_icon(file_path)
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
    --   pcall(vim.api.nvim_buf_set_extmark, buf, ns, value.lnum, value.col, {
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

  local ns_id = vim.api.nvim_create_namespace("namu_workspace_picker")
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  -- Early exit if no valid buffer or items
  if not vim.api.nvim_buf_is_valid(buf) or not filtered_items or #filtered_items == 0 then
    impl.logger.log("apply_workspace_highlights: early exit - invalid buffer or no items")
    return
  end
  -- Get visible range information
  local first_visible = 0
  local last_visible = #filtered_items - 1 -- Default to all items
  -- Cache the line count for efficiency
  local line_count = vim.api.nvim_buf_line_count(buf)
  first_visible = math.max(0, first_visible)
  last_visible = math.min(line_count - 1, last_visible)
  -- Get all visible lines at once for efficiency
  local visible_lines = {}
  if last_visible >= first_visible then
    visible_lines = vim.api.nvim_buf_get_lines(buf, first_visible, last_visible + 1, false)
  end
  impl.logger.log(
    string.format("Highlighting %d visible lines from %d to %d", #visible_lines, first_visible, last_visible)
  )
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
    vim.api.nvim_buf_set_extmark(buf, ns_id, line_idx, 0, {
      end_row = line_idx,
      end_col = name_end,
      hl_group = kind_hl,
      priority = 110,
    })

    -- Highlight kind with the same highlight group as the symbol name
    vim.api.nvim_buf_set_extmark(buf, ns_id, line_idx, kind_start - 1, {
      end_row = line_idx,
      end_col = kind_end,
      hl_group = kind_hl, -- Now using same highlight as symbol name
      priority = 110,
    })

    -- Split file path and filename for separate highlighting
    local file_path_text = line_text:sub(file_start)
    local last_slash_pos = file_path_text:match(".*/()")

    -- Get file icon for the file path
    local function get_file_icon(file_path)
      -- Extract the file name from the path
      local filename = vim.fs.basename(file_path)
      local extension = filename:match("%.([^%.]+)$")

      -- Try to get icon from mini.icons
      local icon, icon_hl, is_default
      local mini_icons_ok, mini_icons = pcall(require, "mini.icons")
      if mini_icons_ok then
        -- First try with exact filename
        icon, icon_hl = mini_icons.get("file", filename)

        -- If it's a default icon and we have an extension, try by extension
        if is_default and extension then
          local ext_icon, ext_hl, ext_is_default = mini_icons.get("extension", extension)
          if not ext_is_default then
            icon, icon_hl = ext_icon, ext_hl
          end
        end
      else
        -- Fall back to nvim-web-devicons
        local devicons_ok, devicons = pcall(require, "nvim-web-devicons")
        if devicons_ok then
          local dev_icon, dev_hl = devicons.get_icon(filename, extension, { default = true })
          if dev_icon then
            icon, icon_hl = dev_icon, dev_hl
          end
        end
      end

      -- If we still don't have an icon, provide a safe default
      if not icon then
        icon = "󰈔" -- Default file icon
        icon_hl = "Normal"
      end

      return icon, icon_hl
    end

    local file_icon, icon_hl
    if last_slash_pos then
      -- Get full filename
      local filename = file_path_text:sub(last_slash_pos)
      file_icon, icon_hl = get_file_icon(value.file_path)
    else
      file_icon, icon_hl = get_file_icon(value.file_path)
    end

    -- Insert the icon with appropriate highlight
    if file_icon then
      -- Create icon with appropriate spacing
      local icon_width = vim.fn.strdisplaywidth(file_icon)
      local icon_text = file_icon .. " "

      -- Add icon at the beginning of file path
      vim.api.nvim_buf_set_extmark(buf, ns_id, line_idx, file_start - 1, {
        virt_text = { { icon_text, icon_hl } },
        virt_text_pos = "overlay",
        priority = 120,
      })

      -- Adjust file_start to account for the icon we've added
      local icon_offset = icon_width + 1 -- icon width + space
    end

    if last_slash_pos then
      -- We have a path and filename to separate
      local path_end = file_start + last_slash_pos - 2

      -- Highlight directory path as Comment
      vim.api.nvim_buf_set_extmark(buf, ns_id, line_idx, file_start - 1, {
        end_row = line_idx,
        end_col = path_end,
        hl_group = "Comment",
        priority = 110,
      })

      -- Highlight filename with same highlight as symbol
      vim.api.nvim_buf_set_extmark(buf, ns_id, line_idx, path_end, {
        end_row = line_idx,
        end_col = #line_text,
        hl_group = kind_hl,
        priority = 110,
      })
    else
      -- No path separator, just a filename - highlight with symbol highlight
      vim.api.nvim_buf_set_extmark(buf, ns_id, line_idx, file_start - 1, {
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
    impl.logger.log("📬 Creating async source for query: '" .. query .. "'")

    -- Return a function that will handle the async processing
    local process_fn = function(callback)
      impl.logger.log("📡 Making LSP request for query: " .. query)

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

        impl.logger.log("📦 Got " .. #symbols .. " symbols from LSP")

        -- Process the symbols into selecta items
        local items = symbols_to_selecta_items(symbols, config)
        impl.logger.log("✅ Processed " .. #items .. " items from symbols")

        -- Return the processed items via callback
        callback(items)
      end, { query = query or "" })
    end

    return process_fn
  end
end

-- Show workspace symbols picker with optional query
function impl.show_with_query(config, query, opts)
  -- Load dependencies
  load_deps()

  -- Save state
  state.config = config
  state.original_win = vim.api.nvim_get_current_win()
  state.original_buf = vim.api.nvim_get_current_buf()
  state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)

  -- Save window state for potential restoration
  if not state.preview_state then
    state.preview_state = impl.preview_utils.create_preview_state("workspace_preview")
  end

  impl.preview_utils.save_window_state(state.original_win, state.preview_state)

  -- Set options
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
      vim.notify("Error fetching workspace symbols: " .. tostring(err), vim.log.levels.WARN)
    elseif symbols and #symbols > 0 then
      -- If we got actual symbols, use them
      initial_items = symbols_to_selecta_items(symbols, config)
    else
      -- Some LSPs require a query - no need for notification here
      -- logger.log("No initial workspace symbols found - LSP may require a query")
    end

    -- Always show picker, even with placeholder items
    impl.selecta(initial_items, {
      title = "Workspace Symbols ",
      window = config.window,
      current_highlight = config.current_highlight,
      debug = config.debug,
      custom_keymaps = config.custom_keymaps,
      preserve_order = true,

      -- Add coroutine-based async source
      async_source = create_async_symbol_source(state.original_buf, config),

      -- Rest of options remain the same as before
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

      formatter = function(item)
        local prefix_padding = ""
        if
          config.current_highlight
          and config.current_highlight.enabled
          and config.current_highlight.prefix_icon
          and #config.current_highlight.prefix_icon > 0
        then
          prefix_padding = string.rep(" ", vim.api.nvim_strwidth(config.current_highlight.prefix_icon))
        end
        return prefix_padding .. item.text
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
        impl.logger.log(string.format("Selected symbol: %s at line %d", item.value.name, item.value.lnum))
        -- -- Clean up preview state
        -- if
        --   state.preview_state
        --   and state.preview_state.scratch_buf
        --   and vim.api.nvim_buf_is_valid(state.preview_state.scratch_buf)
        -- then
        --   vim.api.nvim_buf_delete(state.preview_state.scratch_buf, { force = true })
        --   state.preview_state.scratch_buf = nil
        -- end
        local cache_eventignore = vim.o.eventignore
        vim.o.eventignore = "BufEnter"
        pcall(function()
          -- Set mark for jumplist
          vim.api.nvim_win_call(state.original_win, function()
            vim.cmd("normal! m'")
          end)

          -- Jump to file position using the shared edit_file function
          local value = item.value
          local buf_id = impl.preview_utils.edit_file(value.file_path, state.original_win)

          -- Set cursor position
          if buf_id then
            vim.api.nvim_win_set_cursor(state.original_win, {
              value.lnum + 1,
              value.col,
            })
            vim.api.nvim_win_call(state.original_win, function()
              vim.cmd("normal! zz")
            end)
          end
        end)

        vim.o.eventignore = cache_eventignore
      end,

      on_cancel = function()
        -- Clear highlights
        vim.api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
        if
          state.preview_state
          and state.preview_state.scratch_buf
          and vim.api.nvim_buf_is_valid(state.preview_state.scratch_buf)
        then
          vim.api.nvim_buf_clear_namespace(state.preview_state.scratch_buf, state.preview_ns, 0, -1)
        end

        -- Restore original window state
        if state.preview_state then
          impl.preview_utils.restore_window_state(state.original_win, state.preview_state)
        else
          -- Fallback restoration
          if
            state.original_win
            and state.original_pos
            and state.original_buf
            and vim.api.nvim_win_is_valid(state.original_win)
            and vim.api.nvim_buf_is_valid(state.original_buf)
          then
            vim.api.nvim_win_set_buf(state.original_win, state.original_buf)
            vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
          end
        end
      end,
    })
  end, { query = query or "" })
end

-- Default show function (empty query)
function impl.show(config, opts)
  return impl.show_with_query(config, "", opts)
end

return impl
