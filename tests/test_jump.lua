---@diagnostic disable: need-check-nil, param-type-mismatch
local h = require("tests.helpers")
local selecta = require("namu.selecta.selecta")
local jump = require("namu.selecta.jump")
local selecta_config = require("namu.selecta.selecta_config")
local StateManager = require("namu.selecta.state").StateManager
---@diagnostic disable-next-line: undefined-global
local new_set = MiniTest.new_set

local T = new_set()

-- Force highlights to be set up so NamuJumpLabel exists for extmark validation.
require("namu.core.highlights").setup()

-- selecta.pick is fire-and-forget — it doesn't expose state. Tests need a
-- handle to the SelectaState to drive activate/deactivate/etc., so we
-- transiently monkey-patch StateManager.new to capture it. The patch is
-- reverted before pick() returns; isolation is contained to this helper.
local last_state = nil
local function open_picker(items, opts)
  local original_new = StateManager.new
  StateManager.new = function(...)
    last_state = original_new(...)
    return last_state
  end
  local ok, err = pcall(selecta.pick, items, opts or {})
  StateManager.new = original_new
  if not ok then
    error(err)
  end
  return last_state
end

local function close_picker()
  if last_state and last_state.active then
    pcall(selecta.close_picker, last_state)
  end
  -- The picker leaves floating windows and unlisted scratch buffers around;
  -- delete both so the next test starts on the original buffer.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative ~= "" then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local listed = vim.api.nvim_get_option_value("buflisted", { buf = bufnr })
      if not listed then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end
  pcall(vim.cmd, "stopinsert")
end

local function items_for(n)
  local items = {}
  for i = 1, n do
    items[i] = { text = string.format("item-%02d", i), value = i, id = "id-" .. i }
  end
  return items
end

local picker_hooks = {
  pre_case = function()
    selecta_config.values = vim.deepcopy(selecta_config.defaults)
    last_state = nil
  end,
  post_case = function()
    close_picker()
    last_state = nil
  end,
}

-- ----------------------------------------------------------------------
T["Jump.config"] = new_set()

