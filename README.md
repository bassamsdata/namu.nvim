# Namu.nvim

Jump to symbols in your code with live preview and fuzzy finding. inspired by Zed.
Think of it as a smart compass for your codebase that shows you where you're going.


## What Makes It Special

- 🔍 **Live Preview**: See exactly where you'll land before you jump
- 🌳 **Order Preservation**: Maintains symbol order as they appear in your code, even after filtering
- 📐 **Smart Auto-resize**: Window adapts to your content in real-time as you type and filter, no need for big window with couple of items
- 🚀 **Zero Dependencies**: Works with any LSP-supported language out of the box
- 🎯 **Context Aware**: Always shows your current location in the codebase
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
- 🎨 **Colorscheme Picker**: live preview with your code  and switch themes with persistant
- 🔄 **vim.ui.select**: Enhanced wrapper for vim's built-in selector
- 📦 More modules coming soon, including buffers and diagnostics!


## ⚡ Requirements
- Neovim >= 0.10.0
- Configured LSP server for your language
- Treesitter (for live preview functionality)

## Installation
Using [lazy.nvim](https://github.com/folke/lazy.nvim):
```lua
{
  "bassamsdata/namu.nvim",
  config = function()
    require("selecta").setup({
      -- Enable the modules you want
      magnet = {
        enable = true,
        options = {
          multiselect = {
            keymaps = {
              toggle = "<Tab>",      -- Toggle current item selection
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
      selecta_colorscheme = { enable = false },
      ui_select = { enable = false },
    })
  end
}
```

## Make It Yours
Here's the full setup with defaults:
```lua
```

## Tips

Type to filter symbols - it's fuzzy, so no need to be exact, though it prioritize exact words first
Use regex patterns for precise filtering (e.g., ^test_ for test functions)
Press <CR> to jump, <Esc> to cancel
