local M = {}
local logger = require("namu.utils.logger")

function M.clear_preview_highlight(win, ns_id, state)
  -- Track which buffers we've already cleared to avoid redundant operations
  local cleared_buffers = {}
  -- First priority: Clear specific namespace if provided
  if ns_id then
    -- From window's current buffer
    if win and vim.api.nvim_win_is_valid(win) then
      local bufnr = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
        cleared_buffers[bufnr] = true
      end
    end
    -- From tracked buffers in state
    if state then
      if
        state.original_buf
        and vim.api.nvim_buf_is_valid(state.original_buf)
        and not cleared_buffers[state.original_buf]
      then
        vim.api.nvim_buf_clear_namespace(state.original_buf, ns_id, 0, -1)
        cleared_buffers[state.original_buf] = true
      end
      -- Last highlighted buffer
      if
        state.last_highlighted_bufnr
        and vim.api.nvim_buf_is_valid(state.last_highlighted_bufnr)
        and not cleared_buffers[state.last_highlighted_bufnr]
      then
        vim.api.nvim_buf_clear_namespace(state.last_highlighted_bufnr, ns_id, 0, -1)
        cleared_buffers[state.last_highlighted_bufnr] = true
      end
    end
  end

  -- Second priority: If additional namespaces need to be cleared
  if state then
    -- Clear namu preview namespaces, but only from buffers we care about
    local relevant_buffers = {}
    -- Collect all relevant buffers first
    if state.original_buf and vim.api.nvim_buf_is_valid(state.original_buf) then
      relevant_buffers[state.original_buf] = true
    end
    if state.last_highlighted_bufnr and vim.api.nvim_buf_is_valid(state.last_highlighted_bufnr) then
      relevant_buffers[state.last_highlighted_bufnr] = true
    end
    -- TEST: this might be redundant, check PLEASE
    -- Get all "namu_preview" namespaces
    local namespaces = vim.api.nvim_get_namespaces()
    for name, namespace_id in pairs(namespaces) do
      if name:match("namu") and name:match("preview") then
        -- Clear each namespace from each relevant buffer
        for bufnr in pairs(relevant_buffers) do
          vim.api.nvim_buf_clear_namespace(bufnr, namespace_id, 0, -1)
        end
      end
    end
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

---Finds index of symbol at current cursor position when inital open picker
---for initial_index varibale
---@param items SelectaItem[] The full items list
---@param symbol SelectaItem table The symbol to find (should be from original buffer context)
---@param is_ctags? boolean Whether the symbol is from CTags
---@param context? string Context identifier ("buffer" or "watchtower") - Used mainly for logging/debugging now
---@param state? table State object - Used mainly for logging/debugging now
---@return number|nil index The index of the symbol if found
function M.find_symbol_index(items, symbol, is_ctags, context, state)
  context = context or "buffer" -- Keep for logging clarity

  if not symbol or not symbol.value then
    logger.log("find_symbol_index() - Invalid target symbol provided")
    return nil
  end

  -- Target signature for comparison
  local target_signature = symbol.value.signature

  if is_ctags then
    -- CTags logic remains the same
    -- ... (existing CTags logic from lines 88-108) ...
    for i, item in ipairs(items) do
      if item.value.lnum == symbol.value.lnum and item.value.name == symbol.value.name then
        return i
      end
    end
    for i, item in ipairs(items) do
      if item.value.lnum == symbol.value.lnum then
        return i
      end
    end
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
    -- Skip items without value
    if not item.value then
      goto continue_lsp_find
    end

    local match = false
    -- Primary check: Compare signatures if both exist
    if target_signature and item.value.signature then
      if item.value.signature == target_signature then
        match = true
      end
    -- Fallback check: Compare properties if signatures are missing
    elseif
      item.value.lnum
      and symbol.value.lnum
      and item.value.lnum == symbol.value.lnum
      and item.value.col
      and symbol.value.col
      and item.value.col == symbol.value.col
      and item.value.name
      and symbol.value.name
      and item.value.name == symbol.value.name
    then
      match = true
    -- Deep fallback: Direct table reference comparison (less reliable if tables were recreated)
    elseif item == symbol then
      match = true
    end

    if match then
      -- Optional: Add a debug log here to confirm which buffer the matched item belongs to
      local item_bufnr = item.bufnr or item.value.bufnr
      local original_buf = state and state.original_buf
      logger.log(
        "find_symbol_index() - Matched item "
          .. i
          .. " with signature "
          .. (item.value.signature or "nil")
          .. " in buffer "
          .. (item_bufnr or "unknown")
          .. " with original buffer "
          .. original_buf
      )
      return i -- Found the matching item
    end

    ::continue_lsp_find::
  end

  logger.log(
    "find_symbol_index() - No matching LSP symbol found for target: "
      .. vim.inspect(symbol.value)
      .. " in context "
      .. context
  )
  return nil -- Symbol not found
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
  -- HACK: if there is decorator, catch the whole decorator which is
  -- "decorated_definition".
  if filetype == "python" and type == "decorator" then
    return parent_node
  elseif vim.bo.filetype == "c" then -- need to go one step up to highlight the full node for fn and me
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

