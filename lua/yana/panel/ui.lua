-- yana: the sidebar chat UI (conversation + prompt windows). Panels stack in the sidebar,
-- each with its own session, mode, model and job; commands act on the current panel
-- (cursor's, else most recently used).
local config = require("yana.config")
local agent = require("yana.agent.agent")
local context = require("yana.input.context")
local diff = require("yana.diff")
local control_plane = require("yana.safety.control_plane")
local selection_scope = require("yana.input.selection_scope")
local clipboard = require("yana.input.clipboard")
local log = require("yana.log")
local shadow_ops = require("yana.shadow.ops")
local ui_panel_views = require("yana.panel.ui_panel_views")
local ui_pickers_factory = require("yana.panel.ui_pickers")
local ui_winbar_factory = require("yana.panel.ui_winbar")
-- Pin the applier with the UI so a live turn outliving its runtime dir can still finalize and release its claim.
local shadow_apply = require("yana.shadow.apply")
-- Per-turn flight recorder: in-memory writes only; never affects control flow.
local ledger = require("yana.ledger")
-- Every notification goes through the one-line budget: a wrapped message raises a hit-enter prompt that blocks the main loop.
local notify = require("yana.notify")
local notify_one_line = notify.one_line

local M = {}

local uv = vim.uv or vim.loop
local ui_ns = vim.api.nvim_create_namespace("yana.ui")

-- Native chrome only: links follow the active colorscheme.
for name, link in pairs({
  YanaUserPrompt = "CursorLine",
  YanaActivity = "DiagnosticInfo",
  YanaMuted = "Comment",
}) do
  pcall(vim.api.nvim_set_hl, 0, name, { default = true, link = link })
end
-- Owner chrome only (WinSeparator / WinBar via winhl), never Normal.
pcall(vim.api.nvim_set_hl, 0, "YanaActivePanel", {
  default = true,
  fg = "#61afef",
  bg = "#1f2d3d",
  ctermfg = 75,
  ctermbg = 17,
})

----------------------------------------------------------------------
-- panel registry
----------------------------------------------------------------------

local panels = {}       -- list of panel state tables, in creation order
-- State holder: module values REASSIGNED after first definition live here; children read deps.state.<name> at CALL time.
local S = {}
S._panel_seq = 0
S.cancel_inflight = nil   -- defined after S.submit_panel; used by scope rejection cap
S.submit_panel = nil      -- defined below; forward-declared so on_done can drain the queue
S.maybe_drain_queue = nil -- defined below; review-close drain after release_shadow_turn
S.finalize_shadow_turn = nil -- confirmed-exit overlay consume; also used by on_done spawn-fail
S.render_note = nil

-- The panel's two private owners, each built exactly once per loaded panel: which
-- conversation holds the focus, and how many column rebuilds are in progress.
local focus = require("yana.panel.panel_focus").new()
local depth = require("yana.panel.layout_depth").new()

local function buf_valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function panel_alive(p)
  return p and buf_valid(p.conv_buf) and buf_valid(p.prompt_buf)
end

local function panel_open(p)
  -- Conv alone suffices (a stacked upper panel retires its prompt window). Visible in at least one tab: output has somewhere to land.
  return ui_panel_views.count(p) > 0
end

local function panel_open_in(p, tab)
  -- Visible in THIS tab (layout, toggle, close).
  return ui_panel_views.get(p, tab) ~= nil
end

local function new_panel_state()
  S._panel_seq = S._panel_seq + 1
  return {
    id = S._panel_seq,
    conv_buf = nil,
    prompt_buf = nil,
    -- Per-tabpage window records, owned solely by yana.panel.ui_panel_views.
    views = {},
    session_id = nil,
    session_seats = {}, -- seat-keyed vendor conversation ids; not mode-keyed
    model_actual = nil,    -- the model the VENDOR said it ran
    title = nil,           -- short session title (from the first prompt)
    mode = nil,
    job = nil,
    turn_gen = 0,          -- bumped on every submit/cancel; stale on_event/on_done no-op
    job_spawn_gen = nil,   -- turn_gen when p.job spawned; a late old exit cannot clear a newer job's state
    pending_redirect = nil, -- steer text awaiting old process death (last-wins)
    awaiting_exit = false, -- cancelled, exit not yet observed (spawn barrier)
    busy = false,
    queue = {},            -- prompts submitted while busy; cancel returns them to the prompt buffer, never drops them
    cancelled = false,     -- true when we jobstop()'d; on_done must not treat as error
    got_result = false,
    turn_errored = false,  -- finished turn rendered an agent error or failed exit; gates queue.pause_on_error
                           -- process exit) — gates queue.pause_on_error.
    rendered_any = false,  -- did this turn render any text/tool output?
    stream_text = "",
    assistant_start = 0,   -- 0-based line where the streaming answer begins
    pending_selection = nil,
    active_turn_scope = nil,
    turn_scopes = {}, -- turn_gen -> scope table or false (explicitly unscoped)
    changes = {},          -- file changes made by the agent this session
    review_epoch = 0,      -- bumped on new_chat; batch owners must match or flush must not enqueue
    -- afterFullFileContent is a PER-EDIT snapshot: touching one file twice leaves earlier `after` unmatchable (see flush_review_batch).
    review_batch = {},     -- inline mode: owning changes this turn, flushed into the review queue at turn end
    review_batch_by_path = {}, -- abs path -> owning change in review_batch
    turns = 0,
    last_question = nil,   -- composed prompt last sent (post /command + @mentions)
    cwd = nil,             -- cwd of the last submitted turn
    spinner = { timer = nil, idx = 1 },
    closing = false,       -- guard for the WinClosed sibling-close autocmd
    augroup = nil,
    scope_rejections = {}, -- per-turn out-of-zone rejections by path
    review_rejections = {}, -- per-turn inline-review rejections by path
    turn_modes = {},       -- turn_gen -> resolved mode used for that submit
    turn_backends = {},    -- turn_gen -> backend resolved at submit
    turn_end_outcome = {}, -- turn_gen -> close_turn outcome for turn.end
    turn_end_emitted = {}, -- turn_gen -> true once turn.end written
    turn_questions = {},   -- turn_gen -> composed prompt sent for that submit
    turn_answers = {},     -- turn_gen -> final assistant answer text (result payload)
    image_attachments = {}, -- visible [Image#N] tokens -> private file metadata
    next_image_id = 1,
    last_answer_text = nil, -- most recent final assistant answer text
    system_refusals = {},  -- bounded group/individual refusal summaries
    ask_advice_resend = nil, -- ask-no-edit turn: prompt <M-r>a should resend
  }
end

-- Single destruction site for a dead panel: whoever unsubscribes also nils the field.
local function destroy_panel(p)
  if not p then
    return
  end
  if p.unsubscribe_review then
    pcall(p.unsubscribe_review)
    p.unsubscribe_review = nil
  end
  if p.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, p.augroup)
    p.augroup = nil
  end
