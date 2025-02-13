local M = {}

local default_opts = {
  title = "namu", -- Default title prefix
  level = vim.log.levels.INFO, -- Default log level
  once = false, -- Whether to show the message only once
}

---Sends a notification with consistent formatting across the plugin
---@param msg string The message to display
---@param level? number|string The log level (optional)
---@param opts? table Additional options
---@class selecta_notify_opts
---@field title? string The module title (will be prefixed with "Selecta::")
---@field once? boolean Show the message only once
---@field icon? string Custom icon to show
---@field timeout? number Notification timeout in milliseconds
function M.notify(msg, level, opts)
  opts = vim.tbl_deep_extend("force", default_opts, opts or {})

  -- Handle string log levels
  if type(level) == "string" then
    level = vim.log.levels[string.upper(level)] or vim.log.levels.INFO
  end

  -- Use provided level or default
  opts.level = level or opts.level

  -- Format the title
  local title = opts.title
  if title and title ~= "Selecta" then
    title = "Selecta::" .. title
  end

  -- Create a unique identifier for the message if once is true
  local notify_key = title .. msg
  if opts.once and M._notified and M._notified[notify_key] then
    return
  end

  -- Store the message if once is true
  if opts.once then
    M._notified = M._notified or {}
    M._notified[notify_key] = true
  end

  -- Construct the notification options
  local notify_opts = {
    title = title,
    icon = opts.icon or "",
    timeout = opts.timeout,
  }

  vim.notify(msg, opts.level, notify_opts)
end

-- Convenience methods for different log levels
function M.info(msg, opts)
  M.notify(msg, vim.log.levels.INFO, opts)
end

function M.warn(msg, opts)
  M.notify(msg, vim.log.levels.WARN, opts)
end

function M.error(msg, opts)
  M.notify(msg, vim.log.levels.ERROR, opts)
end

function M.debug(msg, opts)
  M.notify(msg, vim.log.levels.DEBUG, opts)
end

-- Clear notification history for "once" messages
function M.clear_history()
  M._notified = {}
end

return M
