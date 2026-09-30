# Configuration recipes

[README](../README.md) · [Full configuration guide](Namu_config.md)

Each setup example shows only the settings it changes. Combine them into one `require("namu").setup(...)` call, or into lazy.nvim's `opts` table.

## Resume the last picker

Use `:Namu resume` to reopen the last closed picker with its search, options, selected row, scroll position, multiselections, and insert/normal/jump-label mode.

```lua
vim.keymap.set("n", "<leader>nr", "<cmd>Namu resume<CR>", {
  desc = "Namu: Resume last picker",
})
```

Lua mappings can also call `require("namu").resume()`. The snapshot lasts for the current Neovim session and requires the original buffer and window to remain available. Cached asynchronous results appear immediately; changing the search requests new results. A request still pending when the picker closed is restarted on resume.

## Sidebar and favorites

`:Namu outline` opens symbols for the current file in a persistent split with search at the top. The outline refreshes when you switch files, save, or attach an LSP. Use `:Namu outline refresh` to refresh manually, or `:Namu outline toggle` to show/hide it.

In any picker, use `<C-b>` to save the current item (or your Tab selections) to favorites. Use `<C-s>` to send the selected items, or all filtered items when nothing is selected, to a new sidebar. Reopen that list with `:Namu sidebar`; open favorites with `:Namu bookmarks`.

Inside a sidebar:

- `j` / `k`: move between items.
- `h` / `l`: collapse / expand nested groups.
- `/`: edit the search; Enter or Escape returns to the list.
- Enter in the list: jump to the item, keeping the sidebar open.
- `m`: save the current item to favorites.
- `dd` in favorites: remove the current favorite.
- Escape in the list: focus code; `q`: close and save the sidebar.

Favorites, search, selection, scroll position, and collapsed groups are saved across restarts by default. Favorites store file paths and locations, so they remain usable after buffer IDs change. The default storage file is `stdpath("data") .. "/namu/sidebar.json"`.

```lua
require("namu").setup({
  sidebar = {
    position = "right", -- or "left"
    width = 40,
    persist = false, -- optional: keep state only within this session
  },
})
vim.keymap.set("n", "<leader>no", "<cmd>Namu outline toggle<CR>")
vim.keymap.set("n", "<leader>nb", "<cmd>Namu bookmarks<CR>")
```

Change picker shortcuts with `global.custom_keymaps.bookmark.keys` and `global.custom_keymaps.sidebar.keys`. Set either list to `{}` to disable that shortcut. `:Namu bookmarks clear` removes all favorites.

## Jump labels

Manual activation with `;` is already enabled. Change the trigger and label keys:

```lua
require("namu").setup({
  global = {
    jump = { toggle_key = ";", keys = "asdfghjkl" },
  },
})
```

To activate labels automatically for small `vim.ui.select` dialogs, while leaving other pickers manual:

```lua
require("namu").setup({
  ui_select = {
    enable = true,
    jump = {
      auto_activate = 10,
      skip_kinds = { codeaction = true },
    },
  },
})
```

The threshold uses the item count when the picker opens. `skip_kinds` only suppresses automatic activation for those selection kinds; manual activation still works.

To disable jump labels everywhere:

```lua
require("namu").setup({
  global = { jump = { enabled = false } },
})
```

## Display styles

Tree guides are the default. Use indentation everywhere, then restore tree guides for symbols:

```lua
require("namu").setup({
  global = { display = { format = "indent" } },
  namu_symbols = {
    display = { format = "tree_guides", tree_guides = { style = "ascii" } },
  },
})
```

For a font without Nerd Font icons:

```lua
require("namu").setup({
  namu_symbols = {
    display = { mode = "raw" },
    current_highlight = { prefix_icon = "> " },
  },
})
```

## Window and preview

```lua
require("namu").setup({
  namu_symbols = {
    row_position = "center",
    window = { max_width = 90, max_height = 25, border = "single" },
    preview = { highlight_on_move = false },
  },
})
```

`preview.highlight_on_move` controls the preview highlight. There is no supported `preview.enable` switch.

## Symbol filters

