-- test_symbol_processing.lua
---@diagnostic disable: need-check-nil, param-type-mismatch
local h = require("tests.helpers")
local namu_symbols = require("namu.namu_symbols")
local namu_ctags = require("namu.namu_ctags")
local format_utils = require("namu.core.format_utils")
local lsp = require("namu.namu_symbols.lsp")
---@diagnostic disable-next-line: undefined-global
local new_set = MiniTest.new_set

-- Test helpers
local function create_mock_config()
  return {
    display = {
      format = "tree_guides",
      style = 2,
      tree_guides = { style = "unicode" },
      mode = "icon",
      padding = 2,
    },
    kindIcons = {
      Class = "󰌗",
      Method = "󰆧",
      Function = "󰊕",
      Variable = "",
      Unknown = "󱠦",
    },
    AllowKinds = {
      default = { "Function", "Method", "Class", "Variable" },
      lua = { "Function", "Method", "Class", "Variable" },
      python = { "Function", "Method", "Class", "Variable" },
    },
    BlockList = {
      default = {},
      lua = {},
      python = {},
    },
  }
end

-- Store the original function to avoid infinite recursion
local original_symbols_to_selecta = namu_symbols._test.symbols_to_selecta_items

-- Set up the test wrappers
namu_symbols._test.symbols_to_selecta_items = function(symbols, config)
  local orig_config = namu_symbols.config
  namu_symbols.config = config or create_mock_config()
  vim.bo.filetype = "python" -- default, can be overridden in tests
  local result = original_symbols_to_selecta(symbols)
  namu_symbols.config = orig_config
  return result
end

namu_ctags._test = {
  symbols_to_selecta_items = function(symbols, config, filetype)
    local orig_config = namu_ctags.config
    namu_ctags.config = config or create_mock_config()
    local state = { original_ft = filetype or "python" }
    namu_ctags.state_ctags = state
    local result = namu_ctags._test.symbols_to_selecta_items(symbols)
    namu_ctags.config = orig_config
    return result
  end,
}

local T = new_set({
  hooks = {
    pre_case = function()
      vim.cmd("new")
      vim.bo.buftype = "nofile"
      -- Reset caches
      if namu_symbols.symbol_cache then
        namu_symbols.symbol_cache = nil
      end
      if namu_symbols.symbol_range_cache then
        namu_symbols.symbol_range_cache = {}
      end
      if namu_ctags.symbol_cache then
        namu_ctags.symbol_cache = nil
      end
      if namu_ctags.symbol_range_cache then
        namu_ctags.symbol_range_cache = {}
      end
    end,
    post_case = function()
      vim.cmd("bdelete!")
    end,
  },
})

T["LSP.symbols_processing"] = new_set()

