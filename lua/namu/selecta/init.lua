local M = {}

M.setup = function(opts)
  print("\n[DEBUG] selecta/init.lua setup called with opts:", vim.inspect(opts))
  require("namu.selecta.selecta").setup(opts)
end

return M
