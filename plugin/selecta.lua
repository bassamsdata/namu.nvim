if vim.g.namu_loaded then
  return
end
vim.g.namu_loaded = true

-- Command documentation
local command_descriptions = {
  namu = "Jump to location using namu functionality",
  -- selecta = "Open the selecta picker",
  colorscheme = "Select and apply colorscheme",
  -- zoxide = "Navigate using zoxide",
  help = "Show help for all commands",
}
-- Command aliases
-- local command_aliases = {
--   mg = "namu",
--   sel = "selecta",
--   sc = "sel_colorscheme",
--   z = "zoxide",
-- }
-- Argument validators
local command_validators = {
  namu = function(args)
    return #args == 0, "namu doesn't accept arguments"
  end,
  colorscheme = function(args)
    return #args == 0, "sel_colorscheme doesn't accept arguments"
  end,
  -- zoxide = function(args)
  --   return #args <= 1, "zoxide accepts at most one path argument"
  -- end,
}
local registry = {
  namu = function(opts)
    require("namu.namu").jump()
  end,
  colorscheme = function(opts)
    -- Example: run a colorscheme picker function from the sel_colorscheme module.
    require("namu.colorscheme").show()
  end,
  -- zoxide = function(opts)
  --   -- Example: call zoxide functionality from its module.
  --   require("selecta.zoxide").jump()
  -- end,
  help = function()
    local help_text = "Selecta Commands:\n"
    for cmd, desc in pairs(command_descriptions) do
      local aliases = ""
      -- Find aliases for this command
      -- for alias, original in pairs(command_aliases) do
      --   if original == cmd then
      --     aliases = string.format(" (alias: %s)", alias)
      --     break
      --   end
      -- end
      help_text = help_text .. string.format("  %-15s%s%s\n", cmd, desc, aliases)
    end
    vim.notify(help_text, vim.log.levels.INFO)
  end,
}

-- local function resolve_alias(cmd)
--   return command_aliases[cmd] or cmd
-- end

local function command_callback(input)
  local subcommand = input.fargs[1]
  if not subcommand or subcommand == "" then
    vim.notify("Usage: Namu <subcommand> [args]\nTry 'Namu help' for more information", vim.log.levels.WARN)
    return
  end

  -- Resolve alias if it exists
  -- subcommand = resolve_alias(subcommand)

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
    -- Return both commands and aliases
    local completions = vim.tbl_keys(registry)
    -- for alias, _ in pairs(command_aliases) do
    --   table.insert(completions, alias)
    -- end
    return completions
  end

  local candidates = {}
  -- Match against commands
  for key, _ in pairs(registry) do
    if key:find(prefix, 1, true) then
      table.insert(candidates, key)
    end
  end
  -- Match against aliases
  -- for alias, _ in pairs(command_aliases) do
  --   if alias:find(prefix, 1, true) then
  --     table.insert(candidates, alias)
  --   end
  -- end
  table.sort(candidates)
  return candidates
end

vim.api.nvim_create_user_command("Namu", command_callback, {
  nargs = "+",
  complete = command_complete,
  desc = "Namu plugin command with subcommands. Use 'Selecta help' for more information",
})

require("namu").setup({})
