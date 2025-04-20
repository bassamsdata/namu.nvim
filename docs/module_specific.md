# 📦 Module-Specific Configurations

This document describes settings unique to certain modules in `namu.nvim`. These configurations extend beyond the common settings shared across all modules.

<details>
<summary>📸 Click to add module-specific screenshots or demos</summary>

<!-- Add visuals showing diagnostics, call hierarchy, etc. here -->

</details>

---

## 🩺 Diagnostics Module

```lua
diagnostics = {
  highlights = {
    Error = "DiagnosticVirtualTextError",
    Warn  = "DiagnosticVirtualTextWarn",
    Info  = "DiagnosticVirtualTextInfo",
    Hint  = "DiagnosticVirtualTextHint",
  },
  icons = {
    Error = "",
    Warn  = "󰀦",
    Info  = "󰋼",
    Hint  = "󰌶",
  },
  current_highlight = {
    enabled = true,
    hl_group = "NamuCurrentItem",
    prefix_icon = " ",
  },
  window = {
    title_prefix = "󰃣 > ",
    min_width = 20,
    max_width = 80,
    min_height = 1,
    padding = 2,
  },
}
```

---

## 📞 Call Hierarchy Module

```lua
call_hierarchy = {
  preserve_hierarchy = true,
  sort_by_nesting_depth = true, -- Less nested first; if false, order follows the code
  call_hierarchy = {
    max_depth = 2,          -- Default maximum depth for traversal
    max_depth_limit = 4,    -- Hard limit to prevent performance issues
    show_cycles = false,    -- Whether to show recursive calls
  },
}
```
