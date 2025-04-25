local async_module = require("namu.core.async")
local Async = async_module.Async.new({ max_concurrent = 5, default_timeout = 15 })
local Promise = async_module.Promise
local symbolKindMap = require("namu.namu_ctags.kindmap").symbolKindMap
local lsp = require("namu.namu_symbols.lsp")
local ui = require("namu.namu_symbols.ui")
local selecta = require("namu.selecta.selecta")
local symbol_utils = require("namu.core.symbol_utils")
local config = require("namu.namu_symbols.config")
local format_utils = require("namu.core.format_utils")
local utils = require("namu.core.utils")

local M = {}
local api = vim.api
M.config = config.values
M.config = vim.tbl_deep_extend("force", M.config, {
  window = {
    min_width = 35,
    max_width = 120,
  },
  display = {
    format = "tree_guides",
  },
  preserve_hierarchy = true,
  current_highlight = {
    enabled = true,
    hl_group = "NamuCurrentItem",
    prefix_icon = " ",
  },
})

---@type NamuState
local state = nil

local function initialize_state()
  if state and state.original_win and state.preview_ns then
    ui.clear_preview_highlight(state.original_win, state.preview_ns)
    state.original_win = nil
    state.original_buf = nil
    state.original_ft = nil
    state.original_pos = nil
  end

  state = symbol_utils.create_state("namu_watchtower_ctags_preview")
  state.original_win = api.nvim_get_current_win()
  state.original_buf = api.nvim_get_current_buf()
  state.original_ft = vim.bo.filetype
  state.original_pos = api.nvim_win_get_cursor(state.original_win)
end

--- Convert ctags symbols to selecta items, adding source information
---@param raw_symbols TagEntry[]
---@param bufnr integer The buffer number
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols, bufnr)
  local items = {}
  local scope_signatures = {}
  local ft = vim.bo[bufnr].filetype or state.original_ft

  -- Calculate depth based on scope
  local function get_scope_depth(scope)
    if not scope then
      return 0
    end
    -- Special handling for Lua
    if ft == "lua" then
      -- For Lua, we don't count dots as nesting for module patterns
      if symbol and symbol.scopeKind == "unknown" then
        return 0 -- Module pattern, don't create artificial nesting
      end
      -- Only count actual nesting (like methods in classes)
      return symbol and symbol.scopeKind == "class" and 1 or 0
    end
    -- For C/C++/Rust: Count :: as separator
    if ft == "c" or ft == "cpp" or ft == "rust" then
      -- Count the number of :: separators
      return select(2, scope:gsub("::", "")) + 1
    end
    -- For other languages, count dots for nesting depth
    return select(2, scope:gsub("%.", "")) + 1
  end

  local function get_display_name(symbol)
    if state.original_ft == "lua" then
      -- For Lua, show full name for module patterns
      if symbol.scope and symbol.scopeKind == "unknown" then
        return symbol.scope .. "." .. symbol.name
      end
    end
    return symbol.name
  end

  local function generate_signature(symbol, depth)
    if not symbol or not symbol.line then
      return nil
    end
    -- For Lua, include full scope in signature for module patterns
    local name = symbol.name
    if state.original_ft == "lua" and symbol.scope and symbol.scopeKind == "unknown" then
      name = symbol.scope .. "." .. symbol.name
    end
    return string.format("%s:%d:%d:1", symbol.name, depth, symbol.line)
  end

  -- First pass: generate signatures for all scopes
  for _, symbol in ipairs(raw_symbols) do
    -- Check if this symbol is a container type
    if
      symbol.kind == "class"
      or symbol.kind == "struct"
      or symbol.kind == "module"
      or symbol.kind == "namespace"
      or symbol.kind == "interface"
      or symbol.kind == "enum"
    then
      local depth = get_scope_depth(symbol.scope)
      local signature = generate_signature(symbol, depth)

      if signature then
        if symbol.scope then
          -- Get the appropriate separators for this language
          local primary_sep, alt_sep

          if ft == "rust" or ft == "cpp" or ft == "c" then
            primary_sep = "::"
            alt_sep = "."
          else
            primary_sep = "."
            alt_sep = "."
          end

          -- Create primary and alternative keys
          local primary_key = symbol.scope .. primary_sep .. symbol.name
          local alt_key = symbol.scope .. alt_sep .. symbol.name

          -- Store primary key always
          scope_signatures[primary_key] = signature

          -- Only store alternative if it doesn't exist already
          if primary_sep ~= alt_sep and not scope_signatures[alt_key] then
            scope_signatures[alt_key] = signature
          end
        else
          scope_signatures[symbol.name] = signature
        end
      end
    end
  end

  local function process_symbol_result(result)
    if not result or not result.name then
      return
    end
    local depth = get_scope_depth(result.scope)
    local parent_signature = nil

    -- Get parent signature based on scope
    if result.scope then
      parent_signature = scope_signatures[result.scope]

      -- For Rust/C++, try with different separators if not found
      if not parent_signature and (ft == "rust" or ft == "cpp" or ft == "c") then
        -- Try with :: if scope was using dot notation
        if not result.scope:find("::") then
          parent_signature = scope_signatures[result.scope:gsub("%.", "::")]
        end
        -- Try with dot if scope was using :: notation
        if not parent_signature and result.scope:find("::") then
          parent_signature = scope_signatures[result.scope:gsub("::", ".")]
        end
      end
    end

    -- If no parent found in scope, set buffer as parent
    if not parent_signature then
      parent_signature = "buffer:" .. bufnr
    end

    local kind = lsp.symbol_kind(symbolKindMap[result.kind])
    local signature = generate_signature(result, depth)
    local display_name = get_display_name(result)

    local item = {
      value = {
        text = display_name,
        name = display_name,
        kind = kind,
        lnum = result.line,
        col = 1,
        end_lnum = (result["end"] or result.line) + 1,
        end_col = 100,
        signature = signature,
        parent_signature = parent_signature,
        bufnr = bufnr,
      },
      icon = M.config.kindIcons[kind] or M.config.icon,
      kind = kind,
      depth = depth,
      source = "ctags",
      bufnr = bufnr,
    }

    table.insert(items, item)
  end

  -- Process all symbols
  for _, symbol in ipairs(raw_symbols) do
    process_symbol_result(symbol)
  end

  if M.config.display.format == "tree_guides" then
    items = format_utils.add_tree_state_to_items(items)
  end

  for _, item in ipairs(items) do
    item.text = format_utils.format_item_for_display(item, config.values)
  end

  return items
