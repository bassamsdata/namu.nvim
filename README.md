# Namu.nvim

🌿 Jump to symbols in your code with live preview, built-in fuzzy finding, and other modules.
Inspired by Zed, it preserves symbol order while guiding you through your codebase.




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
  - All features are configurable

## 🧩 Other Modules

Namu is powered by Selecta, a minimal and flexible fuzzy finder that's also used by:
- 🎨 **Colorscheme Picker**: Live preview with your code and switch themes with persistence
- 🔄 **vim.ui.select**: Enhanced wrapper for Vim's built-in selector
- 📦 More modules coming soon, including buffers and diagnostics!

## ⚡ Requirements
- Neovim >= 0.10.0
- Configured LSP server for your language
- Treesitter (for live preview functionality)

## Installation

### Lazy.nvim

Using [lazy.nvim](https://github.com/folke/lazy.nvim):
```lua
{
  "bassamsdata/namu.nvim",
  config = function()
    require("selecta").setup({
      -- Enable the modules you want
      namu = {
        enable = true,
        options = {
          multiselect = {
            keymaps = {
              toggle = "<Tab>",      -- Toggle current item selection
              untoggle = "<S-Tab>",  -- Unselect current item
              select_all = "<C-a>",  -- Select all items
              clear_all = "<C-l>",   -- Clear all selections
            }
          },
          keymaps = {
            { key = "<C-y>", desc = "Yank symbol(s) text" },
            { key = "<C-d>", desc = "Delete symbol(s) text" },
            { key = "<C-v>", desc = "Open in vertical split" },
            { key = "<C-o>", desc = "Add symbol(s) to CodeCompanion" },
            { key = "<C-t>", desc = "Add symbol(s) to Avante" }
          }
        }
      },
      -- Optional: Enable other modules if needed
      colorscheme = { enable = false },
      ui_select = { enable = false }, -- vim.ui.select() wrapper
    })
  end
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

## Make It Yours

Here's the full setup with defaults:
```lua
-- TODO: Add full default setup
```

## Tips

- Type to filter symbols - it's fuzzy, so no need to be exact, though it prioritizes exact words first
- Use regex patterns for precise filtering (e.g., `^test_` for test functions)
- Press `<CR>` to jump, `<Esc>` to cancel

## Feature Demos

<details>
  <summary>🌳 Order Preservation</summary>


https://github.com/user-attachments/assets/2f84f1b0-3fb7-4d69-81ea-8ec70acb5b80


</details>

<details>
  <summary>🌑 Initially Hidden Mode</summary>


https://github.com/user-attachments/assets/e279b785-5fcf-4c2c-8cb5-b0467d850dd0


</details>

<details>
  <summary>🔍 Live Preview & Context Aware</summary>

https://github.com/user-attachments/assets/292a94f3-264a-4ffa-9203-407bd101e35c


</details>

<details>
  <summary>⚡ Auto-select</summary>

https://github.com/user-attachments/assets/a8768aae-e190-4707-989a-0ee909380a5d


</details>

## Contributing

I made this plugin for fun at first and didn't know I could replicate what Zed has, and to be independent and free from any pickers.
Pull requests are welcome! Just please be kind and respectful.
Any suggestions to improve and integrate with other plugins are also welcome.

## Credits & Acknowledgements

- [Zed](https://zed.dev) editor for the idea.
- [Mini.pick](https://github.com/echasnovski/mini.nvim) @echasnovski for the idea of `getchar()`, without which this plugin wouldn't exist.
- Magnet module from (couldn’t find it anymore on GitHub), which intrigued me a lot.
- @folke for handling multiple versions of Neovim LSP requests in [Snacks.nvim](https://github.com/folke/snacks.nvim).
