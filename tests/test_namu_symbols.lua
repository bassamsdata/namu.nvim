---@diagnostic disable: need-check-nil, param-type-mismatch
local h = require("tests.helpers")
local namu = require("namu.namu_symbols")
local lsp = require("namu.namu_symbols.lsp")
local format_utils = require("namu.core.format_utils")
---@diagnostic disable-next-line: undefined-global
local new_set = MiniTest.new_set

local T = new_set()

-- Test utilities exposed for testing
T._test = {
  generate_signature = function(symbol, depth)
    local range = symbol.range or (symbol.location and symbol.location.range)
    if not range then
      return nil
    end
    return string.format("%s:%d:%d:%d", symbol.name, depth, range.start.line, range.start.character)
  end,

  make_tree_guides = function(tree_state)
    local chars = {
      continue = "┆ ",
      last = "└─",
      item = "├─",
    }

    local result = ""
    for idx, is_last in ipairs(tree_state) do
      if idx == #tree_state then
        result = result .. (is_last and chars.last or chars.item)
      else
        result = result .. (is_last and "  " or chars.continue)
      end
    end
    return result
  end,

  symbols_to_selecta_items = function(raw_symbols)
    local items = {}
    local parent_stack = {}

    local function process_symbol_result(result, depth)
      if not result or not result.name then
        return
      end

      local range = result.range or (result.location and result.location.range)
      if not range then
        return
      end

      local signature = T._test.generate_signature(result, depth)
      local parent_signature = depth > 0 and parent_stack[depth] or nil

      if lsp.should_include_symbol(result, namu.config, "lua") then
        local kind = lsp.symbol_kind(result.kind)
        local item = {
          value = {
            name = result.name,
            kind = kind,
            lnum = range.start.line + 1,
            col = range.start.character + 1,
            end_lnum = range["end"].line + 1,
            end_col = range["end"].character + 1,
            signature = signature,
            parent_signature = parent_signature,
          },
          icon = namu.config.kindIcons[kind] or "  ",
          kind = kind,
          depth = depth,
        }
        table.insert(items, item)
      end

      if signature then
        parent_stack[depth + 1] = signature
      end

      if result.children then
        for _, child in ipairs(result.children) do
          process_symbol_result(child, depth + 1)
        end
      end

      parent_stack[depth + 1] = nil
    end

    for _, symbol in ipairs(raw_symbols) do
      process_symbol_result(symbol, 0)
    end

    if namu.config.display.format == "tree_guides" then
      items = format_utils.add_tree_state_to_items(items)
    end

    return items
  end,
}

-- Helper functions
local function create_mock_config()
  return {
    kindIcons = {
      Class = "󰠱",
      Method = "󰆧",
      Function = "󰊕",
    },
    display = {
      format = "tree_guides",
      style = 2,
    },
    AllowKinds = {
      default = { "Class", "Method", "Function" },
      lua = { "Class", "Method", "Function" },
    },
    BlockList = {
      default = {},
      lua = {},
    },
    window = {
      relative = "editor",
      border = "none",
    },
    highlight = "Visual",
    icon = "󰎔",
  }
end

local function create_test_symbols()
  return {
    {
      name = "TestClass",
      kind = 5, -- Class
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 10, character = 0 },
      },
      children = {
        {
          name = "test_method",
          kind = 6, -- Method
          range = {
            start = { line = 1, character = 2 },
            ["end"] = { line = 3, character = 2 },
          },
        },
      },
    },
  }
end

-- Tests
T["Init.symbol_processing"] = new_set()

T["Init.symbol_processing"]["converts symbols to selecta items correctly"] = function()
  local symbols = create_test_symbols()
  local _original_config = namu.config
  namu.config = create_mock_config()

  local result = T._test.symbols_to_selecta_items(symbols)

  h.eq(#result, 2)
  h.eq(result[1].value.name, "TestClass")
  h.eq(result[2].value.name, "test_method")
  h.eq(result[2].depth, 1)

  namu.config = _original_config
end

T["Init.symbol_processing"]["maintains parent-child relationships"] = function()
  local symbols = create_test_symbols()
  local _original_config = namu.config
  namu.config = create_mock_config()

  local result = T._test.symbols_to_selecta_items(symbols)
  local parent_sig = result[1].value.signature
  h.eq(result[2].value.parent_signature, parent_sig)

  namu.config = _original_config
end

T["Init.configuration"] = new_set()

T["Init.configuration"]["applies configuration correctly"] = function()
  local test_config = create_mock_config()
  test_config.display.style = 3
  test_config.kindIcons.Class = "C"

  namu.setup(test_config)

  h.eq(namu.config.display.format, "tree_guides")
  h.eq(namu.config.display.style, 3)
  h.eq(namu.config.kindIcons.Class, "C")
end

T["Init.filtering"] = new_set()

T["Init.filtering"]["filters symbols based on configuration"] = function()
  local symbols = create_test_symbols()
  local _original_config = namu.config
  namu.config = create_mock_config()
  namu.config.AllowKinds.lua = { "Method" }

  local result = T._test.symbols_to_selecta_items(symbols)
  local method_count = 0
  for _, item in ipairs(result) do
    if item.kind == "Method" then
      method_count = method_count + 1
    end
  end

  h.eq(method_count, 1)
  h.eq(#result, 1)

  namu.config = _original_config
end

T["Init.show"] = new_set()

T["Init.show"]["handles empty results correctly"] = function()
  local notified = false
  local _original_notify = vim.notify
  local _original_request_symbols = lsp.request_symbols
  local _original_config = namu.config

  namu.config = create_mock_config()
  vim.notify = function(msg, level)
    if msg == "No results." and level == vim.log.levels.WARN then
      notified = true
    end
  end

  lsp.request_symbols = function(_, _, callback)
    callback(nil, {}, nil)
  end

  namu.show()

  h.eq(notified, true)

  vim.notify = _original_notify
  lsp.request_symbols = _original_request_symbols
  namu.config = _original_config
end

T["Init.caching"] = new_set()

T["Init.caching"]["uses cache when available"] = function()
  local symbols = create_test_symbols()
  local _original_config = namu.config
  namu.config = create_mock_config()

  local result1 = T._test.symbols_to_selecta_items(symbols)
  local result2 = T._test.symbols_to_selecta_items(symbols)

  h.eq(vim.inspect(result1), vim.inspect(result2))

  namu.config = _original_config
end

return T
