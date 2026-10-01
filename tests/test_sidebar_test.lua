local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "--noplugin", "--cmd", "set rtp^=" .. vim.fn.getcwd() })
      child.lua([[
        vim.o.lines = 40
        vim.o.columns = 120
        _G.path = vim.fn.tempname() .. ".lua"
        vim.fn.writefile({ "one", "two", "three", "four", "five" }, path)
        vim.cmd.edit(path)
        _G.path = vim.api.nvim_buf_get_name(0)
        _G.source_win = vim.api.nvim_get_current_win()
        _G.source_buf = vim.api.nvim_get_current_buf()
        _G.store_path = vim.fn.tempname() .. ".json"
        _G.sidebar = require("namu.sidebar")
        sidebar.setup({ persist = false, storage_path = store_path })
        _G.items = {
          { text = "Parent", depth = 0, bufnr = source_buf, value = { lnum = 1, col = 1 } },
          { text = "Child", depth = 1, bufnr = source_buf, value = { lnum = 2, col = 1 } },
          { text = "Other", depth = 0, bufnr = source_buf, value = { lnum = 4, col = 2 } },
        }
        function _G.open(opts) _G.panel = sidebar.open(items, opts) end
      ]])
    end,
    post_case = function()
      child.lua([[
        for _, name in ipairs({ "sidebar", "outline", "favorites" }) do sidebar.close(name) end
        vim.fn.delete(path)
        vim.fn.delete(store_path)
      ]])
    end,
    post_once = child.stop,
  },
})

T["persistent split has search above it and remains open when code is focused"] = function()
  child.lua("open()")
  eq(child.lua_get("vim.api.nvim_win_get_config(panel.win).relative"), "")
  eq(
    child.lua_get("vim.api.nvim_win_get_position(panel.prompt_win)[1] < vim.api.nvim_win_get_position(panel.win)[1]"),
    true
  )
  child.type_keys("<Esc>")
  eq(child.lua_get("vim.api.nvim_get_current_win() == source_win"), true)
  eq(child.lua_get("panel.active"), true)
end

T["search filters live and Enter returns to normal navigation"] = function()
  child.lua("open()")
  child.type_keys("/", "Child")
  eq(child.lua_get("#panel.filtered_items"), 1)
  eq(child.lua_get("panel.filtered_items[1].text"), "Child")
  child.type_keys("<CR>")
  eq(child.fn.mode(), "n")
  eq(child.lua_get("vim.api.nvim_get_current_win() == panel.win"), true)
  child.type_keys("<CR>")
  eq(child.lua_get("vim.api.nvim_get_current_win() == source_win"), true)
  eq(child.lua_get("vim.api.nvim_win_get_cursor(source_win)"), { 2, 0 })
  eq(child.lua_get("panel.active"), true)
end

T["j k navigate and h l collapse expand groups"] = function()
  child.lua("open()")
  child.type_keys("h")
  eq(child.lua_get("#panel.filtered_items"), 2)
  child.type_keys("l")
  eq(child.lua_get("#panel.filtered_items"), 3)
  child.type_keys("j")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 2)
  child.type_keys("k")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 1)
end

T["closing and reopening restores query and selected row"] = function()
  child.lua("open()")
  child.type_keys("j", "q")
  child.lua("open()")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 2)
  child.type_keys("/", "Other", "<Esc>", "q")
  child.lua("open()")
  eq(child.lua_get("panel.query"), "Other")
  eq(child.lua_get("#panel.filtered_items"), 1)
end

T["closing either window cleans up both windows and all autocmds"] = function()
  child.lua("open(); _G.group = panel.group; vim.api.nvim_win_close(panel.prompt_win, true)")
  eq(child.lua_get("panel.active"), false)
  eq(child.lua_get("vim.api.nvim_win_is_valid(panel.win)"), false)
  eq(child.lua_get("pcall(vim.api.nvim_get_autocmds, { group = group })"), false)
  child.lua("open(); vim.api.nvim_win_close(panel.win, true)")
  eq(child.lua_get("vim.api.nvim_win_is_valid(panel.prompt_win)"), false)
