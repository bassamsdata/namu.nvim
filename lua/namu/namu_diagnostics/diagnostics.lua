--[[ Namu Diagnostics Implementation
This file contains the actual implementation of the diagnostics module.
It is loaded only when required to improve startup performance.
]]

-- Dependencies are only loaded when the module is actually used
local selecta = require("namu.selecta.selecta")
local preview_utils = require("namu.core.preview_utils")
local notify_opts = { title = "Namu", icon = require("namu").config.icon }
local logger = require("namu.utils.logger")
local api = vim.api
local M = {}
M.loaded_workspace_diagnostics = false
M.cached_workspace_items = {}

-- Store original window and position for preview
local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
  preview_ns = api.nvim_create_namespace("diagnostic_preview"),
  preview_state = nil,
}
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

---Format diagnostic for display in the picker
---@param item table
---@param config table
---@param available_width number|nil
---@return string
local function format_diagnostic_item(item, config, available_width)
  if item.is_auxiliary then
    -- Format: filename • [line:col] • source
    local filename = ""
    if item.value.bufnr then
      local bufname = api.nvim_buf_get_name(item.value.bufnr)
      if bufname and bufname ~= "" then
        filename = vim.fn.fnamemodify(bufname, ":t") -- Just filename, no brackets
      end
    end
    local location = string.format("[%d:%d]", item.value.lnum + 1, item.value.col + 1)
    local source = item.value.diagnostic.source or ""
    -- Build the line: [line:col] filename • source
    local parts = {}
    if filename ~= "" then
      table.insert(parts, filename)
    end
    table.insert(parts, location)
    if source ~= "" then
      table.insert(parts, source)
    end

    return "    " .. table.concat(parts, " • ")
  end

  -- Handle main diagnostic item (same as your current version)
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
  -- Format message - truncate if width is provided
  local message = value.diagnostic.message:gsub("\n", " ")
  if available_width then
    local icon_width = vim.api.nvim_strwidth(icon) + 1
    local prefix_width = vim.api.nvim_strwidth(prefix_padding)
    local available_for_message = available_width - prefix_width - icon_width - 5

    if vim.api.nvim_strwidth(message) > available_for_message and available_for_message > 10 then
      message = message:sub(1, available_for_message - 3) .. "..."
    end
  end

  return prefix_padding .. icon .. " " .. message
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
local function diagnostics_to_selecta_items(diagnostics, buffer_info, config)
  local items = {}
  local seen_diagnostics = {} -- Track unique diagnostics
  local single_buffer = type(buffer_info) == "number"
  local bufnr = single_buffer and buffer_info or nil

  for idx, diagnostic in ipairs(diagnostics) do
    local diag_bufnr = diagnostic.bufnr or bufnr
    if not diag_bufnr then
      goto continue
    end
    -- Create unique key for this diagnostic
    local diag_key = string.format(
      "%d:%d:%d:%s",
      diag_bufnr,
      diagnostic.lnum,
      diagnostic.col,
      diagnostic.message:sub(1, 50) -- First 50 chars to handle similar messages
    )
    -- Skip if we've already seen this diagnostic
    if seen_diagnostics[diag_key] then
      goto continue
    end
    seen_diagnostics[diag_key] = true
    local severity = get_severity_info(diagnostic.severity)
    local file_name = ""
    -- Add file name for multi-buffer views
    if not single_buffer then
      local buf_name = buffer_info[diag_bufnr] or "[No Name]"
      file_name = vim.fn.fnamemodify(buf_name, ":t") .. " - "
    end
    -- Create main diagnostic item
    local main_item = {
      text = format_diagnostic(diagnostic, file_name), -- Keep original for search
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
      group_type = "diagnostic_main",
      group_id = "diag_" .. idx,
    }
    table.insert(items, main_item)

    -- Create auxiliary item for location info
    local aux_item = {
      text = format_diagnostic(diagnostic, file_name), -- SAME text as main for filtering!
      value = main_item.value, -- Same value as main item
      icon = "",
      kind = severity,
      group_type = "diagnostic_aux",
      group_id = "diag_" .. idx,
      is_auxiliary = true,
    }
    table.insert(items, aux_item)

    ::continue::
  end

  -- Sort by buffer, then by line, then by column, but keep groups together
  table.sort(items, function(a, b)
    if a.value.bufnr ~= b.value.bufnr then
      return a.value.bufnr < b.value.bufnr
    elseif a.value.lnum ~= b.value.lnum then
      return a.value.lnum < b.value.lnum
    elseif a.value.col ~= b.value.col then
      return a.value.col < b.value.col
    else
      -- When position is the same, sort by group_id first, then by type within group
      if a.group_id ~= b.group_id then
        -- Different diagnostics - sort by group_id (which includes the index)
        local a_idx = tonumber(a.group_id:match("diag_(%d+)"))
        local b_idx = tonumber(b.group_id:match("diag_(%d+)"))
        return a_idx < b_idx
      else
        -- Same diagnostic group - main comes before aux
        return (a.group_type == "diagnostic_main") and (b.group_type == "diagnostic_aux")
      end
    end
  end)

  return items
