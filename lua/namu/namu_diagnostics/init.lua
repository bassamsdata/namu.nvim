--[[ Namu Diagnostics 
Diagnostics picker with live preview and actions.
Integrates with selecta for fuzzy finding and magnet for symbol handling.
]]

local selecta = require("namu.selecta.selecta").pick
local preview_utils = require("namu.core.preview_utils")
local M = {}

---@class DiagnosticConfig
---@field highlights table<string, string> Highlight groups for different diagnostic severities
---@field icons table<string, string> Icons for different diagnostic severities
---@field window table Window configuration
---@field custom_keymaps table[] Keymap configuration
---@field debug boolean Enable debug logging

---@type DiagnosticConfig
M.config = {
  highlights = {
    Error = "DiagnosticVirtualTextError",
    Warn = "DiagnosticVirtualTextWarn",
    Info = "DiagnosticVirtualTextInfo",
    Hint = "DiagnosticVirtualTextHint",
  },
  icons = {
    Error = "",
    Warn = "󰀦",
    Info = "󰋼",
    Hint = "󰌶",
  },
  current_highlight = {
    enabled = true,
    hl_group = "CursorLine",
    prefix_icon = " ",
  },
  window = {
    border = "rounded",
    title_prefix = "󰃣 > ",
    min_width = 20,
    max_width = 80,
    min_height = 1,
    padding = 2,
  },
  custom_keymaps = {
    yank = {
      keys = { "<C-y>" },
      handler = function(items_or_item, state)
        return M.yank_diagnostic_with_context(items_or_item, state)
      end,
      desc = "Yank diagnostic with context",
    },
    codecompanion = {
      keys = { "<C-o>" },
      handler = function(items_or_item, state)
        return M.add_to_codecompanion(items_or_item, state)
      end,
      desc = "Add to CodeCompanion",
    },
  },
  debug = false,
}

-- Store original window and position for preview
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = vim.api.nvim_create_namespace("diagnostic_preview"),
  preview_state = nil,
}

---Get severity name from severity number
---@param severity number
---@return string
local function get_severity_info(severity)
  local severities = {
    [1] = "Error",
    [2] = "Warn",
    [3] = "Info",
    [4] = "Hint",
  }
  return severities[severity] or "Unknown"
end
local function parse_diagnostic_filter(query, config)
  -- Similar to parse_symbol_filter but for diagnostics
  if #query >= 3 and query:sub(1, 1) == "/" then
    local type_code = query:sub(2, 3):lower()
    local filter_map = {
      er = { severity = 1, description = "Errors" },
      wa = { severity = 2, description = "Warnings" },
      ["in"] = { severity = 3, description = "Information" },
      hi = { severity = 4, description = "Hints" },
    }

    local filter = filter_map[type_code]
    if filter then
      return {
        severity = filter.severity,
        remaining = query:sub(4),
        description = filter.description,
      }
    end
  end
  return nil
end

-- Format diagnostic with optional file name prefix
local function format_diagnostic(diagnostic, file_prefix)
  local severity = get_severity_info(diagnostic.severity)
  local icon = M.config.icons[severity] or "󰊠"
  local message = diagnostic.message:gsub("\n", " ")
  local source = diagnostic.source and (" (" .. diagnostic.source .. ")") or ""
  local line = diagnostic.lnum + 1
  local col = diagnostic.col + 1
  local loc = string.format("[%d:%d]", line, col)

  local file_info = ""
  if file_prefix and #file_prefix > 0 then
    file_info = " [" .. file_prefix:sub(1, -3) .. "]" -- Remove trailing " - "
  end

  return string.format("%s %s%s %s%s", icon, message, source, loc, file_info)
end

-- Format diagnostic for display in the picker
local function format_diagnostic_item(item, config)
  -- Handle current highlight prefix padding
  local prefix_padding = ""
  if
    config.current_highlight
    and config.current_highlight.enabled
    and config.current_highlight.prefix_icon
    and #config.current_highlight.prefix_icon > 0
  then
    prefix_padding = string.rep(" ", vim.api.nvim_strwidth(config.current_highlight.prefix_icon))
  end

  local value = item.value
  local severity = get_severity_info(value.diagnostic.severity)
  local icon = config.icons[severity] or "󰊠"

  -- Format the location information
  local location = string.format("[%d:%d]", value.lnum + 1, value.col + 1)

  -- Format message - ensure it's not too long
  local message = value.diagnostic.message
  if #message > 60 then
    message = message:sub(1, 57) .. "..."
  end

  -- Replace newlines with spaces
  message = message:gsub("\n", " ")

  -- Format source if available
  local source = ""
  if value.diagnostic.source then
    source = string.format(" (%s)", value.diagnostic.source)
  end

  -- Format location
  local location = string.format("[%d:%d]", value.lnum + 1, value.col + 1)
  local file_info = ""
  if value.bufnr then
    local bufname = vim.api.nvim_buf_get_name(value.bufnr)
    if bufname and bufname ~= "" then
      file_info = " [" .. vim.fn.fnamemodify(bufname, ":t") .. "]"
    end
  end

  return prefix_padding .. icon .. " " .. message .. source .. " " .. location .. file_info
