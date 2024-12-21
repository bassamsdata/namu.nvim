local h = require('mini.test')
local selecta = require('selecta')

local T = h.new_set()

local function setup_test_items()
    return {
        { text = "file1.lua", value = "path/to/file1.lua", icon = "󰈙 " },
        { text = "setup_function", value = "function_path", icon = "󰊕 " },
        { text = "config_options", value = "config_path", icon = "󰒓 " },
    }
end

-- -- Create test groups
-- T["highlighting"] = h.new_set()
T["selection"] = h.new_set()
T["filtering"] = h.new_set()
-- -- T["display_modes"] = h.new_set()

-- -- Test data
-- local test_items = {
--     {
--         text = "file1.lua",
--         value = "path/to/file1.lua",
--         icon = "󰈙",
--         kind = "File"
--     },
--     {
--         text = "MyClass",
--         value = "class_definition",
--         icon = "󰌗",
--         kind = "Class"
--     },
--     {
--         text = "setup_function",
--         value = "func_definition",
--         icon = "󰊕",
--         kind = "Function"
--     },
-- }


-- local function with_picker(items, config, test_fn)
--     local child = h.new_child_neovim()
--     child.start()

--     -- First, set up debug logging
--     child.lua([[
--         _G.debug_log = function(msg)
--             vim.fn.writefile({msg}, 'test_log.txt', 'a')
--         end
--     ]])

--     -- Then, set up items and config separately
--     child.lua(string.format('_G.test_items = %s', vim.inspect(items)))
--     child.lua(string.format('_G.test_config = %s', vim.inspect(config or {})))

--     -- Now set up the picker
--     child.lua([[
--         local selecta = require('selecta')
--         selecta.setup()

--         _G.run_picker = function()
--             _G.debug_log("Starting picker")
--             local result = selecta.pick(_G.test_items, _G.test_config)
--             _G.debug_log("Picker finished")
--             return result
--         end
--     ]])

--     -- Run picker
--     child.lua([[
--         _G.picker_running = true
--         vim.schedule(function()
--             _G.run_picker()
--             _G.picker_running = false
--         end)
--     ]])

--     -- Wait for picker to be ready
--     local success = vim.wait(1000, function()
--         return child.lua_get([[
--             local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
--             return #lines > 0
--         ]])
--     end, 50)

--     if not success then
--         child.stop()
--         error("Timeout waiting for picker to initialize")
--         return
--     end

--     -- Run test function
--     local ok, err = pcall(test_fn, child)

--     -- Cleanup
--     child.type_keys('<Esc>')
--     vim.wait(1000, function()
--         return not child.lua_get('_G.picker_running')
--     end, 50)
--     child.stop()

--     if not ok then
--         error(err)
--     end
-- end

-- Test using the helper
-- T["display_modes"]["icon_mode_display"] = function()
--     print("\nTesting icon mode display...")
--     with_picker(test_items, {
--         display = { mode = "icon" },
--         window = { width = 40, height = 10 }
--     }, function(child)
--         local first_line = child.lua_get([[
--             local lines = vim.api.nvim_buf_get_lines(0, 0, 1, false)
--             _G.debug_log("First line: " .. vim.inspect(lines))
--             return lines[1]
--         ]])

--         print("First line content:", vim.inspect(first_line))
--         h.expect.match(first_line, "󰈙")
--     end)
-- end

-- T["display_modes"]["text_mode_display"] = function()
--     local child = h.new_child_neovim()
--     child.start()

--     child.lua([[
--         local selecta = require('selecta')
--         _G.items = ...
--         selecta.setup()

--         _G.run_picker = function()
--             return selecta.pick(_G.items, {
--                 display = { mode = "text" },
--                 window = { width = 40, height = 10 }
--             })
--         end
--     ]], test_items)

--     child.lua([[vim.schedule(function() _G.run_picker() end)]])
--     -- vim.wait(100)

--     -- Verify kind display
--     local first_line = child.lua_get([[
--         return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
--     ]])

--     pairs(first_line)
--     h.expect.match(first_line, "File")

--     child.type_keys('<Esc>')
--     child.stop()
-- end

-- Navigation Tests
-- T["navigation"] = h.new_set()

-- T["navigation"]["moves_with_j_k"] = function()
--     local child = h.new_child_neovim()
--     child.start()

--     child.lua([[
--         local selecta = require('selecta')
--         _G.moved_to = nil
--         _G.items = ...

--         _G.run_picker = function()
--             return selecta.pick(_G.items, {
--                 on_move = function(item)
--                     _G.moved_to = item.text
--                 end
--             })
--         end
--     ]], test_items)

--     child.lua([[vim.schedule(function() _G.run_picker() end)]])
--     -- vim.wait(100)

--     -- Move down
--     child.type_keys('j')
--     -- vim.wait(100)
--     local moved_to = child.lua_get('_G.moved_to')
--     h.expect.equality(moved_to, "MyClass")

--     child.type_keys('<Esc>')
--     child.stop()
-- end


-- T["filtering"]["fuzzy_matches_anywhere"] = function()
--     local child = h.new_child_neovim()
--     child.start()

--     child.lua([[
--         local selecta = require('selecta')
--         _G.items = ...
--         selecta.setup()

--         _G.run_picker = function()
--             return selecta.pick(_G.items)
--         end
--     ]], test_items)

--     child.lua([[vim.schedule(function() _G.run_picker() end)]])
--     -- vim.wait(100)

--     -- Type 'cls' to match 'MyClass'
--     child.type_keys('cls')
--     -- vim.wait(100)