end

local function apply_diagnostic_highlights(buf, filtered_items, config)
  local ns_id = api.nvim_create_namespace("namu_diagnostics_picker")
  api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  for idx, item in ipairs(filtered_items) do
    local line = idx - 1 -- 0-indexed for extmarks
    local value = item.value
    if not item.is_auxiliary then
      -- Main diagnostic line - apply severity highlighting
      local severity = get_severity_info(value.diagnostic.severity)
      local hl_group = config.highlights[severity]
      -- Get the line from buffer
      local lines = api.nvim_buf_get_lines(buf, line, line + 1, false)
      if #lines == 0 then
        goto continue
      end
      local line_text = lines[1]
      -- Highlight the entire diagnostic message line with severity color
      api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
        end_row = line,
        end_col = #line_text,
        hl_group = hl_group,
        priority = 110,
      })
    else
      -- Auxiliary line - highlight parts: [5:24] • file.lua • pylsp
      local lines = api.nvim_buf_get_lines(buf, line, line + 1, false)
      if #lines == 0 then
        goto continue
      end

      local line_text = lines[1]
      local first_bullet = line_text:find(" • ")
      if first_bullet then
        -- Highlight filename
        api.nvim_buf_set_extmark(buf, ns_id, line, 0, {
          end_row = line,
          end_col = first_bullet - 1,
          hl_group = "String",
          priority = 110,
        })
        -- 2. Highlight location (between first and second bullet)
        local second_bullet = line_text:find(" • ", first_bullet + 3)
        if second_bullet then
          local location_start = first_bullet + 3
          local location_end = second_bullet - 1
          api.nvim_buf_set_extmark(buf, ns_id, line, location_start - 1, {
            end_row = line,
            end_col = location_end,
            hl_group = "Directory",
            priority = 100,
          })
          -- 3. Highlight source (after second bullet)
          local source_start = second_bullet + 3
          api.nvim_buf_set_extmark(buf, ns_id, line, source_start - 1, {
            end_row = line,
            end_col = #line_text,
            hl_group = "Comment",
            priority = 110,
          })
        else
          -- Only filename and location, highlight location to end of line
          local location_start = first_bullet + 3
          api.nvim_buf_set_extmark(buf, ns_id, line, location_start - 1, {
            end_row = line,
            end_col = #line_text,
            hl_group = "Directory",
            priority = 100,
          })
        end
      end
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
---@return table, number|nil
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

---Get all files in the workspace using git
---@return string[] Array of file paths or empty array on failure
local function get_workspace_files()
  local output = vim.fn.systemlist("git ls-files")
  if vim.v.shell_error ~= 0 then
    return {}
  end
  -- Get list of all open buffers
  local open_buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local bufname = vim.api.nvim_buf_get_name(bufnr)
      if bufname and bufname ~= "" then
        -- Use absolute paths for comparison
        local abs_path = vim.fn.fnamemodify(bufname, ":p")
        open_buffers[abs_path] = true
      end
    end
  end

  -- Convert paths to absolute
  -- Filter out already open files
  local filtered_files = {}
  for _, path in ipairs(output) do
    local abs_path = vim.fn.fnamemodify(path, ":p")
    if not open_buffers[abs_path] then
      table.insert(filtered_files, abs_path)
    end
  end

  return filtered_files
end

