local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "--noplugin", "--cmd", "set rtp^=" .. vim.fn.getcwd() })
      child.lua([[
        vim.o.lines, vim.o.columns = 40, 120
        vim.o.hidden = true
        vim.opt.runtimepath:prepend(vim.fn.getcwd() .. "/deps/nvim-treesitter")
        vim.cmd("filetype on")
        _G.directory = vim.fn.tempname()
        vim.fn.mkdir(directory, "p")
        _G.first = directory .. "/first.lua"
        _G.second = directory .. "/second.lua"
        _G.empty = directory .. "/empty.lua"
        vim.fn.writefile({ "local function alpha()", "  return 1", "end" }, first)
        vim.fn.writefile({ "local function beta()", "  return 2", "end" }, second)
        vim.fn.writefile({ "-- no symbols" }, empty)
        vim.cmd.edit(first)
        _G.code_win = vim.api.nvim_get_current_win()
        require("namu").setup({
          namu_symbols = { source_priority = "treesitter", auto_select = false },
          sidebar = { persist = false },
        })
        vim.cmd("runtime plugin/namu.lua")
        _G.sidebar = require("namu.sidebar")
        function _G.has_symbol(name)
          return panel and panel.items[1] and panel.items[1].text == name
            and panel.items[1].source == "treesitter"
            and require("namu.sidebar.storage").location(panel.items[1], panel.original_buf).path
              == vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win))
            and vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)[1]:find(name, 1, true) ~= nil
        end
      ]])
    end,
    post_case = function()
      child.lua([[
        sidebar.close("sidebar")
        vim.fn.delete(directory, "rf")
      ]])
    end,
    post_once = child.stop,
  },
})

for _, route in ipairs({ "sidebar", "sidebar symbols", "picker", "saved sidebar" }) do
  for _, toggles_enabled in ipairs({ true, false }) do
    local state = toggles_enabled and "preview/follow on" or "preview/follow off"
    T[route .. " with " .. state .. " displays actual symbols after edit, buffer, split, and empty file switches"] = function()
      if route == "picker" or route == "saved sidebar" then
        child.lua('vim.cmd("Namu symbols")')
        child.type_keys("<C-s>")
        if route == "saved sidebar" then
          child.type_keys("q")
          child.lua('vim.cmd.edit(second); vim.cmd("Namu sidebar")')
        end
      else
        child.lua('vim.cmd("Namu ' .. route .. '")')
      end
      child.lua("_G.panel = sidebar.get()")
      local initial_symbol = route == "saved sidebar" and "beta" or "alpha"
      eq(child.lua_get('vim.wait(1500, function() return has_symbol("' .. initial_symbol .. '") end, 10)'), true)
      if not toggles_enabled then
        child.lua("sidebar.toggle_preview(panel.name); sidebar.toggle_follow_cursor(panel.name)")
      end
      child.type_keys("<Esc>")
      if route == "saved sidebar" then
        child.lua("vim.cmd.edit(first)")
        eq(child.lua_get('vim.wait(1500, function() return has_symbol("alpha") end, 10)'), true)
      end
      child.lua("vim.cmd.edit(second)")
      eq(child.lua_get('vim.wait(1500, function() return has_symbol("beta") end, 10)'), true)
      eq(child.lua_get("vim.api.nvim_get_current_win() == code_win"), true)
      child.lua("vim.cmd.buffer(vim.fn.bufnr(first))")
      eq(child.lua_get('vim.wait(1500, function() return has_symbol("alpha") end, 10)'), true)
      child.lua([[
      vim.cmd.vsplit(second)
      _G.code_win = vim.api.nvim_get_current_win()
    ]])
      eq(child.lua_get('vim.wait(1500, function() return has_symbol("beta") end, 10)'), true)
      eq(child.lua_get("panel.original_win == code_win"), true)
      child.lua("vim.cmd.edit(empty)")
      eq(
        child.lua_get([[
      vim.wait(1500, function()
        return panel.original_buf == vim.api.nvim_get_current_buf()
          and #panel.items == 0 and #panel.filtered_items == 0
      end, 10)
    ]]),
        true
      )
    end
  end
end

return T