end

---Get node text at diagnostic position
---@param bufnr number
---@param diagnostic table
---@return string|nil
local function get_node_text(bufnr, diagnostic)
  local node = vim.treesitter.get_node({
    bufnr = bufnr,
    pos = { diagnostic.lnum, diagnostic.col },
  })

  if not node then
    return nil
  end

  -- Try to find meaningful parent node
  local current = node
  while current:parent() and current:parent():type() ~= "chunk" do
    current = current:parent()
    local type = current:type()
    if
      vim.tbl_contains({
        "function_declaration",
        "local_function",
        "function_definition",
        "method_definition",
        "if_statement",
        "for_statement",
        "while_statement",
      }, type)
    then
      break
    end
  end

  return vim.treesitter.get_node_text(current, bufnr)
end

---Convert diagnostics to selecta items
---@param diagnostics table[]
---@param bufnr number
---@return table[]

-- Enhanced conversion function for diagnostics
local function diagnostics_to_selecta_items(diagnostics, buffer_info)
  local items = {}
  local single_buffer = type(buffer_info) == "number"
  local bufnr = single_buffer and buffer_info or nil

  for _, diagnostic in ipairs(diagnostics) do
    local diag_bufnr = diagnostic.bufnr or bufnr
    if not diag_bufnr then
      goto continue
    end

    local severity = get_severity_info(diagnostic.severity)
    local file_name = ""

    -- Add file name for multi-buffer views
    if not single_buffer then
      local buf_name = buffer_info[diag_bufnr] or "[No Name]"
      file_name = vim.fn.fnamemodify(buf_name, ":t") .. " - "
    end

    local item = {
      text = format_diagnostic(diagnostic, file_name),
      value = {
        diagnostic = diagnostic,
        severity = severity,
        lnum = diagnostic.lnum,
        col = diagnostic.col,
        end_lnum = diagnostic.end_lnum or diagnostic.lnum,
        end_col = diagnostic.end_col or diagnostic.col + 1,
        bufnr = diag_bufnr,
        context = get_node_text(diag_bufnr, diagnostic),
      },
      icon = M.config.icons[severity],
      kind = severity,
    }
    table.insert(items, item)

    ::continue::
  end

  -- Sort by buffer, then by line, then by column
  table.sort(items, function(a, b)
    if a.value.bufnr ~= b.value.bufnr then
      return a.value.bufnr < b.value.bufnr
    elseif a.value.lnum ~= b.value.lnum then
      return a.value.lnum < b.value.lnum
    else
      return a.value.col < b.value.col
    end
  end)

  return items
end

