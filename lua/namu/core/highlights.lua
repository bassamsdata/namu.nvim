local M = {}
local hl_groups = {}

-- Thanks to @nvim-snacks for this one
-- Simple function to set highlights and remember them for ColorScheme events
function M.set_highlights(groups, opts)
  opts = opts or {}
  for name, def in pairs(groups) do
    -- Apply any prefix
    local hl_name = opts.prefix and (opts.prefix .. name) or name
    -- Convert string to link definition
    local hl_def = type(def) == "string" and { link = def } or def
    if opts.default ~= false then
      hl_def.default = true
    end
    hl_groups[hl_name] = hl_def
    vim.api.nvim_set_hl(0, hl_name, hl_def)
  end
end

-- Get foreground color from a highlight group (handles links)
local function get_fg_color(group_name)
  local hl = vim.api.nvim_get_hl(0, { name = group_name, link = false })
  if hl.fg then
    return hl.fg
  end
  local linked_hl = vim.api.nvim_get_hl(0, { name = group_name })
  if linked_hl.link then
    local resolved_hl = vim.api.nvim_get_hl(0, { name = linked_hl.link, link = false })
    return resolved_hl.fg
  end
  return nil
end

-- Get background color from a highlight group (handles links)
local function get_bg_color(group_name)
  local hl = vim.api.nvim_get_hl(0, { name = group_name, link = false })
  if hl.bg then
    return hl.bg
  end

  -- If no bg found, try to resolve link
  local linked_hl = vim.api.nvim_get_hl(0, { name = group_name })
  if linked_hl.link then
    local resolved_hl = vim.api.nvim_get_hl(0, { name = linked_hl.link, link = false })
    return resolved_hl.bg
  end

  return nil
end

function M.create_combined_highlight(fg_group, bg_group, result_group, opts)
  opts = opts or {}
  local fg_color = get_fg_color(fg_group)
  local bg_color = get_bg_color(bg_group)

  local combined_hl = {}
  if fg_color then
    combined_hl.fg = fg_color
  end
  if bg_color then
    combined_hl.bg = bg_color
  end

  -- Apply additional styling options
  for key, value in pairs(opts) do
    if key ~= "fg" and key ~= "bg" then -- Don't override fg/bg from groups
      combined_hl[key] = value
    end
  end

  M.set_highlights({ [result_group] = combined_hl })
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("NamuHighlights", { clear = true }),
  callback = function()
    -- Re-apply all stored highlights
    for name, def in pairs(hl_groups) do
      vim.api.nvim_set_hl(0, name, def)
    end
    M.create_combined_highlight("Special", "NamuCurrentItem", "NamuCurrentItemIcon", { bold = true })
    M.create_combined_highlight("Error", "NamuCurrentItem", "NamuCurrentItemIconSelection", { bold = true })
  end,
})

-- Initialize all Namu highlights
function M.setup()
  -- Namu Core
  M.set_highlights({
    NamuCursor = { blend = 100, nocombine = true },
    NamuPrefix = "Special",
    NamuSourceIndicator = "Ignore",
    NamuMatch = "Identifier", -- the matched characters in items
    NamuFilter = "Type", -- the prefix in prompt window
    NamuPrompt = "FloatTitle", -- Prompt window
    NamuSelected = "Statement", -- Selected item in selection mode
    NamuEmptyIndicator = "Comment", -- Empty selection indicator
    NamuFooter = "Comment", -- Footer text
    NamuCurrentItem = "CursorLine", -- Highlight the current item
    -- NamuCurrentItemIcon = "NamuCurrentItem", -- Icon highlight, defaults to current item, overridden when custom colors are used
    -- Namu Symbols
    NamuPrefixSymbol = "@Comment",
    NamuSymbolFunction = "@function",
    NamuSymbolMethod = "@function.method",
    NamuSymbolClass = "@lsp.type.class",
    NamuSymbolInterface = "@lsp.type.interface",
    NamuSymbolVariable = "@lsp.type.variable",
    NamuSymbolConstant = "@lsp.type.constant",
    NamuSymbolProperty = "@lsp.type.property",
    NamuSymbolField = "@lsp.type.field",
    NamuSymbolEnum = "@lsp.type.enum",
    NamuSymbolModule = "@lsp.type.module",
    -- Namu Tree Guides
    NmuTreeGuides = "Comment",
    NamuFileInfo = "Comment",
    NamuPreview = "Visual",
    -- Parent/nested structure highlights
    NamuParent = "Title", -- Makes parent items stand out with title styling
    NamuNested = "Identifier", -- Good contrast for nested items
    NamuStyle = "Type", -- Type highlighting works well for style elements
  })

  vim.schedule(function()
    M.create_combined_highlight("Special", "NamuCurrentItem", "NamuCurrentItemIcon", { bold = true })
    M.create_combined_highlight("Error", "NamuCurrentItem", "NamuCurrentItemIconSelection", { bold = true })
  end)
end

return M
