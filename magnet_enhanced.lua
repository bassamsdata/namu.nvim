--[[ magnet.lua
Quick LSP symbol jumping with live preview and fuzzy finding.

Features:
- Fuzzy find LSP symbols
- Live preview as you move
- Auto-sized window
- Filtered by symbol kinds
- Configurable exclusions

This version includes:
1. Full integration with our enhanced `selecta` module
2. Live preview as you move through symbols
3. Proper highlight cleanup
4. Position restoration on cancel
5. Auto-sized window
6. Fuzzy finding with highlighting
7. Type annotations
8. Configurable through setup function
9. Better error handling
10. Optional keymap setup

You can enhance it further with:
1. Symbol kind icons in the display
2. More sophisticated preview behavior
3. Additional filtering options
4. Symbol documentation preview
5. Multi-select support

Usage in your Neovim config:

```lua
-- In your init.lua or similar

-- Optional: Configure selecta first
require('selecta').setup({
    window = {
        border = 'rounded',
        title_prefix = "󰍇 > ",
    }
})

-- Configure magnet
require('magnet').setup({
    -- Optional: Override default config
    includeKinds = {
        -- Add custom kinds per filetype
        python = { "Function", "Class", "Method" },
    },
    window = {
        auto_size = true,
        min_width = 50,
        padding = 2,
    },
    -- Custom highlight for preview
    highlight = "MagnetPreview",
})

-- Optional: Set up default keymaps
require('magnet').setup_keymaps()

-- Or set your own keymap
vim.keymap.set('n', 'gs', require('magnet').jump, {
    desc = "Jump to symbol"
})
```
]]

local selecta = require("localModules.selecta.selecta")
local M = {}

---@class MagnetConfig
---@field includeKinds table<string, string[]> Symbol kinds to include
---@field excludeResults table<string, string[]> Patterns to exclude
---@field icon string Icon for the picker
---@field highlight string Highlight group for preview
---@field window table Window configuration

M.config = {
    includeKinds = {
        -- LSP symbol kinds: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind
        default = { "Function", "Method", "Class", "Module" },
        -- Filetype-specific kinds
        yaml = { "Object", "Array" },
        json = { "Module" },
        toml = { "Object" },
        markdown = { "String" }, -- String = Markdown headings
    },
    display = {
        mode = "text", -- or "icon"
        padding = 2,
    },
    kindText = {
        Function = "function",
        Method = "method",
        Class = "class",
        Module = "module",
        Constructor = "constructor",
        Interface = "interface",
        Property = "property",
        Field = "field",
        Enum = "enum",
        Constant = "constant",
        Variable = "variable",
    },
    kindIcons = {
        File = "󰈙",
        Module = "󰏗",
        Namespace = "󰌗",
        Package = "󰏖",
        Class = "󰌗",
        Method = "󰆧",
        Property = "󰜢",
        Field = "󰜢",
        Constructor = "󰆧",
        Enum = "󰒻",
        Interface = "󰕘",
        Function = "󰊕",
        Variable = "󰀫",
        Constant = "󰏿",
        String = "󰀬",
        Number = "󰎠",
        Boolean = "󰨙",
        Array = "󰅪",
        Object = "󰅩",
        Key = "󰌋",
        Null = "󰟢",
        EnumMember = "󰒻",
        Struct = "󰌗",
        Event = "󰉁",
        Operator = "󰆕",
        TypeParameter = "󰊄",
    },
    excludeResults = {
        default = { "^_" }, -- ignores private symbols
        -- Filetype-specific exclusions
        lua = {
            "^vim%.",     -- anonymous functions passed to nvim api
            "%.%.%. :",   -- vim.iter functions
            ":gsub",      -- lua string.gsub
            "^callback$", -- nvim autocmds
            "^filter$",
        },
    },
    icon = "󰍇",
    highlight = "MagnetPreview",
    window = {
        auto_size = true,
        min_width = 40,
        padding = 4,
        border = "rounded",
    },
    debug = true, -- Debug flag for both magnet and selecta
}

-- Store original window and position for preview
local state = {
    original_win = nil,
    original_pos = nil,
    preview_ns = vim.api.nvim_create_namespace("magnet_preview"),
}