T["LSP.symbols_processing"]["processes Python class hierarchy correctly"] = function()
  local python_symbols = {
    {
      name = "MyClass",
      kind = 5, -- Class
      range = {
        start = { line = 3, character = 0 },
        ["end"] = { line = 88, character = 0 },
      },
      children = {
        {
          name = "__init__",
          kind = 6, -- Method
          range = {
            start = { line = 7, character = 4 },
            ["end"] = { line = 13, character = 4 },
          },
        },
        {
          name = "NestedClass",
          kind = 5, -- Class
          range = {
            start = { line = 33, character = 4 },
            ["end"] = { line = 70, character = 4 },
          },
          children = {
            {
              name = "__init__",
              kind = 6, -- Method
              range = {
                start = { line = 36, character = 8 },
                ["end"] = { line = 40, character = 8 },
              },
            },
          },
        },
      },
    },
  }

  local result = namu_symbols._test.symbols_to_selecta_items(python_symbols)

  -- Verify basic structure
  h.eq(#result, 4)

  -- Check root class
  h.eq(result[1].value.name, "MyClass")
  h.eq(result[1].depth, 0)
  h.eq(result[1].kind, "Class")

  -- Check first method
  h.eq(result[2].value.name, "__init__")
  h.eq(result[2].depth, 1)
  h.eq(result[2].kind, "Method")
  h.eq(result[2].value.parent_signature, result[1].value.signature)

  -- Check nested class
  h.eq(result[3].value.name, "NestedClass")
  h.eq(result[3].depth, 1)
  h.eq(result[3].kind, "Class")
  h.eq(result[3].value.parent_signature, result[1].value.signature)

  -- Check nested class method
  h.eq(result[4].value.name, "__init__")
  h.eq(result[4].depth, 2)
  h.eq(result[4].kind, "Method")
  h.eq(result[4].value.parent_signature, result[3].value.signature)
end

-- CTags Processing Tests
T["CTags.symbols_processing"] = new_set()

T["CTags.symbols_processing"]["processes Python CTags output correctly"] = function()
  local ctags_symbols = {
    {
      _type = "tag",
      kind = "class",
      line = 4,
      ["end"] = 88,
      name = "MyClass",
    },
    {
      _type = "tag",
      kind = "member",
      line = 8,
      ["end"] = 13,
      name = "__init__",
      scope = "MyClass",
      scopeKind = "class",
    },
    {
      _type = "tag",
      kind = "class",
      line = 34,
      ["end"] = 70,
      name = "NestedClass",
      scope = "MyClass",
      scopeKind = "class",
    },
    {
      _type = "tag",
      kind = "member",
      line = 37,
      ["end"] = 40,
      name = "__init__",
      scope = "MyClass.NestedClass",
      scopeKind = "class",
    },
  }

  local result = namu_ctags._test.symbols_to_selecta_items(ctags_symbols)

  -- Verify structure
  h.eq(#result, 4)

  -- Check signatures and parent relationships
  h.eq(result[1].value.signature ~= nil, true)
  h.eq(result[2].value.parent_signature, result[1].value.signature)
  h.eq(result[3].value.parent_signature, result[1].value.signature)
  h.eq(result[4].value.parent_signature, result[3].value.signature)

  -- Verify depths
  h.eq(result[1].depth, 0)
  h.eq(result[2].depth, 1)
  h.eq(result[3].depth, 1)
  h.eq(result[4].depth, 2)
end

T["CTags.symbols_processing"]["handles Lua module patterns correctly"] = function()
  local lua_symbols = {
    {
      _type = "tag",
      kind = "function",
      line = 1284,
      name = "help",
      scope = "MiniPick.builtin",
      scopeKind = "unknown",
    },
    {
      _type = "tag",
      kind = "function",
      line = 1300,
      name = "files",
      scope = "MiniPick.builtin",
      scopeKind = "unknown",
    },
  }

  local result = namu_ctags._test.symbols_to_selecta_items(lua_symbols, nil, "lua")

  -- Verify no artificial nesting for Lua module patterns
  h.eq(result[1].depth, 0)
  h.eq(result[2].depth, 0)

  -- Verify full names are preserved
  h.eq(result[1].value.name, "MiniPick.builtin.help")
  h.eq(result[2].value.name, "MiniPick.builtin.files")
end

-- Format Utils Tests
T["Format.tree_guides"] = new_set()

T["Format.tree_guides"]["generates correct tree guides"] = function()
  local config = create_mock_config()
  config.display.format = "tree_guides"

  local items = {
    {
      depth = 0,
      value = {
        name = "Root",
        signature = "root:0:1:1",
      },
    },
    {
      depth = 1,
      value = {
        name = "Child1",
        signature = "child1:1:2:1",
        parent_signature = "root:0:1:1",
      },
    },
    {
      depth = 1,
      value = {
        name = "Child2",
        signature = "child2:1:3:1",
        parent_signature = "root:0:1:1",
      },
    },
  }

  local processed_items = format_utils.add_tree_state_to_items(items)

  -- Root item should be marked as not last since it has children
  h.eq(processed_items[1].tree_state[1], true) -- Root item is last at its level
  -- First child should have parent's state (true) and its own (false)
  h.eq(vim.deep_equal(processed_items[2].tree_state, { true, false }), true)
  -- Last child should have parent's state (true) and its own (true)
  h.eq(vim.deep_equal(processed_items[3].tree_state, { true, true }), true)
  -- Test guide generation
  local guides = format_utils.make_tree_guides(processed_items[2].tree_state, "unicode")
  h.eq(guides, "  ├─") -- Space for parent (last), then branch
  guides = format_utils.make_tree_guides(processed_items[3].tree_state, "unicode")
  h.eq(guides, "  └─") -- Space for parent (last), then end branch
end

-- LSP Symbols additional tests
T["LSP.symbols_processing"]["handles empty children correctly"] = function()
  local symbols = {
    {
      name = "EmptyClass",
      kind = 5,
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 5, character = 0 },
      },
      children = {},
    },
  }

  local result = namu_symbols._test.symbols_to_selecta_items(symbols)
  h.eq(#result, 1)
  h.eq(result[1].depth, 0)
end

T["LSP.symbols_processing"]["handles multiple top-level symbols"] = function()
  local symbols = {
    {
      name = "Class1",
      kind = 5,
      range = {
        start = { line = 0, character = 0 },
        ["end"] = { line = 5, character = 0 },
      },
    },
    {
      name = "Class2",
      kind = 5,
      range = {
        start = { line = 6, character = 0 },
        ["end"] = { line = 10, character = 0 },
      },
    },
  }

  local result = namu_symbols._test.symbols_to_selecta_items(symbols)
  h.eq(#result, 2)
  h.eq(result[1].depth, 0)
  h.eq(result[2].depth, 0)
  h.eq(result[1].value.parent_signature, nil)
  h.eq(result[2].value.parent_signature, nil)
end

-- CTags additional tests
T["CTags.symbols_processing"]["handles C++ class with nested structs"] = function()
  local cpp_symbols = {
    {
      _type = "tag",
      kind = "class",
      line = 1,
      name = "OuterClass",
      ["end"] = 20,
    },
    {
      _type = "tag",
      kind = "struct",
      line = 2,
      name = "InnerStruct",
      scope = "OuterClass",
      scopeKind = "class",
    },
    {
      _type = "tag",
      kind = "member",
      line = 3,
      name = "struct_method",
      scope = "OuterClass.InnerStruct",
      scopeKind = "struct",
    },
  }

  local result = namu_ctags._test.symbols_to_selecta_items(cpp_symbols, nil, "cpp")
  h.eq(#result, 3)
  h.eq(result[2].value.parent_signature, result[1].value.signature)
  h.eq(result[3].value.parent_signature, result[2].value.signature)
end

T["CTags.symbols_processing"]["handles Ruby modules and classes"] = function()
  local ruby_symbols = {
    {
      _type = "tag",
      kind = "module",
      line = 1,
      name = "MyModule",
    },
    {
      _type = "tag",
      kind = "class",
      line = 2,
      name = "MyClass",
      scope = "MyModule",
      scopeKind = "module",
    },
    {
      _type = "tag",
      kind = "method",
      line = 3,
      name = "my_method",
      scope = "MyModule::MyClass",
      scopeKind = "class",
    },
  }

  local result = namu_ctags._test.symbols_to_selecta_items(ruby_symbols, nil, "ruby")
  h.eq(#result, 3)
  h.eq(result[1].depth, 0)
  h.eq(result[2].depth, 1)
  h.eq(result[3].depth, 2)
end

-- Format Utils Extended Tests
T["Format.display_modes"] = new_set()

T["Format.display_modes"]["handles indent format with different styles"] = function()
  local config = create_mock_config()
  config.display.format = "indent"
  config.display.mode = "icon"

  local test_cases = {
    {
      style = 2,
      depths = { 0, 1, 2 },
      expected = {
        [0] = "",
        [1] = "  ..", -- Two spaces before ..
        [2] = "    ..", -- Four spaces before ..
      },
    },
    {
      style = 3,
      depths = { 0, 1, 2 },
      expected = {
        [0] = "",
        [1] = "  →", -- Two spaces before →
        [2] = "    →", -- Four spaces before →
      },
    },
  }

  for _, case in ipairs(test_cases) do
    config.display.style = case.style

    for _, depth in ipairs(case.depths) do
      local item = {
        depth = depth,
        icon = "󰊕",
        value = {
          name = "test_item",
        },
      }

      local result = format_utils.format_item_for_display(item, config)
      -- Check if result contains the expected indentation pattern
      local expected_pattern = vim.pesc(case.expected[depth] .. "test_item")
      h.eq(
        result:match(expected_pattern) ~= nil,
        true,
        string.format("Style %d, depth %d failed to match expected pattern", case.style, depth)
      )
    end
  end
end

T["Format.display_modes"]["handles icon positioning in indent format"] = function()
  local config = create_mock_config()
  config.display.format = "indent"
  config.display.mode = "icon"

  local item = {
    depth = 1,
    icon = "󰊕",
    value = {
      name = "test_item",
    },
  }

  -- Test icon after prefix
  config.display.icon_after_prefix_symbol = true
  local result = format_utils.format_item_for_display(item, config)
  h.eq(result:match("^%.%.󰊕") ~= nil, true, "When icon is after, should start with .. followed by icon")

  -- Test icon before prefix
  config.display.icon_after_prefix_symbol = false
  result = format_utils.format_item_for_display(item, config)
  h.eq(result:match("^󰊕.*%.%.") ~= nil, true, "When icon is before, should start with icon followed by ..")
end

T["Format.tree_guides"]["handles different guide styles"] = function()
  local items = {
    {
      depth = 0,
      value = { name = "Root", signature = "root:0:1" },
    },
    {
      depth = 1,
      value = {
        name = "Child",
        signature = "child:1:2",
        parent_signature = "root:0:1",
      },
    },
  }

  local processed = format_utils.add_tree_state_to_items(items)

  -- Test ASCII style
  local guides_ascii = format_utils.make_tree_guides(processed[1].tree_state, "ascii")
  h.eq(guides_ascii:match("`%-") ~= nil, true) -- Changed from "|%-" to "`%-"

  -- Test Unicode style
  local guides_unicode = format_utils.make_tree_guides(processed[1].tree_state, "unicode")
  h.eq(guides_unicode:match("└%-") ~= nil, true)
end

T["Format.display_modes"]["handles special indicators"] = function()
  local config = create_mock_config()

  local item = {
    depth = 1,
    icon = "󰊕",
    value = {
      name = "test_item",
      is_current = true,
    },
  }

  local result = format_utils.format_item_for_display(item, config)
  h.eq(result:match("^▼") ~= nil, true)
end

T["Format.tree_guides"]["handles different guide styles"] = function()
  local config = create_mock_config()
  config.display.format = "tree_guides"
  -- Test ASCII style
  config.display.tree_guides.style = "ascii"
  local items = {
    {
      depth = 0,
      value = { name = "Root", signature = "root:0:1" },
    },
    {
      depth = 1,
      value = {
        name = "Child",
        signature = "child:1:2",
        parent_signature = "root:0:1",
      },
    },
  }
  local processed = format_utils.add_tree_state_to_items(items)
  -- Test ASCII style
  local result_ascii = format_utils.make_tree_guides(processed[1].tree_state, "ascii")
  -- Pattern should include the spaces
  h.eq(
    result_ascii:match("`-") ~= nil,
    true, -- Note the two spaces before `-
    "ASCII guide should have proper spacing and characters"
  )

  -- Test Unicode style
  local result_unicode = format_utils.make_tree_guides(processed[1].tree_state, "unicode")
  h.eq(result_unicode:match("└─") ~= nil, true, "Unicode guide should have proper spacing and characters")
end

T["Format.display_modes"]["handles raw mode correctly"] = function()
  local config = create_mock_config()
  config.display.mode = "raw"

  local item = {
    depth = 1,
    icon = "󰊕",
    value = {
      name = "test_item",
      text = "raw_text",
    },
  }

  local result = format_utils.format_item_for_display(item, config)
  h.eq(result, "raw_text")
end

-- Edge Cases
T["Edge.cases"] = new_set()

T["Edge.cases"]["handles invalid ranges gracefully"] = function()
  local symbols = {
    {
      name = "InvalidRange",
      kind = 5,
      range = {
        start = { line = 10, character = 0 },
        ["end"] = { line = 5, character = 0 }, -- Invalid: end before start
      },
    },
  }

  local result = namu_symbols._test.symbols_to_selecta_items(symbols)
  h.eq(#result, 1)
  h.eq(result[1].value.lnum > 0, true)
end

T["Edge.cases"]["handles missing scopes in CTags"] = function()
  local ctags_symbols = {
    {
      _type = "tag",
      kind = "function",
      line = 1,
      name = "standalone_function",
      -- No scope information
    },
  }

  local result = namu_ctags._test.symbols_to_selecta_items(ctags_symbols)
  h.eq(#result, 1)
  h.eq(result[1].depth, 0)
  h.eq(result[1].value.parent_signature, nil)
end

return T
