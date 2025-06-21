local M = {}
local log = require("namu.utils.logger").log
M.config = require("namu.namu_symbols.config").values
M.config = vim.tbl_deep_extend("force", M.config, {
  current_highlight = {
    enabled = true,
    hl_group = "NamuCurrentItem",
    prefix_icon = " ",
  },
  window = {
    min_width = 50,
    max_width = 75,
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
  impl = require("namu.namu_workspace.impl")
  impl_loaded = true
end

-- Function to get the implementation module
function M.get_impl()
  load_impl()
  return impl
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

function M.show_with_query(query, opts)
  load_impl()
  if not impl then
    return
  end
  return impl.show_with_query(M.config, query, opts)
end

return M
