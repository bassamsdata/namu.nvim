---@alias LSPSymbolKind string
-- ---@alias TSNode userdata
-- ---@alias vim.lsp.Client table

---@class LSPSymbol
---@field name string Symbol name
---@field kind number LSP symbol kind number
---@field range table<string, table> Symbol range in the document
---@field location? table<string, table> Location information (alternative to range)
---@field children? LSPSymbol[] Child symbols
---@field parent_signature? string Signature of the parent symbol
---@field signature? string Unique signature for this symbol
---@field containerName? string Name of the container (for SymbolInformation)
---@field selectionRange? table<string, table> Range for selection (for DocumentSymbol)

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
---@field ar NamuSymbolType Array symbols
---@field ob NamuSymbolType Object symbols

---@class TagEntry
---@field _type string
---@field name string
---@field kind string
---@field line number
---@field end number
---@field scope string

---@class NamuActionConfig
---@field close_on_yank boolean Whether to close picker after yanking text
---@field close_on_delete boolean Whether to close picker after deleting text

---@class NamuCoreConfig
---@field AllowKinds table<string, string[]> Symbol kinds to include
---@field display table<string, string|number|table> Display configuration
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
---@field kinds table Configuration for kinds
---@field preview table highlight_mode
---@field filter_symbol_types NamuSymbolTypes Configuration for symbol type filtering
---@field actions NamuActionConfig Configuration for picker actions
---@field max_items number|nil
---@field current_highlight CurrentHighlightConfig Configuration for selection highlighting
---@field preserve_hierarchy? boolean Whether to show parent items when filtering

---@class NamuSymbolsConfig : NamuCoreConfig
---@field source_priority "lsp|treesitter" which source to prioritize for symbol resolution
---@field enhance_lua_test_symbols boolean Whether to enhance Lua test symbols
---@field lua_test_truncate_length number Length to truncate Lua test symbols
---@field lua_test_preserve_hierarchy boolean Whether to preserve hierarchy in Lua test symbols

---@class CallHierarchyConfig : NamuCoreConfig
---@field call_hierarchy table Configuration for call hierarchy
---@field call_hierarchy.max_depth number Maximum depth to search for calls
---@field call_hierarchy.max_depth_limit number Hard limit to prevent performance issues
---@field call_hierarchy.show_cycles boolean Whether to show recursive calls

---@class NamuState
---@field original_win number|nil Original window
---@field original_buf number|nil Original buffer
---@field original_ft string|nil Original filetype
---@field original_pos table|nil Original cursor position
---@field preview_ns number|nil Preview namespace
---@field current_request table|nil Current LSP request ID
---@field last_highlighted_bufnr number|nil Last buffer where highlights were applied
