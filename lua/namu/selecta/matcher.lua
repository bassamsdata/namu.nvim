local M = {}
local logger = require("namu.utils.logger")

-- Scoring constants
local MATCH_SCORES = {
  prefix = 100, -- word starts with the exact query
  contains = 60, -- Contains the exact query somewhere in a word
  fuzzy = 25, -- Fuzzy match
}

local SCORE_ADJUSTMENTS = {
  gap_penalty = -3, -- Penalty for each gap in fuzzy match
  consecutive_bonus = 7, -- Bonus for consecutive matches
  start_bonus = 9, -- Bonus for matching at word start
  word_boundary_bonus = 20, -- Bonus for matching at word boundaries
  position_weight = 0.5, -- 0.5 points per position closer to start
  length_weight = 1.5, -- 1.5 points per character shorter
  max_gap_penalty = -20, -- Cap on total gap penalty
  exact_match_bonus = 25, -- bonus for exact substring matches
}

-- Input validation functions
---@param text string
---@param query string
---@return boolean, string?
local function validate_input(text, query)
  if type(text) ~= "string" then
    return false, "text must be a string"
  end
  if type(query) ~= "string" then
    return false, "query must be a string"
  end
  if #text == 0 then
    return false, "text cannot be empty"
  end
  if #query == 0 then
    return false, "query cannot be empty"
  end
  return true
end

