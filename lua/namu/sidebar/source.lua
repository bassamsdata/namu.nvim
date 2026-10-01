local M = {}
local api = vim.api

local function is_active(panel)
  return panel.active and panel.opts.follow_buffer and require("namu.sidebar").get(panel.name) == panel
end

---Refresh a symbol sidebar from its current code window.
---@param panel table
---@param source_win? number
---@return nil
function M.refresh(panel, source_win)
  if not is_active(panel) then
    return
  end
  source_win = source_win or panel.original_win
  if not api.nvim_win_is_valid(source_win) then
    return
  end
  local bufnr = api.nvim_win_get_buf(source_win)
  if vim.bo[bufnr].buftype ~= "" then
    return
  end
  local sidebar = require("namu.sidebar")
  if panel.original_buf ~= bufnr or panel.original_win ~= source_win then
    sidebar.set_source(panel.name, bufnr, source_win)
  end
  panel.source_generation = (panel.source_generation or 0) + 1
  local request = panel.source_generation
  require("namu.namu_symbols").fetch_symbols(bufnr, function(items)
    vim.schedule(function()
      if not is_active(panel) or panel.source_generation ~= request then
        return
      end
      if
        not api.nvim_buf_is_valid(bufnr)
        or panel.original_buf ~= bufnr
        or panel.original_win ~= source_win
        or not api.nvim_win_is_valid(source_win)
        or api.nvim_win_get_buf(source_win) ~= bufnr
      then
        return
      end
      sidebar.update(panel.name, items or {})
    end)
  end)
end

local function schedule_refresh(panel, win)
  panel.source_refresh_win = win
  -- Invalidate older results immediately, and coalesce BufEnter with WinEnter.
  panel.source_generation = (panel.source_generation or 0) + 1
  if panel.source_refresh_pending then
    return
  end
  panel.source_refresh_pending = true
  vim.schedule(function()
    panel.source_refresh_pending = false
    M.refresh(panel, panel.source_refresh_win)
  end)
end

---Attach buffer tracking to a symbol sidebar.
---@param panel table
---@return nil
function M.attach(panel)
  if panel.source_attached then
    return
  end
  panel.source_attached = true
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = panel.group,
    callback = function()
      if not is_active(panel) or panel.previewing then
        return
      end
      local win = api.nvim_get_current_win()
      if win == panel.win or win == panel.prompt_win then
        return
      end
      local bufnr = api.nvim_win_get_buf(win)
      if vim.bo[bufnr].buftype ~= "" or api.nvim_win_get_config(win).relative ~= "" then
        return
      end
      if win ~= panel.original_win or bufnr ~= panel.original_buf then
        schedule_refresh(panel, win)
      end
    end,
  })
  api.nvim_create_autocmd({ "BufWritePost", "LspAttach" }, {
    group = panel.group,
    callback = function(args)
      if not is_active(panel) or panel.previewing or not api.nvim_win_is_valid(panel.original_win) then
        return
      end
      if args.buf == api.nvim_win_get_buf(panel.original_win) then
        schedule_refresh(panel, panel.original_win)
      end
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = panel.group,
    callback = function(args)
      if not is_active(panel) or args.buf ~= panel.original_buf then
        return
      end
      panel.source_generation = (panel.source_generation or 0) + 1
      vim.schedule(function()
        if not is_active(panel) then
          return
        end
        if api.nvim_win_is_valid(panel.original_win) then
          local bufnr = api.nvim_win_get_buf(panel.original_win)
          if bufnr ~= args.buf and vim.bo[bufnr].buftype == "" then
            M.refresh(panel)
            return
          end
        end
        require("namu.sidebar").close(panel.name)
      end)
    end,
  })
end

return M
