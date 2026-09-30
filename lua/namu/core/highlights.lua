local M = {}
local hl_groups = {}
local combined_groups = {}
local generated_groups = {}

local function get_highlight(name, link)
  return vim.api.nvim_get_hl(0, { name = name, link = link == true, create = false })
end

-- Only replace our own generated defaults. A colorscheme or user override wins.
local function set_generated_highlight(name, def)
  local current = get_highlight(name, true)
  if not vim.tbl_isempty(current) and not vim.deep_equal(current, generated_groups[name]) then
    return
  end
  vim.api.nvim_set_hl(0, name, def)
  generated_groups[name] = get_highlight(name, true)
end

local function luminance(color)
  local function channel(value)
    value = value / 255
    return value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * channel(math.floor(color / 65536))
    + 0.7152 * channel(math.floor(color / 256) % 256)
    + 0.0722 * channel(color % 256)
end

local function contrast(a, b)
  local l1, l2 = luminance(a), luminance(b)
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05)
end

local function blend(a, b, amount)
  local color = 0
  for _, shift in ipairs({ 65536, 256, 1 }) do
    local c1, c2 = math.floor(a / shift) % 256, math.floor(b / shift) % 256
    color = color + math.floor(c1 + (c2 - c1) * amount + 0.5) * shift
  end
  return color
end

local function current_item_highlight()
  local normal, float = get_highlight("Normal"), get_highlight("NormalFloat")
  local bg, fg = float.bg or normal.bg, float.fg or normal.fg
  local ctermbg = float.ctermbg or normal.ctermbg
  local result = {}
  -- With transparency we cannot judge CursorLine against the terminal's
  -- background. Prefer a dedicated selection color in that case.
  local candidates = bg and { "CursorLine", "PmenuSel", "Visual" } or { "PmenuSel", "Visual", "CursorLine" }

  -- 1.25 is a modest row/background distinction, not a text contrast target.
  -- Prefer theme colors, and keep syntax foregrounds when using a fallback.
  for _, name in ipairs(candidates) do
    local hl = get_highlight(name)
    local candidate = hl.reverse and (hl.fg or fg) or hl.bg
    if candidate then
      if bg then
        candidate = blend(candidate, bg, (hl.blend or 0) / 100)
      end
      if not result.bg and (not bg or contrast(candidate, bg) >= 1.25) and (not fg or contrast(candidate, fg) >= 3) then
        result.bg = candidate
      end
    end
    local terminal_bg = hl.cterm and hl.cterm.reverse and (hl.ctermfg or float.ctermfg or normal.ctermfg) or hl.ctermbg
    if not result.ctermbg and terminal_bg and terminal_bg ~= ctermbg then
      result.ctermbg = terminal_bg
    end
    if
      name == "CursorLine"
      and bg
      and result.bg
      and result.ctermbg
      and result.ctermbg == hl.ctermbg
      and not hl.reverse
      and (not hl.fg or contrast(result.bg, hl.fg) >= 3)
    then
      return { link = "CursorLine" }
    end
  end

  if not result.bg then
    -- Only the focused row gets a background; the picker stays transparent.
    -- If no theme color is usable, infer a base from 'background'.
    bg = bg or (vim.o.background == "light" and 0xf0f0f0 or 0x202020)
    local target = fg
    if not target or contrast(bg, target) < 3 then
      target = contrast(bg, 0xffffff) > contrast(bg, 0) and 0xffffff or 0
    end
    for step = 1, 100 do
      local candidate = blend(bg, target, step / 100)
      if contrast(candidate, bg) >= 1.25 then
        result.bg = candidate
        break
      end
    end
  end

  -- A neutral selection color for themes without terminal palette entries.
  if not result.ctermbg then
    result.ctermbg = vim.o.background == "light" and 252 or 238
    if result.ctermbg == ctermbg then
      result.ctermbg = vim.o.background == "light" and 249 or 241
    end
  end
  return result
end

-- Thanks to @nvim-snacks for this one
-- Simple function to set highlights and remember them for ColorScheme events
function M.set_highlights(groups, opts)
  opts = opts or {}
  for name, def in pairs(groups) do
    -- Apply any prefix
    local hl_name = opts.prefix and (opts.prefix .. name) or name
    -- Convert string to link definition
    local hl_def = type(def) == "string" and { link = def } or vim.deepcopy(def)
    hl_def.default = opts.default ~= false
    hl_groups[hl_name] = hl_def
    vim.api.nvim_set_hl(0, hl_name, hl_def)
  end
end

local function apply_combined_highlight(fg_group, bg_group, result_group, opts)
  local fg_hl, bg_hl = get_highlight(fg_group), get_highlight(bg_group)

  local combined_hl = {}
  combined_hl.fg = fg_hl.fg
  combined_hl.bg = bg_hl.bg
  combined_hl.ctermfg = fg_hl.ctermfg
  combined_hl.ctermbg = bg_hl.ctermbg

  -- Apply additional styling options
  for key, value in pairs(opts) do
    if key ~= "fg" and key ~= "bg" then -- Don't override fg/bg from groups
      combined_hl[key] = value
    end
  end

  set_generated_highlight(result_group, combined_hl)
end

function M.create_combined_highlight(fg_group, bg_group, result_group, opts)
  opts = vim.deepcopy(opts or {})
  combined_groups[result_group] = { fg_group = fg_group, bg_group = bg_group, opts = opts }
  apply_combined_highlight(fg_group, bg_group, result_group, opts)
end

local function refresh_generated_highlights()
  set_generated_highlight("NamuCurrentItem", current_item_highlight())
  for name, recipe in pairs(combined_groups) do
    apply_combined_highlight(recipe.fg_group, recipe.bg_group, name, recipe.opts)
  end
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("NamuHighlights", { clear = true }),
  callback = function()
    -- Re-apply all stored highlights
    for name, def in pairs(hl_groups) do
      vim.api.nvim_set_hl(0, name, def)
    end
    refresh_generated_highlights()
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
    NamuJumpLabel = "Special", -- Jump-mode label characters
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

  refresh_generated_highlights()
  M.create_combined_highlight("Special", "NamuCurrentItem", "NamuCurrentItemIcon", { bold = true })
  M.create_combined_highlight("Error", "NamuCurrentItem", "NamuCurrentItemIconSelection", { bold = true })
end

return M
