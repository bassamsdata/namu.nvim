# Namu.nvim

🌿 Jump to symbols in your code with live preview, built-in fuzzy finding, and other modules.
Inspired by Zed, it preserves symbol order while guiding you through your codebase.
Supports LSP, Treesitter, ctags, and works across buffers and workspaces.

“Namu” means “tree🌳” in Korean—just like how it helps you navigate the structure of your code.

> [!WARNING]
> 🚧 **Beta Status**: This plugin is currently in beta. While it's functional, you may encounter breaking changes as we improve and refine the architecture. Your feedback and contributions are welcome!

https://github.com/user-attachments/assets/a28a43d9-a477-4b92-89f3-c40479c7801b

## 🧩 Built-in Modules

| Module         | Description                                      |
|----------------|--------------------------------------------------|
| 🏷️ symbols        | LSP symbols for current buffer                      |
| 🌐 workspace      | LSP workspace symbols, interactive, live preview    |
| 📂 all_buffers    | Symbols from all open buffers (LSP or Treesitter)   |
| 🩺 diagnostics    | Diagnostics for buffer or workspace, live filter    |
| 🔗 call_hierarchy | Call hierarchy (in/out/both) for symbol             |
| 🏷️ ctags          | ctags-based symbols (buffer or all_buffers)         |
| 🪟 ui_select      | Wrapper for `vim.ui.select` with enhanced UI        |


## What Makes It Special

- 🔍 **Live Preview**: See exactly where you'll land before you jump
- 🌳 **Order Preservation**: Maintains symbol order as they appear in your code, even after filtering
- 📐 **Smart Auto-resize**: Window adapts to your content in real-time as you type and filter, no need for a big window with only a couple of items
- 🚀 **Zero Dependencies**: Works with any LSP-supported language out of the box
- 🎯 **Context Aware**: Always shows your current location in the codebase
- ⚡ **Powerful Filtering**:
  - Live filtering through `/xx` such as `/fn` for fcuntions or `/bf:` for buffer names if all_buffers module.
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
  config = function()
    require("namu").setup({
      -- Enable the modules you want
      namu_symbols = {
        enable = true,
        options = {}, -- here you can configure namu
      },
      -- Optional: Enable other modules if needed
      ui_select = { enable = false }, -- vim.ui.select() wrapper
    })
    -- === Suggested Keymaps: ===
    vim.keymap.set("n", "<leader>ss",":Namu symbols<cr>" , {
      desc = "Jump to LSP symbol",
      silent = true,
    })
    vim.keymap.set("n", "<leader>sw", ":Namu workspace<cr>", {
      desc = "LSP Symbols - Workspace",
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


## Features

- Live fuzzy filtering for all symbol modules (`/fn`, `/me`, etc.)
- Filter by buffer name in all_buffers: `/bf:buffer_name`
- Combine filters: `/bf:name:fn` (buffer and function)
- Diagnostics filtering: `/er` (errors), `/wa` (warnings), `/hi` (hints), `/in` (info)
- Two display styles: `tree_guides` or `indent`
- Configurable prefix icon for current item
- All operations are asynchronous (non-blocking)
- No dependencies except Neovim, LSP, and optional ctags



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
| :Namu symbols    | function, class… | Show buffer symbols, filter by kind         |
| :Namu workspace | text             | Search workspace symbols                    |
| :Namu all_buffers      |                  | Symbols from all open buffers               |
| :Namu diagnostics  | workspace        | Diagnostics for buffer or workspace         |
| :Namu call in/out/both | in/out/both      | Call hierarchy for symbol                   |
| :Namu ctags [active]   | active           | ctags symbols (buffer or all_buffers)       |
| :Namu help [topic]     | symbols/analysis | Show help                                   |
| :Namu colorscheme      |                  | Colorscheme picker                          |

## Make It Yours

You can check the [configuration documentation](https://github.com/bassamsdata/namu.nvim/tree/main/docs/Namu_config.md) for details on each option.
<details>
  <summary>Here's the full setup with defaults:</summary>

```lua
{ -- Those are the default options
  "bassamsdata/namu.nvim",
  config = function()
    require("namu").setup({
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
      colorscheme = {
        enable = false,
        options = {
          -- NOTE: if you activate persist, then please remove any vim.cmd("colorscheme ...") in your config, no needed anymore
          persist = true, -- very efficient mechanism to Remember selected colorscheme
          write_shada = false, -- If you open multiple nvim instances, then probably you need to enable this
          excluded_schemes = {}, -- exclude any colorscheme from the list
          -- it accept the same row_position and movement keys as the one in namy symbols
        },
      },
      ui_select = { enable = false }, -- vim.ui.select() wrapper
    })
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
- Live preview as you move.

<!-- Demo video here (folded) -->

</details>


<details>
<summary>workspace</summary>

- Interactive workspace symbol search (LSP).
- Start typing to see results, live preview.

<!-- Demo video here (folded) -->

</details>


<details>
<summary>all_buffers</summary>

- Shows symbols from all open buffers (LSP or Treesitter fallback).
- Filter by buffer: `/bf:buffer_name`
- Combine with kind: `/bf:name:fn`

<!-- Demo video here (folded) -->

</details>


<details>
<summary>diagnostics</summary>

- Shows diagnostics for buffer or workspace.
- Filter by severity: `/er`, `/wa`, `/hi`, `/in`
- Live preview and navigation.

<!-- Demo video here (folded) -->

</details>

<details>
<summary>call_hierarchy</summary>

- Show incoming, outgoing, or both calls for a symbol.
- Usage: `:Namu call in`, `:Namu call out`, `:Namu call both`

<!-- Demo video here (folded) -->

</details>

<details>
<summary>ctags</summary>

- Show ctags-based symbols for buffer or all_buffers.
- Requires ctags installed.
- Usage: `:Namu ctags`, `:Namu ctags active`

<!-- Demo video here (folded) -->
</details>

## Display Styles

<details>
<summary>Show display style examples</summary>

- `options.display.format = "tree_guides"`:
  (image here)

- `options.display.format = "indent"`:
  (image here)

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

## Credits & Acknowledgements

- [Zed](https://zed.dev) editor for the idea.
- [Mini.pick](https://github.com/echasnovski/mini.nvim) @echasnovski for the idea of `getchar()`, without which this plugin wouldn't exist.
- Magnet module (couldn’t find it anymore on GitHub, sorry!), which intrigued me a lot.
- @folke for handling multiple versions of Neovim LSP requests and treesitter "locals" in [Snacks.nvim](https://github.com/folke/snacks.nvim).
- tests and ci structure, thanks to @Oli [CodeCompanion](https://github.com/olimorris/codecompanion.nvim)
- A simple mechanism to persist the colorscheme, thanks to this [Reddit comment](https://www.reddit.com/r/neovim/comments/1edwhk8/comment/lfb1m2f/?utm_source=share&utm_medium=web3x&utm_name=web3xcss&utm_term=1&utm_content=share_button).
- [Aerial.nvim](https://github.com/stevearc/aerial.nvim) and @Stevearc for borroing some treesitter queries.
