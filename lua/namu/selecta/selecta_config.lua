local M = {}

-- Default configuration
M.defaults = {
  window = {
    relative = "editor",
    border = "none",
    style = "minimal",
    title_prefix = "> ",
    width_ratio = 0.6,
    height_ratio = 0.6,
    auto_size = true, -- Default to fixed size
    min_width = 20, -- Minimum width even when auto-sizing
    max_width = 120, -- Maximum width even when auto-sizing
    padding = 2, -- Extra padding for content
    max_height = 30, -- Maximum height
    min_height = 2, -- Minimum height
    auto_resize = true, -- Enable dynamic resizing
    title_pos = "left",
    show_footer = true, -- Enable/disable footer
    footer_pos = "right",
  },
  display = {
    mode = "icon",
    padding = 1,
  },
  current_highlight = {
    enabled = false, -- Enable custom selection highlight
    hl_group = "CursorLine", -- Default highlight group (could also create a custom one)
    prefix_icon = " ", --▎ ▎󰇙┆Vertical bar icon for current selection
  },
  offset = 0,
  debug = false,
  preserve_order = false, -- Default to false unless the other module handle it
  keymaps = {},
  auto_select = false,
  row_position = "top10", -- options: "center"|"top10",
  right_position = { -- only works when row_position is one of right aligned
    -- If set to false, it plays nicly with initially_hidden option is on
    fixed = false, -- true for percentage-based, false for flexible width-based
    ratio = 0.7, -- percentage of screen width where right-aligned windows start
  },
  movement = {
    next = { "<C-n>", "<DOWN>" }, -- Support multiple keys
    previous = { "<C-p>", "<UP>" }, -- Support multiple keys
    close = { "<ESC>" },
    select = { "<CR>" },
    delete_word = {},
    clear_line = {},
    -- Deprecated mappings (but still working)
    -- alternative_next = "<DOWN>", -- @deprecated: Will be removed in v1.0
    -- alternative_previous = "<UP>", -- @deprecated: Will be removed in v1.0
  },
  multiselect = {
    enabled = false,
    indicator = "●", -- or "✓"◉
    keymaps = {
      toggle = "<Tab>",
      select_all = "<C-a>",
      clear_all = "<C-l>",
      untoggle = "<S-Tab>",
    },
    max_items = nil, -- No limit by default
  },
  custom_keymaps = {},
  loading_indicator = {
    text = "Loading results...",
    icon = "󰇚",
  },
}

-- Active configuration (will be updated via setup)
M.values = vim.deepcopy(M.defaults)

-- Helper function to check if debug is enabled
function M.is_debug_enabled()
  return M.values.debug == true
end

return M
