local M = {}
local data = { version = 1, favorites = {}, panels = {} }
local config = {}
local loaded = false
local writable = true

local function notify(message)
  vim.notify(message, vim.log.levels.WARN, { title = "Namu sidebar" })
end

---Configure sidebar storage. Persistence can be disabled for session-only state.
---@param opts table
---@return nil
function M.setup(opts)
  config = opts or {}
  loaded = false
  writable = true
  data = { version = 1, favorites = {}, panels = {} }
end

---Load the saved sidebar data on first access.
---@return table
function M.get()
  if loaded then
    return data
  end
  loaded = true
  if config.persist == false then
    return data
  end
  local path = config.storage_path or (vim.fn.stdpath("data") .. "/namu/sidebar.json")
  if vim.fn.filereadable(path) == 0 then
    return data
  end
  local ok, result = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if
    not ok
    or type(result) ~= "table"
    or result.version ~= 1
    or type(result.favorites) ~= "table"
    or not vim.islist(result.favorites)
    or type(result.panels) ~= "table"
  then
    writable = false
    notify("Cannot read saved sidebar state; the file will be preserved")
    return data
  end
  -- Only accept items with usable, session-independent locations.
  for _, item in ipairs(result.favorites) do
    if
      type(item) == "table"
      and type(item.text) == "string"
      and type(item.id) == "string"
      and type(item.location) == "table"
      and type(item.location.path) == "string"
      and type(item.location.line) == "number"
      and type(item.location.col) == "number"
    then
      table.insert(data.favorites, item)
    end
  end
  data.panels = result.panels
  return data
end

---Atomically save bookmarks and sidebar view state.
---@return boolean
function M.save()
  M.get()
  if config.persist == false then
    return true
  end
  if not writable then
    return false
  end
  local path = config.storage_path or (vim.fn.stdpath("data") .. "/namu/sidebar.json")
  local temporary = path .. "." .. tostring(vim.uv.hrtime()) .. ".tmp"
  local ok, err = pcall(function()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    assert(vim.fn.writefile({ vim.json.encode(data) }, temporary) == 0, "write failed")
    assert(vim.fn.rename(temporary, path) == 0, "rename failed")
  end)
  if not ok then
    pcall(vim.fn.delete, temporary)
    notify("Could not save sidebar state: " .. tostring(err))
  end
  return ok
end

---Extract a stable file location from a picker item.
---@param item SelectaItem
---@param fallback_buf? number
---@return table|nil
function M.location(item, fallback_buf)
  if item.location then
    return vim.deepcopy(item.location)
  end
  local value = type(item.value) == "table" and item.value or {}
  local path = value.file_path or value.filename
  local uri = value.uri or (value.location and value.location.uri)
  if not path and uri then
    local ok, name = pcall(vim.uri_to_fname, uri)
    if ok then
      path = name
    end
  end
  local bufnr = value.bufnr or item.bufnr or fallback_buf
  if not path and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    path = vim.api.nvim_buf_get_name(bufnr)
  end
  if not path or path == "" then
    return nil
  end
  local range = value.range
    or (value.location and value.location.range)
    or (value.symbol and value.symbol.location and value.symbol.location.range)
  local zero_based = value.diagnostic or value.symbol
  local line = range and range.start and range.start.line + 1 or (value.lnum and value.lnum + (zero_based and 1 or 0))
  local col = range and range.start and range.start.character
    or (value.col and value.col - (zero_based and 0 or 1))
    or 0
  if not line then
    return nil
  end
  return {
    path = vim.fn.fnamemodify(path, ":p"),
    line = math.max(1, line),
    col = math.max(0, col),
    end_line = range and range["end"] and range["end"].line + 1 or value.end_lnum,
    end_col = range and range["end"] and range["end"].character or (value.end_col and value.end_col - 1),
  }
end

---Convert an item into a serializable favorite.
---@param item SelectaItem
---@param fallback_buf? number
---@return table|nil
function M.record(item, fallback_buf)
  if not item or item.is_root or item.is_auxiliary or item.is_placeholder then
    return nil
  end
  local location = M.location(item, fallback_buf)
  if not location then
    return nil
  end
  return {
    id = string.format("%s:%d:%d", location.path, location.line, location.col),
    text = item.text or "Bookmark",
    icon = item.icon,
    kind = item.kind,
    source = item.source,
    depth = item.depth or 0,
    tree_state = vim.deepcopy(item.tree_state),
    location = location,
  }
end

return M
