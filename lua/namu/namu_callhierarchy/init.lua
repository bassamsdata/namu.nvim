--[[ Namu Call Hierarchy
A call hierarchy browser that shows incoming and outgoing function calls.
Integrates with selecta for fuzzy finding and navigation.
]]

local M = {}

local config_manager = require("namu.core.config_manager")

-- Inherit defaults from symbols config
M.config = require("namu.namu_symbols.config").values

-- Flag to track if implementation is loaded
local impl_loaded = false
local impl = nil

-- Flag to track if config has been resolved from config manager
local config_resolved = false

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

-- Function to resolve config from config manager if not already done
local function resolve_config()
  if not config_resolved then
    -- Get resolved config from config manager
    local resolved_config = config_manager.get_config("callhierarchy")
    -- Merge with existing module-specific config
    M.config = vim.tbl_deep_extend("force", M.config, resolved_config)
    config_resolved = true
  end
end

-- Setup just merges configs
function M.setup(opts)
  if opts then
    -- BACKWARD COMPATIBILITY: Direct setup with options (old style)
    M.config = vim.tbl_deep_extend("force", M.config, opts)
    config_resolved = true -- Mark as resolved to prevent double-application
  else
    -- NEW STYLE: Config comes from config manager
    resolve_config()
  end
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
  resolve_config()
  load_impl()
  if not impl then
    return
  end
  return impl.show(direction)
end

function M.show_incoming_calls()
  resolve_config()
  load_impl()
  if not impl then
    return
  end
  return impl.show_incoming_calls()
end

function M.show_outgoing_calls()
  resolve_config()
  load_impl()
  if not impl then
    return
  end
  return impl.show_outgoing_calls()
end

function M.show_both_calls()
  resolve_config()
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
