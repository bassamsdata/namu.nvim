local M = {}
local logger = require("namu.utils.logger")

function M.readfile_async(path, callback)
  local co = coroutine.create(function()
    -- Wrap the blocking readfile in a protected call.
    local ok, lines = pcall(vim.fn.readfile, path)
    -- Pass the result to the provided callback.
    callback(ok, lines)
  end)
  -- Start the coroutine.
  coroutine.resume(co)
end

function M.create_preview_state(namespace)
  namespace = namespace or "namu_preview"
  logger.log("Creating new preview state for " .. namespace)
  return {
    original_win = nil,
    original_buf = nil,
    original_pos = nil,
    original_view = nil,
    preview_ns = vim.api.nvim_create_namespace(namespace .. "_" .. vim.fn.rand()),
    scratch_buf = nil,
  }
end

-- TODO: might need to set name for it with prefix like "Namu_Preview://"
function M.create_scratch_buffer()
  logger.log("Creating scratch buffer for preview")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].matchpairs = ""
  return buf
end

function M.save_window_state(win_id, preview_state)
  logger.log("Saving window state for win_id: " .. win_id)
  preview_state.original_buf = vim.api.nvim_win_get_buf(win_id)
  preview_state.original_pos = vim.api.nvim_win_get_cursor(win_id)
  preview_state.original_view = vim.api.nvim_win_call(win_id, function()
    return vim.fn.winsaveview()
  end)
end

function M.restore_window_state(win_id, preview_state)
  logger.log("Restoring window state for win_id: " .. win_id)
  if not preview_state.original_buf then
    return
  end

  local cache_eventignore = vim.o.eventignore
  vim.o.eventignore = "all"

  pcall(function()
    if vim.api.nvim_buf_is_valid(preview_state.original_buf) then
      vim.api.nvim_win_set_buf(win_id, preview_state.original_buf)
    end

    if preview_state.original_pos then
      vim.api.nvim_win_set_cursor(win_id, preview_state.original_pos)
    end

    -- TEST: I think this is becomeing redundunt
    if preview_state.original_view then
      vim.api.nvim_win_call(win_id, function()
        vim.fn.winrestview(preview_state.original_view)
      end)
    end
  end)

  vim.o.eventignore = cache_eventignore
end

-- Get buffer for a file path if it exists
function M.get_buffer_for_path(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local buf_path = vim.api.nvim_buf_get_name(bufnr)
      if buf_path == path then
        return bufnr
      end
    end
  end
  return nil
end

function M.edit_file(path, win_id)
  logger.log(string.format("Editing file: %s in window: %s", path, win_id))
  if type(path) ~= "string" then
    logger.log("Invalid path type")
    return
  end

  local b = vim.api.nvim_win_get_buf(win_id or 0)
  local try_mimic_buf_reuse = (vim.fn.bufname(b) == "" and vim.bo[b].buftype ~= "quickfix" and not vim.bo[b].modified)
    and (#vim.fn.win_findbuf(b) == 1 and vim.deep_equal(vim.fn.getbufline(b, 1, "$"), { "" }))

  if try_mimic_buf_reuse then
    logger.log("Will try to reuse empty buffer")
  end

  local buf_id = vim.fn.bufadd(vim.fn.fnamemodify(path, ":."))
  logger.log("Created/got buffer: " .. buf_id)

  -- Set buffer in window (also loads it)
  local ok, err = pcall(vim.api.nvim_win_set_buf, win_id or 0, buf_id)
  if not ok then
    logger.log("Failed to set buffer: " .. err)
    return
  end

  vim.bo[buf_id].buflisted = true

  if try_mimic_buf_reuse then
    pcall(vim.api.nvim_buf_delete, b, { unload = false })
    logger.log("Deleted old empty buffer")
  end

  return buf_id
end

return M
