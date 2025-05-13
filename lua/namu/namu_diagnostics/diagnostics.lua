--[[ Namu Diagnostics Implementation
This file contains the actual implementation of the diagnostics module.
It is loaded only when required to improve startup performance.
]]

-- Dependencies are only loaded when the module is actually used
local selecta = require("namu.selecta.selecta")
local preview_utils = require("namu.core.preview_utils")
local lsp = require("namu.namu_symbols.lsp")
local notify_opts = { title = "Namu", icon = require("namu").config.icon }
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
    vim.notify("Failed to get workspace files. Is this a git repository?", vim.log.levels.WARN, notify_opts)
    return {}
  end

  -- Convert paths to absolute
  return vim.tbl_map(function(path)
    return vim.fn.fnamemodify(path, ":p")
  end, output)
end

---Check if file should be processed for the given client
---@param path string File path
---@param current_file string Currently open file path
---@param client table LSP client
---@return boolean
local function should_process_file(path, current_file, client)
  -- Skip current file - it's already open
  if path == current_file then
    return false
  end

  -- Skip unreadable files
  if vim.fn.filereadable(path) ~= 1 then
    return false
  end

  -- Check if file type matches client's supported filetypes
  local filetype = vim.filetype.match({ filename = path })
  if not filetype or not client.config.filetypes then
    return false
  end

  return vim.tbl_contains(client.config.filetypes, filetype), filetype
end

---Notify LSP server about a file
---@param client table LSP client
---@param path string File path
---@param filetype string File type
---@return boolean success
local function notify_file_to_lsp(client, path, filetype)
  -- Read file content
  local ok, content = pcall(function()
    return table.concat(vim.fn.readfile(path), "\n")
  end)

  if not ok then
    return false
  end

  -- Notify LSP server about file
  local params = {
    textDocument = {
      uri = vim.uri_from_fname(path),
      version = 0,
      text = content,
      languageId = filetype,
    },
  }

  client.notify("textDocument/didOpen", params)
  return true
end

---Start loading workspace files via LSP
---@param workspace_files table List of file paths
---@param lsp_utils table LSP utilities module
---@return table Map of processed client IDs
local function start_loading_workspace_files(workspace_files, lsp_utils, config)
  -- Track which clients have been processed
  M.loaded_clients = M.loaded_clients or {}
  local processed_clients = {}
  local current_file = api.nvim_buf_get_name(api.nvim_get_current_buf())

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
      -- Skip current file and check filetype match
      if path ~= current_file then
        local filetype = vim.filetype.match({ filename = path })
        if filetype and client.config.filetypes and vim.tbl_contains(client.config.filetypes, filetype) then
          table.insert(client_files, { path = path, filetype = filetype })
        end
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

  -- Show initial progress if enabled
  if config.workspace_diagnostics.preload_progress then
    vim.notify(
      "Loading workspace diagnostics: preparing to process " .. progress_total .. " files",
      vim.log.levels.INFO
    )
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
    end

    -- Show progress if enabled
    if config.workspace_diagnostics.preload_progress and processed % 10 == 0 then
      vim.notify(
        string.format(
          "Loading workspace diagnostics: %d/%d files (%.1f%%)",
          processed,
          progress_total,
          (processed / progress_total) * 100
        ),
        vim.log.levels.INFO
      )
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
---Create an async source for workspace diagnostics
---@param config table Configuration table
---@return function Source factory function
local function create_async_diagnostics_source(config)
  -- Storage for loaded diagnostics
  local loaded = false
  local cached_items = {}
  local update_count = 0
  local max_updates = 5

  -- Return the async source function
  return function(query)
    return function(callback)
      -- If we've already loaded and in load_once mode, use cache
      if loaded and config.workspace_diagnostics.load_once then
        callback(cached_items)
        return
      end

      -- Initial loading - if we don't have any diagnostics yet, start loading
      if not loaded then
        -- First check for existing diagnostics
        local diagnostics, buffer_info = get_diagnostics_for_scope("workspace")
        if #diagnostics > 0 then
          -- We already have diagnostics - convert and use them
          local items = diagnostics_to_selecta_items(diagnostics, buffer_info, config)
          cached_items = items
          loaded = true
          callback(items)
          return
        end

        -- Start loading workspace files
        local workspace_files = get_workspace_files()
        if #workspace_files == 0 then
          callback({})
          return
        end

        -- Start the LSP notifications
        local lsp_utils = require("namu.namu_symbols.lsp")
        local clients_processed = start_loading_workspace_files(workspace_files, lsp_utils, config)

        -- Schedule periodic updates to collect diagnostics as they come in
        local function update_diagnostics()
          -- Get current diagnostics
          local current_diagnostics, current_buffer_info = get_diagnostics_for_scope("workspace")
          local current_items = diagnostics_to_selecta_items(current_diagnostics, current_buffer_info, config)

          -- Update cached items
          cached_items = current_items

          -- Call back with current items
          callback(current_items)

          -- Schedule next update if needed
          update_count = update_count + 1
          if update_count < max_updates then
            local delay = math.min(1000 * update_count, 3000) -- Increase delay for later updates
            vim.defer_fn(update_diagnostics, delay)
          else
            -- Final update - mark as loaded
            loaded = true
          end
        end

        -- Start the update cycle after initial delay
        vim.defer_fn(update_diagnostics, 500)
      end
    end
  end
