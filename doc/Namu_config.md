# Configuration

This document explains the configurable options for **Namu.nvim**.

### Basic Setup

To configure `namu.nvim`, modify the `require("namu").setup({ namu = { options = { ... } } })` in your Neovim configuration.

```lua
require("namu").setup({
  namu_symbols = {
    enable = true,
    options = {
      -- symbol navigation options
    }
  },
  ui_select = {
    enable = true,
    options = {
      -- ui select options
    }
  },
  colorscheme = {
    enable = true,
    options = {
      persist = true,      -- Remember selected colorscheme
      write_shada = false, -- For multiple nvim instances
    }
  }
})
```

## Feature Toggles
Most features can be enabled/disabled:

```lua
options = {
  preview = {
    enable = true,              -- Enable/disable preview
    highlight_on_move = true,   -- Highlight while moving
  },
  auto_select = true,          -- Auto-jump on single match
  initially_hidden = false,    -- Start with empty list
  multiselect = {
    enabled = true,           -- Enable multi-selection
  },
  preserve_order = true,      -- Keep symbol order while filtering
}
```

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

## Auto Jump
If only one item remains after filtering, automatically select it.

```lua
auto_select = false,
```

## Jump Labels
Leap-style one-key jumping: place a label character on every visible row,
press the label to jump to that row and select it in one keystroke.

Off by default; enable globally to bind the toggle key (`;`) on every
selecta-based picker:

```lua
require("namu").setup({
  global = {
    jump = { enabled = true },
  },
})
```

Press the toggle key (default `;`) in any picker to enter label mode; press
again or `<Esc>` to exit. Label keystroke selects the labelled row, fires
`on_select`, and closes the picker. While labels are showing the prompt
buffer is locked so the filter can't change underfoot. Multiselect (`Tab`)
is intentionally inert during jump mode — labels are always single-select;
your prior `Tab` selections are preserved for when you toggle out.

### Auto-activate (per-module)

Some pickers benefit from entering jump mode immediately so single-key
picks land in one stroke (code actions, buffer picker, spell suggestions):

```lua
require("namu").setup({
  global    = { jump = { enabled = true } },
  ui_select = {
    enable  = true,
    options = {
      jump = {
        auto_activate = true,
        -- Suppress auto-activate for specific vim.ui.select kinds.
        skip_kinds = { confirmation = true },
      },
    },
  },
})
```

`auto_activate` also accepts a number: auto-activate only when the picker
opens with that many items or fewer. This is ideal for pickers whose lists
are usually short — small list, labels pop up; big list, you filter first
and toggle with `;` when ready:

```lua
require("namu").setup({
  global = {
    jump = {
      enabled       = true,
      auto_activate = 10, -- ≤ 10 items? drop straight into label mode
    },
  },
})
```

`true` still means "always", `false` (default) "never", and `0` effectively
disables auto-activation. The `min_items` floor still applies: activation
needs `min_items ≤ items ≤ auto_activate` when both are set.

### Per-call override

`vim.tbl_deep_extend` means callers can override any field on a single call
without knowing the rest of the config:

```lua
vim.ui.select(items, {
  prompt = "Confirm:",
  jump   = { auto_activate = false }, -- this one picker won't auto-jump
}, on_choice)
```

### Full config surface

```lua
jump = {
  enabled       = false, -- master opt-in; everything below is dead unless true
  toggle_key    = ";",   -- key that enters/exits jump mode
  auto_activate = false, -- enter jump on open: true always, number N = only when <= N items
  keys          = "asdfghjklqwertyuiopzxcvbnmASDFGHJKLQWERTYUIOPZXCVBNM",
  hl_group      = "NamuJumpLabel", -- highlight group used for the labels
  priority      = 300,             -- extmark priority for the labels
  min_items     = 0,               -- skip jump if fewer visible items than this
  skip_kinds    = {},              -- table<vim.ui.select kind, true> to skip auto_activate
},
```
### Recipe: differentiated setup

A real-world setup rarely wants the same behaviour everywhere. Because
`global` propagates to every picker and per-module settings win over it, you
can mix toggle-only pickers with auto-jumping ones in a single `setup()`:

```lua
require("namu").setup({
  -- Jump on everywhere; bind the toggle key on every picker.
  global = {
    jump = {
      enabled    = true,
      toggle_key = ";",
      -- Home-row-first labels. NEVER include the toggle_key in `keys` — a
      -- label keymap would shadow the binding that exits jump mode.
      keys       = "asdfghjklqwertyuiopzxcvbnm",
      min_items  = 3, -- 1–2 visible rows? just press <CR>, skip labelling.
    },
  },

  -- Symbol pickers inherit the global config above: toggle-only. You
  -- typically type to filter first, then press `;` once the target is on
  -- screen — so auto_activate stays off here.

  -- vim.ui.select (LSP code actions, etc.): drop straight into label mode so
  -- a single keystroke picks.
  ui_select = {
    enable  = true,
    options = {
      jump = {
        auto_activate = true,
        min_items     = 2, -- a lone code action is still taken with <CR>.
        -- Suppress auto_activate for specific vim.ui.select kinds — e.g. a
        -- destructive picker where you'd rather read before a key lands.
        skip_kinds    = { codeaction = true },
      },
    },
  },
})

-- Make the labels pop (NamuJumpLabel links to "Special" by default).
vim.api.nvim_set_hl(0, "NamuJumpLabel", { fg = "#ff966c", bold = true })
```

`skip_kinds` only gates `auto_activate`: a skipped kind still enters jump
mode the moment you press the toggle key — it just won't do so on its own.

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
