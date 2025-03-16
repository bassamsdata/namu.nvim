local M = {}
-- Allowed keys for validation
local allowed_keys = {
  -- stylua: ignore start 
  window = {
    "relative", "border", "style", "title_prefix", "width_ratio", "height_ratio",
    "auto_size", "min_width", "max_width", "padding", "max_height", "min_height",
    "auto_resize", "title_pos", "show_footer", "footer_pos", "override"
  },
  display = {
    "mode", "padding", "style", "format", "indent_size", "tree_guides",
    "icon_after_prefix_symbol", "prefix_width"
  },
  multiselect = {
    "enabled", "indicator", "keymaps", "max_items"
  },
  hooks = {
    "on_render", "before_render", "on_window_create", "on_buffer_clear"
  },
  current_highlight = {
    "enabled", "hl_group", "prefix_icon"
  },
  preview = {
    "highlight_on_move", "highlight_mode"
  },
  kinds = {
    "prefix_kind_colors", "enable_highlights", "highlights"
  },
  actions = {
    "close_on_yank", "close_on_delete"
  },
  movement = {
    "next", "previous", "close", "select", "delete_word", "clear_line"
  },
  custom_keymaps = {
    "yank", "delete", "vertical_split", "horizontal_split",
    "codecompanion", "avante"
  },
  root = {
    "window", "display", "offset", "debug", "preserve_order", "keymaps",
    "auto_select", "row_position", "AllowKinds", "BlockList", "multiselect",
    "title", "filter", "kindText", "kindIcons", "preview", "icon", "highlight",
    "highlights", "kinds", "focus_current_symbol", "initially_hidden", "actions",
    "movement", "custom_keymaps", "fuzzy", "offnet", "initial_index", "formatter",
    "on_move", "hooks", "current_highlight", "preserve_hierarchy"
  }
,
  -- stylua: ignore end
}

local function validate_highlight_group(group)
  return vim.fn.hlID(group) > 0
end

local function validate_icon(icon)
  return type(icon) == "string" and vim.api.nvim_strwidth(icon) > 0
end
--- Check for unknown keys
local function check_unknown_keys(user_opts, allowed_keys, section, issues)
  if type(user_opts) ~= "table" then
    return
  end

  for key in pairs(user_opts) do
    if not vim.tbl_contains(allowed_keys, key) then
      table.insert(issues, { level = "warn", msg = string.format("Unknown option '%s' in %s", key, section) })
    end
  end
end

local function is_valid_position(pos)
  if not pos then
    return true
  end

  -- Static positions
  local static_positions = {
    "center",
    "bottom",
    "center_right",
    "bottom_right",
  }

  if vim.tbl_contains(static_positions, pos) then
    return true
  end

  -- Check for topN or topN_right patterns
  local num = pos:match("^top(%d+)$") or pos:match("^top(%d+)_right$")
  if num then
    local n = tonumber(num)
    return n >= 5 and n <= 70
  end

  return false
end