---Start loading workspace files via LSP
---@param workspace_files table List of file paths
---@param lsp_utils table LSP utilities module
---@return table Map of processed client IDs
local function start_loading_workspace_files(workspace_files, lsp_utils, config, status_provider)
  -- Track which clients have been processed
  M.loaded_clients = M.loaded_clients or {}
  local processed_clients = {}

  -- Process clients and files in batches
  local get_clients_fn = vim.lsp.get_clients
  local all_clients = get_clients_fn()
  local files_by_client = {}
  local progress_total = 0

  -- First, organize files by client
  for _, client in ipairs(all_clients) do
    client = lsp_utils.ensure_client_compatibility(client)

    -- Skip already processed clients
    if vim.tbl_contains(M.loaded_clients, client.id) then
      goto continue
    end

    -- Check capabilities
    if not vim.tbl_get(client.server_capabilities, "textDocumentSync", "openClose") then
      goto continue
    end

    -- Collect files for this client
    local client_files = {}
    for _, path in ipairs(workspace_files) do
      local filetype = vim.filetype.match({ filename = path })
      if filetype and client.config.filetypes and vim.tbl_contains(client.config.filetypes, filetype) then
        table.insert(client_files, { path = path, filetype = filetype })
      end
    end

    -- If we have files, store them
    if #client_files > 0 then
      files_by_client[client.id] = {
        client = client,
        files = client_files,
      }
      processed_clients[client.id] = true
      progress_total = progress_total + #client_files
    end

    ::continue::
  end

  -- Update status with initial count
  if status_provider and progress_total > 0 then
    status_provider(string.format("Loading %d files", progress_total))
  end

  -- Process files in small batches to avoid blocking
  local processed = 0
  local function process_batch(client_id, files, start_index, batch_size)
    local client_info = files_by_client[client_id]
    if not client_info then
      return
    end

    local client = client_info.client
    local end_index = math.min(start_index + batch_size - 1, #files)

    -- Process this batch
    for i = start_index, end_index do
      local file = files[i]
      local ok, content = pcall(function()
        return table.concat(vim.fn.readfile(file.path), "\n")
      end)
      if ok then
        client.notify("textDocument/didOpen", {
          textDocument = {
            uri = vim.uri_from_fname(file.path),
            version = 0,
            text = content,
            languageId = file.filetype,
          },
        })
      end
      processed = processed + 1

      -- Update status periodically
      if status_provider and (processed % 5 == 0 or processed == progress_total) then
        local percentage = math.floor((processed / progress_total) * 100)
        status_provider(string.format("Loading files (%d%%)", percentage))
      end
    end

    -- Schedule next batch if needed
    if end_index < #files then
      vim.defer_fn(function()
        process_batch(client_id, files, end_index + 1, batch_size)
      end, 0) -- Process next batch on next event loop
    end
  end

  -- Start processing for each client
  for client_id, info in pairs(files_by_client) do
    process_batch(client_id, info.files, 1, 20) -- Process 20 files at a time

    -- Save client as processed
    if not vim.tbl_contains(M.loaded_clients, client_id) then
      table.insert(M.loaded_clients, client_id)
    end
  end

  return processed_clients
end

---Create an async source for workspace diagnostics with completion flag
---@param config table Configuration table
---@return function Source factory function
local function create_async_diagnostics_source(config)
  local ASYNC_CONFIG = {
    MAX_UPDATES = 4,
    MIN_STABLE_UPDATES = 2,
    MAX_OSCILLATIONS = 3,
    INITIAL_DELAY = 500,
    UPDATE_DELAY_BASE = 1000,
    UPDATE_DELAY_MAX = 2000,
  }
  -- Extract diagnostics fetching to avoid repetition
  local function get_current_diagnostics_items()
    local current_diagnostics, current_buffer_info = get_diagnostics_for_scope("workspace")
    return diagnostics_to_selecta_items(current_diagnostics, current_buffer_info, config)
  end
  -- Mark items as fully loaded and cleanup
  local function mark_fully_loaded(picker_opts)
    if picker_opts then
      picker_opts.items_fully_loaded = true
      picker_opts.async_source = nil
      logger.log("DIAGNOSTICS: Marked items as fully loaded")
    end
  end

  -- Clear loading status
  local function clear_loading_status(status_provider)
    if status_provider then
      status_provider("")
    end
  end

  return function(query, picker_opts)
    return function(callback, status_provider)
      -- Early return if async already started or completed
      if picker_opts and (picker_opts.items_fully_loaded or picker_opts.async_loading_started) then
        logger.log("DIAGNOSTICS: Async already started or completed, using existing data")
        local current_items = get_current_diagnostics_items()
        clear_loading_status(status_provider)
        callback(current_items)
        return
      end
      -- Initialize request tracking
      local request_id = tostring(vim.uv.now()) .. "_" .. math.random(1000, 9999)
      if picker_opts then
        picker_opts.current_request_id = request_id
        picker_opts.async_loading_started = true
      end
      -- Show initial status
      if status_provider then
        status_provider("Loading results")
      end
      local workspace_files = get_workspace_files()
      if #workspace_files == 0 then
        -- Fallback to direct diagnostics (no git repo or no files)
        if status_provider then
          status_provider("Getting workspace diagnostics")
        end
        local current_items = get_current_diagnostics_items()
        if #current_items == 0 then
          vim.notify("No workspace diagnostics found", vim.log.levels.INFO, notify_opts)
          return
        end
        callback(current_items)
        mark_fully_loaded(picker_opts)
        return
      end
      local lsp_utils = require("namu.namu_symbols.lsp")
      start_loading_workspace_files(workspace_files, lsp_utils, config, status_provider)
      local update_state = {
        count = 0,
        last_diagnostic_count = 0,
        stable_count = 0,
        oscillation_count = 0,
      }

      local function is_request_valid()
        return picker_opts and picker_opts.current_request_id == request_id and not picker_opts.items_fully_loaded
      end

      local function update_diagnostics()
        if not is_request_valid() then
          logger.log("DIAGNOSTICS: Request no longer valid, stopping updates")
          return
        end
        if status_provider then
          status_provider(
            string.format("Processing diagnostics (%d/%d)", update_state.count + 1, ASYNC_CONFIG.MAX_UPDATES)
          )
        end
        local current_items = get_current_diagnostics_items()
        local current_count = #current_items
        -- Update stability tracking
        if current_count == update_state.last_diagnostic_count then
          update_state.stable_count = update_state.stable_count + 1
          update_state.oscillation_count = 0
        else
          update_state.stable_count = 0
          update_state.oscillation_count = update_state.oscillation_count + 1
        end
        update_state.last_diagnostic_count = current_count
        -- Return current results
        callback(current_items)
        -- Determine if we should continue
        update_state.count = update_state.count + 1
        local should_continue = update_state.count < ASYNC_CONFIG.MAX_UPDATES
          and update_state.stable_count < ASYNC_CONFIG.MIN_STABLE_UPDATES
          and update_state.oscillation_count < ASYNC_CONFIG.MAX_OSCILLATIONS

        if should_continue then
          local delay = math.min(ASYNC_CONFIG.UPDATE_DELAY_BASE * update_state.count, ASYNC_CONFIG.UPDATE_DELAY_MAX)
          vim.defer_fn(update_diagnostics, delay)
          logger.log("DIAGNOSTICS: Update cycle continues")
        else
          logger.log("DIAGNOSTICS: Update cycle completed")
          mark_fully_loaded(picker_opts)
          clear_loading_status(status_provider)
        end
      end
      -- Start the update cycle
      vim.defer_fn(update_diagnostics, ASYNC_CONFIG.INITIAL_DELAY)
    end
  end
end

---@return number|nil
---@param items table[]
---@return number|nil
local function find_current_diagnostic_index(items)
  local cursor = api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1] - 1 -- Convert to 0-based

  -- First try to find exact line match
  for idx, item in ipairs(items) do
    local diag = item.value.diagnostic
    if diag.lnum == cursor_line then
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

  return closest_idx
