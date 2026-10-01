local parser_dir = vim.fn.getcwd() .. "/deps/nvim-treesitter"
vim.opt.runtimepath:prepend(parser_dir)
require("nvim-treesitter.configs").setup({ parser_install_dir = parser_dir })
vim.cmd("runtime plugin/nvim-treesitter.lua")
vim.cmd("TSInstallSync! lua")
assert(vim.fn.filereadable(parser_dir .. "/parser/lua.so") == 1, "Failed to install the Lua test parser")
assert(pcall(vim.treesitter.language.add, "lua"), "Failed to load the Lua test parser")
