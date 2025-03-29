local M = {}

-- Store all highlight groups
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
    -- Add default flag if specified
    if opts.default ~= false then
      hl_def.default = true
    end
    -- Store for colorscheme changes
    hl_groups[hl_name] = hl_def
    -- Set the highlight
    vim.api.nvim_set_hl(0, hl_name, hl_def)
  end
end

-- Get background-only highlight
function M.get_bg_highlight(hl_name)
  local bg_name = hl_name .. "BG"

  -- Return cached highlight if it exists
  if vim.fn.hlexists(bg_name) == 1 then
    return bg_name
  end

  -- Get original highlight background
  local orig_hl = vim.api.nvim_get_hl(0, { name = hl_name })
  if orig_hl.bg then
    -- Create background-only highlight
    M.set_highlights({ [bg_name] = { bg = string.format("#%06x", orig_hl.bg) } })
    return bg_name
  end

  return hl_name -- Fallback
end

-- Create the autocmd for colorscheme changes
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("NamuHighlights", { clear = true }),
  callback = function()
    -- Re-apply all stored highlights
    for name, def in pairs(hl_groups) do
      vim.api.nvim_set_hl(0, name, def)
    end
  end,
})

-- Initialize all Namu highlights
function M.setup()
  -- Selecta highlights
  M.set_highlights({
    NamuCursor = { blend = 100, nocombine = true },
    NamuPrefix = "Special",
    NamuMatch = "Identifier",
    NamuFilter = "Type",
    NamuPrompt = "FloatTitle",
    NamuSelected = "Statement",
    NamuFooter = "Comment",
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
    NamuTreeGuides = "Comment",
    NamuFileInfo = "Comment",
    NamuPreview = "Visual",
    -- Parent/nested structure highlights
    NamuParent = "Title", -- Makes parent items stand out with title styling
    NamuNested = "Identifier", -- Good contrast for nested items
    NamuStyle = "Type", -- Type highlighting works well for style elements
  })

  -- Diagnostic highlights - create background versions
  -- for _, name in ipairs({
  --   "DiagnosticVirtualTextError",
  --   "DiagnosticVirtualTextWarn",
  --   "DiagnosticVirtualTextInfo",
  --   "DiagnosticVirtualTextHint",
  -- }) do
  --   M.get_bg_highlight(name)
  -- end
end

return M
