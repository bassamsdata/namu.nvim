local M = {}
local common = require("namu.selecta.common")

function M.setup(opts)
  opts = opts or {}
  common.config = vim.tbl_deep_extend("force", common.config, opts)
end

return M
