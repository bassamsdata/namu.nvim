local M = {}
local config = require("namu.selecta.selecta_config")
local logger = require("namu.utils.logger")

function M.setup(opts)
  opts = opts or {}
  config.values = vim.tbl_deep_extend("force", config.defaults, opts)
  logger.setup({ debug = config.values.debug })
end

return M
