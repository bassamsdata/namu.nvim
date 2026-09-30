-- Copyright (c) 2025 Bassam Data. Licensed under the MIT License.
local M = {}
local sidebar = require("namu.sidebar")
local api = vim.api
local generation = 0
local config = {}

---Refresh symbols in place, ignoring stale requests and closed sidebars.
---@return nil
function M.refresh()
  local panel = sidebar.get("outline")
  if not panel or not panel.active then
    return
  end
  if not api.nvim_win_is_valid(panel.original_win) then
    return
  end
  local bufnr = api.nvim_win_get_buf(panel.original_win)
  if vim.bo[bufnr].buftype ~= "" then
    return
  end
  if panel.original_buf ~= bufnr then
    sidebar.set_source("outline", bufnr)
  end
  generation = generation + 1
  local request = generation
  require("namu.namu_symbols").fetch_symbols(bufnr, function(items)
    vim.schedule(function()
      if generation ~= request or sidebar.get("outline") ~= panel or not panel.active then
        return
      end
      if not api.nvim_buf_is_valid(bufnr) or panel.original_buf ~= bufnr then
        return
      end
      sidebar.update("outline", items or {})
    end)
  end)
end

---Open a persistent searchable outline for the current code window.
---@param opts? table
---@return nil
function M.open(opts)
  local panel = sidebar.get("outline")
  if panel then
    api.nvim_set_current_win(panel.win)
    return
  end
  local source_win = sidebar.source_window()
  local source_buf = api.nvim_win_get_buf(source_win)
  opts = vim.tbl_deep_extend("force", config, opts or {}, {
    name = "outline",
    title = "Outline",
    storage_key = "outline:" .. api.nvim_buf_get_name(source_buf),
    initial_line = api.nvim_win_get_cursor(source_win)[1],
  })
  panel = sidebar.open({}, opts, { original_win = source_win, original_buf = source_buf })
  api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "LspAttach" }, {
    group = panel.group,
    callback = function(args)
      if not panel.active or not api.nvim_win_is_valid(panel.original_win) then
        return
      end
      if args.buf == api.nvim_win_get_buf(panel.original_win) then
        vim.schedule(M.refresh)
      end
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = panel.group,
    callback = function(args)
      if args.buf == panel.original_buf then
        M.close()
      end
    end,
  })
  M.refresh()
end

---Close the outline and save its state.
---@return nil
function M.close()
  generation = generation + 1
  sidebar.close("outline")
end

---Toggle the outline sidebar.
---@return nil
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

---Focus the outline list.
---@return nil
function M.focus()
  local panel = sidebar.get("outline")
  if panel then
    api.nvim_set_current_win(panel.win)
  end
end

---Focus the code window.
---@return nil
function M.focus_code()
  sidebar.focus_code("outline")
end

---Check whether the outline is open.
---@return boolean
function M.is_open()
  local panel = sidebar.get("outline")
  return panel ~= nil and panel.active and api.nvim_win_is_valid(panel.win)
end

---Configure the outline sidebar.
---@param opts? table
---@return nil
function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

return M
