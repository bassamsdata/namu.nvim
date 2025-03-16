local M = {}

local start = vim.health.start or vim.health.report_start
local ok = vim.health.ok or vim.health.report_ok
local info = vim.health.info or vim.health.report_info
local warn = vim.health.warn or vim.health.report_warn
local error = vim.health.error or vim.health.report_error
local validate_picker_options = require("namu.validate").validate_picker_options

local function validate_config()
  local user_config = require("namu").config.namu_symbols.options
  local is_valid, issues = validate_picker_options(user_config)
  if is_valid then
    ok("Namu User configuration is valid")
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
  start("Namu Health Check")

  -- Check Neovim version
  if vim.fn.has("nvim-0.10") == 0 then
    error("Namu requires Neovim 0.10+")
  else
    ok("Neovim version is compatible")
  end

  -- Check TreeSitter
  if not vim.treesitter.highlighter then
    error("TreeSitter not available")
  else
    ok("TreeSitter is available")
  end

  -- Check LSP
  local active_clients = vim.lsp.get_clients()
  if #active_clients == 0 then
    warn("No LSP clients attached")
  else
    -- Group clients by name for better reporting
    local client_info = {}
    for _, client in ipairs(active_clients) do
      local name = client.name
      client_info[name] = (client_info[name] or 0) + 1
    end

    local client_list = {}
    for name, count in pairs(client_info) do
      table.insert(client_list, string.format("%s(%d)", name, count))
    end
    ok(string.format("Found %d LSP client(s): %s", #active_clients, table.concat(client_list, ", ")))

    -- Check document_symbol support
    local has_symbol_support = false
    for _, client in ipairs(active_clients) do
      if client.server_capabilities.documentSymbolProvider then
        has_symbol_support = true
        break
      end
    end

    if has_symbol_support then
      ok("Found LSP client(s) with document symbol support")
    else
      warn("No LSP clients with document symbol support found")
    end
  end
  -- Check CTags if enabled
  if require("namu").config.namu_ctags.enable then
    local ctags = vim.fn.executable("ctags")
    if ctags == 0 then
      error("CTags not found in PATH")
    else
      local version = vim.fn.system("ctags --version")
      if version:match("Universal Ctags") then
        ok("Universal CTags found")
      else
        warn("Found CTags but not Universal CTags (recommended)")
      end
    end
  end

  info("===Namu Configuration Check===")
  -- Validate user config
  validate_config()
end

return M
