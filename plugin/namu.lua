if vim.g.namu_loaded then
  return
end
---@diagnostic disable-next-line: inject-field
vim.g.namu_loaded = true
local api = vim.api

-- Command documentation
---@type table<string, string>
local command_descriptions = {
  symbols = "Jump to location using namu functionality",
  ctags = "Show ctags symbols (use 'ctags open' for symbols from all open buffers)",
  colorscheme = "Select and apply colorscheme",
  call = "Show call hierarchy (use 'call in', 'call out', or 'call both')",
  workspace = "Search workspace symbols with LSP",
  treesitter = "Show symbols using Treesitter",
  diagnostics = "Show diagnostics for current buffer (use 'diagnostics workspace' for workspace diagnostics)",
  open = "Show symbols from all open buffers",
  help = "Show help information (use 'help symbols' or 'help analysis' for detailed views)",
}
-- Argument validators
---@type table<string, fun(args: string[]): boolean, string?>
local command_validators = {
  symbols = function(args)
    if #args > 1 then
      return false, "symbols command accepts only one optional argument for type"
    end
    if #args == 1 then
      local valid_types = {
        ["function"] = true,
        ["variable"] = true,
        ["class"] = true,
        ["method"] = true,
        ["interface"] = true,
        ["enum"] = true,
        ["struct"] = true,
        ["constant"] = true,
        ["property"] = true,
        ["field"] = true,
        ["constructor"] = true,
        ["namespace"] = true,
        ["package"] = true,
        ["module"] = true,
        ["parameter"] = true,
        ["typeParameter"] = true,
        ["event"] = true,
        ["operator"] = true,
      }
      ---@diagnostic disable-next-line: undefined-field
      if not valid_types[args[1]:lower()] then
        return false, "invalid symbol type. valid types: function, variable, class, method"
      end
    end
    return true
  end,
  colorscheme = function(args)
    return #args == 0, "sel_colorscheme doesn't accept arguments"
  end,
  call = function(args)
    if #args ~= 1 then
      return false, "call command requires one argument: 'in', 'out', or 'both'"
    end
    local valid_types = { ["in"] = true, out = true, both = true }
    if not valid_types[args[1]:lower()] then
      return false, "invalid call type. Valid types: in, out, both"
    end
    return true
  end,
  workspace = function(args)
    return #args <= 1, "workspace command accepts an optional search query"
  end,
  diagnostics = function(args)
    local valid_types = { workspace = true, buffers = true }
    if #args > 1 then
      return false, "diagnostics command accepts only one optional argument (workspace or buffers)"
    end
    if #args == 1 and not valid_types[args[1]:lower()] then
      return false, "invalid diagnostics type. Valid types: workspace, buffers"
    end
    return true
  end,
  ctags = function(args)
    if #args > 1 then
      return false, "ctags command accepts only one optional argument (watchtower)"
    end
    if #args == 1 and args[1]:lower() ~= "watchtower" then
      return false, "invalid ctags type. Valid type: watchtower"
    end
    return true
  end,
  watchtower = function(args)
    return #args == 0, "watchtower command doesn't accept arguments"
  end,
  treesitter = function(args)
    return #args == 0, "Treesitter doesn't currently accept arguments"
  end,
  help = function(args)
    if #args > 1 then
      return false, "help command accepts only one optional argument (symbols/analysis)"
    end
    if #args == 1 then
      local valid_help = { symbols = true, analysis = true }
      ---@diagnostic disable-next-line: undefined-field
      if not valid_help[args[1]:lower()] then
        return false, "invalid help type. Valid types: symbols, analysis"
      end
    end
    return true
  end,
}

