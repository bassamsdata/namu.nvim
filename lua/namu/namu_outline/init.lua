-- Copyright (c) 2025 Bassam Data. Licensed under the MIT License.
local M = {}
local sidebar = require("namu.sidebar")
local api = vim.api
local config = {}

---Refresh symbols in place, ignoring stale requests and closed sidebars.
---@param source_win? number Code window to adopt after a buffer or split switch
---@return nil
function M.refresh(source_win)
  local panel = sidebar.get("outline")
  if panel then
    require("namu.sidebar.source").refresh(panel, source_win)
  end
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
    follow_buffer = true,
    title = "Outline",
    storage_key = "outline:" .. api.nvim_buf_get_name(source_buf),
    initial_line = api.nvim_win_get_cursor(source_win)[1],
  })
  sidebar.open({}, opts, { original_win = source_win, original_buf = source_buf })
end

---Close the outline and save its state.
---@return nil
function M.close()
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
