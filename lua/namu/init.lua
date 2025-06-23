local M = {}
local config_manager = require("namu.core.config_manager")

-- Default configuration
M.config = {
  namu_symbols = { enable = true, options = {} },
  namu_ctags = { enable = false, options = {} },
  selecta = { enable = true, options = {} },
  callhierarchy = { enable = true, options = {} },
  workspace = { enable = true, options = {} },
  diagnostics = { enable = true, options = {} },
  watchtower = { enable = true, options = {} },
  colorscheme = { enable = false, options = {} },
  ui_select = { enable = false, options = {} },
}

M.setup = function(opts)
  opts = opts or {}
  -- Merge the top-level config
  M.config = vim.tbl_deep_extend("force", M.config, opts)

  -- Setup the config manager with user configuration
  config_manager.setup(M.config)

  require("namu.core.highlights").setup()

  if config_manager.is_module_enabled("namu_symbols") then
    local symbol_config = config_manager.get_config("namu_symbols")
    require("namu.selecta").setup(symbol_config)
    require("namu.namu_symbols").setup() -- No options, will use config manager
  end

  if config_manager.is_module_enabled("namu_ctags") then
    local ctags_config = config_manager.get_config("namu_ctags")
    require("namu.namu_ctags").setup(ctags_config)
  end

  if config_manager.is_module_enabled("callhierarchy") then
    local callhierarchy_config = config_manager.get_config("callhierarchy")
    require("namu.namu_callhierarchy").setup(callhierarchy_config)
  end

  if config_manager.is_module_enabled("workspace") then
    local workspace_config = config_manager.get_config("workspace")
    require("namu.namu_workspace").setup(workspace_config)
  end

  if config_manager.is_module_enabled("watchtower") then
    local watchtower_config = config_manager.get_config("watchtower")
    require("namu.namu_watchtower").setup(watchtower_config)
  end

  if config_manager.is_module_enabled("diagnostics") then
    local diagnostics_config = config_manager.get_config("diagnostics")
    require("namu.namu_diagnostics").setup(diagnostics_config)
  end

  if config_manager.is_module_enabled("colorscheme") then
    local colorscheme_config = config_manager.get_config("colorscheme")
    require("namu.colorscheme").setup(colorscheme_config)
  end

  if config_manager.is_module_enabled("ui_select") then
    local ui_select_config = config_manager.get_config("ui_select")
    require("namu.ui_select").setup(ui_select_config)
  end
end

return M
