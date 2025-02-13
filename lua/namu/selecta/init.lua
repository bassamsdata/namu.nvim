local M = {}

M.setup = function(opts)
  opts = opts or {}
  require("namu.selecta.selecta").setup(opts)
end

return M