end

---Deduplicate diagnostic items by group_id (removes auxiliary duplicates)
---@param items table[]
---@return table[]
local function deduplicate_diagnostic_items(items)
  local seen_groups = {}
  local deduplicated = {}

  for _, item in ipairs(items) do
    if item.group_id and not seen_groups[item.group_id] then
      -- Only include the main diagnostic item, skip auxiliary
      if item.group_type == "diagnostic_main" then
        seen_groups[item.group_id] = true
        table.insert(deduplicated, item)
      end
    elseif not item.group_id then
      -- Include items without group_id (shouldn't happen in diagnostics, but safety)
      table.insert(deduplicated, item)
    end
  end

  return deduplicated
end

---Count logical diagnostic items (ignoring auxiliary items for UI display)
---@param items table[]
---@return number
local function count_logical_diagnostic_items(items)
  local count = 0
  local seen_groups = {}

  for _, item in ipairs(items) do
    if item.group_id and not seen_groups[item.group_id] then
      seen_groups[item.group_id] = true
      count = count + 1
    elseif not item.group_id then
      -- Count items without group_id (shouldn't happen in diagnostics, but safety)
      count = count + 1
    end
  end

  return count
end

---@param config table
---@param items_or_item table|table[]
---@param state table
---@return boolean
function M.yank_diagnostic_with_context(config, items_or_item, state)
  local raw_items = vim.islist(items_or_item) and items_or_item or { items_or_item }
  local items = deduplicate_diagnostic_items(raw_items)
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

  return false
end

---@param config table
---@param items_or_item table|table[]
---@param state table
function M.add_to_codecompanion(config, items_or_item, state)
  local status, codecompanion = pcall(require, "codecompanion")
  if not status then
    return
  end
  local raw_items = vim.islist(items_or_item) and items_or_item or { items_or_item }
  local items = deduplicate_diagnostic_items(raw_items)
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

  local chat = codecompanion.last_chat()
  if not chat then
    chat = codecompanion.chat()
    if not chat then
      return vim.notify("Could not create chat buffer", vim.log.levels.WARN, notify_opts)
    end
  end
  chat:add_buf_message({
    role = require("codecompanion.config").constants.USER_ROLE,
    content = table.concat(texts, "\n\n"),
  })
  chat.ui:open()
end

---Send diagnostic to CodeCompanion inline for AI-powered fixing
---@param config table
---@param items_or_item table|table[]
---@param picker_state table
---@return boolean
function M.send_to_codecompanion_inline(config, items_or_item, picker_state)
  local item = vim.islist(items_or_item) and items_or_item[1] or items_or_item
  if not item or not item.value or not item.value.diagnostic then
    vim.notify("No diagnostic selected", vim.log.levels.WARN, notify_opts)
    return false
  end
  -- Check if CodeCompanion is available
  local status, _ = pcall(require, "codecompanion")
  if not status then
    vim.notify("CodeCompanion not found", vim.log.levels.WARN, notify_opts)
    return false
  end
  local diagnostic = item.value.diagnostic
  local bufnr = item.value.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("Invalid buffer for diagnostic", vim.log.levels.WARN, notify_opts)
    return false
  end
  local original_win = state.original_win
  local target_winnr = original_win
  -- If original window is not valid or doesn't have our buffer, find a suitable window
  if
    not original_win
    or not vim.api.nvim_win_is_valid(original_win)
    or vim.api.nvim_win_get_buf(original_win) ~= bufnr
  then
    -- Find a window that has our target buffer
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        target_winnr = win
        break
      end
    end
    if not target_winnr or vim.api.nvim_win_get_buf(target_winnr) ~= bufnr then
      vim.cmd("split")
      target_winnr = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(target_winnr, bufnr)
    end
  end
  vim.api.nvim_set_current_win(target_winnr)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(target_winnr, { diagnostic.lnum + 1, diagnostic.col })
  local context_lines = {}
  local selection_start_line, selection_end_line
  local selection_start_col, selection_end_col

  -- Emulate exactly how CodeCompanion gets lines using nvim_buf_get_lines
  -- Get a few lines around the diagnostic for context
  -- Calculate the same range that CodeCompanion would use for a visual selection around the diagnostic
  selection_start_line = math.max(1, diagnostic.lnum + 1 - 2) -- diagnostic.lnum is 0-based, convert to 1-based and go 2 lines up
  selection_end_line = math.min(vim.api.nvim_buf_line_count(bufnr), diagnostic.lnum + 1 + 4) -- 4 lines down from diagnostic

  -- Calculate column positions based on diagnostic position
  local diagnostic_line = diagnostic.lnum + 1 -- Convert to 1-based
  if diagnostic_line >= selection_start_line and diagnostic_line <= selection_end_line then
    -- If diagnostic is within our selection range, use its exact column position
    selection_start_col = diagnostic.col + 1 -- Convert from 0-based to 1-based
    -- If diagnostic has end_col, use it; otherwise extend to end of error or reasonable length
    if diagnostic.end_col then
      selection_end_col = diagnostic.end_col
    else
      -- Get the line content to determine a reasonable end column
      local line_content = vim.api.nvim_buf_get_lines(bufnr, diagnostic.lnum, diagnostic.lnum + 1, false)[1] or ""
      selection_end_col = math.min(#line_content, selection_start_col + 10) -- Reasonable default span
    end
  else
    -- If diagnostic is outside our context range, select full lines
    selection_start_col = 1
    selection_end_col = 0 -- 0 means end of line in vim
  end

  -- Get lines exactly like CodeCompanion does: using nvim_buf_get_lines
  local start_line_0 = selection_start_line - 1 -- Convert to 0-based for nvim_buf_get_lines
  local end_line_0 = selection_end_line
  context_lines = vim.api.nvim_buf_get_lines(bufnr, start_line_0, end_line_0, false)

  -- Create context for CodeCompanion inline
  local context = {
    bufnr = bufnr,
    winnr = target_winnr,
    buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr }) or "",
    filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr }),
    filename = vim.api.nvim_buf_get_name(bufnr),
    line_count = vim.api.nvim_buf_line_count(bufnr),
    mode = "v",
    is_normal = false,
    start_line = selection_start_line,
    end_line = selection_end_line,
    start_col = selection_start_col,
    end_col = selection_end_col,
    is_visual = true, -- Treat as visual selection to include context
    lines = context_lines,
    cursor_pos = { selection_start_line, selection_start_col }, -- Start of selection, like CodeCompanion
  }
  -- Create a more detailed diagnostic-specific prompt that matches CodeCompanion's style
  local severity_text = item.value.severity:lower()
  local source_text = diagnostic.source and (" from " .. diagnostic.source) or ""
  local prompt = string.format(
    "Please fix the %s%s in this %s code: %s",
    severity_text,
    source_text,
    context.filetype,
    diagnostic.message
  )
  local inline_strategy = require("codecompanion.strategies.inline")
  local inline = inline_strategy.new({
    context = context,
    placement = "replace",
  })
  if not inline then
    vim.notify("Failed to create CodeCompanion inline instance", vim.log.levels.ERROR, notify_opts)
    return false
  end
  inline:prompt(prompt)
  logger.log("CodeCompanion inline started for diagnostic fix")
  return true
