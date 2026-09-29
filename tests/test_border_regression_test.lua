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
        function _G.open_picker(border, show_footer)
          local opts = require("namu.core.config_manager").get_config("workspace")
          opts.title = "Border test"
          opts.window.border = border or opts.window.border
          opts.window.show_footer = show_footer
          require("namu.selecta.selecta").pick({
            { text = "alpha" }, { text = "beta" }, { text = "gamma" },
          }, opts)
        end
      ]])
    end,
    post_once = child.stop,
  },
})

local function check_picker()
  eq(child.lua_get("vim.api.nvim_win_is_valid(state.win)"), true)
  eq(child.lua_get("vim.api.nvim_win_is_valid(state.prompt_win)"), true)
  child.type_keys("beta")
  eq(child.lua_get("#state.filtered_items"), 1)
  eq(child.lua_get("state.filtered_items[1].text"), "beta")
  eq(
    child.lua_get("vim.api.nvim_win_get_width(state.win)"),
    child.lua_get("vim.api.nvim_win_get_width(state.prompt_win)")
  )
  eq(child.lua_get("vim.v.errmsg"), "")
end

T["inherits bold winborder for every Namu module"] = function()
  local supported = child.lua_get('pcall(function() vim.o.winborder = "bold" end)')
  if not supported then
    MiniTest.skip("This Neovim version does not support bold winborder")
  end
  for _, module in ipairs({
    "namu_symbols",
    "workspace",
    "diagnostics",
    "watchtower",
    "namu_ctags",
    "callhierarchy",
    "ui_select",
  }) do
    eq(child.lua_get('require("namu.core.config_manager").get_config(...).window.border', { module }), "bold")
  end
  child.lua("open_picker(nil, true)")
  check_picker()
  eq(
    child.lua_get("vim.api.nvim_win_get_config(state.prompt_win).border"),
    { "┏", "━", "┓", "┃", "", "", "", "┃" }
  )
  eq(child.lua_get("vim.api.nvim_win_get_config(state.win).footer[1][1]"), " 1/3 ")
end

for _, border in ipairs({ "none", "single", "double", "rounded", "solid", "shadow", "bold" }) do
  T["opens and resizes the " .. border .. " border"] = function()
    for _, show_footer in ipairs({ true, false }) do
      child.lua("open_picker(...)", { border, show_footer })
      check_picker()
      child.lua('require("namu.selecta.selecta").close_picker(state)')
    end
  end
end

T["preserves custom border characters and highlights"] = function()
  local borders = {
    { "+", "-", "+", "|", "+", "-", "+", "|" },
    {
      { "+", "WarningMsg" },
      { "-", "ErrorMsg" },
      { "+", "WarningMsg" },
      { "|", "ErrorMsg" },
      { "+", "WarningMsg" },
      { "-", "ErrorMsg" },
      { "+", "WarningMsg" },
      { "|", "ErrorMsg" },
    },
  }
  for _, border in ipairs(borders) do
    child.lua("_G.border = ...; open_picker(border, true)", { border })
    check_picker()
    eq(child.lua_get("border"), border)
    local prompt_border = child.lua_get("vim.api.nvim_win_get_config(state.prompt_win).border")
    for _, index in ipairs({ 1, 2, 3, 4, 8 }) do
      eq(prompt_border[index], border[index])
    end
    child.lua('require("namu.selecta.selecta").close_picker(state)')
  end
end

return T
