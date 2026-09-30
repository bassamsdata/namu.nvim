# Namu configuration

[README](../README.md) · [Recipes](recipes.md)

Namu works with `require("namu").setup({})`. Override only the options you want to change. With lazy.nvim, use the same table as `opts` in the plugin specification.

## Setup structure

```lua
require("namu").setup({
  global = {
    -- Shared picker settings. These are the current defaults.
    display = { format = "tree_guides" },
    jump = { enabled = true, toggle_key = ";", auto_activate = false },
  },
  namu_symbols = { enable = true },
  workspace = { enable = true },
  watchtower = { enable = true },
  diagnostics = { enable = true },
  callhierarchy = { enable = true },
  namu_ctags = { enable = false },
  colorscheme = { enable = false },
  ui_select = { enable = false },
})
```

The symbols module is named `namu_symbols`, and the call hierarchy module is named `callhierarchy`. Options belong directly under a module key. The older `module.options` nesting is still accepted; new configurations should use the direct form.

### How overrides resolve

Shared defaults are merged with module defaults, then your `global` settings, then your module settings. A module override wins over a global override. Legacy `module.options` settings are applied before direct module options. Module implementations also supply their own base defaults for options such as symbol icons and filtering.

```lua
require("namu").setup({
  global = { window = { max_width = 100 } },
  workspace = { window = { max_width = 75 } },
})
```

Here, the workspace picker uses a maximum width of 75; other pickers use 100. Lua lists are merged by index, so list overrides should be checked when replacing defaults.

## Full defaults

The following files contain the complete defaults, including filetype filters, icons, and module-specific settings. They are the authoritative reference:

- [Shared and module defaults](../lua/namu/core/config_manager.lua)
- [Symbol defaults](../lua/namu/namu_symbols/config.lua)
- [Picker and jump defaults](../lua/namu/selecta/selecta_config.lua)
- [Enabled modules](../lua/namu/init.lua)
- [Configuration types](../lua/namu/namu_symbols/types.lua)

For a copyable configuration covering the main settings and every module, see [configuration.lua](configuration.lua). It is a starting point; it does not duplicate every internal or experimental option from the source files.

To inspect the shared configuration resolved for a module inside Neovim:

```vim
:lua require("namu.core.config_manager").debug_config("namu_symbols")
```

To inspect the symbols configuration after opening its picker:

```vim
:lua vim.print(require("namu.namu_symbols").config)
```

## Shared picker options

Place these under `global` to affect all pickers, or under a module to affect that picker.

### Jump labels

| Option | Default | Purpose |
| --- | --- | --- |
| `jump.enabled` | `true` | Allow jump mode |
| `jump.toggle_key` | `";"` | Enter or leave jump mode |
| `jump.auto_activate` | `false` | `true` activates on opening; a number `N` activates when the picker opens with at most `N` items |
| `jump.keys` | `"asdfghjklqwertyuiopzxcvbnmASDFGHJKLQWERTYUIOPZXCVBNM"` | Characters assigned to visible rows |
| `jump.hl_group` | `"NamuJumpLabel"` | Label highlight |
| `jump.priority` | `300` | Label extmark priority |
| `jump.min_items` | `0` | Minimum visible item count for activation |
| `jump.skip_kinds` | `{}` | `vim.ui.select` kinds excluded from automatic activation |

Press `;`, then a label to select its item. Labels are assigned to visible rows, up to the number of characters in `jump.keys`. Use distinct single-byte characters. While jump mode is active, label keys select rows instead of typing into the filter. Press `;` or `<Esc>` to return to filtering. Without active jump mode, `<Esc>` closes the picker.

### Movement and actions

| Option | Default |
| --- | --- |
| `movement.next` | `{ "<C-n>", "<DOWN>" }` |
| `movement.previous` | `{ "<C-p>", "<UP>" }` |
| `movement.close` | `{ "<ESC>" }` |
| `movement.select` | `{ "<CR>" }` |
| `multiselect.enabled` | `true` |
| `multiselect.selected_icon` | `"● "` |
| `multiselect.unselected_icon` | `"○ "` |
| `multiselect.keymaps.toggle` | `"<Tab>"` |
| `multiselect.keymaps.untoggle` | `"<S-Tab>"` |
| `multiselect.keymaps.select_all` | `"<C-a>"` |
| `multiselect.keymaps.clear_all` | `"<C-l>"` |

Action keymaps live in `custom_keymaps`. Each action accepts `keys` (a string or list), a `desc`, and an optional `handler`. Availability depends on the module and item data.

| Action | Default keys |
| --- | --- |
| `yank` | `<C-y>` |
| `delete` | `<C-d>` |
| `vertical_split` | `<C-v>` |
| `horizontal_split` | `<C-h>` |
| `quickfix` | `<C-q>` |
| `codecompanion` | `<C-o>` |
| `avante` | `<C-t>` |

For symbols, `actions.close_on_yank` defaults to `false`, `actions.close_on_delete` to `true`, and `actions.close_on_quickfix` to `false`. Integration examples are in [action_intergration.md](action_intergration.md).

### Display and current-item marker