--     local filtered_count = child.lua_get([[
--         return #selecta.current.filtered_items
--     ]])
--     h.expect.equality(filtered_count, 1)

--     child.type_keys('<Esc>')
--     child.stop()
-- end

-- -- Window Tests
-- T["window"] = h.new_set()

-- T["window"]["honors_custom_border"] = function()
--     local child = h.new_child_neovim()
--     child.start()

--     child.lua([[
--         local selecta = require('selecta')
--         _G.items = ...

--         _G.run_picker = function()
--             return selecta.pick(_G.items, {
--                 window = {
--                     border = "rounded",
--                     title_prefix = "󰍉 "
--                 }
--             })
--         end
--     ]], test_items)

--     child.lua([[vim.schedule(function() _G.run_picker() end)]])
--     -- vim.wait(100)

--     -- Verify window config
--     local win_config = child.lua_get([[
--         local wins = vim.api.nvim_list_wins()
--         return vim.api.nvim_win_get_config(wins[#wins])
--     ]])

--     h.expect.equality(win_config.border[1], "╭")

--     child.type_keys('<Esc>')
--     child.stop()
-- end

-- -- Callback Tests
-- T["callbacks"] = h.new_set()

-- T["callbacks"]["triggers_on_select"] = function()
--     local child = h.new_child_neovim()
--     child.start()

--     child.lua([[
--         local selecta = require('selecta')
--         _G.items = ...
--         _G.selected_item = nil

--             return selecta.pick(_G.items, {
--                 on_select = function(item)
--                     _G.selected_item = item.text
--                 end
--             })
--     ]], test_items)

--     child.lua([[vim.schedule(function() _G.run_picker() end)]])
--     -- vim.wait(100)

--     -- Select first item
--     child.type_keys('<CR>')
--     -- vim.wait(100)

--     local selected = child.lua_get('_G.selected_item')
--     h.expect.equality(selected, "file1.lua")

--     child.stop()
-- end

-- T["callbacks"]["triggers_on_cancel"] = function()
--     local child = h.new_child_neovim()
--     child.start()

--     child.lua([[
--         local selecta = require('selecta')
--         _G.items = ...
--         _G.was_cancelled = false

--         _G.run_picker = function()
--             return selecta.pick(_G.items, {
--                 on_cancel = function()
--                     _G.was_cancelled = true
--                 end
--             })
--         end
--     ]], test_items)

--     child.lua([[vim.schedule(function() _G.run_picker() end)]])
--     -- vim.wait(100)

--     child.type_keys('<Esc>')
--     -- vim.wait(100)

--     local cancelled = child.lua_get('_G.was_cancelled')
--     h.expect.equality(cancelled, true)

--     child.stop()
-- end

T["filtering"]["fuzzy_match"] = function()
    local child = h.new_child_neovim()
    child.start()

    -- Test setup
    child.lua([[
        local selecta = require('selecta')
        _G.items = {
            { text = "file1.lua", value = "path/to/file1.lua", icon = "󰈙 " },
            { text = "setup_function", value = "function_path", icon = "󰊕 " },
            { text = "other_file.lua", value = "path/other.lua", icon = "󰈙 " },
        }
        selecta.setup()

        _G.run_picker = function()
            _G.state = selecta.pick(_G.items)
        end
    ]])

    -- Run picker in background
    child.lua([[vim.schedule(function() _G.run_picker() end)]])

    -- Test fuzzy filtering
    child.type_keys('fl') -- Should match "file1.lua" and "other_file.lua"
    local filtered_count = child.lua_get([[function() return #selecta.current.filtered_items end]])
    h.expect.equality(filtered_count, 2, "Should match two files with 'fl'")

    child.type_keys('<Esc>')
    child.stop()
end

-- T["highlighting"]["icon_mode"] = function()
--     local child = h.new_child_neovim()
--     child.start()

--     child.lua([[
--         local selecta = require('selecta')
--         _G.items = {
--             { text = "file1.lua", value = "path/to/file1.lua", icon = "󰈙 " },
--         }
--         selecta.setup({ display = { mode = "icon" }})

--         _G.run_picker = function()
--             _G.state = selecta.pick(_G.items)
--         end
--     ]])

--     child.lua([[vim.schedule(function() _G.run_picker() end)]])
--     -- vim.wait(100)

--     -- Type to trigger highlighting
--     child.type_keys('f')
--     -- vim.wait(100)

--     -- Verify highlighting
--     local marks = child.lua_get([[
--         local ns_id = vim.api.nvim_create_namespace('selecta_highlights')
--         return vim.api.nvim_buf_get_extmarks(0, ns_id, 0, -1, {details = true})
--     ]])

--     h.expect.no_equality(#marks, 0, "Should have highlighting marks")

--     child.type_keys('<Esc>')
--     child.stop()
-- end

T["selection"]["item_selection"] = function()
    local child = h.new_child_neovim()
    child.start()

    child.lua([[
        local selecta = require('selecta')
        _G.items = {
            { text = "file1.lua", value = "path/to/file1.lua", icon = "󰈙 " },
            { text = "setup_function", value = "function_path", icon = "󰊕 " },
        }
        selecta.setup()

        _G.result = nil
        _G.run_picker = function()
            _G.result = selecta.pick(_G.items)
        end
    ]])

    child.lua([[vim.schedule(function() _G.run_picker() end)]])

    -- Select first item
    child.type_keys('<CR>')

    local selected = child.lua_get('_G.result')
    h.expect.equality(selected.value, "path/to/file1.lua", "Should select first item")

    child.stop()
end

return T
