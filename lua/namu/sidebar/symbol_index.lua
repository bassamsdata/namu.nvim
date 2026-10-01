local M = {}
local storage = require("namu.sidebar.storage")

local function build(entries, first, last)
  if first > last then
    return nil
  end
  local middle = math.floor((first + last) / 2)
  local node = entries[middle]
  node.left = build(entries, first, middle - 1)
  node.right = build(entries, middle + 1, last)
  node.max_end = math.max(node.finish, node.left and node.left.max_end or 0, node.right and node.right.max_end or 0)
  return node
end

---Index visible symbol ranges by file for code-cursor following.
---@param items table[]
---@param fallback_buf? number
---@return table<string, table>
function M.new(items, fallback_buf)
  local files = {}
  for row, item in ipairs(items) do
    local location = not item.is_root and not item.is_auxiliary and storage.location(item, fallback_buf)
    if location then
      local entries = files[location.path] or {}
      files[location.path] = entries
      local finish = location.end_line or location.line
      if location.end_col == 0 and finish > location.line then
        finish = finish - 1
      end
      entries[#entries + 1] = {
        row = row,
        start = location.line,
        finish = math.max(location.line, finish),
        depth = item.depth or 0,
      }
    end
  end
  for path, entries in pairs(files) do
    table.sort(entries, function(a, b)
      if a.start ~= b.start then
        return a.start < b.start
      end
      if a.finish ~= b.finish then
        return a.finish > b.finish
      end
      if a.depth ~= b.depth then
        return a.depth < b.depth
      end
      return a.row < b.row
    end)
    files[path] = build(entries, 1, #entries)
  end
  return files
end

local function containing(node, line)
  if not node or node.max_end < line then
    return nil
  end
  if node.start > line then
    return containing(node.left, line)
  end
  -- Later starts (and smaller ranges at the same start) are more specific.
  local match = containing(node.right, line)
  if match then
    return match
  end
  if node.finish >= line then
    return node.row
  end
  return containing(node.left, line)
end

---Find the most specific visible symbol containing a code line.
---@param index table<string, table>
---@param path string
---@param line number One-based code line
---@return number? row
function M.find(index, path, line)
  return containing(index[path], line)
end

return M
