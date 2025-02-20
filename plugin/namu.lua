if vim.g.namu_loaded then
  return
end
vim.g.namu_loaded = true

-- Command documentation
local command_descriptions = {
  symbols = "Jump to location using namu functionality",
  colorscheme = "Select and apply colorscheme",
  -- zoxide = "Navigate using zoxide",
  help = "Show help for all commands",
}
-- Argument validators
local command_validators = {
  symbols = function(args)
    return #args == 0, "namu doesn't accept arguments"
  end,
  colorscheme = function(args)
    return #args == 0, "sel_colorscheme doesn't accept arguments"
  end,
}
local registry = {
  symbols = function(opts)
    require("namu.namu_symbols").show()
  end,
  ctags = function(opts)
    require("namu.namu_ctags").show()
  end,
  colorscheme = function(opts)
    require("namu.colorscheme").show()
  end,
  help = function()
    local help_text = "Selecta Commands:\n"
    for cmd, desc in pairs(command_descriptions) do
      help_text = help_text .. string.format("  %-15s%s\n", cmd, desc)
    end
    vim.notify(help_text, vim.log.levels.INFO)
  end,
}

local function command_callback(input)
  local subcommand = input.fargs[1]
  if not subcommand or subcommand == "" then
    vim.notify("Usage: Namu <subcommand> [args]\nTry 'Namu help' for more information", vim.log.levels.WARN)
    return
  end

  local cmd = registry[subcommand]
  if not cmd then
    vim.notify("Invalid subcommand: " .. subcommand, vim.log.levels.ERROR)
    return
  end

  -- Extract arguments
  local args = {}
  for i = 2, #input.fargs do
    table.insert(args, input.fargs[i])
  end

  -- Validate arguments if validator exists
  if command_validators[subcommand] then
    local is_valid, error_msg = command_validators[subcommand](args)
    if not is_valid then
      vim.notify("Invalid arguments for " .. subcommand .. ": " .. error_msg, vim.log.levels.ERROR)
      return
    end
  end

  -- Execute command
  local success, result = pcall(cmd, args)
  if not success then
    vim.notify("Error executing " .. subcommand .. ": " .. result, vim.log.levels.ERROR)
  end
end

local function command_complete(_, line, col)
  local _, _, prefix = string.find(line:sub(1, col), "%S+%s+(%S*)$")
  if not prefix then
    local completions = vim.tbl_keys(registry)
    return completions
  end

  local candidates = {}
  -- Match against commands
  for key, _ in pairs(registry) do
    if key:find(prefix, 1, true) then
      table.insert(candidates, key)
    end
  end
  table.sort(candidates)
  return candidates
end

vim.api.nvim_create_user_command("Namu", command_callback, {
  nargs = "+",
  complete = command_complete,
  desc = "Namu plugin command with subcommands. Use 'Selecta help' for more information",
})

require("namu").setup({})
