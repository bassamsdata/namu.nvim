local M = {}
local api = vim.api
local storage = require("namu.sidebar.storage")
local panels = {}
local configured = false
local config = {}
local common = require("namu.selecta.common")
local jump = require("namu.selecta.jump")
local update_current
local clear_preview
local schedule_follow
local symbol_index = require("namu.sidebar.symbol_index")

local function picker_options(opts)
  local resolved = vim.tbl_deep_extend(
    "force",
    require("namu.selecta.selecta_config").values,
    require("namu.namu_symbols.config").values,
    config,
    opts,
    {
      auto_select = false,
      initially_hidden = false,
    }
  )
  resolved = vim.deepcopy(resolved)
  resolved.follow_cursor = vim.tbl_deep_extend(
    "force",
    { enabled = true, toggle_key = "<C-f>", letter_key = "f" },
    resolved.follow_cursor or {}
  )
  resolved.jump = vim.tbl_deep_extend("force", require("namu.selecta.selecta_config").values.jump, resolved.jump or {})
  resolved.pre_filter = opts.pre_filter
    or function(items, query)
      return require("namu.core.symbol_utils").filter_items(items, query, resolved)
    end
  resolved.preserve_order = opts.preserve_order ~= false
  resolved.formatter = opts.formatter
    or function(item)
      return require("namu.core.format_utils").format_item_for_display(item, resolved)
    end
  resolved.hooks = resolved.hooks or {}
  resolved.hooks.on_render = opts.hooks and opts.hooks.on_render
    or function(buf, items)
      require("namu.namu_symbols.ui").apply_highlights(buf, items, resolved)
    end
  return resolved
end

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
    saved.follow_buffer = panel.opts.follow_buffer == true
    saved.items = {}
    for _, entry in ipairs(panel.items) do
      local record = storage.record(entry, panel.original_buf)
      if record then
        table.insert(saved.items, record)
      end
    end
    storage.get().panels.sidebar = saved
  end
  storage.get().panels[panel.storage_key] = saved
end

local function update_prompt(panel)
  local ui = require("namu.selecta.ui")
  ui.update_prompt_prefix(panel, panel.opts, panel.query)
  local source = current_item(panel) and current_item(panel).source
  local source_info = source
      and {
        text = source == "treesitter" and " TS" or source == "lsp" and "󰿘 LSP" or source,
        hl_group = "NamuSourceIndicator",
      }
    or panel.source_info
    or panel.opts.initial_prompt_info
  local filter_only = panel.filter_metadata and (panel.filter_metadata.remaining or "") == ""
  ui.update_prompt_info(panel, { initial_prompt_info = source_info }, not filter_only)
  ui.update_filter_info(panel, panel.filter_metadata, source_info)
  vim.wo[panel.prompt_win].statusline = "%#NamuSidebarHint# "
    .. (panel.opts.preview.toggle_key or "p"):gsub("%%", "%%%%")
    .. ":preview "
    .. panel.opts.follow_cursor.letter_key:gsub("%%", "%%%%")
    .. ":follow g?:help %= follow:"
    .. (panel.opts.follow_cursor.enabled and "on" or "off")
    .. " %*"
end

