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

local M = {}
M.config = require("namu.namu_symbols.config").values

---@type NamuState
local state = nil

local function initialize_state()
  if state and state.original_win and state.preview_ns then
    ui.clear_preview_highlight(state.original_win, state.preview_ns)
  end

  state = symbol_utils.create_state("namu_active_ctags_preview")
  state.original_win = vim.api.nvim_get_current_win()
  state.original_buf = vim.api.nvim_get_current_buf()
  state.original_ft = vim.bo.filetype
  state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)
end

--- Convert ctags symbols to selecta items, adding source information
---@param raw_symbols TagEntry[]
---@return SelectaItem[]
local function symbols_to_selecta_items(raw_symbols)
  local bufnr = vim.api.nvim_get_current_buf()

  local items = {}
  local scope_signatures = {}

  -- Calculate depth based on scope
  local function get_scope_depth(scope)
    if not scope then
      return 0
    end
    -- Special handling for Lua
    if state.original_ft == "lua" then
      -- For Lua, we don't count dots as nesting for module patterns
      if symbol.scopeKind == "unknown" then
        return 0 -- Module pattern, don't create artificial nesting
      end
      -- Only count actual nesting (like methods in classes)
      return symbol.scopeKind == "class" and 1 or 0
    end
    -- For C/C++/Rust: Count :: as separator
    if state.original_ft == "c" or state.original_ft == "cpp" or state.original_ft == "rust" then
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

      if symbol.scope then
        -- Get the appropriate separators for this language
        local primary_sep, alt_sep = ".", "."
        -- Create primary and alternative keys
        local primary_key = symbol.scope .. primary_sep .. symbol.name
        local alt_key = symbol.scope .. alt_sep .. symbol.name
        -- Store primary key always
        scope_signatures[primary_key] = signature

        -- Only store alternative if it doesn't exist already
        if not scope_signatures[alt_key] then
          scope_signatures[alt_key] = signature
        end
      else
        scope_signatures[symbol.name] = signature
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
      },
      icon = config.values.kindIcons[kind] or config.values.icon,
      kind = kind,
      depth = depth,
      source = "ctags",
    }

    table.insert(items, item)
  end
  -- First, let's define the symbolKindMap
  local symbolKindMap = {
    function_ = "Function",
    method = "Method",
    class = "Class",
    struct = "Struct",
    member = "Field",
    variable = "Variable",
    constant = "Constant",
    file = "File",
    module = "Module",
    namespace = "Namespace",
  }
  for _, symbol in ipairs(raw_symbols) do
    process_symbol_result(symbol)
  end
  if config.values.display.format == "tree_guides" then
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

  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) or vim.bo[bufnr].buftype ~= "" then
    promise:resolve({}, "Buffer invalid or not loaded")
    return promise
  end

  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    promise:resolve({}, "Buffer has no file path")
    return promise
  end

  get_ctags_symbols(path):and_then(function(symbols)
    if symbols and #symbols > 0 then
      promise:resolve(symbols_to_selecta_items(symbols))
    else
      promise:resolve({}, "No ctags symbols found")
    end
  end, function(err)
    promise:reject("Ctags error: " .. tostring(err))
  end)

  return promise
end

--- Main function to show active buffer symbols
function M.show()
  initialize_state()

  local bufs = vim.api.nvim_list_bufs()
  local all_items = {}
  local num_processed = 0
  local total_bufs = #bufs

  local function on_buffer_processed(items, err)
    num_processed = num_processed + 1
    if err then
      vim.notify("Error processing buffer: " .. err, vim.log.levels.WARN, { title = "Namu" })
    elseif items and #items > 0 then
      for _, item in ipairs(items) do
        table.insert(all_items, item)
      end
    end

    if num_processed == total_bufs then
      if #all_items == 0 then
        vim.notify("No ctags symbols found in active buffers", vim.log.levels.WARN, { title = "Namu" })
      else
        symbol_utils.show_picker(all_items, state, M.config, ui, selecta, "Active Symbols (ctags)", { title = "Namu" })
      end
    end
  end

  if total_bufs == 0 then
    vim.notify("No active buffers found", vim.log.levels.WARN, { title = "Namu" })
    return
  end

  for _, bufnr in ipairs(bufs) do
    process_buffer(bufnr):and_then(function(items)
      on_buffer_processed(items, nil)
    end, function(err)
      on_buffer_processed(nil, err)
    end)
  end
end

return M
