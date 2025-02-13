local M = {}

M.setup = function(opts)
  opts = opts or {}
  require("selecta.namu.namu").setup(opts)
end
M.jump = function()
  require("selecta.namu.namu").show()
end

return M
