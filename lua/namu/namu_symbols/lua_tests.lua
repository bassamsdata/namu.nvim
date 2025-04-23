local logger = require("namu.utils.logger")

local M = {}

-- Function to extract test information from Lua test patterns
function M.extract_lua_test_info(line_content)
  logger.log("Analyzing line: " .. line_content)

  -- First try to identify the namespace and first bracket content
  local namespace, first_segment = line_content:match('^(%w+)%["([^"]+)"%]')

  if not namespace or not first_segment then
    -- Try with single quotes if double quotes not found
    namespace, first_segment = line_content:match("^(%w+)%['([^']+)'%]")

    if not namespace or not first_segment then
      logger.log("No valid test pattern found in line: " .. line_content)
      return nil
    end
  end

  logger.log("Found namespace: " .. namespace .. ", first segment: " .. first_segment)

  -- Find all bracket segments
  local segments = {}
  local quote_type = line_content:match('%["') and '"' or "'"

  if quote_type == '"' then
    for segment_content in line_content:gmatch('%["([^"]+)"%]') do
      table.insert(segments, segment_content)
    end
  else
    for segment_content in line_content:gmatch("%['([^']+)'%]") do
      table.insert(segments, segment_content)
    end
  end

  logger.log("Total segments found: " .. #segments)

  -- Build result object
  local result = {
    namespace = namespace,
    segments = segments,
    quote_type = quote_type,
  }

  -- Always use first segment as parent, combine rest for child display
  result.parent_name = segments[1]

  -- Format the display names
  local bformat = function(s)
    return quote_type == '"' and '["' .. s .. '"]' or "['" .. s .. "']"
  end

  -- Parent full name is always just namespace + first bracket
  result.parent_full_name = namespace .. bformat(segments[1])

  -- Full name is the complete string
  result.full_name = namespace
  for _, segment in ipairs(segments) do
    result.full_name = result.full_name .. bformat(segment)
  end

  -- Child display is everything after the first bracket for multi-segment tests
  if #segments > 1 then
    result.child_display = ""
    for i = 2, #segments do
      result.child_display = result.child_display .. bformat(segments[i])
    end
    result.child_name = result.child_display
  else
    -- For single bracket tests, set child as nil
    result.child_display = nil
    result.child_name = nil
  end

  logger.log("Full name: " .. result.full_name)
  logger.log("Parent full name: " .. result.parent_full_name)

  if result.child_display then
    logger.log("Child display: " .. result.child_display)
  else
    logger.log("No child display (single bracket test)")
  end

  -- Find the position of the second bracket (for cursor positioning)
  local last_bracket_pos = nil
  if #segments > 1 then
    local first_bracket_end = line_content:find("%]", 1, true)
    if first_bracket_end then
      -- Find the position right after the first bracket's closing ']'
      last_bracket_pos = first_bracket_end + 1
      logger.log("Child starts at position: " .. last_bracket_pos)
    end
  end

  result.last_bracket_pos = last_bracket_pos

  logger.log("Test info extraction complete")
  return result
end