end

---Get symbols from ctags
---@param path string
---@return Promise<table[], any>
local function get_ctags_symbols(path)
  local promise = Promise.new()
  Async:go_with_timeout(
    function()
      local request = vim.system(
        { "ctags", "--output-format=json", "--sort=no", "--fields='{scope}{name}{line}{end}{kind}{scopeKind}'", path },
        { text = true },
        function(obj)
          local result = nil
          local request_err = nil
          if obj.code ~= 0 then
            request_err = obj
          else
            local lines = vim.split(obj.stdout, "[\r]?\n")
            result = {}
            for _, line in ipairs(lines) do
              local ok, dec = pcall(vim.json.decode, line)
              if ok then
                table.insert(result, dec)
              end
            end
          end
          vim.schedule(function()
            if request_err then
              promise:reject(request_err)
            else
              promise:resolve(result)
            end
          end)
        end
      )
      -- Optionally, you can add a cancellation function to the promise
      promise._cancel = function()
        if request and request.close then
          request:close() -- Assuming vim.system returns a request with a close method
        end
      end
    end,
    5 -- Timeout in seconds
  )
  return promise
end

--- Process a single buffer to get symbols
---@param bufnr integer
---@return Promise<SelectaItem[], string?>
local function process_buffer(bufnr)
  local promise = Promise.new()
  if
    not vim.fn.getbufvar(bufnr, "&buflisted") == 1
    or vim.bo[bufnr].buftype ~= ""
    or not api.nvim_buf_is_valid(bufnr)
    or not api.nvim_buf_is_loaded(bufnr)
    or utils.is_big_buffer(bufnr, {
      line_threshold = false,
      byte_threshold_mb = 5,
    }) -- TODO: make this configurable so the user have control
  then
    promise:resolve({}, "Buffer invalid or not loaded")
    return promise
  end

  local path = api.nvim_buf_get_name(bufnr)
  if path == "" then
    promise:resolve({}, "Buffer has no file path")
    return promise
  end

  get_ctags_symbols(path):and_then(function(symbols)
    if symbols and #symbols > 0 then
      promise:resolve(symbols_to_selecta_items(symbols, bufnr))
    else
      promise:resolve({}, "No ctags symbols found")
    end
  end, function(err)
    promise:reject("Ctags error: " .. tostring(err))
  end)

  return promise