local function debug_node(node)
    if not node then return "nil" end
    return string.format("%s [%d,%d]-[%d,%d]",
        node:type(),
        node:range())
end

-- TODO: simplify that in lua, if the line has `=`, assignment_statement then take the range
-- from it and keep the one for rust.
---@param node TSNode The treesitter node
---@param lnum number The line number (0-based)
local function find_meaningful_node(node, lnum)
    if not node then return nil end

    -- Store the original node
    local original_node = node

    -- Common declaration types across languages
    local declaration_types = {
        "function_declaration",
        "function_definition",
        "function_item",
        "method_declaration",
        "class_declaration",
        "class_definition",
        "module",
        "mod_item",
        "struct_declaration",
        "interface_declaration",
        "trait_item",
        "impl_item",
    }

    -- Special handling for Lua assignments
    local function find_lua_function(node)
        -- If we're already at a function_definition, return it
        if node:type() == "function_definition" then
            return node
        end

        -- If we're in an assignment statement
        if node:type() == "assignment_statement" then
            -- Look for function_definition in expression_list
            for child in node:iter_children() do
                if child:type() == "expression_list" then
                    for expr in child:iter_children() do
                        if expr:type() == "function_definition" then
                            return expr
                        end
                    end
                end
            end
            -- If no function found, return the whole assignment
            return node
        end

        -- If we're at an identifier or dot_index_expression,
        -- try to find the parent assignment
        local current = node
        while current do
            if current:type() == "assignment_statement" then
                -- Recursively search this assignment
                return find_lua_function(current)
            end
            current = current:parent()
        end

        return nil
    end

    -- Try to find a meaningful parent node that starts on the same line
    local current = node
    while current do
        -- For Lua, handle assignments specially
        if vim.bo.filetype == "lua" then
            local lua_node = find_lua_function(current)
            if lua_node then return lua_node end
        end

        -- General case
        if vim.tbl_contains(declaration_types, current:type())
            and select(1, current:range()) == lnum then
            return current
        end

        current = current:parent()

        -- Stop if we reach a node that starts on a different line
        if current and select(1, current:range()) ~= lnum then
            break
        end
    end

    -- Fallback to original node if we couldn't find a better match
    return original_node
end

---@param symbol table LSP symbol item
local function highlight_symbol(symbol)
    local picker_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(state.original_win)
    vim.api.nvim_buf_clear_namespace(0, state.preview_ns, 0, -1)

    -- Get the line content
    local bufnr = vim.api.nvim_win_get_buf(state.original_win)
    local line = vim.api.nvim_buf_get_lines(bufnr, symbol.lnum - 1, symbol.lnum, false)[1]

    -- Find first non-whitespace character position
    local first_char_col = line:find("%S")
    if not first_char_col then return end
    first_char_col = first_char_col - 1 -- Convert to 0-based index

    -- Get node at the first non-whitespace character
    local node = vim.treesitter.get_node({
        pos = { symbol.lnum - 1, first_char_col },
        ignore_injections = false,
    })
    -- Try to find a more meaningful node
    node = find_meaningful_node(node, symbol.lnum - 1)

    if node then
        local srow, scol, erow, ecol = node:range()

        -- Create extmark for the entire node range
        vim.api.nvim_buf_set_extmark(bufnr, state.preview_ns, srow, 0, {
            end_row = erow,
            end_col = ecol,
            hl_group = M.config.highlight,
            hl_eol = true,
            priority = 100,
            strict = false -- Allow marks beyond EOL
        })

        -- Center the view on the node
        vim.api.nvim_win_set_cursor(state.original_win, { srow + 1, scol })
        vim.cmd("normal! zz")
    end

    vim.api.nvim_set_current_win(picker_win)
end

local function clear_preview_highlight()
    if state.preview_ns and state.original_win then
        -- Get the buffer number from the original window
        local bufnr = vim.api.nvim_win_get_buf(state.original_win)
        vim.api.nvim_buf_clear_namespace(bufnr, state.preview_ns, 0, -1)
    end
end

