local M = {}
local storage = require("namu.sidebar.storage")

---Add a file-backed picker item to favorites, ignoring duplicates.
---@param item SelectaItem
---@param fallback_buf? number
---@return string|nil id
function M.add(item, fallback_buf)
  local record = storage.record(item, fallback_buf)
  if not record then
    return nil
  end
  record.depth = 0
  local favorites = storage.get().favorites
  for _, existing in ipairs(favorites) do
    if existing.id == record.id then
      return existing.id
    end
  end
  table.insert(favorites, record)
  storage.save()
  require("namu.sidebar").refresh_favorites()
  return record.id
end

---Remove a saved favorite by ID.
---@param id string
---@return boolean
function M.remove(id)
  local favorites = storage.get().favorites
  for index, item in ipairs(favorites) do
    if item.id == id then
      table.remove(favorites, index)
      storage.save()
      require("namu.sidebar").refresh_favorites()
      return true
    end
  end
  return false
end

---Return a copy of all favorites.
---@return table[]
function M.get_all()
  return vim.deepcopy(storage.get().favorites)
end

---Count saved favorites.
---@return number
function M.count()
  return #storage.get().favorites
end

---Open the searchable favorites sidebar.
---@return nil
function M.show()
  require("namu.sidebar").open_favorites()
end

---Clear saved favorites.
---@return nil
function M.clear()
  storage.get().favorites = {}
  storage.save()
  require("namu.sidebar").refresh_favorites()
end

---Create a picker action which saves selected items, or the current item.
---@return function
function M.create_keymap_handler()
  return function(items_or_item, picker_state)
    local items = items_or_item and items_or_item.text and { items_or_item } or items_or_item or {}
    if picker_state and picker_state.selected_count > 0 then
      items = picker_state:get_selected_items()
    end
    local added = 0
    for _, item in ipairs(items) do
      if M.add(item, picker_state and picker_state.original_buf) then
        added = added + 1
      end
    end
    vim.notify(string.format("Saved %d item(s) to favorites", added), vim.log.levels.INFO, { title = "Namu" })
    return false
  end
end

return M
