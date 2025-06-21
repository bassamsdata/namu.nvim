local M = {}

-- Find the parent of an item
function M.find_parent_item(items, current_index)
  local current = items[current_index]
  if not current or not current.value.parent_signature then
    return nil
  end

  -- Look for the parent
  for i, item in ipairs(items) do
    if item.value.signature == current.value.parent_signature then
      return i
    end
  end

  return nil
end

-- Find the first child of an item
function M.find_first_child(items, current_index)
  local current = items[current_index]
  if not current or not current.value.signature then
    return nil
  end

  -- Look for the first child
  for i = 1, #items do
    if items[i].value.parent_signature == current.value.signature then
      return i
    end
  end

  return nil
end

-- Find the next sibling of an item
function M.find_next_sibling(items, current_index)
  local current = items[current_index]
  if not current or not current.value.parent_signature then
    return nil
  end

  -- Find siblings (items with the same parent)
  local siblings = {}
  for i, item in ipairs(items) do
    if item.value.parent_signature == current.value.parent_signature then
      table.insert(siblings, i)
    end
  end

  -- Find the current item's position among siblings
  for i, idx in ipairs(siblings) do
    if idx == current_index and i < #siblings then
      -- Return next sibling
      return siblings[i + 1]
    end
  end

  return nil
end

-- Find the previous sibling of an item
function M.find_prev_sibling(items, current_index)
  local current = items[current_index]
  if not current or not current.value.parent_signature then
    return nil
  end

  -- Find siblings (items with the same parent)
  local siblings = {}
  for i, item in ipairs(items) do
    if item.value.parent_signature == current.value.parent_signature then
      table.insert(siblings, i)
    end
  end

  -- Find the current item's position among siblings
  for i, idx in ipairs(siblings) do
    if idx == current_index and i > 1 then
      -- Return previous sibling
      return siblings[i - 1]
    end
  end

  return nil
end

-- Add visual feedback to navigation using extmark
function M.navigate_with_feedback(selecta_state, new_index, message)
  if new_index then
    -- Save current position for highlighting
    local _ = selecta_state:get_selected_index()

    -- Move to new position
    selecta_state:select_item(new_index)

    -- Add brief highlight to show movement
    local buf = selecta_state.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      local ns_id = vim.api.nvim_create_namespace("namu_navigation_highlight")

      -- Clear any existing highlights
      vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

      -- Add highlight to the line we moved to using extmark
      vim.api.nvim_buf_set_extmark(buf, ns_id, new_index - 1, 0, {
        end_row = new_index - 1,
        end_col = -1, -- Highlight to end of line
        hl_group = "Search",
        priority = 200,
        strict = false,
      })

      -- Remove highlight after a brief moment
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
        end
      end, 150)
    end
  else
    vim.notify(message, vim.log.levels.INFO)
  end

  return true -- Keep picker open
end

-- Navigation command implementations
function M.navigate_to_parent(selecta_state)
  local current_index = selecta_state:get_selected_index()
  local parent_index = M.find_parent_item(selecta_state.items, current_index)
  return M.navigate_with_feedback(selecta_state, parent_index, "No parent found")
end

function M.navigate_to_child(selecta_state)
  local current_index = selecta_state:get_selected_index()
  local child_index = M.find_first_child(selecta_state.items, current_index)
  return M.navigate_with_feedback(selecta_state, child_index, "No children found")
end

function M.navigate_to_next_sibling(selecta_state)
  local current_index = selecta_state:get_selected_index()
  local sibling_index = M.find_next_sibling(selecta_state.items, current_index)
  return M.navigate_with_feedback(selecta_state, sibling_index, "No next sibling found")
end

function M.navigate_to_prev_sibling(selecta_state)
  local current_index = selecta_state:get_selected_index()
  local sibling_index = M.find_prev_sibling(selecta_state.items, current_index)
  return M.navigate_with_feedback(selecta_state, sibling_index, "No previous sibling found")
end

-- Calculate the maximum nesting depth of an item
function M.calculate_nesting_depth(items, index, signature_to_index)
  local item = items[index]
  if not item then
    return 0
  end

  -- If we already calculated depth for this item, return it
  if item.calculated_depth ~= nil then
    return item.calculated_depth
  end

  -- If it's a leaf node or reached max depth, depth is 0
  if not item.value.has_children then
    item.calculated_depth = 0
    return 0
  end

  -- Find all direct children of this item
  local max_child_depth = 0
  for i, child in ipairs(items) do
    if child.value.parent_signature == item.value.signature then
      local child_depth = M.calculate_nesting_depth(items, i, signature_to_index)
      max_child_depth = math.max(max_child_depth, child_depth + 1)
    end
  end

  -- Store and return the result
  item.calculated_depth = max_child_depth
  return max_child_depth
end

-- Mark items that have children for sorting purposes
function M.mark_items_with_children(items)
  -- Build a map of signatures to item indices
  local signature_to_index = {}
  for i, item in ipairs(items) do
    if item.value.signature then
      signature_to_index[item.value.signature] = i
    end
  end

  -- First pass: mark items that have children
  for _, item in ipairs(items) do
    item.value.has_children = false

    -- Root item is always preserved at the top
    if item.value.is_current then
      item.value.is_root = true
    end
  end

  -- Second pass: check for parent relationships
  for _, item in ipairs(items) do
    if item.value.parent_signature and signature_to_index[item.value.parent_signature] then
      local parent_index = signature_to_index[item.value.parent_signature]
      items[parent_index].value.has_children = true
    end
  end

  -- Calculate nesting depths
  for i, item in ipairs(items) do
    if not item.calculated_depth then
      M.calculate_nesting_depth(items, i, signature_to_index)
    end
  end

  return signature_to_index
