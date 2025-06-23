--[[ Namu Diagnostics 
Diagnostics picker with live preview and actions.
Integrates with selecta for fuzzy finding and magnet for symbol handling.
]]

local M = {}

local config_manager = require("namu.core.config_manager")

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
  impl = require("namu.namu_diagnostics.diagnostics")
  impl_loaded = true
end

-- Function to resolve config from config manager if not already done
local function resolve_config()
  if not config_resolved then
    -- Get resolved config from config manager
    local resolved_config = config_manager.get_config("diagnostics")
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
end

function M.get_impl()
  load_impl()
  return impl
end

-- Define API functions that lazy-load the implementation
function M.show(scope)
  resolve_config()
  load_impl()
  if not impl then
    return
  end
  return impl.show(M.config, scope)
end

function M.show_current_diagnostics()
  resolve_config()
  load_impl()
  if not impl then
    return
  end
  return impl.show_current_diagnostics(M.config)
end

function M.show_buffer_diagnostics()
  resolve_config()
  load_impl()
  if not impl then
    return
  end
  return impl.show_buffer_diagnostics(M.config)
end

function M.show_workspace_diagnostics()
  resolve_config()
  load_impl()
  if not impl then
    return
  end
  return impl.show_workspace_diagnostics(M.config)
end

return M
