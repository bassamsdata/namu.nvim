local M = {}
local logger = require("namu.utils.logger")

-- Internal state for UI operations
local state = {
  preview_ns = vim.api.nvim_create_namespace("namu_preview"),
}
local MAX_PREVIEW_SIZE = 524288 -- 512KB
local LINES_AROUND_SYMBOL = 100 -- +/- lines to load

local ns_id = vim.api.nvim_create_namespace("namu_symbols")

function M.setup_highlights()
  local highlights = {
    NamuPrefixSymbol = { link = "@Comment" },
    NamuSymbolFunction = { link = "@function" },
    NamuSymbolMethod = { link = "@function.method" },
    NamuSymbolClass = { link = "@lsp.type.class" },
    NamuSymbolInterface = { link = "@lsp.type.interface" },
    NamuSymbolVariable = { link = "@lsp.type.variable" },
    NamuSymbolConstant = { link = "@lsp.type.constant" },
    NamuSymbolProperty = { link = "@lsp.type.property" },
    NamuSymbolField = { link = "@lsp.type.field" },
    NamuSymbolEnum = { link = "@lsp.type.enum" },
    NamuSymbolModule = { link = "@lsp.type.module" },
  }

  for name, attrs in pairs(highlights) do
    vim.api.nvim_set_hl(0, name, attrs)
  end
end

function M.clear_preview_highlight(win, ns_id)
  if ns_id then
    local bufnr = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
end

-- Style options for nested items
---@param depth number
---@param style number 1: Just indentation, 2: Dot style, 3: Arrow style
---@return string
function M.get_prefix(depth, style)
  local prefix = depth == 0 and ""
    or (
      style == 1 and string.rep("  ", depth)
      or style == 2 and string.rep("  ", depth - 1) .. ".."
      or style == 3 and string.rep("  ", depth - 1) .. " →"
      or string.rep("  ", depth)
    )

  return prefix
end

---Finds index of symbol at current cursor position
---@param items SelectaItem[] The filtered items list
---@param symbol SelectaItem table The symbol to find
---@return number|nil index The index of the symbol if found
function M.find_symbol_index(items, symbol, is_ctags)
  if is_ctags then
    -- TODO: make it more robust
    -- For CTags, just match by name and line number (ignore column)
    for i, item in ipairs(items) do
      if item.value.lnum == symbol.value.lnum and item.value.name == symbol.value.name then
        return i
      end
    end
    -- If no exact match, try matching just by line number
    for i, item in ipairs(items) do
      if item.value.lnum == symbol.value.lnum then
        return i
      end
    end
    -- If still no match, try matching just by name
    for i, item in ipairs(items) do
      if item.value.name == symbol.value.name then
        return i
      end
    end

    logger.log("find_symbol_index() - No match found for CTags symbol")
    return nil
  end

  -- Standard matching for LSP symbols
  for i, item in ipairs(items) do
    if
      item.value.lnum == symbol.value.lnum
      and item.value.col == symbol.value.col
      and item.value.name == symbol.value.name
    then
      return i
    end
  end
  return nil
end

---Traverses syntax tree to find significant nodes for better symbol context
---@param node TSNode The treesitter node
---@param lnum number The line number (0-based)
---@return TSNode|nil
function M.find_meaningful_node(node, lnum)
  if not node then
    return nil
  end

  local filetype = vim.o.filetype
  -- NOTE: we need to account if the fucntion at the start of the file make lnum = lunm + 1
  -- this solved many issue except teh decorator below.
  if filetype == "python" then
    lnum = lnum + 1
  end

  local function starts_at_line(n)
    local start_row = select(1, n:range())
    return start_row == lnum
  end

  local current = node
  local target_node = node
  local parent_node = node:parent()
  -- Walk up to find the deepest node starting at lnum, stopping before root
  while current and starts_at_line(current) and current:parent() do
    target_node = current
    ---@diagnostic disable-next-line: undefined-field
    current = current:parent()
  end
  -- If target_node is root, use the initial node instead
  if not target_node:parent() then
    target_node = node
  end
  ---@diagnostic disable-next-line: undefined-field
  local type = target_node:type()

  -- HACK: if there is  decorator, catch the whole decorator which is
  -- "decorated_definition".
  if filetype == "python" and type == "decorator" then
    return parent_node
  end
  if type == "function_definition" then
    return node
  end

  if type == "assignment_statement" then
    ---@diagnostic disable-next-line: undefined-field
    local expr_list = target_node:field("rhs")[1]
    if expr_list then
      for i = 0, expr_list:named_child_count() - 1 do
        local child = expr_list:named_child(i)
        if child and child:type() == "function_definition" then
          return target_node
        end
      end
    end
  end

  if type == "local_function" or type == "function_declaration" then
    return target_node
  end

  if type == "local_declaration" then
    ---@diagnostic disable-next-line: undefined-field
    local values = target_node:field("values")
    if values and values[1] and values[1]:type() == "function_definition" then
      return target_node
    end
  end

  if type == "method_definition" then
    return target_node
  end

  return target_node
