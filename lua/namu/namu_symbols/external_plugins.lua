local M = {}
---Process and collect symbol text content
---@param items table[] Array of selected items
---@param bufnr number Buffer number
---@return table|nil {text: string, symbols: table[], content: string[]} Processed content and metadata
local function process_symbol_content(items, bufnr)
  if not items or #items == 0 then
    vim.notify("No items received", vim.log.levels.WARN)
    return nil
  end

  local sorted_symbols = {}
  local all_content = {}

  -- First pass: collect and sort symbols by line number
  for _, item in ipairs(items) do
    table.insert(sorted_symbols, item.value)
  end
  table.sort(sorted_symbols, function(a, b)
    return a.lnum < b.lnum
  end)

  -- Second pass: collect content with no duplicates
  local last_end_lnum = -1
  for _, symbol in ipairs(sorted_symbols) do
    -- Only add if this section doesn't overlap with the previous one
    if symbol.lnum > last_end_lnum then
      local lines = vim.api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.end_lnum, false)
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

---Add symbol text to CodeCompanion chat buffer
---@param items table[] Array of selected items from selecta
---@param bufnr number The buffer number of the original buffer
function M.add_symbol_to_codecompanion(items, bufnr)
  -- Check if the 'codecompanion' module is available
  local status, codecompanion = pcall(require, "codecompanion")
  if not status then
    return
  end

  local result = process_symbol_content(items, bufnr)
  if not result then
    return
  end

  local chat = codecompanion.last_chat()

  if not chat then
    chat = codecompanion.chat()
    if not chat then
      return vim.notify("Could not create chat buffer", vim.log.levels.WARN)
    end
  end

  chat:add_buf_message({
    role = require("codecompanion.config").constants.USER_ROLE,
    content = "Here is some code from "
      .. vim.api.nvim_buf_get_name(bufnr)
      .. ":\n\n```"
      .. vim.api.nvim_get_option_value("filetype", { buf = bufnr })
      .. "\n"
      .. result.text
      .. "\n```\n",
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
    M.add_symbol_to_codecompanion(items_or_item, original_buf)
  else
    -- Single item case
    M.add_symbol_to_codecompanion({ items_or_item }, original_buf)
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
