-- Panel window construction/keymaps and lifecycle (open/close/quit/toggle), split out of yana.ui.
-- deps.M is the parent's own module table (never reassigned), so it resolves in any extraction order.
local M = {}

-- deps.state: parent's shared table S; deps.M: parent's module table; the rest are the parent's panel helpers.
function M.new(deps)
  local focus_prompt_ref = {}
  local layout = require("yana.panel.ui_panel_layout").new(vim.tbl_extend("force", deps, {
    focus_prompt = function(p, tab)
      if focus_prompt_ref.fn then
        return focus_prompt_ref.fn(p, tab)
      end
    end,
  }))

  -- Late-bound lifecycle refs: keymaps are constructed before lifecycle but
  -- call into it at key-press time, not at map-install time.
  local lifecycle_ref = {}
  local keymaps = require("yana.panel.ui_panel_keymaps").new(vim.tbl_extend("force", deps, {
    close_panel = function(p)
      return lifecycle_ref.close_panel(p)
    end,
    open_new_panel = function()
      return lifecycle_ref.open_new_panel()
    end,
    focus_prompt = function(p)
      return lifecycle_ref.focus_prompt(p)
    end,
    next_panel = layout.next_panel,
    prev_panel = layout.prev_panel,
  }))
  local autocmds = require("yana.panel.ui_panel_autocmds").new(vim.tbl_extend("force", deps, {
    ensure_prompt_win = layout.ensure_prompt_win,
    panels_in_column = layout.panels_in_column,
  }))

  lifecycle_ref = require("yana.panel.ui_panel_lifecycle").new(vim.tbl_extend("force", deps, {
    apply_panel_keymaps = keymaps.apply_panel_keymaps,
    setup_panel_autocmds = autocmds.setup_panel_autocmds,
    set_panel_buf_opts = layout.set_panel_buf_opts,
    open_windows = layout.open_windows,
    relayout = layout.relayout,
    ensure_prompt_win = layout.ensure_prompt_win,
    panels_in_column = layout.panels_in_column,
    show_next_after_close = layout.show_next_after_close,
  }))
  focus_prompt_ref.fn = lifecycle_ref.focus_prompt

  return {
    apply_panel_keymaps = keymaps.apply_panel_keymaps,
    setup_panel_autocmds = autocmds.setup_panel_autocmds,
    relayout = layout.relayout,
    open_windows = layout.open_windows,
    is_open = lifecycle_ref.is_open,
    panel_count = lifecycle_ref.panel_count,
    current_session_id = lifecycle_ref.current_session_id,
    focus_prompt = lifecycle_ref.focus_prompt,
    open = lifecycle_ref.open,
    open_new_panel = lifecycle_ref.open_new_panel,
    open_in_tab = lifecycle_ref.open_in_tab,
    quit_current = lifecycle_ref.quit_current,
    quit_all = lifecycle_ref.quit_all,
    close_panel = lifecycle_ref.close_panel,
    close = lifecycle_ref.close,
    toggle = lifecycle_ref.toggle,
    next_panel = layout.next_panel,
    prev_panel = layout.prev_panel,
  }
end

return M