--- Fuzzy matches query characters in text with scoring
---@param text string
---@param query string
---@param has_uppercase boolean
---@return number[][]|nil positions, number score, number gaps
function M.find_fuzzy_match(text, query, has_uppercase)
  -- Validate input
  local is_valid, error_msg = validate_input(text, query)
  if not is_valid then
    logger.log("Fuzzy match error: " .. error_msg)
    return nil, 0, 0
  end

  -- Initialize variables
  local positions = {}
  local last_match_pos = nil
  local current_range = nil
  local score = MATCH_SCORES.fuzzy
  local gaps = 0
  local consecutive_matches = 0 -- Track consecutive matches

  local text_pos = 1
  local query_pos = 1

  while query_pos <= #query and text_pos <= #text do
    -- Add early exit if remaining text < remaining query
    if (#text - text_pos) < (#query - query_pos) then
      break
    end
    local query_char = has_uppercase and query:sub(query_pos, query_pos) or query:lower():sub(query_pos, query_pos)
    local text_char = has_uppercase and text:sub(text_pos, text_pos) or text:lower():sub(text_pos, text_pos)

    if text_char == query_char then
      -- If this is consecutive with last match
      if last_match_pos and text_pos == last_match_pos + 1 then
        consecutive_matches = consecutive_matches + 1
        -- Cap consecutive bonus to prevent over-scoring
        if consecutive_matches <= 3 then
          score = score + SCORE_ADJUSTMENTS.consecutive_bonus
        end
        if current_range then
          current_range[2] = text_pos
        else
          current_range = { text_pos, text_pos }
        end
      else
        if last_match_pos then
          local gap_size = text_pos - last_match_pos - 1
          gaps = gaps + gap_size
          -- Apply penalty with diminishing effect for larger gaps
          local gap_penalty = math.max(SCORE_ADJUSTMENTS.max_gap_penalty, SCORE_ADJUSTMENTS.gap_penalty * gap_size)
          score = score + gap_penalty
          if current_range then
            table.insert(positions, current_range)
          end
        end
        current_range = { text_pos, text_pos }
        consecutive_matches = 1
      end

      -- Bonus for matching at word boundary
      if text_pos == 1 or text:sub(text_pos - 1, text_pos - 1):match("[^%w]") then
        score = score + SCORE_ADJUSTMENTS.start_bonus
      end

      last_match_pos = text_pos
      query_pos = query_pos + 1
    end
    text_pos = text_pos + 1
  end

  -- Add final range if exists
  if current_range then
    table.insert(positions, current_range)
  end

  -- Return nil if we didn't match all characters
  if query_pos <= #query then
    return nil, 0, 0
  end

  return positions, score, gaps
end

local function is_word_boundary(text, pos)
  -- Start of string is always a boundary
  if pos == 1 then
    return true
  end

  local prev_char = text:sub(pos - 1, pos - 1)
  local curr_char = text:sub(pos, pos)

  -- Check for traditional word boundaries (spaces, underscores, etc.)
  if prev_char:match("[^%w]") ~= nil or prev_char == "_" then
    return true
  end

  -- Check for camelCase and PascalCase boundaries
  -- Current char is uppercase and previous char is lowercase
  if curr_char:match("[A-Z]") and prev_char:match("[a-z]") then
    return true
  end

  return false
end

---@param text string The text to search in
---@param query string The query to search for
---@return MatchResult|nil
function M.get_match_positions(text, query)
  -- Work with raw text, no formatting adjustments here
  if query == "" then
    return nil
  end
  -- Smart-case: check if query has any uppercase
  local has_uppercase = query:match("[A-Z]") ~= nil

  local lower_text, lower_query
  if not has_uppercase then
    lower_text = text:lower()
    lower_query = query:lower()
  end

  -- Prefix match
  local is_prefix = true
  for i = 1, #query do
    local tc = has_uppercase and text:sub(i, i) or lower_text:sub(i, i)
    local qc = has_uppercase and query:sub(i, i) or lower_query:sub(i, i)
    if tc ~= qc then
      is_prefix = false
      break
    end
  end

  -- Calculate position and length bonuses
  local position_bonus = SCORE_ADJUSTMENTS.position_weight * 100 -- For prefix, always position 1
  local length_bonus = (1 / math.max(#text, 1)) * SCORE_ADJUSTMENTS.length_weight * 100

  -- Check for prefix match
  if is_prefix then
    -- Base score calculation
    -- TEST: Testing this neo ones
    local score = MATCH_SCORES.prefix
      + SCORE_ADJUSTMENTS.exact_match_bonus
      + SCORE_ADJUSTMENTS.word_boundary_bonus
      + position_bonus
      + length_bonus
    -- Add special bonus for exact full-word matches
    if #query == #text then
      score = score + (SCORE_ADJUSTMENTS.exact_match_bonus * 2)
      -- Optional: Add additional length bonus for perfect matches
      score = score + (SCORE_ADJUSTMENTS.length_weight * 100)
    end
    return {
      positions = { { 1, #query } },
      -- TODO: this position bonus probably not needed, since pos = 1 is always
      score = score, -- MATCH_SCORES.prefix + position_bonus + length_bonus,
      type = "prefix",
      matched_chars = #query,
      gaps = 0,
    }
  end

  -- Enhanced substring match with word boundary detection
  local function find_best_substring_match()
    local best_start, best_score, curr_pos = nil, -1, 1
    while true do
      local start_idx
      if has_uppercase then
        start_idx = text:find(query, curr_pos, true) -- Case-sensitive
      else
        start_idx = lower_text:find(lower_query, curr_pos, true)
      end
      if not start_idx then
        break
      end
      -- Calculate score for this match position
      local curr_score = MATCH_SCORES.contains
      -- Add exact match bonus
      if #query > 1 then -- Only for queries longer than 1 char
        curr_score = curr_score + SCORE_ADJUSTMENTS.exact_match_bonus
      end

      -- Add word boundary bonus with improved detection
      if is_word_boundary(text, start_idx) then
        curr_score = curr_score + SCORE_ADJUSTMENTS.word_boundary_bonus
        -- Extra bonus if it matches at a word after a separator
        if start_idx > 1 and text:sub(start_idx - 1, start_idx - 1):match("[:/_%-%.]") then
          curr_score = curr_score + SCORE_ADJUSTMENTS.word_boundary_bonus * 0.5
        end
      end

      -- Position bonus relative to start
      curr_score = curr_score + (1 / start_idx) * SCORE_ADJUSTMENTS.position_weight * 100

      if curr_score > best_score then
        best_score = curr_score
        best_start = start_idx
      end

      curr_pos = start_idx + 1
    end

    return best_start, best_score
  end

  -- Find best substring match
  local start_idx, substring_score = find_best_substring_match()
  if start_idx then
    position_bonus = (1 / start_idx) * SCORE_ADJUSTMENTS.position_weight * 100 -- Recalculate for non-prefix position

    return {
      positions = { { start_idx, start_idx + #query - 1 } },
      score = substring_score + position_bonus + length_bonus,
      type = "contains",
      matched_chars = #query,
      gaps = 0,
    }
  end

  -- Fuzzy match
  local fuzzy_positions, fuzzy_score, fuzzy_gaps = M.find_fuzzy_match(text, query, has_uppercase)
  if fuzzy_positions then
    -- Get position of first match from fuzzy_positions
    local first_match_pos = fuzzy_positions[1][1]
    position_bonus = (1 / first_match_pos) * SCORE_ADJUSTMENTS.position_weight * 100
    length_bonus = (1 / #text) * SCORE_ADJUSTMENTS.length_weight * 100

    return {
      positions = fuzzy_positions,
      score = fuzzy_score + position_bonus + length_bonus,
      type = "fuzzy",
      matched_chars = #query,
      gaps = fuzzy_gaps,
    }
  end

  return nil
end

---sorter function
---@param items SelectaItem[]
---@param query string
---@param preserve_order boolean
function M.sort_items(items, query, preserve_order)
  -- Store match results for each item
  local item_matches = {}
  local best_score = -1
  local best_index = 1

  -- Get match results for all items
  for i, item in ipairs(items) do
    local match = M.get_match_positions(item.text, query)
    if match then
      -- Log detailed scoring information
      -- print(string.format("Item: %-30s Score: %d Type: %-8s Gaps: %d", item.text, match.score, match.type, match.gaps))
      table.insert(item_matches, {
        item = item,
        match = match,
        original_index = i,
      })

      -- Track best match for cursor positioning (only for preserve_order)
      if preserve_order and match.score > best_score then
        best_score = match.score
        best_index = #item_matches
      end
    end
  end

  if preserve_order then
    -- Sort only by original index
    table.sort(item_matches, function(a, b)
      return a.original_index < b.original_index
    end)
  else
    -- Sort based on match score and additional factors
    table.sort(item_matches, function(a, b)
      -- First compare by match type/score
      if a.match.score ~= b.match.score then
        return a.match.score > b.match.score
      end

      -- Then by number of gaps (fewer is better)
      if a.match.gaps ~= b.match.gaps then
        return a.match.gaps < b.match.gaps
      end

      -- Finally by text length (shorter is better)
      return #a.item.text < #b.item.text
    end)

    -- When not preserving order, best match is always first item
    best_index = 1
  end

  -- Extract sorted items
  local sorted_items = {}
  for _, match in ipairs(item_matches) do
    table.insert(sorted_items, match.item)
  end

  return sorted_items, best_index
end

M._test = {
  get_match_positions = M.get_match_positions,
  is_word_boundary = is_word_boundary,
  validate_input = validate_input,
}

return M
