local M = {}

---@class NamuCoreConfig
M.defaults = {
  AllowKinds = {
    default = {
      "Function",
      "Method",
      "Class",
      "Module",
      "Property",
      "Variable",
      -- "Constant",
      -- "Enum",
      -- "Interface",
      -- "Field",
      -- "Struct",
      -- "Array"
    },
    go = {
      "Function",
      "Method",
      "Struct", -- For struct definitions
      "Field", -- For struct fields
      "Interface",
      "Constant",
      -- "Variable",
      "Property",
      -- "TypeParameter", -- For type parameters if using generics
    },
    rust = {
      "Function",
      "Method",
      "Class",
      "Module",
      "Property",
      "Variable",
      "Interface", -- rust cosider traits as Interface
    },
    lua = { "Function", "Method", "Table", "Module" },
    python = { "Function", "Class", "Method" },
    -- Filetype specific
    yaml = { "Object", "Array" },
    toml = { "Object" },
    markdown = { "String" },
  },
  BlockList = {
    default = {},
    -- Filetype-specific
    lua = {
      "^vim%.", -- anonymous functions passed to nvim api
      "%.%.%. :", -- vim.iter functions
      ":gsub", -- lua string.gsub
      "^callback$", -- nvim autocmds
      "^filter$",
      "^map$", -- nvim keymaps
    },
    -- another example:
    -- python = { "^__" }, -- ignore __init__ functions
  },
  display = {
    mode = "icon", -- "icon" or "raw"
    padding = 2,
    style = 2, -- 1 or 2
    format = "indent", -- Options = "indent"|"tree_guides"
    indent_size = 2,
    tree_guides = { style = "unicode" }, -- Options = "ascii"|"unicode"
  },
  kindText = {
    Function = "function",
    Class = "class",
    Module = "module",
    Constructor = "constructor",
    Interface = "interface",
    Property = "property",
    Field = "field",
    Enum = "enum",
    Constant = "constant",
    Variable = "variable",
  },
  kindIcons = {
    File = "󰈙",
    Module = "󰏗",
    Namespace = "󰌗",
    Package = "󰏖",
    Class = "󰌗",
    Method = "󰆧",
    Property = "󰜢",
    Field = "󰜢",
    Constructor = "󰆧",
    Enum = "󰒻",
    Interface = "󰕘",
    Function = "󰊕",
    Variable = "",
    Constant = "",
    String = "󰀬",
    Number = "󰎠",
    Boolean = "󰨙",
    Array = "󰅪",
    Object = "󰅩",
    Key = "󰌋",
    Null = "󰟢",
    EnumMember = "󰒻",
    Struct = "󰌗",
    Event = "󰉁",
    Operator = "󰆕",
    TypeParameter = "󰊄",
  },
  hierarchical_mode = false,
  current_highlight = {
    enabled = true, -- Enable custom selection highlight
    hl_group = "NamuCurrentItem", -- Default highlight group (could also create a custom one)
    -- Please keep space after the icon for better viewing
    prefix_icon = " ", --icon for current selection, some other example ▎ 󰇙 ┆
  },
  preview = {
    highlight_on_move = true, -- Whether to highlight symbols as you move through them
    -- TODO: still needs implementing, keep it always now
    highlight_mode = "always", -- "always" | "select" (only highlight when selecting)
  },
  icon = "󱠦  ", -- 󱠦 -  -  -- 󰚟
  highlight = "NamuPreview",
  highlights = {
    parent = "NamuParent",
    nested = "NamuNested",
    style = "NamuStyle",
  },
  kinds = {
    prefix_kind_colors = true,
    enable_highlights = true,
    highlights = {
      -- TODO: change the highlights name to refer to highilgiht.lua
      PrefixSymbol = "NamuPrefixSymbol",
      Function = "NamuSymbolFunction",
      Method = "NamuSymbolMethod",
      Class = "NamuSymbolClass",
      Interface = "NamuSymbolInterface",
      Variable = "NamuSymbolVariable",
      Constant = "NamuSymbolConstant",
      Property = "NamuSymbolProperty",
      Field = "NamuSymbolField",
      Enum = "NamuSymbolEnum",
      Module = "NamuSymbolModule",
    },
  },
  -- This is a preset that let's set window without really get into the hassle of tuning window options
  -- top10 meaning top 10% of the window
  row_position = "top10", -- options: "center"|"top10"|"top10_right"|"center_right"|"bottom", --
  window = {
    auto_size = true,
    min_height = 1,
    min_width = 20,
    max_width = 120,
    max_height = 41,
    padding = 2,
    -- this is borrored from @mini.nvim, thanks :), it's for >= 0.11
    border = (vim.fn.exists("+winborder") == 1 and vim.o.winborder ~= "") and vim.o.winborder or "rounded",
    title_pos = "left",
    show_footer = true,
    footer_pos = "right",
    relative = "editor",
    style = "minimal",
    width_ratio = 0.6,
    height_ratio = 0.6,
    title_prefix = "󱠦 ",
  },
  debug = false,
  focus_current_symbol = true,
  auto_select = false,
  initially_hidden = false,
  multiselect = {
    enabled = true,
    indicator = "✓", -- or "✓"●
    keymaps = {
      toggle = "<Tab>",
      untoggle = "<S-Tab>",
      select_all = "<C-a>",
      clear_all = "<C-l>",
    },
    max_items = nil, -- No limit by default
  },
  actions = {
    close_on_yank = false, -- Whether to close picker after yanking
    close_on_delete = true, -- Whether to close picker after deleting
    close_on_quickfix = false,
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
  filter_symbol_types = {
    -- Functions
    fn = {
      kinds = { "Function", "Constructor" },
      description = "Functions, methods and constructors",
    },
    -- Methods:
    me = {
      kinds = { "Method", "Accessor" },
      description = "Methods",
    },
    -- Variables
    va = {
      kinds = { "Variable", "Parameter", "TypeParameter" },
      description = "Variables and parameters",
    },
    -- Classes
    cl = {
      kinds = { "Class", "Interface", "Struct" },
      description = "Classes, interfaces and structures",
    },
    -- Constants
    co = {
      kinds = { "Constant", "Boolean", "Number", "String" },
      description = "Constants and literal values",
    },
    -- Fields
    fi = {
      kinds = { "Field", "Property", "EnumMember" },
      description = "Object fields and properties",
    },
    -- Modules
    mo = {
      kinds = { "Module", "Package", "Namespace" },
      description = "Modules and packages",
    },
    -- Arrays
    ar = {
      kinds = { "Array", "List", "Sequence" },
      description = "Arrays, lists and sequences",
    },
    -- Objects
    ob = {
      kinds = { "Object", "Class", "Instance" },
      description = "Objects and class instances",
    },
  },
  custom_keymaps = {
    yank = {
      keys = { "<C-y>" },
      handler = nil, -- Will be initialized in the module
      desc = "Yank symbol text",
    },
    delete = {
      keys = { "<C-d>" },
      handler = nil, -- Will be initialized in the module
      desc = "Delete symbol text",
    },
    vertical_split = {
      keys = { "<C-v>" },
      handler = nil, -- Will be initialized in the module
      desc = "Open in vertical split",
    },
    horizontal_split = {
      keys = { "<C-h>" },
      handler = nil, -- Will be initialized in the module
      desc = "Open in horizontal split",
    },
    codecompanion = {
      keys = "<C-o>",
      handler = nil, -- Will be initialized in the module
      desc = "Add symbol to CodeCompanion",
    },
    avante = {
      keys = "<C-t>",
      handler = nil, -- Will be initialized in the module
      desc = "Add symbol to Avante",
    },
    quickfix = {
      keys = { "<C-q>" }, -- or whatever keymap you prefer
      handler = nil,
      description = "Add to quickfix",
    },
  },
}

-- The actual config that will be used
M.values = vim.deepcopy(M.defaults)

-- Setup function to configure the module
function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", M.values, opts or {})
end

-- Get the complete config or a specific section
function M.get(section)
  if section then
    return M.values[section]
  end
  return M.values
end

return M
