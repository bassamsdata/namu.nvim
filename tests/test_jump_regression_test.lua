local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "--noplugin", "--cmd", "set rtp^=" .. vim.fn.getcwd() })
      child.lua([[
        vim.o.lines = 40
        vim.o.columns = 120
        local StateManager = require("namu.selecta.state").StateManager
        local original_new = StateManager.new
        StateManager.new = function(...)
          _G.state = original_new(...)
          return _G.state
        end
        function _G.items_for(n)
          local items = {}
          for i = 1, n do
            items[i] = { text = "item-" .. i, value = i }
          end
          return items
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["auto labels follow the initial selection into a scrolled viewport"] = function()
  child.lua([[
    require("namu.selecta.selecta").pick(items_for(61), {
      initial_index = 45,
      window = { max_height = 5 },
      jump = { enabled = true, auto_activate = true },
      on_select = function(item) _G.chosen = item.value end,
    })
  ]])
  child.cmd("redraw")
  local view = child.lua_get("vim.fn.getwininfo(state.win)[1]")
  local marks = child.lua_get("vim.api.nvim_buf_get_extmarks(state.buf, state.jump.ns, 0, -1, {})")
  eq(view.topline > 1, true)
  eq(#marks, view.botline - view.topline + 1)
  for i, mark in ipairs(marks) do
    eq(mark[2] + 1, view.topline + i - 1)
  end
  child.type_keys("a")
  eq(child.lua_get("_G.chosen"), view.topline)
end

T["toggling off restores normal-mode navigation on every activation"] = function()
  child.lua([[
    require("namu.selecta.selecta").pick(items_for(12), {
      normal_mode = true,
      jump = { enabled = true },
    })
    _G.previous_j = vim.fn.maparg("j", "n", false, true)
    _G.previous_k = vim.fn.maparg("k", "n", false, true)
  ]])
  for _ = 1, 2 do
    child.type_keys(";", ";", "<Esc>")
    eq(child.lua_get('vim.fn.maparg("j", "n", false, true).callback == previous_j.callback'), true)
    eq(child.lua_get('vim.fn.maparg("k", "n", false, true).callback == previous_k.callback'), true)
    local row = child.lua_get("vim.api.nvim_win_get_cursor(state.win)[1]")
    child.type_keys("j")
    eq(child.lua_get("vim.api.nvim_win_get_cursor(state.win)[1]"), row + 1)
    child.type_keys("k")
    eq(child.lua_get("vim.api.nvim_win_get_cursor(state.win)[1]"), row)
    child.type_keys("i")
  end
end

T["restores expression mapping options without shadowing global mappings"] = function()
  child.lua([[
    vim.keymap.set("n", "s", function() return "l" end, { expr = true })
    require("namu.selecta.selecta").pick(items_for(3), { jump = { enabled = true } })
    vim.keymap.set("n", "a", function() return "h" end, {
      buffer = state.prompt_buf, expr = true, silent = true, nowait = true,
      remap = true, desc = "Existing expression mapping",
    })
    _G.previous_a = vim.fn.maparg("a", "n", false, true)
    _G.previous_s = vim.fn.maparg("s", "n", false, true)
  ]])
  child.type_keys(";", ";")
  eq(
    child.lua_get([[
    (function()
      local restored = vim.fn.maparg("a", "n", false, true)
      for _, key in ipairs({"callback", "expr", "silent", "nowait", "noremap", "desc", "buffer"}) do
        if restored[key] ~= previous_a[key] then return false end
      end
      return true
    end)()
  ]]),
    true
  )
  eq(child.lua_get('vim.fn.maparg("s", "n", false, true).callback == previous_s.callback'), true)
  eq(child.lua_get('vim.fn.maparg("s", "n", false, true).buffer'), 0)
end

return T
