local M = {}

-- Global defaults that apply to all modules
M.global_defaults = {
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
  custom_keymaps = {
    yank = { keys = { "<C-y>" }, desc = "Yank symbol text" },
    delete = { keys = { "<C-d>" }, desc = "Delete symbol text" },
    vertical_split = { keys = { "<C-v>" }, desc = "Open in vertical split" },
    horizontal_split = { keys = { "<C-h>" }, desc = "Open in horizontal split" },
    codecompanion = { keys = "<C-o>", desc = "Add symbol to CodeCompanion" },
    avante = { keys = "<C-t>", desc = "Add symbol to Avante" },
    quickfix = { keys = { "<C-q>" }, desc = "Add to quickfix" },
    -- NOTE: handlers will be set by individual modules as needed
  },
  current_highlight = {
    enabled = true,
    hl_group = "NamuCurrentItem",
    prefix_icon = " ",
  },
  window = {
    auto_size = true,
    min_height = 1,
    min_width = 35,
    max_width = 120,
    max_height = 41,
    padding = 2,
    border = (vim.fn.exists("+winborder") == 1 and vim.o.winborder ~= "") and vim.o.winborder or "rounded",
    title_pos = "center",
    show_footer = true,
    footer_pos = "right",
    relative = "editor",
    style = "minimal",
    width_ratio = 0.6,
    height_ratio = 0.6,
  },
}

M.module_defaults = {
  namu_symbols = {
    -- Module-specific defaults that differ from global
    display = { mode = "icon", format = "indent" },
    hierarchical_mode = false,
    enhance_lua_test_symbols = true,
    lua_test_truncate_length = 50,
    lua_test_preserve_hierarchy = true,
    source_priority = "lsp", -- Options: "lsp", "treesitter"
  },
  diagnostics = {
    display = { mode = "icon", format = "tree_guides" },
    preserve_hierarchy = true,
    row_position = "top10",
    highlights = {
      Error = "DiagnosticVirtualTextError",
      Warn = "DiagnosticVirtualTextWarn",
      Info = "DiagnosticVirtualTextInfo",
      Hint = "DiagnosticVirtualTextHint",
    },
    icons = {
      Error = "",
      Warn = "󰀦",
      Info = "󰋼",
      Hint = "󰌶",
    },
    window = {
      title_prefix = "󰃣 ",
      min_width = 79,
      max_width = 100,
      max_height = 15,
      min_height = 1,
      padding = 2,
    },
    custom_keymaps = {
      code_action = {
        keys = { "<C-CR>", "<D-CR>" },
        desc = "Invoke code action",
      },
      codecompanion_inline = {
        keys = {}, -- FIX: needs some integration from the codecompanion to be robust
        desc = "Fix diagnostic with AI",
      },
    },
  },
  watchtower = {
    display = { format = "tree_guides" },
    preserve_hierarchy = true,
    enhance_lua_test_symbols = true,
    lua_test_truncate_length = 50,
    lua_test_preserve_hierarchy = true,
  },
  namu_ctags = {
    -- ctags uses global defaults
  },
  callhierarchy = {
    preserve_hierarchy = true,
    sort_by_nesting_depth = true,
    call_hierarchy = {
      max_depth = 2, -- Default max depth
      max_depth_limit = 4, -- Hard limit to prevent performance issues
      show_cycles = false, -- Whether to show recursive calls
    },
  },
  workspace = {
    window = {
      min_width = 50,
      max_width = 75,
    },
  },
  -- colorscheme = {},
  ui_select = {
    window = {
      title_prefix = "󰆤 ",
      min_height = 1,
      auto_size = true,
      min_width = 35,
      max_width = 120,
      max_height = 30,
      padding = 2,
      title_pos = "left",
      footer_pos = "right",
      relative = "editor",
      width_ratio = 0.6,
      height_ratio = 0.6,
    },
    display = {
      mode = "raw",
      padding = 0,
      show_numbers = true,
    },
  },
}

M.user_config = {}

function M.get_config(module_name)
  local config = vim.deepcopy(M.global_defaults)

  -- Apply module-specific defaults
  if M.module_defaults[module_name] then
    config = vim.tbl_deep_extend("force", config, M.module_defaults[module_name])
  end

  -- Apply user global overrides
  if M.user_config.global then
    config = vim.tbl_deep_extend("force", config, M.user_config.global)
  end

  -- BACKWARD COMPATIBILITY: Apply old-style module config (module.options.*)
  if M.user_config[module_name] and M.user_config[module_name].options then
    config = vim.tbl_deep_extend("force", config, M.user_config[module_name].options)
  end

  -- Apply new-style module-specific overrides (direct module settings)
  if M.user_config[module_name] then
    local module_config = vim.deepcopy(M.user_config[module_name])
    -- Remove non-config fields
    module_config.enable = nil
    module_config.options = nil
    if next(module_config) then -- Only apply if there are actual config values
      config = vim.tbl_deep_extend("force", config, module_config)
    end
  end

  return config
end

-- Helper function for debugging config resolution
function M.debug_config(module_name)
  print("=== Config Debug for " .. module_name .. " ===")
  print("Global defaults:", vim.inspect(M.global_defaults))
  print("Module defaults:", vim.inspect(M.module_defaults[module_name] or {}))
  print("User global:", vim.inspect(M.user_config.global or {}))
  print("User module:", vim.inspect(M.user_config[module_name] or {}))
  print("Final config:", vim.inspect(M.get_config(module_name)))
  print("========================================")
end

-- Setup function to store user configuration
function M.setup(user_opts)
  M.user_config = vim.deepcopy(user_opts or {})
end

return M