end

--- Main function to show open buffer symbols
function M.show()
  initialize_state()

  local bufs = api.nvim_list_bufs()
  local current_bufnr = api.nvim_get_current_buf()
  local buffer_results = {}
  local num_processed = 0
  local total_bufs = #bufs

  local function on_buffer_processed(items, bufnr, err)
    num_processed = num_processed + 1
    if err then
      vim.notify("Error processing buffer: " .. err, vim.log.levels.WARN, { title = "Namu" })
    elseif items and #items > 0 then
      buffer_results[bufnr] = items
    end

    if num_processed == total_bufs then
      local all_items = {}

      -- Process buffers in desired order
      local ordered_bufs = {}

      -- Current buffer first
      table.insert(ordered_bufs, current_bufnr)

      -- Then other buffers
      for _, buf in ipairs(bufs) do
        if buf ~= current_bufnr then
          table.insert(ordered_bufs, buf)
        end
      end

      -- Add items in proper hierarchy
      for _, bufnr in ipairs(ordered_bufs) do
        local items = buffer_results[bufnr]
        if items and #items > 0 then
          -- Add buffer header
          local buf_name = vim.fn.bufname(bufnr) or ""
          local display_name = buf_name ~= "" and vim.fn.fnamemodify(buf_name, ":t") or "[Buffer " .. bufnr .. "]"

          -- Get file icon and highlight for the buffer
          local icon, icon_hl = "󰈙", "Normal" -- Default icon
          if buf_name and buf_name ~= "" then
            icon, icon_hl = utils.get_file_icon(buf_name)
          end

          local buffer_item = {
            text = display_name,
            icon = icon,
            icon_hl = icon_hl,
            kind = "buffer",
            is_root = true,
            depth = 0,
            value = {
              bufnr = bufnr,
              name = display_name,
              full_path = buf_name,
              signature = "buffer:" .. bufnr,
              lnum = 0,
              end_lnum = math.huge,
              col = 0,
              end_col = math.huge,
            },
          }

          -- Mark current buffer
          if bufnr == current_bufnr then
            buffer_item.text = buffer_item.text .. " (current)"
          end

          -- Add buffer header
          table.insert(all_items, buffer_item)

          -- Add symbols with parent relationship (already set in symbols_to_selecta_items)
          for _, item in ipairs(items) do
            table.insert(all_items, item)
          end
        end
      end

      if #all_items == 0 then
        vim.notify("No ctags symbols found in open buffers", vim.log.levels.WARN, { title = "Namu" })
      else
        -- Create config with hierarchy settings
        local picker_config = vim.tbl_deep_extend("force", M.config, {
          preserve_hierarchy = true,
          parent_key = function(item)
            return item.value and item.value.parent_signature
          end,
          is_root_item = function(item)
            return item.is_root == true
          end,
          root_item_first = true,
          on_move = function(item)
            -- Skip buffer items (which don't have line numbers)
            if item and item.is_root then
              return
            end

            if
              M.config.preview
              and M.config.preview.highlight_on_move
              and M.config.preview.highlight_mode == "always"
            then
              if item and item.value then
                ui.preview_symbol(item.value, state.original_win, state.preview_ns, state, M.config.highlight)
              end
            end
          end,
        })
        -- Count buffer items
        local buffer_count = 0
        for _, item in ipairs(all_items) do
          if item.kind == "buffer" then
            buffer_count = buffer_count + 1
          end
        end
        local prompt_info = nil
        if buffer_count > 0 then
          local suffix = buffer_count == 1 and "buffer" or "buffers"
          prompt_info = { text = "(" .. buffer_count .. " " .. suffix .. ")", hl_group = "Comment" }
        end
        symbol_utils.show_picker(
          all_items,
          state,
          picker_config,
          ui,
          selecta,
          "Watchtower Symbols (ctags)",
          { title = "Namu" },
          false,
          "open",
          prompt_info
        )
      end
    end
  end

  if total_bufs == 0 then
    vim.notify("No open buffers found", vim.log.levels.WARN, { title = "Namu" })
    return
  end

  for _, bufnr in ipairs(bufs) do
    process_buffer(bufnr):and_then(function(items)
      on_buffer_processed(items, bufnr, nil)
    end, function(err)
      on_buffer_processed(nil, bufnr, err)
    end)
  end
end

return M
