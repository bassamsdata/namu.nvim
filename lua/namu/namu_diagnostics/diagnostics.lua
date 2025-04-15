--[[ Namu Diagnostics Implementation
This file contains the actual implementation of the diagnostics module.
It is loaded only when required to improve startup performance.
]]

-- Dependencies are only loaded when the module is actually used
local selecta = require("namu.selecta.selecta")
local preview_utils = require("namu.core.preview_utils")
local api = vim.api
local M = {}

-- Store original window and position for preview
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = api.nvim_create_namespace("diagnostic_preview"),
  preview_state = nil,
}
-- We need to store the config when passed in to be used by local functions
M.config = {}

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

---@param query string
---@param config table
---@return table|nil
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
---@param diagnostic table
---@param file_prefix string|nil
---@return string
local function format_diagnostic(diagnostic, file_prefix)
  local message = diagnostic.message:gsub("\n", " ")
  local source = diagnostic.source and (" (" .. diagnostic.source .. ")") or ""
  local line = diagnostic.lnum + 1
  local col = diagnostic.col + 1
  local loc = string.format("[%d:%d]", line, col)

  local file_info = ""
  if file_prefix and #file_prefix > 0 then
    file_info = " [" .. file_prefix:sub(1, -3) .. "]" -- Remove trailing " - "
  end

  return string.format("%s%s %s%s", message, source, loc, file_info)
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
    prefix_padding = string.rep(" ", api.nvim_strwidth(config.current_highlight.prefix_icon))
  end

  local value = item.value
  local severity = get_severity_info(value.diagnostic.severity)
  local icon = config.icons[severity] or "󰊠"

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
    local bufname = api.nvim_buf_get_name(value.bufnr)
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
local function get_node_text(bufnr, diagnostic, with_line_numbers)
  local node = vim.treesitter.get_node({
    bufnr = bufnr,
    pos = { diagnostic.lnum, diagnostic.col },
  })
  if not node then
    return nil
  end

  -- Find meaningful parent node
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

  if with_line_numbers then
    local start_row, _, end_row, _ = current:range()
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    local numbered = {}
    for i, line in ipairs(lines) do
      table.insert(numbered, string.format("%4d | %s", start_row + i, line))
    end
    return table.concat(numbered, "\n")
  else
    return vim.treesitter.get_node_text(current, bufnr)
  end
end

---Convert diagnostics to selecta items
---@param diagnostics table[]
---@param buffer_info number
---@param config table
---@return table[]
-- Enhanced conversion function for diagnostics
local function diagnostics_to_selecta_items(diagnostics, buffer_info, config)
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
        context = get_node_text(diag_bufnr, diagnostic, true),
      },
      icon = config.icons[severity],
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

-- Apply severity-based highlights in the picker UI
---@param buf number
---@param filtered_items table[]
---@param config table
local function apply_diagnostic_highlights(buf, filtered_items, config)
  local ns_id = api.nvim_create_namespace("namu_diagnostics_picker")
  api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  for idx, item in ipairs(filtered_items) do
    local line = idx - 1
    local value = item.value
    local severity = get_severity_info(value.diagnostic.severity)
    local hl_group = config.highlights[severity]

    -- Get the line from buffer
    local lines = api.nvim_buf_get_lines(buf, line, line + 1, false)
    if #lines == 0 then
      goto continue
    end

    local line_text = lines[1]

    -- Find where the location info starts
    local location_pattern = "%[%d+:%d+%]"
    local location_start = line_text:find(location_pattern)

    if location_start then
      -- Highlight the icon and message with severity color
      api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
        end_row = line,
        end_col = location_start - 1,
        hl_group = hl_group,
        priority = 110,
      })

      -- Highlight the location info
      local location_text = line_text:match(location_pattern)
      api.nvim_buf_set_extmark(buf, ns_id, line, location_start - 1, {
        end_row = line,
        end_col = location_start - 1 + #location_text,
        hl_group = "Directory",
        priority = 100,
      })

      -- Highlight source if present
      local source_pattern = " %(.-%)$"
      local source_start = line_text:find(source_pattern)
      if source_start then
        api.nvim_buf_set_extmark(buf, ns_id, line, source_start - 1, {
          end_row = line,
          end_col = #line_text,
          hl_group = "Comment",
          priority = 110,
        })
      end
    else
      -- Fallback: highlight entire line
      api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
        end_row = line,
        end_col = #line_text,
        hl_group = hl_group,
        priority = 110,
      })
    end

    ::continue::
  end
end

---@param bufnr number
---@param ns number
---@param item table
local function preview_highlight_fn(bufnr, ns, item)
  if not item or not item.value or not item.value.diagnostic then
    return
  end
  local diag = item.value.diagnostic
  local d_lnum = diag.lnum or 0
  local d_col = diag.col or 0
  local d_end_lnum = diag.end_lnum or d_lnum
  local d_end_col = diag.end_col or (d_col + 1)
  local severity = diag.severity
  local severity_map = {
    -- TODO: make this configurable with namu highlights
    [1] = "DiagnosticVirtualTextError",
    [2] = "DiagnosticVirtualTextWarn",
    [3] = "DiagnosticVirtualTextInfo",
    [4] = "DiagnosticVirtualTextHint",
  }
  local diag_hl = severity_map[severity] or "DiagnosticVirtualTextOk"
  pcall(api.nvim_buf_set_extmark, bufnr, ns, d_lnum, d_col, {
    end_row = d_end_lnum,
    end_col = d_end_col,
    hl_group = diag_hl,
    priority = 120,
  })
end