Use `:Namu symbols function` or `:Namu symbols class` for a one-off kind filter. For picker query aliases, see `:Namu help symbols`.

To change the default Python kinds and exclude Python names beginning with `__`:

```lua
require("namu").setup({
  namu_symbols = {
    AllowKinds = { python = { "Function", "Class", "Method" } },
    BlockList = { python = { "^__" } },
  },
})
```

`AllowKinds` contains LSP kind names. `BlockList` contains Lua patterns, not regular expressions. Per-filetype lists take precedence over `default` lists.

To prefer Tree-sitter symbols:

```lua
require("namu").setup({
  namu_symbols = { source_priority = "treesitter" },
})
```

Install a parser for the file's language. You can also use `:Namu treesitter` directly.

## Keys and multiselect

```lua
require("namu").setup({
  global = {
    movement = { next = { "<C-j>", "<Down>" }, previous = { "<C-k>", "<Up>" } },
    custom_keymaps = {
      quickfix = { keys = { "<C-q>" }, desc = "Send to quickfix" },
    },
  },
  namu_symbols = {
    actions = { close_on_yank = true, close_on_quickfix = true },
  },
})
```

Use `<Tab>` to select multiple items, then invoke an available action. CodeCompanion and Avante examples are in [action_intergration.md](action_intergration.md).

## Highlights and colorschemes

The default row background adapts to the colorscheme. You normally do not need an override. A transparent picker still gives its focused row a background; it does not add an underline as a visibility fallback.

To set your own row color and keep it across colorscheme changes:

```lua
local function set_namu_highlights()
  vim.api.nvim_set_hl(0, "NamuCurrentItem", { bg = "#3b4b52", bold = true })
  vim.api.nvim_set_hl(0, "NamuJumpLabel", { fg = "#ffd580", bold = true })
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("MyNamuHighlights", { clear = true }),
  callback = set_namu_highlights,
})
set_namu_highlights()
```

Choose a background that contrasts with your picker. Explicit highlight definitions take precedence over Namu's adaptive defaults.

To hide only the current-item prefix marker:

```lua
require("namu").setup({
  global = { current_highlight = { enabled = false } },
})
```

The row background remains visible.

## Optional pickers

```lua
require("namu").setup({
  namu_ctags = { enable = true }, -- Requires Universal Ctags.
  colorscheme = { enable = true },
  ui_select = { enable = true }, -- Replaces vim.ui.select.
})
```

Then use `:Namu ctags`, `:Namu ctags watchtower`, or `:Namu colorscheme`. UI selection uses Namu when another plugin calls `vim.ui.select`.

## Test a local checkout

A local checkout can be loaded without changing your installed package. Use one source for Namu in each Neovim session to avoid mixing versions.

### Built-in vim.pack

Temporarily replace the GitHub `vim.pack.add` entry for Namu with:

```lua
local namu_path = vim.fn.expand("~/repos/namu.nvim")
vim.opt.runtimepath:prepend(namu_path)
vim.cmd.source(namu_path .. "/plugin/namu.lua")
require("namu").setup({})
```

Start a fresh Neovim session. This loads the working checkout directly, including uncommitted edits. There is no install or update step for the local checkout. Restore the GitHub package entry when finished.

If your configuration wraps `vim.pack` with custom lazy-loading hooks, put these operations in that wrapper's load callback, keeping its command or key triggers. Those hooks belong to your configuration rather than `vim.pack` itself.

### lazy.nvim

Temporarily use a local directory in the plugin specification:

```lua
{
  dir = vim.fn.expand("~/repos/namu.nvim"),
  name = "namu.nvim",
  main = "namu",
  cmd = "Namu",
  opts = {},
  keys = {
    { "<leader>ss", "<cmd>Namu symbols<cr>", desc = "Namu symbols" },
  },
}
```

The command and key triggers still lazy-load the local checkout.

### Check which copy is loaded

```vim
:lua vim.print(vim.api.nvim_get_runtime_file("lua/namu/init.lua", true))
:lua vim.print(debug.getinfo(require("namu").setup, "S").source)
```

The first command lists matching runtime files; the second identifies the implementation actually loaded. Restart Neovim after switching sources, since Lua modules are cached for the session.
