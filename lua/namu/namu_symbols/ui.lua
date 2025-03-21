local M = {}
local logger = require("namu.utils.logger")
local uv = vim.uv or vim.loop

-- Internal state for UI operations
local state = {
  preview_ns = vim.api.nvim_create_namespace("namu_preview"),
}

local ns_id = vim.api.nvim_create_namespace("namu_symbols")

function M.setup_highlights()
  -- Helper function to add default = true to highlight attributes
  local function hl(attrs)
    attrs.default = true
    return attrs
  end

  local highlights = {
    NamuPrefixSymbol = hl({ link = "@Comment" }),
    NamuSymbolFunction = hl({ link = "@function" }),
    NamuSymbolMethod = hl({ link = "@function.method" }),
    NamuSymbolClass = hl({ link = "@lsp.type.class" }),
    NamuSymbolInterface = hl({ link = "@lsp.type.interface" }),
    NamuSymbolVariable = hl({ link = "@lsp.type.variable" }),
    NamuSymbolConstant = hl({ link = "@lsp.type.constant" }),
    NamuSymbolProperty = hl({ link = "@lsp.type.property" }),
    NamuSymbolField = hl({ link = "@lsp.type.field" }),
    NamuSymbolEnum = hl({ link = "@lsp.type.enum" }),
    NamuSymbolModule = hl({ link = "@lsp.type.module" }),
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
  elseif vim.bo.filetype == "c" then
    current = node
    while current do
      if current:type() == "function_definition" then
        node = current
        break
      end
      current = current:parent()
    end
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

-- Cache system implementation
local function setup_file_cache()
  -- Initialize cache with weak keys for GC
  local cache = setmetatable({}, { __mode = "k" })

  -- Constants
  local LINES_AROUND = 100 -- Load 100 lines before and after target line

  -- Get file content from cache or load it
  -- Returns either all lines or a slice around target_line
  local function get_cached_content(filepath, target_line, partial)
    if not filepath then
      return nil
    end

    local stat = uv.fs_stat(filepath)
    if not stat then
      return nil
    end

    local mtime = stat.mtime.sec
    local size = stat.size
    local key = filepath

    -- Check if we have valid cached content
    if cache[key] and cache[key].mtime == mtime then
      if not partial then
        -- Return full content
        return cache[key].lines
      else
        -- Return partial content around target line
        local start = math.max(1, target_line - LINES_AROUND)
        local finish = math.min(#cache[key].lines, target_line + LINES_AROUND)
        return {
          lines = vim.list_slice(cache[key].lines, start, finish),
          start_line = start,
          is_partial = true,
        }
      end
    end

    -- File not in cache or modified, load it
    local content
    local success = false

    -- Try async file reading first
    if uv.fs_open then
      local fd = uv.fs_open(filepath, "r", 438)
      if fd then
        local content_str = uv.fs_read(fd, size, 0)
        uv.fs_close(fd)
        if content_str then
          content = vim.split(content_str, "\n")
          success = true
        end
      end
    end

    -- Fall back to readfile if needed
    if not success then
      logger.log("Async function was not available, falling back to readfile")
      local ok, file_content = pcall(vim.fn.readfile, filepath)
      if ok then
        content = file_content
        success = true
      end
    end

    -- Store in cache if load successful
    if success then
      cache[key] = {
        lines = content,
        mtime = mtime,
      }

      -- Return partial content if requested
      if partial then
        local start = math.max(1, target_line - LINES_AROUND)
        local finish = math.min(#content, target_line + LINES_AROUND)
        return {
          lines = vim.list_slice(content, start, finish),
          start_line = start,
          is_partial = true,
        }
      end

      return content
    end

    return nil
  end

  return {
    get_file_content = get_cached_content,
  }
end

-- Initialize the file cache
local file_cache = setup_file_cache()

-- Debug helper function
local function debug_log(prefix, ...)
  if M.config and M.config.debug then
    local args = { ... }
    local msg = prefix .. ": "
    for i, arg in ipairs(args) do
      if type(arg) == "table" then
        msg = msg .. vim.inspect(arg) .. " "
      else
        msg = msg .. tostring(arg) .. " "
      end
    end
    logger.log(msg)
  end
end

-- Check Neovim version
-- why: cause neovim 0.11 nightly is doing async for all treesitter and this
-- introduces many issues to my way of previewing files.
local is_neovim_nightly = vim.fn.has("nvim-0.11.0") == 1

-- Enhanced highlighting function using LanguageTree callbacks
local function apply_enhanced_highlighting(bufnr, symbol, win, ns_id, picked_win)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return ""
  end
  -- Make sure the buffer and line number are valid
  if symbol.lnum < 1 then
    return
  end
  -- Make sure the line exists in the buffer
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if symbol.lnum > line_count then
    return
  end
  -- Get the line content safely
  local line = vim.api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.lnum, false)[1]
  if not line then
    return
  end
  local first_char_col = line:find("%S")
  if not first_char_col then
    return
  end
  first_char_col = first_char_col - 1
  -- Use treesitter for node-based highlighting if possible
  local has_ts, node
  if is_neovim_nightly then
    -- Neovim 0.11+ approach
    debug_log("apply_enhanced", "Using Neovim 0.11+ approach for treesitter")
    has_ts, node = pcall(function()
      return vim.treesitter.get_node({
        pos = { symbol.lnum - 1, first_char_col },
        bufnr = bufnr,
        ignore_injections = false,
      })
    end)
  else
    -- Neovim stable approach
    has_ts, node = pcall(vim.treesitter.get_node, {
      pos = { symbol.lnum - 1, first_char_col },
      bufnr = bufnr,
      ignore_injections = false,
    })
  end
  debug_log("apply_enhanced", "Treesitter node found:", has_ts, node ~= nil)
  if has_ts and node then
    local current_win = vim.api.nvim_get_current_win()
    -- Switch to the target window for operations
    vim.api.nvim_set_current_win(win)
    local meaningful_node = M.find_meaningful_node(node, symbol.lnum - 1)
    if meaningful_node then
      -- local node_type = pcall(function()
      --   return meaningful_node:type()
      -- end) and meaningful_node:type() or "unknown"
      -- debug_log("apply_enhanced", "Meaningful node type:", node_type)

      -- Get node range safely
      local success, srow, scol, erow, ecol = pcall(function()
        return meaningful_node:range()
      end)
      if success then
        -- Create the extmark for highlighting
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, srow, 0, {
          end_row = erow,
          end_col = ecol,
          hl_group = M.config.highlight,
          hl_eol = true,
          priority = 1,
          strict = false,
        })

        -- Set cursor position and center view
        vim.api.nvim_win_set_cursor(win, { srow + 1, scol })
        vim.api.nvim_win_call(win, function()
          vim.cmd("keepjumps normal! zz")
        end)

        -- Return to original window
        vim.api.nvim_set_current_win(current_win)
        debug_log("apply_enhanced", "Applied node-based highlighting successfully")
        return true
      end
    end
    -- Return to original window if we got here
    vim.api.nvim_set_current_win(current_win)
  end
  debug_log("apply_enhanced", "Could not apply enhanced highlighting")
  return false
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

    -- ** IMPORTANT ** Make a copy of the symbol to avoid modifying the original
    local symbol_copy = vim.deepcopy(symbol)
    local target_lnum = symbol_copy.lnum or 1

    -- Check file size before attempting to load
    local MAX_PREVIEW_SIZE = 524288 -- 512KB
    local stat = uv.fs_stat(filepath)
    if not stat then
      -- File not found, create placeholder buffer
      debug_log("highlight_symbol", "File not found:", filepath)
      target_bufnr = M.create_preview_buffer("File not found: " .. filepath)
      vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, {
        "-- File not available: " .. filepath,
        "-- Symbol: " .. (symbol_copy.name or "unknown") .. " at line " .. (target_lnum or "?"),
      })
    elseif stat.size > MAX_PREVIEW_SIZE then
      -- For large files, load only a portion around the symbol
      debug_log("highlight_symbol", "Large file detected, size:", stat.size)
      local need_reload = true

      -- Try to find if the buffer is already created as a preview buffer
      if state and state.preview_buffers then
        for _, buf in ipairs(state.preview_buffers) do
          if
            vim.api.nvim_buf_is_valid(buf)
            and vim.api.nvim_buf_get_name(buf):match("preview://" .. vim.pesc(filepath) .. "$")
          then
            target_bufnr = buf
            -- Check if we already have loaded the portion containing this symbol
            if vim.b[buf] and vim.b[buf].partial_view then
              local view_data = vim.b[buf].partial_view
              local start_line = view_data.start_line or 1
              local end_line = view_data.end_line or start_line + 200
              -- If the symbol is within the current view, don't reload
              if target_lnum >= start_line and target_lnum <= end_line then
                need_reload = false
                -- Calculate adjusted line number for this view
                symbol_copy.lnum = target_lnum - start_line + 1
                if view_data.has_header then
                  symbol_copy.lnum = symbol_copy.lnum + 1 -- Account for header line
                end
              else
              end
            else
            end
            break
          end
        end
      end

      -- If not found or needs reloading, create/update a preview buffer
      if not target_bufnr then
        debug_log("highlight_symbol", "Creating new preview buffer")
        target_bufnr = M.create_preview_buffer(filepath)
      end

      if need_reload then
        debug_log("highlight_symbol", "Loading partial content around line", target_lnum)
        -- Get partial content around the symbol line
        local content_result = file_cache.get_file_content(filepath, target_lnum, true)

        if content_result and content_result.lines then
          local has_header = false
          debug_log(
            "highlight_symbol",
            "Got partial content, start_line:",
            content_result.start_line,
            "lines:",
            #content_result.lines
          )

          -- Add indicator lines if this is a partial view
          if content_result.is_partial and content_result.start_line > 1 then
            table.insert(content_result.lines, 1, "-- [Lines 1-" .. (content_result.start_line - 1) .. " omitted] --")
            has_header = true
            debug_log("highlight_symbol", "Added header line")
          end

          -- Add indicator at end if needed
          if content_result.is_partial and (content_result.start_line + #content_result.lines - 1) < stat.size then
            table.insert(content_result.lines, "-- [More lines omitted] --")
            debug_log("highlight_symbol", "Added footer line")
          end

          -- Set the buffer content
          vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, content_result.lines)

          -- Store view metadata in buffer-local variable
          vim.b[target_bufnr].partial_view = {
            start_line = content_result.start_line,
            end_line = content_result.start_line + #content_result.lines - 1,
            has_header = has_header,
          }

          debug_log("highlight_symbol", "Stored partial view data:", vim.b[target_bufnr].partial_view)

          -- Adjust symbol line number for the partial content
          symbol_copy.lnum = target_lnum - content_result.start_line + 1
          if has_header then
            symbol_copy.lnum = symbol_copy.lnum + 1 -- Account for header line
          end

          debug_log("highlight_symbol", "Adjusted symbol line:", symbol_copy.lnum)

          -- Set filetype for syntax highlighting
          local ft = vim.filetype.match({ filename = filepath })
          if ft then
            vim.api.nvim_set_option_value("filetype", ft, { buf = target_bufnr })
            -- Set basic syntax highlighting while waiting for treesitter
            vim.bo[target_bufnr].syntax = ft
          end
        else
          -- Failed to load content, show a notice
          debug_log("highlight_symbol", "Failed to load partial content")
          vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, {
            "-- File too large for preview: " .. filepath,
            "-- Size: " .. string.format("%.2f MB", stat.size / 1024 / 1024),
            "-- Symbol: " .. (symbol_copy.name or "unknown") .. " at line " .. (target_lnum or "?"),
          })
        end
      end
    else
      -- Regular sized file, use normal loading with cache
      debug_log("highlight_symbol", "Regular sized file, using full cache")

      -- Try to find if the buffer is already created as a preview buffer
      if state and state.preview_buffers then
        for _, buf in ipairs(state.preview_buffers) do
          if
            vim.api.nvim_buf_is_valid(buf)
            and vim.api.nvim_buf_get_name(buf):match("preview://" .. vim.pesc(filepath) .. "$")
          then
            target_bufnr = buf
            debug_log("highlight_symbol", "Found existing preview buffer:", buf)
            break
          end
        end
      end

      -- If not found, create a new preview buffer
      if not target_bufnr then
        debug_log("highlight_symbol", "Creating new preview buffer")
        target_bufnr = M.create_preview_buffer(filepath)
      end

      -- Get the content from cache or load it
      local content = file_cache.get_file_content(filepath, nil, false)

      if content then
        debug_log("highlight_symbol", "Loading full file content, lines:", #content)
        vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, content)
        -- Clear partial view metadata since this is a full file view
        vim.b[target_bufnr].partial_view = nil

        -- Set filetype for syntax highlighting
        local ft = vim.filetype.match({ filename = filepath })
        if ft then
          vim.api.nvim_set_option_value("filetype", ft, { buf = target_bufnr })
          -- Set basic syntax highlighting while waiting for treesitter
          vim.bo[target_bufnr].syntax = ft
        end
      else
        -- If can't load file, create a placeholder
        debug_log("highlight_symbol", "Failed to load file content")
        vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, {
          "-- File could not be loaded: " .. filepath,
          "-- Symbol: " .. (symbol_copy.name or "unknown") .. " at line " .. (target_lnum or "?"),
        })
      end
    end

    -- Track this preview buffer in state
    if state then
      if not state.preview_buffers then
        state.preview_buffers = {}
      end
      if not vim.tbl_contains(state.preview_buffers, target_bufnr) then
        table.insert(state.preview_buffers, target_bufnr)
        debug_log("highlight_symbol", "Added buffer to preview_buffers")
      end
      state.active_preview_buf = target_bufnr
      state.last_previewed_path = filepath
      state.is_previewing = true
    end

    -- Switch to the preview buffer without adding to jumplist
    vim.api.nvim_set_current_win(win)
    vim.cmd("keepjumps buffer " .. target_bufnr)
    vim.api.nvim_set_current_win(picker_win)

    -- Use the adjusted symbol copy for highlighting
    symbol = symbol_copy
  end

  -- Clear any existing highlights
  local current_buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_buf_clear_namespace(current_buf, ns_id, 0, -1)

  -- Store information for async highlighting enhancement
  vim.b[current_buf].namu_highlight_info = {
    symbol = vim.deepcopy(symbol), -- Make a clean copy with no metatable references
    win = win,
    ns_id = ns_id,
    picker_win = picker_win,
    pending_enhancement = true,
    needs_basic_syntax = true,
  }

  -- Initial line-based highlighting for immediate feedback
  debug_log("highlight_symbol", "Applying immediate line highlighting")

  -- Make sure the buffer and line number are valid
  if not vim.api.nvim_buf_is_valid(current_buf) or symbol.lnum < 1 then
    debug_log("highlight_symbol", "Invalid buffer or line number")
    vim.api.nvim_set_current_win(picker_win)
    vim.o.eventignore = saved_eventignore
    return
  end

  -- Make sure the line exists in the buffer
  local line_count = vim.api.nvim_buf_line_count(current_buf)
  if symbol.lnum > line_count then
    debug_log("highlight_symbol", "Line number out of range:", symbol.lnum, "max:", line_count)
    vim.api.nvim_set_current_win(picker_win)
    vim.o.eventignore = saved_eventignore
    return
  end

  -- Fallback: just highlight the line for immediate feedback
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

  -- Ensure basic syntax highlighting is enabled while waiting for treesitter
  local ft = vim.bo[current_buf].filetype
  if ft and ft ~= "" and vim.b[current_buf].needs_basic_syntax then
    vim.bo[current_buf].syntax = ft
    vim.b[current_buf].needs_basic_syntax = false
  end

  -- Start treesitter parsing with async callback for enhancement
  if is_neovim_nightly then
    debug_log("highlight_symbol", "Starting async treesitter parsing")

    -- Start treesitter parsing
    pcall(vim.treesitter.start, current_buf)

    -- Try to get language tree
    local success, language_tree = pcall(function()
      return vim.treesitter.get_parser(current_buf)
    end)

    if success and language_tree then
      debug_log("highlight_symbol", "Got language tree, setting up parse callback")

      -- Set up a timeout to cancel waiting for parser after a reasonable time
      local timeout_id
      timeout_id = vim.defer_fn(function()
        if
          vim.api.nvim_buf_is_valid(current_buf)
          and vim.b[current_buf].namu_highlight_info
          and vim.b[current_buf].namu_highlight_info.pending_enhancement
        then
          debug_log("highlight_symbol", "Parser timeout reached, keeping basic highlighting")
          vim.b[current_buf].namu_highlight_info.pending_enhancement = false
        end
      end, 1000) -- 1 second timeout

      -- Request parsing with callback for when it's done
      language_tree:parse(true, function(err, trees)
        if err or not trees or #trees == 0 then
          debug_log("highlight_symbol", "Parser error or no trees")
          return
        end

        -- Check if buffer is still valid and waiting for enhancement
        if not vim.api.nvim_buf_is_valid(current_buf) then
          debug_log("highlight_symbol", "Buffer no longer valid")
          return
        end

        local highlight_info = vim.b[current_buf].namu_highlight_info
        if not highlight_info then
          debug_log("highlight_symbol", "No longer waiting for enhancement")
          return
        end

        -- Apply enhanced highlighting now that parsing is complete
        apply_enhanced_highlighting(
          current_buf,
          highlight_info.symbol,
          highlight_info.win,
          highlight_info.ns_id,
          highlight_info.picker_win
        )

        -- Mark as enhanced so we don't try again
        highlight_info.pending_enhancement = false
      end)
    else
      debug_log("highlight_symbol", "Could not get language tree")
    end
  else
    -- For stable Neovim, try enhanced highlighting immediately
    debug_log("highlight_symbol", "Using immediate treesitter parsing (stable Neovim)")
    pcall(vim.treesitter.start, current_buf)
    apply_enhanced_highlighting(current_buf, symbol, win, ns_id, picker_win)
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
