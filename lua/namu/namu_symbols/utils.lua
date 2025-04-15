local ui = require("namu.namu_symbols.ui")
local M = {}
local notify_opts = { title = "Namu", icon = require("namu").config.icon }
local api = vim.api

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

---Yank the symbol text to registers
---@param items table|table[] Single item or array of selected items
---@param state table The picker state
---@param with_line_numbers boolean|nil Whether to include buffer line numbers in the yanked text
function M.yank_symbol_text(items, state, with_line_numbers)
  if not state.original_buf or not api.nvim_buf_is_valid(state.original_buf) then
    vim.notify("Invalid buffer", vim.log.levels.ERROR, notify_opts)
    return
  end

  local symbols = type(items) == "table" and items[1] and items or { items }
  local all_text = {}

  table.sort(symbols, function(a, b)
    return a.value.lnum < b.value.lnum
  end)

  for _, item in ipairs(symbols) do
    local symbol = item.value
    if symbol and symbol.lnum and symbol.end_lnum then
      local lines = api.nvim_buf_get_lines(state.original_buf, symbol.lnum - 1, symbol.end_lnum, false)
      local first_line = symbol.lnum - 1
      local annotation_start = nil
      -- Check for Lua annotations if it's a Lua file
      local filetype = api.nvim_get_option_value("filetype", { buf = state.original_buf })
      if filetype == "lua" then
        annotation_start = get_lua_annotation_range(state.original_buf, first_line)
        local annotation_lines = api.nvim_buf_get_lines(state.original_buf, annotation_start, first_line, false)
        if #annotation_lines > 0 then
          table.insert(all_text, table.concat(annotation_lines, "\n"))
        end
      end
      if #lines > 0 then
        if #lines == 1 then
          lines[1] = lines[1]:sub(symbol.col, symbol.end_col)
        else
          lines[1] = lines[1]:sub(symbol.col)
          lines[#lines] = lines[#lines]:sub(1, symbol.end_col)
        end
        if with_line_numbers then
          for i, line in ipairs(lines) do
            lines[i] = string.format("%4d | %s", symbol.lnum - 1 + i, line)
          end
        end
        table.insert(all_text, table.concat(lines, "\n"))
      end
    else
      vim.notify("Invalid symbol found, skipping", vim.log.levels.WARN, notify_opts)
    end
  end

  if #all_text > 0 then
    local final_text = table.concat(all_text, "\n\n")
    vim.fn.setreg('"', final_text)
    vim.fn.setreg("+", final_text)
    vim.notify(string.format("Yanked %d symbol(s) to clipboard", #symbols), vim.log.levels.INFO, notify_opts)
    return true
  end
  return false
end

---Delete the symbol text from buffer
---@param items table|table[] Single item or array of selected items
---@param state table The picker state
function M.delete_symbol_text(items, state)
  if not state.original_buf or not api.nvim_buf_is_valid(state.original_buf) then
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
      local first_line = symbol.lnum - 1
      local last_line = symbol.end_lnum
      local annotation_start = nil
      -- Check for Lua annotations if it's a Lua file
      local filetype = api.nvim_get_option_value("filetype", { buf = state.original_buf })
      if filetype == "lua" then
        annotation_start = get_lua_annotation_range(state.original_buf, first_line)
      end
      -- Delete the text and annotations (if any)
      local delete_start = annotation_start or first_line
      -- Delete the text
      api.nvim_buf_set_lines(state.original_buf, delete_start, last_line, false, {})
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
