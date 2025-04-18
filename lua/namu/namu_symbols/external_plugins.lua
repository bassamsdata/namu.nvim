local M = {}
local api = vim.api

---Process and collect symbol text content
---@param items table[] Array of selected items
---@param bufnr number Buffer number
---@param with_line_numbers boolean|nil Whether to include buffer line numbers in the output
---@return table|nil {text: string, symbols: table[], content: string[]} Processed content and metadata
local function process_symbol_content(items, bufnr, with_line_numbers)
  if not items or #items == 0 then
    vim.notify("No items received", vim.log.levels.WARN)
    return nil
  end

  local sorted_symbols = {}
  local all_content = {}
  for _, item in ipairs(items) do
    table.insert(sorted_symbols, item.value)
  end
  table.sort(sorted_symbols, function(a, b)
    return a.lnum < b.lnum
  end)
  local last_end_lnum = -1
  for _, symbol in ipairs(sorted_symbols) do
    if symbol.lnum > last_end_lnum then
      local lines = api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.end_lnum, false)
      if with_line_numbers then
        for i, line in ipairs(lines) do
          lines[i] = string.format("%4d | %s", symbol.lnum - 1 + i, line)
        end
      end
      table.insert(all_content, table.concat(lines, "\n"))
      last_end_lnum = symbol.end_lnum
    end
  end

  return {
    text = table.concat(all_content, "\n\n"),
    symbols = sorted_symbols,
    content = all_content,
  }
end

-- TODO: No need for this as it's in the utils module but just
-- needs to insure there is no infinte loop before deleting it
local function get_lua_annotation_range(bufnr, start_line)
  local annotation_start = start_line
  -- Go backwards to find the start of the annotation block
  for i = start_line, 1, -1 do
    local line = api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
    if line:match("^---") then
      annotation_start = i - 1
    else
      break
    end
  end

  return annotation_start
end

---Add symbol text to CodeCompanion chat buffer
---@param items table[] Array of selected items from selecta
---@param bufnr number The buffer number of the original buffer
---@param with_line_numbers boolean|nil Whether to include buffer line numbers in the output
function M.add_symbol_to_codecompanion(items, bufnr, with_line_numbers)
  local status, codecompanion = pcall(require, "codecompanion")
  if not status then
    return
  end

  local all_content = {}
  local sorted_symbols = {}

  for _, item in ipairs(items) do
    table.insert(sorted_symbols, item.value)
  end

  table.sort(sorted_symbols, function(a, b)
    return a.lnum < b.lnum
  end)

  for _, symbol in ipairs(sorted_symbols) do
    local first_line = symbol.lnum - 1
    local last_line = symbol.end_lnum
    local annotation_start = nil
    local symbol_lines = {}

    -- Check for Lua annotations if it's a Lua file
    local filetype = api.nvim_get_option_value("filetype", { buf = bufnr })
    if filetype == "lua" then
      annotation_start = get_lua_annotation_range(bufnr, first_line)
      local annotation_lines = api.nvim_buf_get_lines(bufnr, annotation_start, first_line, false)
      if #annotation_lines > 0 then
        -- Add annotations to symbol_lines first
        for _, line in ipairs(annotation_lines) do
          table.insert(symbol_lines, line)
        end
      end
    end

    local lines = api.nvim_buf_get_lines(bufnr, first_line, last_line, false)
    if with_line_numbers then
      for i, line in ipairs(lines) do
        lines[i] = string.format("%4d | %s", symbol.lnum - 1 + i, line)
      end
    end
    -- Add symbol content to symbol_lines
    for _, line in ipairs(lines) do
      table.insert(symbol_lines, line)
    end
    -- Concatenate all lines for the symbol
    local symbol_content = table.concat(symbol_lines, "\n")
    table.insert(all_content, symbol_content)
  end
  local result_text = table.concat(all_content, "\n\n")

  local chat = codecompanion.last_chat()
  if not chat then
    chat = codecompanion.chat()
    if not chat then
      return vim.notify("Could not create chat buffer", vim.log.levels.WARN)
    end
  end
  chat:add_buf_message({
    role = require("codecompanion.config").constants.USER_ROLE,
    content = "Here is some code from " .. api.nvim_buf_get_name(bufnr) .. ":\n\n```" .. api.nvim_get_option_value(
      "filetype",
      { buf = bufnr }
    ) .. "\n" .. result_text .. "\n```\n",
  })
  chat.ui:open()
end

---BUG: This function doesn't work as expected - need to check with Avante
---Add symbol text to Avante sidebar
---@param items table[] Array of selected items from selecta
---@param bufnr number The buffer number of the original buffer
function M.add_symbol_to_avante(items, bufnr)
  -- Check if the 'avante.api' module is available
  local status, avante_api = pcall(require, "avante.api")
  if not status then
    return
  end

  local result = process_symbol_content(items, bufnr)
  if not result then
    return
  end

  -- Create the selection object that Avante expects
  local selection = {
    text = result.text,
    range = {
      start = {
        line = result.symbols[1].lnum - 1,
        character = result.symbols[1].col - 1,
      },
      ["end"] = {
        line = result.symbols[#result.symbols].end_lnum - 1,
        character = result.symbols[#result.symbols].end_col - 1,
      },
    },
  }

  -- Call Avante's ask function with the selection
  avante_api.ask({
    selection = selection,
    floating = true,
  })
end

function M.codecompanion_handler(items_or_item, original_buf)
  if type(items_or_item) == "table" and items_or_item[1] then
    M.add_symbol_to_codecompanion(items_or_item, original_buf, true)
  else
    -- Single item case
    M.add_symbol_to_codecompanion({ items_or_item }, original_buf, true)
  end
end

function M.avante_handler(items_or_item, original_buf)
  if type(items_or_item) == "table" and items_or_item[1] then
    M.add_symbol_to_avante(items_or_item, original_buf)
  else
    -- Single item case
    M.add_symbol_to_avante({ items_or_item }, original_buf)
  end
end

return M
