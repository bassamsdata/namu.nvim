local M = {}
local api = vim.api
local storage = require("namu.sidebar.storage")
local panels = {}
local configured = false
local config = {}

local function ensure_config()
  if not configured then
    M.setup(require("namu.core.config_manager").get_config("sidebar"))
  end
end

local function item_id(item)
  local value = type(item.value) == "table" and item.value or {}
  local record = storage.record(item)
  return item.id or (record and record.id) or value.signature or item.text
end

local function current_item(panel)
  if not panel.active or not api.nvim_win_is_valid(panel.win) then
    return nil
  end
  return panel.filtered_items[api.nvim_win_get_cursor(panel.win)[1]]
end

local function remember(panel)
  local item = current_item(panel)
  if item then
    panel.selected_id = item_id(item)
  end
  local saved = {
    query = panel.query,
    selected_id = panel.selected_id,
    collapsed = vim.deepcopy(panel.collapsed),
  }
  if api.nvim_win_is_valid(panel.win) then
    saved.view = api.nvim_win_call(panel.win, vim.fn.winsaveview)
  end
  if panel.name == "sidebar" then
    saved.items = {}
    for _, entry in ipairs(panel.items) do
      local record = storage.record(entry, panel.original_buf)
      if record then
        table.insert(saved.items, record)
      end
    end
  end
  storage.get().panels[panel.storage_key] = saved
end

local function render(panel)
  if not panel.active or not api.nvim_win_is_valid(panel.win) then
    return
  end
  local filter_state = { items = panel.items, filtered_items = {}, initial_open = false }
  require("namu.selecta.selecta").update_filtered_items(filter_state, panel.query, panel.opts)
  local visible, lines = {}, {}
  local blocked_depth
  for _, item in ipairs(filter_state.filtered_items) do
    local depth = item.depth or 0
    if blocked_depth and depth <= blocked_depth then
      blocked_depth = nil
    end
    if panel.query ~= "" or not blocked_depth then
      table.insert(visible, item)
      local label = panel.opts.formatter and panel.opts.formatter(item) or ((item.icon or "") .. " " .. item.text)
      label = label:gsub("[\r\n]", " ")
      table.insert(lines, string.rep("  ", depth) .. (panel.collapsed[item_id(item)] and "▸ " or "  ") .. label)
      if panel.query == "" and panel.collapsed[item_id(item)] then
        blocked_depth = depth
      end
    end
  end
  panel.filtered_items = visible
  if #lines == 0 then
    lines = { panel.query == "" and "  No items" or "  No matching items" }
  end
  vim.bo[panel.buf].modifiable = true
  api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
  local row = 1
  for index, item in ipairs(visible) do
    if item_id(item) == panel.selected_id then
      row = index
      break
    end
  end
  api.nvim_win_set_cursor(panel.win, { row, 0 })
  vim.wo[panel.win].statusline = " Namu "
    .. panel.title:gsub("%%", "%%%%")
    .. " %="
    .. #visible
    .. "/"
    .. #panel.items
    .. " "
  if panel.pending_view and #visible > 0 then
    pcall(api.nvim_win_call, panel.win, function()
      vim.fn.winrestview(panel.pending_view)
    end)
    panel.pending_view = nil
  end
  local hint_ns = api.nvim_create_namespace("namu_sidebar_hint")
  api.nvim_buf_clear_namespace(panel.prompt_buf, hint_ns, 0, -1)
  if panel.query == "" then
    api.nvim_buf_set_extmark(panel.prompt_buf, hint_ns, 0, 0, {
      virt_text = { { "Type to search…", "Comment" } },
      virt_text_pos = "overlay",
    })
  end
  remember(panel)
end

local function code_window(panel)
  if api.nvim_win_is_valid(panel.original_win) then
    return panel.original_win
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if vim.bo[api.nvim_win_get_buf(win)].buftype == "" and api.nvim_win_get_config(win).relative == "" then
      panel.original_win = win
      return win
    end
  end
