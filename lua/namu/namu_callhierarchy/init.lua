--[[ Namu Call Hierarchy 
A call hierarchy browser that shows incoming and outgoing function calls.
Integrates with selecta for fuzzy finding and navigation.
]]

local M = {}

-- Inherit defaults from symbols config
M.config = require("namu.namu_symbols.config").values
M.config = vim.tbl_deep_extend("force", M.config, {
  preserve_hierarchy = true,
  current_highlight = {
    enabled = true,
    hl_group = "NamuCurrentItem",
    prefix_icon = " ",
  },
  sort_by_nesting_depth = true,
  call_hierarchy = {
    max_depth = 2, -- Default max depth
    max_depth_limit = 4, -- Hard limit to prevent performance issues
    show_cycles = false, -- Whether to show recursive calls
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
  impl = require("namu.namu_callhierarchy.callhierarchy")
  impl.update_config(M.config)
  impl_loaded = true
end

-- Setup just merges configs
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if impl_loaded and impl then
    impl.update_config(M.config)
  end
end

function M.get_impl()
  load_impl()
  return impl
end

-- Define API functions that lazy-load the implementation
function M.show(direction)
  load_impl()
  if not impl then
    return
  end
  return impl.show(direction)
end

function M.show_incoming_calls()
  load_impl()
  if not impl then
    return
  end
  return impl.show_incoming_calls()
end

function M.show_outgoing_calls()
  load_impl()
  if not impl then
    return
  end
  return impl.show_outgoing_calls()
end

function M.show_both_calls()
  load_impl()
  if not impl then
    return
  end
  return impl.show_both_calls()
end

function M.setup_keymaps()
  vim.keymap.set("n", "<leader>ci", M.show_incoming_calls, {
    desc = "Show incoming calls",
    silent = true,
  })

  vim.keymap.set("n", "<leader>co", M.show_outgoing_calls, {
    desc = "Show outgoing calls",
    silent = true,
  })

  vim.keymap.set("n", "<leader>cc", M.show_both_calls, {
    desc = "Show call hierarchy (both directions)",
    silent = true,
  })
end

return M
