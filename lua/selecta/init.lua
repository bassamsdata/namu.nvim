local M = {}

-- Default configuration
M.config = {
	magnet = { enable = true, options = {} },
	selecta = { enable = true, options = {} },
	selecta_colorscheme = { enable = false, options = {} },
	cc_codecompanion = { enable = false, options = {} },
}

M.setup = function(user_config)
	-- Merge user config with defaults
	M.config = vim.tbl_deep_extend("force", M.config, user_config or {})

	-- Load modules only if enabled
	if M.config.magnet.enable then
		require("selecta.magnet").setup(M.config.magnet.options)
	end

	if M.config.selecta.enable then
		require("selecta.selecta").setup(M.config.selecta.options)
	end

	if M.config.selecta_colorscheme.enable then
		require("my_plugin.selecta_colorscheme").setup(M.config.selecta_colorscheme.options)
	end

	if M.config.cc_codecompanion.enable then
		require("selecta.cc_codecompanion").setup(M.config.cc_codecompanion.options)
	end
end

return M
