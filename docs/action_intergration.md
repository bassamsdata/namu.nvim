# 🧩 Actions & Integrations

This section documents custom actions available across `namu.nvim` modules, and how they integrate with other tools — especially [CodeCompanion](https://github.com/codecompanion/codecompanion.nvim).

These actions can be triggered with keymaps, support multiple item selection, and return control to your configured handler functions.

---

## 📋 Multi-item Support

Most actions in `namu.nvim` support multiple selection. For example:
- Yank (`<C-y>`) will concatenate all selected items into a single string.
- Delete (`<C-d>`) will remove all selected items.
- CodeCompanion actions send the text of all selected symbols.

---

## 💬 CodeCompanion Integration

### 🔹 Add to Chat

Sends one or more symbols (with line numbers) to a CodeCompanion chat.

```lua
codecompanion = {
  keys = { "<C-o>" },
  desc = "Add to CodeCompanion",
  handler = function(items_or_item, state)
    local impl = M.get_impl()
    if not impl then return end
    return impl.add_to_codecompanion(M.config, items_or_item, state)
  end,
},
```

<details>
<summary>🎥 Upload video or gif for: sending symbols to chat</summary>
<!-- Drop media here -->
</details>

### 🔹 Add with Diagnostics (for diagnostics module)

If used in the diagnostics module, the symbol text is sent along with the associated diagnostic info.

<details>
<summary>🎥 Upload video or gif for: sending diagnostics to chat</summary>
<!-- Drop media here -->
</details>

---

## 🪟 Window Actions

### 🔸 Vertical Split

```lua
vertical_split = {
  keys = { "<C-v>" },
  desc = "Open in vertical split",
  handler = function(items_or_item, state)
    local impl = M.get_impl()
    if impl then
      return impl.open_in_vertical_split(M.config, items_or_item, state)
    end
  end,
},
```

### 🔸 Horizontal Split

```lua
horizontal_split = {
  keys = { "<C-s>", "<C-h>" },
  desc = "Open in horizontal split",
  handler = function(items_or_item, state)
    local impl = M.get_impl()
    if impl then
      return impl.open_in_horizontal_split(M.config, items_or_item, state)
    end
  end,
},
```

---

## 📝 Utility Actions

### 🔸 Yank

Copies the symbol text (or texts) into the unnamed register.
```lua
-- Default key: <C-y>
```

### 🔸 Delete

Removes the symbol(s) from the list.
```lua
-- Default key: <C-d>
```

Let me know if you'd like to rename actions, document a new integration, or refactor this layout!
