# Configuration

This document explains the configurable options for **Namu.nvim**.

### Basic Setup

To configure `namu.nvim`, modify the `require("namu").setup({ namu = { options = { ... } } })` in your Neovim configuration.

## Display
Controls how symbols are shown in the picker.

```lua
display = {
  mode = "text", -- "icon" or "text" (prefix displayed as icons or text)
  padding = 2, -- Padding around displayed symbols
}
```

## Preview
Determines whether symbols are highlighted while navigating.

```lua
preview = {
  highlight_on_move = true, -- Highlight symbols as you move
  -- the below one is not working correctly
  highlight_mode = "always", -- "always" | "select" (only highlight when selecting)
}
```

## Row Position
Defines the general window placement preset.

```lua
row_position = "top10", -- Options:
-- "center": Centered on screen
-- "top10": 10% from top
-- "top10_right": 10% from top, aligned right
-- "center_right": Centered vertically, aligned right
-- "bottom": Aligned to bottom
```

## Right Position
Only applies when `row_position` is right-aligned.

```lua
right_position = {
  fixed = false, -- true for percentage-based, false for flexible width
  ratio = 0.7, -- Percentage of screen width where right-aligned windows start
}
```

## Initially Hidden
Start with an empty list that updates dynamically as you type (like VS Code/Zed command palette).

```lua
initially_hidden = false,
```

## Auto Select
If only one item remains after filtering, automatically select it.

```lua
auto_select = false,
```

## Preserve Order
Determines whether symbols maintain their original order after filtering.

```lua
preserve_order = false, -- If true, keeps symbols in their original order
```

---

### Symbol Filtering

#### `AllowKinds`
Defines which symbol types are allowed per file type.
```lua
AllowKinds = {
  default = { "Function", "Method", "Class", "Module", "Property", "Variable" },
  go = { "Function", "Method", "Struct", "Field", "Interface", "Constant", "Property" },
  lua = { "Function", "Method", "Table", "Module" },
  python = { "Function", "Class", "Method" },
  yaml = { "Object", "Array" },
  json = { "Module" },
  toml = { "Object" },
  markdown = { "String" },
}
```

#### `BlockList`
Symbols that should be excluded from search results.
```lua
BlockList = {
  lua = { "^vim%.", "%.%.%. :", ":gsub", "^callback$", "^filter$", "^map$" },
  python = { "^__" },
}
```

---

## Other Configurations

```lua
kindText = {
  Function = "function",
  Method = "method",
  Class = "class",
  Module = "module",
  Constructor = "constructor",
},

kindIcons = {
  File = "󰈙", Module = "󰏗", Class = "󰌗", Method = "󰆧",
},

icon = "󱠦",
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
    PrefixSymbol = "NamuPrefixSymbol",
    Function = "NamuSymbolFunction",
  },
},

window = {
  auto_size = true,
  min_width = 30,
  padding = 4,
  border = "rounded",
  show_footer = true,
  footer_pos = "right",
},

debug = false,
focus_current_symbol = true,

multiselect = {
  enabled = true,
  indicator = "●",
  keymaps = {
    toggle = "<Tab>",
    untoggle = "<S-Tab>",
    select_all = "<C-a>",
    clear_all = "<C-l>",
  },
},

actions = {
  close_on_yank = false,
  close_on_delete = true,
},

keymaps = {
  {
    key = "<C-y>",
    handler = function(items_or_item, state)
      local success = M.yank_symbol_text(items_or_item, state)
      if success and M.config.actions.close_on_yank then
        M.clear_preview_highlight()
        return false
      end
    end,
    desc = "Yank symbol text",
  },
},
```


This should cover all the main configuration options for `namu.nvim`. Let me know if you need changes! 🚀
