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
--- @param bufnr number|nil Buffer number (uses current buffer if nil)
--- @return boolean Whether the buffer is considered big
function M.is_big_buffer(bufnr, line_threshold, byte_threshold)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Size thresholds
  line_threshold = line_threshold or 10000 -- Lines above which a file is considered big
  byte_threshold = byte_threshold or 1000000 -- ~1MB
  -- Check line count first (faster)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count > line_threshold then
    return true
  end
  -- Check file size if available
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath and filepath ~= "" then
    local stat = vim.loop.fs_stat(filepath)
    if stat and stat.size > byte_threshold then
      return true
    end
  end
  -- Additional heuristics
  -- Check if the buffer has very long lines
  local sample_lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(100, line_count), false)
  for _, line in ipairs(sample_lines) do
    if #line > 1000 then -- Very long line detected
      return true
    end
  end
  return false
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

return M
