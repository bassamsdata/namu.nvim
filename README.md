# Namu.nvim

🌿 Jump to symbols in your code with live preview, built-in fuzzy finding, and other modules.
Inspired by Zed, it preserves symbol order while guiding you through your codebase.

“Namu” means “tree🌳” in Korean—just like how it helps you navigate the structure of your code.

> [!WARNING]
> 🚧 **Beta Status**: This plugin is currently in beta. While it's functional, you may encounter breaking changes as we improve and refine the architecture. Your feedback and contributions are welcome!

https://github.com/user-attachments/assets/a28a43d9-a477-4b92-89f3-c40479c7801b





## What Makes It Special

- 🔍 **Live Preview**: See exactly where you'll land before you jump
- 🌳 **Order Preservation**: Maintains symbol order as they appear in your code, even after filtering
- 📐 **Smart Auto-resize**: Window adapts to your content in real-time as you type and filter, no need for a big window with only a couple of items
- 🚀 **Zero Dependencies**: Works with any LSP-supported language out of the box
- 🎯 **Context Aware**: Always shows your current location in the codebase
- 🌑 **Initially Hidden Mode**: Start with an empty list and populate it dynamically as you type, just like the command palette in Zed and VS Code
- ⚡ **Powerful Filtering**:
  - Built-in fuzzy finding that understands code structure
  - Filter by symbol types (functions, classes, methods)
  - Use regex patterns (e.g., `^__` to filter out Python's `__init__` methods)
- 🎨 **Quality of Life**:
  - Auto-select when only one match remains
  - Remembers cursor position when you cancel
  - Customizable window style and behavior
- ✂️  **Multi-Action Workflow**: Perform multiple operations while Namu is open (or close it after, you choose!):
  - Delete, yank, and add to CodeCompanion chat (more plugins coming soon)
  - Works with both single and multiple selected symbols

## 🧩 Other Built-in Modules

Namu is powered by Selecta, a minimal and flexible fuzzy finder that's also used by:
- 🎨 **Colorscheme Picker**: Live preview with your code and switch themes with persistence
- 🔄 **vim.ui.select**: Enhanced wrapper for Vim's built-in selector
- 📦 More modules coming soon, including buffers and diagnostics!

## ⚡ Requirements
- Neovim >= 0.10.0
- Configured LSP server for your language (Treesitter fallback coming soon)
- Treesitter (for live preview functionality)

## Installation

### Lazy.nvim

Using [lazy.nvim](https://github.com/folke/lazy.nvim):
```lua
{
  "bassamsdata/namu.nvim",
  config = function()
    require("namu").setup({
      -- Enable the modules you want
      namu_symbols = {
        enable = true,
        options = {}, -- here you can configure namu
      },
      -- Optional: Enable other modules if needed
      colorscheme = {
        enable = false,
        options = {
          -- NOTE: if you activate persist, then please remove any vim.cmd("colorscheme ...") in your config, no needed anymore
          persist = true, -- very efficient mechanism to Remember selected colorscheme
          write_shada = false, -- If you open multiple nvim instances, then probably you need to enable this
        },
      },
      ui_select = { enable = false }, -- vim.ui.select() wrapper
    })
    -- === Suggested Keymaps: ===
    local namu = require("namu.namu_symbols")
    local colorscheme = require("namu.colorscheme")
    vim.keymap.set("n", "<leader>ss", namu.show, {
      desc = "Jump to LSP symbol",
      silent = true,
    })
    vim.keymap.set("n", "<leader>th", colorscheme.show, {
      desc = "Colorscheme Picker",
      silent = true,
    })
  end,
}
```

<details>
  <summary>📦 Paq.nvim</summary>

  ```lua
  require "paq" {
    "bassamsdata/namu.nvim"
  }
  ```

</details>

<details>
  <summary>📦 Mini.deps</summary>

  ```lua
  require("mini.deps").add("bassamsdata/namu.nvim")
  ```

</details>

### Default Keymaps

<details>
  <summary>default keymps are:</summary>
 **Navigation Keymaps**
───────────────────
 `<CR>`    Select item
 `<Esc>`   Close picker
 `<C-n>`   Next item
 `<Down>`  Next item
 `<C-p>`   Previous item
 `<Up>`    Previous item
 `q `      Close help

 **Multiselect**
───────────────
`<Tab>`   toggle
`<C-a>`   select_all
`<C-l>`   clear_all
`<S-Tab>` untoggle

 **Custom Actions**
───────────────
`<C-y>`   Yank symbol/ or concatenate selected symbols and yank
`<C-d>`   Delete symbol/ or concatenate selected symbols and delete
`<C-v>`   open symbol buffer on vertical split
`<C-o>`  add symbol/ or concatenate selected symbols and add them to codecompanion chat buffer.


</details>

## Make It Yours

You can check the [configuration documentation](https://github.com/bassamsdata/namu.nvim/tree/main/docs/Namu_config.md) for details on each option.
<details>
  <summary>Here's the full setup with defaults:</summary>

```lua
M.config = {
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
    lua = { "Function", "Method", "Table", "Module" },
    python = { "Function", "Class", "Method" },
    -- Filetype specific
    yaml = { "Object", "Array" },
    json = { "Module" },
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
    mode = "text", -- "icon" or "raw"
    padding = 2,
  },
  kindText = {
    Function = "function",
    Method = "method",
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
    Variable = "󰀫",
    Constant = "󰏿",
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
  preview = {
    highlight_on_move = true, -- Whether to highlight symbols as you move through them
    -- TODO: still needs implmenting, keep it always now
    highlight_mode = "always", -- "always" | "select" (only highlight when selecting)
  },
  icon = "󱠦", -- 󱠦 -  -  -- 󰚟
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
  window = {
    auto_size = true,
    min_width = 30,
    padding = 4,
    border = "rounded",
    show_footer = true,
    footer_pos = "right",
  },
  debug = false, -- Debug flag for both namu and selecta
  focus_current_symbol = true, -- Add this option to control the feature
  auto_select = false,
  row_position = "top10", -- options: "center"|"top10",
  initially_hidden = false,
  multiselect = {
    enabled = true,
    indicator = "●", -- or "✓"
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
  },
  keymaps = {
    {
      key = "<C-y>",
      handler = function(items_or_item, state)
        local success = M.yank_symbol_text(items_or_item, state)
        -- Only close if yanking was successful and config says to close
        if success and M.config.actions.close_on_yank then
          M.clear_preview_highlight()
          return false -- This should close the picker
        end
      end,
      desc = "Yank symbol text",
    },
    {
      key = "<C-d>",
      handler = function(items_or_item, state)
        local deleted = M.delete_symbol_text(items_or_item, state)
        -- Only close if deletion was successful and config says to close
        if deleted and M.config.actions.close_on_delete then
          M.clear_preview_highlight()
          return false
        end
      end,
      desc = "Delete symbol text",
    },
    {
      key = "<C-v>",
      handler = function(item, state)
        if not state.original_buf then
          vim.notify("No original buffer available", vim.log.levels.ERROR)
          return
        end

        local new_win = selecta.open_in_split(state, item, "vertical")
        if new_win then
          local symbol = item.value
          if symbol and symbol.lnum and symbol.col then
            -- Set cursor to symbol position
            pcall(vim.api.nvim_win_set_cursor, new_win, { symbol.lnum, symbol.col - 1 })
            vim.cmd("normal! zz")
          end
          M.clear_preview_highlight()
          return false
        end
      end,
      desc = "Open in vertical split",
    },
    {
      key = "<C-o>",
      handler = function(items_or_item)
        if type(items_or_item) == "table" and items_or_item[1] then
          M.add_symbol_to_codecompanion(items_or_item, state.original_buf)
        else
          -- Single item case
          M.add_symbol_to_codecompanion({ items_or_item }, state.original_buf)
        end
      end,
      desc = "Add symbol to CodeCompanion",
    },
    {
      key = "<C-t>",
      handler = function(items_or_item)
        if type(items_or_item) == "table" and items_or_item[1] then
          M.add_symbol_to_avante(items_or_item, state.original_buf)
        else
          -- Single item case
          M.add_symbol_to_avante({ items_or_item }, state.original_buf)
        end
      end,
      desc = "Add symbol to Avante",
    },
  },
}
```

</details>


## Tips

- Type to filter symbols - it's fuzzy, so no need to be exact, though it prioritizes exact words first
- Use regex patterns for precise filtering (e.g., `^test_` for test functions)
- Press `<CR>` to jump, `<Esc>` to cancel

## Feature Demos

<details>
  <summary>🌳 Order Preservation</summary>
Maintains symbol order as they appear in your code, even after filtering


https://github.com/user-attachments/assets/2f84f1b0-3fb7-4d69-81ea-8ec70acb5b80


</details>

<details>
  <summary>🌑 Initially Hidden Mode</summary>
Start with an empty list and populate it dynamically as you type, just like the command palette in Zed and VS Code


https://github.com/user-attachments/assets/e279b785-5fcf-4c2c-8cb5-b0467d850dd0


</details>

<details>
  <summary>🔍 Live Preview & Context Aware</summary>
focus on the current location in the codebase when open so you know where you are in the code

https://github.com/user-attachments/assets/292a94f3-264a-4ffa-9203-407bd101e35c


</details>

<details>
  <summary>⚡ Auto-select</summary>
if only one match remains, automatically select it. In the video I didn't press enter, yet the jump was done automatically.

https://github.com/user-attachments/assets/a8768aae-e190-4707-989a-0ee909380a5d


</details>

## Contributing

I made this plugin for fun at first and didn't know I could replicate what Zed has, and to be independent and free from any pickers.
Pull requests are welcome! Just please be kind and respectful.
Any suggestions to improve and integrate with other plugins are also welcome.

## Credits & Acknowledgements

- [Zed](https://zed.dev) editor for the idea.
- [Mini.pick](https://github.com/echasnovski/mini.nvim) @echasnovski for the idea of `getchar()`, without which this plugin wouldn't exist.
- Magnet module (couldn’t find it anymore on GitHub, sorry!), which intrigued me a lot.
- @folke for handling multiple versions of Neovim LSP requests in [Snacks.nvim](https://github.com/folke/snacks.nvim).
- tests structure, thanks to @Oli [CodeCompanion](https://github.com/olimorris/codecompanion.nvim)
- A simple mechanism to persist the colorscheme, thanks to this [Reddit comment](https://www.reddit.com/r/neovim/comments/1edwhk8/comment/lfb1m2f/?utm_source=share&utm_medium=web3x&utm_name=web3xcss&utm_term=1&utm_content=share_button).
