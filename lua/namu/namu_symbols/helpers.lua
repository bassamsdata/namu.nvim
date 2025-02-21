local M = {}
local request_symbols = require("namu.namu_symbols").request_symbols
local filter_symbol_types = require("namu.namu_symbols").config.filter_symbol_types

-- Shared constants and utilities
---@enum LSPSymbolKinds
local lsp_symbol_kinds = {
  [1] = "File",
  [2] = "Module",
  [3] = "Namespace",
  [4] = "Package",
  [5] = "Class",
  [6] = "Method",
  [7] = "Property",
  [8] = "Field",
  [9] = "Constructor",
  [10] = "Enum",
  [11] = "Interface",
  [12] = "Function",
  [13] = "Variable",
  [14] = "Constant",
  [15] = "String",
  [16] = "Number",
  [17] = "Boolean",
  [18] = "Array",
  [19] = "Object",
  [20] = "Key",
  [21] = "Null",
  [22] = "EnumMember",
  [23] = "Struct",
  [24] = "Event",
  [25] = "Operator",
  [26] = "TypeParameter",
}

-- Shared UI setup function
---@param buf number
---@param filetype string
local function setup_buffer(buf, filetype)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", filetype, { buf = buf })

  local opts = { noremap = true, silent = true }
  vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", opts)
  vim.api.nvim_buf_set_keymap(buf, "n", "<Esc>", ":close<CR>", opts)
end

---@param buf number
---@param content_lines string[]
---@return number window ID
local function create_floating_window(buf, content_lines)
  local width = math.min(70, vim.o.columns - 4)
  local height = math.min(#content_lines, vim.o.lines - 12)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
  })

  -- Set window-local options
  vim.api.nvim_set_option_value("conceallevel", 2, { win = win })
  vim.api.nvim_set_option_value("foldenable", false, { win = win })
  vim.api.nvim_set_option_value("wrap", false, { win = win })

  return win
end

-- Highlight management
---@param buf number
---@param ns_id number
---@param line number
---@param col_start number
---@param col_end number
---@param hl_group string
local function add_highlight(buf, ns_id, line, col_start, col_end, hl_group)
  local line_content = vim.api.nvim_buf_get_lines(buf, line, line + 1, true)[1] or ""
  local end_col = col_end == -1 and #line_content or math.min(col_end, #line_content)

  if end_col > col_start then
    vim.api.nvim_buf_add_highlight(buf, ns_id, hl_group, line, col_start, end_col)
  end
end

local function helper_highlights()
  vim.cmd([[
    highlight default link NamuHelperHeader Title
    highlight default link NamuHelperSubHeader Statement
    highlight default link NamuHelperCount Number
    highlight default link NamuHelperKind Type
    highlight default link NamuHelperFilter Special
    highlight default link NamuHelperPath Comment
    highlight default link NamuHelperCode Special
  ]])
end

---@param current_bufname string
---@param total_symbols number
---@param kind_count table<string, number>
---@param kind_examples table<string, string>
---@param default_symbol_types table
---@return string[]
function M.create_analysis_content(current_bufname, total_symbols, kind_count, kind_examples, default_symbol_types)
  local lines = {
    "Symbol Analysis",
    string.rep("=", 50),
    "",
    string.format("File: %s", vim.fn.fnamemodify(current_bufname, ":.")),
    string.format("Total Symbols: %d", total_symbols),
    "",
    "Symbol Distribution:",
    string.rep("-", 50),
    "",
  }

  -- Find matching symbol types
  local matched_types = {}
  for kind, _ in pairs(kind_count) do
    for code, symbol_type in pairs(default_symbol_types) do
      if vim.tbl_contains(symbol_type.kinds, kind) then
        matched_types[kind] = code
        break
      end
    end
  end

  -- Add symbol counts and examples
  for kind, count in pairs(kind_count) do
    local filter_code = matched_types[kind] or "??"
    local example = kind_examples[kind] or "N/A"
    table.insert(lines, string.format("  %s (%d symbols)", kind, count))
    table.insert(lines, string.format("    Filter: /%s", filter_code)) -- Updated to use / instead of %
    table.insert(lines, string.format("    Example: %s", example))
    table.insert(lines, "")
  end

  -- Add usage hints
  table.insert(lines, "Usage Tips:")
  table.insert(lines, string.rep("-", 50))
  table.insert(lines, "  - Use the filters shown above to narrow down symbols")
  table.insert(lines, "  - Combine with text: /fn main")
  table.insert(lines, "  - Press ? in symbol picker for more help")

  return lines
end

-- Symbol analysis
---@param symbol table
---@param kind_count table<string, number>
---@param kind_examples table<string, string>
---@return number total_count
local function analyze_symbol(symbol, kind_count, kind_examples)
  local total_count = 0

  if symbol.kind then
    local kind_str = type(symbol.kind) == "number" and lsp_symbol_kinds[symbol.kind] or symbol.kind
    if kind_str then
      kind_count[kind_str] = (kind_count[kind_str] or 0) + 1
      total_count = total_count + 1

      if not kind_examples[kind_str] and symbol.name then
        kind_examples[kind_str] = symbol.name
      end
    end
  end

  if symbol.children then
    for _, child in ipairs(symbol.children) do
      total_count = total_count + analyze_symbol(child, kind_count, kind_examples)
    end
  end

  return total_count