end

local function jump_to_item(panel)
  local item = current_item(panel)
  if not item then
    return
  end
  local location = storage.location(item, panel.original_buf)
  local win = code_window(panel)
  if not location or not win then
    vim.notify("This item has no available file location", vim.log.levels.WARN, { title = "Namu" })
    return
  end
  if vim.fn.filereadable(location.path) == 0 then
    vim.notify("File is no longer available: " .. location.path, vim.log.levels.WARN, { title = "Namu" })
    return
  end
  remember(panel)
  local ok, err = pcall(function()
    local buf = vim.fn.bufadd(location.path)
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = true
    api.nvim_set_current_win(win)
    vim.cmd("normal! m`")
    api.nvim_win_set_buf(win, buf)
    local line = math.min(location.line, api.nvim_buf_line_count(buf))
    local text = api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    api.nvim_win_set_cursor(win, { line, math.min(location.col, #text) })
    vim.cmd("normal! zz")
  end)
  if not ok then
    vim.notify(tostring(err), vim.log.levels.WARN, { title = "Namu" })
  end
end

local function setup_keymaps(panel)
  local function map(modes, lhs, callback, buf)
    vim.keymap.set(modes, lhs, callback, { buffer = buf or panel.buf, silent = true, nowait = true })
  end
  local function focus_list()
    vim.cmd("stopinsert")
    if panel.active then
      api.nvim_set_current_win(panel.win)
    end
  end
  for _, buf in ipairs({ panel.buf, panel.prompt_buf }) do
    map("n", "q", function()
      M.close(panel.name)
    end, buf)
    map("n", "<Esc>", function()
      M.focus_code(panel.name)
    end, buf)
    map("n", "<CR>", function()
      jump_to_item(panel)
    end, buf)
    map("n", "j", function()
      focus_list()
      local row = api.nvim_win_get_cursor(panel.win)[1]
      api.nvim_win_set_cursor(panel.win, { math.min(row + 1, math.max(1, #panel.filtered_items)), 0 })
      remember(panel)
    end, buf)
    map("n", "k", function()
      focus_list()
      local row = api.nvim_win_get_cursor(panel.win)[1]
      api.nvim_win_set_cursor(panel.win, { math.max(1, row - 1), 0 })
      remember(panel)
    end, buf)
    map("n", "/", function()
      M.search(panel.name)
    end, buf)
    map("n", "h", function()
      local item = current_item(panel)
      if item then
        panel.collapsed[item_id(item)] = true
        render(panel)
      end
    end, buf)
    map("n", "l", function()
      local item = current_item(panel)
      if item then
        panel.collapsed[item_id(item)] = nil
        render(panel)
      end
    end, buf)
    map("n", "m", function()
      local item = current_item(panel)
      if item then
        require("namu.bookmarks").add(item, panel.original_buf)
      end
    end, buf)
  end
  map({ "i", "n" }, "<CR>", focus_list, panel.prompt_buf)
  map("i", "<Esc>", focus_list, panel.prompt_buf)
  map("i", "<C-n>", function()
    focus_list()
    vim.cmd("normal! j")
  end, panel.prompt_buf)
  map("i", "<C-p>", function()
    focus_list()
    vim.cmd("normal! k")
  end, panel.prompt_buf)
  if panel.name == "favorites" then
    map("n", "dd", function()
      local item = current_item(panel)
      if item then
        require("namu.bookmarks").remove(item.id)
      end
    end)
  end
end

---Find the code window when a command is called from another sidebar.
---@return number
function M.source_window()
  local win = api.nvim_get_current_win()
  for _, panel in pairs(panels) do
    if panel.active and (win == panel.win or win == panel.prompt_win) then
      return code_window(panel) or win
    end
  end
  return win
end

---Configure sidebars and persistent favorites.
---@param opts? table
---@return nil
function M.setup(opts)
  config = vim.tbl_deep_extend("force", { position = "right", width = 40, persist = true }, opts or {})
  configured = true
  storage.setup(config)
end

---Open or update a searchable sidebar without closing it when focus moves.
---@param items SelectaItem[]
---@param opts? table
---@param module_state? table
---@return table panel
function M.open(items, opts, module_state)
  ensure_config()
  opts = opts or {}
  module_state = module_state or {}
  local name = opts.name or "sidebar"
  local existing = panels[name]
  if existing and existing.active then
    existing.items = items
    existing.opts = vim.tbl_deep_extend("force", opts, { auto_select = false, initially_hidden = false })
    existing.title = opts.title or existing.title
    existing.original_win = module_state.original_win or existing.original_win
    existing.original_buf = module_state.original_buf or existing.original_buf
    if opts.replace then
      existing.query = ""
      existing.selected_id = nil
      existing.pending_view = nil
      existing.collapsed = {}
      api.nvim_buf_set_lines(existing.prompt_buf, 0, -1, false, { "" })
    end
    render(existing)
    api.nvim_set_current_win(existing.win)
    return existing
  end
  local original_win = module_state.original_win or M.source_window()
  local original_buf = module_state.original_buf or api.nvim_win_get_buf(original_win)
  local storage_key = opts.storage_key or name
  local saved = storage.get().panels[storage_key]
  saved = type(saved) == "table" and saved or {}
  local panel = {
    name = name,
    title = opts.title or "Sidebar",
    items = items,
    opts = vim.tbl_deep_extend("force", opts, { auto_select = false, initially_hidden = false }),
    original_win = original_win,
    original_buf = original_buf,
    query = type(saved.query) == "string" and saved.query or "",
    selected_id = saved.selected_id,
    pending_view = type(saved.view) == "table" and saved.view or nil,
    collapsed = type(saved.collapsed) == "table" and saved.collapsed or {},
    storage_key = storage_key,
    buf = api.nvim_create_buf(false, true),
    prompt_buf = api.nvim_create_buf(false, true),
    active = true,
  }
  panels[name] = panel
  panel.win = api.nvim_open_win(panel.buf, true, {
    split = (opts.position or config.position) == "left" and "left" or "right",
    win = original_win,
    width = opts.width or config.width,
  })
  panel.prompt_win = api.nvim_open_win(panel.prompt_buf, false, { split = "above", win = panel.win, height = 1 })
  for _, buf in ipairs({ panel.buf, panel.prompt_buf }) do
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "namu_sidebar"
    vim.bo[buf].completefunc = ""
    vim.bo[buf].omnifunc = ""
    vim.b[buf].completion = false
    if vim.fn.exists("+autocomplete") == 1 then
      vim.bo[buf].autocomplete = false
    end
  end
  for _, win in ipairs({ panel.win, panel.prompt_win }) do
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].wrap = false
    vim.wo[win].winfixwidth = true
    vim.wo[win].spell = false
  end
  vim.wo[panel.win].cursorline = true
  vim.wo[panel.prompt_win].winfixheight = true
  vim.wo[panel.prompt_win].statusline = " Search (/ to edit)"
  api.nvim_buf_set_lines(panel.prompt_buf, 0, -1, false, { panel.query })
  panel.group = api.nvim_create_augroup("NamuSidebar_" .. panel.buf, { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = panel.group,
    buffer = panel.buf,
    callback = function()
      remember(panel)
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = panel.group,
    callback = function()
      remember(panel)
      storage.save()
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = panel.group,
    callback = function(args)
      if tonumber(args.match) == panel.win or tonumber(args.match) == panel.prompt_win then
        M.close(panel.name)
      end
    end,
  })
  api.nvim_buf_attach(panel.prompt_buf, false, {
    on_lines = function()
      vim.schedule(function()
        if not panel.active or not api.nvim_buf_is_valid(panel.prompt_buf) then
          return
        end
        local query = api.nvim_buf_get_lines(panel.prompt_buf, 0, 1, false)[1] or ""
        if query ~= panel.query then
          panel.selected_id = nil
        end
        panel.query = query
        render(panel)
      end)
    end,
  })
  setup_keymaps(panel)
  render(panel)
  vim.cmd("stopinsert")
  api.nvim_set_current_win(panel.win)
  return panel
end

---Replace a sidebar's items without changing focus or its search.
---@param name string
---@param items SelectaItem[]
---@return nil
function M.update(name, items)
  local panel = panels[name]
  if panel and panel.active then
    panel.items = items
    render(panel)
  end
end

---Switch an outline to a new source buffer and restore that file's search.
---@param name string
---@param bufnr number
---@return nil
function M.set_source(name, bufnr)
  local panel = panels[name]
  if not panel or not panel.active then
    return
  end
  remember(panel)
  panel.original_buf = bufnr
  panel.storage_key = name .. ":" .. api.nvim_buf_get_name(bufnr)
  local saved = storage.get().panels[panel.storage_key]
  saved = type(saved) == "table" and saved or {}
  panel.query = type(saved.query) == "string" and saved.query or ""
  panel.selected_id = saved.selected_id
  panel.pending_view = type(saved.view) == "table" and saved.view or nil
  panel.collapsed = type(saved.collapsed) == "table" and saved.collapsed or {}
  api.nvim_buf_set_lines(panel.prompt_buf, 0, -1, false, { panel.query })
end

---Close a sidebar, saving its view and cleaning up both split windows.
---@param name? string
---@return nil
function M.close(name)
  local panel = panels[name or "sidebar"]
  if not panel or not panel.active then
    return
  end
  remember(panel)
  storage.save()
  panel.active = false
  pcall(api.nvim_del_augroup_by_id, panel.group)
  for _, win in ipairs({ panel.prompt_win, panel.win }) do
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
  panels[panel.name] = nil
end

---Focus the original code window while keeping the sidebar open.
---@param name? string
---@return nil
function M.focus_code(name)
  local panel = panels[name or "sidebar"]
  if panel then
    local win = code_window(panel)
    if win then
      vim.cmd("stopinsert")
      api.nvim_set_current_win(win)
    end
  end
end

---Focus the search input in a sidebar.
---@param name? string
---@return nil
function M.search(name)
  local panel = panels[name or "sidebar"]
  if not panel or not panel.active then
    return
  end
  api.nvim_set_current_win(panel.prompt_win)
  vim.cmd("startinsert!")
end

---Get a currently open sidebar.
---@param name? string
---@return table|nil
function M.get(name)
  return panels[name or "sidebar"]
end

---Reopen the last list sent from a picker, or open the current symbols outline.
---@return nil
function M.show()
  ensure_config()
  local panel = panels.sidebar
  if panel then
    api.nvim_set_current_win(panel.win)
    return
  end
  local saved = storage.get().panels.sidebar
  if type(saved) == "table" and type(saved.items) == "table" and #saved.items > 0 then
    M.open(saved.items, { title = "Sidebar" })
  else
    require("namu.namu_outline").open()
  end
end

local function favorite_items()
  local items = require("namu.bookmarks").get_all()
  for _, item in ipairs(items) do
    item.text = item.text .. "  " .. vim.fn.fnamemodify(item.location.path, ":t") .. ":" .. item.location.line
  end
  return items
end

---Open the favorites sidebar.
---@return nil
function M.open_favorites()
  ensure_config()
  M.open(favorite_items(), { name = "favorites", title = "Favorites" })
end

---Update the favorites sidebar in place after adding or removing an item.
---@return nil
function M.refresh_favorites()
  local panel = panels.favorites
  if panel and panel.active then
    panel.items = favorite_items()
    render(panel)
  end
end

return M
