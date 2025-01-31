-- Add current directory to runtimepath
vim.cmd([[let &rtp.=','.getcwd()]])

vim.cmd("set rtp+=./deps/nvim-treesitter")
-- add parent directory to package.path to find selecta.lua
package.path = package.path .. ";" .. vim.fn.getcwd() .. "/?.lua"

-- Set up 'mini.test' only when calling headless Neovim
if #vim.api.nvim_list_uis() == 0 then
	-- Add mini.nvim to runtimepath
	vim.cmd("set rtp+=deps/mini.nvim")

	-- Set up mini.test
	require("mini.test").setup({})
end
