local Helpers = {}

Helpers.expect = MiniTest.expect --[[@type function]]
Helpers.eq = MiniTest.expect.equality --[[@type function]]
Helpers.not_eq = MiniTest.expect.no_equality --[[@type function]]

Helpers.get_buf_lines = function(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
end

return Helpers
