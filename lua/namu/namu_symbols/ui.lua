local M = {}
local logger = require("namu.utils.logger")
local uv = vim.uv or vim.loop

-- Internal state for UI operations
local state = {
  preview_ns = vim.api.nvim_create_namespace("namu_preview"),
}

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

function M.cleanup_previews(state, restore_original)
  if not state then
    return
  end

  -- Clear any highlights
  if state.preview_ns then
    M.clear_preview_highlight(state.original_win, state.preview_ns)
  end

  -- Close any preview buffers
  if state.preview_buffers then
    for _, bufnr in ipairs(state.preview_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    state.preview_buffers = {}
  end

  -- Restore original buffer if requested and possible
  if
    restore_original
    and state.original_win
    and state.original_buf
    and vim.api.nvim_win_is_valid(state.original_win)
    and vim.api.nvim_buf_is_valid(state.original_buf)
  then
    vim.api.nvim_win_set_buf(state.original_win, state.original_buf)
    if state.original_pos then
      vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
    end
  end

  -- Reset preview state
  state.active_preview_buf = nil
  state.last_previewed_path = nil
  state.is_previewing = false
end

---Handles visual highlighting of selected symbols in preview
---@param symbol table LSP symbol item
---@param win number Window handle
---@param ns_id number Namespace ID for highlighting
function M.highlight_symbol(symbol, win, ns_id, state)
  local picker_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(win)

  local bufnr = vim.api.nvim_win_get_buf(win)
  local saved_eventignore = vim.o.eventignore
  vim.o.eventignore = "BufEnter,WinEnter,BufWinEnter,FileType"

  -- Handle symbols from different files
  if symbol.uri and symbol.uri ~= vim.uri_from_bufnr(bufnr) then
    local filepath = symbol.file_path or vim.uri_to_fname(symbol.uri)
    local target_bufnr

    -- Check file size before attempting to load
    local MAX_PREVIEW_SIZE = 524288 -- 512KB
    local stat = uv.fs_stat(filepath)
    if not stat then
      -- File not found, create placeholder buffer
      target_bufnr = M.create_preview_buffer("File not found: " .. filepath)
      vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, {
        "-- File not available: " .. filepath,
        "-- Symbol: " .. (symbol.name or "unknown") .. " at line " .. (symbol.lnum or "?"),
      })
    elseif stat.size > MAX_PREVIEW_SIZE then
      -- File too large, create notice buffer
      target_bufnr = M.create_preview_buffer("File too large: " .. filepath)
      vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, {
        "-- File too large for preview: " .. filepath,
        "-- Size: " .. string.format("%.2f MB", stat.size / 1024 / 1024),
        "-- Symbol: " .. (symbol.name or "unknown") .. " at line " .. (symbol.lnum or "?"),
      })
    else
      -- Try to find if the buffer is already created as a preview buffer
      if state and state.preview_buffers then
        for _, buf in ipairs(state.preview_buffers) do
          if
            vim.api.nvim_buf_is_valid(buf)
            and vim.api.nvim_buf_get_name(buf):match("preview://" .. vim.pesc(filepath) .. "$")
          then
            target_bufnr = buf
            break
          end
        end
      end

      -- If not found, create a new preview buffer
      if not target_bufnr then
        target_bufnr = M.create_preview_buffer(filepath)

        -- Try to load file content asynchronously if available
        local content
        if uv.fs_open then
          -- Use async file reading when available
          local fd = uv.fs_open(filepath, "r", 438)
          if fd then
            stat = uv.fs_fstat(fd)
            if stat then
              content = uv.fs_read(fd, stat.size, 0)
              uv.fs_close(fd)
              if content then
                content = vim.split(content, "\n")
              end
            else
              uv.fs_close(fd)
            end
          end
        end

        -- Fallback to readfile if async read didn't work
        if not content then
          logger.log("Async function was not available, falling back to readfile")
          local ok, file_content = pcall(vim.fn.readfile, filepath)
          if ok then
            content = file_content
          end
        end

        -- Set buffer content if available
        if content then
          vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, content)

          -- Set filetype for syntax highlighting
          local ft = vim.filetype.match({ filename = filepath })
          if ft then
            vim.api.nvim_set_option_value("filetype", ft, { buf = target_bufnr })
          end
        else
          -- If can't load file, create a placeholder
          vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, {
            "-- File could not be loaded: " .. filepath,
            "-- Symbol: " .. (symbol.name or "unknown") .. " at line " .. (symbol.lnum or "?"),
          })
        end
        pcall(vim.treesitter.start, target_bufnr)
      end
    end

    -- Track this preview buffer in state
    if state then
      if not state.preview_buffers then
        state.preview_buffers = {}
      end
      if not vim.tbl_contains(state.preview_buffers, target_bufnr) then
        table.insert(state.preview_buffers, target_bufnr)
      end
      state.active_preview_buf = target_bufnr
      state.last_previewed_path = filepath
      state.is_previewing = true
    end

    -- Switch to the preview buffer without adding to jumplist
    vim.api.nvim_set_current_win(win)
    vim.cmd("keepjumps buffer " .. target_bufnr)
    vim.api.nvim_set_current_win(picker_win)

    -- We don't need to schedule return to original buffer since we'll handle
    -- that in the cleanup function when needed
  end

  -- Clear any existing highlights
  vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(win), ns_id, 0, -1)

  -- Make sure the buffer and line number are valid
  local current_buf = vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(current_buf) or symbol.lnum < 1 then
    vim.api.nvim_set_current_win(picker_win)
    vim.o.eventignore = saved_eventignore
    return
  end

  -- Make sure the line exists in the buffer
  local line_count = vim.api.nvim_buf_line_count(current_buf)
  if symbol.lnum > line_count then
    vim.api.nvim_set_current_win(picker_win)
    vim.o.eventignore = saved_eventignore
    return
  end

  -- Get the line content safely
  local line = vim.api.nvim_buf_get_lines(current_buf, symbol.lnum - 1, symbol.lnum, false)[1]
  if not line then
    vim.api.nvim_set_current_win(picker_win)
    vim.o.eventignore = saved_eventignore
    return
  end

  -- use treesitter for better highlighting
  local has_ts, node = pcall(vim.treesitter.get_node, {
    pos = { symbol.lnum - 1, (symbol.col or 1) - 1 },
    bufnr = current_buf,
    ignore_injections = false,
  })

  if has_ts and node then
    node = M.find_meaningful_node(node, symbol.lnum - 1)
    if node then
      local srow, scol, erow, ecol = node:range()
      vim.api.nvim_buf_set_extmark(current_buf, ns_id, srow, 0, {
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
    end
  else
    -- Fallback: just highlight the line
    vim.api.nvim_buf_set_extmark(current_buf, ns_id, symbol.lnum - 1, 0, {
      end_line = symbol.lnum,
      hl_group = M.config.highlight,
      hl_eol = true,
      priority = 1,
    })

    -- Set cursor to the symbol position
    vim.api.nvim_win_set_cursor(win, { symbol.lnum, (symbol.col or 1) - 1 })
    vim.api.nvim_win_call(win, function()
      vim.cmd("keepjumps normal! zz")
    end)
  end

  vim.api.nvim_set_current_win(picker_win)
  vim.o.eventignore = saved_eventignore
end

-- Helper function to create preview buffers
function M.create_preview_buffer(filepath)
  -- Create a non-listed, scratch buffer
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set buffer options to prevent it from being tracked in history
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = vim.filetype.match({ filename = filepath }) or ""

  -- Set identifying metadata (use prefix to identify preview buffers)
  vim.api.nvim_buf_set_name(buf, "preview://" .. filepath)

  return buf
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