---@type table<string, function>
local registry = {
  symbols = function(args)
    if #args == 0 then
      require("namu.namu_symbols").show()
    else
      local type_map = {
        ["function"] = "Function",
        ["variable"] = "Variable",
        ["class"] = "Class",
        ["method"] = "Method",
        ["interface"] = "Interface",
        ["enum"] = "Enum",
        ["struct"] = "Struct",
        ["constant"] = "Constant",
        ["property"] = "Property",
        ["field"] = "Field",
        ["constructor"] = "Constructor",
        ["namespace"] = "Namespace",
        ["package"] = "Package",
        ["module"] = "Module",
        ["parameter"] = "Parameter",
        ["typeParameter"] = "TypeParameter",
        ["event"] = "Event",
        ["operator"] = "Operator",
      }
      local symbol_type = type_map[args[1]:lower()]
      require("namu.namu_symbols").show({ filter_kind = symbol_type })
    end
  end,
  ctags = function(args)
    if #args == 0 then
      require("namu.namu_ctags").show()
    else
      require("namu.namu_watchtower.ctags").show()
    end
  end,
  colorscheme = function(opts)
    require("namu.colorscheme").show()
  end,
  call = function(args)
    local call_type = args[1]:lower()
    if call_type == "in" then
      require("namu.namu_callhierarchy").show_incoming_calls()
    elseif call_type == "out" then
      require("namu.namu_callhierarchy").show_outgoing_calls()
    elseif call_type == "both" then
      require("namu.namu_callhierarchy").show_both_calls()
    end
  end,
  workspace = function(args)
    local query = args[1] or ""
    require("namu.namu_workspace").show_with_query(query)
  end,
  diagnostics = function(args)
    if #args == 0 then
      require("namu.namu_diagnostics").show()
    else
      local diag_module = require("namu.namu_diagnostics")
      if args[1] == "workspace" then
        diag_module.show_workspace_diagnostics()
      elseif args[1] == "buffers" then
        diag_module.show("buffers")
      else
        diag_module.show(args[1])
      end
    end
  end,
  watchtower = function(args)
    require("namu.namu_watchtower").show()
  end,
  treesitter = function(args)
    require("namu.namu_symbols").show_treesitter()
  end,
  help = function(args)
    if #args == 0 then
      -- Show general help
      local help_text = "# Namu Help\n\n"
      help_text = help_text .. "## Commands\n"
      for cmd, desc in pairs(command_descriptions) do
        help_text = help_text .. string.format("  %-15s%s\n", cmd, desc)
      end
      help_text = help_text .. "\n## Symbol Types\n"
      help_text = help_text .. "  function    Show only functions\n"
      help_text = help_text .. "  variable    Show only variables\n"
      help_text = help_text .. "  class       Show only classes\n"
      help_text = help_text .. "\n## Help Types\n"
      help_text = help_text .. "  symbols     Show detailed symbol filtering help\n"
      help_text = help_text .. "  analysis    Show symbol analysis for current buffer\n"
      -- Calculate the width based on the longest line of text
      local lines = vim.split(help_text, "\n")
      local max_line_width = 0
      for _, line in ipairs(lines) do
        max_line_width = math.max(max_line_width, api.nvim_strwidth(line))
      end
      local width = max_line_width + 4 -- Add some padding
      -- Ensure width doesn't go off screen (subtract 10 for padding/borders)
      local ui = api.nvim_list_uis()[1]
      width = math.min(width, ui.width - 10)
      local height = #lines + 2
      local bufnr = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
      api.nvim_set_option_value("filetype", "markdown", { buf = bufnr })
      api.nvim_set_option_value("modifiable", false, { buf = bufnr })
      api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
      -- Calculate window position
      local row = math.floor((ui.height - height) / 2)
      local col = math.floor((ui.width - width) / 2)
      local opts = {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        -- this is borrored from @mini.nvim, thanks :), it's for >= 0.11
        border = (vim.fn.exists("+winborder") == 1 and vim.o.winborder ~= "") and vim.o.winborder or "rounded",
        title = "󱠦  Namu Help",
        title_pos = "center",
      }
      local _ = api.nvim_open_win(bufnr, true, opts)
      api.nvim_buf_set_keymap(bufnr, "n", "q", ":close<CR>", { noremap = true, silent = true })
      api.nvim_buf_set_keymap(bufnr, "n", "<Esc>", ":close<CR>", { noremap = true, silent = true })
      return
    end

    local help_type = args[1]:lower()
    if help_type == "symbols" then
      require("namu.namu_symbols.helpers").create_help_buffer()
    elseif help_type == "analysis" then
      require("namu.namu_symbols.helpers").create_analysis_buffer()
    end
  end,
}

---@param input { fargs: string[] }
local function command_callback(input)
  local subcommand = input.fargs[1]
  if not subcommand or subcommand == "" then
    vim.notify(
      "Usage: Namu <subcommand> [args]\nTry 'Namu help' for more information",
      vim.log.levels.WARN,
      { title = "Namu" }
    )
    return
  end

  local cmd = registry[subcommand]
  if not cmd then
    vim.notify("Invalid subcommand: " .. subcommand, vim.log.levels.ERROR, { title = "Namu" })
    return
  end

  local args = {}
  for i = 2, #input.fargs do
    table.insert(args, input.fargs[i])
  end

  if command_validators[subcommand] then
    local is_valid, error_msg = command_validators[subcommand](args)
    if not is_valid then
      vim.notify("Invalid arguments for " .. subcommand .. ": " .. error_msg, vim.log.levels.ERROR, { title = "Namu" })
      return
    end
  end

  local success, result = pcall(cmd, args)
  if not success then
    vim.notify("Error executing " .. subcommand .. ": " .. result, vim.log.levels.ERROR, { title = "Namu" })
  end
end

---@param _ any
---@param line string
---@param col number
---@return string[]
local function command_complete(_, line, col)
  ---@diagnostic disable-next-line: undefined-field
  local words = vim.split(line:sub(1, col), "%s+")

  if #words <= 2 then
    local completions = vim.tbl_keys(registry)
    return completions
  end

  if words[2] == "symbols" then
    -- stylua: ignore start 
    local symbol_types = {
      "function", "variable", "class", "method", "interface", "enum",
      "struct", "constant", "property", "field", "constructor", "namespace",
      "package", "module", "parameter", "typeParameter", "event", "operator",
    }
    -- stylua: ignore end
    local prefix = words[3] or ""
    local candidates = vim.tbl_filter(function(type)
      ---@diagnostic disable-next-line: undefined-field
      return vim.startswith(type, prefix:lower())
    end, symbol_types)
    return candidates
  end
  if words[2] == "call" then
    local call_types = { "in", "out", "both" }
    local prefix = words[3] or ""
    return vim.tbl_filter(function(type)
      return vim.startswith(type, prefix:lower())
    end, call_types)
  end
  if words[2] == "ctags" then
    local ctags_types = { "watchtower" }
    local prefix = words[3] or ""
    return vim.tbl_filter(function(type)
      return vim.startswith(type, prefix:lower())
    end, ctags_types)
  end
  if words[2] == "help" then
    local help_types = { "symbols", "analysis" }
    local prefix = words[3] or ""
    return vim.tbl_filter(function(type)
      ---@diagnostic disable-next-line: undefined-field
      return vim.startswith(type, prefix:lower())
    end, help_types)
  end
  if words[2] == "diagnostics" then
    local diag_types = { "workspace", "buffers" }
    local prefix = words[3] or ""
    return vim.tbl_filter(function(type)
      return vim.startswith(type, prefix:lower())
    end, diag_types)
  end

  return {}
end

api.nvim_create_user_command("Namu", command_callback, {
  nargs = "+",
  complete = command_complete,
  desc = "Namu plugin command with subcommands. Use 'Namu help' for more information",
})
