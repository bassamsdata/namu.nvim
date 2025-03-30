local M = {}

-- Default configuration
M.config = {
  namu_symbols = { enable = true, options = {} },
  namu_ctags = { enable = false, options = {} },
  selecta = { enable = true, options = {} },
  colorscheme = { enable = false, options = {} },
  ui_select = { enable = false, options = {} },
  namu_callhierarchy = { enable = true, options = {} },
  namu_workspace = { enable = true, options = {} },
}

M.setup = function(opts)
  opts = opts or {}
  -- Merge the top-level config
  M.config = vim.tbl_deep_extend("force", M.config, opts)
  require("namu.core.highlights").setup()

  if M.config.namu_symbols.enable then
    require("namu.selecta.selecta").setup(M.config.namu_symbols.options)
    require("namu.namu_symbols").setup(M.config.namu_symbols.options)
  end

  if M.config.namu_ctags.enable then
    require("namu.namu_ctags").setup(M.config.namu_ctags.options)
  end

  if M.config.namu_callhierarchy.enable then
    require("namu.namu_callhierarchy").setup(M.config.namu_callhierarchy.options)
  end

  if M.config.namu_workspace.enable then
    require("namu.namu_workspace").setup(M.config.namu_workspace.options)
  end

  if M.config.colorscheme.enable then
    require("namu.colorscheme").setup(M.config.colorscheme.options)
  end

  if M.config.ui_select.enable then
    require("namu.ui_select").setup(M.config.ui_select.options)
  end
end

return M