local function render(panel)
  if not panel.active or not api.nvim_win_is_valid(panel.win) then
    return
  end
  local sources = {}
  for _, item in ipairs(panel.items) do
    if item.source then
      sources[item.source] = true
    end
  end
  local source = vim.tbl_count(sources) == 1 and next(sources) or vim.tbl_count(sources) > 1 and "Mixed" or nil
  panel.source_info = source
      and {
        text = source == "treesitter" and " TS" or source == "lsp" and "󰿘 LSP" or source,
        hl_group = "NamuSourceIndicator",
      }
    or nil
  local refresh_jump = jump.is_active(panel)
  if refresh_jump then
    jump.deactivate(panel)
  end
  local filter_state = { items = panel.items, filtered_items = {}, initial_open = false }
  require("namu.selecta.selecta").update_filtered_items(filter_state, panel.query, panel.opts)
  panel.filter_metadata = filter_state.filter_metadata
  panel.best_match_index = filter_state.best_match_index
  if panel.query_changed then
    local best = filter_state.best_match_index and filter_state.filtered_items[filter_state.best_match_index]
    panel.selected_id = best and item_id(best) or nil
    panel.query_changed = false
  end
  panel.opts.display.prefix_width =
    require("namu.selecta.ui").calculate_max_prefix_width(panel.items, panel.opts.display.mode)
  for index, item in ipairs(panel.items) do
    if not item.tree_state and (item.depth or 0) > 0 then
      item.tree_state = {}
      for level = 1, item.depth do
        local last = true
        for next_index = index + 1, #panel.items do
          local depth = panel.items[next_index].depth or 0
          if depth < level then
            break
          end
          if depth == level then
            last = false
            break
          end
        end
        item.tree_state[level] = last
      end
    end
  end
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
      table.insert(lines, label)
      if panel.query == "" and panel.collapsed[item_id(item)] then
        blocked_depth = depth
      end
    end
  end
  panel.filtered_items = visible
  panel.follow_index = panel.opts.follow_cursor.enabled and symbol_index.new(visible, panel.original_buf) or nil
  panel.follow_last = nil
  if #lines == 0 then
    lines = { panel.query == "" and "  No items" or "  No matching items" }
  end
  vim.bo[panel.buf].modifiable = true
  api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
  if not panel.selected_id and #visible > 0 then
    if panel.initial_item then
      panel.selected_id = item_id(panel.initial_item)
      panel.initial_item = nil
    elseif panel.initial_line then
      local best, distance = nil, math.huge
      for _, item in ipairs(visible) do
        local location = storage.location(item, panel.original_buf)
        if location then
          local value = type(item.value) == "table" and item.value or {}
          local last_line = value.end_lnum or location.line
          local delta = panel.initial_line >= location.line
              and panel.initial_line <= last_line
              and (last_line - location.line)
            or (100000 + math.abs(location.line - panel.initial_line))
          if delta < distance then
            best, distance = item, delta
          end
        end
      end
      if best then
        panel.selected_id = item_id(best)
      end
      panel.initial_line = nil
    end
  end
  local row = 1
  for index, item in ipairs(visible) do
    if item_id(item) == panel.selected_id then
      row = index
      break
    end
  end
  if #visible > 0 then
    panel.initial_item = nil
    panel.initial_line = nil
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
  api.nvim_buf_clear_namespace(panel.buf, common.ns_id, 0, -1)
  for index, item in ipairs(visible) do
    require("namu.selecta.ui").apply_highlights(
      panel.buf,
      index - 1,
      item,
      panel.opts,
      panel.query,
      #lines[index],
      panel
    )
  end
  panel.opts.hooks.on_render(panel.buf, visible, panel.opts)
  common.update_current_highlight(panel, panel.opts, api.nvim_win_get_cursor(panel.win)[1] - 1)
  update_prompt(panel)
  remember(panel)
  if update_current then
    update_current(panel)
  end
  schedule_follow(panel)
  if refresh_jump then
    vim.cmd("redraw")
    jump.activate(panel, panel.opts)
  end
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

clear_preview = function(panel, restore)
  local buf = panel.last_highlighted_bufnr
  if buf and api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, panel.preview_ns, 0, -1)
  end
  panel.last_highlighted_bufnr = nil
  local saved = panel.preview_saved
  panel.preview_saved = nil
  -- A buffer chosen by the user after leaving the sidebar must not be replaced
  -- by the earlier preview snapshot.
  if
    restore
    and saved
    and buf
    and api.nvim_win_is_valid(saved.win)
    and api.nvim_buf_is_valid(saved.buf)
    and api.nvim_win_get_buf(saved.win) == buf
  then
    panel.previewing = true
    local previous = vim.o.eventignore
    vim.o.eventignore = "all"
    pcall(api.nvim_win_call, saved.win, function()
      api.nvim_win_set_buf(saved.win, saved.buf)
      api.nvim_win_set_cursor(saved.win, saved.cursor)
      vim.fn.winrestview(saved.view)
    end)
    vim.o.eventignore = previous
    panel.previewing = false
  end
end