T["Jump.config"]["defaults register a disabled jump table"] = function()
  selecta.setup({})
  local config = selecta.get_config()
  h.eq(type(config.jump), "table")
  h.eq(config.jump.enabled, false)
  h.eq(config.jump.toggle_key, ";")
  h.eq(config.jump.auto_activate, false)
  h.eq(type(config.jump.keys), "string")
  h.eq(#config.jump.keys > 0, true)
end

T["Jump.config"]["user setup merges jump overrides"] = function()
  selecta.setup({ jump = { enabled = true, toggle_key = "/" } })
  local config = selecta.get_config()
  h.eq(config.jump.enabled, true)
  h.eq(config.jump.toggle_key, "/")
  h.eq(config.jump.auto_activate, false) -- defaults preserved
  selecta_config.values = vim.deepcopy(selecta_config.defaults)
end

-- ----------------------------------------------------------------------
T["Jump.activation"] = new_set({ hooks = picker_hooks })

T["Jump.activation"]["is_active is false on a fresh picker"] = function()
  local state = open_picker(items_for(5), { jump = { enabled = true } })
  h.eq(jump.is_active(state), false)
end

T["Jump.activation"]["activate places one extmark per visible row"] = function()
  local opts = { jump = selecta.get_config().jump }
  local state = open_picker(items_for(5), opts)
  jump.activate(state, opts)
  h.eq(jump.is_active(state), true)
  local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.jump.ns, 0, -1, { details = true })
  h.eq(#marks, 5, "one label per visible row")
  for _, mark in ipairs(marks) do
    h.eq(mark[4].virt_text[1][2], "NamuJumpLabel")
  end
end

T["Jump.activation"]["activate locks the prompt buffer"] = function()
  local opts = { jump = selecta.get_config().jump }
  local state = open_picker(items_for(3), opts)
  jump.activate(state, opts)
  h.eq(vim.bo[state.prompt_buf].modifiable, false)
end

T["Jump.activation"]["deactivate clears labels and unbinds keys"] = function()
  local opts = { jump = selecta.get_config().jump }
  local state = open_picker(items_for(4), opts)
  jump.activate(state, opts)
  local first_key = opts.jump.keys:sub(1, 1)

  local function has_normal_keymap(key)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.prompt_buf, "n")) do
      if m.lhs == key then
        return true
      end
    end
    return false
  end

  h.eq(has_normal_keymap(first_key), true, "label key bound after activate")

  jump.deactivate(state)
  h.eq(jump.is_active(state), false)
  h.eq(vim.bo[state.prompt_buf].modifiable, true)
  local marks = vim.api.nvim_buf_get_extmarks(state.buf, state.jump.ns, 0, -1, {})
  h.eq(#marks, 0)
  h.eq(has_normal_keymap(first_key), false, "label key unbound after deactivate")
end

T["Jump.activation"]["activate is a no-op when min_items not satisfied"] = function()
  local opts = { jump = { enabled = true, min_items = 5 } }
  local state = open_picker({ { text = "only-one", value = 1, id = "id-1" } }, opts)
  jump.activate(state, opts)
  h.eq(jump.is_active(state), false)
end

-- ----------------------------------------------------------------------
T["Jump.toggle_key"] = new_set({ hooks = picker_hooks })

local function buf_keymap_has(bufnr, mode, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    if m.lhs == lhs then
      return true
    end
  end
  return false
end

T["Jump.toggle_key"]["setup_keymap binds toggle key in insert mode"] = function()
  local state = open_picker(items_for(3), { jump = { enabled = true, toggle_key = ";" } })
  h.eq(buf_keymap_has(state.prompt_buf, "i", ";"), true)
end

T["Jump.toggle_key"]["setup_keymap binds toggle key in normal mode too"] = function()
  -- Required so the user can toggle OUT of jump mode (jump runs in normal
  -- mode; without an n-mode binding `;` does nothing and the user is stuck).
  local state = open_picker(items_for(3), { jump = { enabled = true, toggle_key = ";" } })
  h.eq(buf_keymap_has(state.prompt_buf, "n", ";"), true)
end

T["Jump.toggle_key"]["close keys are mirrored into normal mode"] = function()
  -- selecta binds <Esc> insert-only by default; jump must extend it into
  -- normal mode so <Esc> cancels the picker even while labels are showing.
  local state = open_picker(items_for(3), {
    jump = { enabled = true },
    movement = { close = { "<ESC>" } },
  })
  h.eq(buf_keymap_has(state.prompt_buf, "n", "<Esc>"), true)
end

T["Jump.toggle_key"]["setup_keymap is a no-op when jump disabled"] = function()
  local state = open_picker(items_for(3), {})
  h.eq(buf_keymap_has(state.prompt_buf, "i", ";"), false)
  h.eq(buf_keymap_has(state.prompt_buf, "n", ";"), false)
end

-- ----------------------------------------------------------------------
T["Jump.selection"] = new_set({ hooks = picker_hooks })

T["Jump.selection"]["label invokes on_move then on_select with the right item"] = function()
  local move_calls, select_calls = {}, {}
  local opts = {
    jump = selecta.get_config().jump,
    on_move = function(item) table.insert(move_calls, item.value) end,
    on_select = function(item) table.insert(select_calls, item.value) end,
  }
  local state = open_picker(items_for(4), opts)
  jump.activate(state, opts)
  -- Selecta fires on_move once during initial render; reset so we only count
  -- the calls the label-press handler makes.
  move_calls = {}
  -- Fire the first label's keymap callback directly.
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.prompt_buf, "n")) do
    if m.lhs == opts.jump.keys:sub(1, 1) and m.callback then
      m.callback()
      break
    end
  end
  h.eq(select_calls, { state.filtered_items[1].value })
  h.eq(move_calls, { state.filtered_items[1].value })
  h.eq(state.active, false)
end

-- ----------------------------------------------------------------------
T["Jump.auto_activate"] = new_set({ hooks = picker_hooks })

