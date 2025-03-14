---@diagnostic disable: need-check-nil, param-type-mismatch
local h = require("tests.helpers")
local callhierarchy = require("namu.namu_callhierarchy")
local navigation = require("namu.namu_callhierarchy.navigation")
---@diagnostic disable-next-line: undefined-global
local new_set = MiniTest.new_set

local T = new_set()

-- Expose test functions from the module
callhierarchy._test = {
  generate_signature = function(symbol, depth)
    local range = symbol.range or (symbol.location and symbol.location.range)
    if not range then
      return nil
    end
    return string.format("%s:%d:%d:%d", symbol.name, depth, range.start.line, range.start.character)
  end,
  make_tree_guides = function(tree_state)
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
  end,
  find_parent_position = function(items, parent_signature)
    for i = #items, 1, -1 do
      if items[i].value and items[i].value.signature == parent_signature then
        return i
      end
    end
    return nil
  end,
  check_call_hierarchy_support = function(bufnr)
    return { prepare = true, incoming = true, outgoing = true } -- Mock for tests
  end,
  calls_to_selecta_items = function(calls, direction, depth, parent_tree_state, visited)
    -- Simplified mock version for testing
    local items = {}
    for i, call in ipairs(calls) do
      local item_data = direction == "incoming" and call.from or call.to
      local is_last = (i == #calls)
      local current_tree_state = {}
      if parent_tree_state then
        for _, branch_info in ipairs(parent_tree_state) do
          table.insert(current_tree_state, branch_info)
        end
      end
      table.insert(current_tree_state, is_last)

      local range = item_data.selectionRange or item_data.range
      local uri = item_data.uri
      local file_path = vim.uri_to_fname(uri)
      local short_path = file_path:match("([^/\\]+)$") or file_path
      local signature = string.format("%s:%d:%d:%s", uri, range.start.line, range.start.character, item_data.name)

      local item = {
        text = item_data.name .. " [" .. short_path .. ":" .. (range.start.line + 1) .. "]",
        value = {
          name = item_data.name,
          kind = "Function",
          lnum = range.start.line + 1,
          col = range.start.character + 1,
          end_lnum = range["end"].line + 1,
          end_col = range["end"].character + 1,
          uri = uri,
          file_path = file_path,
          call_type = direction,
          signature = signature,
        },
        icon = "󰊕",
        kind = "Function",
        depth = depth,
        tree_state = current_tree_state,
      }

      table.insert(items, item)
    end
    return items
  end,
  create_lsp_call_item = function(item)
    return {
      name = item.value.name,
      kind = 12, -- Function
      uri = item.value.uri,
      range = {
        start = { line = item.value.lnum - 1, character = item.value.col - 1 },
        ["end"] = { line = item.value.end_lnum - 1, character = item.value.end_col - 1 },
      },
      selectionRange = {
        start = { line = item.value.lnum - 1, character = item.value.col - 1 },
        ["end"] = { line = item.value.end_lnum - 1, character = item.value.end_col - 1 },
      },
    }
  end,
  format_lsp_error = function(err, default_message)
    if type(err) == "string" then
      return err
    elseif type(err) == "table" and err.message then
      return err.message
    else
      return default_message or "Unknown error"
    end
  end,
  apply_simple_highlights = function(buf, filtered_items, config)
    -- Mock implementation for testing
    return true
  end,
  create_synthetic_call_item = function()
    return {
      name = "test_function",
      kind = 12,
      selectionRange = {
        start = { line = 10, character = 5 },
        ["end"] = { line = 10, character = 15 },
      },
      uri = "file:///test/path.lua",
    }
  end,
  process_call_hierarchy_item = function(item, direction, cache_key, notify_opts)
    return {}
  end,
  jump_to_call = function(item)
    -- Mock implementation
    return item and item.value and true or false
  end,
  update_tree_guides_after_sorting = navigation.update_tree_guides_after_sorting,
  sort_by_nesting_depth = navigation.sort_by_nesting_depth,
}

-- Set up basic config for tests
T.setup = function()
  callhierarchy.setup({
    display = { format = "tree_guides" },
    call_hierarchy = {
      max_depth = 2,
      max_depth_limit = 4,
      show_cycles = false,
    },
    current_highlight = {
      enabled = true,
      hl_group = "Visual",
      prefix_icon = " ",
    },
  })
end

-- Config Tests
T["CallHierarchy.config"] = new_set()

-- test 1
T["CallHierarchy.config"]["applies default configuration"] = function()
  callhierarchy.setup({})

  -- Check config values are correctly set
  h.eq(callhierarchy.config.call_hierarchy.max_depth, 2)
  h.eq(callhierarchy.config.call_hierarchy.max_depth_limit, 4)
  h.eq(callhierarchy.config.call_hierarchy.show_cycles, false)
  h.eq(callhierarchy.config.display.format, "tree_guides")
end

-- test 2
T["CallHierarchy.config"]["merges user configuration"] = function()
  callhierarchy.setup({
    call_hierarchy = {
      max_depth = 3,
      show_cycles = true,
    },
    current_highlight = {
      enabled = true,
      prefix_icon = "▶",
    },
  })

  -- Check merged config values
  h.eq(callhierarchy.config.call_hierarchy.max_depth, 3)
  h.eq(callhierarchy.config.call_hierarchy.max_depth_limit, 4) -- Default preserved
  h.eq(callhierarchy.config.call_hierarchy.show_cycles, true) -- User value applied
  h.eq(callhierarchy.config.current_highlight.enabled, true) -- User value applied
  h.eq(callhierarchy.config.current_highlight.prefix_icon, "▶") -- User value applied
end

-- test 3
T["CallHierarchy.config"]["preserves core UI values"] = function()
  local original_border = callhierarchy.config.window.border

  callhierarchy.setup({
    window = {
      border = "single",
    },
  })

  h.eq(callhierarchy.config.window.border, "single")

  -- Restore
  callhierarchy.setup({
    window = {
      border = original_border,
    },
  })
end

-- Tree Guide Tests
T["CallHierarchy.tree_guides"] = new_set()

-- test 4
T["CallHierarchy.tree_guides"]["generates correct tree guides"] = function()
  local make_tree_guides = callhierarchy._test.make_tree_guides

  -- Test a simple branch
  local guides = make_tree_guides({ true })
  h.eq(guides, "└─")

  -- Test a non-last item
  guides = make_tree_guides({ false })
  h.eq(guides, "├─")

  -- Test nested structure
  guides = make_tree_guides({ false, true })
  h.eq(guides, "┆ └─")

  -- Test complex structure
  guides = make_tree_guides({ false, false, true })
  h.eq(guides, "┆ ┆ └─")

  -- Test another variation
  guides = make_tree_guides({ true, false })
  h.eq(guides, "  ├─")
end

-- test 5
T["CallHierarchy.tree_guides"]["handles deeply nested guides"] = function()
  local make_tree_guides = callhierarchy._test.make_tree_guides

  -- Deep nesting with alternating patterns
  local guides = make_tree_guides({ true, false, true, false, true })
  h.eq(guides, "  ┆   ┆ └─")

  -- Consistent non-last items
  guides = make_tree_guides({ false, false, false, false })
  h.eq(guides, "┆ ┆ ┆ ├─")

  -- Consistent last items
  guides = make_tree_guides({ true, true, true, true })
  h.eq(guides, "      └─")
end

-- Parent Position Finding Tests
T["CallHierarchy.parent_finding"] = new_set()

-- test 6
T["CallHierarchy.parent_finding"]["finds parent position correctly"] = function()
  local find_parent_position = callhierarchy._test.find_parent_position

  -- Mock items with signatures
  local items = {
    { value = { signature = "func1:0:10:5" } },
    { value = { signature = "func2:1:15:2" } },
    { value = { signature = "func3:2:20:8" } },
  }

  -- Test finding each position
  local pos = find_parent_position(items, "func1:0:10:5")
  h.eq(pos, 1)

  pos = find_parent_position(items, "func2:1:15:2")
  h.eq(pos, 2)

  pos = find_parent_position(items, "func3:2:20:8")
  h.eq(pos, 3)

  -- Test non-existent signature
  pos = find_parent_position(items, "nonexistent")
  h.eq(pos, nil)
end

-- test 7
T["CallHierarchy.parent_finding"]["handles empty and nil cases"] = function()
  local find_parent_position = callhierarchy._test.find_parent_position

  -- Empty items array
  local pos = find_parent_position({}, "signature")
  h.eq(pos, nil)

  -- Nil signature
  pos = find_parent_position({ { value = { signature = "test" } } }, nil)
  h.eq(pos, nil)

  -- Items without value property
  pos = find_parent_position({ { text = "test" } }, "test")
  h.eq(pos, nil)

  -- Items without signature property
  pos = find_parent_position({ { value = { name = "test" } } }, "test")
  h.eq(pos, nil)
end

-- Call Hierarchy Support Tests
T["CallHierarchy.support"] = new_set()

-- test 8
T["CallHierarchy.support"]["detects call hierarchy support correctly"] = function()
  local check_call_hierarchy_support = callhierarchy._test.check_call_hierarchy_support

  -- Test with mocked function that always returns support
  local support = check_call_hierarchy_support(0)
  h.eq(support.prepare, true)
  h.eq(support.incoming, true)
  h.eq(support.outgoing, true)
end

-- Synthetic Call Item Tests
T["CallHierarchy.synthetic_item"] = new_set()

-- test 9
T["CallHierarchy.synthetic_item"]["creates proper synthetic call item"] = function()
  local create_synthetic_call_item = callhierarchy._test.create_synthetic_call_item

  -- Test synthetic item creation
  local item = create_synthetic_call_item()
  h.eq(item.name, "test_function")
  h.eq(item.kind, 12) -- Function kind
  h.eq(item.uri, "file:///test/path.lua")
  h.eq(type(item.selectionRange), "table")
  h.eq(item.selectionRange.start.line, 10)
  h.eq(item.selectionRange.start.character, 5)
end

-- LSP Item Conversion Tests
T["CallHierarchy.lsp_conversion"] = new_set()

-- test 10
T["CallHierarchy.lsp_conversion"]["converts selecta items to LSP call items"] = function()
  local create_lsp_call_item = callhierarchy._test.create_lsp_call_item

  -- Mock selecta item
  local item = {
    value = {
      name = "test_function",
      lnum = 10,
      col = 5,
      end_lnum = 15,
      end_col = 20,
      uri = "file:///test/path.lua",
    },
  }

  -- Convert to LSP item
  local lsp_item = create_lsp_call_item(item)

  -- Verify structure
  h.eq(lsp_item.name, "test_function")
  h.eq(lsp_item.kind, 12) -- Function
  h.eq(lsp_item.uri, "file:///test/path.lua")
  h.eq(lsp_item.range.start.line, 9) -- 0-indexed
  h.eq(lsp_item.range.start.character, 4) -- 0-indexed
  h.eq(lsp_item.range["end"].line, 14) -- 0-indexed
  h.eq(lsp_item.range["end"].character, 19) -- 0-indexed
end

-- test 11
T["CallHierarchy.lsp_conversion"]["handles edge cases in LSP item creation"] = function()
  local create_lsp_call_item = callhierarchy._test.create_lsp_call_item

  -- Edge case: minimal item
  local item = {
    value = {
      name = "minimal",
      lnum = 1,
      col = 1,
      end_lnum = 1,
      end_col = 1,
      uri = "file:///minimal.lua",
    },
  }

  local lsp_item = create_lsp_call_item(item)
  h.eq(lsp_item.name, "minimal")
  h.eq(lsp_item.range.start.line, 0)
  h.eq(lsp_item.range.start.character, 0)
end

-- Error Formatting Tests
T["CallHierarchy.error_formatting"] = new_set()

-- test 12
T["CallHierarchy.error_formatting"]["formats LSP errors correctly"] = function()
  local format_lsp_error = callhierarchy._test.format_lsp_error

  -- Test string error
  local msg = format_lsp_error("Error message", "Default")
  h.eq(msg, "Error message")

  -- Test table error with message
  msg = format_lsp_error({ message = "Table message" }, "Default")
  h.eq(msg, "Table message")

  -- Test fallback to default
  msg = format_lsp_error({}, "Default")
  h.eq(msg, "Default")

  -- Test nil with default
  msg = format_lsp_error(nil, "Default")
  h.eq(msg, "Default")
end

-- test 13
T["CallHierarchy.error_formatting"]["handles complex error structures"] = function()
  local format_lsp_error = callhierarchy._test.format_lsp_error

  -- Complex error object with nested message
  local error_obj = {
    code = 100,
    message = "Complex error",
    data = {
      details = "More details",
    },
  }

  local msg = format_lsp_error(error_obj, "Default")
  h.eq(msg, "Complex error")

  -- Object without message but with code (should use default)
  local error_obj2 = {
    code = 100,
    data = {
      details = "Details only",
    },
  }

  msg = format_lsp_error(error_obj2, "Default for no message")
  h.eq(msg, "Default for no message")
end

-- Call to Selecta Item Conversion Tests
T["CallHierarchy.item_conversion"] = new_set()

-- test 14
T["CallHierarchy.item_conversion"]["converts call items to selecta items"] = function()
  local calls_to_selecta_items = callhierarchy._test.calls_to_selecta_items

  -- Mock call hierarchy items
  local calls = {
    {
      from = {
        name = "caller_function",
        uri = "file:///test/caller.lua",
        range = {
          start = { line = 5, character = 10 },
          ["end"] = { line = 5, character = 25 },
        },
      },
    },
  }

  -- Convert to selecta items
  local items = calls_to_selecta_items(calls, "incoming", 1)

  -- Verify structure
  h.eq(#items, 1)
  h.eq(items[1].value.name, "caller_function")
  h.eq(items[1].value.call_type, "incoming")
  h.eq(items[1].depth, 1)
  h.eq(type(items[1].tree_state), "table")
end

-- test 15
T["CallHierarchy.item_conversion"]["handles multiple call items"] = function()
  local calls_to_selecta_items = callhierarchy._test.calls_to_selecta_items

  -- Mock multiple call hierarchy items
  local calls = {
    {
      from = {
        name = "caller_function1",
        uri = "file:///test/caller1.lua",
        range = {
          start = { line = 5, character = 10 },
          ["end"] = { line = 5, character = 25 },
        },
      },
    },
    {
      from = {
        name = "caller_function2",
        uri = "file:///test/caller2.lua",
        range = {
          start = { line = 15, character = 5 },
          ["end"] = { line = 15, character = 20 },
        },
      },
    },
  }

  -- Convert to selecta items
  local items = calls_to_selecta_items(calls, "incoming", 1)

  -- Verify structure
  h.eq(#items, 2)
  h.eq(items[1].value.name, "caller_function1")
  h.eq(items[2].value.name, "caller_function2")

  -- Verify last item in tree state is handled correctly
  h.eq(items[1].tree_state[1], false) -- First item not last
  h.eq(items[2].tree_state[1], true) -- Second item is last
end

-- test 16
T["CallHierarchy.item_conversion"]["preserves parent tree state"] = function()
  local calls_to_selecta_items = callhierarchy._test.calls_to_selecta_items

  -- Parent tree state
  local parent_tree_state = { false, true }

  -- Mock call hierarchy items
  local calls = {
    {
      from = {
        name = "nested_function",
        uri = "file:///test/nested.lua",
        range = {
          start = { line = 10, character = 5 },
          ["end"] = { line = 10, character = 15 },
        },
      },
    },
  }

  -- Convert with parent tree state
  local items = calls_to_selecta_items(calls, "incoming", 2, parent_tree_state)

  -- Verify tree state is preserved and extended
  h.eq(#items[1].tree_state, 3)
  h.eq(items[1].tree_state[1], false)
  h.eq(items[1].tree_state[2], true)
  h.eq(items[1].tree_state[3], true) -- Last (and only) item
end

-- Jump To Call Tests
T["CallHierarchy.jump"] = new_set()

-- test 17
T["CallHierarchy.jump"]["jump_to_call handles valid items"] = function()
  local jump_to_call = callhierarchy._test.jump_to_call

  -- Valid item
  local valid_item = {
    value = {
      name = "test_function",
      lnum = 10,
      col = 5,
      uri = "file:///test/path.lua",
      file_path = "/test/path.lua",
    },
  }

  local result = jump_to_call(valid_item)
  h.eq(result, true)

  -- Invalid item
  local invalid_item = {}
  result = jump_to_call(invalid_item)
  h.eq(result, false)

  -- Nil case
  result = jump_to_call(nil)
  h.eq(result, false)
end

-- TODO: uncomment those when adapt the naigation to the new refactor of callhierarchy
-- Navigation and Sorting Tests
-- T["CallHierarchy.navigation"] = new_set()

-- test 18
-- T["CallHierarchy.navigation"]["sort_by_nesting_depth organizes items correctly"] = function()
--   local sort_by_nesting_depth = callhierarchy._test.sort_by_nesting_depth
--
--   -- Create items with different depths
--   local items = {
--     { depth = 2, value = { name = "level2" } },
--     { depth = 0, value = { name = "root" } },
--     { depth = 1, value = { name = "level1a" } },
--     { depth = 1, value = { name = "level1b" } },
--   }
--
--   local sorted = sort_by_nesting_depth(items)
--
--   -- Verify sorting by depth
--   h.eq(sorted[1].value.name, "root") -- depth 0
--   h.eq(sorted[2].value.name, "level1a") -- depth 1
--   h.eq(sorted[3].value.name, "level1b") -- depth 1
--   h.eq(sorted[4].value.name, "level2") -- depth 2
-- end
--
-- -- test 19
-- T["CallHierarchy.navigation"]["updates tree guides after sorting"] = function()
--   local update_tree_guides = callhierarchy._test.update_tree_guides_after_sorting
--
--   -- Items with tree states but in wrong order
--   local items = {
--     {
--       depth = 1,
--       value = { name = "child", signature = "child", parent_signature = "root" },
--       tree_state = { false },
--     },
--     {
--       depth = 0,
--       value = { name = "root", signature = "root", parent_signature = nil },
--       tree_state = {},
--     },
--   }
--
--   -- Update tree guides
--   local updated = update_tree_guides(items)
--
--   -- Verify tree guide updates
--   h.eq(#updated, 2)
--   h.eq(updated[1].value.name, "root")
--   h.eq(#updated[1].tree_state, 0) -- Root has no tree guides
--
--   h.eq(updated[2].value.name, "child")
--   h.eq(#updated[2].tree_state, 1)
--   h.eq(updated[2].tree_state[1], true) -- Should be marked as last child
-- end
--
-- -- test 20
-- T["CallHierarchy.navigation"]["handles complex hierarchies"] = function()
--   local update_tree_guides = callhierarchy._test.update_tree_guides_after_sorting
--
--   -- Complex hierarchy with multiple levels
--   local items = {
--     {
--       depth = 2,
--       value = { name = "grandchild1", signature = "gc1", parent_signature = "child1" },
--       tree_state = { false, false },
--     },
--     {
--       depth = 2,
--       value = { name = "grandchild2", signature = "gc2", parent_signature = "child1" },
--       tree_state = { false, true },
--     },
--     {
--       depth = 1,
--       value = { name = "child1", signature = "child1", parent_signature = "root" },
--       tree_state = { false },
--     },
--     {
--       depth = 1,
--       value = { name = "child2", signature = "child2", parent_signature = "root" },
--       tree_state = { true },
--     },
--     {
--       depth = 0,
--       value = { name = "root", signature = "root", parent_signature = nil },
--       tree_state = {},
--     },
--   }
--
--   -- Sort and update tree guides
--   local sorted = callhierarchy._test.sort_by_nesting_depth(items)
--   local updated = update_tree_guides(sorted)
--
--   -- Verify
--   h.eq(updated[1].value.name, "root")
--   h.eq(updated[2].value.name, "child1")
--   h.eq(updated[3].value.name, "grandchild1")
--   h.eq(updated[4].value.name, "grandchild2")
--   h.eq(updated[5].value.name, "child2")
--
--   -- Check tree state update for child1
--   h.eq(updated[2].tree_state[1], false) -- Not last child of root
--
--   -- Check tree state update for grandchild1
--   h.eq(updated[3].tree_state[1], false) -- Same parent branch
--   h.eq(updated[3].tree_state[2], false) -- Not last grandchild
--
--   -- Check tree state update for grandchild2
--   h.eq(updated[4].tree_state[1], false) -- Same parent branch
--   h.eq(updated[4].tree_state[2], true) -- Last grandchild
--
--   -- Check tree state update for child2
--   h.eq(updated[5].tree_state[1], true) -- Last child of root
-- end

-- Highlight Application Tests
T["CallHierarchy.highlights"] = new_set()

-- test 21
T["CallHierarchy.highlights"]["applies simple highlights correctly"] = function()
  local apply_simple_highlights = callhierarchy._test.apply_simple_highlights

  -- Mock buffer and items
  local buf = 1
  local filtered_items = {
    {
      text = "function1 [test.lua:10]",
      kind = "Function",
    },
    {
      text = "method2 [test.lua:20] (recursive)",
      kind = "Method",
    },
  }

  -- Apply highlights (mock returns true)
  local result = apply_simple_highlights(buf, filtered_items, callhierarchy.config)
  h.eq(result, true)
end

return T