end

---Handles visual highlighting of selected symbols in preview
---@param symbol table LSP symbol item
---@param win number Window handle
function M.highlight_symbol(symbol, win, ns_id)
  local picker_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)

  local bufnr = vim.api.nvim_win_get_buf(win)

  local saved_eventignore = vim.o.eventignore
  vim.o.eventignore = "BufEnter,WinEnter,BufWinEnter"
  -- Handle symbols from different files
  if symbol.uri and symbol.uri ~= vim.uri_from_bufnr(bufnr) then
    -- Try to find if the buffer is already loaded
    local target_bufnr
    local filepath = symbol.file_path or vim.uri_to_fname(symbol.uri)

    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == filepath then
        target_bufnr = buf
        break
      end
    end

    -- If not found, create a new buffer for preview
    if not target_bufnr then
      target_bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(target_bufnr, filepath)

      -- Try to load file content
      local ok, file_content = pcall(vim.fn.readfile, filepath)
      if ok and file_content then
        vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, file_content)

        -- Set filetype for syntax highlighting
        local ft = vim.filetype.match({ filename = filepath })
        if ft then
          vim.api.nvim_set_option_value("filetype", ft, { buf = target_bufnr })
        end
      else
        -- If can't load file, create a placeholder
        vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, {
          "-- File not available: " .. filepath,
          "-- Symbol: " .. (symbol.name or "unknown") .. " at line " .. (symbol.lnum or "?"),
        })
      end
    end

    -- NOTE: nvim_win_set_buf is always adding preview to jumplist
    -- so this is becomes a hack, not sure if using eventignore could play part
    -- and might revert to nvim_win_set_buf function later.
    -- Switch to the new buffer temporarily
    vim.api.nvim_set_current_win(win)
    vim.cmd("keepjumps buffer " .. target_bufnr)
    vim.api.nvim_set_current_win(picker_win)

    -- Schedule return to original buffer
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_set_current_win(win)
        vim.cmd("keepjumps buffer " .. bufnr)
        vim.api.nvim_set_current_win(picker_win)
      end
    end)

    -- Update bufnr for highlighting
    bufnr = target_bufnr
  end

  -- Clear any existing highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Make sure the buffer and line number are valid
  if not vim.api.nvim_buf_is_valid(bufnr) or symbol.lnum < 1 then
    vim.api.nvim_set_current_win(picker_win)
    return
  end

  -- Make sure the line exists in the buffer
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if symbol.lnum > line_count then
    vim.api.nvim_set_current_win(picker_win)
    return
  end

  -- Get the line content safely
  local line = vim.api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.lnum, false)[1]
  if not line then
    vim.api.nvim_set_current_win(picker_win)
    return
  end

  local first_char_col = line:find("%S")
  if not first_char_col then
    vim.api.nvim_set_current_win(picker_win)
    return
  end
  first_char_col = first_char_col - 1

  -- Try to use treesitter for better highlighting
  local has_ts, node = pcall(vim.treesitter.get_node, {
    pos = { symbol.lnum - 1, first_char_col },
    bufnr = bufnr,
    ignore_injections = false,
  })

  if has_ts and node then
    logger.log("highlight_symbol() - before finding meaningful node, its type is: " .. node:type())
    node = M.find_meaningful_node(node, symbol.lnum - 1)
  end

  if has_ts and node then
    local srow, scol, erow, ecol = node:range()
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, srow, 0, {
      end_row = erow,
      end_col = ecol,
      hl_group = M.config.highlight,
      hl_eol = true,
      priority = 1,
      strict = false,
    })

    vim.api.nvim_win_set_cursor(win, { srow + 1, scol })
    vim.api.nvim_win_call(win, function()
      vim.cmd("keepjumps normal! zz")
    end)
  else
    -- Fallback: just highlight the line
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, symbol.lnum - 1, 0, {
      end_line = symbol.lnum,
      hl_group = M.config.highlight,
      hl_eol = true,
      priority = 1,
    })

    -- Set cursor to the symbol position
    vim.api.nvim_win_set_cursor(win, { symbol.lnum, first_char_col })
    vim.api.nvim_win_call(win, function()
      vim.cmd("keepjumps normal! zz")
    end)
  end

  vim.api.nvim_set_current_win(picker_win)
  vim.o.eventignore = saved_eventignore
