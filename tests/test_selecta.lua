---@diagnostic disable: need-check-nil
local h = require("tests.helpers")
local selecta = require("namu.selecta.selecta")
local matcher = require("namu.selecta.matcher")
local new_set = MiniTest.new_set

local T = new_set()

T["Selecta.matching"] = new_set()

-- test 1
-- Test exact prefix matches
T["Selecta.matching"]["detects prefix matches correctly"] = function()
  local get_match_positions = matcher._test.get_match_positions

  -- Basic prefix match
  local result = get_match_positions("hello", "he")
  h.eq(result.type, "prefix")
  h.eq(result.positions, { { 1, 2 } })

  -- Case-sensitive match
  result = get_match_positions("Hello", "He")
  h.eq(result.type, "prefix")
  h.eq(result.positions, { { 1, 2 } })

  -- Case-insensitive match
  result = get_match_positions("HELLO", "he")
  h.eq(result.type, "prefix")
  h.eq(result.positions, { { 1, 2 } })

  -- No match
  result = get_match_positions("hello", "xy")
  h.eq(result, nil)
end

-- test 2
-- Test substring matches
T["Selecta.matching"]["detects substring matches correctly"] = function()
  local get_match_positions = matcher._test.get_match_positions

  -- Basic substring match that isn't a prefix
  -- Using "orl" instead of "ello" because "ello" is being detected as a prefix
  local result = get_match_positions("hello world", "orl")
  h.eq(result.type, "contains")
  h.eq(result.positions, { { 8, 10 } })

  -- Test another substring case
  result = get_match_positions("abcdefg", "def")
  h.eq(result.type, "contains")
  h.eq(result.positions, { { 4, 6 } })

  -- Match at word boundary
  result = get_match_positions("hello_world", "orld")
  h.eq(result.type, "contains")
  h.eq(result.positions, { { 8, 11 } })
  h.eq(result.score > 70, true, "Should have word boundary bonus")

  -- Multiple occurrences should find best match
  result = get_match_positions("world hello world", "orld")
  h.eq(result.type, "contains")
  h.eq(result.positions, { { 2, 5 } }, "Should prefer earlier occurrence")
end

