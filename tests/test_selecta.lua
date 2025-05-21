---@diagnostic disable: need-check-nil, param-type-mismatch
local h = require("tests.helpers")
local selecta = require("namu.selecta.selecta")
local matcher = require("namu.selecta.matcher")
local StateManager = require("namu.selecta.state").StateManager
local selecta_config = require("namu.selecta.selecta_config")
local common = require("namu.selecta.common") -- Added for mocking
---@diagnostic disable-next-line: undefined-global
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
  -- Opts for StateManager.new can be empty if not specifically testing StateManager features here.
  local state_manager_opts = {}
  local state = StateManager.new(items, state_manager_opts)

  -- Set initial state conditions as per test requirements
  state.filtered_items = items -- Initial state before filtering might show all items
  state.query = { "a" } -- Represents a pre-existing query before this update cycle
  state.cursor_pos = 2 -- Example cursor position

  -- Opts for update_filtered_items
  local update_opts = { preserve_order = false }

  -- Call the update function with the current query "a"
  selecta._test.update_filtered_items(state, "a", update_opts)

  h.eq(#state.filtered_items, 2) -- Should match "apple" and "banana"
  -- Verify the content of filtered items
  local texts = {}
  for _, item in ipairs(state.filtered_items) do
    table.insert(texts, item.text)
  end
  table.sort(texts) -- Sort because preserve_order is false, order might not be guaranteed
  h.eq(texts[1], "apple")
  h.eq(texts[2], "banana")
end

-- test 6 (moved from Selecta.matching)
T["Selecta.filtering"]["filters items correctly"] = function()
  local items = {
    { text = "apple" },
    { text = "banana" },
    { text = "cherry" },
  }
  local state_manager_opts = {} -- Opts for StateManager.new
  local state = StateManager.new(items, state_manager_opts)

  -- Set initial state conditions as per test requirements
  -- state.items is already set by StateManager.new
  -- state.filtered_items is also set to items by default in StateManager.new
  state.query = { "a" } -- Represents a pre-existing query
  state.cursor_pos = 2 -- Example cursor position, matching original test

  -- Opts for update_filtered_items
  local update_opts = { preserve_order = false }

  -- Call the update function with the current query "a"
  selecta._test.update_filtered_items(state, "a", update_opts)

  h.eq(#state.filtered_items, 2)
  -- Verify the content of filtered items, sorting because preserve_order = false
  local texts = {}
  for _, item in ipairs(state.filtered_items) do
    table.insert(texts, item.text)
  end
  table.sort(texts)
  h.eq(texts[1], "apple")
  h.eq(texts[2], "banana")
end

-- Config TEST ---------------------------------------------------
T["Selecta.config"] = new_set()

-- test 9
T["Selecta.config"]["applies default configuration"] = function()
  selecta.setup({})

  -- Check default window config
  h.eq(selecta_config.values.window.relative, "editor")
  h.eq(selecta_config.values.window.border, "none")
  h.eq(selecta_config.values.window.width_ratio, 0.6)
  h.eq(selecta_config.values.window.height_ratio, 0.6)

  -- Check default display config
  h.eq(selecta_config.values.display.mode, "icon")
  h.eq(selecta_config.values.display.padding, 1)
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
  h.eq(selecta_config.values.window.border, "rounded")
  h.eq(selecta_config.values.window.width_ratio, 0.8)
  h.eq(selecta_config.values.window.relative, "editor") -- Default preserved

  -- Check merged display config
  h.eq(selecta_config.values.display.mode, "text")
  h.eq(selecta_config.values.display.padding, 2)
end

-- Highlight TEST ---------------------------------------------------
T["Selecta.highlights"] = new_set({})

-- test 11
T["Selecta.highlights"]["sets up highlight groups"] = function()
  require("namu.core.highlights").setup()
  local match_hl = vim.api.nvim_get_hl(0, { name = "NamuMatch" })
  local prefix_hl = vim.api.nvim_get_hl(0, { name = "NamuPrefix" })
  local cursor_hl = vim.api.nvim_get_hl(0, { name = "NamuCursor" })
  local filter_hl = vim.api.nvim_get_hl(0, { name = "NamuFilter" })

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
  local opts_general = { window = { relative = "editor" } } -- General opts

  -- Test center position
  local row, col = get_window_position(40, "center", opts_general, nil, "")
  h.eq(row, 48) -- (100 - 1 - 2) * 0.5 = 48.5, floor to 48
  h.eq(col, 80) -- (200 - 40) / 2

  -- Test top percentage
  row, col = get_window_position(40, "top20", opts_general, nil, "")
  h.eq(row, 19) -- math.floor((100 - 1 - 2) * 0.2) = math.floor(97 * 0.2) = 19
  h.eq(col, 80) -- (200 - 40) / 2

  -- Test top percentage with right alignment
  row, col = get_window_position(40, "top25_right", opts_general, nil, "")
  h.eq(row, 24) -- math.floor((100 - 1 - 2) * 0.25) = math.floor(97 * 0.25) = 24
  h.eq(col, 156) -- 200 - 40 - 4

  -- Test bottom position
  local opts_for_bottom = { window = { relative = "editor", height = 40 } } -- Provide window height
  row, col = get_window_position(40, "bottom", opts_for_bottom, nil, "")
  h.eq(row, 73) -- math.floor(97 * 0.8) - 4 = 77 - 4 = 73
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
  local opts_for_test21 = { window = { relative = "editor" } }

  -- Modify fields of the existing selecta_config.values.right_position table
  local original_right_position_fixed = selecta_config.values.right_position.fixed
  local original_right_position_ratio = selecta_config.values.right_position.ratio

  selecta_config.values.right_position.fixed = true
  selecta_config.values.right_position.ratio = 0.8

  -- Test fixed right position
  ---@diagnostic disable-next-line: param-type-mismatch
  local row, col = get_window_position(40, "top20_right", opts_for_test21, nil, "")
  h.eq(row, 19) -- math.floor((100 - 1 - 2) * 0.2) = 19
  h.eq(col, 160) -- 200 * 0.8 (should be fixed now)

  -- Restore mocks
  vim.o = _original_o
  -- Restore original values to the fields
  selecta_config.values.right_position.fixed = original_right_position_fixed
  selecta_config.values.right_position.ratio = original_right_position_ratio
end

-- StateManager TEST ---------------------------------------------------
T["StateManager"] = new_set({})

-- test 22
T["StateManager"]["updates query from buffer correctly"] = function()
  local items = {}
  local opts = {}
  local state = StateManager.new(items, opts)

  state.prompt_buf = 1 -- Mock buffer ID
  state.prompt_win = 1 -- Mock window ID

  -- Store original vim.api functions
  local orig_nvim_buf_is_valid = vim.api.nvim_buf_is_valid
  local orig_nvim_win_is_valid = vim.api.nvim_win_is_valid
  local orig_nvim_buf_get_lines = vim.api.nvim_buf_get_lines
  local orig_nvim_win_get_cursor = vim.api.nvim_win_get_cursor

  local success, err_msg -- To store pcall result and error

  pcall(function() -- Wrap test logic in pcall for cleanup
    -- Apply mocks
    vim.api.nvim_buf_is_valid = function(bufnr)
      if bufnr == state.prompt_buf then return true end
      return orig_nvim_buf_is_valid(bufnr)
    end
    vim.api.nvim_win_is_valid = function(winid)
      if winid == state.prompt_win then return true end
      return orig_nvim_win_is_valid(winid)
    end
    vim.api.nvim_buf_get_lines = function(bufnr, start_line, end_line, strict_indexing)
      if bufnr == state.prompt_buf and start_line == 0 and end_line == 1 then
        return { "test query" }
      end
      return orig_nvim_buf_get_lines(bufnr, start_line, end_line, strict_indexing)
    end
    vim.api.nvim_win_get_cursor = function(winid)
      if winid == state.prompt_win then
        return { 1, 5 } -- line 1, col 5 (0-indexed) -> cursor_pos = 6
      end
      return orig_nvim_win_get_cursor(winid)
    end

    -- Scenario 1: Query changes
    state.query_string = "" -- Ensure it's different initially for the first check
    local changed = state:update_query_from_buffer()
    h.eq(changed, true, "Changed should be true on first update")
    h.eq(state.query_string, "test query", "query_string should be updated")
    h.eq(state.query, { "t", "e", "s", "t", " ", "q", "u", "e", "r", "y" }, "state.query table incorrect")
    h.eq(state.cursor_pos, 6, "cursor_pos should be updated (col 5 -> index 6)")

    -- Scenario 2: Query does not change
    -- state.query_string is now "test query". nvim_buf_get_lines will return "test query".
    -- The internal logic of update_query_from_buffer compares the new buffer content
    -- with the *current* state.query_string *before* state.query_string is updated with new buffer content.
    local changed_again = state:update_query_from_buffer()
    h.eq(changed_again, false, "Changed should be false when buffer content matches state.query_string")
    h.eq(state.query_string, "test query", "query_string should remain the same after no change")
    h.eq(state.cursor_pos, 6, "cursor_pos should still be updated from nvim_win_get_cursor")
  end)
  success = success -- Temporarily store actual success, pcall might overwrite it.
  -- Restore original vim.api functions
  vim.api.nvim_buf_is_valid = orig_nvim_buf_is_valid
  vim.api.nvim_win_is_valid = orig_nvim_win_is_valid
  vim.api.nvim_buf_get_lines = orig_nvim_buf_get_lines
  vim.api.nvim_win_get_cursor = orig_nvim_win_get_cursor

  -- Re-throw error if pcall failed
  if not success then
    error(err_msg) -- Use the stored error message
  end
end

-- StateManager TEST ---------------------------------------------------
T["StateManager"] = new_set({})

-- test 22
T["StateManager"]["updates query from buffer correctly"] = function()
  local items = {}
  local opts = {}
  local state = StateManager.new(items, opts)

  state.prompt_buf = 1 -- Mock buffer ID
  state.prompt_win = 1 -- Mock window ID

  -- Store original vim.api functions
  local orig_nvim_buf_is_valid = vim.api.nvim_buf_is_valid
  local orig_nvim_win_is_valid = vim.api.nvim_win_is_valid
  local orig_nvim_buf_get_lines = vim.api.nvim_buf_get_lines
  local orig_nvim_win_get_cursor = vim.api.nvim_win_get_cursor

  local success, err_msg

  success, err_msg = pcall(function() -- Wrap test logic in pcall for cleanup
    -- Apply mocks
    vim.api.nvim_buf_is_valid = function(bufnr)
      if bufnr == state.prompt_buf then return true end
      return orig_nvim_buf_is_valid(bufnr)
    end
    vim.api.nvim_win_is_valid = function(winid)
      if winid == state.prompt_win then return true end
      return orig_nvim_win_is_valid(winid)
    end
    vim.api.nvim_buf_get_lines = function(bufnr, start_line, end_line, strict_indexing)
      if bufnr == state.prompt_buf and start_line == 0 and end_line == 1 then
        return { "test query" }
      end
      return orig_nvim_buf_get_lines(bufnr, start_line, end_line, strict_indexing)
    end
    vim.api.nvim_win_get_cursor = function(winid)
      if winid == state.prompt_win then
        return { 1, 5 } -- line 1, col 5 (0-indexed) -> cursor_pos = 6
      end
      return orig_nvim_win_get_cursor(winid)
    end

    -- Scenario 1: Query changes
    state.query_string = "" -- Ensure it's different initially for the first check
    local changed = state:update_query_from_buffer()
    h.eq(changed, true, "Changed should be true on first update")
    h.eq(state.query_string, "test query", "query_string should be updated")
    h.eq(state.query, { "t", "e", "s", "t", " ", "q", "u", "e", "r", "y" }, "state.query table incorrect")
    h.eq(state.cursor_pos, 6, "cursor_pos should be updated (col 5 -> index 6)")

    -- Scenario 2: Query does not change
    -- state.query_string is now "test query". nvim_buf_get_lines will return "test query".
    local changed_again = state:update_query_from_buffer()
    h.eq(changed_again, false, "Changed should be false when buffer content matches state.query_string")
    h.eq(state.query_string, "test query", "query_string should remain the same after no change")
    h.eq(state.cursor_pos, 6, "cursor_pos should still be updated from nvim_win_get_cursor")
  end)
  
  -- Restore original vim.api functions
  vim.api.nvim_buf_is_valid = orig_nvim_buf_is_valid
  vim.api.nvim_win_is_valid = orig_nvim_win_is_valid
  vim.api.nvim_buf_get_lines = orig_nvim_buf_get_lines
  vim.api.nvim_win_get_cursor = orig_nvim_win_get_cursor

  -- Re-throw error if pcall failed
  if not success then
    error(err_msg) 
  end
end

T["StateManager"]["handles movement correctly"] = function()
  local items = { { text = "item1" }, { text = "item2" }, { text = "item3" } }
  local on_move_spy = { called_with = nil, call_count = 0 }
  local opts = {
    on_move = function(item)
      on_move_spy.called_with = item
      on_move_spy.call_count = on_move_spy.call_count + 1
    end,
    -- Add current_highlight options as common.update_current_highlight expects them
    current_highlight = { enabled = true, prefix_icon = ">" } 
  }
  local state = StateManager.new(items, opts)
  state.filtered_items = items
  state.win = 1 -- Mock window ID

  -- Store original functions
  local orig_nvim_win_is_valid = vim.api.nvim_win_is_valid
  local orig_nvim_win_get_cursor = vim.api.nvim_win_get_cursor
  local orig_nvim_win_set_cursor = vim.api.nvim_win_set_cursor
  local orig_common_update_highlight = common.update_current_highlight -- Use 'common' from top

  local current_cursor_pos_mock = { 1, 0 } -- {line, col}
  local set_cursor_calls = {}
  local update_highlight_calls = {}

  local success, err_msg

  success, err_msg = pcall(function()
    -- Apply mocks
    vim.api.nvim_win_is_valid = function(winid)
      return winid == state.win
    end
    vim.api.nvim_win_get_cursor = function(winid)
      if winid == state.win then
        return vim.deepcopy(current_cursor_pos_mock)
      end
      return { 0, 0 }
    end
    vim.api.nvim_win_set_cursor = function(winid, new_pos_arr)
      if winid == state.win then
        table.insert(set_cursor_calls, vim.deepcopy(new_pos_arr))
      end
    end
    common.update_current_highlight = function(s, o, line_nr)
      -- Basic check, can be more specific if needed
      table.insert(update_highlight_calls, line_nr)
    end

    -- Initial state for user_navigated
    state.user_navigated = false

    -- Test moving down
    current_cursor_pos_mock = { 1, 0 }
    set_cursor_calls = {} 
    update_highlight_calls = {}
    on_move_spy.called_with = nil
    on_move_spy.call_count = 0
    
    local handled = state:handle_movement(1, opts)
    h.eq(handled, true, "Move down should be handled")
    h.eq(#set_cursor_calls, 1, "nvim_win_set_cursor call count for down move")
    h.eq(set_cursor_calls[1], { 2, 0 }, "Cursor should move to 2nd item")
    h.eq(#update_highlight_calls, 1, "update_current_highlight call count for down move")
    h.eq(update_highlight_calls[1], 1, "Highlight should be for line_nr 1 (0-indexed for item2)")
    h.eq(state.user_navigated, true, "user_navigated should be true after move")
    h.eq(on_move_spy.call_count, 1, "on_move call count for down move")
    h.eq(on_move_spy.called_with, items[2], "on_move callback for item2")

    -- Test moving up from middle
    current_cursor_pos_mock = { 2, 0 }
    set_cursor_calls = {}
    update_highlight_calls = {}
    on_move_spy.called_with = nil
    on_move_spy.call_count = 0
    state.user_navigated = false -- Reset for this specific action

    handled = state:handle_movement(-1, opts)
    h.eq(handled, true, "Move up should be handled")
    h.eq(#set_cursor_calls, 1, "nvim_win_set_cursor call count for up move")
    h.eq(set_cursor_calls[1], { 1, 0 }, "Cursor should move to 1st item")
    h.eq(#update_highlight_calls, 1, "update_current_highlight call count for up move")
    h.eq(update_highlight_calls[1], 0, "Highlight should be for line_nr 0 (0-indexed for item1)")
    h.eq(state.user_navigated, true)
    h.eq(on_move_spy.call_count, 1, "on_move call count for up move")
    h.eq(on_move_spy.called_with, items[1], "on_move callback for item1")

    -- Test wrapping around (moving down from last item)
    current_cursor_pos_mock = { 3, 0 } -- Last item
    set_cursor_calls = {}
    update_highlight_calls = {}
    on_move_spy.called_with = nil
    on_move_spy.call_count = 0

    handled = state:handle_movement(1, opts)
    h.eq(handled, true, "Wrap down should be handled")
    h.eq(#set_cursor_calls, 1)
    h.eq(set_cursor_calls[1], { 1, 0 }, "Cursor should wrap to 1st item")
    h.eq(#update_highlight_calls, 1)
    h.eq(update_highlight_calls[1], 0) 
    h.eq(on_move_spy.call_count, 1)
    h.eq(on_move_spy.called_with, items[1], "on_move callback for item1 on wrap down")

    -- Test wrapping around (moving up from first item)
    current_cursor_pos_mock = { 1, 0 } -- First item
    set_cursor_calls = {}
    update_highlight_calls = {}
    on_move_spy.called_with = nil
    on_move_spy.call_count = 0

    handled = state:handle_movement(-1, opts)
    h.eq(handled, true, "Wrap up should be handled")
    h.eq(#set_cursor_calls, 1)
    h.eq(set_cursor_calls[1], { 3, 0 }, "Cursor should wrap to 3rd item")
    h.eq(#update_highlight_calls, 1)
    h.eq(update_highlight_calls[1], 2) 
    h.eq(on_move_spy.call_count, 1)
    h.eq(on_move_spy.called_with, items[3], "on_move callback for item3 on wrap up")

  end)

  -- Restore original functions
  vim.api.nvim_win_is_valid = orig_nvim_win_is_valid
  vim.api.nvim_win_get_cursor = orig_nvim_win_get_cursor
  vim.api.nvim_win_set_cursor = orig_nvim_win_set_cursor
  common.update_current_highlight = orig_common_update_highlight

  if not success then
    error(err_msg)
  end
end

T["StateManager"]["handles multiselect correctly"] = function()
  local items = { 
    { text = "item1", id = "id1" }, 
    { text = "item2", id = "id2" }, 
    { text = "item3", id = "id3" },
  }
  -- Initial opts for enabled multiselect without max_items limit
  local opts = { 
    multiselect = { enabled = true, max_items = nil } 
  }
  local state = StateManager.new(items, opts)

  local orig_common_update_highlights = common.update_selection_highlights
  local update_highlights_spy = { call_count = 0 }

  local success, err_msg

  success, err_msg = pcall(function()
    common.update_selection_highlights = function(s, o)
      -- Basic spy: just count calls. Could be more specific if needed.
      if s == state then -- Check if the state matches, opts might change for different scenarios
        update_highlights_spy.call_count = update_highlights_spy.call_count + 1
      end
    end

    -- Scenario 1: Test toggling selection on
    update_highlights_spy.call_count = 0 -- Reset spy
    local changed = state:toggle_selection(items[1], opts)
    h.eq(changed, true, "Toggle on item1: changed should be true")
    h.eq(state.selected["id1"], true, "Toggle on item1: item1 should be selected")
    h.eq(state.selected_count, 1, "Toggle on item1: selected_count should be 1")
    local selected_items = state:get_selected_items()
    h.eq(#selected_items, 1, "Toggle on item1: #get_selected_items should be 1")
    h.eq(selected_items[1].id, "id1", "Toggle on item1: get_selected_items should return item1")
    h.eq(update_highlights_spy.call_count, 1, "Toggle on item1: update_selection_highlights should be called")

    -- Scenario 2: Test toggling another item on
    update_highlights_spy.call_count = 0
    changed = state:toggle_selection(items[2], opts)
    h.eq(changed, true, "Toggle on item2: changed should be true")
    h.eq(state.selected["id2"], true, "Toggle on item2: item2 should be selected")
    h.eq(state.selected_count, 2, "Toggle on item2: selected_count should be 2")
    selected_items = state:get_selected_items()
    h.eq(#selected_items, 2, "Toggle on item2: #get_selected_items should be 2")
    local found_item1_s2 = false
    local found_item2_s2 = false
    for _, item in ipairs(selected_items) do
      if item.id == "id1" then found_item1_s2 = true end
      if item.id == "id2" then found_item2_s2 = true end
    end
    h.eq(found_item1_s2 and found_item2_s2, true, "Toggle on item2: get_selected_items should contain item1 and item2")
    h.eq(update_highlights_spy.call_count, 1, "Toggle on item2: update_selection_highlights should be called")

    -- Scenario 3: Test toggling selection off
    update_highlights_spy.call_count = 0
    changed = state:toggle_selection(items[1], opts) -- Toggle item1 off
    h.eq(changed, true, "Toggle off item1: changed should be true")
    h.eq(state.selected["id1"], nil, "Toggle off item1: item1 should not be selected")
    h.eq(state.selected_count, 1, "Toggle off item1: selected_count should be 1")
    selected_items = state:get_selected_items()
    h.eq(#selected_items, 1, "Toggle off item1: #get_selected_items should be 1")
    h.eq(selected_items[1].id, "id2", "Toggle off item1: get_selected_items should return item2")
    h.eq(update_highlights_spy.call_count, 1, "Toggle off item1: update_selection_highlights should be called")

    -- Scenario 4: Test max_items limit
    opts.multiselect.max_items = 1
    state.selected = {} 
    state.selected_count = 0
    update_highlights_spy.call_count = 0

    changed = state:toggle_selection(items[1], opts) -- Select item1
    h.eq(changed, true, "Max items (1) test: toggle on item1 changed should be true")
    h.eq(state.selected_count, 1, "Max items (1) test: selected_count should be 1 after item1")
    h.eq(update_highlights_spy.call_count, 1, "Max items (1) test: update_selection_highlights for item1")
    
    local changed_limit = state:toggle_selection(items[2], opts) -- Try to select item2
    h.eq(changed_limit, false, "Max items (1) test: toggle on item2 changed_limit should be false")
    h.eq(state.selected_count, 1, "Max items (1) test: selected_count should remain 1")
    h.eq(state.selected["id2"], nil, "Max items (1) test: item2 should not be selected")
    -- update_selection_highlights should not be called if no change in selection state (as per current StateManager impl)
    h.eq(update_highlights_spy.call_count, 1, "Max items (1) test: update_selection_highlights not called for item2")

    -- Scenario 5: Test with multiselect disabled
    opts.multiselect.enabled = false
    opts.multiselect.max_items = nil -- Reset max_items
    state.selected = {} 
    state.selected_count = 0
    update_highlights_spy.call_count = 0

    local changed_disabled = state:toggle_selection(items[1], opts)
    h.eq(changed_disabled, false, "Disabled test: changed_disabled should be false")
    h.eq(state.selected_count, 0, "Disabled test: selected_count should be 0")
    h.eq(update_highlights_spy.call_count, 0, "Disabled test: update_selection_highlights should not be called")

  end)

  -- Restore original functions
  common.update_selection_highlights = orig_common_update_highlights

  if not success then
    error(err_msg)
  end
end

T["StateManager"]["handles multiselect correctly"] = function()
  local items = { 
    { text = "item1", id = "id1" }, 
    { text = "item2", id = "id2" }, 
    { text = "item3", id = "id3" },
  }
  local opts = { 
    multiselect = { enabled = true, max_items = nil } 
  }
  local state = StateManager.new(items, opts)

  local orig_common_update_highlights = common.update_selection_highlights
  local update_highlights_spy = { call_count = 0 }

  local success, err_msg

  success, err_msg = pcall(function()
    common.update_selection_highlights = function(s, o)
      if s == state and o == opts then
        update_highlights_spy.call_count = update_highlights_spy.call_count + 1
      end
    end

    -- Test toggling selection on
    update_highlights_spy.call_count = 0
    local changed = state:toggle_selection(items[1], opts)
    h.eq(changed, true, "Toggle on item1: changed should be true")
    h.eq(state.selected["id1"], true, "Toggle on item1: item1 should be selected")
    h.eq(state.selected_count, 1, "Toggle on item1: selected_count should be 1")
    local selected_items = state:get_selected_items()
    h.eq(#selected_items, 1, "Toggle on item1: #get_selected_items should be 1")
    h.eq(selected_items[1], items[1], "Toggle on item1: get_selected_items should return item1")
    h.eq(update_highlights_spy.call_count, 1, "Toggle on item1: update_selection_highlights should be called")

    -- Test toggling another item on
    update_highlights_spy.call_count = 0
    changed = state:toggle_selection(items[2], opts)
    h.eq(changed, true, "Toggle on item2: changed should be true")
    h.eq(state.selected["id2"], true, "Toggle on item2: item2 should be selected")
    h.eq(state.selected_count, 2, "Toggle on item2: selected_count should be 2")
    selected_items = state:get_selected_items()
    h.eq(#selected_items, 2, "Toggle on item2: #get_selected_items should be 2")
    -- Check contents (order might vary, so check for presence)
    local found_item1 = false
    local found_item2 = false
    for _, item in ipairs(selected_items) do
      if item.id == "id1" then found_item1 = true end
      if item.id == "id2" then found_item2 = true end
    end
    h.eq(found_item1 and found_item2, true, "Toggle on item2: get_selected_items should contain item1 and item2")
    h.eq(update_highlights_spy.call_count, 1, "Toggle on item2: update_selection_highlights should be called")

    -- Test toggling selection off
    update_highlights_spy.call_count = 0
    changed = state:toggle_selection(items[1], opts)
    h.eq(changed, true, "Toggle off item1: changed should be true")
    h.eq(state.selected["id1"], nil, "Toggle off item1: item1 should not be selected")
    h.eq(state.selected_count, 1, "Toggle off item1: selected_count should be 1")
    selected_items = state:get_selected_items()
    h.eq(#selected_items, 1, "Toggle off item1: #get_selected_items should be 1")
    h.eq(selected_items[1], items[2], "Toggle off item1: get_selected_items should return item2")
    h.eq(update_highlights_spy.call_count, 1, "Toggle off item1: update_selection_highlights should be called")

    -- Test max_items limit
    opts.multiselect.max_items = 1
    state.selected = {} -- Reset selection
    state.selected_count = 0
    update_highlights_spy.call_count = 0

    changed = state:toggle_selection(items[1], opts)
    h.eq(changed, true, "Max items test: toggle on item1 changed should be true")
    h.eq(state.selected_count, 1, "Max items test: selected_count should be 1 after item1")
    h.eq(update_highlights_spy.call_count, 1, "Max items test: update_selection_highlights for item1")
    
    local changed_limit = state:toggle_selection(items[2], opts)
    h.eq(changed_limit, false, "Max items test: toggle on item2 changed_limit should be false")
    h.eq(state.selected_count, 1, "Max items test: selected_count should remain 1")
    -- update_selection_highlights should not be called if no change in selection state
    h.eq(update_highlights_spy.call_count, 1, "Max items test: update_selection_highlights not called for item2")


    -- Test with multiselect disabled
    opts.multiselect.enabled = false
    opts.multiselect.max_items = nil -- Reset max_items
    state.selected = {} -- Reset selection
    state.selected_count = 0
    update_highlights_spy.call_count = 0

    local changed_disabled = state:toggle_selection(items[1], opts)
    h.eq(changed_disabled, false, "Disabled test: changed_disabled should be false")
    h.eq(state.selected_count, 0, "Disabled test: selected_count should be 0")
    h.eq(update_highlights_spy.call_count, 0, "Disabled test: update_selection_highlights should not be called")

  end)

  -- Restore original functions
  common.update_selection_highlights = orig_common_update_highlights

  if not success then
    error(err_msg)
  end
end

T["StateManager"]["handles movement correctly"] = function()
  local items = { { text = "item1" }, { text = "item2" }, { text = "item3" } }
  local on_move_spy = { called_with = nil, call_count = 0 }
  local opts = {
    on_move = function(item)
      on_move_spy.called_with = item
      on_move_spy.call_count = on_move_spy.call_count + 1
    end,
    current_highlight = { enabled = true, prefix_icon = ">" } -- Expected by common.update_current_highlight
  }
  local state = StateManager.new(items, opts)
  state.filtered_items = items -- All items are part of the filtered list for this test
  state.win = 1 -- Mock window ID

  -- Store original functions
  local orig_nvim_win_is_valid = vim.api.nvim_win_is_valid
  local orig_nvim_win_get_cursor = vim.api.nvim_win_get_cursor
  local orig_nvim_win_set_cursor = vim.api.nvim_win_set_cursor
  local orig_common_update_highlight = common.update_current_highlight

  local current_cursor_pos_mock = { 1, 0 } -- {line, col}, 1-based line for nvim_win_get_cursor
  local set_cursor_calls = {}
  local update_highlight_calls = {}

  local success, err_msg

  success, err_msg = pcall(function()
    -- Apply mocks
    vim.api.nvim_win_is_valid = function(winid)
      return winid == state.win
    end
    vim.api.nvim_win_get_cursor = function(winid)
      if winid == state.win then
        return vim.deepcopy(current_cursor_pos_mock)
      end
      return {0,0} 
    end
    vim.api.nvim_win_set_cursor = function(winid, new_pos_arr)
      if winid == state.win then
        table.insert(set_cursor_calls, vim.deepcopy(new_pos_arr))
      end
    end
    common.update_current_highlight = function(s, o, line_nr) -- line_nr is 0-indexed here
      table.insert(update_highlight_calls, line_nr)
    end

    -- Initial state for user_navigated
    state.user_navigated = false

    -- Test moving down (j)
    current_cursor_pos_mock = { 1, 0 }
    set_cursor_calls = {} 
    update_highlight_calls = {}
    on_move_spy.called_with = nil
    on_move_spy.call_count = 0
    
    local handled = state:handle_movement(1, opts) -- 1 for down
    h.eq(handled, true, "Move down: should be handled")
    h.eq(#set_cursor_calls, 1, "Move down: nvim_win_set_cursor call count")
    h.eq(set_cursor_calls[1], { 2, 0 }, "Move down: cursor should move to 2nd item")
    h.eq(#update_highlight_calls, 1, "Move down: update_current_highlight call count")
    h.eq(update_highlight_calls[1], 1, "Move down: highlight line_nr 1 (0-indexed for item2)")
    h.eq(state.user_navigated, true, "Move down: user_navigated should be true")
    h.eq(on_move_spy.call_count, 1, "Move down: on_move call count")
    h.eq(on_move_spy.called_with, items[2], "Move down: on_move callback for item2")

    -- Test moving up from middle (k)
    current_cursor_pos_mock = { 2, 0 }
    set_cursor_calls = {}
    update_highlight_calls = {}
    on_move_spy.called_with = nil
    on_move_spy.call_count = 0
    state.user_navigated = false 

    handled = state:handle_movement(-1, opts) -- -1 for up
    h.eq(handled, true, "Move up: should be handled")
    h.eq(#set_cursor_calls, 1, "Move up: nvim_win_set_cursor call count")
    h.eq(set_cursor_calls[1], { 1, 0 }, "Move up: cursor should move to 1st item")
    h.eq(#update_highlight_calls, 1, "Move up: update_current_highlight call count")
    h.eq(update_highlight_calls[1], 0, "Move up: highlight line_nr 0 (0-indexed for item1)")
    h.eq(state.user_navigated, true, "Move up: user_navigated should be true")
    h.eq(on_move_spy.call_count, 1, "Move up: on_move call count")
    h.eq(on_move_spy.called_with, items[1], "Move up: on_move callback for item1")

    -- Test wrapping around (moving down from last item)
    current_cursor_pos_mock = { #items, 0 } -- Cursor on last item
    set_cursor_calls = {}
    update_highlight_calls = {}
    on_move_spy.called_with = nil
    on_move_spy.call_count = 0
    
    handled = state:handle_movement(1, opts)
    h.eq(handled, true, "Wrap down: should be handled")
    h.eq(#set_cursor_calls, 1, "Wrap down: nvim_win_set_cursor call count")
    h.eq(set_cursor_calls[1], { 1, 0 }, "Wrap down: cursor should wrap to 1st item")
    h.eq(#update_highlight_calls, 1, "Wrap down: update_current_highlight call count")
    h.eq(update_highlight_calls[1], 0, "Wrap down: highlight line_nr 0") 
    h.eq(on_move_spy.call_count, 1, "Wrap down: on_move call count")
    h.eq(on_move_spy.called_with, items[1], "Wrap down: on_move callback for item1")

    -- Test wrapping around (moving up from first item)
    current_cursor_pos_mock = { 1, 0 } -- Cursor on first item
    set_cursor_calls = {}
    update_highlight_calls = {}
    on_move_spy.called_with = nil
    on_move_spy.call_count = 0

    handled = state:handle_movement(-1, opts)
    h.eq(handled, true, "Wrap up: should be handled")
    h.eq(#set_cursor_calls, 1, "Wrap up: nvim_win_set_cursor call count")
    h.eq(set_cursor_calls[1], { #items, 0 }, "Wrap up: cursor should wrap to last item")
    h.eq(#update_highlight_calls, 1, "Wrap up: update_current_highlight call count")
    h.eq(update_highlight_calls[1], #items - 1, "Wrap up: highlight line_nr for last item") 
    h.eq(on_move_spy.call_count, 1, "Wrap up: on_move call count")
    h.eq(on_move_spy.called_with, items[#items], "Wrap up: on_move callback for last item")

  end)

  -- Restore original functions
  vim.api.nvim_win_is_valid = orig_nvim_win_is_valid
  vim.api.nvim_win_get_cursor = orig_nvim_win_get_cursor
  vim.api.nvim_win_set_cursor = orig_nvim_win_set_cursor
  common.update_current_highlight = orig_common_update_highlight

  if not success then
    error(err_msg)
  end
end

return T
