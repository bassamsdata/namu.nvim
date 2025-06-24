# 🛠️ Common Configuration

This file documents the shared settings available across most `namu.nvim` modules. These affect display, preview behavior, formatting style, layout, and highlighting.

<details>
<summary>📸 Click to add a screenshot or video here</summary>

<!-- Drop an image, gif, or video showing the general UI here -->

</details>

---

## 🔎 Preview

```lua
preview = {
  enable = true,              -- Enable or disable preview pane
  highlight_on_move = true,   -- Highlight symbol as you move through the list
}
```

---

## 🚀 Behavior

```lua
auto_select = true,           -- Auto-jump if there's only one match
initially_hidden = false,     -- Start with an empty list (e.g., search-as-you-type)
preserve_order = true,        -- Keep original order while filtering
focus_current_symbol = true,  -- Automatically focus symbol under cursor
```

---

## 🤭 Positioning

This controls where the floating symbol picker window appears.

These percentages allow flexible positioning. For example, `"top15"` would position the window 15% down from the top of the screen.
```lua
row_position = "top10", -- Options: (those are perentages from the top of editor)
-- "center"          -- Center of the screen
-- "top10"           -- 10% from the top
-- "top10_right"     -- 10% from top, aligned right
-- "center_right"    -- Center vertically, aligned right
-- "bottom"          -- Bottom of the screen
```


---

## 🔆 Icons

```lua
icon = "󱠦," -- A decorative symbol used in the UI.
-- You can change this to: "", "", or "" (just make sure to leave a space if used as a prefix)
```

---

## ✨ Current Selection Highlighting

```lua
current_highlight = {
  enabled = true,                 -- Highlight the currently selected item
  hl_group = "NamuCurrentItem",   -- Custom highlight group (you can override it)
  prefix_icon = " ",            -- Icon used for the selected item (e.g., "", "▎", "┆", "")
}
```

---

## 🖼️ Display Style

```lua
display = {
  mode = "icon",          -- Options: "icon" or "text"
  format = "indent",      -- Options: "indent" or "tree_guides"
  tree_guides = {
    style = "unicode",    -- "ascii" or "unicode"
  },
}
```

---

## 💂️ Hierarchy Control

```lua
preserve_hierarchy = true, -- Keeps parent-child symbol relationships after search
```

This is useful when you want to maintain the structure of symbol trees during filtering (e.g., nested functions stay grouped even after fuzzy filtering).
