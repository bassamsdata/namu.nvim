local M = {}

-- Get file icon for the file path
function M.get_file_icon(file_path)
  -- Extract the file name from the path
  local filename = vim.fs.basename(file_path)
  local extension = filename:match("%.([^%.]+)$")

  -- Try to get icon from mini.icons
  local icon, icon_hl, is_default
  local mini_icons_ok, mini_icons = pcall(require, "mini.icons")
  if mini_icons_ok then
    -- First try with exact filename
    icon, icon_hl, is_default = mini_icons.get("file", filename)

    -- If it's a default icon and we have an extension, try by extension
    if is_default and extension then
      local ext_icon, ext_hl, ext_is_default = mini_icons.get("extension", extension)
      if not ext_is_default then
        icon, icon_hl = ext_icon, ext_hl
      end
    end
  else
    -- Fall back to nvim-web-devicons
    local devicons_ok, devicons = pcall(require, "nvim-web-devicons")
    if devicons_ok then
      local dev_icon, dev_hl = devicons.get_icon(filename, extension, { default = true })
      if dev_icon then
        icon, icon_hl = dev_icon, dev_hl
      end
    end
  end

  -- If we still don't have an icon, provide a safe default
  if not icon then
    icon = "󰈔" -- Default file icon
    icon_hl = "Normal"
  end

  return icon, icon_hl
end

--- Determines if a buffer is considered "big" based on size thresholds
--- @param bufnr? number Buffer number (uses current buffer if nil)
--- @param opts? {line_threshold?: number|false, byte_threshold_mb?: number|false, long_line_threshold?: number|false}
---   Configuration options with thresholds:
---   - line_threshold: Maximum number of lines (default: 10000, false to disable)
---   - byte_threshold_mb: Maximum file size in MB (default: 1MB, false to disable)
---   - long_line_threshold: Maximum line length (default: 1000, false to disable)
--- @return boolean Whether the buffer is considered big
function M.is_big_buffer(bufnr, opts)
  -- Handle parameters
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}

  -- Set defaults with clear variable names
  local max_lines = opts.line_threshold
  if max_lines == nil then
    max_lines = 10000
  end

  local max_mb = opts.byte_threshold_mb
  if max_mb == nil then
    max_mb = 1
  end -- Default 1MB

  -- Convert MB to bytes internally
  local max_bytes = max_mb ~= false and (max_mb * 1024 * 1024) or false

  local max_line_length = opts.long_line_threshold
  if max_line_length == nil then
    max_line_length = 1000
  end

  -- 1. Check line count
  if max_lines ~= false then
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line_count > max_lines then
      return true
    end
  end

  -- 2. Check file size
  if max_bytes ~= false then
    local filepath = vim.api.nvim_buf_get_name(bufnr)
    if filepath and filepath ~= "" then
      local stat = vim.uv.fs_stat(filepath)
      if stat and stat.size > max_bytes then
        return true
      end
    end
  end

  -- 3. Check for long lines
  if max_line_length ~= false then
    -- Only sample the first 100 lines for efficiency
    local lines_to_check = math.min(100, vim.api.nvim_buf_line_count(bufnr))
    local sample_lines = vim.api.nvim_buf_get_lines(bufnr, 0, lines_to_check, false)

    for _, line in ipairs(sample_lines) do
      if #line > max_line_length then
        return true
      end
    end
  end

  -- Buffer is not considered big by any criteria
  return false
end

-- Cache frequently used patterns
local NON_TEST_NAME_PATTERN = "^([^%s%(]+)"
local MARKDOWN_LINE_PATTERN = "^([^\n\r]+)" -- this is for markdown lsp returns multiline sometime
---Clean symbol name for display, handling special cases for different filetypes
---@param name string Original symbol name
---@param filetype string|nil File type
---@param is_test_file boolean Whether this is a test file
---@return string Cleaned name
function M.clean_symbol_name(name, filetype, is_test_file)
  if not name then
    return ""
  end

  if is_test_file then
    return name
  end

  if filetype == "markdown" then
    return name:match(MARKDOWN_LINE_PATTERN) or name
  end

  return name:match(NON_TEST_NAME_PATTERN) or name
end

--- Modified highlighting function that uses is_big_buffer
--- @param symbol table LSP symbol item
--- @param win number Window handle
--- @param ns_id number Namespace ID for highlighting
function M.highlight_symbol(symbol, win, ns_id)
  local bufnr = vim.api.nvim_win_get_buf(win)

  -- Use nvim_win_call to execute all window-related operations
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

    -- Skip complex highlighting for big buffers
    if M.is_big_buffer(bufnr) then
      -- Simple line highlighting for big files
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, symbol.lnum - 1, 0, {
        end_row = symbol.lnum - 1,
        hl_group = M.config.highlight,
        hl_eol = true,
        priority = 1,
      })

      -- Set cursor position
      vim.api.nvim_win_set_cursor(win, { symbol.lnum, 0 })
      vim.cmd("normal! zz")
      return
    end

    -- Regular highlighting with treesitter for normal files
    local line = vim.api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.lnum, false)[1]
    local first_char_col = line:find("%S")
    if not first_char_col then
      return
    end

    first_char_col = first_char_col - 1
    local node = vim.treesitter.get_node({
      pos = { symbol.lnum - 1, first_char_col },
      ignore_injections = false,
    })

    if node then
      node = M.find_meaningful_node(node, symbol.lnum - 1)
    end

    if node then
      local srow, scol, erow, ecol = node:range()
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, srow, 0, {
        end_row = erow,
        end_col = ecol,
        hl_group = M.config.highlight,
        hl_eol = true,
        priority = 1,
        strict = false,
      })

      -- Set cursor position in this window
      vim.api.nvim_win_set_cursor(win, { srow + 1, scol })
      vim.cmd("normal! zz")
    end
  end)
end

---Restore focus and cursor position
---@param win_id number Window ID
---@param cursor_pos table Cursor position
---@return nil
function M.restore_focus_and_cursor(win_id, cursor_pos)
  if win_id and vim.api.nvim_win_is_valid(win_id) then
    pcall(vim.api.nvim_set_current_win, win_id)
  end
  if cursor_pos then
    pcall(vim.api.nvim_win_set_cursor, win_id, cursor_pos)
  end
end

return M