---Highlight diagnostic in original buffer
---@param item table
local function preview_diagnostics(item, win_id)
  if not item or not item.value then
    return
  end

  local value = item.value
  local bufnr = value.bufnr
  local severity = get_severity_info(value.diagnostic.severity)
  local hl_group = M.config.highlights[severity]

  -- If buffer exists and is valid, use it directly
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_win_call(win_id, function()
      -- Set buffer in window
      if vim.api.nvim_win_get_buf(win_id) ~= bufnr then
        vim.api.nvim_win_set_buf(win_id, bufnr)
      end

      -- Position cursor and highlight
      pcall(vim.api.nvim_win_set_cursor, win_id, {
        value.lnum + 1,
        value.col,
      })
      vim.cmd("normal! zz")

      -- Apply highlight at exact position
      vim.api.nvim_buf_clear_namespace(bufnr, state.preview_ns, 0, -1)
      -- Safely determine end_row and end_col
      local end_row = value.end_lnum or value.lnum
      local end_col = value.end_col or (value.col + 1)
      -- Get line content to validate end_col
      local lines = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)
      if #lines > 0 then
        local line_length = #lines[1]
        -- If end_col is beyond line length, adjust it
        if end_col > line_length then
          end_col = line_length
        end
      end

      -- Create the extmark with validated positions
      pcall(vim.api.nvim_buf_set_extmark, bufnr, state.preview_ns, value.lnum, value.col, {
        end_row = end_row,
        end_col = end_col,
        hl_group = hl_group,
        priority = 301,
      })
    end)
    return
  end

  -- If we get here, we need to handle a file that's not in a buffer
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if file_path == "" then
    return -- No path available
  end

  -- Initialize preview state if needed
  if not state.preview_state then
    state.preview_state = preview_utils.create_preview_state("diagnostic_preview")
    state.preview_state.original_win = win_id
  end

  -- Check if we need a scratch buffer
  if not state.preview_state.scratch_buf or not vim.api.nvim_buf_is_valid(state.preview_state.scratch_buf) then
    state.preview_state.scratch_buf = preview_utils.create_scratch_buffer()
  end

  local cache_eventignore = vim.o.eventignore
  vim.o.eventignore = "BufEnter"

  -- Read file content asynchronously
  preview_utils.readfile_async(file_path, function(ok, lines)
    if not ok or not lines then
      vim.o.eventignore = cache_eventignore
      return
    end

    -- Set buffer content and options
    vim.api.nvim_buf_set_lines(state.preview_state.scratch_buf, 0, -1, false, lines)

    -- Set filetype for syntax highlighting
    local ft = vim.filetype.match({ filename = file_path })
    if ft then
      vim.bo[state.preview_state.scratch_buf].filetype = ft

      -- Try using treesitter if available
      if state.preview_state.scratch_buf and vim.api.nvim_buf_is_valid(state.preview_state.scratch_buf) then
        local has_parser, parser = pcall(vim.treesitter.get_parser, state.preview_state.scratch_buf, ft)
        if has_parser and parser then
          parser:parse()
        end
      end
    end

    -- Set scratch buffer in window
    vim.api.nvim_win_set_buf(win_id, state.preview_state.scratch_buf)

    -- Set cursor to diagnostic line and center
    vim.api.nvim_win_set_cursor(win_id, { value.lnum + 1, value.col })
    vim.api.nvim_win_call(win_id, function()
      vim.cmd("normal! zz")
    end)

    -- Apply highlight
    vim.api.nvim_buf_clear_namespace(state.preview_state.scratch_buf, state.preview_ns, 0, -1)
    -- Safely determine end positions
    local end_row = value.end_lnum or value.lnum
    local end_col = value.end_col or (value.col + 1)

    -- Get line content to validate end_col
    local lines = vim.api.nvim_buf_get_lines(state.preview_state.scratch_buf, end_row, end_row + 1, false)
    if #lines > 0 then
      local line_length = #lines[1]
      -- If end_col is beyond line length, adjust it
      if end_col > line_length then
        end_col = line_length
      end
    end
    pcall(vim.api.nvim_buf_set_extmark, state.preview_state.scratch_buf, state.preview_ns, value.lnum, value.col, {
      end_row = end_row,
      end_col = end_col,
      hl_group = hl_group,
      priority = 301,
    })

    vim.o.eventignore = cache_eventignore
  end)
end

-- Apply severity-based highlights in the picker UI
local function apply_diagnostic_highlights(buf, filtered_items, config)
  local ns_id = vim.api.nvim_create_namespace("namu_diagnostics_picker")
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  for idx, item in ipairs(filtered_items) do
    local line = idx - 1
    local value = item.value
    local severity = get_severity_info(value.diagnostic.severity)
    local hl_group = config.highlights[severity]

    -- Get the line from buffer
    local lines = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)
    if #lines == 0 then
      goto continue
    end

    local line_text = lines[1]

    -- Find where the location info starts
    local location_pattern = "%[%d+:%d+%]"
    local location_start = line_text:find(location_pattern)

    if location_start then
      -- Highlight the icon and message with severity color
      vim.api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
        end_row = line,
        end_col = location_start - 1,
        hl_group = hl_group,
        priority = 110,
      })

      -- Highlight the location info
      local location_text = line_text:match(location_pattern)
      vim.api.nvim_buf_set_extmark(buf, ns_id, line, location_start - 1, {
        end_row = line,
        end_col = location_start - 1 + #location_text,
        hl_group = "Directory",
        priority = 100,
      })

      -- Highlight source if present
      local source_pattern = " %(.-%)$"
      local source_start = line_text:find(source_pattern)
      if source_start then
        vim.api.nvim_buf_set_extmark(buf, ns_id, line, source_start - 1, {
          end_row = line,
          end_col = #line_text,
          hl_group = "Comment",
          priority = 110,
        })
      end
    else
      -- Fallback: highlight entire line
      vim.api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
        end_row = line,
        end_col = #line_text,
        hl_group = hl_group,
        priority = 110,
      })
    end

    ::continue::
  end