T["Jump.auto_activate"]["pick enters jump mode synchronously"] = function()
  local state = open_picker(items_for(3), { jump = { enabled = true, auto_activate = true } })
  -- No vim.wait — auto_activate is now a synchronous call inside pick().
  h.eq(jump.is_active(state), true)
end

T["Jump.auto_activate"]["disabled jump skips auto_activate even when flag is set"] = function()
  -- auto_activate is gated behind `enabled`. Setting only auto_activate=true
  -- must be a no-op so callers can't accidentally turn it on.
  local state = open_picker(items_for(3), { jump = { auto_activate = true } })
  h.eq(jump.is_active(state), false)
end

T["Jump.auto_activate"]["numeric auto_activate activates when items <= threshold"] = function()
  local state = open_picker(items_for(3), { jump = { enabled = true, auto_activate = 3 } })
  h.eq(jump.is_active(state), true)
end

T["Jump.auto_activate"]["numeric auto_activate is inert when items exceed threshold"] = function()
  local state = open_picker(items_for(3), { jump = { enabled = true, auto_activate = 2 } })
  h.eq(jump.is_active(state), false)
end

T["Jump.auto_activate"]["numeric auto_activate = 0 never activates"] = function()
  local state = open_picker(items_for(3), { jump = { enabled = true, auto_activate = 0 } })
  h.eq(jump.is_active(state), false)
end

T["Jump.auto_activate"]["numeric auto_activate still respects min_items floor"] = function()
  -- min_items gates activate() itself, so it wins over the numeric threshold:
  -- 3 items with auto_activate=10 but min_items=5 must stay inactive.
  local state = open_picker(items_for(3), { jump = { enabled = true, auto_activate = 10, min_items = 5 } })
  h.eq(jump.is_active(state), false)
end

T["Jump.auto_activate"]["should_auto_activate predicate"] = function()
  h.eq(jump.should_auto_activate({ jump = { enabled = true, auto_activate = true } }, 999), true)
  h.eq(jump.should_auto_activate({ jump = { enabled = true, auto_activate = 5 } }, 5), true)
  h.eq(jump.should_auto_activate({ jump = { enabled = true, auto_activate = 5 } }, 6), false)
  h.eq(jump.should_auto_activate({ jump = { enabled = true, auto_activate = 0 } }, 3), false)
  h.eq(jump.should_auto_activate({ jump = { enabled = true, auto_activate = false } }, 3), false)
  h.eq(jump.should_auto_activate({ jump = { enabled = true } }, 3), false) -- nil = never
  h.eq(jump.should_auto_activate({}, 3), false) -- no jump table at all
end

-- ----------------------------------------------------------------------
T["Jump.multiselect"] = new_set({ hooks = picker_hooks })

local function fire_normal_keymap(bufnr, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == lhs and m.callback then
      m.callback()
      return true
    end
  end
  return false
end

T["Jump.multiselect"]["toggle keymap no-ops while jump is active"] = function()
  local state = open_picker(items_for(4), {
    jump = { enabled = true },
    -- normal_mode = true so multiselect Tab is also bound in normal mode,
    -- which is the only scenario where the keys could otherwise fire while
    -- jump mode (a normal-mode mode) is active.
    normal_mode = true,
    multiselect = {
      enabled = true,
      selected_icon = "● ",
      unselected_icon = "○ ",
      keymaps = { toggle = "<Tab>" },
    },
  })
  -- Sanity: outside jump, Tab toggles selection on the cursor row.
  h.eq(state.selected_count, 0)
  h.eq(fire_normal_keymap(state.prompt_buf, "<Tab>"), true)
  h.eq(state.selected_count, 1)

  -- Clear the selection so we can prove the next Tab does nothing.
  state.selected = {}
  state.selected_count = 0

  jump.activate(state, { jump = selecta.get_config().jump })
  fire_normal_keymap(state.prompt_buf, "<Tab>")
  h.eq(state.selected_count, 0, "Tab must not toggle selection during jump")

  jump.deactivate(state)
  fire_normal_keymap(state.prompt_buf, "<Tab>")
  h.eq(state.selected_count, 1, "Tab must toggle selection again after jump exits")
end

return T
