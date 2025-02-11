local selecta = require("selecta.selecta.selecta")

local M = {}

M.config = {
  title = "Select one of:",
  auto_select = false,
  window = {
    border = "rounded",
    title_prefix = "󰆤 ",
    show_footer = true,
    min_height = 1,
  },
  display = { mode = "raw" },
}

---@param items any[]
---@diagnostic disable-next-line: undefined-doc-name
---@param opts { prompt?: string, format_item?: fun(item: any): string, kind?: string }
---@param on_choice fun(item: any?, idx: number?)
function M.select(items, opts, on_choice)
  opts = opts or {}

  -- Convert items to SelectaItem format
  local selecta_items = {}
  for i, item in ipairs(items) do
    local formatted = (opts.format_item and opts.format_item(item)) or tostring(item)
    table.insert(selecta_items, {
      text = formatted,
      value = item,
      original_index = i, -- Store original index for callback
    })
  end

  -- Configure Selecta options
  local default_selecta_opts = {
    title = opts.prompt or M.config.title,
    auto_select = M.config.auto_select,
    window = M.config.window,
    display = M.config.display,
    on_select = function(selected)
      if selected then
        vim.schedule(function()
          on_choice(selected.value, selected.original_index)
        end)
      end
    end,
    on_cancel = function()
      on_choice(nil, nil)
    end,
  }
  local selecta_opts = vim.tbl_deep_extend("force", default_selecta_opts, opts.selecta_opts or {})

  -- Launch Selecta
  vim.schedule(function()
    selecta.pick(selecta_items, selecta_opts)
  end)
end

-- Replace the default vim.ui.select
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  vim.ui.select = M.select
end

return M