end

T["favorites can be added and removed without closing their sidebar"] = function()
  child.lua("open()")
  child.type_keys("m", "m")
  eq(child.lua_get('require("namu.bookmarks").count()'), 1)
  child.type_keys("q")
  child.lua('require("namu.bookmarks").show(); _G.fav = sidebar.get("favorites")')
  eq(child.lua_get("#fav.filtered_items"), 1)
  child.type_keys("dd")
  eq(child.lua_get('require("namu.bookmarks").count()'), 0)
  eq(child.lua_get("fav.active"), true)
  eq(child.lua_get("#fav.filtered_items"), 0)
end

T["picker can send selected items into sidebar and resume still works"] = function()
  child.lua([[
    local manager = require("namu.selecta.state").StateManager
    local new = manager.new
    manager.new = function(...) _G.picker = new(...); return picker end
    require("namu.selecta.selecta").pick(items, {
      multiselect = { enabled = true, selected_icon = "*", unselected_icon = " " },
    })
  ]])
  child.type_keys("<Tab>", "<C-b>")
  eq(child.lua_get('require("namu.bookmarks").count()'), 1)
  child.type_keys("<C-s>")
  eq(child.lua_get("picker.active"), false)
  eq(child.lua_get("sidebar.get().items[1].text"), "Parent")
  eq(child.lua_get("sidebar.get().active"), true)
  child.type_keys("q")
  child.lua('require("namu").resume()')
  eq(child.lua_get("picker.active"), true)
  eq(child.lua_get("picker.selected_count"), 1)
  child.type_keys("<Esc>")
end

T["persistence saves portable locations and reloads favorites and search"] = function()
  child.lua([[
    sidebar.setup({ persist = true, storage_path = store_path })
    require("namu.bookmarks").add(items[2])
    open()
  ]])
  child.type_keys("/", "Other", "<Esc>", "q")
  child.lua([[
    _G.saved = vim.json.decode(table.concat(vim.fn.readfile(store_path)))
    sidebar.setup({ persist = true, storage_path = store_path })
    open()
  ]])
  eq(child.lua_get("panel.query"), "Other")
  eq(child.lua_get('require("namu.bookmarks").get_all()[1].location.path == path'), true)
  eq(child.lua_get("saved.favorites[1].bufnr == nil"), true)
  eq(child.lua_get("saved.favorites[1].location.line"), 2)
end

T["persistence can be disabled without reading or modifying existing storage"] = function()
  child.lua([[
    vim.fn.writefile({ "existing content" }, store_path)
    require("namu.bookmarks").add(items[1])
    open()
  ]])
  child.type_keys("q")
  eq(child.lua_get("vim.fn.readfile(store_path)"), { "existing content" })
  eq(child.lua_get('require("namu.bookmarks").count()'), 1)
end

T["corrupt storage is preserved and does not crash"] = function()
  child.lua([[
    vim.fn.writefile({ "{invalid json" }, store_path)
    sidebar.setup({ persist = true, storage_path = store_path })
    require("namu.bookmarks").add(items[1])
  ]])
  eq(child.lua_get("vim.fn.readfile(store_path)"), { "{invalid json" })
end

T["workspace and diagnostic coordinates are normalized correctly"] = function()
  eq(
    child.lua_get([[
    require("namu.sidebar.storage").record({ text = "Diagnostic", bufnr = source_buf,
      value = { lnum = 0, col = 2, diagnostic = {} } }).location
  ]]),
    { path = child.lua_get("path"), line = 1, col = 2 }
  )
  eq(
    child.lua_get([[
    require("namu.sidebar.storage").record({ text = "Workspace", value = {
      file_path = path, lnum = 2, col = 1, symbol = { location = {
        uri = vim.uri_from_fname(path), range = { start = { line = 2, character = 1 } },
      } },
    } }).location
  ]]),
    { path = child.lua_get("path"), line = 3, col = 1 }
  )
end

