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

-- Format symbol text for display
local function format_symbol_text(symbol, file_path)
  local name = symbol.name
  local kind = impl.lsp.symbol_kind(symbol.kind)
  local range = symbol.location.range
  local line = range.start.line + 1
  local col = range.start.character + 1
  local filename = vim.fn.fnamemodify(file_path, ":t")

  return string.format("%s [%s] - %s:%d", name, kind, filename, line)
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

  -- BUG: NO need for this one
  -- Sort items by kind, then by name
  -- table.sort(items, function(a, b)
  --   if a.kind == b.kind then
  --     return a.value.name < b.value.name
  --   end
  --   return a.kind < b.kind
  -- end)
  impl.logger.log("✅ Converted " .. #items .. " items")
  return items
end

-- Preview symbol in its file
local function preview_symbol(item, win_id)
  if not item or not item.value then
    return
  end

  local value = item.value
  local file_path = value.file_path

  -- Initialize preview state if needed
  if not state.preview_state then
    state.preview_state = impl.preview_utils.create_preview_state("workspace_preview")
    state.preview_state.original_win = win_id
  end

  -- Check if we have a valid buffer for this file already
  local bufnr = vim.fn.bufadd(file_path)
  local is_loaded = vim.api.nvim_buf_is_loaded(bufnr)

  if is_loaded then
    -- Use existing buffer
    vim.api.nvim_win_call(win_id, function()
      vim.api.nvim_win_set_buf(win_id, bufnr)

      -- Set cursor position and center
      pcall(vim.api.nvim_win_set_cursor, win_id, {
        value.lnum + 1,
        value.col,
      })
      vim.cmd("normal! zz")

      -- Highlight the symbol
      vim.api.nvim_buf_clear_namespace(bufnr, state.preview_ns, 0, -1)

      -- Get highlight group
      local hl_group = impl.highlights.get_bg_highlight(state.config.highlight)

      -- Apply background highlight for the entire line
      pcall(vim.api.nvim_buf_set_extmark, bufnr, state.preview_ns, value.lnum, 0, {
        end_row = value.lnum + 1,
        hl_eol = true,
        hl_group = hl_group,
        hl_mode = "blend",
        priority = 300,
      })

      -- Apply foreground highlight for exact range
      pcall(vim.api.nvim_buf_set_extmark, bufnr, state.preview_ns, value.lnum, value.col, {
        end_row = value.end_lnum,
        end_col = value.end_col,
        hl_group = state.config.highlight,
        priority = 301,
      })
    end)
  else
    -- Create scratch buffer and load file content
    if not state.preview_state.scratch_buf or not vim.api.nvim_buf_is_valid(state.preview_state.scratch_buf) then
      state.preview_state.scratch_buf = impl.preview_utils.create_scratch_buffer()
    end

    local cache_eventignore = vim.o.eventignore
    vim.o.eventignore = "BufEnter"

    impl.preview_utils.readfile_async(file_path, function(ok, lines)
      if not ok or not lines then
        vim.o.eventignore = cache_eventignore
        return
      end

      -- Set buffer content
      vim.api.nvim_buf_set_lines(state.preview_state.scratch_buf, 0, -1, false, lines)

      -- Set filetype
      local ft = vim.filetype.match({ filename = file_path })
      if ft then
        vim.bo[state.preview_state.scratch_buf].filetype = ft

        -- Try using treesitter if available
        if state.preview_state.scratch_buf and vim.api.nvim_buf_is_valid(state.preview_state.scratch_buf) then
          pcall(function()
            local has_parser, parser = pcall(vim.treesitter.get_parser, state.preview_state.scratch_buf, ft)
            if has_parser and parser then
              parser:parse()
            end
          end)
        end
      end

      -- Set scratch buffer in window
      vim.api.nvim_win_set_buf(win_id, state.preview_state.scratch_buf)

      -- Set cursor position
      vim.api.nvim_win_set_cursor(win_id, { value.lnum + 1, value.col })
      vim.api.nvim_win_call(win_id, function()
        vim.cmd("normal! zz")
      end)

      -- Highlight the symbol
      vim.api.nvim_buf_clear_namespace(state.preview_state.scratch_buf, state.preview_ns, 0, -1)

      -- Get highlight group
      local hl_group = impl.highlights.get_bg_highlight(state.config.highlight)

      -- Apply highlight
      pcall(vim.api.nvim_buf_set_extmark, state.preview_state.scratch_buf, state.preview_ns, value.lnum, 0, {
        end_row = value.lnum + 1,
        hl_eol = true,
        hl_group = hl_group,
        hl_mode = "blend",
        priority = 300,
      })

      -- Apply foreground highlight
      pcall(vim.api.nvim_buf_set_extmark, state.preview_state.scratch_buf, state.preview_ns, value.lnum, value.col, {
        end_row = value.end_lnum,
        end_col = value.end_col,
        hl_group = state.config.highlight,
        priority = 301,
      })

      vim.o.eventignore = cache_eventignore
    end)
  end
end

-- Apply symbol highlighting in the selecta UI
local function apply_workspace_highlights(buf, filtered_items, config)
  local ns_id = vim.api.nvim_create_namespace("namu_workspace_picker")
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  for idx, item in ipairs(filtered_items) do
    local line = idx - 1
    -- Skip items without a value (like loading indicators)
    if not item.value then
      goto continue
    end
    local value = item.value
    local kind = value.kind
    local kind_hl = config.kinds.highlights[kind] or "Identifier"

    -- Get the line text
    local lines = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)
    if #lines == 0 then
      goto continue
    end

    local line_text = lines[1]

    -- Find parts to highlight
    local name_end = line_text:find("%[") - 2
    local kind_start = name_end + 2
    local kind_end = line_text:find("%]", kind_start)
    local file_start = line_text:find("-") + 2

    -- Highlight symbol name
    vim.api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
      end_row = line,
      end_col = name_end,
      hl_group = kind_hl,
      priority = 110,
    })

    -- Highlight kind
    vim.api.nvim_buf_set_extmark(buf, ns_id, line, kind_start, {
      end_row = line,
      end_col = kind_end,
      hl_group = "Type",
      priority = 110,
    })

    -- Highlight file info
    vim.api.nvim_buf_set_extmark(buf, ns_id, line, file_start, {
      end_row = line,
      end_col = #line_text,
      hl_group = "Directory",
      priority = 110,
    })

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
      title = "Workspace Symbols" .. (query ~= "" and (" - " .. query) or ""),
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

      -- formatter = function(item)
      --   return impl.format_utils.format_item_for_display(item, config)
      -- end,

      hooks = {
        on_render = function(buf, filtered_items)
          -- apply_workspace_highlights(buf, filtered_items, config)
        end,
      },

      on_move = function(item)
        -- if item and item.value then
        --   preview_symbol(item, state.original_win)
        -- end
      end,

      on_select = function(item)
        if not item or not item.value then
          return
        end

        -- Clean up preview state
        if
          state.preview_state
          and state.preview_state.scratch_buf
          and vim.api.nvim_buf_is_valid(state.preview_state.scratch_buf)
        then
          vim.api.nvim_buf_delete(state.preview_state.scratch_buf, { force = true })
          state.preview_state.scratch_buf = nil
        end

        -- Jump to file position
        -- TODO: check here why we need bufadd
        local value = item.value
        local bufnr = vim.fn.bufadd(value.file_path)

        -- Load buffer if needed and jump to position
        if not vim.api.nvim_buf_is_loaded(bufnr) then
          vim.fn.bufload(bufnr)
        end

        vim.api.nvim_win_set_buf(state.original_win, bufnr)
        vim.api.nvim_win_set_cursor(state.original_win, {
          value.lnum + 1,
          value.col,
        })
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