end

local function prune_panels()
  for i = #panels, 1, -1 do
    if not panel_alive(panels[i]) then
      -- The panel's real destruction. close_panel keeps the panel alive (only closes windows), so release happens here only.
      destroy_panel(panels[i])
      table.remove(panels, i)
    else
      -- Drop dead view records only; V.prune never removes a panel, keeping this the single destruction site.
      ui_panel_views.prune(panels[i])
    end
  end
  focus:prune(panel_alive)
end

local function panel_for_buf(buf)
  for _, p in ipairs(panels) do
    if p.conv_buf == buf or p.prompt_buf == buf then
      return p
    end
  end
  return nil
end

-- Global half of <C-c> focus tracking: entering a NORMAL or terminal buffer that is not a panel's own means the user left
-- yana. Transient/plugin buffers (noice, popups, quickfix) neither grant nor revoke it. BufEnter is included because
-- WinEnter alone misses a buffer swap in the same window; a terminal owns its own <C-c> (install_stop_on_key).
vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  group = vim.api.nvim_create_augroup("YanaFocusTrack", { clear = true }),
  callback = function(ev)
    log.guard("yana.ui YanaFocusTrack", function()
      local bt = vim.bo[ev.buf].buftype
      if (bt == "" or bt == "terminal") and not panel_for_buf(ev.buf) then
        focus:set_focused(nil)
      end
    end)
  end,
})

