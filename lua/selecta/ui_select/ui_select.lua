local selecta = require("selecta.selecta.selecta")

local M = {}

---@param items any[]
---@diagnostic disable-next-line: undefined-doc-name
---@param opts { prompt?: string, format_item?: fun(item: any): string, kind?: string }
---@param on_choice fun(item: any?, idx: number?)
function M.select(items, opts, on_choice)
  opts = opts or {}

  -- Add cursor preservation wrapper
  -- local original_guicursor = vim.o.guicursor
  -- local function ensure_restore()
  --   print("2: guicursor", vim.o.guicursor)
  --   print("3: original_guicursor", original_guicursor)
  --   if vim.o.guicursor == "a:SelectaCursor" then
  --     vim.schedule(function()
  --       vim.o.guicursor = original_guicursor
  --     end)
  --   end
  -- end

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
  local selecta_opts = {
    title = opts.prompt or "Select one of:",
    auto_select = true,
    window = {
      border = "rounded",
      title_prefix = "󰆤 ",
      show_footer = true,
      min_height = 1,
    },
    display = { mode = "raw" },
    on_select = function(selected)
      if selected then
        -- ensure_restore()
        vim.schedule(function()
          on_choice(selected.value, selected.original_index)
        end)
      end
    end,
    on_cancel = function()
      -- ensure_restore()
      on_choice(nil, nil)
    end,
  }

  -- Launch Selecta
  vim.schedule(function()
    selecta.pick(selecta_items, selecta_opts)
  end)
end

-- Replace the default vim.ui.select
function M.setup()
  vim.ui.select = M.select
end

return M
