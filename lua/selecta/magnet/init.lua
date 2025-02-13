local M = {}

M.setup = function(opts)
  opts = opts or {}
  require("selecta.magnet.magnet_enhanced").setup(opts)
end
M.jump = function()
  require("selecta.magnet.magnet_enhanced").show()
end

return M
