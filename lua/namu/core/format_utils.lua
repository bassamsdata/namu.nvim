local M = {}
local logger = require("namu.utils.logger")

-- Get the appropriate prefix based on format configuration
---@param item table The item to format with depth and tree_state properties
---@param config table Configuration with display settings
---@return string Formatted prefix for display
function M.get_item_prefix(item, config)
  if not item then
    return ""
  end

  -- Calculate prefix padding (for current highlight)
  local prefix_padding = ""
  if
    config.current_highlight
    and config.current_highlight.enabled
    and config.current_highlight.prefix_icon
    and #config.current_highlight.prefix_icon > 0
  then
    prefix_padding = string.rep(" ", vim.api.nvim_strwidth(config.current_highlight.prefix_icon))
  end

  local format = config.display.format or "indent"

  if format == "indent" then
    -- For indent format, we'll only return the padding
    -- The actual indentation will be handled in format_item_for_display
    return prefix_padding
  elseif format == "tree_guides" then
    return prefix_padding
  end

  return prefix_padding
end

-- Generate tree guides based on tree state
---@param tree_state table Array of boolean values indicating if item is last in its level
---@param style string "ascii" or "unicode"
---@return string Formatted guide string
function M.make_tree_guides(tree_state, style)
  -- Debug logging
  logger = require("namu.utils.logger")
  logger.log("make_tree_guides called with tree_state: " .. vim.inspect(tree_state))

  if not tree_state or #tree_state == 0 then
    logger.log("make_tree_guides: empty tree_state, returning empty string")
    return ""
  end

  local result = ""
  local chars = {
    ascii = {
      continue = "| ",
      last = "`-",
      item = "|-",
    },
    unicode = {
      continue = "┆ ",
      last = "└─",
      item = "├─",
    },
  }

  local style_chars = chars[style] or chars.unicode
  -- Generate guides for all levels except the last one
  for idx = 1, #tree_state - 1 do
    if tree_state[idx] then
      -- This branch is the last item at its level, no continuation needed
      result = result .. "  "
      logger.log("Level " .. idx .. " is last, adding spaces")
    else
      -- This branch has siblings below, need vertical line
      result = result .. style_chars.continue
      logger.log("Level " .. idx .. " has siblings, adding " .. style_chars.continue)
    end
  end

  -- Handle the last level
  if #tree_state > 0 then
    if tree_state[#tree_state] then
      result = result .. style_chars.last
      logger.log("Last level is last, adding " .. style_chars.last)
    else
      result = result .. style_chars.item
      logger.log("Last level has siblings, adding " .. style_chars.item)
    end
  end

  logger.log("Final tree guide result: '" .. result .. "'")
  return result
end

-- Format  anitem for display, including prefix and content
---@param item table Item to format with text, icon, etc.
---@param config table Configuration with display settings
---@return string Formatted display string
function M.format_item_for_display(item, config)
  -- Get basic prefix (padding for current highlight)
  local prefix = M.get_item_prefix(item, config)

  -- Special handling for tree guides format
  if config.display.format == "tree_guides" then
    -- Generate tree guides for any item with tree_state
    local tree_guides = ""
    if item.tree_state and item.depth then
      local guide_style = (config.display.tree_guides and config.display.tree_guides.style) or "unicode"
      tree_guides = M.make_tree_guides(item.tree_state, guide_style)
    end

    -- Add tree guides after prefix
    prefix = prefix .. tree_guides
  end
  -- tenable
  -- Special case for indent format with icon mode
  if config.display.mode == "icon" and config.display.format == "indent" then
    local depth = item.depth or 0
    local style = tonumber(config.display.style) or 2

    -- Icon and other elements
    local icon = item.icon or "  "
    local padding = string.rep(" ", config.display.padding or 1)
    local text = item.value and item.value.name or item.text

    -- Handle special indicators
    local indicator = ""
    if item.value and item.value.is_current then
      indicator = "▼ "
    end

    -- Create depth indicator with padding before the symbol
    local depth_indicator = ""
    if depth > 0 then
      if style == 2 then
        depth_indicator = string.rep(" ", (depth - 1) * 2) .. ".."
      elseif style == 3 then
        depth_indicator = string.rep(" ", (depth - 1) * 2) .. "→"
      end
    end

    -- Optional file info
    local file_info = ""
    if item.value and item.value.file_info then
      file_info = " " .. item.value.file_info
    end

    -- Check if icon should be after prefix symbol
    local icon_after_prefix = config.display.icon_after_prefix_symbol or false

    if icon_after_prefix then
      return prefix .. indicator .. depth_indicator .. icon .. padding .. text .. file_info
    else
      return prefix .. indicator .. icon .. padding .. depth_indicator .. text .. file_info
    end
  else
    -- Handle different display modes
    if config.display.mode == "raw" then
      -- Just the text with prefix
      return prefix .. (item.value and item.value.text or item.text)
    elseif config.display.mode == "icon" then
      -- Icon + text
      local icon = item.icon or "  "
      local padding = string.rep(" ", config.display.padding or 1)
      local text = item.value and item.value.name or item.text

      -- Handle special indicators
      local indicator = ""
      if item.value and item.value.is_current then
        indicator = "▼ "
      end

      -- Optional file info (used in call hierarchy)
      local file_info = ""
      if item.value and item.value.file_info then
        file_info = " " .. item.value.file_info
      end

      return prefix .. indicator .. icon .. padding .. text .. file_info
    else
      -- Legacy prefix_info approach
      if config.get_prefix_info then
        local prefix_info = config.get_prefix_info(item, config.display.prefix_width)
        local padding = string.rep(" ", prefix_info.padding or 0)
        return prefix .. prefix_info.text .. padding .. item.text
      else
        -- Fallback
        return prefix .. (item.value and item.value.text or item.text)
      end
    end
  end
end

-- Convert a flat list of items into a hierarchical structure with tree_state
---@param items table[] List of items with parent-child relationships
---@return table[] Updated items with tree_state property
function M.add_tree_state_to_items(items)
  -- Debug logging
  logger = require("namu.utils.logger")
  logger.log("add_tree_state_to_items called with " .. #items .. " items")

  -- Skip if no items
  if not items or #items == 0 then
    logger.log("No items, returning early")
    return items
  end

  -- Build parent-child relationships
  local children_by_parent = {}
  local signature_to_index = {}

  -- Debug counter for items with signatures and parent signatures
  local items_with_signature = 0
  local items_with_parent = 0
  local root_item_count = 0

  -- Build the maps and collect stats
  for i, item in ipairs(items) do
    if item.value and item.value.signature then
      items_with_signature = items_with_signature + 1
      signature_to_index[item.value.signature] = i

      -- Group children by parent
      if item.value.parent_signature then
        items_with_parent = items_with_parent + 1
        if not children_by_parent[item.value.parent_signature] then
          children_by_parent[item.value.parent_signature] = {}
        end
        table.insert(children_by_parent[item.value.parent_signature], item)
      else
        root_item_count = root_item_count + 1
      end
    end
  end

  logger.log("Items with signature: " .. items_with_signature)
  logger.log("Items with parent: " .. items_with_parent)
  logger.log("Root items (no parent): " .. root_item_count)

  -- Debug parent-child relationships
  for parent_sig, children in pairs(children_by_parent) do
    logger.log("Parent " .. parent_sig .. " has " .. #children .. " children")
  end

  -- Add a synthetic root if needed
  local need_synthetic_root = (root_item_count > 1 or root_item_count == 0) and items_with_parent > 0
  if need_synthetic_root then
    logger.log("Need synthetic root detected")

    -- Find items that should be treated as top-level (have parent signatures that don't exist)
    local orphaned_items = {}
    for i, item in ipairs(items) do
      if item.value and item.value.parent_signature and not signature_to_index[item.value.parent_signature] then
        table.insert(orphaned_items, item)
      end
    end

    logger.log("Orphaned items (parents don't exist): " .. #orphaned_items)

    -- Create a temporary root signature
    local root_signature = "synthetic_root"

    -- Make orphaned items children of the synthetic root
    for _, item in ipairs(orphaned_items) do
      if not children_by_parent[root_signature] then
        children_by_parent[root_signature] = {}
      end
      item.value.true_parent = item.value.parent_signature
      item.value.parent_signature = root_signature
      table.insert(children_by_parent[root_signature], item)
    end
  end

  -- Process function to build tree state for each item
  local processed = {}
  local function process_children(parent_signature, parent_tree_state)
    local children = children_by_parent[parent_signature]
    if not children or #children == 0 then
      return
    end

    logger.log("Processing " .. #children .. " children for parent " .. parent_signature)

    for i, child in ipairs(children) do
      local is_last = (i == #children)

      -- Copy parent tree state and add child's state
      local child_tree_state = {}
      if parent_tree_state then
        for _, state in ipairs(parent_tree_state) do
          table.insert(child_tree_state, state)
        end
      end
      table.insert(child_tree_state, is_last)

      logger.log("Child " .. (child.value.signature or "unknown") .. " tree_state: " .. vim.inspect(child_tree_state))

      -- Set the tree state on the item
      child.tree_state = child_tree_state

      -- Process this child's children
      if child.value and child.value.signature then
        process_children(child.value.signature, child_tree_state)
      end
    end
  end

  -- Critical difference: For call hierarchy, there's always a clear root item,
  -- but for symbols, we may have multiple top-level items with no parent.
  -- Let's ensure even top-level items get proper tree guides.

  -- First, collect all true root items (no parent)
  local root_items = {}
  for i, item in ipairs(items) do
    if item.value and item.value.signature and not item.value.parent_signature then
      table.insert(root_items, item)
    end
  end

  logger.log("Root items collected: " .. #root_items)

  -- If we have multiple root items, they should indicate they're part of a sequence
  for i, root_item in ipairs(root_items) do
    local is_last = (i == #root_items)
    root_item.tree_state = { is_last }
    logger.log(
      "Root item " .. i .. " with signature " .. root_item.value.signature .. " set is_last=" .. tostring(is_last)
    )

    -- Process children of this root
    process_children(root_item.value.signature, root_item.tree_state)
  end

  -- If we had a synthetic root, use it to process orphaned items
  if need_synthetic_root then
    process_children("synthetic_root", {})

    -- Restore original parent signatures
    for _, item in ipairs(items) do
      if item.value and item.value.true_parent then
        item.value.parent_signature = item.value.true_parent
        item.value.true_parent = nil
      end
    end
  end

  -- Log final tree state count
  local items_with_tree_state = 0
  for _, item in ipairs(items) do
    if item.tree_state and #item.tree_state > 0 then
      items_with_tree_state = items_with_tree_state + 1
    end
  end

  logger.log("Final items with tree_state: " .. items_with_tree_state .. " out of " .. #items)

  return items
end

return M