-- Get diagnostics for a specific scope
---@param scope string
---@param opts table|nil
---@return table, table|nil
local function get_diagnostics_for_scope(scope, opts)
  opts = opts or {}

  if scope == "current" then
    -- Current buffer diagnostics
    local bufnr = api.nvim_get_current_buf()
    return vim.diagnostic.get(bufnr, opts), bufnr
  elseif scope == "buffers" then
    -- All open buffers diagnostics
    local all_diagnostics = {}
    local buffer_info = {}

    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(bufnr) then
        local buf_diagnostics = vim.diagnostic.get(bufnr, opts)
        for _, diag in ipairs(buf_diagnostics) do
          diag.bufnr = bufnr -- Ensure bufnr is set
          table.insert(all_diagnostics, diag)
          buffer_info[bufnr] = buffer_info[bufnr] or api.nvim_buf_get_name(bufnr)
        end
      end
    end
    return all_diagnostics, buffer_info
  elseif scope == "workspace" then
    -- Workspace diagnostics (all buffers including unloaded)
    local all_diagnostics = {}
    local buffer_info = {}

    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      local buf_diagnostics = vim.diagnostic.get(bufnr, opts)
      for _, diag in ipairs(buf_diagnostics) do
        diag.bufnr = bufnr -- Ensure bufnr is set
        table.insert(all_diagnostics, diag)
        buffer_info[bufnr] = buffer_info[bufnr] or api.nvim_buf_get_name(bufnr)
      end
    end
    return all_diagnostics, buffer_info
  end

  return {}, nil
end

---@return number|nil
---@param items table[]
---@return number|nil
local function find_current_diagnostic_index(items)
  local cursor = api.nvim_win_get_cursor(0)
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

-- Helper to get numbered context lines
local function get_numbered_context(bufnr, lnum, end_lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, (end_lnum or lnum) + 1, false)
  local numbered = {}
  for i, line in ipairs(lines) do
    table.insert(numbered, string.format("%4d | %s", lnum + i, line))
  end
  return table.concat(numbered, "\n")
end

---Yank diagnostic with its context
---@param config table
---@param items_or_item table|table[]
---@param state table
---@return boolean
function M.yank_diagnostic_with_context(config, items_or_item, state)
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
---@param config table
---@param items_or_item table|table[]
---@param state table
function M.add_to_codecompanion(config, items_or_item, state)
  local items = vim.islist(items_or_item) and items_or_item or { items_or_item }
  local texts = {}

  for _, item in ipairs(items) do
    local value = item.value
    local source = value.diagnostic.source or "N/A"
    local text = string.format(
      [[
Diagnostic: %s
Severity: %s
Source: %s
Location: Line %d, Column %d
Context:
```%s
%s
```]],
      value.diagnostic.message,
      value.severity,
      source,
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

---Open diagnostic in vertical split
---@param config table
---@param items_or_item table|table[]
---@param module_state table
function M.open_in_vertical_split(config, items_or_item, module_state)
  local item = vim.islist(items_or_item) and items_or_item[1] or items_or_item
  selecta.open_in_split(item, "vertical", state)
  return false
end

---Open diagnostic in horizontal split
---@param config table
---@param items_or_item table|table[]
---@param module_state table
function M.open_in_horizontal_split(config, items_or_item, module_state)
  local item = vim.islist(items_or_item) and items_or_item[1] or items_or_item
  selecta.open_in_split(item, "horizontal", state)
  return false
end

---Show diagnostics picker
---@param config table
---@param scope string
function M.show(config, scope)
  scope = scope or "current"
  M.config = config

  -- Store current window info
  state.original_win = api.nvim_get_current_win()
  state.original_buf = api.nvim_get_current_buf()
  state.original_pos = api.nvim_win_get_cursor(state.original_win)

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
  local items = diagnostics_to_selecta_items(diagnostics, buffer_info, config)

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
  selecta.pick(items, {
    title = titles[scope] or "Diagnostics",
    window = config.window,
    current_highlight = config.current_highlight,
    debug = config.debug,
    custom_keymaps = config.custom_keymaps,
    initial_index = current_index,
    preserve_order = true,
    pre_filter = function(items, query)
      local filter = parse_diagnostic_filter(query, config)
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
      return format_diagnostic_item(item, config)
    end,
    hooks = {
      on_render = function(buf, filtered_items)
        apply_diagnostic_highlights(buf, filtered_items, config)
      end,
    },
    on_move = function(item)
      if item and item.value then
        preview_utils.preview_symbol(item, state.original_win, state.preview_state, {
          highlight_fn = preview_highlight_fn,
        })
      end
    end,
    on_select = function(item)
      api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
      if
        state.preview_state
        and state.preview_state.scratch_buf
        and api.nvim_buf_is_valid(state.preview_state.scratch_buf)
      then
        api.nvim_buf_clear_namespace(state.preview_state.scratch_buf, state.preview_ns, 0, -1)
      end
      if
        state.original_win
        and state.original_pos
        and state.original_buf
        and api.nvim_win_is_valid(state.original_win)
        and api.nvim_buf_is_valid(state.original_buf)
      then
        api.nvim_win_call(state.original_win, function()
          api.nvim_win_set_buf(state.original_win, item.value.bufnr)
          api.nvim_win_set_cursor(state.original_win, { item.value.lnum + 1, item.value.col })
          vim.cmd("normal! zz")
        end)
      end
    end,
    on_cancel = function()
      api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
      if state.preview_state then
        preview_utils.restore_window_state(state.original_win, state.preview_state)
      end
    end,
  })
end

-- API functions for different scopes with config parameter
function M.show_current_diagnostics(config)
  M.show(config, "current")
end

function M.show_buffer_diagnostics(config)
  M.show(config, "buffers")
end

function M.show_workspace_diagnostics(config)
  M.show(config, "workspace")
end

return M
