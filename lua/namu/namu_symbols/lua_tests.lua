local logger = require("namu.utils.logger")

local M = {}

-- Function to extract test information from Lua test patterns
function M.extract_lua_test_info(line_content)
  -- Match namespace and identify quote style in one pass
  local namespace, bracket_content = line_content:match("^(%w+)%[(['\"])")
  if not namespace or not bracket_content then
    return nil
  end
  local quote_type = bracket_content
  local segments = {}
  local pattern = "%[" .. quote_type .. "([^" .. quote_type .. "]+)" .. quote_type .. "%]"
  for segment_content in line_content:gmatch(pattern) do
    table.insert(segments, segment_content)
  end
  if #segments == 0 then
    return nil
  end
  -- Build result object with all necessary properties in one go
  local result = {
    namespace = namespace,
    segments = segments,
    quote_type = quote_type,
    parent_name = segments[1],
    full_name = namespace,
  }
  -- Create a format function once instead of inline string concatenation
  local bformat = function(s)
    return "[" .. quote_type .. s .. quote_type .. "]"
  end
  -- Build names in a single pass
  result.parent_full_name = namespace .. bformat(segments[1])
  -- Calculate full_name in one pass
  for _, segment in ipairs(segments) do
    result.full_name = result.full_name .. bformat(segment)
  end
  -- Set child display and name if needed
  if #segments > 1 then
    result.child_display = ""
    for i = 2, #segments do
      if i > 2 then
        result.child_display = result.child_display .. " "
      end
      result.child_display = result.child_display .. bformat(segments[i])
    end
    result.child_name = result.child_display
  end

  -- Find bracket position more efficiently
  if #segments > 1 then
    -- Find the position after the first segment directly
    local first_segment_pattern = namespace .. bformat(segments[1])
    local _, first_segment_end_pos = line_content:find(first_segment_pattern, 1, true)
    result.last_bracket_pos = first_segment_end_pos and (first_segment_end_pos + 1) or nil
  end

  return result
end

--- Processes a symbol potentially representing a Lua test.
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
  local line = vim.api.nvim_buf_get_lines(bufnr, range.start.line, range.start.line + 1, false)[1]
  local test_info = test_info_cache[range.start.line] or M.extract_lua_test_info(line)
  local parent_signature = nil
  if test_info then
    symbol.is_test_symbol = true
    if config.lua_test_preserve_hierarchy then
      local should_create_hierarchy = (first_bracket_counts[test_info.parent_full_name] or 0) > 1
      logger.log("Checking hierarchy for " .. test_info.full_name .. ": " .. tostring(should_create_hierarchy))

      if should_create_hierarchy then
        if test_info.last_bracket_pos then
          range.start.character = test_info.last_bracket_pos - 1
        else
          range.start.character = 0
        end
        local parent_found = false
        for _, item in ipairs(items) do
          if item.value and item.value.name == test_info.parent_full_name then
            parent_found = true
            parent_signature = item.value.signature
            break
          end
        end

        if not parent_found then
          local parent_symbol = {
            name = test_info.parent_full_name,
            kind = 6,
            range = {
              start = { line = range.start.line, character = 0 },
              ["end"] = { line = range.start.line + 1, character = 0 },
            },
          }
          local parent_sig = generate_signature(parent_symbol, 0)
          if parent_sig then
            parent_signature = parent_sig
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
              depth = 0,
            }
            table.insert(items, parent_item)
          end
        end

        if parent_signature then
          symbol.parent_signature = parent_signature
          symbol.name = test_info.child_display
          depth = 1
        else
          symbol.name = test_info.full_name
          range.start.character = 0
        end
      else
        symbol.name = test_info.full_name
        range.start.character = 0
      end
    else
      symbol.name = test_info.full_name
      range.start.character = 0
    end

    if symbol.name and config.lua_test_truncate_length and #symbol.name > config.lua_test_truncate_length then
      symbol.name = symbol.name:sub(1, config.lua_test_truncate_length) .. "..."
    elseif not symbol.name then
      symbol.name = test_info.full_name or "Unknown Test"
      range.start.character = 0
    end
  else
    logger.log("No test information found for symbol.")
  end

  return depth, parent_signature
end

--- Recursively counts first bracket occurrences in potential test symbols.
--- (Function body remains the same)
function M.count_first_brackets(symbol, state, config, test_info_cache, first_bracket_counts)
  if not symbol or not symbol.name then
    return
  end
  if
    (symbol.name == "" or symbol.name == " " or symbol.name:match("^function"))
    and (symbol.range or (symbol.location and symbol.location.range))
  then
    local range = symbol.range or (symbol.location and symbol.location.range)
    local line = vim.api.nvim_buf_get_lines(state.original_buf, range.start.line, range.start.line + 1, false)[1]
    if line then
      local test_info = M.extract_lua_test_info(line)
      if test_info then
        test_info_cache[range.start.line] = test_info
        first_bracket_counts[test_info.parent_full_name] = (first_bracket_counts[test_info.parent_full_name] or 0) + 1
      end
    end
  end

  if symbol.children then
    for _, child in ipairs(symbol.children) do
      M.count_first_brackets(child, state, config, test_info_cache, first_bracket_counts)
    end
  end
end

return M