T["outline ignores stale results and refreshes without stealing code focus"] = function()
  child.lua([[
    _G.deliveries = {}
    require("namu.namu_symbols").fetch_symbols = function(buf, cb)
      table.insert(deliveries, cb)
    end
    _G.outline = require("namu.namu_outline")
    outline.open()
    _G.panel = sidebar.get("outline")
    outline.refresh()
    deliveries[#deliveries](items)
    deliveries[1]({ items[1] })
    sidebar.focus_code("outline")
  ]])
  eq(child.lua_get("#panel.items"), 3)
  eq(child.lua_get("vim.api.nvim_get_current_win() == source_win"), true)
  child.lua("outline.close(); deliveries[#deliveries](items)")
  eq(child.lua_get('sidebar.get("outline") == nil'), true)
end

T["bookmark and outline commands are available"] = function()
  child.lua('vim.cmd("runtime plugin/namu.lua"); vim.cmd("Namu bookmarks")')
  eq(child.lua_get('sidebar.get("favorites").active'), true)
  child.type_keys("q")
end

T["favorites survive a fresh Neovim process and jump without old buffer IDs"] = function()
  child.lua([[
    local prefix = vim.uv.os_tmpdir() .. "/namu-sidebar-" .. vim.uv.hrtime()
    _G.store_path = prefix .. ".json"
    _G.path = prefix .. ".lua"
    vim.fn.writefile(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), path)
    vim.api.nvim_buf_set_name(source_buf, path)
    _G.path = vim.api.nvim_buf_get_name(source_buf)
    sidebar.setup({ persist = true, storage_path = store_path })
    require("namu.bookmarks").add(items[3])
    require("namu.bookmarks").show()
  ]])
  child.type_keys("q")
  local path, store_path = child.lua_get("path"), child.lua_get("store_path")
  child.restart({ "--noplugin", "--cmd", "set rtp^=" .. vim.fn.getcwd() })
  child.lua(string.format(
    [[
    vim.o.lines = 40
    vim.o.columns = 120
    _G.path = %q
    _G.store_path = %q
    _G.sidebar = require("namu.sidebar")
    sidebar.setup({ persist = true, storage_path = store_path })
    _G.code_win = vim.api.nvim_get_current_win()
    require("namu.bookmarks").show()
  ]],
    path,
    store_path
  ))
  eq(child.lua_get('require("namu.bookmarks").count()'), 1)
  child.type_keys("<CR>")
  eq(child.lua_get("vim.api.nvim_get_current_win() == code_win"), true)
  eq(child.lua_get("vim.api.nvim_buf_get_name(0)"), path)
  eq(child.lua_get("vim.api.nvim_win_get_cursor(code_win)"), { 4, 1 })
end

