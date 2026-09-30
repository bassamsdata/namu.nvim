# Actions and integrations

[Configuration guide](Namu_config.md) · [Recipes](recipes.md)

Action availability depends on the picker and its item data. In the symbols picker, select several items with `<Tab>`, then invoke an action to use the selection. Without a multiselection, the action uses the current item.

| Key | Action |
| --- | --- |
| `<C-y>` | Yank symbol text |
| `<C-d>` | Delete symbol text from the source buffer |
| `<C-v>` / `<C-h>` | Open the location in a vertical / horizontal split |
| `<C-q>` | Send locations to quickfix |
| `<C-o>` | Add symbol text to CodeCompanion |
| `<C-t>` | Add symbol text to Avante |

The AI integrations require the corresponding plugin to be installed and configured. Diagnostics can also provide context to supported integrations. Namu supplies the built-in action handlers; you only need to configure keys or closing behavior:

```lua
require("namu").setup({
  namu_symbols = {
    custom_keymaps = {
      codecompanion = { keys = { "<C-o>" }, desc = "Add to CodeCompanion" },
      avante = { keys = { "<C-t>" }, desc = "Add to Avante" },
      quickfix = { keys = { "<C-q>" }, desc = "Send to quickfix" },
    },
    actions = {
      close_on_yank = false,
      close_on_delete = true,
      close_on_quickfix = false,
    },
  },
})
```
