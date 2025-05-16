local M = {}
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
  require("namu.core.highlights").setup()

  if M.config.namu_symbols.enable then
    require("namu.selecta").setup(M.config.namu_symbols.options)
    require("namu.namu_symbols").setup(M.config.namu_symbols.options)
  end

  if M.config.namu_ctags.enable then
    require("namu.namu_ctags").setup(M.config.namu_ctags.options)
  end

  if M.config.callhierarchy.enable then
    require("namu.namu_callhierarchy").setup(M.config.callhierarchy.options)
  end

  if M.config.workspace.enable then
    require("namu.namu_workspace").setup(M.config.workspace.options)
  end

  if M.config.watchtower.enable then
    require("namu.namu_watchtower").setup(M.config.watchtower.options)
  end

  if M.config.diagnostics.enable then
    require("namu.namu_diagnostics").setup(M.config.diagnostics.options)
  end

  if M.config.colorscheme.enable then
    require("namu.colorscheme").setup(M.config.colorscheme.options)
  end

  if M.config.ui_select.enable then
    require("namu.ui_select").setup(M.config.ui_select.options)
  end
end

return M
