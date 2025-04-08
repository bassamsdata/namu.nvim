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

function M.preview_symbol(item, win_id, preview_state, options)
  if not item or not item.value then
    logger.log("Invalid item for preview")
    return
  end

  local value = item.value
  local file_path = value.file_path
  if not file_path then
    logger.log("No file path in item")
    return
  end

  -- Get line and column info, with proper validation
  local lnum = value.lnum or 0
  local col = value.col or 0
  local name = value.name or item.text
  -- Make sure we have a valid scratch buffer
  if not preview_state.scratch_buf or not vim.api.nvim_buf_is_valid(preview_state.scratch_buf) then
    preview_state.scratch_buf = M.create_scratch_buffer()
  end

  local cache_eventignore = vim.o.eventignore
  vim.o.eventignore = "BufEnter"

  -- Read file content asynchronously
  M.readfile_async(file_path, function(ok, lines)
    if not ok or not lines then
      logger.log("Failed to read file: " .. file_path)
      vim.o.eventignore = cache_eventignore
      return
    end

    -- Set buffer content and options
    vim.api.nvim_buf_set_lines(preview_state.scratch_buf, 0, -1, false, lines)

    -- Set filetype for syntax highlighting
    local ft = vim.filetype.match({ filename = file_path })
    if ft then
      vim.bo[preview_state.scratch_buf].filetype = ft

      -- Try using treesitter if available
      if preview_state.scratch_buf and vim.api.nvim_buf_is_valid(preview_state.scratch_buf) then
        pcall(function()
          local has_parser, parser = pcall(vim.treesitter.get_parser, preview_state.scratch_buf, ft)
          if has_parser and parser then
            parser:parse()
          end
        end)
      end
    end

    -- Set scratch buffer in window
    vim.api.nvim_win_set_buf(win_id, preview_state.scratch_buf)

    -- IMPORTANT: Determine cursor position correctly
    -- For API calls like nvim_win_set_cursor, line numbers are 1-based
    -- But for extmarks, line numbers are 0-based
    local cursor_line = lnum
    if type(cursor_line) == "number" then
      -- Ensure the cursor line is 1-based for nvim_win_set_cursor
      if options and options.line_index_offset then
        cursor_line = cursor_line + options.line_index_offset
      else
        -- Default: assume lnum is 0-based and add 1 for API call
        cursor_line = cursor_line + 1
      end
    end

    vim.api.nvim_win_set_cursor(win_id, { cursor_line, col })
    vim.api.nvim_win_call(win_id, function()
      vim.cmd("normal! zz")
    end)

    -- Clear previous highlights
    vim.api.nvim_buf_clear_namespace(preview_state.scratch_buf, preview_state.preview_ns, 0, -1)

    -- Get highlight options
    options = options or {}
    local hl_group = options.highlight_group or "NamuPreview"

    -- Calculate highlight line (0-based for extmark API)
    local highlight_line = lnum
    if options and options.highlight_line_offset then
      highlight_line = highlight_line + options.highlight_line_offset
    end

    -- Always apply the main line highlight (0-based index for extmark API)
    pcall(vim.api.nvim_buf_set_extmark, preview_state.scratch_buf, preview_state.preview_ns, highlight_line, 0, {
      end_row = highlight_line + 1,
      hl_eol = true,
      hl_group = hl_group,
      priority = 100,
    })

    -- If the module provides a highlight_fn, call it to add module-specific highlighting
    if options.highlight_fn and type(options.highlight_fn) == "function" then
      options.highlight_fn(preview_state.scratch_buf, preview_state.preview_ns, item)
    end

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

  vim.bo[buf_id].buflisted = true

  if try_mimic_buf_reuse then
    pcall(vim.api.nvim_buf_delete, b, { unload = false })
    logger.log("Deleted old empty buffer")
  end

  return buf_id
end

return M
