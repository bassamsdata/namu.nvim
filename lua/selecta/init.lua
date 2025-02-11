local M = {}

-- Default configuration
M.config = {
  magnet = { enable = true, options = {} },
  selecta = { enable = true, options = {} },
  selecta_colorscheme = { enable = false, options = {} },
  cc_codecompanion = { enable = false, options = {} },
  ui_select = { enable = true, options = {} },
}

M.setup = function(opts)
  opts = opts or {}
  -- Merge user config with defaults
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Load modules only if enabled
  if opts.magnet and M.config.magnet.enable then
    require("selecta.magnet").setup(M.config.magnet.options)
  end

  if M.config.selecta.enable then
    require("selecta.selecta").setup(M.config.selecta.options)
  end

  if M.config.selecta_colorscheme.enable then
    require("selecta.selecta_colorscheme")
  end

  if M.config.cc_codecompanion.enable then
    require("selecta.cc_codecompanion").setup(M.config.cc_codecompanion.options)
  end

  if M.config.ui_select.enable then
    require("selecta.ui_select").setup(M.config.ui_select.options)
  end
end

return M
