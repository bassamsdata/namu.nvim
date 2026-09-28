local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "--noplugin", "--cmd", "set rtp^=" .. vim.fn.getcwd() })
      child.lua([[
        function _G.hl(name, def) vim.api.nvim_set_hl(0, name, def) end
        function _G.get(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
        function _G.refresh() vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test" }) end
        -- Reproduce the seaglass dark palette without depending on a user file.
        hl("Normal", { fg = 0xe5e9eb, bg = 0x1f292d, ctermfg = 254, ctermbg = 235 })
        hl("NormalFloat", { link = "TestFloat" })
        hl("TestFloat", { fg = 0xe5e9eb, bg = 0x283439, ctermfg = 254, ctermbg = 236 })
        hl("CursorLine", { bg = 0x283439, ctermbg = 236 })
        hl("PmenuSel", { fg = 0xe5e9eb, bg = 0x405964, ctermfg = 254, ctermbg = 240 })
        hl("Visual", { bg = 0x303f45, ctermbg = 237 })
        hl("Special", { fg = 0xe99767, ctermfg = 173 })
        hl("Error", { fg = 0xf18e98, ctermfg = 210 })
        _G.highlights = require("namu.core.highlights")
      ]])
    end,
    post_once = child.stop,
  },
})

T["equal and nearly equal backgrounds use the theme selection color"] = function()
  for _, color in ipairs({ 0x283439, 0x29353a }) do
    child.lua("hl('CursorLine', { bg = ..., ctermbg = 236 }); highlights.setup()", { color })
    eq(child.lua_get("get('NamuCurrentItem').bg"), 0x405964)
    eq(child.lua_get("get('NamuCurrentItem').ctermbg"), 240)
    eq(child.lua_get("get('NamuCurrentItem').fg == nil"), true)
    eq(child.lua_get("get('NamuCurrentItemIcon').bg"), 0x405964)
  end
end

T["a visible cursorline keeps its link and styling"] = function()
  child.lua([[
    hl("CursorLine", { bg = 0x405964, ctermbg = 240, bold = true })
    highlights.setup()
  ]])
  eq(child.lua_get("vim.api.nvim_get_hl(0, { name = 'NamuCurrentItem' }).link"), "CursorLine")
  eq(child.lua_get("get('NamuCurrentItem').bold"), true)
end

T["an unreadable menu color falls back to Visual without its foreground"] = function()
  child.lua([[
    hl("PmenuSel", { bg = 0xe5e9eb, ctermbg = 236 })
    hl("Visual", { bg = 0x405964, ctermbg = 240 })
    highlights.setup()
  ]])
  eq(child.lua_get("get('NamuCurrentItem').bg"), 0x405964)
  eq(child.lua_get("get('NamuCurrentItem').fg == nil"), true)
end

T["dark and light themes with no usable selection color get a subtle background"] = function()
  for _, light in ipairs({ false, true }) do
    child.lua(
      [[
      local light = ...
      vim.o.background = light and "light" or "dark"
      hl("Normal", { bg = light and 0xf0f0f0 or 0x202020, fg = light and 0x202020 or 0xf0f0f0 })
      hl("NormalFloat", {})
      hl("CursorLine", { link = "Normal" })
      hl("PmenuSel", {})
      hl("Visual", {})
      highlights.setup()
    ]],
      { light }
    )
    local bg = child.lua_get("get('NamuCurrentItem').bg")
    if light then
      eq(bg < 0xf0f0f0 and bg > 0x808080, true)
    else
      eq(bg > 0x202020 and bg < 0x808080, true)
    end
    eq(child.lua_get("get('NamuCurrentItem').ctermbg"), light and 252 or 238)
    eq(child.lua_get("get('NamuCurrentItem').underline == nil"), true)
  end
end

