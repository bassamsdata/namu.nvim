--[[ Namu Diagnostics 
Diagnostics picker with live preview and actions.
Integrates with selecta for fuzzy finding and magnet for symbol handling.
]]

local M = {}

M.config = require("namu.namu_symbols.config").values
M.config = vim.tbl_deep_extend("force", M.config, {
  row_position = "top10",
  highlights = {
    Error = "DiagnosticVirtualTextError",
    Warn = "DiagnosticVirtualTextWarn",
    Info = "DiagnosticVirtualTextInfo",
    Hint = "DiagnosticVirtualTextHint",
  },
  icons = {
    Error = "",
    Warn = "󰀦",
    Info = "󰋼",
    Hint = "󰌶",
  },
  current_highlight = {
    enabled = true,
    hl_group = "NamuCurrentItem",
    prefix_icon = " ",
  },
  window = {
    title_prefix = "󰃣 ",
    min_width = 79,
    max_width = 100,
    max_height = 15,
    min_height = 1,
    padding = 2,
  },
  custom_keymaps = {
    yank = {
      keys = { "<C-y>" },
      desc = "Yank diagnostic with context",
      handler = function(items_or_item, state)
        local impl = M.get_impl()
        if not impl then
          return
        end
        return impl.yank_diagnostic_with_context(M.config, items_or_item, state)
      end,
    },
    codecompanion = {
      keys = { "<C-o>" },
      desc = "Add to CodeCompanion",
      handler = function(items_or_item, state)
        local impl = M.get_impl()
        if not impl then
          return
        end
        return impl.add_to_codecompanion(M.config, items_or_item, state)
      end,
    },
    vertical_split = {
      keys = { "<C-v>" },
      desc = "Open in vertical split",
      handler = function(items_or_item, state)
        local impl = M.get_impl()
        return impl.open_in_vertical_split(M.config, items_or_item)
      end,
    },
    horizontal_split = {
      keys = { "<c-h>" },
      desc = "Open in horizontal split",
      handler = function(items_or_item, state)
        local impl = M.get_impl()
        return impl.open_in_horizontal_split(M.config, items_or_item, state)
      end,
    },
    code_action = {
      keys = { "<C-CR>", "<D-CR>" },
      handler = function(items_or_item, state)
        local impl = M.get_impl()
        return impl.invoke_code_action(M.config, items_or_item, state)
      end,
    },
    codecompanion_inline = {
      keys = {}, -- FIX: needs some integration from the codecompanion to be robust
      desc = "Fix diagnostic with AI",
      handler = function(items_or_item, state)
        local impl = M.get_impl()
        return impl.send_to_codecompanion_inline(M.config, items_or_item, state)
      end,
    },
  },
})

-- Flag to track if implementation is loaded
local impl_loaded = false
local impl = nil

-- Function to load the full implementation
local function load_impl()
  if impl_loaded then
    return
  end
  -- Load the actual implementation
  impl = require("namu.namu_diagnostics.diagnostics")
  impl_loaded = true
end

-- Setup just merges configs
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

function M.get_impl()
  load_impl()
  return impl
end

-- Define API functions that lazy-load the implementation
function M.show(scope)
  load_impl()
  if not impl then
    return
  end
  return impl.show(M.config, scope)
end

function M.show_current_diagnostics()
  load_impl()
  if not impl then
    return
  end
  return impl.show_current_diagnostics(M.config)
end

function M.show_buffer_diagnostics()
  load_impl()
  if not impl then
    return
  end
  return impl.show_buffer_diagnostics(M.config)
end

function M.show_workspace_diagnostics()
  load_impl()
  if not impl then
    return
  end
  return impl.show_workspace_diagnostics(M.config)
end

return M