end

-- Get diagnostics for a specific scope
local function get_diagnostics_for_scope(scope, opts)
  opts = opts or {}

  if scope == "current" then
    -- Current buffer diagnostics
    local bufnr = vim.api.nvim_get_current_buf()
    return vim.diagnostic.get(bufnr, opts), bufnr
  elseif scope == "buffers" then
    -- All open buffers diagnostics
    local all_diagnostics = {}
    local buffer_info = {}

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local buf_diagnostics = vim.diagnostic.get(bufnr, opts)
        for _, diag in ipairs(buf_diagnostics) do
          diag.bufnr = bufnr -- Ensure bufnr is set
          table.insert(all_diagnostics, diag)
          buffer_info[bufnr] = buffer_info[bufnr] or vim.api.nvim_buf_get_name(bufnr)
        end
      end
    end
    return all_diagnostics, buffer_info
  elseif scope == "workspace" then
    -- Workspace diagnostics (all buffers including unloaded)
    local all_diagnostics = {}
    local buffer_info = {}

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      local buf_diagnostics = vim.diagnostic.get(bufnr, opts)
      for _, diag in ipairs(buf_diagnostics) do
        diag.bufnr = bufnr -- Ensure bufnr is set
        table.insert(all_diagnostics, diag)
        buffer_info[bufnr] = buffer_info[bufnr] or vim.api.nvim_buf_get_name(bufnr)
      end
    end
    return all_diagnostics, buffer_info
  end

  return {}, nil
end

---@return number|nil
local function find_current_diagnostic_index(items)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1] - 1 -- Convert to 0-based

  if M.config.debug then
    print(string.format("Current cursor line: %d", cursor_line))
  end

  -- First try to find exact line match
  for idx, item in ipairs(items) do
    local diag = item.value.diagnostic
    if diag.lnum == cursor_line then
      if M.config.debug then
        print(string.format("Found diagnostic at index %d on same line", idx))
      end
      return idx
    end
  end

  -- If no exact match, find closest diagnostic
  local closest_idx = 1
  local closest_distance = math.huge

  for idx, item in ipairs(items) do
    local diag = item.value.diagnostic
    local distance = math.abs(diag.lnum - cursor_line)
    if distance < closest_distance then
      closest_distance = distance
      closest_idx = idx
    end
  end

  if M.config.debug then
    print(string.format("Using closest diagnostic at index %d", closest_idx))
  end

  return closest_idx
end