end

local function set_buffer_lines(buf, lines)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@return number, number buffer window ID, number window ID
function M.create_help_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  setup_buffer(buf, "namu-help")

  local lines = {
    "Namu Symbol Types",
    string.rep("=", 40),
    "",
    "Usage: Type /xx followed by search term",
    "Example: /fn main - finds functions containing 'main'",
    "",
    "Available Symbol Types:",
    string.rep("-", 40),
    "",
  }

  for code, symbol_type in pairs(filter_symbol_types) do
    table.insert(lines, string.format("  %s - %s", code, symbol_type.description))
    table.insert(lines, string.format("    Matches: %s", table.concat(symbol_type.kinds, ", ")))
    table.insert(lines, "")
  end

  set_buffer_lines(buf, lines)

  local win = create_floating_window(buf, lines)

  helper_highlights()
  local ns_id = vim.api.nvim_create_namespace("namu_help")

  -- Apply highlights with unified groups
  add_highlight(buf, ns_id, 0, 0, -1, "NamuHelperHeader")
  add_highlight(buf, ns_id, 3, 0, 5, "NamuHelperSubHeader")
  add_highlight(buf, ns_id, 4, 0, -1, "NamuHelperCode")
  add_highlight(buf, ns_id, 6, 0, -1, "NamuHelperSubHeader")

  local current_line = 9
  for _ in pairs(filter_symbol_types) do
    add_highlight(buf, ns_id, current_line, 2, 4, "NamuHelperCode")
    add_highlight(buf, ns_id, current_line, 7, -1, "NamuHelperKind")
    add_highlight(buf, ns_id, current_line + 1, 4, -1, "NamuHelperFilter")
    current_line = current_line + 3
  end

  return buf, win
end

-- Analyzer functionality
---@return number, number buffer ID, number window ID
function M.create_analysis_buffer()
  local current_buf = vim.api.nvim_get_current_buf()
  local current_bufname = vim.api.nvim_buf_get_name(current_buf)
  local buf = vim.api.nvim_create_buf(false, true)

  setup_buffer(buf, "namu-analysis")
  -- Create initial window while waiting for symbols
  set_buffer_lines(buf, { "Loading symbols..." })
  local win = create_floating_window(buf, { "Loading symbols..." })

  -- Setup highlights
  helper_highlights()
  local ns_id = vim.api.nvim_create_namespace("namu_analysis")

  -- Collect and analyze symbols
  request_symbols(current_buf, function(err, symbols)
    if err then
      vim.notify("Error fetching symbols: " .. vim.inspect(err), vim.log.levels.ERROR)
      return
    end

    local kind_count = {}
    local kind_examples = {}
    local total_symbols = 0

    -- Analyze symbols
    for _, symbol in ipairs(symbols or {}) do
      total_symbols = total_symbols + analyze_symbol(symbol, kind_count, kind_examples)
    end

    -- Create and set content
    local lines =
      M.create_analysis_content(current_bufname, total_symbols, kind_count, kind_examples, filter_symbol_types)

    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, buf)
      set_buffer_lines(buf, lines)
      -- Adjust window height for new content
      local new_height = math.min(#lines, vim.o.lines - 6)
      local width = math.min(70, vim.o.columns - 4)

      -- Update both height and position
      vim.api.nvim_win_set_config(win, {
        relative = "editor",
        row = math.floor((vim.o.lines - new_height - 4) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        height = new_height,
      })
    end

    add_highlight(buf, ns_id, 0, 0, -1, "NamuHelperHeader")
    add_highlight(buf, ns_id, 3, 0, 5, "NamuHelperSubHeader")
    add_highlight(buf, ns_id, 3, 6, -1, "NamuHelperPath")
    add_highlight(buf, ns_id, 4, 0, 14, "NamuHelperSubHeader")
    add_highlight(buf, ns_id, 4, 15, -1, "NamuHelperCount")
    add_highlight(buf, ns_id, 6, 0, -1, "NamuHelperSubHeader")

    -- Symbol Distribution section
    add_highlight(buf, ns_id, 6, 0, -1, "NamuAnalysisSubHeader")

    -- Highlight symbol sections
    local current_line = 9
    for kind, _ in pairs(kind_count) do
      -- Kind line
      add_highlight(buf, ns_id, current_line, 2, -1, "NamuHelperKind")
      -- Filter line
      add_highlight(buf, ns_id, current_line + 1, 12, -1, "NamuHelperFilter")
      current_line = current_line + 4
    end

    -- Usage section
    add_highlight(buf, ns_id, current_line, 0, -1, "NamuAnalysisSubHeader")
    add_highlight(buf, ns_id, current_line + 1, 0, -1, "NamuAnalysisFilter")
  end)

  return buf, win
end

return M
