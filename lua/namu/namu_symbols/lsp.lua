local logger = require("namu.utils.logger")
local M = {}

-- Store current request state
local state = {
  current_request = nil,
}

---Thanks to @folke snacks lsp for this handling, basically this function mostly borrowed from him
---Fixes old style clients
---@param client vim.lsp.Client
---@return vim.lsp.Client
function M.ensure_client_compatibility(client)
  -- If client already has the new-style API, return it as-is
  if getmetatable(client) and getmetatable(client).request then
    return client
  end
  -- If we've already wrapped this client, don't wrap it again
  if client.namu_wrapped then
    return client
  end
  -- Create a wrapper for older style clients
  local wrapped = {
    namu_wrapped = true,
  }

  return setmetatable(wrapped, {
    __index = function(_, key)
      -- Special handling for supports_method in older versions
      if key == "supports_method" then
        return function(_, method)
          return client:supports_method(method)
        end
      end

      -- Handle request and cancel_request methods
      if key == "request" or key == "cancel_request" then
        return function(_, ...)
          return client[key](...)
        end
      end

      -- Pass through all other properties
      return client[key]
    end,
  })
end

---Returns the LSP client with specified method support
---@param bufnr number
---@param method string LSP method to check for
---@return vim.lsp.Client|nil, string|nil
function M.get_client_with_method(bufnr, method)
  logger.log("\n=== Finding LSP client ===")
  logger.log(string.format("Buffer: %d, Method: %s", bufnr, method))

  local get_clients_fn = vim.lsp.get_clients
  local clients = vim.tbl_map(M.ensure_client_compatibility, get_clients_fn({ bufnr = bufnr }))

  logger.log(string.format("Found %d clients", #clients))

  if vim.tbl_isempty(clients) then
    logger.log("No LSP clients attached")
    return nil, "No LSP client attached to buffer"
  end

  for _, client in ipairs(clients) do
    logger.log(string.format("Checking client: %s", client.name))
    if client and client.server_capabilities then
      local has_capability = method == "textDocument/documentSymbol"
          and client.server_capabilities.documentSymbolProvider
        or method == "workspace/symbol" and client.server_capabilities.workspaceSymbolProvider
        or client:supports_method(method)

      logger.log(string.format("Has capability %s: %s", method, tostring(has_capability)))

      if has_capability then
        return client, nil
      end
    end
  end

  logger.log("No client with required capability found")
  return nil, string.format("No LSP client supports %s", method)
end

---Creates position params compatible with both Neovim stable and nightly
---@param bufnr number Buffer number
---@return table LSP position parameters
function M.make_position_params(bufnr)
  -- Get the first client attached to the buffer to use its encoding
  local get_clients_fn = vim.lsp.get_clients
  local clients = get_clients_fn({ bufnr = bufnr })
  -- Default to utf-16 if no clients found
  local position_encoding = "utf-16"
  -- Get encoding from the first client
  if clients[1] and clients[1].offset_encoding then
    position_encoding = clients[1].offset_encoding
  end
  -- Make params with explicit position encoding
  return vim.lsp.util.make_position_params(nil, position_encoding)
end

---Make LSP request parameters based on method
---@param bufnr number
---@param method string
---@param extra_params? table Additional parameters
---@return table
function M.make_params(bufnr, method, extra_params)
  logger.log("\n=== Making LSP parameters ===")
  logger.log(string.format("Method: %s", method))
  logger.log("Extra params: " .. vim.inspect(extra_params))

  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
  }

  if method == "workspace/symbol" then
    -- For workspace symbols, we only need the query
    params = { query = extra_params.query or "" }
    logger.log("Workspace symbol params: " .. vim.inspect(params))
  end

  local final_params = vim.tbl_deep_extend("force", params, extra_params or {})
  logger.log("Final params: " .. vim.inspect(final_params))
  return final_params
end

---Make LSP request for symbols or other methods
---@param bufnr number
---@param method string LSP method (e.g., "textDocument/documentSymbol")
---@param callback fun(err: any, result: any, ctx: any)
---@param extra_params? table Additional parameters for the request
function M.request_symbols(bufnr, method, callback, extra_params)
  logger.log("\n=== Making LSP request ===")
  logger.log(string.format("Buffer: %d, Method: %s", bufnr, method))
  logger.log("Extra params: " .. vim.inspect(extra_params))

  -- Cancel existing request
  if state.current_request then
    logger.log("Cancelling existing request")
    local client = state.current_request.client
    local request_id = state.current_request.request_id
    if client and type(client.cancel_request) == "function" and request_id then
      client:cancel_request(request_id)
    end
    state.current_request = nil
  end

  -- Get client with method support
  local client, err = M.get_client_with_method(bufnr, method)
  if err then
    logger.log("Error getting client: " .. err)
    callback(err, nil, nil)
    return
  end

  -- Create params
  local params = M.make_params(bufnr, method, extra_params)

  -- Send request
  -- Send request
  logger.log("Sending LSP request")
  local success, request_id = client:request(method, params, function(request_err, result, ctx)
    logger.log("\n=== LSP Response ===")
    logger.log("Error: " .. vim.inspect(request_err))
    logger.log("Context: " .. vim.inspect(ctx))

    state.current_request = nil
    callback(request_err, result, ctx)
  end)

  if success and request_id then
    logger.log(string.format("Request successful, ID: %s", tostring(request_id)))
    state.current_request = {
      client = client,
      request_id = request_id,
    }
  else
    logger.log("Request failed")
    callback("Request failed or request_id was nil", nil, nil)
  end

  return state.current_request
end

---Filters symbols based on configured kinds and blocklist
---@param symbol LSPSymbol
---@param config table Configuration table
---@param filetype string Current filetype
---@return boolean
function M.should_include_symbol(symbol, config, filetype)
  local kind = M.symbol_kind(symbol.kind)
  local includeKinds = config.AllowKinds[filetype] or config.AllowKinds.default
  local excludeResults = config.BlockList[filetype] or config.BlockList.default

  local include = vim.tbl_contains(includeKinds, kind)
  local exclude = vim.iter(excludeResults):any(function(pattern)
    return symbol.name:find(pattern) ~= nil
  end)

  return include and not exclude
end

-- Cache for symbol kinds
local symbol_kinds = nil

---Converts LSP symbol kind numbers to readable strings
---@param kind number
---@return LSPSymbolKind
function M.symbol_kind(kind)
  if not symbol_kinds then
    symbol_kinds = {}
    for k, v in pairs(vim.lsp.protocol.SymbolKind) do
      if type(v) == "number" then
        symbol_kinds[v] = k
      end
    end
  end
  return symbol_kinds[kind] or "Unknown"
end

function M.symbol_kind_to_number(kind_str)
  -- Find the number for a given kind string
  for k, v in pairs(vim.lsp.protocol.SymbolKind) do
    if type(v) == "number" and k:lower() == kind_str:lower() then
      return v
    end
  end
  return 12 -- Function as default
end

return M
