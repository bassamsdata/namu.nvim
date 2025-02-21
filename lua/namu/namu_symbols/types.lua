---@alias LSPSymbolKind string
-- ---@alias TSNode userdata
-- ---@alias vim.lsp.Client table

---@class LSPSymbol
---@field name string Symbol name
---@field kind number LSP symbol kind number
---@field range table<string, table> Symbol range in the document
---@field location? table<string, table>
---@field children? LSPSymbol[] Child symbols

---@class NamuSymbolType
---@field kinds string[] List of LSP symbol kinds that match this filter
---@field description string Description of what this filter matches

---@class NamuSymbolTypes
---@field fn NamuSymbolType Function symbols
---@field va NamuSymbolType Variable symbols
---@field cl NamuSymbolType Class symbols
---@field co NamuSymbolType Constant symbols
---@field fi NamuSymbolType Field symbols
---@field mo NamuSymbolType Module symbols

---@class NamuActionConfig
---@field close_on_yank boolean Whether to close picker after yanking text
---@field close_on_delete boolean Whether to close picker after deleting text

---@class NamuConfig
---@field AllowKinds table<string, string[]> Symbol kinds to include
---@field display table<string, string|number> Display configuration
---@field kindText table<string, string> Text representation of kinds
---@field kindIcons table<string, string> Icons for kinds
---@field BlockList table<string, string[]> Patterns to exclude
---@field icon string Icon for the picker
---@field highlight string Highlight group for preview
---@field highlights table<string, string> Highlight groups
---@field window table Window configuration
---@field debug boolean Enable debug logging
---@field focus_current_symbol boolean Focus the current symbol
---@field auto_select boolean Auto-select single matches
---@field row_position "center"|"top10"|"top10_right"|"center_right"|"bottom" Window position preset
---@field multiselect table Multiselect configuration
---@field custom_keymaps table Keymap configuration
---@field movement? SelectaMovementConfig
---@field initially_hidden? boolean
---@field preview table highlight_mode
---@field filter_symbol_types NamuSymbolTypes Configuration for symbol type filtering
---@field actions NamuActionConfig Configuration for picker actions

---@class NamuState
---@field original_win number|nil Original window
---@field original_buf number|nil Original buffer
---@field original_ft string|nil Original filetype
---@field original_pos table|nil Original cursor position
---@field preview_ns number|nil Preview namespace
---@field current_request table|nil Current LSP request ID
