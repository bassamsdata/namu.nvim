local ui = require("namu.namu_symbols.ui")
local M = {}
local notify_opts = { title = "Namu", icon = require("namu").config.icon }

---Yank the symbol text to registers
---@param items table|table[] Single item or array of selected items
---@param state table The picker state
function M.yank_symbol_text(items, state)
  if not state.original_buf or not vim.api.nvim_buf_is_valid(state.original_buf) then
    vim.notify("Invalid buffer", vim.log.levels.ERROR, notify_opts)
    return
  end

  -- Convert single item to array for consistent handling
  local symbols = type(items) == "table" and items[1] and items or { items }
  local all_text = {}

  -- Sort symbols by line number to maintain order
  table.sort(symbols, function(a, b)
    return a.value.lnum < b.value.lnum
  end)

  for _, item in ipairs(symbols) do
    local symbol = item.value
    if symbol and symbol.lnum and symbol.end_lnum then
      -- Get the text content
      local lines = vim.api.nvim_buf_get_lines(state.original_buf, symbol.lnum - 1, symbol.end_lnum, false)

      if #lines > 0 then
        -- Handle single line case
        if #lines == 1 then
          lines[1] = lines[1]:sub(symbol.col, symbol.end_col)
        else
          -- Handle multi-line case
          lines[1] = lines[1]:sub(symbol.col)
          lines[#lines] = lines[#lines]:sub(1, symbol.end_col)
        end
        table.insert(all_text, table.concat(lines, "\n"))
      end
    else
      vim.notify("Invalid symbol found, skipping", vim.log.levels.WARN, notify_opts)
    end
  end

  if #all_text > 0 then
    local final_text = table.concat(all_text, "\n\n")
    vim.fn.setreg('"', final_text) -- Set to unnamed register
    vim.fn.setreg("+", final_text) -- Set to system clipboard if unnamed register is not supported
    vim.notify(string.format("Yanked %d symbol(s) to clipboard", #symbols), vim.log.levels.INFO, notify_opts)
    return true
  end
  return false
end

---Delete the symbol text from buffer
---@param items table|table[] Single item or array of selected items
---@param state table The picker state
function M.delete_symbol_text(items, state)
  if not state.original_buf or not vim.api.nvim_buf_is_valid(state.original_buf) then
    vim.notify("Invalid buffer", vim.log.levels.ERROR, notify_opts)
    return
  end

  -- Convert single item to array for consistent handling
  local symbols = type(items) == "table" and items[1] and items or { items }

  -- Sort symbols by line number in reverse order (to delete from bottom up)
  table.sort(symbols, function(a, b)
    return a.value.lnum > b.value.lnum
  end)

  -- Confirm deletion
  local confirm = vim.fn.confirm(string.format("Delete %d selected symbol(s)?", #symbols), "&Yes\n&No", 2)

  if confirm ~= 1 then
    return
  end

  -- Create undo block
  vim.cmd("undojoin")

  local deleted_count = 0
  for _, item in ipairs(symbols) do
    local symbol = item.value
    if symbol and symbol.lnum and symbol.end_lnum then
      -- Delete the text
      vim.api.nvim_buf_set_lines(state.original_buf, symbol.lnum - 1, symbol.end_lnum, false, {})
      deleted_count = deleted_count + 1
    else
      vim.notify("Invalid symbol found, skipping", vim.log.levels.WARN, notify_opts)
    end
  end

  if deleted_count > 0 then
    vim.notify(string.format("Deleted %d symbol(s)", deleted_count), vim.log.levels.INFO, notify_opts)
    ui.clear_preview_highlight(state.original_win, state.preview_ns)
    return true
  end
  return false
end

return M
