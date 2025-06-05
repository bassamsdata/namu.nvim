--[[ namu.lua
Quick LSP symbol jumping with live preview and fuzzy finding.

Features:
- Fuzzy find LSP symbols
- Live preview as you move
- Auto-sized window
- Filtered by symbol kinds
- Configurable exclusions


-- Configure Namu 
require('namu').setup({
    -- Optional: Override default config
    includeKinds = {
        -- Add custom kinds per filetype
        python = { "Function", "Class", "Method" },
    },
    window = {
        auto_size = true,
        min_width = 50,
        padding = 2,
    },
    -- Custom highlight for preview
    highlight = "NamuPreview",
})

-- set your own keymap
vim.keymap.set('n', 'gs', require('namu').jump, {
    desc = "Jump to symbol"
})
]]

local M = {}

local config = require("namu.namu_symbols.config")

---@NamuSymbolsConfig
M.config = config.values
M.config = vim.tbl_deep_extend("force", M.config, {
  enhance_lua_test_symbols = true,
  lua_test_truncate_length = 50,
  lua_test_preserve_hierarchy = true,
  source_priority = "lsp", -- Options: "lsp", "treesitter"
})

-- Flag to track if implementation is loaded
local impl_loaded = false
local impl = nil

-- Function to load the full implementation
local function load_impl()
  if impl_loaded then
    return
  end
  impl = require("namu.namu_symbols.symbols")
  impl_loaded = true
end

function M.get_impl()
  load_impl()
  return impl
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- Define API function that lazy-loads the implementation
function M.show(opts)
  load_impl()
  if not impl then
    return
  end
  return impl.show(M.config, opts)
end

function M.show_treesitter(opts)
  load_impl()
  if not impl then
    return
  end
  return impl.show_treesitter(M.config, opts)
end

-- Expose test utilities if implementation is loaded
function M._test()
  load_impl()
  if not impl then
    return {}
  end
  return impl._test
end

return M
