# Namu.nvim

🌿 Jump to symbols in your code with live preview, built-in fuzzy finding, and more.
Inspired by Zed, it preserves symbol order while guiding you through your codebase.
Supports LSP, Treesitter, ctags, and works across buffers and workspaces.


> [!WARNING]
> 🚧 **Beta**: This plugin is in beta. Breaking changes may occur.



https://github.com/user-attachments/assets/a97ff3b1-8b25-4da1-b276-f623e37d0368



## 🧩 Built-in Modules

| Module         | Description                                      |
|----------------|--------------------------------------------------|
| 🏷️ symbols        | LSP symbols for current buffer                      |
| 🌐 workspace      | LSP workspace symbols, interactive, live preview    |
| 📂 watchtower    | Symbols from all open buffers (LSP or Treesitter)   |
| 🩺 diagnostics    | Diagnostics for buffer or full workspace, live filter    |
| 🔗 call_hierarchy | Call hierarchy (in/out/both) for symbol             |
| 🏷️ ctags          | ctags-based symbols (buffer or watchtower)         |
| 🪟 ui_select      | Wrapper for `vim.ui.select` with enhanced UI        |


## What Makes It Special

- 🔍 **Live Preview**: See exactly where you'll land before you jump
- 🌳 **Order Preservation**: Maintains symbol order as they appear in your code, even after filtering
- 🗂️ **Hierarchy Preservation**: Keeps the parent-child structure of your code symbols intact, so you always see context.
- 📐 **Smart Auto-resize**: Window adapts to your content in real-time as you type and filter, no need for a big window with only a couple of items
- 🚀 **Zero Dependencies**: Works with any LSP-supported language out of the box
- 🎯 **Context Aware**: Always shows your current location in the codebase
- ⚡ **Powerful Filtering**:
  - Live filtering through `/xx` such as `/fn` for fcuntions or `/bf:` for buffer names if watchtower module.
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
- 🌑 **Initially Hidden Mode**: Start with an empty list and populate it dynamically as you type, just like the command palette in Zed and VS Code

## Table of Contents