---@param symbols table[] LSP symbols
local function filterSymbols(symbols)
    local includeKinds = M.config.includeKinds[vim.bo.filetype]
        or M.config.includeKinds.default
    local excludeResults = M.config.excludeResults[vim.bo.filetype]
        or M.config.excludeResults.default

    return vim
        .iter(symbols)
        :map(function(symbol)
            symbol.text = symbol.text:gsub("%[%w+%] ", "")
            return symbol
        end)
        :filter(function(symbol)
            local exclude = vim.iter(excludeResults):any(function(pattern)
                return symbol.text:find(pattern)
            end)
            local include = vim.tbl_contains(includeKinds, symbol.kind)
            return include and not exclude
        end)
        :totable()
end

---@param symbols table[] LSP symbols
local function symbolsToSelectaItems(symbols)
    return vim.tbl_map(function(symbol)
        return {
            text = symbol.text,
            value = symbol,
            icon = M.config.kindIcons[symbol.kind] or M.config.icon, -- Fallback to magnet icon if kind icon not found
            kind = symbol.kind,
        }
    end, symbols)
end

---@param symbol table LSP symbol
local function jumpToSymbol(symbol)
    vim.cmd.normal({ "m`", bang = true }) -- set jump mark
    vim.api.nvim_win_set_cursor(state.original_win, { symbol.lnum, symbol.col - 1 })
end

function M.jump()
    -- Store current window and position
    state.original_win = vim.api.nvim_get_current_win()
    state.original_pos = vim.api.nvim_win_get_cursor(state.original_win)

    -- Set up highlight group
    vim.api.nvim_set_hl(0, M.config.highlight, {
        background = "#2a2a2a", -- Adjust color to match your theme
        bold = true,
    })

    -- Create autocmd for cleanup
    local augroup = vim.api.nvim_create_augroup("MagnetCleanup", { clear = true })

    local params = vim.lsp.util.make_position_params(0, "utf-8")

    vim.lsp.buf_request(
        0,
        "textDocument/documentSymbol",
        params,
        function(err, result, _, _)
            if err then
                vim.notify(
                    "Error fetching symbols: " .. err.message,
                    vim.log.levels.ERROR,
                    { title = "Magnet", icon = M.config.icon }
                )
                return
            end
            if not result or #result == 0 then
                vim.notify(
                    "No results.",
                    vim.log.levels.WARN,
                    { title = "Magnet", icon = M.config.icon }
                )
                return
            end

            local items = vim.lsp.util.symbols_to_items(result or {}, 0) or {}
            local symbols = filterSymbols(items)

            if #symbols == 0 then
                vim.notify(
                    "Current `kindFilter` doesn't match any symbols.",
                    nil,
                    { title = "Magnet", icon = M.config.icon }
                )
                return
            end

            -- Convert symbols to selecta items
            local selectaItems = symbolsToSelectaItems(symbols)
            -- local prefix_width = calculate_prefix_width(selectaItems)

            local picker_win = selecta.pick(selectaItems, {
                title = "LSP Symbols",
                fuzzy = true,
                window = vim.tbl_deep_extend("force", M.config.window, {
                    title_prefix = M.config.icon .. " ",
                }),
                on_select = function(item)
                    clear_preview_highlight()
                    jumpToSymbol(item.value)
                end,
                on_cancel = function()
                    clear_preview_highlight()
                    if state.original_win and state.original_pos and vim.api.nvim_win_is_valid(state.original_win) then
                        vim.api.nvim_win_set_cursor(state.original_win, state.original_pos)
                    end
                end,
                on_move = function(item)
                    if item then
                        highlight_symbol(item.value)
                    end
                end,
            })

            -- Add cleanup autocmd after picker is created
            if picker_win then
                vim.api.nvim_create_autocmd("WinClosed", {
                    group = augroup,
                    pattern = tostring(picker_win),
                    callback = function()
                        clear_preview_highlight()
                        vim.api.nvim_del_augroup_by_name("MagnetCleanup")
                    end,
                    once = true,
                })
            end
        end
    )
end

---@param opts? table
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    -- Configure selecta with appropriate options
    selecta.setup({
        debug = M.config.debug,
        display = {
            mode = M.config.display.mode,
            padding = M.config.display.padding
        },
        window = vim.tbl_deep_extend("force", {}, M.config.window)
    })
end

-- Optional: Add commands or keymaps in setup
function M.setup_keymaps()
    vim.keymap.set("n", "<leader>ss", M.jump, {
        desc = "Jump to LSP symbol",
        silent = true,
    })
end

return M
