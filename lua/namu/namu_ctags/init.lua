local M = {}
-- TEST: Testing this new design to load the plugin lazily so it doesn't affect neovim startup
-- Only load config (lightweight)
M.config = require("namu.namu_symbols.config").values
M.config = vim.tbl_deep_extend("force", M.config, {
  current_highlight = {
    enabled = true,
    hl_group = "NamuCurrentItem",
    prefix_icon = " ",
  },
})

-- Flag to track if implementation is loaded
local impl_loaded = false
local impl = nil

-- Function to load the full implementation
local function load_impl()
  if impl_loaded then
    return
  end
  -- Load the actual implementation
  impl = require("namu.namu_ctags.ctags")
  impl_loaded = true
end

-- Setup just merges configs
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- Define API functions that lazy-load the implementation
function M.show(opts)
  load_impl()
  if not impl then
    return
  end
  return impl.show(M.config, opts)
end

-- Expose test functionality but with lazy loading
M._test = setmetatable({}, {
  __index = function(_, key)
    load_impl()
    if not impl then
      return
    end
    return impl._test[key]
  end,
})

return M
