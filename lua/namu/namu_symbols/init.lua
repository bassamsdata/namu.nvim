local M = {}

M.setup = function(opts)
  opts = opts or {}
  require("namu.namu_symbols.namu").setup(opts)
end
M.show = function()
  require("namu.namu_symbols.namu").show()
end

return M
