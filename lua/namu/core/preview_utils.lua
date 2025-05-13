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
  preview_state.original_buf = vim.api.nvim_win_get_buf(win_id)
  preview_state.original_pos = vim.api.nvim_win_get_cursor(win_id)
  preview_state.original_view = vim.api.nvim_win_call(win_id, function()
    return vim.fn.winsaveview()
  end)
end

function M.restore_window_state(win_id, preview_state)
  if not preview_state.original_buf then
    return
  end

  local cache_eventignore = vim.o.eventignore
  vim.o.eventignore = "all"

  pcall(function()
    if vim.api.nvim_buf_is_valid(preview_state.original_buf) then
      vim.api.nvim_set_current_win(win_id)
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

local function apply_preview_to_window(bufnr, win_id, lnum, col, options, preview_state, item)
  vim.api.nvim_win_call(win_id, function()
    vim.api.nvim_win_set_buf(win_id, bufnr)
    local cursor_line = lnum
    if options.line_index_offset then
      cursor_line = cursor_line + options.line_index_offset
    else
      cursor_line = cursor_line + 1
    end
    vim.api.nvim_win_set_cursor(win_id, { cursor_line, col })
    vim.cmd("normal! zz")
    vim.api.nvim_buf_clear_namespace(bufnr, preview_state.preview_ns, 0, -1)
    local hl_group = options.highlight_group or "NamuPreview"
    local highlight_line = lnum
    if options.highlight_line_offset then
      highlight_line = highlight_line + options.highlight_line_offset
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, preview_state.preview_ns, highlight_line, 0, {
      end_row = highlight_line + 1,
      hl_eol = true,
      hl_group = hl_group,
      priority = 100,
    })
    if options.highlight_fn and type(options.highlight_fn) == "function" then
      options.highlight_fn(bufnr, preview_state.preview_ns, item)
    end
  end)
end

function M.preview_symbol(item, win_id, preview_state, options)
  if not item or not item.value then
    logger.log("Invalid item for preview")
    return
  end

  local value = item.value
  local bufnr = value.bufnr
  local file_path = value.file_path or (bufnr and vim.api.nvim_buf_get_name(bufnr))
  if not file_path then
    logger.log("No file path in item")
    return
  end

  local lnum = value.lnum or 0
  local col = value.col or 0
  local name = value.name or item.text
  options = options or {}

  local cache_eventignore = vim.o.eventignore
  vim.o.eventignore = "BufEnter"
  -- If buffer is valid and loaded, use it directly
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    apply_preview_to_window(bufnr, win_id, lnum, col, options, preview_state, item)
    vim.o.eventignore = cache_eventignore
    return
  end

  -- Otherwise, fallback to scratch buffer and async file read
  if not preview_state.scratch_buf or not vim.api.nvim_buf_is_valid(preview_state.scratch_buf) then
    preview_state.scratch_buf = M.create_scratch_buffer()
  end

  M.readfile_async(file_path, function(ok, lines)
    if not ok or not lines then
      logger.log("Failed to read file: " .. file_path)
      vim.o.eventignore = cache_eventignore
      return
    end

    vim.api.nvim_buf_set_lines(preview_state.scratch_buf, 0, -1, false, lines)
    local ft = vim.filetype.match({ filename = file_path })
    if ft then
      vim.bo[preview_state.scratch_buf].filetype = ft
      if preview_state.scratch_buf and vim.api.nvim_buf_is_valid(preview_state.scratch_buf) then
        pcall(function()
          local has_parser, parser = pcall(vim.treesitter.get_parser, preview_state.scratch_buf, ft)
          if has_parser and parser then
            parser:parse()
          end
        end)
      end
    end

    apply_preview_to_window(preview_state.scratch_buf, win_id, lnum, col, options, preview_state, item)
    vim.o.eventignore = cache_eventignore
  end)
end

function M.edit_file(path, win_id)
  if type(path) ~= "string" then
    logger.log("Invalid path type")
    return
  end
  local b = vim.api.nvim_win_get_buf(win_id or 0)
  -- TODO: name teh scratch_buf and remove maybe this
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
  pcall(vim.api.nvim_set_current_win, win_id)

  vim.bo[buf_id].buflisted = true

  if try_mimic_buf_reuse then
    pcall(vim.api.nvim_buf_delete, b, { unload = false })
    logger.log("Deleted old empty buffer")
  end

  return buf_id
end

return M