T["outline follows source buffer switches and clears old items on empty results"] = function()
  child.lua([[
    _G.requests = {}
    require("namu.namu_symbols").fetch_symbols = function(buf, callback)
      table.insert(requests, { buf = buf, callback = callback })
    end
    require("namu.namu_outline").open()
    _G.panel = sidebar.get("outline")
    requests[#requests].callback(items)
  ]])
  eq(child.lua_get("#requests"), 1)
  eq(child.lua_get("requests[1].buf == source_buf"), true)
  child.type_keys("<Esc>")
  child.lua([[
    _G.other_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(other_buf)
  ]])
  eq(child.lua_get("#requests"), 2)
  eq(child.lua_get("requests[2].buf == other_buf"), true)
  child.lua("requests[2].callback({})")
  eq(child.lua_get("panel.original_buf == other_buf"), true)
  eq(child.lua_get("#panel.items"), 0)
  eq(child.lua_get("#panel.filtered_items"), 0)
  child.lua("requests[1].callback(items)")
  eq(child.lua_get("#panel.items"), 0)
end

T["outline conversion reads its source even while a sidebar or another picker is active"] = function()
  child.lua([[
    local config = require("namu.namu_symbols.config").values
    require("namu.namu_symbols.lsp").request_symbols = function(_, _, callback)
      _G.symbol_callback = callback
    end
    _G.impl = require("namu.namu_symbols.symbols")
    impl.fetch_symbols(config, source_buf, function(result) _G.fetched = result end)
    open()
    symbol_callback(nil, { {
      name = "SomeFunction", kind = 12,
      range = { start = { line = 1, character = 0 }, ["end"] = { line = 2, character = 1 } },
    } })
  ]])
  eq(child.lua_get("fetched[1].text"), "SomeFunction")
  eq(child.lua_get("fetched[1].bufnr == source_buf"), true)
  eq(child.lua_get("vim.api.nvim_get_current_win() == panel.win"), true)
end

T["search keeps matching children visible inside collapsed groups"] = function()
  child.lua("open()")
  child.type_keys("h", "/", "Child", "<Esc>")
  eq(child.lua_get("#panel.filtered_items"), 1)
  eq(child.lua_get("panel.filtered_items[1].text"), "Child")
end

T["opening favorites from the outline still jumps into the code window"] = function()
  child.lua([[
    require("namu.namu_symbols").fetch_symbols = function(_, cb) cb(items) end
    require("namu.namu_outline").open()
    require("namu.bookmarks").add(items[2])
    require("namu.bookmarks").show()
    _G.favorites = sidebar.get("favorites")
  ]])
  eq(child.lua_get("favorites.original_win == source_win"), true)
  child.type_keys("<CR>")
  eq(child.lua_get("vim.api.nvim_get_current_win() == source_win"), true)
  eq(child.lua_get('sidebar.get("outline").active'), true)
  eq(child.lua_get("favorites.active"), true)
end

T["sending another list replaces stale filters and formatter in the existing sidebar"] = function()
  child.lua("open()")
  child.type_keys("/", "Child", "<Esc>")
  child.lua([[
    sidebar.open({ items[3] }, {
      replace = true, title = "New list",
      formatter = function(item) return "new: " .. item.text end,
    }, { original_win = source_win, original_buf = source_buf })
  ]])
  eq(child.lua_get("panel.query"), "")
  eq(child.lua_get("panel.title"), "New list")
  eq(child.lua_get("#panel.filtered_items"), 1)
  eq(child.lua_get("vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)[1]:find('new: Other', 1, true) ~= nil"), true)
end

T["sidebar renders picker guides and highlights without extra indentation"] = function()
  child.lua([[
    open({ display = { mode = "icon", format = "tree_guides" } })
    _G.lines = vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
  ]])
  eq(child.lua_get("lines[2]:find('└─', 1, true) ~= nil"), true)
  eq(
    child.lua_get(
      ' #vim.api.nvim_buf_get_extmarks(panel.buf, vim.api.nvim_create_namespace("namu_formatted_highlights"), 0, -1, {}) > 0'
    ),
    true
  )
end

T["moving previews in code and Escape restores the original code cursor"] = function()
  child.lua("open()")
  child.type_keys("j")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(source_win)[1]"), 2)
  eq(child.lua_get("vim.api.nvim_get_current_win() == panel.win"), true)
  eq(child.lua_get("#vim.api.nvim_buf_get_extmarks(source_buf, panel.preview_ns, 0, -1, {}) > 0"), true)
  child.type_keys("<Esc>")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(source_win)[1]"), 1)
  eq(child.lua_get("#vim.api.nvim_buf_get_extmarks(source_buf, panel.preview_ns, 0, -1, {})"), 0)
end

T["jump labels select without closing the sidebar and restore navigation"] = function()
  child.lua("open()")
  child.type_keys(";")
  eq(child.lua_get('require("namu.selecta.jump").is_active(panel)'), true)
  eq(child.lua_get("#vim.api.nvim_buf_get_extmarks(panel.buf, panel.jump.ns, 0, -1, {})"), 3)
  child.type_keys("s")
  eq(child.lua_get("panel.active"), true)
  eq(child.lua_get("vim.api.nvim_win_get_cursor(source_win)[1]"), 2)
  child.lua("vim.api.nvim_set_current_win(panel.win)")
  child.type_keys("j")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 3)
end