end

-- Sort items so less nested items appear before more nested ones
-- while maintaining parent-child relationships
function M.sort_by_nesting_depth(items)
  -- If fewer than 3 items, no need to sort
  if #items <= 2 then
    return items
  end

  -- Step 1: Find the root item and build parent-child relationships
  local root_item = nil
  local item_by_sig = {}
  local children_by_parent = {}

  -- Build maps
  for _, item in ipairs(items) do
    local sig = item.value and item.value.signature
    if sig then
      item_by_sig[sig] = item

      -- Identify root item
      if item.value.is_current then
        root_item = item
      end

      -- Group children by parent
      local parent_sig = item.value.parent_signature
      if parent_sig then
        if not children_by_parent[parent_sig] then
          children_by_parent[parent_sig] = {}
        end
        table.insert(children_by_parent[parent_sig], item)
      end
    end
  end

  -- If we can't find a root item, return original list
  if not root_item then
    return items
  end

  -- Step 2: Calculate number of descendants for each item
  local descendant_counts = {}

  -- Helper to count descendants safely
  local function count_descendants(sig, visited)
    visited = visited or {}
    if visited[sig] then
      return 0
    end -- Prevent cycles
    visited[sig] = true

    local count = 0
    local children = children_by_parent[sig]
    if not children then
      return 0
    end

    count = #children -- Direct children count

    -- Add descendants of each child
    for _, child in ipairs(children) do
      count = count + count_descendants(child.value.signature, visited)
    end

    return count
  end

  -- Calculate descendant counts for all items
  for sig, _ in pairs(item_by_sig) do
    -- Use a new visited table for each count to avoid false cycle detection
    descendant_counts[sig] = count_descendants(sig, {})
  end

  -- Step 3: Sort each group of siblings by their descendant count
  for _, children in pairs(children_by_parent) do
    table.sort(children, function(a, b)
      local a_count = descendant_counts[a.value.signature] or 0
      local b_count = descendant_counts[b.value.signature] or 0

      if a_count == b_count then
        -- Secondary sort by name for stability
        return a.value.name < b.value.name
      end

      -- Sort by complexity - fewer descendants first
      return a_count < b_count
    end)
  end

  -- Step 4: Rebuild the list preserving hierarchy but with sorted siblings
  local result = {}
  local processed = {}

  -- Non-recursive function to add an item and its children
  local function add_item_and_descendants(item)
    local sig = item.value.signature
    if processed[sig] then
      return
    end -- Skip if already processed (cycle prevention)
    processed[sig] = true

    table.insert(result, item)

    -- Add all children in the sorted order
    local children = children_by_parent[sig]
    if children then
      for _, child in ipairs(children) do
        add_item_and_descendants(child)
      end
    end
  end

  -- Start with the root
  add_item_and_descendants(root_item)

  -- Add any disconnected items
  for _, item in ipairs(items) do
    local sig = item.value and item.value.signature
    if sig and not processed[sig] then
      add_item_and_descendants(item)
    end
  end

  -- Step 5: Update tree guides for new ordering
  M.update_tree_guides_after_sorting(result)

  return result
end

-- Update tree guides after sorting to reflect new ordering
function M.update_tree_guides_after_sorting(items)
  -- Build parent-child relationships
  local children_by_parent = {}
  local signature_to_index = {}

  -- First pass - build the maps
  for i, item in ipairs(items) do
    signature_to_index[item.value.signature] = i

    if item.value.parent_signature then
      if not children_by_parent[item.value.parent_signature] then
        children_by_parent[item.value.parent_signature] = {}
      end
      table.insert(children_by_parent[item.value.parent_signature], item)
    end
  end

  -- Function to update tree state recursively
  local function update_tree_state(item_index, parent_tree_state)
    local item = items[item_index]
    if not item then
      return
    end

    -- Start with parent's tree state
    local new_tree_state = {}
    if parent_tree_state then
      for _, is_last in ipairs(parent_tree_state) do
        table.insert(new_tree_state, is_last)
      end
    end

    -- Calculate if this item is the last child of its parent
    local is_last = true
    if item.value.parent_signature then
      local siblings = children_by_parent[item.value.parent_signature]
      if siblings then
        is_last = (siblings[#siblings].value.signature == item.value.signature)
      end
    end

    -- Update the tree state for this item
    if #new_tree_state > 0 or item.depth > 0 then
      table.insert(new_tree_state, is_last)
    end

    -- Set the updated tree state
    item.tree_state = new_tree_state

    -- Update children
    local children = children_by_parent[item.value.signature]
    if children then
      for _, child in ipairs(children) do
        local child_index = signature_to_index[child.value.signature]
        if child_index then
          update_tree_state(child_index, new_tree_state)
        end
      end
    end
  end

  -- Start with the root item(s)
  for i, item in ipairs(items) do
    if item.value.is_root or item.value.is_current or not item.value.parent_signature then
      update_tree_state(i, {})
    end
  end

  return items
end

return M
