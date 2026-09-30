-- Copy this table into require("namu").setup(...) or lazy.nvim's opts.
-- This covers the main settings; for all defaults see doc/Namu_config.md.
return {
  global = {
    display = { format = "tree_guides" },
    jump = {
      enabled = true,
      toggle_key = ";",
      auto_activate = false,
      keys = "asdfghjklqwertyuiopzxcvbnmASDFGHJKLQWERTYUIOPZXCVBNM",
      hl_group = "NamuJumpLabel",
      priority = 300,
      min_items = 0,
      skip_kinds = {},
    },
    movement = {
      next = { "<C-n>", "<DOWN>" },
      previous = { "<C-p>", "<UP>" },
      close = { "<ESC>" },
      select = { "<CR>" },
    },
    multiselect = {
      enabled = true,
      selected_icon = "● ",
      unselected_icon = "○ ",
      keymaps = {
        toggle = "<Tab>",
        untoggle = "<S-Tab>",
        select_all = "<C-a>",
        clear_all = "<C-l>",
      },
    },
    current_highlight = { enabled = true, prefix_icon = " " },
    window = {
      auto_size = true,
      min_height = 1,
      max_height = 41,
      min_width = 35,
      max_width = 120,
      padding = 2,
      -- Omit border to inherit Neovim's winborder (or rounded).
      title_pos = "center",
      show_footer = true,
      footer_pos = "right",
      relative = "editor",
      style = "minimal",
      width_ratio = 0.6,
      height_ratio = 0.6,
    },
  },
  namu_symbols = {
    enable = true,
    display = { mode = "icon", indent_size = 2, tree_guides = { style = "unicode" } },
    source_priority = "lsp",
    focus_current_symbol = true,
    auto_select = false,
    row_position = "top10",
    preview = { highlight_on_move = true },
    actions = { close_on_yank = false, close_on_delete = true, close_on_quickfix = false },
    -- AllowKinds, BlockList, and kindIcons can be overridden here.
  },
  workspace = { enable = true, window = { min_width = 50, max_width = 75 } },
  watchtower = { enable = true, preserve_hierarchy = true },
  diagnostics = {
    enable = true,
    preserve_hierarchy = true,
    window = { min_width = 79, max_width = 100, max_height = 15 },
  },
  callhierarchy = {
    enable = true,
    preserve_hierarchy = true,
    call_hierarchy = { max_depth = 2, max_depth_limit = 4, show_cycles = false },
  },
  namu_ctags = { enable = false },
  colorscheme = { enable = false },
  ui_select = { enable = false },
}
