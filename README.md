# Namu.nvim 🌳

Navigate the structure of your code in Neovim. Namu brings symbols, diagnostics, and call hierarchies into a fuzzy picker with live preview, inspired by [Zed](https://zed.dev).

https://github.com/user-attachments/assets/a97ff3b1-8b25-4da1-b276-f623e37d0368

## Features

- **Symbols with context:** search the current buffer, open buffers, or your workspace. Tree guides show how symbols fit together.
- **Jump labels:** press `;` in a picker, then a displayed label to jump directly to that item. Enabled by default, with configurable keys and optional automatic activation.
- **Live preview:** see a symbol's location as you move through the results.
- **Diagnostics and calls:** browse diagnostics or follow incoming and outgoing calls when your language server supports them.
- **Actions and multiselect:** select several items, send them to quickfix, yank or delete symbol text, or open a split. CodeCompanion and Avante integrations are available when installed.
- **Theme-aware selection:** the focused row gets a contrasting background, including with transparent colorschemes. Custom highlights take precedence.
- **Optional pickers:** Tree-sitter and ctags symbols, a colorscheme picker, and a `vim.ui.select` replacement.

## Requirements

Namu requires **Neovim 0.11+**. The built-in `vim.pack` installation below requires **Neovim 0.12+**.

Use a configured language server for LSP symbols, workspace search, and call hierarchies; available features depend on the server's capabilities. Tree-sitter symbol extraction requires a parser for the buffer's language. A Nerd Font is optional for icons, and [Universal Ctags](https://ctags.io/) is needed for the ctags picker.

## Installation

### Built-in vim.pack

Add this to your `init.lua`:

```lua
vim.pack.add({
  { src = "https://github.com/bassamsdata/namu.nvim" },
})

require("namu").setup({})

vim.keymap.set("n", "<leader>ss", "<cmd>Namu symbols<cr>", { desc = "Namu symbols" })
vim.keymap.set("n", "<leader>sw", "<cmd>Namu workspace<cr>", { desc = "Namu workspace symbols" })
```

This follows the default branch. To follow v0.7 releases, add `version = vim.version.range("0.7")` to the package specification. See [Neovim's package documentation](https://neovim.io/doc/user/pack/) for installation and updates.

### lazy.nvim

Add this plugin specification:

```lua
{
  "bassamsdata/namu.nvim",
  cmd = "Namu",
  main = "namu",
  opts = {},
  keys = {
    { "<leader>ss", "<cmd>Namu symbols<cr>", desc = "Namu symbols" },
    { "<leader>sw", "<cmd>Namu workspace<cr>", desc = "Namu workspace symbols" },
  },
}
```

The command and keys load Namu on demand. Put configuration in `opts`; see [lazy.nvim's loading documentation](https://lazy.folke.io/spec/lazy_loading) for other triggers.

## Getting started

Open a file with an attached language server, then run `:Namu symbols`. Type to filter, move through the results to preview the code, and press `<CR>` to jump. Press `;` to show labels and select a result directly.

Tree guides and manual jump labels are the defaults. No configuration is needed to enable them.

### Commands

| Command | What it shows |
| --- | --- |
| `:Namu symbols` | Symbols in the current buffer |
| `:Namu symbols function` | Only functions; other kinds such as `class`, `method`, and `variable` are supported |
| `:Namu treesitter` | Current-buffer symbols from Tree-sitter |
| `:Namu workspace` | Workspace symbols from your language server |
| `:Namu workspace query` | Workspace symbols with an initial query |
| `:Namu watchtower` | Symbols across open buffers |
| `:Namu diagnostics` | Current-buffer diagnostics |
| `:Namu diagnostics buffers` | Diagnostics across open buffers |
| `:Namu diagnostics workspace` | Available workspace diagnostics |
| `:Namu call in` | Incoming calls |
| `:Namu call out` | Outgoing calls |
| `:Namu call both` | Both directions |
| `:Namu ctags` | Current-buffer ctags symbols; enable `namu_ctags` first |
| `:Namu ctags watchtower` | Ctags symbols across open buffers |
| `:Namu colorscheme` | Colorscheme picker; enable `colorscheme` first |
| `:Namu help` | Command help |
| `:Namu help symbols` | Symbol filtering help |
| `:Namu help analysis` | Symbol information for the current buffer |

### Picker keys

| Key | Action |
| --- | --- |
| `<C-n>` / `<Down>` | Next item |
| `<C-p>` / `<Up>` | Previous item |
| `<CR>` | Select item |
| `<Esc>` | Close picker; in jump mode, return to filtering first |
| `;` | Toggle jump labels |
| `<Tab>` / `<S-Tab>` | Select / unselect an item |
| `<C-a>` / `<C-l>` | Select all / clear selection |
| `<C-y>` | Yank symbol text |
| `<C-d>` | Delete symbol text |
| `<C-v>` / `<C-h>` | Open a vertical / horizontal split |
| `<C-q>` | Send items to quickfix |
| `<C-o>` / `<C-t>` | Add to CodeCompanion / Avante |

Actions depend on the picker and its items. Integrations require the corresponding plugin.

## Configuration

Use `global` for shared picker options and a module key for its overrides:

```lua
require("namu").setup({
  global = {
    display = { format = "tree_guides" },
    jump = { enabled = true, toggle_key = ";", auto_activate = false },
  },
  namu_symbols = {
    row_position = "top10",
    window = { max_width = 100 },
  },
  ui_select = { enable = false },
})
```

See the [full configuration guide](doc/Namu_config.md) for module names, option reference, defaults, and precedence. The [configuration recipes](doc/recipes.md) cover jump labels, display styles, filters, highlights, optional pickers, and testing a local checkout with `vim.pack` or lazy.nvim.

You can also read `:help namu` inside Neovim.

## Demos

| Feature | Recording |
| --- | --- |
| Current-buffer symbols | [Watch](https://github.com/user-attachments/assets/bb2a14da-cba0-4ae7-b826-4ceb1c828b79) |
| Workspace symbols | [Watch](https://github.com/user-attachments/assets/e548c3ea-6cdb-4f20-9569-175c57b31039) |
| Watchtower | [Watch](https://github.com/user-attachments/assets/76c637d2-30d3-4f54-9290-510a51dcbe7e) |
| Diagnostics | [Watch](https://github.com/user-attachments/assets/02dc0ce5-c87a-445f-a477-ac4f411c6592) |
| Call hierarchy | [Watch](https://github.com/user-attachments/assets/5d30214a-a5d8-46e3-89d4-be71203501e7) |
| Ctags | [Watch](https://github.com/user-attachments/assets/09ccc178-c067-45bb-8f86-3f8aa183e69d) |

<details>
<summary>Compare display styles</summary>

Tree guides (default):

![Tree guides](https://github.com/user-attachments/assets/5be3180c-87b8-4a06-9cd1-e65e5fe08b81)

Indentation (`display.format = "indent"`):

![Indentation](https://github.com/user-attachments/assets/8d78aa5d-27d9-4331-9898-01d18e3bd23a)

</details>

## Contributing

Bug reports, suggestions, and pull requests are welcome. Include your Neovim version, configuration, and a small reproduction when reporting a problem. Run `make format`, `make docs`, and relevant tests for changes.

“Namu” means “tree” in Korean, reflecting the structure of your code.

## Credits

- [Zed](https://zed.dev) for the inspiration.
- [@themastersheep](https://github.com/themastersheep) for [jump labels](https://github.com/bassamsdata/namu.nvim/pull/65). Thank you!
- [@echasnovski](https://github.com/echasnovski) and [mini.pick](https://github.com/echasnovski/mini.nvim) for the `getchar()` idea.
- The Magnet module for the early inspiration.
- [@folke](https://github.com/folke) and [Snacks.nvim](https://github.com/folke/snacks.nvim) for LSP compatibility and Tree-sitter locals handling.
- [@olimorris](https://github.com/olimorris) and [CodeCompanion](https://github.com/olimorris/codecompanion.nvim) for the tests, CI structure, and vimdoc approach.
- [This Reddit comment](https://www.reddit.com/r/neovim/comments/1edwhk8/comment/lfb1m2f/) for colorscheme persistence.
- [@stevearc](https://github.com/stevearc) and [Aerial.nvim](https://github.com/stevearc/aerial.nvim) for Tree-sitter queries.

## License

[MIT](LICENSE)
