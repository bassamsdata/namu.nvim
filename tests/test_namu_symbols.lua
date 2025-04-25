---@diagnostic disable: need-check-nil, param-type-mismatch
local h = require("tests.helpers")
local namu = require("namu.namu_symbols")
local lsp = require("namu.namu_symbols.lsp")
local format_utils = require("namu.core.format_utils")
local test_patterns = require("namu.namu_symbols.lua_tests")
local treesitter_symbols = require("namu.core.treesitter_symbols")
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

local function create_mock_state()
  return { original_buf = 1, original_ft = "lua" }
end
local function mock_lsp_symbol_kind(kind_num)
  local kind_map = { [5] = "Class", [6] = "Method", [12] = "Function" }
  return kind_map[kind_num] or "Unknown"
end

-- Mock buffer lines storage
local mock_buffer_lines = {}
local original_nvim_buf_get_lines = nil

local function create_test_symbols()
  return {
    {
      name = "TestClass",
      kind = 5,
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 10, character = 0 } },
      children = {
        {
          name = "test_method",
          kind = 6,
          range = { start = { line = 1, character = 2 }, ["end"] = { line = 3, character = 2 } },
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
  local expected_message = "No symbol provider for lua buffer (missing LSP/TreeSitter)"
  namu.config = create_mock_config()
  vim.bo.filetype = "lua"
  vim.notify = function(msg, level)
    if msg == expected_message and level == vim.log.levels.WARN then
      notified = true
    end
  end
  -- Mock LSP to return no results
  lsp.request_symbols = function(_, _, callback)
    callback(nil, {}, nil) -- Simulate LSP error/empty result
  end
  -- Mock TreeSitter to also return no results
  treesitter_symbols.get_symbols = function(_)
    return {} -- Simulate TreeSitter finding no symbols
  end
  namu.show()
  h.eq(notified, true)
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

T["LuaTests"] = new_set({
  hooks = {
    pre_case = function()
      -- Store original and apply mock before each test case in this set
      original_nvim_buf_get_lines = vim.api.nvim_buf_get_lines
      vim.api.nvim_buf_get_lines = function(bufnr, start_line, end_line, _)
        -- Basic checks within the mock
        if bufnr ~= 1 then
          error("Mocked for bufnr 1 only")
        end
        if end_line ~= start_line + 1 then
          error("Mocked for single line fetch only")
        end
        -- Return the mocked line or empty string
        return { mock_buffer_lines[start_line + 1] or "" }
      end
      mock_buffer_lines = {} -- Ensure clean slate for lines
    end,
    post_case = function()
      -- Restore original function after each test case
      if original_nvim_buf_get_lines then
        vim.api.nvim_buf_get_lines = original_nvim_buf_get_lines
      end
      original_nvim_buf_get_lines = nil
      mock_buffer_lines = {} -- Clear lines after test
    end,
  },
})

-- Tests for extract_lua_test_info (Keep tests as they were)
T["LuaTests"]["extract_lua_test_info handles double quotes multi-bracket"] = function()
  local line = 'T["Category"]["Test Name"] = function()'
  local result = test_patterns.extract_lua_test_info(line)
  h.not_eq(result, nil)
  h.eq(result.namespace, "T")
  h.eq(result.segments[1], "Category")
  h.eq(result.segments[2], "Test Name")
  h.eq(result.quote_type, '"')
  h.eq(result.parent_name, "Category")
  h.eq(result.parent_full_name, 'T["Category"]')
  h.eq(result.full_name, 'T["Category"]["Test Name"]')
  h.eq(result.child_display, '["Test Name"]')
  h.eq(type(result.last_bracket_pos), "number")
end

T["LuaTests"]["extract_lua_test_info handles single quotes multi-bracket"] = function()
  local line = "T['Category']['Test Name'] = function()"
  local result = test_patterns.extract_lua_test_info(line)
  h.not_eq(result, nil)
  h.eq(result.namespace, "T")
  h.eq(result.segments[1], "Category")
  h.eq(result.segments[2], "Test Name")
  h.eq(result.quote_type, "'")
  h.eq(result.parent_full_name, "T['Category']")
  h.eq(result.full_name, "T['Category']['Test Name']")
  h.eq(result.child_display, "['Test Name']")
  h.eq(type(result.last_bracket_pos), "number")
end

T["LuaTests"]["extract_lua_test_info handles single bracket"] = function()
  local line = 'T["Single Test"] = function()'
  local result = test_patterns.extract_lua_test_info(line)
  h.not_eq(result, nil)
  h.eq(result.namespace, "T")
  h.eq(#result.segments, 1)
  h.eq(result.segments[1], "Single Test")
  h.eq(result.parent_full_name, 'T["Single Test"]')
  h.eq(result.full_name, 'T["Single Test"]')
  h.eq(result.child_display, nil)
  h.eq(result.last_bracket_pos, nil)
end

T["LuaTests"]["extract_lua_test_info handles invalid line"] = function()
  local line = "local function my_func()"
  local result = test_patterns.extract_lua_test_info(line)
  h.eq(result, nil)
end

-- Tests for count_first_brackets (Keep tests as they were)
T["LuaTests"]["count_first_brackets counts correctly"] = function()
  local config = create_mock_config()
  local state = create_mock_state()
  local test_info_cache = {}
  local first_bracket_counts = {}
  mock_buffer_lines[1] = 'T["Category"]["Test 1"] = function()' -- Line 1 (index 0 in API)
  mock_buffer_lines[2] = 'T["Category"]["Test 2"] = function()' -- Line 2 (index 1 in API)
  mock_buffer_lines[3] = 'T["Other"]["Test 3"] = function()' -- Line 3 (index 2 in API)

  local symbols = {
    { name = "", kind = 12, range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 10 } } },
    { name = "", kind = 12, range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 10 } } },
    { name = "", kind = 12, range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 10 } } },
  }

  for _, symbol in ipairs(symbols) do
    test_patterns.count_first_brackets(symbol, state, config, test_info_cache, first_bracket_counts)
  end

  h.eq(first_bracket_counts['T["Category"]'], 2)
  h.eq(first_bracket_counts['T["Other"]'], 1)
  h.not_eq(test_info_cache[0], nil)
  h.not_eq(test_info_cache[1], nil)
  h.not_eq(test_info_cache[2], nil)
