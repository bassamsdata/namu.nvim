local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local index = require("namu.sidebar.symbol_index")

local function item(path, first, last, col)
  return { location = { path = path, line = first, col = 0, end_line = last, end_col = col } }
end

T["nested ranges find their containing parent between sibling bodies"] = function()
  local items = { item("a.lua", 1, 1000) }
  for line = 10, 900, 10 do
    items[#items + 1] = item("a.lua", line, line + 4)
  end
  local cached = index.new(items)
  eq(index.find(cached, "a.lua", 714), 72)
  eq(index.find(cached, "a.lua", 715), 1)
  eq(index.find(cached, "a.lua", 950), 1)
  eq(index.find(cached, "a.lua", 1001), nil)
end

T["unsorted ranges same starts and exclusive line endings are handled"] = function()
  local cached = index.new({
    item("a.lua", 10, 20, 0),
    item("a.lua", 1, 30),
    item("a.lua", 10, 15),
    item("b.lua", 1, 100),
  })
  eq(index.find(cached, "a.lua", 12), 3)
  eq(index.find(cached, "a.lua", 19), 1)
  eq(index.find(cached, "a.lua", 20), 2)
  eq(index.find(cached, "b.lua", 12), 4)
  eq(index.find(cached, "c.lua", 12), nil)
end

T["root entries are ignored and missing ranges match only their location"] = function()
  local root = item("a.lua", 1, 100)
  root.is_root = true
  local cached = index.new({ root, item("a.lua", 4) })
  eq(index.find(cached, "a.lua", 4), 2)
  eq(index.find(cached, "a.lua", 5), nil)
  eq(index.find(index.new({}), "a.lua", 1), nil)
end

return T
