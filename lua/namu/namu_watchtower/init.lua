--[[ Namu Watchtower Buffers
Displays symbols from all open/valid buffers in a picker with preview.
Integrates with selecta for fuzzy finding and LSP for symbol handling.
]]

local M = {}

-- Import only the configuration dependency
M.config = require("namu.namu_symbols.config").values
local config_manager = require("namu.core.config_manager")

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
  impl = require("namu.namu_watchtower.watchtower")
  impl_loaded = true
end

function M.get_impl()
  load_impl()
  return impl
end

-- Function to resolve config from config manager if not already done
local function resolve_config()
  if not config_resolved then
    -- Get resolved config from config manager
    local resolved_config = config_manager.get_config("watchtower")
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

-- Define API function that lazy-loads the implementation
function M.show()
  -- Ensure config is resolved before showing
  resolve_config()
  load_impl()
  if not impl then
    return
  end
  -- Explicitly pass the config to the implementation
  return impl.show(M.config)
end

return M