- [Requirements](#-requirements)
- [Installation](#installation)
- [Features](#features)
- [Keymaps](#keymaps)
- [Commands](#commands)
- [Make It Yours](#make-it-yours)
- [Tips](#tips)
- [Feature Demos](#feature-demos)
- [Display Styles](#display-styles)
- [Highlights](#highlights)
- [Contributing](#contributing)
- [Credits & Acknowledgements](#credits--acknowledgements)
- [Demo](#demo)

## ⚡ Requirements
- LSP server for your language (Treesitter fallback for some modules)
- Treesitter (for live preview)
- [ctags](https://ctags.io) (for ctags module, optional)

## Installation

### Lazy.nvim

Using [lazy.nvim](https://github.com/folke/lazy.nvim):
```lua
{
    "bassamsdata/namu.nvim",
    opts = {
        global = { },
        namu_symbols = { -- Specific Module options
            options = {},
        },
    },
    -- === Suggested Keymaps: ===
    vim.keymap.set("n", "<leader>ss", ":Namu symbols<cr>", {
        desc = "Jump to LSP symbol",
        silent = true,
    }),
    vim.keymap.set("n", "<leader>sw", ":Namu workspace<cr>", {
        desc = "LSP Symbols - Workspace",
        silent = true,
    })
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


## Features

- Live kind filtering for all symbol modules (`/fn`, `/me`, etc.) and then start type like `/fnmain` to filter more [see demo](#feature-demos)
- Filter by buffer name in watchtower: `/bf:buffer_name` [see demo](#feature-demos)
- Combine filters: `/bf:name:fn` (buffer and function) [see demo](#feature-demos)
- Diagnostics filtering: `/er` (errors), `/wa` (warnings), `/hi` (hints), `/in` (info) [see demo](#feature-demos)
- Two display styles: `tree_guides` or `indent` [see pictures](## Display Styles)
- Configurable prefix icon for current item
- All operations are asynchronous (non-blocking)
- No dependencies except Neovim, LSP, and optional ctags
-  Hierarchy Preservation: Keeps the parent-child structure of your code symbols intact, so you always see context.



## Keymaps

<details>
<summary>Show keymaps</summary>

| Key         | Action                                 |
|-------------|----------------------------------------|
| `<CR>`      | Select item                            |
| `<Esc>`     | Close picker                           |
| `<C-n>`     | Next item                              |
| `<C-p>`     | Previous item                          |
| `<Tab>`     | Toggle multiselect                     |
| `<C-a>`     | Select all                             |
| `<C-l>`     | Clear all                              |
| `<C-y>`     | Yank symbol(s)                         |
| `<C-d>`     | Delete symbol(s)                       |
| `<C-v>`     | Open symbol in vertical split          |
| `<C-h>`     | Open symbol in horizontal split        |
| `<C-o>`     | Add symbol(s) to CodeCompanion chat    |

</details>

### Change Keymaps:

<details>
<summary>change the default keymaps:</summary>

```lua
-- in namu_symbols.options
  movement = {
    next = { "<C-n>", "<DOWN>" }, -- Support multiple keys
    previous = { "<C-p>", "<UP>" }, -- Support multiple keys
    close = { "<ESC>" }, -- close mapping
    select = { "<CR>" }, -- select mapping
    delete_word = {}, -- delete word mapping
    clear_line = {}, -- clear line mapping
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
  custom_keymaps = {
    yank = {
      keys = { "<C-y>" }, -- yank symbol text
    },
    delete = {
      keys = { "<C-d>" }, -- delete symbol text
    },
    vertical_split = {
      keys = { "<C-v>" }, -- open in vertical split
    },
    horizontal_split = {
      keys = { "<C-h>" }, -- open in horizontal split
    },
    codecompanion = {
      keys = "<C-o>", -- Add symbols to CodeCompanion
    },
    avante = {
      keys = "<C-t>", -- Add symbol to Avante
    },
  },
```

</details>

## Commands

| Command                | Arguments         | Description                                 |
|------------------------|------------------|---------------------------------------------|
| `:Namu symbols`    | function, class, method… | Show buffer symbols, filter by kind         |
| `:Namu workspace` | | Search workspace symbols                    |
| `:Namu watchtower`      |                  | Symbols from all open buffers, it fallbacks to treesitter               |
| `:Namu diagnostics`  | buffers, workspace        | Diagnostics for buffer or workspace (not only open buffers)         |
| `:Namu call in/out/both` | in/out/both      | Call hierarchy for symbol                   |
| `:Namu ctags [watchtower]`   | watchtower           | ctags symbols (buffer or watchtower)       |
| `:Namu help [topic]`     | symbols/analysis | Show help                                   |

## Make It Yours

You can check the [configuration documentation](https://github.com/bassamsdata/namu.nvim/tree/main/docs/Namu_config.md) for details on each option.
<details>
  <summary>Here's the full setup with defaults:</summary>

```lua
{ -- Those are the default options
  "bassamsdata/namu.nvim",
    opts = {
      -- Enable symbols navigator which is the default
      namu_symbols = {
        enable = true,
        ---@type NamuConfig
        options = {
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
            mode = "icon", -- "icon" or "raw"
            padding = 2,
          },
          -- This is a preset that let's set window without really get into the hassle of tuning window options
          -- top10 meaning top 10% of the window
          row_position = "top10", -- options: "center"|"top10"|"top10_right"|"center_right"|"bottom",
          preview = {
            highlight_on_move = true, -- Whether to highlight symbols as you move through them
            -- still needs implmenting, keep it always now
            highlight_mode = "always", -- "always" | "select" (only highlight when selecting)
          },
          window = {
            auto_size = true,
            min_height = 1,
            min_width = 20,
            max_width = 120,
            max_height = 30,
            padding = 2,
            border = "rounded",
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
          },
          movement = {-- Support multiple keys
            next = { "<C-n>", "<DOWN>" },
            previous = { "<C-p>", "<UP>" },
            close = { "<ESC>" }, -- "<C-c>" can be added as well
            select = { "<CR>" },
            delete_word = {}, -- it can assign "<C-w>"
            clear_line = {}, -- it can be "<C-u>"
          },
          custom_keymaps = {
            yank = {
              keys = { "<C-y>" },
              desc = "Yank symbol text",
            },
            delete = {
              keys = { "<C-d>" },
              desc = "Delete symbol text",
            },
            vertical_split = {
              keys = { "<C-v>" },
              desc = "Open in vertical split",
            },
            horizontal_split = {
              keys = { "<C-h>" },
              desc = "Open in horizontal split",
            },
            codecompanion = {
              keys = "<C-o>",
              desc = "Add symbol to CodeCompanion",
            },
            avante = {
              keys = "<C-t>",
              desc = "Add symbol to Avante",
            },
          },
          icon = "󱠦", -- 󱠦 -  -  -- 󰚟
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
        }
      }
      ui_select = { enable = false }, -- vim.ui.select() wrapper
    }
  end,
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
<summary>symbols</summary>

- Shows LSP symbols for current buffer.
- Filter by kind: `:Namu symbols function`
- Live kind filtering: `/fn` for fucntion , `/me` for methods, etc.
- Live preview as you move.



https://github.com/user-attachments/assets/bb2a14da-cba0-4ae7-b826-4ceb1c828b79



</details>


<details>
<summary>workspace</summary>

- Interactive workspace symbol search (LSP).
- Start typing to see results, live preview.



https://github.com/user-attachments/assets/e548c3ea-6cdb-4f20-9569-175c57b31039



</details>


<details>
<summary>watchtower</summary>

- Shows symbols from all open buffers (LSP or Treesitter fallback).
- Filter by buffer: `/bf:buffer_name`
- Combine with kind: `/bf:name:fn`


https://github.com/user-attachments/assets/76c637d2-30d3-4f54-9290-510a51dcbe7e




</details>


<details>
<summary>diagnostics</summary>

- Shows diagnostics for buffer or workspace.
- Filter by severity: `/er`, `/wa`, `/hi`, `/in`
- Live preview and navigation.



https://github.com/user-attachments/assets/02dc0ce5-c87a-445f-a477-ac4f411c6592



</details>

<details>
<summary>call_hierarchy</summary>

- Show incoming, outgoing, or both calls for a symbol.
- Usage: `:Namu call in`, `:Namu call out`, `:Namu call both`

https://github.com/user-attachments/assets/5d30214a-a5d8-46e3-89d4-be71203501e7

</details>

<details>
<summary>ctags</summary>

- Show ctags-based symbols for buffer or watchtower.
- Requires ctags installed.
- Usage: `:Namu ctags`, `:Namu ctags watchtower`


https://github.com/user-attachments/assets/09ccc178-c067-45bb-8f86-3f8aa183e69d



</details>

## Display Styles

<details>
<summary>Show display style examples</summary>

- `options.display.format = "tree_guides"`:
![tree_guides](https://github.com/user-attachments/assets/5be3180c-87b8-4a06-9cd1-e65e5fe08b81)


- `options.display.format = "indent"`:
![indent](https://github.com/user-attachments/assets/8d78aa5d-27d9-4331-9898-01d18e3bd23a)


</details>

## Highlights

<details>
<summary>Show highlight groups</summary>

| Group                | Description                                 |
|----------------------|---------------------------------------------|
| NamuPrefix           | Prefix highlight                            |
| NamuMatch            | Matched characters in search                |
| NamuFilter           | Filter prompt                               |
| NamuPrompt           | Prompt window                               |
| NamuSelected         | Selected item in multiselect                |
| NamuFooter           | Footer text                                 |
| NamuCurrentItem      | Current item highlight                      |
| NamuPrefixSymbol     | Symbol prefix                               |
| **LSP KINDS HIGHLIGHTS** | -----------------|
| NamuSymbolFunction   | Function symbol                             |
| NamuSymbolMethod     | Method symbol                               |
| NamuSymbolClass      | Class symbol                                |
| NamuSymbolInterface  | Interface symbol                            |
| NamuSymbolVariable   | Variable symbol                             |
| NamuSymbolConstant   | Constant symbol                             |
| NamuSymbolProperty   | Property symbol                             |
| NamuSymbolField      | Field symbol                                |
| NamuSymbolEnum       | Enum symbol                                 |
| NamuSymbolModule     | Module symbol                               |
| **Some Other Styles**    | --------------------|
| NamuTreeGuides       | Tree guide lines                            |
| NamuFileInfo         | File info text                              |
| NamuPreview          | Preview window highlight                    |
| NamuParent           | Parent item highlight                       |
| NamuNested           | Nested item highlight                       |
| NamuStyle            | Style elements highlight                    |
| NamuCursor           | Cursor highlight during Picker active

</details>

## Contributing

I made this plugin for fun at first and didn't know I could replicate what Zed has, and to be independent and free from any pickers.
Pull requests are welcome! Just please be kind and respectful.
Any suggestions to improve and integrate with other plugins are also welcome.

# Naming:

“Namu” means “tree🌳” in Korean, just like how it helps you navigate the structure of your code.

## Credits & Acknowledgements

- [Zed](https://zed.dev) editor for the idea.
- [Mini.pick](https://github.com/echasnovski/mini.nvim) @echasnovski for the idea of `getchar()`, without which this plugin wouldn't exist.
- Magnet module (couldn’t find it anymore on GitHub, sorry!), which intrigued me a lot.
- @folke for handling multiple versions of Neovim LSP requests and treesitter "locals" in [Snacks.nvim](https://github.com/folke/snacks.nvim).
- tests and ci structure and vimdocs, thanks to @Oli [CodeCompanion](https://github.com/olimorris/codecompanion.nvim)
- A simple mechanism to persist the colorscheme, thanks to this [Reddit comment](https://www.reddit.com/r/neovim/comments/1edwhk8/comment/lfb1m2f/?utm_source=share&utm_medium=web3x&utm_name=web3xcss&utm_term=1&utm_content=share_button).
- [Aerial.nvim](https://github.com/stevearc/aerial.nvim) and @Stevearc for borroing some treesitter queries.
