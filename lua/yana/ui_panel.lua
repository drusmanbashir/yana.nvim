-- Panel window construction/keymaps and lifecycle (open/close/quit/toggle), split out
-- of yana.ui (cluster 8). Those go through `deps.M` (the parent's own module table,
-- never reassigned, so this resolves correctly regardless of extraction order) -- the
-- same `ui_M` mechanism yana.ui_submit's `resend` already uses for
-- `M.new_chat`/`M.set_mode`. The ELEVEN functions that actually belong to THIS cluster
-- (is_open/panel_count/
local M = {}

-- deps.state: the parent's shared state table `S` -- read/write S.last_panel,
-- S.last_focused_panel; call S.submit_panel, S.cancel_inflight, S.render_note,
-- S.maybe_drain_queue. deps.M: the parent's own module table (see header above).
-- deps.panels / deps.panel_open / deps.buf_valid / deps.win_valid /
-- deps.new_panel_state / deps.current_panel / deps.panel_index / deps.panel_for_buf /
-- deps.prune_panels / deps.destroy_panel / deps.install_stop_on_key: parent's panel
function M.new(deps)
  local focus_prompt_ref = {}
  local layout = require("yana.ui_panel_layout").new(vim.tbl_extend("force", deps, {
    focus_prompt = function(p, tab)
      if focus_prompt_ref.fn then
        return focus_prompt_ref.fn(p, tab)
      end
    end,
  }))

  -- Late-bound lifecycle refs: keymaps are constructed before lifecycle but
  -- call into it at key-press time, not at map-install time.
  local lifecycle_ref = {}
  local keymaps = require("yana.ui_panel_keymaps").new(vim.tbl_extend("force", deps, {
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
  local autocmds = require("yana.ui_panel_autocmds").new(vim.tbl_extend("force", deps, {
    ensure_prompt_win = layout.ensure_prompt_win,
    panels_in_column = layout.panels_in_column,
  }))

  lifecycle_ref = require("yana.ui_panel_lifecycle").new(vim.tbl_extend("force", deps, {
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
