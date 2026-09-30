local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "--noplugin", "--cmd", "set rtp^=" .. vim.fn.getcwd() })
      child.lua([[
        vim.o.lines = 40
        vim.o.columns = 120
        _G.selecta = require("namu.selecta.selecta")
        local manager = require("namu.selecta.state").StateManager
        local new = manager.new
        manager.new = function(...)
          _G.state = new(...)
          return state
        end
        _G.items = {}
        for i = 1, 60 do items[i] = { id = tostring(i), text = "item-" .. i, value = i } end
        function _G.open(opts) selecta.pick(items, opts or {}) end
      ]])
    end,
    post_once = child.stop,
  },
})

T["resume without a previous picker is a harmless no-op"] = function()
  eq(child.lua_get('require("namu").resume()'), false)
end

T["command restores query, options, selection and insert mode"] = function()
  child.lua([[
    vim.cmd("runtime plugin/namu.lua")
    open({ title = "Saved picker", multiselect = { enabled = true, selected_icon = "*", unselected_icon = " ",
        on_select = function(selected) _G.chosen = selected[1].value end },
      on_select = function(item) _G.chosen = item.value end })
  ]])
  child.type_keys("item-2")
  child.lua([[
    state:handle_movement(1, state.original_opts)
    state:toggle_selection(state.filtered_items[2], state.original_opts)
    _G.row = vim.api.nvim_win_get_cursor(state.win)[1]
    _G.old_prompt = state.prompt_buf
  ]])
  child.type_keys("<Esc>")
  child.cmd("Namu resume")
  eq(child.lua_get("state:get_query_string()"), "item-2")
  eq(child.lua_get("state.original_opts.title"), "Saved picker")
  eq(child.lua_get("state.selected_count"), 1)
  eq(child.lua_get("vim.api.nvim_win_get_cursor(state.win)[1] == row"), true)
  eq(child.lua_get("state.prompt_buf ~= old_prompt"), true)
  eq(child.fn.mode(), "i")
  child.type_keys("<CR>")
  eq(child.lua_get("_G.chosen ~= nil"), true)
end

T["normal mode is restored after cancellation"] = function()
  child.lua("open({ normal_mode = true, jump = { enabled = false } })")
  child.type_keys("item-", "<Esc>", "j", "<Esc>")
  eq(child.lua_get("state.active"), false)
  child.lua("selecta.resume()")
  eq(child.fn.mode(), "n")
  eq(child.lua_get("state:get_query_string()"), "item-")
  local row = child.lua_get("vim.api.nvim_win_get_cursor(state.win)[1]")
  child.type_keys("j")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(state.win)[1]"), row + 1)
end

T["jump labels and scrolled viewport are restored with working callbacks"] = function()
  child.lua([[
    open({ initial_index = 45, window = { max_height = 5 },
      on_select = function(item) _G.chosen = item.value end })
  ]])
  child.type_keys(";", "<Esc>")
  child.lua("selecta.resume()")
  eq(child.lua_get('require("namu.selecta.jump").is_active(state)'), true)
  eq(child.fn.mode(), "n")
  local view = child.lua_get("vim.fn.getwininfo(state.win)[1]")
  eq(view.topline > 1, true)
  local marks = child.lua_get("vim.api.nvim_buf_get_extmarks(state.buf, state.jump.ns, 0, -1, {})")
  eq(marks[1][2] + 1, view.topline)
  child.type_keys("a")
  eq(child.lua_get("_G.chosen"), view.topline)
end

T["toggled-off auto labels stay off when resumed"] = function()
  child.lua("open({ jump = { enabled = true, auto_activate = true } })")
  child.type_keys(";", "<Esc>")
  child.lua("selecta.resume()")
  eq(child.lua_get('require("namu.selecta.jump").is_active(state)'), false)
  eq(child.fn.mode(), "i")
end

T["most recently closed picker replaces the saved snapshot"] = function()
  child.lua('open({ title = "First" })')
  child.type_keys("first", "<Esc>")
  child.lua('open({ title = "Second" })')
  child.type_keys("item-3", "<Esc>")
  child.lua("selecta.resume()")
  eq(child.lua_get("state.original_opts.title"), "Second")
  eq(child.lua_get("state:get_query_string()"), "item-3")
  child.type_keys("<BS>", "<Esc>")
  child.lua("selecta.resume()")
  eq(child.lua_get("state:get_query_string()"), "item-")
end

T["cached async results resume immediately and editing starts a fresh request"] = function()
  child.lua([[
    _G.deliveries = {}
    open({ async_source = function(query)
      _G.last_query = query
      return function(cb) table.insert(deliveries, cb) end
    end })
    deliveries[1](items)
  ]])
  child.type_keys("item-2")
  child.lua("deliveries[#deliveries](items)")
  child.type_keys(";", "<Esc>")
  child.lua("selecta.resume()")
  eq(child.lua_get("#deliveries"), 2)
  eq(child.lua_get('require("namu.selecta.jump").is_active(state)'), true)
  child.type_keys(";", "<End>", "x")
  eq(child.lua_get("last_query"), "item-2x")
  child.lua("deliveries[1]({ { text = 'stale' } })")
  eq(child.lua_get("state.items[1].text"), "item-1")
end

T["closed source buffers are handled without opening a picker"] = function()
  child.lua('vim.api.nvim_buf_set_name(0, "resume-source"); open(); _G.source = state.original_buf')
  child.type_keys("<Esc>")
  child.lua("vim.api.nvim_buf_delete(source, { force = true })")
  eq(child.lua_get("selecta.resume()"), false)
end

T["resume while a picker is open focuses it without duplicating windows"] = function()
  child.lua("open(); _G.prompt = state.prompt_buf; _G.windows = #vim.api.nvim_list_wins()")
  child.lua("selecta.resume()")
  eq(child.lua_get("state.prompt_buf == prompt"), true)
  eq(child.lua_get("#vim.api.nvim_list_wins() == windows"), true)
end

T["closing during a request restarts it and ignores its old callback"] = function()
  child.lua([[
    _G.deliveries = {}
    open({ async_source = function()
      return function(cb) table.insert(deliveries, cb) end
    end })
  ]])
  child.type_keys("<Esc>")
  child.lua("selecta.resume()")
  eq(child.lua_get("#deliveries"), 2)
  child.lua("deliveries[1]({ { text = 'stale' } }); deliveries[2](items)")
  eq(child.lua_get("state.items[1].text"), "item-1")
  eq(child.lua_get("state.is_loading"), false)
end

T["saving happens before cancellation callbacks change mode or query"] = function()
  child.lua([[
    open({ on_cancel = function()
      vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { "changed" })
      vim.cmd("stopinsert")
    end })
  ]])
  child.type_keys("item-4", "<Esc>")
  child.lua("selecta.resume()")
  eq(child.lua_get("state:get_query_string()"), "item-4")
  eq(child.fn.mode(), "i")
end

T["empty results and auto-select options resume without selecting immediately"] = function()
  child.lua("open({ auto_select = true, on_select = function() _G.chosen = true end })")
  child.type_keys("zzzz", "<Esc>")
  child.lua("selecta.resume()")
  eq(child.lua_get("#state.filtered_items"), 0)
  eq(child.lua_get("_G.chosen == nil"), true)
end

T["selection preserves original item identity across repeated resumes"] = function()
  child.lua([[
    open({ on_select = function(item) _G.same_item = item == items[1] end })
  ]])
  child.type_keys("<CR>")
  eq(child.lua_get("_G.same_item"), true)
  child.lua("selecta.resume()")
  child.type_keys("<CR>")
  eq(child.lua_get("_G.same_item"), true)
end

return T