---Handles visual highlighting of selected symbols in preview
---@param symbol table LSP symbol item
---@param win number Window handle
---@param ns_id number Namespace ID
---@param state? table Optional state object that may contain buffer information
function M.preview_symbol(symbol, win, ns_id, state, highlight_group)
  if state and state.last_highlighted_bufnr and vim.api.nvim_buf_is_valid(state.last_highlighted_bufnr) then
    vim.api.nvim_buf_clear_namespace(state.last_highlighted_bufnr, ns_id, 0, -1)
  end
  -- TODO: use state.original_buffer
  local current_bufnr = vim.api.nvim_win_get_buf(win)
  local target_bufnr = nil
  -- Check if we have buffer info in symbol
  if symbol.bufnr then
    target_bufnr = symbol.bufnr
  elseif symbol.value.bufnr then
    target_bufnr = symbol.value.bufnr
  end
  local value = symbol.value
  -- Determine if we need to switch buffers
  local need_buffer_switch = target_bufnr and target_bufnr ~= current_bufnr and vim.api.nvim_buf_is_valid(target_bufnr)

  -- Switch buffer if needed (before win_call)
  if need_buffer_switch then
    pcall(vim.api.nvim_win_set_buf, win, target_bufnr)
  end
  -- use buffer in window regardless of the success of switching buffers so no erros will happen
  local bufnr = vim.api.nvim_win_get_buf(win)
  state.last_highlighted_bufnr = bufnr
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    local line = vim.api.nvim_buf_get_lines(bufnr, value.lnum - 1, value.lnum, false)[1]
    if not line then
      return
    end
    local first_char_col = line:find("%S")
    if not first_char_col then
      return
    end
    first_char_col = first_char_col - 1
    local node = vim.treesitter.get_node({
      pos = { value.lnum - 1, first_char_col },
      ignore_injections = false,
    })
    if node then
      node = M.find_meaningful_node(node, value.lnum - 1)
    end
    if node then
      local srow, scol, erow, ecol = node:range()
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, srow, 0, {
        end_row = erow,
        end_col = ecol,
        hl_group = highlight_group,
        hl_eol = true,
        priority = 201,
        strict = false,
      })
      -- Set cursor position in this window
      vim.api.nvim_win_set_cursor(win, { srow + 1, scol })
      vim.cmd("normal! zz")
    end
  end)
end

-- Apply consistent highlighting to formatted items in the buffer
---@param buf number Buffer handle
---@param items table[] List of items to highlight
---@param config table Configuration with highlight and display settings
---TODO: Refactor please to be maore readable
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
          ---@diagnostic disable-next-line: undefined-field
          local pattern_pos = line_text:find(pattern, start_pos + 1, true)
          if not pattern_pos then
            break
          end
          -- Get the exact character at this position in the line
          ---@diagnostic disable-next-line: undefined-field
          local actual_char = line_text:sub(pattern_pos, pattern_pos + #pattern - 1)
          local actual_bytes = {}
          for i = 1, #actual_char do
            table.insert(actual_bytes, string.byte(actual_char, i))
          end
          -- Calculate visual width properly
          -- local visual_width = vim.api.nvim_strwidth(pattern)
          -- Try highlighting with a slightly expanded range
          vim.api.nvim_buf_set_extmark(buf, namu_ns_id, line, pattern_pos - 1, {
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
          ---@diagnostic disable-next-line: undefined-field
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
      ---@diagnostic disable-next-line: undefined-field
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
    -- 4. Highlight file icon with its specific highlight group if available
    if item.is_root and item.icon and item.icon_hl then
      local icon = item.icon
      local icon_hl = item.icon_hl
      if icon_hl then
        -- Get the foreground color from the icon's highlight group
        local hl_info = vim.api.nvim_get_hl(0, { name = icon_hl, link = false })
        -- TODO: Make it fg but bold and italic
        -- maybe add some decoration for the buffer to get
        -- recognised more
        if hl_info.fg then
          -- Create a highlight group name for this specific icon color
          local bg_hl = "SelectaBg_" .. icon_hl
          -- Create this background highlight group if it doesn't exist yet
          if not vim.g["selecta_bg_" .. icon_hl] then
            -- Create a new highlight with icon's fg as background
            vim.api.nvim_set_hl(0, bg_hl, {
              bg = hl_info.fg,
              blend = 50,
              default = true,
            })
            vim.g["selecta_bg_" .. icon_hl] = true
          end
          -- Apply the background highlight to the whole line
          vim.api.nvim_buf_set_extmark(buf, namu_ns_id, line, 0, {
            end_row = line + 1,
            end_col = 0,
            hl_eol = true,
            hl_group = icon_hl,
            priority = 202,
          })
        end
        -- Still highlight the icon with its original highlight
        ---@diagnostic disable-next-line: undefined-field
        local icon_pos = line_text:find(icon, 1, true)
        if icon_pos then
          vim.api.nvim_buf_set_extmark(buf, namu_ns_id, line, icon_pos - 1, {
            end_row = line,
            end_col = icon_pos - 1 + #icon,
            hl_group = icon_hl,
            priority = 202,
          })
        end
      end
    end

    ::continue::
  end
end

-- TODO: No need for it
-- Initialize UI module with config
function M.setup(config)
  M.config = config
end

return M