T["picker transfer preserves focused item and rendering hook"] = function()
  child.lua([[
    local manager = require("namu.selecta.state").StateManager
    local new = manager.new
    manager.new = function(...) _G.picker = new(...); return picker end
    require("namu.selecta.selecta").pick(items, {
      initial_index = 3,
      formatter = function(item) return "picker: " .. item.text end,
      hooks = { on_render = function() _G.render_count = (_G.render_count or 0) + 1 end },
    })
  ]])
  child.type_keys("<C-s>")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(sidebar.get().win)[1]"), 3)
  eq(child.lua_get("render_count > 1"), true)
  eq(child.lua_get("vim.api.nvim_buf_get_lines(sidebar.get().buf, 2, 3, false)[1]"), "picker: Other")
  child.lua("_G.panel = sidebar.get()")
end

T["outline initially focuses the symbol at the code cursor"] = function()
  child.lua([[
    vim.api.nvim_win_set_cursor(source_win, { 4, 0 })
    require("namu.namu_symbols").fetch_symbols = function(_, cb) cb(items) end
    require("namu.namu_outline").open()
    _G.panel = sidebar.get("outline")
  ]])
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 3)
end

T["preview and jump labels can be disabled independently"] = function()
  child.lua("open({ preview = { highlight_on_move = false }, jump = { enabled = false } })")
  child.type_keys("j")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(source_win)[1]"), 1)
  eq(child.lua_get('require("namu.selecta.jump").is_active(panel)'), false)
end

T["auto labels activate when outline results arrive and toggling restores j k"] = function()
  child.lua([[
    require("namu.namu_symbols").fetch_symbols = function(_, cb) _G.deliver = cb end
    require("namu.namu_outline").open({ jump = { enabled = true, auto_activate = true } })
    _G.panel = sidebar.get("outline")
    deliver(items)
  ]])
  eq(child.lua_get('require("namu.selecta.jump").is_active(panel)'), true)
  child.type_keys(";", "j")
  eq(child.lua_get('require("namu.selecta.jump").is_active(panel)'), false)
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 2)
end

T["symbol filters work for direct sidebars and saved bookmarks"] = function()
  child.lua([[
    items[1].kind, items[1].source = "Module", "lsp"
    items[2].kind, items[2].source = "Function", "lsp"
    items[3].kind, items[3].source = "Class", "treesitter"
    open()
  ]])
  for _, example in ipairs({ { "/fn", "Child" }, { "/mo", "Parent" }, { "/cl", "Other" }, { "/fnChild", "Child" } }) do
    child.lua("sidebar.search()")
    child.type_keys("<C-u>", example[1])
    eq(child.lua_get("#panel.filtered_items"), 1)
    eq(child.lua_get("panel.filtered_items[1].text"), example[2])
    eq(child.lua_get("panel.filter_metadata.is_symbol_filter"), true)
  end
  child.lua([[
    vim.cmd("stopinsert")
    sidebar.close()
    for _, item in ipairs(items) do require("namu.bookmarks").add(item, source_buf) end
    sidebar.open_favorites()
    _G.panel = sidebar.get("favorites")
  ]])
  child.type_keys("/", "/fn")
  eq(child.lua_get("panel.query"), "/fn")
  eq(child.lua_get("#panel.filtered_items"), 1)
  eq(child.lua_get("panel.filtered_items[1].kind"), "Function")
  eq(child.lua_get("panel.filtered_items[1].source"), "lsp")
end

T["prompt shares the icon and shows the selected source while searching"] = function()
  child.lua([[
    items[1].source = "treesitter"
    items[2].source = "lsp"
    open()
  ]])
  eq(
    child.lua_get(
      "#vim.api.nvim_buf_get_extmarks(panel.prompt_buf, require('namu.selecta.common').prompt_icon_ns, 0, -1, {})"
    ),
    1
  )
  child.type_keys("j")
  eq(
    child.lua_get(
      "vim.api.nvim_buf_get_extmarks(panel.prompt_buf, require('namu.selecta.common').prompt_info_ns, 0, -1, { details = true })[1][4].virt_text[1][1]:find('LSP') ~= nil"
    ),
    true
  )
  child.type_keys("/", "Child")
  eq(
    child.lua_get(
      "#vim.api.nvim_buf_get_extmarks(panel.prompt_buf, require('namu.selecta.common').prompt_info_ns, 0, -1, {})"
    ),
    1
  )
