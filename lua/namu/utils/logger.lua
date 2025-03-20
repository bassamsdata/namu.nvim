local M = {}

local log_file = vim.fn.stdpath("cache") .. "/selecta_debug.log"
local debug_enabled = false
local benchmarks = {}
local benchmark_results = {}
local uv = vim.uv or vim.loop

-- Try to load string buffer, fallback to standard methods
local has_string_buffer, string_buffer = pcall(require, "string.buffer")

function M.setup(opts)
  opts = opts or {}
  debug_enabled = opts.debug or false
end

---@param message string|table
---@param level? string Optional level for the log
function M.log(message, level)
  if not debug_enabled then
    return
  end

  if type(message) == "table" then
    message = vim.inspect(message)
  end

  message = tostring(message)
  local timestamp = os.date("%Y-%m-%d %H:%M:%S")

  -- Format log line efficiently
  local log_line
  if has_string_buffer then
    local buffer = string_buffer.new()
    buffer:put("[")
    buffer:put(timestamp)
    buffer:put("]")
    if level then
      buffer:put(" [")
      buffer:put(level)
      buffer:put("]")
    end
    buffer:put(" ")
    buffer:put(message)
    buffer:put("\n")
    log_line = buffer:get()
  else
    log_line = level and string.format("[%s] [%s] %s\n", timestamp, level, message)
      or string.format("[%s] %s\n", timestamp, message)
  end

  local file = io.open(log_file, "a")
  if file then
    file:write(log_line)
    file:close()
  end
end

-- Start a benchmark timer
---@param name string Name of the benchmark
function M.benchmark_start(name)
  benchmarks[name] = uv.hrtime()
end

-- End a benchmark and log the result
---@param name string Name of the benchmark
---@param log_result? boolean Whether to log the result (default: true)
---@return number elapsed_ms Time elapsed in milliseconds
function M.benchmark_end(name, log_result)
  if not benchmarks[name] then
    M.log("Benchmark '" .. name .. "' was not started", "ERROR")
    return 0
  end

  local elapsed_ns = uv.hrtime() - benchmarks[name]
  local elapsed_ms = elapsed_ns / 1000000 -- Convert to milliseconds

  benchmark_results[name] = elapsed_ms

  if log_result ~= false then
    M.log(string.format("Benchmark '%s' took %.3f ms", name, elapsed_ms), "BENCHMARK")
  end

  benchmarks[name] = nil
  return elapsed_ms
end

-- Measure execution time of a function
---@param name string Name of the benchmark
---@param fn function Function to benchmark
---@param ... any Arguments to pass to the function
---@return any The return value of the function
function M.measure(name, fn, ...)
  M.benchmark_start(name)
  local result = { fn(...) }
  M.benchmark_end(name)
  return unpack(result)
end

function M.clear_log()
  local file = io.open(log_file, "w")
  if file then
    file:write("=== Log cleared ===\n")
    file:close()
  end
end

-- Get all benchmark results
---@return table<string, number> Map of benchmark names to times in milliseconds
function M.get_benchmark_results()
  return benchmark_results
end

-- Clear all stored benchmark results
function M.clear_benchmark_results()
  benchmark_results = {}
end

-- Generate a benchmark report for all active benchmarks
function M.benchmark_report()
  local active = {}
  for name, start_time in pairs(benchmarks) do
    active[name] = (uv.hrtime() - start_time) / 1000000
  end

  if next(active) then
    M.log("Active benchmarks:", "BENCHMARK")
    M.log(active)
  else
    M.log("No active benchmarks", "BENCHMARK")
  end

  -- Also report completed benchmarks if we have any
  if next(benchmark_results) then
    M.log("Completed benchmarks:", "BENCHMARK")

    -- Sort by time for better analysis
    local sorted = {}
    for name, time in pairs(benchmark_results) do
      table.insert(sorted, { name = name, time = time })
    end

    table.sort(sorted, function(a, b)
      return a.time > b.time
    end)

    for _, item in ipairs(sorted) do
      M.log(string.format("%s: %.3f ms", item.name, item.time), "BENCHMARK")
    end
  end
end

-- Analyze performance and identify bottlenecks
---@param total_benchmark_name string The name of the total/overall benchmark
function M.analyze_bottlenecks(total_benchmark_name)
  local total_time = benchmark_results[total_benchmark_name]
  if not total_time then
    M.log("Total benchmark '" .. total_benchmark_name .. "' not found", "ERROR")
    return
  end

  local sorted_benchmarks = {}
  for name, time in pairs(benchmark_results) do
    if name ~= total_benchmark_name then
      table.insert(sorted_benchmarks, { name = name, time = time })
    end
  end

  table.sort(sorted_benchmarks, function(a, b)
    return a.time > b.time
  end)

  M.log("PERFORMANCE BOTTLENECK ANALYSIS", "BENCHMARK")
  M.log("=================================", "BENCHMARK")
  M.log(string.format("Total execution time: %.3f ms", total_time), "BENCHMARK")
  M.log("", "BENCHMARK")
  M.log("Sorted by time spent:", "BENCHMARK")

  for i, benchmark in ipairs(sorted_benchmarks) do
    local percentage = (benchmark.time / total_time * 100)
    M.log(string.format("%d. %s: %.3f ms (%.1f%%)", i, benchmark.name, benchmark.time, percentage), "BENCHMARK")
  end
end

return M