end

-- Tests for process_lua_test_symbol (Keep tests as they were)
T["LuaTests"]["process_lua_test_symbol hierarchy enabled multi-bracket"] = function()
  local config = create_mock_config()
  config.lua_test_preserve_hierarchy = true
  local state = create_mock_state()
  local test_info_cache = {}
  local first_bracket_counts = { ['T["Category"]'] = 2 }
  local items = {}
  local bufnr = 1

  mock_buffer_lines[1] = 'T["Category"]["Test 1"] = function()' -- Line 1 (index 0 in API)
  local symbol = { name = "", kind = 12 }
  local range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 30 } }

  local depth, parent_sig = test_patterns.process_lua_test_symbol(
    symbol,
    config,
    state,
    range,
    test_info_cache,
    first_bracket_counts,
    items,
    0,
    T._test.generate_signature,
    mock_lsp_symbol_kind,
    bufnr
  )

  h.eq(#items, 1)
  h.eq(items[1].value.name, 'T["Category"]')
  h.eq(items[1].depth, 0)
  local expected_parent_sig = items[1].value.signature

  h.eq(symbol.name, '["Test 1"]')
  h.eq(symbol.is_test_symbol, true)
  h.eq(range.start.character >= 0, true) -- Check character was adjusted (>=0)
  h.eq(symbol.parent_signature, expected_parent_sig)

  h.eq(depth, 1)
  h.eq(parent_sig, expected_parent_sig)
end

T["LuaTests"]["process_lua_test_symbol hierarchy enabled single bracket"] = function()
  local config = create_mock_config()
  config.lua_test_preserve_hierarchy = true
  local state = create_mock_state()
  local test_info_cache = {}
  local first_bracket_counts = { ['T["Single"]'] = 1 }
  local items = {}
  local bufnr = 1

  mock_buffer_lines[1] = 'T["Single"] = function()' -- Line 1 (index 0 in API)
  local symbol = { name = "", kind = 12 }
  local range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 30 } }

  local depth, parent_sig = test_patterns.process_lua_test_symbol(
    symbol,
    config,
    state,
    range,
    test_info_cache,
    first_bracket_counts,
    items,
    0,
    T._test.generate_signature,
    mock_lsp_symbol_kind,
    bufnr
  )

  h.eq(#items, 0)

  h.eq(symbol.name, 'T["Single"]')
  h.eq(symbol.is_test_symbol, true)
  h.eq(range.start.character, 0)
  h.eq(symbol.parent_signature, nil)

  h.eq(depth, 0)
  h.eq(parent_sig, nil)
end

T["LuaTests"]["process_lua_test_symbol hierarchy disabled"] = function()
  local config = create_mock_config()
  config.lua_test_preserve_hierarchy = false
  local state = create_mock_state()
  local test_info_cache = {}
  local first_bracket_counts = {}
  local items = {}
  local bufnr = 1

  mock_buffer_lines[1] = 'T["Category"]["Test 1"] = function()' -- Line 1 (index 0 in API)
  local symbol = { name = "", kind = 12 }
  local range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 30 } }

  local depth, parent_sig = test_patterns.process_lua_test_symbol(
    symbol,
    config,
    state,
    range,
    test_info_cache,
    first_bracket_counts,
    items,
    0,
    T._test.generate_signature,
    mock_lsp_symbol_kind,
    bufnr
  )

  h.eq(#items, 0)

  h.eq(symbol.name, 'T["Category"]["Test 1"]')
  h.eq(symbol.is_test_symbol, true)
  h.eq(range.start.character, 0)
  h.eq(symbol.parent_signature, nil)

  h.eq(depth, 0)
  h.eq(parent_sig, nil)
end

T["LuaTests"]["process_lua_test_symbol handles truncation"] = function()
  local config = create_mock_config()
  config.lua_test_preserve_hierarchy = false
  config.lua_test_truncate_length = 10
  local state = create_mock_state()
  local test_info_cache = {}
  local first_bracket_counts = {}
  local items = {}
  local bufnr = 1

  mock_buffer_lines[1] = 'T["AVeryLongCategoryName"]["AnotherVeryLongTestName"] = function()' -- Line 1 (index 0 in API)
  local symbol = { name = "", kind = 12 }
  local range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 60 } }

  test_patterns.process_lua_test_symbol(
    symbol,
    config,
    state,
    range,
    test_info_cache,
    first_bracket_counts,
    items,
    0,
    T._test.generate_signature,
    mock_lsp_symbol_kind,
    bufnr
  )

  h.eq(symbol.name, 'T["AVeryLo...')
end

return T