T["transparent seaglass uses the menu selection background without an underline"] = function()
  for _, light in ipairs({ false, true }) do
    child.lua(
      [[
      local light = ...
      vim.o.background = light and "light" or "dark"
      hl("Normal", { fg = light and 0x1c272c or 0xe5e9eb })
      hl("NormalFloat", { link = "Normal" })
      hl("CursorLine", { bg = light and 0xe0ebf0 or 0x283439, ctermbg = light and 255 or 236 })
      hl("PmenuSel", { bg = light and 0xbbd3dd or 0x405964, ctermbg = light and 152 or 240 })
      highlights.setup()
    ]],
      { light }
    )
    eq(child.lua_get("get('NamuCurrentItem').bg"), light and 0xbbd3dd or 0x405964)
    eq(child.lua_get("get('NamuCurrentItem').ctermbg"), light and 152 or 240)
    eq(child.lua_get("get('NamuCurrentItem').underline == nil"), true)
    eq(child.lua_get("get('NamuCurrentItem').cterm == nil"), true)
    eq(child.lua_get("get('NamuCurrentItemIcon').bg == get('NamuCurrentItem').bg"), true)
    eq(child.lua_get("get('NormalFloat').bg == nil"), true)
  end
end

T["transparent themes without selection colors get a background without an underline"] = function()
  child.lua([[
    vim.o.background = "dark"
    hl("Normal", { fg = 0xffffff })
    hl("NormalFloat", {})
    hl("CursorLine", {})
    hl("PmenuSel", {})
    hl("Visual", {})
    highlights.setup()
  ]])
  local bg = child.lua_get("get('NamuCurrentItem').bg")
  eq(bg > 0x202020 and bg < 0x808080, true)
  eq(child.lua_get("get('NamuCurrentItem').underline == nil"), true)
  eq(child.lua_get("get('NamuCurrentItem').ctermbg"), 238)
  eq(child.lua_get("get('NormalFloat').bg == nil"), true)
end

T["ColorScheme rebuilds row and icon colors with and without highlight clear"] = function()
  for _, clear in ipairs({ false, true }) do
    child.lua(
      [[
      highlights.setup()
      if ... then vim.cmd("highlight clear") end
      hl("Normal", { fg = 0x1c272c, bg = 0xedf4f7, ctermfg = 235, ctermbg = 255 })
      hl("NormalFloat", { fg = 0x1c272c, bg = 0xe0ebf0, ctermfg = 235, ctermbg = 255 })
      hl("CursorLine", { bg = 0xe0ebf0, ctermbg = 255 })
      hl("PmenuSel", { bg = 0xbbd3dd, ctermbg = 152 })
      hl("Special", { fg = 0x954618, ctermfg = 94 })
      hl("Error", { fg = 0xb61b2b, ctermfg = 124 })
      refresh()
    ]],
      { clear }
    )
    eq(child.lua_get("get('NamuCurrentItem').bg"), 0xbbd3dd)
    for _, group in ipairs({ "NamuCurrentItemIcon", "NamuCurrentItemIconSelection" }) do
      eq(child.lua_get("get(...).bg", { group }), 0xbbd3dd)
      eq(child.lua_get("get(...).ctermbg", { group }), 152)
    end
    eq(child.lua_get("get('NamuCurrentItemIcon').fg"), 0x954618)
    eq(child.lua_get("get('NamuCurrentItemIconSelection').fg"), 0xb61b2b)
  end
end

T["custom row and icon definitions survive setup and refresh"] = function()
  child.lua([[
    hl("NamuCurrentItem", { bg = 0x123456 })
    hl("NamuCurrentItemIcon", { fg = 0xabcdef, bg = 0x654321 })
    highlights.setup()
    refresh()
    highlights.setup()
  ]])
  eq(child.lua_get("get('NamuCurrentItem').bg"), 0x123456)
  eq(child.lua_get("get('NamuCurrentItemIcon').fg"), 0xabcdef)
  eq(child.lua_get("get('NamuCurrentItemIcon').bg"), 0x654321)
  child.lua([[
    hl("NamuCurrentItem", { link = "Visual" })
    hl("NamuCurrentItemIconSelection", { fg = 0xaabbcc })
    refresh()
  ]])
  eq(child.lua_get("vim.api.nvim_get_hl(0, { name = 'NamuCurrentItem' }).link"), "Visual")
  eq(child.lua_get("get('NamuCurrentItemIconSelection').fg"), 0xaabbcc)
end

T["set_highlights does not mutate caller definitions"] = function()
  child.lua([[
    _G.def = { fg = 0x123456 }
    highlights.set_highlights({ TestHighlight = def })
  ]])
  eq(child.lua_get("def.default == nil"), true)
end

return T
