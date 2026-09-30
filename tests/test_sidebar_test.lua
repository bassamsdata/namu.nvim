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
  child.type_keys("<Esc>")
  child.lua([[
    _G.other_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(other_buf)
  ]])
  child.lua("requests[#requests].callback({})")
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

return T
