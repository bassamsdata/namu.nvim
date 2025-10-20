local selecta = require("namu.selecta.selecta")
local config_manager = require("namu.core.config_manager")
local preview_utils = require("namu.core.preview_utils")
local utils = require("namu.core.utils")

local M = {}

local state = {
  original_win = nil,
  original_buf = nil,
  original_pos = nil,
}
M.config = {}
local config_resolved = false

local function resolve_config()
  if not config_resolved then
    local resolved_config = config_manager.get_config("ui_select")
    M.config = vim.tbl_deep_extend("force", M.config, resolved_config)
    config_resolved = true
  end
end

local function create_custom_formatter(opts)
  return function(item)
    local prefix_padding = ""
    if opts.current_highlight and opts.current_highlight.enabled and opts.current_highlight.prefix_icon then
      if #opts.current_highlight.prefix_icon > 0 then
        prefix_padding = string.rep(" ", vim.api.nvim_strwidth(opts.current_highlight.prefix_icon))
      end
    end
    local number_str = ""
    if opts.display.show_numbers then
      local number = item.original_index or 1
      number_str = string.format("%2d.", number)
    end
    local padding = opts.display.padding or 1
    return prefix_padding .. number_str .. item.text
  end
end

-- Enhanced cleanup function
local function cleanup_state()
  if state.preview_state then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_clear_namespace, bufnr, state.preview_state.preview_ns, 0, -1)
      end
    end
  end
end

-- Enhanced restore function
local function restore_original_state()
  if state.preview_state and state.original_win then
    preview_utils.restore_window_state(state.original_win, state.preview_state)
  end

  if state.original_win and state.original_pos then
    utils.restore_focus_and_cursor(state.original_win, state.original_pos)
  end

  cleanup_state()
end

-- Function to highlight various patterns in text content
local function apply_text_content_highlights(buf, ns_id, line_nr, start_offset, text)
  local patterns = {
    {
      pattern = "%b()",
      hl_group = "Comment",
    },
    {
      pattern = "%b[]",
      hl_group = "Comment",
    },
  }

  for _, pattern_info in ipairs(patterns) do
    local pattern = pattern_info.pattern
    local hl_group = pattern_info.hl_group

    local start_pos = 1
    while true do
      local match_start, match_end = text:find(pattern, start_pos)
      if not match_start then
        break
      end
      -- Calculate absolute positions in the buffer line
      local abs_start = start_offset + match_start - 1
      local abs_end = start_offset + match_end
      -- Apply highlighting with bounds checking
      if abs_start >= start_offset and abs_end <= start_offset + #text then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, line_nr, abs_start - 1, {
          end_col = abs_end,
          hl_group = hl_group,
          priority = 140,
        })
      end
      start_pos = match_end + 1
    end
  end
end

local function apply_ui_select_highlights(buf, filtered_items, opts)
  local ns_id = vim.api.nvim_create_namespace("namu_ui_select_highlights")
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
  for idx, item in ipairs(filtered_items) do
    local line_nr = idx - 1 -- 0-indexed for extmarks
    -- Calculate positions
    local prefix_padding_width = 0
    if opts.current_highlight and opts.current_highlight.enabled and opts.current_highlight.prefix_icon then
      if #opts.current_highlight.prefix_icon > 0 then
        prefix_padding_width = vim.api.nvim_strwidth(opts.current_highlight.prefix_icon)
      end
    end
    local number_width = 0
    if opts.display.show_numbers then
      local number = item.original_index or 1
      number_width = string.len(string.format("%2d.", number))
    end
    local padding_width = opts.display.padding or 0
    -- Highlight the number if present
    if opts.display.show_numbers and number_width > 0 then
      local number_start = prefix_padding_width
      local number_end = number_start + number_width - 1 -- -1 to exclude the space
      pcall(vim.api.nvim_buf_set_extmark, buf, ns_id, line_nr, number_start, {
        end_col = number_end,
        hl_group = "Number",
        priority = 150,
      })
    end
    -- Calculate text start position
    local text_start = prefix_padding_width + number_width + padding_width
    local text_content = item.text
    -- Apply different types of highlighting
    apply_text_content_highlights(buf, ns_id, line_nr, text_start, text_content)
  end
end

---@param items any[]
---@param opts SelectaOptions
---@param on_choice fun(item: any?, idx: number?)
function M.select(items, opts, on_choice)
  local win = vim.api.nvim_get_current_win()
  state = {
    original_win = win,
    original_buf = vim.api.nvim_get_current_buf(),
    original_pos = vim.api.nvim_win_get_cursor(win),
    preview_state = preview_utils.create_preview_state("ui_select"),
  }
  -- Save the original window state for preview
  preview_utils.save_window_state(state.original_win, state.preview_state)

  -- Convert items to SelectaItem format
  local selecta_items = {}
  for i, item in ipairs(items) do
    ---@diagnostic disable-next-line: undefined-field
    local formatted = (opts.format_item and opts.format_item(item)) or tostring(item)
    table.insert(selecta_items, {
      text = formatted,
      value = item,
      original_index = i, -- Store original index for callback
    })
  end

  -- Configure Selecta options
  local default_selecta_opts = {
    title = opts.prompt or M.config.title,
    auto_select = M.config.auto_select,
    window = M.config.window,
    display = M.config.display,
    movement = vim.tbl_deep_extend("force", M.config.movement, {}),
    current_highlight = M.config.current_highlight,
    row_position = M.config.row_position or "top10",
    formatter = create_custom_formatter(M.config),
    -- Custom offset function to account for numbering
    offset = function(item)
      local total_offset = 0
      if
        M.config.current_highlight
        and M.config.current_highlight.enabled
        and M.config.current_highlight.prefix_icon
      then
        if #M.config.current_highlight.prefix_icon > 0 then
          total_offset = total_offset + vim.api.nvim_strwidth(M.config.current_highlight.prefix_icon)
        end
      end
      if M.config.display.show_numbers then
        local number = item.original_index or 1
        total_offset = total_offset + string.len(string.format("%2d. ", number))
      end
      total_offset = total_offset + (M.config.display.padding or 1)
      return total_offset
    end,
    hooks = {
      on_render = function(buf, filtered_items)
        apply_ui_select_highlights(buf, filtered_items, M.config)
      end,
    },
    on_move = function(item)
      if item and item.value and opts.kind ~= "codeaction" then
        preview_utils.preview_symbol(item, state.original_win, state.preview_state, {
          highlight_group = "NamuPreview",
        })
      end
    end,
    on_select = function(selected)
      if selected then
        vim.schedule(function()
          on_choice(selected.value, selected.original_index)
        end)
        restore_original_state()
      else
        restore_original_state()
      end
    end,

    on_cancel = function()
      restore_original_state()
      on_choice(nil, nil)
    end,

    on_close = function()
      cleanup_state()
    end,
  }
  local selecta_opts = vim.tbl_deep_extend("force", default_selecta_opts, opts or {})

  -- Launch Selecta
  vim.schedule(function()
    selecta.pick(selecta_items, selecta_opts)
  end)
end

-- Replace the default vim.ui.select
function M.setup()
  resolve_config()
  vim.ui.select = M.select
end

return M
