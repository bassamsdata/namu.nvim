local M = {}

M.setup = function(opts)
  opts = opts or {}
  require("namu.ui_select.ui_select").setup()
end

return M
