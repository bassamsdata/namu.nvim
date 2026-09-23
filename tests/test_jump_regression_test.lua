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