--- Processes a symbol potentially representing a Lua test.
--- Modifies symbol.name, range.start.character, adds parent items to `items` list if needed.
---@param symbol table The LSP symbol object (will be modified).
---@param config table Plugin configuration.
---@param state table Plugin state.
---@param range table The symbol's range object (will be modified).
---@param test_info_cache table Cache for extracted test info.
---@param first_bracket_counts table Counts of parent test names for hierarchy.
---@param items table The list of selecta items being built (will be modified).
---@param depth number Current symbol depth.
---@param generate_signature function Function to generate unique symbol signatures.
---@param lsp_symbol_kind function Function to get LSP symbol kind string.
---@param bufnr number Buffer number.
---@return number new_depth The potentially adjusted depth for the symbol.
---@return string|nil parent_signature The signature of the parent if hierarchy was applied.
function M.process_lua_test_symbol(
  symbol,
  config,
  state,
  range,
  test_info_cache,
  first_bracket_counts,
  items,
  depth,
  generate_signature,
  lsp_symbol_kind,
  bufnr
)
  local line = vim.api.nvim_buf_get_lines(state.original_buf, range.start.line, range.start.line + 1, false)[1]
  local test_info = test_info_cache[range.start.line] or M.extract_lua_test_info(line)
  local parent_signature = nil -- Initialize parent_signature for this scope

  if test_info then
    symbol.is_test_symbol = true -- Mark as processed test symbol

    if config.lua_test_preserve_hierarchy then
      local should_create_hierarchy = (first_bracket_counts[test_info.parent_full_name] or 0) > 1
      logger.log("Checking hierarchy for " .. test_info.full_name .. ": " .. tostring(should_create_hierarchy))

      if should_create_hierarchy then
        -- Adjust range for child item positioning
        if test_info.last_bracket_pos then
          range.start.character = test_info.last_bracket_pos
        else
          range.start.character = 0 -- Default to start if position not found
        end

        -- Look for an existing parent node
        local parent_found = false
        for _, item in ipairs(items) do
          if item.value and item.value.name == test_info.parent_full_name then
            parent_found = true
            parent_signature = item.value.signature -- Use existing parent's signature
            break
          end
        end

        -- Create parent node if it doesn't exist
        if not parent_found then
          local parent_symbol = {
            name = test_info.parent_full_name,
            kind = 6, -- Method kind for test suites
            range = {
              start = { line = range.start.line, character = 0 },
              ["end"] = { line = range.start.line + 1, character = 0 },
            },
          }
          local parent_sig = generate_signature(parent_symbol, 0) -- Parent is always at depth 0
          if parent_sig then
            parent_signature = parent_sig -- Store the new parent's signature
            local kind = lsp_symbol_kind(parent_symbol.kind)
            local parent_item = {
              value = {
                text = test_info.parent_full_name,
                name = test_info.parent_full_name,
                kind = kind,
                lnum = range.start.line + 1,
                col = 1,
                end_lnum = range.start.line + 2,
                end_col = 1,
                signature = parent_sig,
              },
              text = test_info.parent_full_name,
              bufnr = bufnr,
              icon = config.kindIcons[kind] or config.icon,
              kind = kind,
              depth = 0, -- Parent depth is 0
            }
            table.insert(items, parent_item)
            logger.log("Created parent item: " .. test_info.parent_full_name)
          else
            logger.log("Failed to generate signature for parent: " .. test_info.parent_full_name)
          end
        end

        -- Set this test as a child of the parent
        if parent_signature then
          symbol.parent_signature = parent_signature -- Assign to the symbol for later use
          symbol.name = test_info.child_display -- Use child display name
          depth = 1 -- Set depth to 1 for all children under this parent
        else
          -- Fallback if parent signature couldn't be created/found
          symbol.name = test_info.full_name
          range.start.character = 0 -- Reset character if hierarchy failed
        end
      else
        -- Unique first bracket, display it directly
        symbol.name = test_info.full_name
        range.start.character = 0
      end
    else
      -- Hierarchy preservation is disabled
      symbol.name = test_info.full_name
      range.start.character = 0
    end

    -- Truncate if configured and name is not nil
    if symbol.name and config.lua_test_truncate_length and #symbol.name > config.lua_test_truncate_length then
      symbol.name = symbol.name:sub(1, config.lua_test_truncate_length) .. "..."
    elseif not symbol.name then
      -- Fallback name if somehow it became nil (e.g., child_display was nil/empty)
      logger.log("Warning: symbol name became nil after processing, using fallback.")
      symbol.name = test_info.full_name or "Unknown Test"
      range.start.character = 0 -- Ensure range is reset for fallback
    end
  else
    -- Not a recognized test pattern, keep original name but log it
    logger.log("Symbol at line " .. range.start.line + 1 .. " did not match test pattern: " .. line)
    -- Keep original symbol.name and range.start.character
  end

  return depth, parent_signature -- Return potentially modified depth and parent_signature
end

--- Recursively counts first bracket occurrences in potential test symbols.
--- Modifies test_info_cache and first_bracket_counts tables.
---@param symbol LSPSymbol The symbol to process.
---@param state NamuState The plugin state.
---@param config table Plugin configuration.
---@param test_info_cache table Cache for extracted test info.
---@param first_bracket_counts table Counts of parent test names.
function M.count_first_brackets(symbol, state, config, test_info_cache, first_bracket_counts)
  if not symbol or not symbol.name then
    return
  end

  -- Check if this is potentially a Lua test function based on name/structure
  if
    (symbol.name == "" or symbol.name == " " or symbol.name:match("^function"))
    and (symbol.range or (symbol.location and symbol.location.range))
  then
    local range = symbol.range or (symbol.location and symbol.location.range)
    local line = vim.api.nvim_buf_get_lines(state.original_buf, range.start.line, range.start.line + 1, false)[1]
    -- Use the passed-in extractor function
    local test_info = M.extract_lua_test_info(line)
    if test_info then
      -- Cache the test info for later use in processing
      test_info_cache[range.start.line] = test_info

      -- Count occurrences of the first bracket pattern
      first_bracket_counts[test_info.parent_full_name] = (first_bracket_counts[test_info.parent_full_name] or 0) + 1
      logger.log(
        "Counting first bracket: "
          .. test_info.parent_full_name
          .. " = "
          .. first_bracket_counts[test_info.parent_full_name]
      )
    end
  end

  -- Check children recursively, passing all necessary context
  if symbol.children then
    for _, child in ipairs(symbol.children) do
      M.count_first_brackets(child, state, config, test_info_cache, first_bracket_counts, extract_lua_test_info, logger)
    end
  end
end
return M