end

T["search movement keeps input focus and insert mode"] = function()
  child.lua("open()")
  child.type_keys("/", "<C-n>")
  eq(child.fn.mode(), "i")
  eq(child.lua_get("vim.api.nvim_get_current_win() == panel.prompt_win"), true)
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 2)
  child.type_keys("<C-p>")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 1)
end

T["preview covers saved ranges without a parser and toggles independently of letters"] = function()
  child.lua([[
    vim.treesitter.get_node = function() return nil end
    items[1].value.end_lnum, items[1].value.end_col = 3, 6
    require("namu.bookmarks").add(items[1], source_buf)
    sidebar.open_favorites()
    _G.panel = sidebar.get("favorites")
  ]])
  eq(
    child.lua_get(
      "vim.api.nvim_buf_get_extmarks(source_buf, panel.preview_ns, 0, -1, { details = true })[1][4].end_row"
    ),
    2
  )
  child.type_keys(";")
  eq(child.lua_get("require('namu.selecta.jump').is_active(panel)"), true)
  child.type_keys("<C-o>")
  eq(child.lua_get("panel.opts.preview.highlight_on_move"), false)
  eq(child.lua_get("#vim.api.nvim_buf_get_extmarks(source_buf, panel.preview_ns, 0, -1, {})"), 0)
  eq(child.lua_get("require('namu.selecta.jump').is_active(panel)"), true)
  child.type_keys("<C-o>")
  eq(child.lua_get("#vim.api.nvim_buf_get_extmarks(source_buf, panel.preview_ns, 0, -1, {})"), 1)
  child.type_keys(";", "p")
  eq(child.lua_get("panel.opts.preview.highlight_on_move"), false)
end

T["empty search results clear preview and restore code view"] = function()
  child.lua("open()")
  child.type_keys("j", "/", "missing-symbol")
  eq(child.lua_get("#panel.filtered_items"), 0)
  eq(child.lua_get("#vim.api.nvim_buf_get_extmarks(source_buf, panel.preview_ns, 0, -1, {})"), 0)
  eq(child.lua_get("vim.api.nvim_win_get_cursor(source_win)[1]"), 1)
end

T["sidebar previews the same meaningful Treesitter node as the floating picker"] = function()
  child.lua([[
    _G.fake_node = {
      type = function() return "function_declaration" end,
      range = function() return 0, 0, 3, 0 end,
      parent = function() return nil end,
    }
    vim.treesitter.get_node = function() return fake_node end
    require("namu.namu_symbols.ui").find_meaningful_node = function(node) return node end
    open()
  ]])
  eq(
    child.lua_get(
      "vim.api.nvim_buf_get_extmarks(source_buf, panel.preview_ns, 0, -1, { details = true })[1][4].end_row"
    ),
    3
  )
end

T["preview toggles stay local to each panel and leave symbol defaults unchanged"] = function()
  child.lua([[
    open()
    sidebar.toggle_preview()
    require("namu.bookmarks").add(items[1], source_buf)
    sidebar.open_favorites()
    _G.favorites = sidebar.get("favorites")
  ]])
  eq(child.lua_get("panel.opts.preview.highlight_on_move"), false)
  eq(child.lua_get("favorites.opts.preview.highlight_on_move"), true)
  eq(child.lua_get("require('namu.namu_symbols.config').values.preview.highlight_on_move"), true)
end