update_current = function(panel)
  update_prompt(panel)
  remember(panel)
  local row = api.nvim_win_get_cursor(panel.win)[1]
  local selected = panel.filtered_items[row]
  if selected then
    local line = api.nvim_buf_get_lines(panel.buf, row - 1, row, false)[1] or ""
    require("namu.selecta.ui").apply_highlights(panel.buf, row - 1, selected, panel.opts, panel.query, #line, panel)
  end
  common.update_current_highlight(panel, panel.opts, row - 1)
  local focus = api.nvim_get_current_win()
  if focus ~= panel.win and focus ~= panel.prompt_win then
    return
  end
  if panel.opts.preview and panel.opts.preview.highlight_on_move == false then
    return
  end
  local item = current_item(panel)
  local location = item and storage.location(item, panel.original_buf)
  local win = code_window(panel)
  if not location or not win then
    clear_preview(panel, true)
    return
  end
  if not panel.preview_saved then
    panel.preview_saved = {
      win = win,
      buf = api.nvim_win_get_buf(win),
      cursor = api.nvim_win_get_cursor(win),
      view = api.nvim_win_call(win, vim.fn.winsaveview),
    }
  end
  panel.previewing = true
  -- Load normally so BufRead/FileType still initialize syntax and LSP support.
  local loaded, buf = pcall(function()
    local buffer = vim.fn.bufadd(location.path)
    vim.fn.bufload(buffer)
    return buffer
  end)
  if not loaded then
    panel.previewing = false
    return
  end
  local previous = vim.o.eventignore
  vim.o.eventignore = "all"
  pcall(api.nvim_win_call, win, function()
    api.nvim_win_set_buf(win, buf)
    local line = math.min(location.line, api.nvim_buf_line_count(buf))
    local text = api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    api.nvim_win_set_cursor(win, { line, math.min(location.col, #text) })
    vim.cmd("normal! zz")
    -- Normalize saved bookmarks into the same symbol shape as the picker.
    local symbol = vim.deepcopy(item)
    symbol.bufnr = buf
    symbol.value = vim.tbl_extend("force", type(item.value) == "table" and item.value or {}, {
      lnum = line,
      col = location.col + 1,
      end_lnum = location.end_line,
      end_col = location.end_col and location.end_col + 1,
    })
    require("namu.namu_symbols.ui").preview_symbol(symbol, win, panel.preview_ns, panel, panel.opts.highlight)
  end)
  vim.o.eventignore = previous
  panel.previewing = false
end

schedule_follow = function(panel)
  if not panel.active or not panel.opts.follow_cursor.enabled or panel.previewing or panel.follow_pending then
    return
  end
  if api.nvim_get_current_win() ~= panel.original_win then
    return
  end
  panel.follow_pending = true
  vim.schedule(function()
    panel.follow_pending = false
    if not panel.active or not panel.opts.follow_cursor.enabled or panel.previewing then
      return
    end
    if api.nvim_get_current_win() ~= panel.original_win or not api.nvim_win_is_valid(panel.win) then
      return
    end
    local buf = api.nvim_win_get_buf(panel.original_win)
    local line = api.nvim_win_get_cursor(panel.original_win)[1]
    local last = panel.follow_last
    if last and last.buf == buf and last.line == line then
      return
    end
    panel.follow_last = { buf = buf, line = line }
    local row = symbol_index.find(panel.follow_index or {}, api.nvim_buf_get_name(buf), line)
    if not row or api.nvim_win_get_cursor(panel.win)[1] == row then
      return
    end
    api.nvim_win_set_cursor(panel.win, { row, 0 })
    -- Change only the selected row; never move code, run preview, or serialize items.
    local item = panel.filtered_items[row]
    panel.selected_id = item_id(item)
    common.update_current_highlight(panel, panel.opts, row - 1)
    update_prompt(panel)
  end)
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
  clear_preview(panel, true)
  jump.deactivate(panel)
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
  -- Reserve control letters so they and g? still work in jump mode.
  panel.jump_reserved_keys = { g = true }
  for _, key in ipairs({ panel.opts.preview.toggle_key or "p", panel.opts.follow_cursor.letter_key }) do
    if #key == 1 then
      panel.jump_reserved_keys[key] = true
    end
  end
  local function map(modes, lhs, callback, buf)
    vim.keymap.set(modes, lhs, callback, { buffer = buf or panel.buf, silent = true, nowait = true })
  end
  local function focus_list()
    vim.cmd("stopinsert")
    if panel.active then
      api.nvim_set_current_win(panel.win)
      update_current(panel)
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
      update_current(panel)
    end, buf)
    map("n", "k", function()
      focus_list()
      local row = api.nvim_win_get_cursor(panel.win)[1]
      api.nvim_win_set_cursor(panel.win, { math.max(1, row - 1), 0 })
      update_current(panel)
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
    map("n", "g?", function()
      M.show_help(panel.name)
    end, buf)
    map("n", panel.opts.follow_cursor.letter_key, function()
      M.toggle_follow_cursor(panel.name)
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
  for _, direction in ipairs({ { "next", 1 }, { "previous", -1 } }) do
    for _, key in ipairs(panel.opts.movement[direction[1]] or {}) do
      map("i", key, function()
        local row = api.nvim_win_get_cursor(panel.win)[1]
        api.nvim_win_set_cursor(panel.win, { math.max(1, math.min(row + direction[2], #panel.filtered_items)), 0 })
        update_current(panel)
      end, panel.prompt_buf)
    end
  end
  for _, buf in ipairs({ panel.buf, panel.prompt_buf }) do
    map("n", panel.opts.preview.toggle_key or "p", function()
      M.toggle_preview(panel.name)
    end, buf)
    map({ "i", "n" }, panel.opts.follow_cursor.toggle_key, function()
      M.toggle_follow_cursor(panel.name)
    end, buf)
    map({ "i", "n" }, "<C-o>", function()
      M.toggle_preview(panel.name)
    end, buf)
  end
  if panel.opts.jump.enabled then
    for _, buf in ipairs({ panel.buf, panel.prompt_buf }) do
      map({ "i", "n" }, panel.opts.jump.toggle_key, function()
        panel.jump_auto_pending = false
        if jump.is_active(panel) then
          jump.deactivate(panel)
        else
          api.nvim_set_current_win(panel.win)
          vim.cmd("redraw")
          jump.activate(panel, panel.opts)
        end
      end, buf)
    end
  end
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
      clear_preview(panel, true)
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
    existing.source_generation = (existing.source_generation or 0) + 1
    existing.items = items
    existing.opts = picker_options(opts)
    existing.title = opts.title or existing.title
    existing.original_win = module_state.original_win or existing.original_win
    existing.original_buf = module_state.original_buf or existing.original_buf
    if opts.replace then
      clear_preview(existing, true)
      existing.storage_key = opts.storage_key
        or (opts.follow_buffer and name .. ":" .. api.nvim_buf_get_name(existing.original_buf))
        or name
      existing.query = ""
      existing.initial_item = opts.initial_item
      existing.initial_line = opts.initial_line
      existing.selected_id = opts.initial_item and item_id(opts.initial_item) or nil
      existing.pending_view = nil
      existing.collapsed = {}
      api.nvim_buf_set_lines(existing.prompt_buf, 0, -1, false, { "" })
    end
    render(existing)
    if existing.opts.follow_buffer then
      require("namu.sidebar.source").attach(existing)
      if #items == 0 then
        require("namu.sidebar.source").refresh(existing)
      end
    end
    api.nvim_set_current_win(existing.win)
    return existing
  end
  local original_win = module_state.original_win or M.source_window()
  local original_buf = module_state.original_buf or api.nvim_win_get_buf(original_win)
  local storage_key = opts.storage_key
    or (opts.follow_buffer and name .. ":" .. api.nvim_buf_get_name(original_buf))
    or name
  local saved = storage.get().panels[storage_key]
  saved = type(saved) == "table" and saved or {}
  local panel = {
    name = name,
    title = opts.title or "Sidebar",
    items = items,
    opts = picker_options(opts),
    original_win = original_win,
    original_buf = original_buf,
    query = type(saved.query) == "string" and saved.query or "",
    selected_id = opts.initial_item and item_id(opts.initial_item) or saved.selected_id,
    initial_item = opts.initial_item,
    initial_line = opts.initial_line,
    sidebar_mode = true,
    picker_id = tostring(vim.uv.hrtime()),
    preview_ns = api.nvim_create_namespace("namu_sidebar_preview_" .. name),
    get_query_string = function(self)
      return self.query
    end,
    pending_view = type(saved.view) == "table" and saved.view or nil,
    collapsed = type(saved.collapsed) == "table" and saved.collapsed or {},
    storage_key = storage_key,
    buf = api.nvim_create_buf(false, true),
    prompt_buf = api.nvim_create_buf(false, true),
    active = true,
  }
  panel.jump_select = function(row)
    api.nvim_win_set_cursor(panel.win, { row, 0 })
    jump_to_item(panel)
  end
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
    vim.bo[buf].complete = ""
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
  vim.bo[panel.prompt_buf].filetype = "namu_prompt"
  api.nvim_buf_set_lines(panel.prompt_buf, 0, -1, false, { panel.query })
  panel.group = api.nvim_create_augroup("NamuSidebar_" .. panel.buf, { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = panel.group,
    buffer = panel.buf,
    callback = function()
      update_current(panel)
    end,
  })
  api.nvim_create_autocmd("WinEnter", {
    group = panel.group,
    buffer = panel.buf,
    callback = function()
      update_current(panel)
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled", "WinEnter", "BufEnter" }, {
    group = panel.group,
    callback = function()
      schedule_follow(panel)
    end,
  })
  api.nvim_create_autocmd("WinLeave", {
    group = panel.group,
    callback = function()
      if api.nvim_get_current_win() == panel.win or api.nvim_get_current_win() == panel.prompt_win then
        vim.schedule(function()
          if
            panel.active
            and api.nvim_get_current_win() ~= panel.win
            and api.nvim_get_current_win() ~= panel.prompt_win
          then
            clear_preview(panel, true)
          end
        end)
      end
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
          panel.jump_auto_pending = false
          panel.selected_id = nil
          panel.query_changed = true
        end
        panel.query = query
        render(panel)
      end)
    end,
  })
  setup_keymaps(panel)
  panel.jump_auto_pending = true
  render(panel)
  vim.cmd("stopinsert")
  api.nvim_set_current_win(panel.win)
  update_current(panel)
  if #panel.filtered_items > 0 then
    panel.jump_auto_pending = false
    if jump.should_auto_activate(panel.opts, #panel.filtered_items) then
      jump.activate(panel, panel.opts)
    end
  end
  if panel.opts.follow_buffer then
    require("namu.sidebar.source").attach(panel)
    if #items == 0 then
      require("namu.sidebar.source").refresh(panel)
    end
  end
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
    if panel.jump_auto_pending and #items > 0 and api.nvim_get_current_win() == panel.win then
      panel.jump_auto_pending = false
      if jump.should_auto_activate(panel.opts, #panel.filtered_items) then
        vim.cmd("redraw")
        jump.activate(panel, panel.opts)
      end
    end
  end
end

---Switch a symbol sidebar to a new source buffer and restore that file's search.
---@param name string
---@param bufnr number
---@param win? number New code window
---@return nil
function M.set_source(name, bufnr, win)
  local panel = panels[name]
  if not panel or not panel.active then
    return
  end
  clear_preview(panel, win ~= nil and win ~= panel.original_win)
  if win then
    panel.original_win = win
  end
  if panel.original_buf == bufnr then
    return
  end
  remember(panel)
  panel.original_buf = bufnr
  panel.follow_index = nil
  panel.follow_last = nil
  panel.storage_key = name .. ":" .. api.nvim_buf_get_name(bufnr)
  local saved = storage.get().panels[panel.storage_key]
  saved = type(saved) == "table" and saved or {}
  panel.query = type(saved.query) == "string" and saved.query or ""
  panel.selected_id = saved.selected_id
  panel.pending_view = type(saved.view) == "table" and saved.view or nil
  panel.collapsed = type(saved.collapsed) == "table" and saved.collapsed or {}
  panel.initial_item = nil
  panel.initial_line = nil
  panel.query_changed = false
  panel.items = {}
  render(panel)
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
  require("namu.sidebar.help").close(panel, false)
  jump.deactivate(panel)
  clear_preview(panel, true)
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
    clear_preview(panel, true)
    jump.deactivate(panel)
    if win then
      vim.cmd("stopinsert")
      api.nvim_set_current_win(win)
    end
  end
end

---Toggle symbol body preview while keeping jump letters independent.
---@param name? string
---@return nil
function M.toggle_preview(name)
  local panel = panels[name or "sidebar"]
  if not panel or not panel.active then
    return
  end
  panel.opts.preview.highlight_on_move = not panel.opts.preview.highlight_on_move
  if panel.opts.preview.highlight_on_move then
    update_current(panel)
  else
    clear_preview(panel, true)
  end
end

---Toggle tracking the code cursor without changing preview or jump labels.
---@param name? string
---@return nil
function M.toggle_follow_cursor(name)
  local panel = panels[name or "sidebar"]
  if not panel or not panel.active then
    return
  end
  panel.opts.follow_cursor.enabled = not panel.opts.follow_cursor.enabled
  panel.follow_last = nil
  update_prompt(panel)
  if panel.opts.follow_cursor.enabled then
    panel.follow_index = symbol_index.new(panel.filtered_items, panel.original_buf)
    schedule_follow(panel)
  else
    panel.follow_index = nil
  end
end

---Show the sidebar shortcuts and current toggle states.
---@param name? string
---@return nil
function M.show_help(name)
  local panel = panels[name or "sidebar"]
  if panel and panel.active then
    require("namu.sidebar.help").open(panel)
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
  jump.deactivate(panel)
  api.nvim_set_current_win(panel.prompt_win)
  vim.cmd("startinsert!")
end

---Get a currently open sidebar.
---@param name? string
---@return table|nil
function M.get(name)
  return panels[name or "sidebar"]
end

---Open the current file's symbols in the sidebar, replacing any transferred list.
---@param opts? table
---@return table panel
function M.open_symbols(opts)
  local source_win = M.source_window()
  local source_buf = api.nvim_win_get_buf(source_win)
  opts = vim.tbl_deep_extend("force", opts or {}, {
    name = "sidebar",
    title = "Sidebar",
    follow_buffer = true,
    replace = true,
    storage_key = "sidebar:" .. api.nvim_buf_get_name(source_buf),
    initial_line = api.nvim_win_get_cursor(source_win)[1],
  })
  return M.open({}, opts, { original_win = source_win, original_buf = source_buf })
end

---Refresh the live symbols sidebar without changing focus.
---@param source_win? number
---@return nil
function M.refresh(source_win)
  local panel = panels.sidebar
  if panel then
    require("namu.sidebar.source").refresh(panel, source_win)
  end
end

---Toggle the sidebar, restoring its last list when reopening.
---@return nil
function M.toggle()
  if panels.sidebar then
    M.close()
  else
    M.show()
  end
end

---Reopen the last list sent from a picker, or show the current file's symbols.
---@param opts? table
---@return nil
function M.show(opts)
  ensure_config()
  local panel = panels.sidebar
  if panel then
    api.nvim_set_current_win(panel.win)
    return
  end
  local saved = storage.get().panels.sidebar
  local symbol_list = type(saved) == "table" and saved.follow_buffer
  if type(saved) == "table" and saved.follow_buffer == nil and type(saved.items) == "table" and #saved.items > 0 then
    -- Migrate saved symbol lists that predate buffer tracking.
    local first_location = storage.location(saved.items[1])
    symbol_list = first_location
      and vim.iter(saved.items):all(function(item)
        local location = storage.location(item)
        return (item.source == "treesitter" or item.source == "lsp")
          and location
          and location.path == first_location.path
      end)
  end
  if symbol_list then
    M.open_symbols(opts)
  elseif type(saved) == "table" and type(saved.items) == "table" and #saved.items > 0 then
    M.open(saved.items, vim.tbl_extend("force", { title = "Sidebar" }, opts or {}))
  else
    M.open_symbols(opts)
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