| Option | Default / values |
| --- | --- |
| `display.format` | `"tree_guides"`; also `"indent"` |
| `display.mode` | Symbols use `"icon"`; `"raw"` omits kind icons |
| `display.indent_size` | `2` for symbols |
| `display.tree_guides.style` | `"unicode"`; also `"ascii"` |
| `current_highlight.enabled` | `true`; controls the current-item prefix marker |
| `current_highlight.prefix_icon` | `" "`; keep a trailing space |

The current row's background comes from `NamuCurrentItem`, independently of the prefix marker. Customize it with a highlight definition, as shown in the [highlight recipe](recipes.md#highlights-and-colorschemes).

### Window

| Option | Shared default |
| --- | --- |
| `window.auto_size` | `true` |
| `window.min_height` / `max_height` | `1` / `41` |
| `window.min_width` / `max_width` | `35` / `120` |
| `window.padding` | `2` |
| `window.border` | Neovim's nonempty `winborder`, otherwise `"rounded"` |
| `window.title_pos` | `"center"` |
| `window.show_footer` | `true` |
| `window.footer_pos` | `"right"` |
| `window.relative` | `"editor"` |
| `window.style` | `"minimal"` |
| `window.width_ratio` / `height_ratio` | `0.6` / `0.6` |

Modules can override dimensions and title prefixes. `row_position` supports `"center"`, `"top10"`, `"top10_right"`, `"center_right"`, and `"bottom"`; symbols default to `"top10"`.

## Module options

### Symbols (`namu_symbols`)

| Option | Default / purpose |
| --- | --- |
| `source_priority` | `"lsp"`; use `"treesitter"` to prefer Tree-sitter |
| `AllowKinds` | Allowed kinds by filetype, with a `default` list; see full symbol defaults |
| `BlockList` | Lua patterns excluding symbol names by filetype; `default` applies when no filetype list exists |
| `filter_symbol_types` | Kind filter aliases used in picker queries; see `:Namu help symbols` |
| `focus_current_symbol` | `true`; start near the current symbol |
| `auto_select` | `false`; automatically select a sole result when enabled |
| `hierarchical_mode` | `false` |
| `enhance_lua_test_symbols` | `true`; show richer Lua test names |
| `lua_test_truncate_length` | `50` |
| `lua_test_preserve_hierarchy` | `true` |
| `preview.highlight_on_move` | `true` |
| `kindIcons` / `kindText` | Icons and display names keyed by symbol kind |
| `kinds.enable_highlights` | `true` |
| `kinds.prefix_kind_colors` | `true` |
| `kinds.highlights` | Highlight group names keyed by kind |

Tree-sitter is also accessible directly with `:Namu treesitter`. Parser and query support determine which symbols can be extracted. A Tree-sitter preference can fall back to LSP when available.

### Workspace (`workspace`)

Uses the language server's workspace symbol support. The default window width is 50–75 columns. `:Namu workspace query` supplies an initial query.

### Open buffers (`watchtower`)

Collects symbols across open buffers. It defaults to tree guides, `preserve_hierarchy = true`, and the same Lua test enhancement settings as symbols.

### Diagnostics (`diagnostics`)

Defaults to tree guides, `preserve_hierarchy = true`, and `row_position = "top10"`. The window defaults to 79–100 columns and at most 15 rows. `icons` and `highlights` have `Error`, `Warn`, `Info`, and `Hint` entries. The code action mapping is `<C-CR>` / `<D-CR>` when supported by the terminal and language server.

### Calls (`callhierarchy`)

Requires a language server with call hierarchy support. Defaults:

```lua
require("namu").setup({
  callhierarchy = {
    preserve_hierarchy = true,
    sort_by_nesting_depth = true,
    call_hierarchy = {
      max_depth = 2,
      max_depth_limit = 4,
      show_cycles = false,
    },
  },
})
```

### Ctags (`namu_ctags`)

Disabled by default. Enable it and install Universal Ctags to use `:Namu ctags` or `:Namu ctags watchtower`.

### Colorschemes (`colorscheme`)

Disabled by default. Enable it to use the colorscheme picker and its setup behavior. See the [optional picker recipe](recipes.md#optional-pickers).

### UI selection (`ui_select`)

Disabled by default. Enabling it replaces `vim.ui.select`. It uses raw display, numbered items, and a maximum height of 30 rows. Shared jump settings apply here too; use a `ui_select.jump` override to change them for selection dialogs.

## Highlights

Namu defines its highlights in [core/highlights.lua](../lua/namu/core/highlights.lua).

| Group | Purpose |
| --- | --- |
| `NamuCurrentItem` | Focused row background |
| `NamuCurrentItemIcon` / `NamuCurrentItemIconSelection` | Current-item marker colors |
| `NamuJumpLabel` | Jump labels |
| `NamuMatch` | Matched query characters |
| `NamuSelected` | Multiselect marker |
| `NamuPrompt` / `NamuFilter` | Picker prompt and filter |
| `NamuFooter` | Footer |
| `NamuPreview` | Code preview highlight |
| `NamuSymbolFunction`, `NamuSymbolMethod`, etc. | Symbol kind colors |

The default focused-row background uses `CursorLine` when it provides enough contrast. Otherwise, Namu tries `PmenuSel`, `Visual`, and a derived contrasting background. Transparent pickers prefer selection colors. Defaults refresh on colorscheme changes, while explicit current-item and icon highlight definitions take precedence. A custom override is responsible for its own contrast.

See [recipes](recipes.md) for working examples.