end

-- Apply consistent highlighting to formatted items in the buffer
---@param buf number Buffer handle
---@param items table[] List of items to highlight
---@param config table Configuration with highlight and display settings
function M.apply_highlights(buf, items, config)
  local namu_ns_id = vim.api.nvim_create_namespace("namu_formatted_highlights")
  vim.api.nvim_buf_clear_namespace(buf, namu_ns_id, 0, -1)

  -- Highlight group for tree guides and prefix symbols
  local guide_hl = "Comment" -- config.highlights and config.highlights.guides or
  local prefix_symbol_hl = "Comment" -- config.highlights and config.highlights.prefix_symbol or

  for idx, item in ipairs(items) do
    local line = idx - 1
    local lines = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)
    if #lines == 0 then
      goto continue
    end

    local line_text = lines[1]
    local kind = item.kind
    local kind_hl = config.kinds.highlights[kind] or "Identifier"

    -- 1. Apply base highlight to the whole line (lower priority)
    vim.api.nvim_buf_set_extmark(buf, namu_ns_id, line, 0, {
      end_row = line,
      end_col = #line_text,
      hl_group = kind_hl,
      hl_mode = "combine",
      priority = 200,
    })

    -- 2. Highlight tree guides with higher priority
    if config.display.format == "tree_guides" then
      local guide_style = (config.display.tree_guides and config.display.tree_guides.style) or "unicode"
      local chars = {
        ascii = { "|", "`-", "|-" },
        unicode = { "┆", "└─", "├─" },
      }
      local style_chars = chars[guide_style] or chars.unicode

      -- Find and highlight all occurrences of tree guide characters
      for _, pattern in ipairs(style_chars) do
        -- Log the pattern and its byte representation
        local bytes = {}
        for i = 1, #pattern do
          table.insert(bytes, string.byte(pattern, i))
        end

        local start_pos = 0

        -- Find all occurrences of this pattern in the line
        while true do
          local pattern_pos = line_text:find(pattern, start_pos + 1, true)
          if not pattern_pos then
            break
          end

          -- Get the exact character at this position in the line
          local actual_char = line_text:sub(pattern_pos, pattern_pos + #pattern - 1)
          local actual_bytes = {}
          for i = 1, #actual_char do
            table.insert(actual_bytes, string.byte(actual_char, i))
          end
          -- Calculate visual width properly
          local visual_width = vim.api.nvim_strwidth(pattern)

          -- Try highlighting with a slightly expanded range
          vim.api.nvim_buf_set_extmark(buf, ns_id, line, pattern_pos - 1, {
            end_row = line,
            end_col = pattern_pos - 1 + #pattern, -- Use byte length instead of visual width
            hl_group = guide_hl,
            priority = 201,
          })

          -- Move past this occurrence
          start_pos = pattern_pos
        end
      end
    elseif config.display.format == "indent" then
      -- Handle indent formatting symbols
      local depth = item.depth or 0
      if depth > 0 then
        local style = tonumber(config.display.style) or 2
        local prefix_symbol = ""

        if style == 2 then
          prefix_symbol = ".."
        elseif style == 3 then
          prefix_symbol = "→"
        end

        if prefix_symbol ~= "" then
          local symbol_pos = line_text:find(prefix_symbol, 1, true)
          if symbol_pos then
            vim.api.nvim_buf_set_extmark(buf, namu_ns_id, line, symbol_pos - 1, {
              end_row = line,
              end_col = symbol_pos - 1 + #prefix_symbol,
              hl_group = prefix_symbol_hl,
              priority = 201,
            })
          end
        end
      end
    end

    -- 3. Highlight the file info with higher priority (if present)
    if item.value and item.value.file_info then
      local file_info = item.value.file_info
      local file_pos = line_text:find(file_info, 1, true)
      if file_pos then
        vim.api.nvim_buf_set_extmark(buf, namu_ns_id, line, file_pos - 1, {
          end_row = line,
          end_col = file_pos - 1 + #file_info,
          hl_group = "NamuFileInfo",
          priority = 201,
        })
      end
    end

    ::continue::
  end
end

-- Initialize UI module with config
function M.setup(config)
  M.config = config
end

return M
