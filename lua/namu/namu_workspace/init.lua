local M = {}
-- TEST: Testing this new design to load the plugin lazely so doesn't affect neovim startup
-- Only load config (lightweight)
M.config = require("namu.namu_symbols.config").values
M.config = vim.tbl_deep_extend("force", M.config, {
  current_highlight = {
    enabled = true,
    hl_group = "NamuCurrentItem",
    prefix_icon = " ",
  },
  window = {
    min_width = 39,
    max_width = 75,
  },
})

-- Flag to track if implementation is loaded
local impl_loaded = false

-- Function to load the full implementation
local function load_impl()
  if impl_loaded then
    return
  end
  -- Load the actual implementation
  local impl = require("namu.namu_workspace.impl")
  -- Copy all implementation functions to the module
  for k, v in pairs(impl) do
    if type(v) == "function" then
      -- Create wrapper that passes config to implementation
      M[k] = function(...)
        return v(M.config, ...)
      end
    else
      M[k] = v
    end
  end
  impl_loaded = true
end

-- Setup just merges configs
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- Define API functions that lazy-load the implementation
function M.show(opts)
  load_impl()
  return M.show(opts) -- Now calls the implementation version
end

function M.show_with_query(query, opts)
  load_impl()
  return M.show_with_query(query, opts)
end

return M