function M.validate_picker_options(opts)
  local issues = {}

  if not opts then
    table.insert(issues, { level = "error", msg = "Options cannot be nil" })
    return false, issues
  end

  local function check(condition, msg, level)
    if not condition then
      table.insert(issues, { level = level or "error", msg = msg })
    end
  end
  -- Check unknown options at the root level
  check_unknown_keys(opts, allowed_keys.root, "root", issues)
  -- Validate nested tables and check unknown keys
  if opts.window then
    check(type(opts.window) == "table", "window must be a table", "error")
    check_unknown_keys(opts.window, allowed_keys.window, "window", issues)
  end
  -- Validate display options
  if opts.display then
    check(
      vim.tbl_contains({ "indent", "tree_guides" }, opts.display.format),
      "display.format must be either 'indent' or 'tree_guides'"
    )
    check(
      vim.tbl_contains({ "icon", "raw", "text" }, opts.display.mode),
      "display.mode must be either 'icon', 'raw' or 'text'",
      "error"
    )
    if opts.display.tree_guides then
      check(
        vim.tbl_contains({ "ascii", "unicode" }, opts.display.tree_guides.style),
        "tree_guides.style must be either 'ascii' or 'unicode'"
      )
    end
  end
  if opts.current_highlight then
    if opts.current_highlight.enabled then
      check(
        validate_highlight_group(opts.current_highlight.hl_group),
        "current_highlight.hl_group must be a valid highlight group"
      )
      check(validate_icon(opts.current_highlight.prefix_icon), "current_highlight.prefix_icon must be a valid icon")
    end
  end
  -- Validate preview options
  if opts.preview then
    check(type(opts.preview.highlight_on_move) == "boolean", "preview.highlight_on_move must be a boolean")
    check(
      vim.tbl_contains({ "always", "select" }, opts.preview.highlight_mode),
      "preview.highlight_mode must be either 'always' or 'select'"
    )
  end
  -- Validate kinds configuration
  if opts.kinds then
    check(type(opts.kinds.prefix_kind_colors) == "boolean", "kinds.prefix_kind_colors must be a boolean")
    if opts.kinds.highlights then
      for group_name, hl_group in pairs(opts.kinds.highlights) do
        check(
          validate_highlight_group(hl_group),
          string.format("Invalid highlight group '%s' for kind '%s'", hl_group, group_name)
        )
      end
    end
  end
  if opts.multiselect then
    check(type(opts.multiselect) == "table", "multiselect must be a table")
    check_unknown_keys(opts.multiselect, allowed_keys.multiselect, "multiselect", issues)
  end
  if opts.hooks then
    check(type(opts.hooks) == "table", "hooks must be a table")
    check_unknown_keys(opts.hooks, allowed_keys.hooks, "hooks", issues)
  end
  -- Check other options
  check(not opts.offset or type(opts.offset) == "number", "offset must be a number")
  check(not opts.debug or type(opts.debug) == "boolean", "debug must be a boolean")
  check(not opts.preserve_order or type(opts.preserve_order) == "boolean", "preserve_order must be a boolean")
  check(not opts.auto_select or type(opts.auto_select) == "boolean", "auto_select must be a boolean")
  check(
    is_valid_position(opts.row_position),
    "Invalid row_position: must be one of 'center', 'bottom', 'center_right', 'bottom_right', or 'topN'/'topN_right' where N is 5-70"
  )

  if opts.multiselect and opts.multiselect.keymaps then
    check(type(opts.multiselect.keymaps) == "table", "multiselect.keymaps must be a table")
  end

  -- Check options
  check(not opts.title or type(opts.title) == "string", "title must be a string")
  check(not opts.filter or type(opts.filter) == "function", "filter must be a function")
  check(not opts.fuzzy or type(opts.fuzzy) == "boolean", "fuzzy must be a boolean")
  check(not opts.offnet or type(opts.offnet) == "number", "offnet must be a number")
  check(not opts.initial_index or type(opts.initial_index) == "number", "initial_index must be a number")
  check(not opts.formatter or type(opts.formatter) == "function", "formatter must be a function")
  check(not opts.on_move or type(opts.on_move) == "function", "on_move must be a function")
  check(not opts.sorter or type(opts.sorter) == "function", "sorter must be a function")
  -- Validate callbacks
  for _, callback in ipairs({ "on_select", "on_cancel", "on_move" }) do
    check(not opts[callback] or type(opts[callback]) == "function", callback .. " must be a function")
  end

  -- Validate keymaps
  if opts.keymaps then
    check(type(opts.keymaps) == "table", "keymaps must be a table")
    for i, keymap in ipairs(opts.keymaps) do
      check(type(keymap) == "table", string.format("keymap %d must be a table", i))
      check(type(keymap.key) == "string", string.format("keymap %d key must be a string", i))
      check(type(keymap.handler) == "function", string.format("keymap %d handler must be a function", i))
    end
  end
  -- Validate custom_keymaps
  if opts.custom_keymaps then
    for name, keymap in pairs(opts.custom_keymaps) do
      check(
        type(keymap.keys) == "string" or type(keymap.keys) == "table",
        string.format("custom_keymaps.%s.keys must be a string or table", name)
      )
      check(
        keymap.desc == nil or type(keymap.desc) == "string",
        string.format("custom_keymaps.%s.desc must be a string if present", name)
      )
    end
  end

  return #issues == 0, issues
end

return M
