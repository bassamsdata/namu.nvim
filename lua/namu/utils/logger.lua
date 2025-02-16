local M = {}

local log_file = vim.fn.stdpath("cache") .. "/selecta_debug.log"

---@param message string|table
function M.log(message, debug_enabled)
  if not debug_enabled then
    return
  end

  if type(message) == "table" then
    message = vim.inspect(message)
  end

  message = tostring(message)
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local log_line = string.format("[%s] %s\n", timestamp, message)

  local file = io.open(log_file, "a")
  if file then
    file:write(log_line)
    file:close()
  end
end

function M.clear_log()
  local file = io.open(log_file, "w")
  if file then
    file:write("=== Log cleared ===\n")
    file:close()
  end
end

return M
