--[[ Namu Watchtower Buffers
Displays symbols from all open/valid buffers in a picker with preview.
Integrates with selecta for fuzzy finding and LSP for symbol handling.
]]

local M = {}

-- Import only the configuration dependency
M.config = require("namu.namu_symbols.config").values
M.config = vim.tbl_deep_extend("force", M.config, {
  enhance_lua_test_symbols = true,
  lua_test_truncate_length = 50,
  lua_test_preserve_hierarchy = true,
  display = {
    format = "tree_guides",
  },
  preserve_hierarchy = true,
  current_highlight = {
    enabled = true,
    hl_group = "NamuCurrentItem",
    prefix_icon = " ",
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
        -- FIX: Implemetn this please
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
        if impl then
          return impl.open_in_vertical_split(M.config, items_or_item, state)
        end
      end,
    },
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
  impl = require("namu.namu_watchtower.watchtower")
  impl_loaded = true
end

function M.get_impl()
  load_impl()
  return impl
end

-- Setup just merges configs
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- Define API function that lazy-loads the implementation
function M.show()
  load_impl()
  if not impl then
    return
  end
  -- Explicitly pass the config to the implementation
  return impl.show(M.config)
end

return M