local function find_panel_by_session(session_id)
  if not session_id then
    return nil
  end
  for _, p in ipairs(panels) do
    if p.session_id == session_id and panel_alive(p) then
      return p
    end
  end
  return nil
end

-- The panel commands act on: the one under the cursor, else the most
-- recently used, else any open one, else the newest alive one.
local function current_panel()
  prune_panels()
  local p = panel_for_buf(vim.api.nvim_get_current_buf())
  if p then
    return p
  end
  if focus:last() then
    return focus:last()
  end
  if focus:primary() and panel_alive(focus:primary()) then
    return focus:primary()
  end
  for _, q in ipairs(panels) do
    if panel_open(q) then
      return q
    end
  end
  return panels[#panels]
end

local function panel_index(p)
  for i, q in ipairs(panels) do
    if q == p then
      return i
    end
  end
  return 0
end

----------------------------------------------------------------------
-- low-level buffer helpers
----------------------------------------------------------------------

-- Render primitives (yana.panel.ui_render), instantiated early: append/set_lines are the highest fan-in helpers.
local ui_render_factory = require("yana.panel.ui_render")
local ui_render = ui_render_factory.new({
  buf_valid = buf_valid,
  win_valid = win_valid,
  ui_ns = ui_ns,
})
local set_lines = ui_render.set_lines
local scroll_to_bottom = ui_render.scroll_to_bottom
local decorate_append = ui_render.decorate_append
local turn_ledger = ui_render.turn_ledger
local with_render_gen = ui_render.with_render_gen
local append = ui_render.append
local render_user = ui_render.render_user
local backend_label = ui_render.backend_label
local start_assistant_block = ui_render.start_assistant_block
local render_stream = ui_render.render_stream
local append_stream = ui_render.append_stream
local commit_stream = ui_render.commit_stream
local tool_activity = ui_render.tool_activity
local render_tool_note = ui_render.render_tool_note
local utf8_safe_truncate = ui_render.utf8_safe_truncate
local render_error = ui_render.render_error

----------------------------------------------------------------------
-- mode lock
----------------------------------------------------------------------

-- A chat's mode is fixed at its first turn (cursor-agent workaround): mode is per-message and an explicit `--mode` wins,
-- but OMITTING it inherits the previous message's mode, and only `--mode plan|ask` exists (no `--mode agent`). Locking
-- per chat means an agent chat never inherits ask; changing mode means a new chat (new upstream session). Lock once an
-- upstream session identity exists (init received or restored on resume).
local update_winbar
local ui_modes_factory = require("yana.panel.ui_modes")
local ui_modes = ui_modes_factory.new({
  current_panel = current_panel,
  update_winbar = function(p)
    return update_winbar(p)
  end,
  turn_ledger = turn_ledger,
})
local mode_change_blocked = ui_modes.mode_change_blocked
local remember_seat_session = ui_modes.remember_seat_session
local restore_seat_session = ui_modes.restore_seat_session
local renewal_blocked_reason = ui_modes.renewal_blocked_reason
local build_apply_resend = ui_modes.build_apply_resend
local renewal_brief = ui_modes.renewal_brief
local seat_shared_context = ui_modes.seat_shared_context
local mode_change_refused_notify = ui_modes.mode_change_refused_notify
local reconcile_pending = ui_modes.reconcile_pending
-- Also required directly: used outside the mode-lock cluster.
local renewal = require("yana.agent.renewal")

----------------------------------------------------------------------
-- turn liveness: elapsed, last event, stall notice
----------------------------------------------------------------------
-- Reports elapsed time, time since the last event, a short label, and `stalled` past a fixed threshold. It never kills:
-- a live process is not dead because its output paused (nested tasks run minutes silently); automatic death
-- classification belongs solely to the claims-concurrency rules and requires an EMPTY process set. :YanaStop acts.
-- PRODUCT POLICY, not an operator option: 90 s is about four times the widest gap ever observed.

local ui_liveness_factory = require("yana.panel.ui_liveness")
local ui_liveness = ui_liveness_factory.new({
  state = S,
  update_winbar = function(p)
    return update_winbar(p)
  end,
})
local stall_threshold_ms = ui_liveness.stall_threshold_ms
local liveness_for = ui_liveness.liveness_for
local liveness_text = ui_liveness.liveness_text
local note_liveness_event = ui_liveness.note_liveness_event
local stop_spinner = ui_liveness.stop_spinner
local start_spinner = ui_liveness.start_spinner


-- Winbar / chip rendering: yana.panel.ui_winbar.
local ui_winbar = ui_winbar_factory.new({
  panels = panels,
  panel_index = panel_index,
  win_valid = win_valid,
  liveness_text = liveness_text,
  reconcile_pending = reconcile_pending,
})
update_winbar = ui_winbar.update_winbar
local winbar_text = ui_winbar.winbar_text
local prompt_winbar_text = ui_winbar.prompt_winbar_text
local fit_winbar = ui_winbar.fit_winbar
local mode_chip = ui_winbar.mode_chip
local model_chip = ui_winbar.model_chip
local trunc_display = ui_winbar.trunc_display

-- Instantiated early so later clusters read these as plain in-scope locals (same placement as ui_render).
local ui_claims_factory = require("yana.panel.ui_claims")
local ui_claims = ui_claims_factory.new({
  state = S,
  append = append,
  commit_stream = commit_stream,
  update_winbar = update_winbar,
  buf_valid = buf_valid,
  start_spinner = start_spinner,
  stop_spinner = stop_spinner,
})
local begin_accept_indication = ui_claims.begin_accept_indication
local change_footer_text = ui_claims.change_footer_text
local conv_base_line = ui_claims.conv_base_line
local change_header_text = ui_claims.change_header_text
local stamp_undeclared_badge = ui_claims.stamp_undeclared_badge
local refresh_change_block = ui_claims.refresh_change_block
local reload_after_scope_revert = ui_claims.reload_after_scope_revert
local scope_rejection_cap_note = ui_claims.scope_rejection_cap_note
local bump_scope_rejection = ui_claims.bump_scope_rejection
local review_rejection_cap_note = ui_claims.review_rejection_cap_note
local bump_review_rejection = ui_claims.bump_review_rejection
local render_scope_rejection = ui_claims.render_scope_rejection
local panel_claimed_workspace = ui_claims.panel_claimed_workspace
local refresh_review_claim = ui_claims.refresh_review_claim
local preview_module = ui_claims.preview_module
local emit_turn_end = ui_claims.emit_turn_end
local release_shadow_turn = ui_claims.release_shadow_turn
local retain_shadow_turn = ui_claims.retain_shadow_turn

local ui_review_factory = require("yana.panel.ui_review")
local ui_review = ui_review_factory.new({
  state = S,
  append = append,
  commit_stream = commit_stream,
  turn_ledger = turn_ledger,
  update_winbar = update_winbar,
  current_panel = current_panel,
  panel_claimed_workspace = panel_claimed_workspace,
  refresh_change_block = refresh_change_block,
  refresh_review_claim = refresh_review_claim,
  release_shadow_turn = release_shadow_turn,
  preview_module = preview_module,
  begin_accept_indication = begin_accept_indication,
  change_header_text = change_header_text,
  change_footer_text = change_footer_text,
  conv_base_line = conv_base_line,
  stamp_undeclared_badge = stamp_undeclared_badge,
  bump_review_rejection = bump_review_rejection,
})
local refresh_all_review_claims = ui_review.refresh_all_review_claims
local MAX_REVIEW_RETRY = ui_review.MAX_REVIEW_RETRY
local REVIEW_RETRY_EXHAUSTED = ui_review.REVIEW_RETRY_EXHAUSTED
local inline_review_opts = ui_review.inline_review_opts
local coalesce_into_owner = ui_review.coalesce_into_owner
local flush_review_batch = ui_review.flush_review_batch
local drop_review_batch = ui_review.drop_review_batch
local render_tool_change = ui_review.render_tool_change

local ui_changes_factory = require("yana.panel.ui_changes")
local ui_changes = ui_changes_factory.new({
  current_panel = current_panel,
  update_winbar = update_winbar,
  turn_ledger = turn_ledger,
  refresh_change_block = refresh_change_block,
  panel_claimed_workspace = panel_claimed_workspace,
  inline_review_opts = inline_review_opts,
  MAX_REVIEW_RETRY = MAX_REVIEW_RETRY,
  REVIEW_RETRY_EXHAUSTED = REVIEW_RETRY_EXHAUSTED,
})
M.show_changes = ui_changes.show_changes
M.accept_change = ui_changes.accept_change
M.reject_change = ui_changes.reject_change
M.accept_changes = ui_changes.accept_changes
M.reject_changes = ui_changes.reject_changes
M.review_changes = ui_changes.review_changes

S.render_note = function(p, text)
  append(p, { "  " .. notify.flatten(text), "" }, "note")
end

-- Pure-function boundary probe for the headless row (no panel needed).
M._test = M._test or {}
M._test.utf8_safe_truncate = utf8_safe_truncate

----------------------------------------------------------------------
-- event handling / refusal recording / turn completion (ui_events, ui_turn_shadow, ui_turn_end).
-- shadow_turn_gen is exposed on S (assigned below) because BOTH ui_turn_shadow and ui_turn_end call it.
----------------------------------------------------------------------
local ui_events_factory = require("yana.panel.ui_events")
local ui_events = ui_events_factory.new({
  state = S,
  append = append,
  append_stream = append_stream,
  render_tool_note = render_tool_note,
  render_user = render_user,
  start_assistant_block = start_assistant_block,
  render_error = render_error,
  turn_ledger = turn_ledger,
  with_render_gen = with_render_gen,
  update_winbar = update_winbar,
  panel_open = panel_open,
  panel_open_in = panel_open_in,
  preview_module = preview_module,
  remember_seat_session = remember_seat_session,
  note_liveness_event = note_liveness_event,
})
local turn_evidence_dir = ui_events.turn_evidence_dir
local on_event = ui_events.on_event
S.shadow_turn_gen = ui_events.shadow_turn_gen
local refusal_kind_summary = ui_events.refusal_kind_summary
local record_control_plane_refusals = ui_events.record_control_plane_refusals
local write_through_ignored = ui_events.write_through_ignored
local record_artifact_refusals = ui_events.record_artifact_refusals
local record_confinement_refusals = ui_events.record_confinement_refusals

local ui_turn_shadow_factory = require("yana.panel.ui_turn_shadow")
local ui_turn_shadow = ui_turn_shadow_factory.new({
  state = S,
  render_error = render_error,
  turn_ledger = turn_ledger,
  with_render_gen = with_render_gen,
  render_tool_change = render_tool_change,
  preview_module = preview_module,
  release_shadow_turn = release_shadow_turn,
  retain_shadow_turn = retain_shadow_turn,
  record_confinement_refusals = record_confinement_refusals,
  write_through_ignored = write_through_ignored,
  record_artifact_refusals = record_artifact_refusals,
  record_control_plane_refusals = record_control_plane_refusals,
})

-- Defined below; each service that needs one is handed a named forwarder, so the
-- callback is still resolved at call time without a registry to look it up in.
local submit_panel
local steer_text

local ui_turn_end_factory = require("yana.panel.ui_turn_end")
local ui_turn_end = ui_turn_end_factory.new({
  shadow_turn_gen = ui_events.shadow_turn_gen,
  finalize_shadow_turn = S.finalize_shadow_turn,
  maybe_drain_queue = S.maybe_drain_queue,
  submit_panel = function(p, opts)
    return submit_panel(p, opts)
  end,
  turn_evidence_dir = turn_evidence_dir,
  append = append,
  render_error = render_error,
  backend_label = backend_label,
  turn_ledger = turn_ledger,
  inline_review_opts = inline_review_opts,
  flush_review_batch = flush_review_batch,
  emit_turn_end = emit_turn_end,
  build_apply_resend = build_apply_resend,
  update_winbar = update_winbar,
  panel_open = panel_open,
  stop_spinner = stop_spinner,
  buf_valid = buf_valid,
  M = M,
})
local last_stderr_line = ui_turn_end.last_stderr_line
local on_done = ui_turn_end.on_done
local on_exit_confirmed = ui_turn_end.on_exit_confirmed
local set_model_actual = ui_turn_end.set_model_actual

----------------------------------------------------------------------
-- submit / queue
----------------------------------------------------------------------

-- submit_panel, M.submit, M.resend: yana.panel.ui_submit. cancel_inflight, M.stop, M.steer, M.pick_queue: yana.panel.ui_queue.
local ui_submit_factory = require("yana.panel.ui_submit")
local ui_submit_deps = {
  focus = focus,
  finalize_shadow_turn = S.finalize_shadow_turn,
  render_note = S.render_note,
  steer_text = function(p, text, opts)
    return steer_text(p, text, opts)
  end,
  on_event = on_event,
  set_model_actual = set_model_actual,
  on_done = on_done,
  on_exit_confirmed = on_exit_confirmed,
  M = M,
  panel_open = panel_open,
  panel_open_in = panel_open_in,
  buf_valid = buf_valid,
  current_panel = current_panel,
  panels = panels,
  update_winbar = update_winbar,
  render_user = render_user,
  start_assistant_block = start_assistant_block,
  start_spinner = start_spinner,
  stop_spinner = stop_spinner,
  render_error = render_error,
  seat_shared_context = seat_shared_context,
  expand_attachments = function(p, text, opts)
    return M.expand_attachments(p, text, opts)
  end,
}
local ui_submit = ui_submit_factory.new(ui_submit_deps)
submit_panel = ui_submit.submit_panel
S.submit_panel = submit_panel
M.submit = ui_submit.submit
M.resend = ui_submit.resend

local ui_queue_factory = require("yana.panel.ui_queue")
local ui_queue = ui_queue_factory.new({
  state = S,
  buf_valid = buf_valid,
  win_valid = win_valid,
  current_panel = current_panel,
  update_winbar = update_winbar,
  stop_spinner = stop_spinner,
  liveness_for = liveness_for,
  stall_threshold_ms = stall_threshold_ms,
})
S.cancel_inflight = ui_queue.cancel_inflight
steer_text = S.steer_text
M.stop = ui_queue.stop
M.steer = ui_queue.steer
M.pick_queue = ui_queue.pick_queue

-- Panel <C-c> target accessor, paste and stop-key: yana.panel.ui_input.
M._stop_key_probe = { seen = 0, mode = nil, had_panel = nil, had_job = nil, scheduled = false, error = nil }
local ui_input_factory = require("yana.panel.ui_input")
local ui_input = ui_input_factory.new({
  state = S,
  focus = focus,
  M = M,
  buf_valid = buf_valid,
  win_valid = win_valid,
  current_panel = current_panel,
})
function M.focused_panel()
  return ui_input.focused_panel()
end

-- Sidebar panel that owns a review (by review_owner.panel_id), or the current
-- open panel. Used by the review button strip; nil when no sidebar is open.
function M.panel_for_owner(owner)
  prune_panels()
  if owner and owner.panel_id ~= nil then
    for _, p in ipairs(panels) do
      if p.id == owner.panel_id then
        return panel_open(p) and p or nil
      end
    end
  end
  local p = current_panel()
  return p and panel_open(p) and p or nil
end
function M.insert_at_cursor(bufnr, winid, text)
  return ui_input.insert_at_cursor(bufnr, winid, text)
end
function M.expand_attachments(p, text, opts)
  return ui_input.expand_attachments(p, text, opts)
end
function M.paste_image()
  return ui_input.paste_image()
end
local install_stop_on_key = ui_input.install_stop_on_key


-- mode / chat management: yana.panel.ui_modes.
M.toggle_mode = ui_modes.toggle_mode
M.set_mode = ui_modes.set_mode
M.panel_write_capable = ui_modes.panel_write_capable
M.ensure_agent_mode = ui_modes.ensure_agent_mode

-- Layer-1 (backend/vendor) and layer-2 (model) pickers: yana.panel.ui_pickers.
local ui_pickers = ui_pickers_factory.new({
  panels = panels,
  current_panel = current_panel,
  update_winbar = update_winbar,
})
M.pick_model = ui_pickers.pick_model
M.pick_backend = ui_pickers.pick_backend
M.pick_vendor_then_model = ui_pickers.pick_vendor_then_model


M.render_greeting = ui_render.render_greeting

----------------------------------------------------------------------
-- window construction / panel lifecycle (yana.panel.ui_panel). The panel bookkeeping above stays here:
-- sibling modules already depend on those as plain values.
----------------------------------------------------------------------
local ui_panel_factory = require("yana.panel.ui_panel")
local ui_panel = ui_panel_factory.new({
  state = S,
  focus = focus,
  depth = depth,
  cancel_inflight = ui_queue.cancel_inflight,
  maybe_drain_queue = S.maybe_drain_queue,
  M = M,
  panels = panels,
  panel_open = panel_open,
  panel_open_in = panel_open_in,
  buf_valid = buf_valid,
  win_valid = win_valid,
  new_panel_state = new_panel_state,
  current_panel = current_panel,
  panel_index = panel_index,
  panel_for_buf = panel_for_buf,
  prune_panels = prune_panels,
  destroy_panel = destroy_panel,
  install_stop_on_key = install_stop_on_key,
  paste_into_panel = ui_input.paste_into_panel,
  update_winbar = update_winbar,
  prompt_winbar_text = prompt_winbar_text,
  refresh_all_review_claims = refresh_all_review_claims,
  stop_spinner = stop_spinner,
})
local apply_panel_keymaps = ui_panel.apply_panel_keymaps
local setup_panel_autocmds = ui_panel.setup_panel_autocmds
local relayout = ui_panel.relayout
local open_windows = ui_panel.open_windows
-- WINDOW OWNERSHIP as a fact, not a geometry inference (equal column/width let one panel's review resize and destroy
-- a sibling's panes): one entry per conversation visible in `tab`, in creation order, with the window ids that panel
-- alone owns. Read-only fresh copies; `prompt` is nil except for the panel holding the column's single prompt slot.
function M.panel_views(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local views = require("yana.panel.ui_panel_views")
  local out = {}
  for i, p in ipairs(panels) do
    local v = views.get(p, tab)
    if v then
      out[#out + 1] = {
        index = i,
        panel = p,
        conv = v.conv,
        prompt = v.prompt,
      }
    end
  end
  return out
end

-- The panel index owning `win` in `tab`, plus which view it is
-- ("conv"/"prompt"), or nil when no panel owns it.
function M.window_owner(win, tab)
  for _, v in ipairs(M.panel_views(tab)) do
    if v.conv == win then
      return v.index, "conv"
    end
    if v.prompt == win then
      return v.index, "prompt"
    end
  end
  return nil
end

M.is_open = ui_panel.is_open
M.panel_count = ui_panel.panel_count
M.current_session_id = ui_panel.current_session_id
M.focus_prompt = ui_panel.focus_prompt
M.open = ui_panel.open
M.open_in_tab = ui_panel.open_in_tab
M.open_new_panel = ui_panel.open_new_panel
M.quit_current = ui_panel.quit_current
M.quit_all = ui_panel.quit_all
M.close_panel = ui_panel.close_panel
M.close = ui_panel.close
M.toggle = ui_panel.toggle
M.next_panel = ui_panel.next_panel
M.prev_panel = ui_panel.prev_panel
-- Small panel/claim command utilities (yana.panel.ui_commands); deps.M lets it call other clusters' commands in any extraction order.
local ui_commands_factory = require("yana.panel.ui_commands")
local ui_commands = ui_commands_factory.new({
  state = S,
  M = M,
  panels = panels,
  panel_open = panel_open,
  panel_open_in = panel_open_in,
  buf_valid = buf_valid,
  current_panel = current_panel,
  panel_for_buf = panel_for_buf,
  open_new_panel = ui_panel.open_new_panel,
  update_winbar = update_winbar,
  preview_module = preview_module,
  release_shadow_turn = release_shadow_turn,
  drop_review_batch = drop_review_batch,
  inline_review_opts = inline_review_opts,
  refusal_kind_summary = refusal_kind_summary,
  set_lines = set_lines,
})
M.new_chat = ui_commands.new_chat
M.dump_diary_session = ui_commands.dump_diary_session
M.panel_turn_keys = ui_commands.panel_turn_keys


-- Live-daemon session attachment: yana.panel.ui_sessions.
local ui_sessions_factory = require("yana.panel.ui_sessions")
local ui_sessions = ui_sessions_factory.new({
  current_panel = current_panel,
  panel_open = panel_open,
  panel_open_in = panel_open_in,
  open_windows = open_windows,
  open_new_panel = ui_panel.open_new_panel,
  focus_prompt = M.focus_prompt,
  update_winbar = update_winbar,
  remember_seat_session = remember_seat_session,
  start_new_session = function(target)
    if target then
      M.new_chat()
    else
      ui_panel.open_new_panel()
    end
  end,
  recover_session = function(row, target)
    return require("yana.runtime.yanad_recover").recover(row.session_id, {
      panel = target,
      current_panel = current_panel,
      inline_review_opts = inline_review_opts,
      render_change = render_tool_change,
      notify = notify_one_line,
    })
  end,
})
M.list_live_sessions = ui_sessions.list_live
M.check_recovery = ui_sessions.check_recovery
M.recover = ui_sessions.recover

-- Attach a selection to the next submitted prompt and open the panel.
-- selection: table from context.selection_from_range (or nil).
-- question: optional; if given, submit immediately.
M.ask = ui_commands.ask
M.inline_edit = ui_commands.inline_edit
M.system_refused_lines = ui_commands.system_refused_lines
M.show_refusals = ui_commands.show_refusals

M._test = M._test or {}
M._test.force_turn_edits = nil
M._test.on_done = on_done
M._test.emit_turn_end = emit_turn_end
M._test.on_event = on_event
M._test.on_exit_confirmed = on_exit_confirmed
M._test.maybe_drain_queue = function(p)
  return S.maybe_drain_queue(p)
end
M._test.finalize_shadow_turn = S.finalize_shadow_turn
M._test.render_tool_change = render_tool_change
M._test.flush_review_batch = flush_review_batch
M._test.REVIEW_RETRY_EXHAUSTED = REVIEW_RETRY_EXHAUSTED
M._test.MAX_REVIEW_RETRY = MAX_REVIEW_RETRY
M._test.inline_review_opts = inline_review_opts
M._test.change_footer_text = change_footer_text
M._test.begin_accept_indication = begin_accept_indication
M._test.panel_claimed_workspace = panel_claimed_workspace
M._test.new_chat = M.new_chat
M._test.expand_attachments = ui_submit_deps.expand_attachments
-- Exported so a row can prove the REFUSALS fire, not merely that a switch succeeds.
M._test.renewal_blocked_reason = renewal_blocked_reason
M._test.renewal_brief = renewal_brief
M._test.winbar_text = winbar_text
M._test.update_winbar = update_winbar
M._test.mode_chip = mode_chip
M._test.model_chip = model_chip
M._test.set_model_actual = set_model_actual
M._test.fit_winbar = fit_winbar
M._test.trunc_display = trunc_display
M._test.backend_label = backend_label
M._test.turn_evidence_dir = turn_evidence_dir
M._test.last_stderr_line = last_stderr_line
-- Liveness seams: the threshold is policy with no operator option; tests move the one number from here. `liveness`
-- exposes per-turn state so a row can assert the pairing, not only its text.
M._test.set_stall_threshold_ms = ui_liveness.set_stall_threshold_override
M._test.stall_threshold_ms = stall_threshold_ms
M._test.liveness = function(p)
  return p and liveness_for(p) or nil
end

-- The configured side-panel observer reads this key without requiring it.
package.loaded["yana.ui"] = M

return M