end

---Process files for a single LSP client
---@param client table LSP client
---@param workspace_files table List of files
---@param current_file string Currently open file
---@return number Number of files processed
local function process_client_files(client, workspace_files, current_file)
  local file_count = 0

  for _, path in ipairs(workspace_files) do
    local should_process, filetype = should_process_file(path, current_file, client)
    if should_process then
      if notify_file_to_lsp(client, path, filetype) then
        file_count = file_count + 1
      end
    end
  end

  return file_count
end

---Load workspace diagnostics by notifying LSP servers about all files
---@param config table Plugin configuration
---@return boolean Success indicator
function M.joad_workspace_diagnostics(config)
  local workspace_files = get_workspace_files()
  if #workspace_files == 0 then
    return false
  end
  -- Track which clients have been processed
  M.loaded_clients = M.loaded_clients or {}
  local current_file = api.nvim_buf_get_name(api.nvim_get_current_buf())
  local current_bufnr = api.nvim_get_current_buf()
  local loaded_clients_count = 0

  -- Get all clients that support textDocument/didOpen
  local get_clients_fn = vim.lsp.get_clients
  local all_clients = get_clients_fn({ bufnr = current_bufnr })

  -- Process each LSP client
  for _, client in ipairs(all_clients) do
    -- Ensure compatibility (using your existing wrapper)
    client = lsp.ensure_client_compatibility(client)

    -- Skip already processed clients
    if vim.tbl_contains(M.loaded_clients, client.id) then
      goto continue
    end

    -- Check if client supports textDocument/didOpen
    if not vim.tbl_get(client.server_capabilities, "textDocumentSync", "openClose") then
      goto continue
    end

    -- Process this client's files
    local file_count = process_client_files(client, workspace_files, current_file)

    if file_count > 0 then
      table.insert(M.loaded_clients, client.id)
      loaded_clients_count = loaded_clients_count + 1
      -- TODO: no need for this notification
      vim.notify(string.format("Loaded %d files for %s", file_count, client.name), vim.log.levels.INFO, notify_opts)
    end

    ::continue::
  end

  if loaded_clients_count > 0 then
    -- TODO: No need for this one
    vim.notify(
      "Workspace diagnostics triggered for " .. loaded_clients_count .. " LSP clients",
      vim.log.levels.INFO,
      notify_opts
    )
    return true
  else
    -- TODO: no need for this one
    vim.notify("No files were loaded for workspace diagnostics", vim.log.levels.WARN, notify_opts)
    return false
  end
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

  vim.notify(string.format("Yanked %d diagnostic(s) with context", #items), notify_opts)
  return true
end

---Add diagnostic(s) to CodeCompanion
---@param config table
---@param items_or_item table|table[]
---@param state table
function M.add_to_codecompanion(config, items_or_item, state)
  local status, codecompanion = pcall(require, "codecompanion")
  if not status then
    return
  end
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
    vim.notify("No diagnostics found", vim.log.levels.INFO, notify_opts)
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
  -- Create pick options with only the necessary modifications
  local pick_options = vim.tbl_deep_extend("force", config, {
    title = titles[scope] or "Diagnostics",
    initial_index = current_index,
    preserve_order = true,

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
      api.nvim_buf_clear_namespace(state.original_buf, state.preview_state.preview_ns, 0, -1)
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
      api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
      api.nvim_buf_clear_namespace(state.original_buf, state.preview_state.preview_ns, 0, -1)
      if state.preview_state then
        preview_utils.restore_window_state(state.original_win, state.preview_state)
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

  -- Save window state for potential restoration
  if not state.preview_state then
    state.preview_state = preview_utils.create_preview_state("diagnostic_preview")
  end
  preview_utils.save_window_state(state.original_win, state.preview_state)

  -- Create placeholder items for when loading
  local placeholder_items = {
    {
      text = "Loading workspace diagnostics...",
      icon = "󰍉",
      value = nil,
      is_placeholder = true,
    },
  }

  -- Create pick options
  local pick_options = vim.tbl_deep_extend("force", {}, {
    title = "Diagnostics - Workspace",
    preserve_order = true,
    window = config.window,
    current_highlight = config.current_highlight,
    debug = config.debug,
    custom_keymaps = config.custom_keymaps,
    -- Add async source for workspace diagnostics
    async_source = create_async_diagnostics_source(config),
    -- Add load_once option to avoid re-querying
    load_once_mode = config.workspace_diagnostics.load_once,
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
      api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
      api.nvim_buf_clear_namespace(state.original_buf, state.preview_state.preview_ns, 0, -1)
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
      api.nvim_buf_clear_namespace(state.original_buf, state.preview_ns, 0, -1)
      api.nvim_buf_clear_namespace(state.original_buf, state.preview_state.preview_ns, 0, -1)
      if state.preview_state then
        preview_utils.restore_window_state(state.original_win, state.preview_state)
      end
    end,
  })

  -- Check if we already have diagnostics
  local diagnostics, buffer_info = get_diagnostics_for_scope("workspace")
  -- If we have diagnostics, use them directly
  if #diagnostics > 0 then
    local items = diagnostics_to_selecta_items(diagnostics, buffer_info, config)
    selecta.pick(items, pick_options)
  else
    -- Otherwise show placeholder and let async source handle loading
    selecta.pick(placeholder_items, pick_options)
  end
end

return M
