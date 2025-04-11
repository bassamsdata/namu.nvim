---@diagnostic disable: missing-fields
local Async = {}
local Promise = {}
---@class Promise
---@field completed boolean Whether the promise has been resolved or rejected
---@field result any The result of the resolved promise
---@field error any The error if the promise was rejected
---@field _cancel function|nil Function to cancel the promise
---@field _resolve_callbacks function[] List of callbacks to call when resolved
---@field _reject_callbacks function[] List of callbacks to call when rejected
---@field resolve fun(self: Promise, result: any): nil
---@field reject fun(self: Promise, err: any): nil
---@field and_then fun(self: Promise, resolve_cb: function|nil, reject_cb: function|nil): Promise
---@field cancel fun(self: Promise): boolean
local Promise_mt = { __index = Promise }

---@class AsyncConfig
---@field max_concurrent integer Maximum number of concurrent coroutines
---@field default_timeout number Default timeout in seconds for operations
---@field error_handler function Custom error handler function
local default_config = {
  max_concurrent = 10,
  default_timeout = 5,
  error_handler = function(err)
    vim.schedule(function()
      vim.notify("Async error: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end,
}

---@class Async
---@field config AsyncConfig
---@field running integer Number of currently running coroutines
---@field queue table<function> Queue of pending coroutines
---@field promises table<Promise> List of all promises
---@field progress_cb function|nil Callback for progress updates
---@field total_tasks integer Total number of tasks
---@field completed_tasks integer Number of completed tasks
---@field failed_tasks integer Number of failed tasks
---@field _async_handle any UV async handle for processing the queue
local Async_mt = { __index = Async }

---Create new Promise instance
---@return Promise
function Promise.new()
  local self = setmetatable({
    completed = false,
    result = nil,
    error = nil,
    _cancel = nil,
    _resolve_callbacks = {},
    _reject_callbacks = {},
  }, Promise_mt)
  return self
end

---Resolve the promise with a result
---@param result any The result to resolve with
---@return nil
function Promise:resolve(result)
  if self.completed then
    return
  end
  self.completed = true
  self.result = result
  for _, cb in ipairs(self._resolve_callbacks) do
    vim.schedule(function()
      cb(result)
    end)
  end
end

---Reject the promise with an error
---@param err any The error to reject with
---@return nil
function Promise:reject(err)
  if self.completed then
    return
  end
  self.completed = true
  self.error = err
  for _, cb in ipairs(self._reject_callbacks) do
    vim.schedule(function()
      cb(err)
    end)
  end
end

---Add callbacks to be called when the promise is resolved or rejected
---@param resolve_cb function|nil Callback for when the promise is resolved
---@param reject_cb function|nil Callback for when the promise is rejected
---@return Promise Self for chaining
function Promise:and_then(resolve_cb, reject_cb)
  if resolve_cb then
    table.insert(self._resolve_callbacks, function(result)
      resolve_cb(result)
    end)
  end
  if reject_cb then
    table.insert(self._reject_callbacks, function(err)
      reject_cb(err)
    end)
  end

  if self.completed then
    if self.error then
      if reject_cb then
        vim.schedule(function()
          reject_cb(self.error)
        end)
      end
    else
      if resolve_cb then
        vim.schedule(function()
          resolve_cb(self.result)
        end)
      end
    end
  end
  return self
end

---Cancel the promise if possible
---@return boolean Whether the promise was successfully cancelled
function Promise:cancel()
  if type(self._cancel) == "function" then
    self._cancel()
    self:reject("Cancelled")
    return true
  end
  return false
end

---Create new Async instance
---@param config? AsyncConfig
---@return Async
function Async.new(config)
  local self = setmetatable({
    config = vim.tbl_deep_extend("force", default_config, config or {}),
    running = 0,
    queue = {},
    promises = {},
    _async_handle = nil,
    -- Progress tracking fields
    progress_cb = nil,
    total_tasks = 0,
    completed_tasks = 0,
    failed_tasks = 0,
  }, Async_mt)

  ---@diagnostic disable-next-line: undefined-field
  self._async_handle = vim.uv.new_async(vim.schedule_wrap(function()
    self:process_queue()
  end))

  return self
end

---Add progress callback
---@param cb function Callback function receiving progress information
---@return Async Self for chaining
function Async:on_progress(cb)
  self.progress_cb = cb
  return self
end

---Internal progress updater
---@return nil
function Async:_update_progress()
  if self.progress_cb then
    vim.schedule(function()
      self.progress_cb({
        total = self.total_tasks,
        completed = self.completed_tasks,
        failed = self.failed_tasks,
        running = self.running,
        pending = self.total_tasks - (self.completed_tasks + self.failed_tasks),
      })
    end)
  end
end

---Add async task to queue
---@param fn function Function to run asynchronously
---@vararg any Arguments to pass to the function
---@return Promise
function Async:go(fn, ...)
  local promise = Promise.new()
  local args = { ... }
  local task_id = #self.promises + 1

  -- Update total tasks
  self.total_tasks = self.total_tasks + 1
  self:_update_progress()

  ---@type thread
  local co

  ---@type function
  local function cancel()
    if co and coroutine.status(co) == "suspended" then
      self.running = self.running - 1
      self._async_handle:send()
    end
    promise:reject("Cancelled")
  end

  co = coroutine.create(function()
    local ok, result = xpcall(fn, debug.traceback, unpack(args))

    if ok then
      promise:resolve(result)
      self.completed_tasks = self.completed_tasks + 1
    else
      promise:reject(result)
      self.failed_tasks = self.failed_tasks + 1
      self.config.error_handler(result)
    end

    self.running = self.running - 1
    self:_update_progress()
    self._async_handle:send()
  end)

  promise._cancel = cancel
  self.promises[task_id] = promise
  table.insert(self.queue, co)
  self._async_handle:send()

  return promise
end

---Process queue items
function Async:process_queue()
  while self.running < self.config.max_concurrent and #self.queue > 0 do
    self.running = self.running + 1
    local co = table.remove(self.queue, 1)
    coroutine.resume(co)
  end
end

---Add async task to queue with timeout
---@param fn function
---@param timeout number
---@vararg any
---@return Promise
function Async:go_with_timeout(fn, timeout, ...)
  local promise = self:go(fn, ...)
  local timeout_ms = timeout * 1000
  local _ = vim.defer_fn(function()
    if not promise.completed then
      promise:cancel()
      promise:reject("Task timeout")
    end
  end, timeout_ms)
  return promise
end

---Clear all pending tasks
function Async:clear()
  self.queue = {}
  for _, promise in ipairs(self.promises) do
    promise:cancel()
  end
  self.running = 0
end

---LSP request helper
---@param bufnr integer
---@param method string
---@param params table
---@return Promise
function Async:lsp_request(bufnr, method, params)
  local promise = Promise.new()

  local client = require("namu.namu_symbols.lsp").get_client_with_method(bufnr, method)
  if not client then
    promise:reject("No LSP client found")
    return promise
  end

  ---@type boolean, integer|nil
  local success, request_id = client:request(method, params, function(err, result)
    if err then
      if type(err) == "table" then
        promise:reject(err.message or "LSP request failed") -- Use err.message if available
      else
        promise:reject(tostring(err))
      end
    else
      promise:resolve(result)
    end
  end)

  if not success then
    promise:reject("LSP request failed")
    return promise
  end

  -- The request_id should be an integer if success is true
  ---@type integer
  local req_id = request_id or 0 -- Providing a fallback to satisfy type check

  promise._cancel = function()
    client:cancel_request(req_id)
  end

  -- Timeout mechanism using vim.defer_fn
  local timeout_ms = self.config.default_timeout * 1000
  local _ = vim.defer_fn(function()
    if not promise.completed then
      promise:cancel()
      promise:reject("LSP request timeout")
    end
  end, timeout_ms)

  return promise
end

return {
  Async = Async,
  Promise = Promise,
}