end

function M.open_in_vertical_split(config, items_or_item)
  local item = vim.islist(items_or_item) and items_or_item[1] or items_or_item
  selecta.open_in_split(item, "vertical", state)
  return true
end

function M.open_in_horizontal_split(config, items_or_item, module_state)
  local item = vim.islist(items_or_item) and items_or_item[1] or items_or_item
  selecta.open_in_split(item, "horizontal", state)
  return true
end
---Cleanup preview highlights from all buffers
---Invoke code actions for the diagnostic
---@param config table
---@param items_or_item table|table[]
---@param picker_state table
---@return boolean
function M.invoke_code_action(config, items_or_item, picker_state)
  local item = vim.islist(items_or_item) and items_or_item[1] or items_or_item
  if not item or not item.value or not item.value.diagnostic then
    vim.notify("No diagnostic selected", vim.log.levels.WARN, notify_opts)
    return false
  end
  local diagnostic = item.value.diagnostic
  local bufnr = item.value.bufnr
  -- Validate buffer
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("Invalid buffer for diagnostic", vim.log.levels.WARN, notify_opts)
    return false
  end
  local current_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(current_win, { diagnostic.lnum + 1, diagnostic.col })
  vim.lsp.buf.code_action()
  return true
end

---Cleanup preview highlights from all buffers
---@param state table Module state
local function cleanup_preview_highlights(state)
  -- Clear from original buffer
  pcall(api.nvim_buf_clear_namespace, state.original_buf, state.preview_ns, 0, -1)
  if state.preview_state then
    pcall(api.nvim_buf_clear_namespace, state.original_buf, state.preview_state.preview_ns, 0, -1)
    -- Clear diagnostic-specific preview highlights from all buffers
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_valid(bufnr) then
        pcall(api.nvim_buf_clear_namespace, bufnr, state.preview_state.preview_ns, 0, -1)
      end
    end
  end
