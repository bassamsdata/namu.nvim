local M = {}
local api = vim.api

---Close a sidebar's help window, optionally returning to its previous window.
---@param panel table
---@param restore? boolean
---@return nil
function M.close(panel, restore)
  local help = panel.help
  if not help then
    return
  end
  panel.help = nil
  if api.nvim_win_is_valid(help.win) then
    pcall(api.nvim_win_close, help.win, true)
  end
  if restore ~= false and panel.active and api.nvim_win_is_valid(help.return_win) then
    api.nvim_set_current_win(help.return_win)
    if help.insert then
      vim.cmd("startinsert!")
    end
  end
end

---Open a compact reference for this sidebar's configured shortcuts.
---@param panel table
---@return nil
function M.open(panel)
  if panel.help and api.nvim_win_is_valid(panel.help.win) then
    api.nvim_set_current_win(panel.help.win)
    return
  end
  local opts = panel.opts
  local entries = {
    { section = "NAVIGATION" },
    { key = "j / k", text = "Move through items" },
    { key = "/", text = "Search; Enter or Escape returns to the list" },
    { key = table.concat(opts.movement.next or {}, " / "), text = "Next result while searching" },
    { key = table.concat(opts.movement.previous or {}, " / "), text = "Previous result while searching" },
    { key = "Enter", text = "Jump to the symbol and keep the sidebar open" },
    { key = "Escape", text = "Focus code" },
    { key = "q", text = "Close the sidebar" },
    {},
    { section = "SYMBOLS" },
    { key = "h / l", text = "Collapse / expand nested groups" },
    {
      key = opts.follow_cursor.letter_key .. " / " .. opts.follow_cursor.toggle_key,
      text = "Follow code cursor [" .. (opts.follow_cursor.enabled and "on" or "off") .. "]",
    },
    {
      key = (opts.preview.toggle_key or "p") .. " / <C-o>",
      text = "Symbol preview [" .. (opts.preview.highlight_on_move and "on" or "off") .. "]",
    },
    {
      key = opts.jump.toggle_key,
      text = opts.jump.enabled
          and ("Jump letters [" .. (require("namu.selecta.jump").is_active(panel) and "on" or "off") .. "]")
        or "Jump letters disabled",
    },
    {},
    { section = "BOOKMARKS" },
    { key = "m", text = "Add the selected symbol to favorites" },
  }
  if panel.name == "favorites" then
    entries[#entries + 1] = { key = "dd", text = "Remove the selected favorite" }
  end
  vim.list_extend(entries, {
    {},
    { section = "SEARCH FILTERS" },
    { key = "/fn", text = "Functions and constructors" },
    { key = "/me", text = "Methods" },
    { key = "/mo", text = "Modules and packages" },
    { key = "/cl", text = "Classes, interfaces and structures" },
    { key = "/fnrender", text = "Search within a symbol kind" },
    {},
    { hint = "Escape, q or g? closes this help." },
    { hint = "Control keys also work while searching; letters work in normal mode." },
  })
  local key_width = 0
  for _, entry in ipairs(entries) do
    key_width = math.max(key_width, api.nvim_strwidth(entry.key or ""))
  end
  local lines = {}
  local content_width = 0
  for _, entry in ipairs(entries) do
    local line = entry.section and ("  " .. entry.section)
      or entry.key and ("  " .. entry.key .. string.rep(" ", key_width - api.nvim_strwidth(entry.key) + 3) .. entry.text)
      or entry.hint and ("  " .. entry.hint)
      or ""
    lines[#lines + 1] = line
    content_width = math.max(content_width, api.nvim_strwidth(line))
  end
  local return_win = api.nvim_get_current_win()
  local insert = api.nvim_get_mode().mode:match("^i") ~= nil
  vim.cmd("stopinsert")
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "namu_help"
  vim.bo[buf].swapfile = false
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = math.max(1, math.min(content_width + 2, vim.o.columns - 6))
  local height = math.max(1, math.min(#lines, vim.o.lines - vim.o.cmdheight - 6))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Namu shortcuts ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    zindex = 70,
  })
  panel.help = { win = win, buf = buf, return_win = return_win, insert = insert }
  vim.wo[win].winhighlight = "Normal:NamuHelp,FloatBorder:NamuHelpBorder,FloatTitle:NamuHelpTitle"
  vim.wo[win].wrap = true
  vim.wo[win].spell = false
  local ns = api.nvim_create_namespace("namu_sidebar_help")
  for row, entry in ipairs(entries) do
    if entry.section or entry.key or entry.hint then
      api.nvim_buf_set_extmark(buf, ns, row - 1, 2, {
        end_col = entry.key and (2 + #entry.key) or #lines[row],
        hl_group = entry.section and "NamuHelpTitle" or entry.key and "NamuHelpKey" or "NamuHelpHint",
      })
    end
  end
  for _, key in ipairs({ "<Esc>", "q", "g?" }) do
    vim.keymap.set("n", key, function()
      M.close(panel)
    end, { buffer = buf, silent = true, nowait = true })
  end
  api.nvim_create_autocmd("WinClosed", {
    group = panel.group,
    pattern = tostring(win),
    once = true,
    callback = function()
      if panel.help and panel.help.win == win then
        panel.help = nil
      end
    end,
  })
end

return M
