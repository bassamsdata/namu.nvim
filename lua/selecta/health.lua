local M = {}

local start = vim.health.start or vim.health.report_start
local ok = vim.health.ok or vim.health.report_ok
local info = vim.health.info or vim.health.report_info
local warn = vim.health.warn or vim.health.report_warn
local error = vim.health.error or vim.health.report_error
local validate_picker_options = require("selecta.validate").validate_picker_options

local function validate_config()
  local user_config = require("selecta").config.namu.options
  local is_valid, issues = validate_picker_options(user_config)
  if is_valid then
    ok("Selecta User configuration is valid")
  else
    for _, issue in ipairs(issues) do
      if issue.level == "error" then
        error(issue.msg)
      elseif issue.level == "warn" then
        warn(issue.msg)
      else
        info(issue.msg)
      end
    end
  end
end

function M.check()
  start("Selecta Health Check")

  -- Check Neovim version
  if vim.fn.has("nvim-0.10") == 0 then
    error("Selecta requires Neovim 0.10+")
  else
    ok("Neovim version is compatible")
  end

  info("===Selecta Health Check===")
  -- Validate user config
  validate_config()

  -- TODO: check lsp capabilities

  -- TODO: check namu options
end

return M