---Yank diagnostic with its context
---@param items_or_item table|table[]
---@param state table
---@return boolean
function M.yank_diagnostic_with_context(items_or_item, state)
  local items = vim.islist(items_or_item) and items_or_item or { items_or_item }
  local texts = {}

  for _, item in ipairs(items) do
    local value = item.value
    local text = string.format(
      [[
Diagnostic: %s
Severity: %s
Location: Line %d, Column %d
Context: %s
]],
      value.diagnostic.message,
      value.severity,
      value.lnum + 1,
      value.col + 1,
      value.context or "No context available"
    )

    table.insert(texts, text)
  end

  local final_text = table.concat(texts, "\n\n")
  vim.fn.setreg('"', final_text)
  vim.fn.setreg("+", final_text)

  vim.notify(string.format("Yanked %d diagnostic(s) with context", #items))
  return true
end

---Add diagnostic(s) to CodeCompanion
---@param items_or_item table|table[]
---@param state table
function M.add_to_codecompanion(items_or_item, state)
  local items = vim.islist(items_or_item) and items_or_item or { items_or_item }
  local texts = {}

  for _, item in ipairs(items) do
    local value = item.value
    local text = string.format(
      [[
Diagnostic: %s
Severity: %s
Location: Line %d, Column %d
Context:
```%s
%s
```]],
      value.diagnostic.message,
      value.severity,
      value.lnum + 1,
      value.col + 1,
      vim.bo[value.bufnr].filetype,
      value.context or "No context available"
    )

    table.insert(texts, text)
  end

  local chat = require("codecompanion").chat()
  if chat then
    chat:add_buf_message({
      role = require("codecompanion.config").constants.USER_ROLE,
      content = table.concat(texts, "\n\n"),
    })
    chat.ui:open()
  end
end

---Show diagnostics picker
function M.show(scope)
  scope = scope or "current"

  -- Store current window info
  state.original_win = vim.api.nvim_get_current_win()
  state.original_buf = vim.api.nvim_get_current_buf()
  state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)

  -- Save window state for potential restoration
  if not state.preview_state then
    state.preview_state = preview_utils.create_preview_state("diagnostic_preview")
  end
  preview_utils.save_window_state(state.original_win, state.preview_state)

  -- Get diagnostics for selected scope
  local diagnostics, buffer_info = get_diagnostics_for_scope(scope)
  if #diagnostics == 0 then
    vim.notify("No diagnostics found", vim.log.levels.INFO)
    return
  end

  -- Convert to selecta items
  local items = diagnostics_to_selecta_items(diagnostics, buffer_info)

  -- Find current diagnostic (for current file only)
  local current_index = nil
  if scope == "current" then
    current_index = find_current_diagnostic_index(items)
  end

  -- Create picker title based on scope
  local titles = {
    current = "Diagnostics - Current File",
    buffers = "Diagnostics - Open Buffers",
    workspace = "Diagnostics - Workspace",
  }

  -- Show picker
  selecta(items, {
    title = titles[scope] or "Diagnostics",
    window = M.config.window,
    current_highlight = M.config.current_highlight,
    debug = M.config.debug,
    custom_keymaps = M.config.custom_keymaps,
    initial_index = current_index,
    preserve_order = true,
    pre_filter = function(items, query)
      local filter = parse_diagnostic_filter(query, M.config)
      if filter then
        local filtered = vim.tbl_filter(function(item)
          local severity_num = item.value.diagnostic.severity
          return severity_num == filter.severity
        end, items)
        return filtered, filter.remaining
      end
      return items, query
    end,
    formatter = function(item)
      return format_diagnostic_item(item, M.config)
    end,
    hooks = {
      on_render = function(buf, filtered_items)
        apply_diagnostic_highlights(buf, filtered_items, M.config)
      end,
    },
    on_move = function(item)
      if item and item.value then
        preview_diagnostics(item, state.original_win)
      end
    end,
    on_select = function(item)
      if item and item.value then
        -- Reset preview state when selecting
        if
          state.preview_state
          and state.preview_state.scratch_buf
          and vim.api.nvim_buf_is_valid(state.preview_state.scratch_buf)
        then
          vim.api.nvim_buf_delete(state.preview_state.scratch_buf, { force = true })
          state.preview_state.scratch_buf = nil
        end

        -- Jump to diagnostic position
        local value = item.value
        local bufnr = value.bufnr

        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_win_set_buf(state.original_win, bufnr)
          vim.api.nvim_win_set_cursor(state.original_win, {
            value.lnum + 1,
            value.col,
          })
        end
      end
    end,
    on_cancel = function()
      -- Clear highlights across all buffers
      vim.api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
      if
        state.preview_state
        and state.preview_state.scratch_buf
        and vim.api.nvim_buf_is_valid(state.preview_state.scratch_buf)
      then
        vim.api.nvim_buf_clear_namespace(state.preview_state.scratch_buf, state.preview_ns, 0, -1)
      end

      -- Restore original window state
      if state.preview_state then
        preview_utils.restore_window_state(state.original_win, state.preview_state)
      else
        -- Fallback to basic restoration
        if
          state.original_win
          and state.original_pos
          and state.original_buf
          and vim.api.nvim_win_is_valid(state.original_win)
          and vim.api.nvim_buf_is_valid(state.original_buf)
        then
          vim.api.nvim_win_set_buf(state.original_win, state.original_buf)
          vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
        end
      end
    end,
  })
end

-- API functions for different scopes
function M.show_current_diagnostics()
  M.show("current")
end

function M.show_buffer_diagnostics()
  M.show("buffers")
end

function M.show_workspace_diagnostics()
  M.show("workspace")
end

---Setup the module
---@param opts? DiagnosticConfig
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  vim.api.nvim_create_user_command("NamuDiagnostics", function()
    M.show_current_diagnostics()
  end, { desc = "Show diagnostics for current file" })

  vim.api.nvim_create_user_command("NamuBufferDiagnostics", function()
    M.show_buffer_diagnostics()
  end, { desc = "Show diagnostics for all open buffers" })

  vim.api.nvim_create_user_command("NamuWorkspaceDiagnostics", function()
    M.show_workspace_diagnostics()
  end, { desc = "Show diagnostics for workspace" })
end

return M
