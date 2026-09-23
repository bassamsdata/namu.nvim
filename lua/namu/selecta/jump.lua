-- Jump-label support for selecta pickers (one-key jumping to any visible row).
-- Opt-in: no-op unless `opts.jump.enabled = true`.

local M = {}
local common = require("namu.selecta.common")

function M.is_active(state)
  return state and state.jump and state.jump.active or false
end

---Decide whether pick() should enter jump mode synchronously at open.
---`auto_activate` accepts `true` (always), `false` (never), or a number N
---(only when the picker opens with N items or fewer). Always gated behind
---`jump.enabled`, and `activate()` still applies its own `min_items` floor.
---@param opts SelectaOptions
---@param item_count number Number of items visible when the picker opens
---@return boolean
function M.should_auto_activate(opts, item_count)
  local jump_opts = opts and opts.jump
  if not (jump_opts and jump_opts.enabled) then
    return false
  end
  local auto = jump_opts.auto_activate
  if auto == true then
    return true
  end
  if type(auto) == "number" then
    return item_count <= auto
  end
  return false
end

function M.activate(state, opts)
  if M.is_active(state) or not state.active or state.is_loading then
    return
  end
  local jump_opts = opts.jump
  if #state.filtered_items < math.max(1, jump_opts.min_items or 0) then
    return
  end

  state.jump = state.jump or {}
  state.jump.active = true
  state.jump.ns = state.jump.ns or vim.api.nvim_create_namespace("namu_jump_" .. tostring(state.picker_id))
  state.jump.bound_keys = {}
  state.jump.saved_keymaps = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.prompt_buf, "n")) do
    state.jump.saved_keymaps[mapping.lhs] = mapping
  end
  state.jump.prev_modifiable = vim.bo[state.prompt_buf].modifiable

  -- Lock the prompt buffer (so unbound keys can't edit the filter) and drop
  -- out of insert mode (so the normal-mode label keymaps below fire).
  vim.bo[state.prompt_buf].modifiable = false
  vim.cmd("stopinsert")

  -- Place a label per visible row, bind a normal-mode keymap per label.
  -- Label presses are always single-select: move cursor to the row (so
  -- previews recentre via on_move), close, then fire on_select with the
  -- target item. Multiselect users keep using their Tab binding.
  local win_info = vim.fn.getwininfo(state.win)[1]
  local labels = jump_opts.keys
  for i = 1, #labels do
    local row = win_info.topline + i - 1
    if row > win_info.botline or not state.filtered_items[row] then
      break
    end
    local key = labels:sub(i, i)
    table.insert(state.jump.bound_keys, key)
    vim.api.nvim_buf_set_extmark(state.buf, state.jump.ns, row - 1, 0, {
      virt_text = { { key, jump_opts.hl_group } },
      virt_text_pos = "overlay",
      priority = jump_opts.priority,
    })
    vim.keymap.set("n", key, function()
      if not state.active then
        return
      end
      local item = state.filtered_items[row]
      vim.api.nvim_win_set_cursor(state.win, { row, 0 })
      common.update_current_highlight(state, opts, row - 1)
      if opts.on_move then
        opts.on_move(item)
      end
      common.close_picker_with_cleanup(state, opts, require("namu.selecta.selecta").close_picker, false)
      if opts.on_select then
        opts.on_select(item)
      end
    end, {
      buffer = state.prompt_buf,
      nowait = true,
      silent = true,
      desc = "Namu: Jump label " .. key,
    })
  end
end

function M.deactivate(state)
  if not M.is_active(state) then
    return
  end
  state.jump.active = false

  if vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_clear_namespace(state.buf, state.jump.ns, 0, -1)
  end
  if vim.api.nvim_buf_is_valid(state.prompt_buf) then
    vim.api.nvim_buf_call(state.prompt_buf, function()
      for _, key in ipairs(state.jump.bound_keys) do
        pcall(vim.keymap.del, "n", key, { buffer = state.prompt_buf })
        local previous = state.jump.saved_keymaps[key]
        if previous then
          pcall(vim.fn.mapset, "n", false, previous)
        end
      end
    end)
  end
  state.jump.bound_keys = {}
  state.jump.saved_keymaps = {}

  if vim.api.nvim_buf_is_valid(state.prompt_buf) then
    vim.bo[state.prompt_buf].modifiable = state.jump.prev_modifiable ~= false
  end

  -- Re-enter insert mode only if the prompt window still owns the focus —
  -- skipped during cleanup-driven deactivation where the window is going away.
  if
    state.active
    and vim.api.nvim_win_is_valid(state.prompt_win)
    and vim.api.nvim_get_current_win() == state.prompt_win
  then
    vim.cmd("startinsert")
  end
end

---Register the toggle key (i+n) and normal-mode close mirrors so <Esc>
---cancels from jump mode. No-op when jump is disabled.
function M.setup_keymap(state, opts)
  local jump_opts = opts.jump
  if not (jump_opts and jump_opts.enabled) then
    return
  end

  -- Toggle must work in BOTH modes: insert to enter, normal to exit (jump
  -- itself runs in normal mode, so an n-binding is the only way out).
  vim.keymap.set({ "i", "n" }, jump_opts.toggle_key, function()
    if not state.active then
      return
    end
    if M.is_active(state) then
      M.deactivate(state)
    else
      M.activate(state, opts)
    end
  end, {
    buffer = state.prompt_buf,
    nowait = true,
    silent = true,
    desc = "Namu: Toggle jump mode",
  })

  -- selecta binds close keys insert-only by default; mirror into normal mode
  -- so <Esc> cancels even while labels are showing.
  for _, key in ipairs((opts.movement and opts.movement.close) or { "<ESC>" }) do
    vim.keymap.set("n", key, function()
      if state.active then
        common.close_picker_with_cleanup(state, opts, require("namu.selecta.selecta").close_picker, true)
      end
    end, {
      buffer = state.prompt_buf,
      nowait = true,
      silent = true,
      desc = "Namu: Cancel (from jump mode)",
    })
  end
end

return M