end

function M.create_keymap_handlers(config, state)
  return {
    vertical_split = function(items_or_item, picker_state)
      return M.open_in_vertical_split(config, items_or_item, state)
    end,
    horizontal_split = function(items_or_item, picker_state)
      return M.open_in_horizontal_split(config, items_or_item, state)
    end,
    yank = function(items_or_item, picker_state)
      return M.yank_diagnostic_with_context(config, items_or_item, state)
    end,
    codecompanion = function(items_or_item, picker_state)
      return M.add_to_codecompanion(config, items_or_item, state)
    end,
    codecompanion_inline = function(items_or_item, picker_state)
      return M.send_to_codecompanion_inline(config, items_or_item, picker_state)
    end,
    bookmark = function(items_or_item, picker_state)
      local bookmarks = require("namu.bookmarks")
      return bookmarks.create_keymap_handler()(items_or_item, picker_state)
    end,
    code_action = function(items_or_item, picker_state)
      return M.invoke_code_action(config, items_or_item, picker_state)
    end,
    quickfix = function(items_or_item, picker_state)
      -- Handle quickfix specially for diagnostics

      local items_to_send

      -- Check if we have selections
      if picker_state and picker_state.selected_count and picker_state.selected_count > 0 then
        -- Use selected items and deduplicate them
        local selected_items = picker_state:get_selected_items()
        items_to_send = deduplicate_diagnostic_items(selected_items)
      elseif vim.islist(items_or_item) then
        -- Multiple items passed (shouldn't happen for single item selection)
        items_to_send = deduplicate_diagnostic_items(items_or_item)
      else
        -- No selections - send ALL filtered items (like other modules)
        if picker_state and picker_state.filtered_items then
          items_to_send = deduplicate_diagnostic_items(picker_state.filtered_items)
        else
          items_to_send = deduplicate_diagnostic_items({ items_or_item })
        end
      end

      return selecta.add_to_quickfix(items_to_send, state)
    end,
  }
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
  local handlers = M.create_keymap_handlers(config, state)
  if config.custom_keymaps then
    if config.custom_keymaps.vertical_split then
      config.custom_keymaps.vertical_split.handler = handlers.vertical_split
    end
    if config.custom_keymaps.horizontal_split then
      config.custom_keymaps.horizontal_split.handler = handlers.horizontal_split
    end
    if config.custom_keymaps.yank then
      config.custom_keymaps.yank.handler = handlers.yank
    end
    if config.custom_keymaps.codecompanion then
      config.custom_keymaps.codecompanion.handler = handlers.codecompanion
    end
    if config.custom_keymaps.codecompanion_inline then
      config.custom_keymaps.codecompanion_inline.handler = handlers.codecompanion_inline
    end
    if config.custom_keymaps.code_action then
      config.custom_keymaps.code_action.handler = handlers.code_action
    end
    if config.custom_keymaps.quickfix then
      config.custom_keymaps.quickfix.handler = handlers.quickfix
    end
  end

  -- Save window state for potential restoration
  if not state.preview_state then
    state.preview_state = preview_utils.create_preview_state("diagnostic_preview")
  end
  preview_utils.save_window_state(state.original_win, state.preview_state)

  -- Get diagnostics for selected scope
  local diagnostics, buffer_info = get_diagnostics_for_scope(scope)
  if #diagnostics == 0 then
    vim.notify("No diagnostics found", vim.log.levels.INFO, notify_opts)
    return
  end

  -- Convert to selecta items
  local items = diagnostics_to_selecta_items(diagnostics, buffer_info or api.nvim_get_current_buf(), config)

  -- Find current diagnostic (for current file only)
  local current_index = nil
  if scope == "current" then
    current_index = find_current_diagnostic_index(items)
  end

  -- Create picker title based on scope
  local titles = {
    current = " Namu Diagnostics - Current File ",
    buffers = " Namu Diagnostics - Open Buffers ",
    workspace = " Namu Diagnostics - Workspace ",
  }

  -- Show picker
  -- Create pick options with only the necessary modifications
  local pick_options = vim.tbl_deep_extend("force", config, {
    title = config.title or titles[scope] or " Namu Diagnostics ",
    initial_index = current_index,
    preserve_order = true,
    grouped_navigation = true,
    multiline_items = true,
    logical_item_counter = count_logical_diagnostic_items,

    -- These are the custom functions specific to diagnostics
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
      -- Calculate available width from current window
      local available_width = nil
      if config.window and config.window.max_width then
        available_width = config.window.max_width + 10 -- Account for borders/padding
      end

      if item.is_placeholder then
        return item.text
      end
      return format_diagnostic_item(item, config, available_width)
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
      if
        state.original_win
        and state.original_pos
        and state.original_buf
        and api.nvim_win_is_valid(state.original_win)
        and api.nvim_buf_is_valid(state.original_buf)
      then
        api.nvim_set_current_win(state.original_win)
        api.nvim_win_call(state.original_win, function()
          api.nvim_set_option_value("buflisted", true, { buf = item.value.bufnr })
          api.nvim_win_set_buf(state.original_win, item.value.bufnr)
          api.nvim_win_set_cursor(state.original_win, { item.value.lnum + 1, item.value.col })
          vim.fn.setreg("#", state.original_buf)
          vim.cmd("normal! zz")
        end)
      end
    end,

    on_cancel = function()
      if state.preview_state then
        preview_utils.restore_window_state(state.original_win, state.preview_state)
      end
    end,

    on_close = function()
      pcall(api.nvim_buf_clear_namespace, state.original_buf, state.preview_ns, 0, -1)
      pcall(api.nvim_buf_clear_namespace, state.original_buf, state.preview_state.preview_ns, 0, -1)
      -- TODO: pass items insitead of this
      for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_valid(bufnr) then
          pcall(api.nvim_buf_clear_namespace, bufnr, state.preview_state.preview_ns, 0, -1)
        end
      end
    end,
  })

  -- Add config options to pick_options
  pick_options = vim.tbl_deep_extend("force", pick_options, {
    window = config.window,
    current_highlight = config.current_highlight,
    debug = config.debug,
    custom_keymaps = config.custom_keymaps,
  })

  -- Show picker
  selecta.pick(items, pick_options)
end

-- API functions for different scopes with config parameter
function M.show_current_diagnostics(config)
  M.show(config, "current")
end

function M.show_buffer_diagnostics(config)
  M.show(config, "buffers")
end

function M.show_workspace_diagnostics(config)
  -- Store current window info
  state.original_win = api.nvim_get_current_win()
  state.original_buf = api.nvim_get_current_buf()
  state.original_pos = api.nvim_win_get_cursor(state.original_win)

  -- Create keymap handlers and update config
  local handlers = M.create_keymap_handlers(config, state)
  if config.custom_keymaps then
    if config.custom_keymaps.vertical_split then
      config.custom_keymaps.vertical_split.handler = handlers.vertical_split
    end
    if config.custom_keymaps.horizontal_split then
      config.custom_keymaps.horizontal_split.handler = handlers.horizontal_split
    end
    if config.custom_keymaps.yank then
      config.custom_keymaps.yank.handler = handlers.yank
    end
    if config.custom_keymaps.codecompanion then
      config.custom_keymaps.codecompanion.handler = handlers.codecompanion
    end
    if config.custom_keymaps.codecompanion_inline then
      config.custom_keymaps.codecompanion_inline.handler = handlers.codecompanion_inline
    end
    if config.custom_keymaps.code_action then
      config.custom_keymaps.code_action.handler = handlers.code_action
    end
    if config.custom_keymaps.quickfix then
      config.custom_keymaps.quickfix.handler = handlers.quickfix
    end
  end

  -- Save window state for potential restoration
  if not state.preview_state then
    state.preview_state = preview_utils.create_preview_state("diagnostic_preview")
  end
  preview_utils.save_window_state(state.original_win, state.preview_state)

  -- Check if we've already loaded diagnostics for this session
  local session_loaded = M.workspace_session_loaded or false

  local pick_options = vim.tbl_deep_extend("force", {}, {
    title = "Namu Diagnostics - Workspace",
    preserve_order = true,
    window = config.window,
    current_highlight = config.current_highlight,
    row_position = config.row_position,
    debug = config.debug,
    custom_keymaps = config.custom_keymaps,
    grouped_navigation = true,
    multiline_items = true,
    multiselect = config.multiselect,
    movement = config.movement,
    logical_item_counter = count_logical_diagnostic_items,
    items_fully_loaded = false,

    -- Filter function
    pre_filter = function(items, query)
      local filter = parse_diagnostic_filter(query, config)
      if filter then
        local filtered = vim.tbl_filter(function(item)
          -- Skip placeholders
          if item.is_placeholder then
            return false
          end

          local severity_num = item.value and item.value.diagnostic and item.value.diagnostic.severity or nil
          return severity_num == filter.severity
        end, items)
        return filtered, filter.remaining
      end
      return items, query
    end,

    formatter = function(item)
      if item.is_placeholder then
        return item.text
      end
      return format_diagnostic_item(item, config)
    end,

    hooks = {
      on_render = function(buf, filtered_items)
        -- Skip applying highlights for placeholder items
        if #filtered_items == 1 and filtered_items[1].is_placeholder then
          return
        end
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
      -- Skip placeholders
      if not item or not item.value then
        return
      end
      if
        state.original_win
        and state.original_pos
        and state.original_buf
        and api.nvim_win_is_valid(state.original_win)
        and api.nvim_buf_is_valid(state.original_buf)
      then
        api.nvim_set_current_win(state.original_win)
        api.nvim_win_call(state.original_win, function()
          api.nvim_set_option_value("buflisted", true, { buf = item.value.bufnr })
          api.nvim_win_set_buf(state.original_win, item.value.bufnr)
          api.nvim_win_set_cursor(state.original_win, { item.value.lnum + 1, item.value.col })
          vim.fn.setreg("#", state.original_buf)
          vim.cmd("normal! zz")
        end)
      end
    end,

    on_cancel = function()
      if state.preview_state then
        preview_utils.restore_window_state(state.original_win, state.preview_state)
      end
    end,

    on_close = function()
      -- Always clean up preview highlights when picker closes
      pcall(api.nvim_buf_clear_namespace, state.original_buf, state.preview_ns, 0, -1)
      pcall(api.nvim_buf_clear_namespace, state.original_buf, state.preview_state.preview_ns, 0, -1)
      -- Clear diagnostic-specific preview highlights from all buffers
      for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_valid(bufnr) then
          pcall(api.nvim_buf_clear_namespace, bufnr, state.preview_state.preview_ns, 0, -1)
        end
      end
    end,
  })
  -- Check if we need the async loading approach or can use direct diagnostics
  if session_loaded then
    -- We've already loaded workspace files in this session
    -- Just get current diagnostics directly from LSP
    local diagnostics, buffer_info = get_diagnostics_for_scope("workspace")
    if #diagnostics > 0 then
      local items = diagnostics_to_selecta_items(diagnostics, buffer_info or api.nvim_get_current_buf(), config)
      selecta.pick(items, pick_options)
    else
      vim.notify("No workspace diagnostics found", vim.log.levels.INFO, notify_opts)
      return
    end
  else
    -- First-time loading: use async approach with flag setting
    pick_options.async_source = create_async_diagnostics_source(config)
    local placeholder_items = {
      {
        text = "Loading workspace diagnostics...",
        icon = "󰍉",
        value = nil,
        is_placeholder = true,
      },
    }
    selecta.pick(placeholder_items, pick_options)
    M.workspace_session_loaded = true
    pick_options.items_fully_loaded = true
  end
end

return M