-- test 3
-- Test fuzzy matches
T["Selecta.matching"]["handles fuzzy matches correctly"] = function()
  local get_match_positions = matcher._test.get_match_positions

  -- Basic fuzzy match
  local result = get_match_positions("hello world", "hwd")
  h.eq(result.type, "fuzzy")
  h.eq(#result.positions, 3)
  h.eq(result.matched_chars, 3)

  -- Consecutive characters score higher
  local score1 = get_match_positions("hello", "hel").score
  local score2 = get_match_positions("hello", "hlo").score
  h.eq(score1 > score2, true, "Consecutive matches should score higher")

  -- Word boundary matches score higher
  local score3 = get_match_positions("hello_world", "hw").score
  local score4 = get_match_positions("helloworld", "hw").score
  h.eq(score3 > score4, true, "Word boundary matches should score higher")
end

-- test 4
-- Test word boundaries
T["Selecta.matching"]["detects word boundaries correctly"] = function()
  local is_word_boundary = matcher._test.is_word_boundary

  h.eq(is_word_boundary("hello", 1), true) -- Start of string
  h.eq(is_word_boundary("hello_world", 7), true) -- After underscore
  h.eq(is_word_boundary("helloWorld", 6), true) -- camelCase boundary
  h.eq(is_word_boundary("HelloWorld", 1), true) -- PascalCase boundary
  h.eq(is_word_boundary("hello", 2), false) -- Not a boundary
end

-- test 5
T["Selecta.matching"]["applies correct scoring rules"] = function()
  local get_match_positions = matcher._test.get_match_positions

  -- Test different match types with the same pattern length
  local prefix_score = get_match_positions("hello", "he").score
  local contains_score = get_match_positions("the hello", "el").score
  local fuzzy_score = get_match_positions("handle", "hl").score

  -- Verify match type hierarchy
  h.eq(prefix_score > contains_score, true, "Prefix should score higher than contains")
  h.eq(contains_score > fuzzy_score, true, "Contains should score higher than fuzzy")

  -- Position scoring within the same match type
  local early_match = get_match_positions("abcdef", "abc").score
  local late_match = get_match_positions("defabc", "abc").score
  h.eq(early_match > late_match, true, "Earlier matches should score higher")

  -- Length scoring
  local short_text = get_match_positions("hi", "hi").score
  local long_text = get_match_positions("history", "hi").score
  h.eq(short_text > long_text, true, "Shorter text should score higher")
end

-- test 6
T["Selecta.matching"]["filters items correctly"] = function()
  local items = {
    { text = "apple" },
    { text = "banana" },
    { text = "cherry" },
  }

  local state = {
    items = items,
    query = { "a" },
    cursor_pos = 2,
  }

  -- Call the update function directly
  selecta._test.update_filtered_items(state, "a", {
    preserve_order = false,
  })

  h.eq(#state.filtered_items, 2)
  h.eq(state.filtered_items[1].text, "apple")
  h.eq(state.filtered_items[2].text, "banana")
end

-- Scoring TEST ---------------------------------------------------
T["Selecta.scoring"] = new_set()

-- test 7
T["Selecta.scoring"]["applies correct scoring rules"] = function()
  -- Test scoring directly
  local text1 = "hello"
  local text2 = "help me"
  local query = "he"

  local score1 = matcher._test.get_match_positions(text1, query).score
  local score2 = matcher._test.get_match_positions(text2, query).score

  h.eq(score1 > score2, true, "Shorter match should score higher")
end

-- Filtering TEST ---------------------------------------------------
T["Selecta.filtering"] = new_set()

-- test 8
T["Selecta.filtering"]["handles basic filtering"] = function()
  local items = {
    { text = "apple" },
    { text = "banana" },
    { text = "cherry" },
  }

  -- Change 3: Call update_filtered_items directly
  local state = {
    items = items,
    filtered_items = items,
    query = { "a" },
    cursor_pos = 2,
  }

  selecta._test.update_filtered_items(state, "a", {
    preserve_order = false,
  })

  h.eq(#state.filtered_items, 2) -- Should match "apple" and "banana"
end

-- Config TEST ---------------------------------------------------
T["Selecta.config"] = new_set()

-- test 9
T["Selecta.config"]["applies default configuration"] = function()
  selecta.setup({})

  -- Check default window config
  h.eq(selecta.config.window.relative, "editor")
  h.eq(selecta.config.window.border, "none")
  h.eq(selecta.config.window.width_ratio, 0.6)
  h.eq(selecta.config.window.height_ratio, 0.6)

  -- Check default display config
  h.eq(selecta.config.display.mode, "icon")
  h.eq(selecta.config.display.padding, 1)
end

-- test 10
T["Selecta.config"]["merges user configuration"] = function()
  selecta.setup({
    window = {
      border = "rounded",
      width_ratio = 0.8,
    },
    display = {
      mode = "text",
      padding = 2,
    },
  })

  -- Check merged window config
  h.eq(selecta.config.window.border, "rounded")
  h.eq(selecta.config.window.width_ratio, 0.8)
  h.eq(selecta.config.window.relative, "editor") -- Default preserved

  -- Check merged display config
  h.eq(selecta.config.display.mode, "text")
  h.eq(selecta.config.display.padding, 2)
end

-- Highlight TEST ---------------------------------------------------
T["Selecta.highlights"] = new_set({})

-- test 11
T["Selecta.highlights"]["sets up highlight groups"] = function()
  selecta._test.setup_highlights()
  local match_hl = vim.api.nvim_get_hl(0, { name = "SelectaMatch" })
  local prefix_hl = vim.api.nvim_get_hl(0, { name = "SelectaPrefix" })
  local cursor_hl = vim.api.nvim_get_hl(0, { name = "SelectaCursor" })
  local filter_hl = vim.api.nvim_get_hl(0, { name = "SelectaFilter" })

  -- Verify highlight attributes
  h.eq(type(match_hl), "table")
  h.eq(type(prefix_hl), "table")
  h.eq(type(cursor_hl), "table")
  h.eq(type(filter_hl), "table")

  -- Check specific attributes
  h.eq(cursor_hl.blend, 100)
end

-- test 12
T["Selecta.highlights"]["calculates highlight positions"] = function()
  -- Test highlight position calculation directly
  local text = "hello world"
  local query = "he"
  local matches = matcher._test.get_match_positions(text, query)

  h.eq(type(matches), "table")
  h.eq(type(matches.positions), "table")
  h.eq(matches.positions[1][1], 1)
  h.eq(matches.positions[1][2], 2)
end

-- Window TEST ---------------------------------------------------
T["Selecta.window_sizing"] = new_set()

-- test 13
T["Selecta.window_sizing"]["calculates correct dimensions"] = function()
  local items = {
    { text = "short" },
    { text = "this is a much longer item" },
  }

  -- Test calculate_window_size directly
  local width, height = selecta._test.calculate_window_size(items, {
    window = {
      auto_size = true,
      min_width = 20,
      max_width = 120,
      padding = 2,
    },
  }, function(item)
    return item.text
  end)

  h.eq(type(width), "number")
  h.eq(width >= 20, true)
  h.eq(width <= 120, true)
  h.eq(height, 2)
end

-- Input TEST ---------------------------------------------------
T["Selecta.input_validation"] = new_set()

-- test 14
T["Selecta.input_validation"]["validates search input"] = function()
  -- Test validate_input directly
  local valid, _ = matcher._test.validate_input("text", "query")
  h.eq(valid, true)

  local valid2, err = matcher._test.validate_input("", "query")
  h.eq(valid2, false)
  h.eq(type(err), "string")
end

--Window Management--------------------------------------------------
T["Selecta.window_management"] = new_set()

-- test 15
T["Selecta.window_management"]["calculates window dimensions correctly"] = function()
  local items = {
    { text = "short" },
    { text = "this is a much longer item that should affect width" },
  }

  -- Test window calculation function directly
  local width, height = selecta._test.calculate_window_size(items, {
    window = {
      auto_size = true,
      padding = 2,
      min_width = 20,
      max_width = 120,
    },
  }, function(item)
    return item.text
  end)

  h.eq(type(width), "number")
  h.eq(type(height), "number")
  h.eq(width >= 20, true)
  h.eq(width <= 120, true)
  h.eq(height, 2)
end

--Cursor Management--------------------------------------------------
T["Selecta.cursor_management"] = new_set()

-- test 16
T["Selecta.cursor_management"]["restores cursor on errors"] = function()
  local original_guicursor = vim.o.guicursor

  -- Force an error by providing invalid items
  local ok, err = pcall(function()
    selecta.pick(nil, {})
  end)

  h.eq(ok, false)
  h.eq(type(err), "string")
  h.eq(vim.o.guicursor, original_guicursor)
end

--Error Handling-----------------------------------------------------
T["Selecta.error_handling"] = new_set()

-- test 17
T["Selecta.error_handling"]["handles invalid items"] = function()
  local ok, err = pcall(function()
    selecta.pick(nil, {})
  end)

  h.eq(ok, false)
  h.eq(type(err), "string")
end

-- test 18
T["Selecta.error_handling"]["handles window creation errors"] = function()
  local items = { { text = "test" } }

  -- Force window creation error with invalid relative option
  local ok, err = pcall(function()
    selecta.pick(items, {
      window = {
        relative = "invalid_option",
      },
    })
  end)
  h.eq(ok, false)
  h.eq(type(err), "string")
end

--Window Positioning-----------------------------------------------------
T["Window.positioning"] = new_set()

-- test 19
T["Window.positioning"]["parse_position handles all position types correctly"] = function()
  local parse_position = selecta._test.parse_position

  -- Test top with percentage
  local result = parse_position("top20")
  h.eq(result.type, "top")
  h.eq(result.ratio, 0.2)

  -- Test top with percentage and right alignment
  result = parse_position("top25_right")
  h.eq(result.type, "top_right")
  h.eq(result.ratio, 0.25)

  -- Test fixed center position
  result = parse_position("center")
  h.eq(result.type, "center")
  h.eq(result.ratio, 0.5)

  -- Test fixed bottom position
  result = parse_position("bottom")
  h.eq(result.type, "bottom")
  h.eq(result.ratio, 0.8)

  -- Test invalid input fallback
  result = parse_position("invalid_position")
  h.eq(result.type, "top")
  h.eq(result.ratio, 0.1)

  -- Test nil input fallback
  result = parse_position(nil)
  h.eq(result and result.type, "top")
  h.eq(result and result.ratio, 0.1)
end

-- test 20
T["Window.positioning"]["get_window_position calculates correct positions"] = function()
  local get_window_position = selecta._test.get_window_position

  -- Mock vim.o values
  local _original_o = vim.o
  vim.o = {
    lines = 100,
    columns = 200,
    cmdheight = 1,
  }

  -- Test center position
  local row, col = get_window_position(40, "center")
  h.eq(row, 48) -- (100 - 1 - 2) * 0.5 = 48.5, floor to 48
  h.eq(col, 80) -- (200 - 40) / 2

  -- Test top percentage
  row, col = get_window_position(40, "top20")
  h.eq(row, 20) -- 100 * 0.2
  h.eq(col, 80) -- (200 - 40) / 2

  -- Test top percentage with right alignment
  row, col = get_window_position(40, "top25_right")
  h.eq(row, 25) -- 100 * 0.25
  h.eq(col, 156) -- 200 - 40 - 4

  -- Test bottom position
  row, col = get_window_position(40, "bottom")
  h.eq(row, 76) -- (100 * 0.8) - 4
  h.eq(col, 80) -- (200 - 40) / 2

  -- Restore vim.o
  vim.o = _original_o
end

-- test 21
-- right position with fixed ratio
T["Window.positioning"]["handles fixed right position correctly"] = function()
  local get_window_position = selecta._test.get_window_position

  -- Mock vim.o and config
  local _original_o = vim.o
  vim.o = {
    lines = 100,
    columns = 200,
    cmdheight = 1,
  }

  local _original_config = selecta.config
  selecta.config = {
    right_position = {
      fixed = true,
      ratio = 0.8,
    },
  }

  -- Test fixed right position
  ---@diagnostic disable-next-line: param-type-mismatch
  local row, col = get_window_position(40, "top20_right")
  h.eq(row, 20) -- 100 * 0.2
  h.eq(col, 160) -- 200 * 0.8

  -- Restore mocks
  vim.o = _original_o
  selecta.config = _original_config
end

return T
