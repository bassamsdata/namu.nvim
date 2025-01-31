if vim.g.selecta_loaded then
	return
end
vim.g.selecta_loaded = true

require("selecta").setup({})
