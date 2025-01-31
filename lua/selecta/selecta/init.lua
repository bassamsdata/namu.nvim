local M = {}

M.setup = function(opts)
	opts = opts or {}
	require("selecta.selecta.selecta").setup(opts)
end

return M