T["search focuses the picker best match while preserving list order"] = function()
  child.lua([[
    items[1].text, items[2].text, items[3].text = "render_extra_details", "render", "pre_render"
    for _, item in ipairs(items) do item.kind = "Function" end
    open({ preview = { highlight_on_move = false } })
  ]])
  child.type_keys("/", "render")
  eq(child.lua_get("#panel.filtered_items"), 3)
  eq(child.lua_get("panel.filtered_items[1].text"), "render_extra_details")
  eq(child.lua_get("panel.best_match_index"), 2)
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 2)
  child.type_keys("<C-n>")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 3)
  child.lua("sidebar.update('sidebar', items)")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 3)
  child.type_keys("<C-u>", "/fnrender")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 2)
end

T["code following selects nested symbols without focus preview or rendering work"] = function()
  child.lua([[
    items[1].value.end_lnum = 5
    items[2].value.end_lnum = 3
    items[3].value.end_lnum = 5
    open()
    sidebar.focus_code()
    _G.code_before = vim.api.nvim_win_get_buf(source_win)
    _G.list_tick = vim.api.nvim_buf_get_changedtick(panel.buf)
    _G.follow_index = panel.follow_index
    _G.fetch_count = 0
    require("namu.namu_symbols").fetch_symbols = function() fetch_count = fetch_count + 1 end
    vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
  ]])
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 2)
  eq(child.lua_get("vim.api.nvim_get_current_win()"), child.lua_get("source_win"))
  eq(child.lua_get("vim.api.nvim_win_get_cursor(source_win)[1]"), 3)
  eq(child.lua_get("vim.api.nvim_win_get_buf(source_win) == code_before"), true)
  eq(child.lua_get("vim.api.nvim_buf_get_changedtick(panel.buf) == list_tick"), true)
  eq(child.lua_get("panel.follow_index == follow_index"), true)
  eq(child.lua_get("fetch_count"), 0)
  eq(child.lua_get("#vim.api.nvim_buf_get_extmarks(source_buf, panel.preview_ns, 0, -1, {})"), 0)
  child.lua([[
    vim.api.nvim_win_set_cursor(source_win, { 5, 0 })
    vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(source_win) })
  ]])
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 3)
end

T["follow cursor is optional and can be toggled without changing preview or labels"] = function()
  child.lua([[
    open({ follow_cursor = { enabled = false } })
    sidebar.focus_code()
    vim.api.nvim_win_set_cursor(source_win, { 4, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
  ]])
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 1)
  child.lua("sidebar.toggle_follow_cursor()")
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 3)
  child.lua("vim.api.nvim_set_current_win(panel.win)")
  child.type_keys(";", "<C-f>")
  eq(child.lua_get("panel.opts.follow_cursor.enabled"), false)
  eq(child.lua_get("panel.opts.preview.highlight_on_move"), true)
  eq(child.lua_get("require('namu.selecta.jump').is_active(panel)"), true)
  child.type_keys("<C-f>")
  eq(child.lua_get("panel.opts.follow_cursor.enabled"), true)
end

T["follow cursor respects filters collapse and file identity"] = function()
  child.lua([[
    items[1].value.end_lnum = 5
    open()
  ]])
  child.type_keys("h", "<Esc>")
  child.lua([[
    vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
  ]])
  eq(child.lua_get("#panel.filtered_items"), 2)
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 1)
  child.lua("vim.api.nvim_set_current_win(panel.win)")
  child.type_keys("/", "Other", "<Esc>", "<Esc>")
  child.lua([[
    vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
  ]])
  eq(child.lua_get("panel.query"), "Other")
  eq(child.lua_get("panel.filtered_items[1].text"), "Other")
  child.lua([[
    _G.other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(source_win, other)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = other })
  ]])
  eq(child.lua_get("vim.api.nvim_get_current_win() == source_win"), true)
  eq(child.lua_get("panel.filtered_items[1].text"), "Other")
end

T["following stays idle outside the source window and cancels safely on close"] = function()
  child.lua([[
    open()
    vim.api.nvim_win_set_cursor(source_win, { 4, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
  ]])
  eq(child.lua_get("vim.api.nvim_win_get_cursor(panel.win)[1]"), 1)
  child.lua([[
    sidebar.focus_code()
    vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
    sidebar.close()
  ]])
  eq(child.lua_get("panel.active"), false)
end

return T
