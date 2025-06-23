--[[ namu.lua
Quick LSP symbol jumping with live preview and fuzzy finding.

Features:
- Fuzzy find LSP symbols
- Live preview as you move
- Auto-sized window
- Filtered by symbol kinds
- Configurable exclusions


-- Configure Namu 
require('namu').setup({
    -- Optional: Override default config
    includeKinds = {
        -- Add custom kinds per filetype
        python = { "Function", "Class", "Method" },
    },
    window = {
        auto_size = true,
        min_width = 50,
        padding = 2,
    },
    -- Custom highlight for preview
    highlight = "NamuPreview",
})

-- set your own keymap
vim.keymap.set('n', 'gs', require('namu').jump, {
    desc = "Jump to symbol"
})
]]

local M = {}

local config = require("namu.namu_symbols.config")
local config_manager = require("namu.core.config_manager")

---@NamuSymbolsConfig
M.config = config.values

-- Flag to track if config has been resolved from config manager
local config_resolved = false

-- Flag to track if implementation is loaded
local impl_loaded = false
local impl = nil

-- Function to load the full implementation
local function load_impl()
  if impl_loaded then
    return
  end
  impl = require("namu.namu_symbols.symbols")
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
    local resolved_config = config_manager.get_config("namu_symbols")
    -- Merge with existing module-specific config
    M.config = vim.tbl_deep_extend("force", M.config, resolved_config)
    config_resolved = true
  end
end

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
function M.show(opts)
  -- Ensure config is resolved before showing
  resolve_config()
  load_impl()
  if not impl then
    return
  end
  return impl.show(M.config, opts)
end

function M.show_treesitter(opts)
  -- Ensure config is resolved before showing
  resolve_config()
  load_impl()
  if not impl then
    return
  end
  return impl.show_treesitter(M.config, opts)
end

-- Expose test utilities if implementation is loaded
function M._test()
  load_impl()
  if not impl then
    return {}
  end
  return impl._test
end

return M
