-- yana: the sidebar chat UI (conversation + prompt windows) and streaming
-- render of cursor-agent responses.
--
-- Multiple panels can be open at once, each with its own session, mode, model
-- and in-flight job, so several conversations can run in parallel. Panels
-- stack vertically inside the sidebar column. Commands act on the "current"
-- panel: the one your cursor is in, else the most recently used one.
local config = require("yana.config")
local agent = require("yana.agent")
local context = require("yana.context")
local diff = require("yana.diff")
local control_plane = require("yana.safety.control_plane")
local selection_scope = require("yana.selection_scope")
local clipboard = require("yana.clipboard")
local log = require("yana.log")
local shadow_ops = require("yana.shadow.ops")
local ui_panel_views = require("yana.ui_panel_views")
local ui_pickers_factory = require("yana.ui_pickers")
local ui_winbar_factory = require("yana.ui_winbar")
-- A live turn may outlast the runtime directory it started from (plugin
-- update/rename). Pin the applier with the UI so finalize can still classify,
-- settle, and release that turn instead of stranding its workspace claim.
local shadow_apply = require("yana.shadow.apply")
-- The per-turn flight recorder. Every call in this file is an in-memory table
-- write; nothing here reaches disk, and nothing here can change control flow.
local ledger = require("yana.ledger")
-- Every notification in this file goes through the one-line budget: several
-- embed arbitrary-length strings (paths, review_error text, agent output), and
-- a wrapped message raises a hit-enter prompt that blocks the main loop --
-- freezing queue pumps and claim repaints until a human presses a key.
local notify = require("yana.notify")
local notify_one_line = notify.one_line

local M = {}

local uv = vim.uv or vim.loop
local ui_ns = vim.api.nvim_create_namespace("yana.ui")

-- Native Neovim chrome only. Links keep Yana inside the active colorscheme;
-- no palette, icon font, or decoration dependency is imposed on the user.
for name, link in pairs({
  YanaUserPrompt = "CursorLine",
  YanaActivity = "DiagnosticInfo",
  YanaMuted = "Comment",
}) do
  pcall(vim.api.nvim_set_hl, 0, name, { default = true, link = link })
end
-- Owner chrome only (WinSeparator / WinBar via winhl) — never Normal. A
-- dedicated step off Normal that is not Visual (selection) and not the
-- default WinSeparator grey, under both --clean and onedark-warmer.
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
-- State holder: every module-level value that is REASSIGNED after its first
-- definition lives here as a field, not a bare local. Children receive this
-- same table via deps.state and read deps.state.<name> at CALL time, which
-- removes the "forward-declared, assigned later" closure hazard entirely.
local S = {}
S.last_panel = nil  -- most recently focused/used panel
-- Tracked (not sampled) panel focus for the <C-c> stop hook: set only when a panel's
-- own conv_buf/prompt_buf is entered, cleared only when a NORMAL (buftype "") non-panel
-- buffer is entered. Transient/plugin buffers (e.g. a noice message window, buftype
-- "nofile") do neither, so a notification popping up and stealing the current window
-- cannot silently revoke the panel's claim on <C-c> — see setup_panel_autocmds and the
-- global YanaFocusTrack augroup below.
S.last_focused_panel = nil
-- "The" sidebar conversation -- current_panel() prefers this over "any open
-- panel" so an incidental additional panel never steals focus from the one
-- the operator thinks of as THE sidebar conversation.
--
-- A CACHE, not a fact: the answer is `sidebar_panel()` in
-- yana.ui_panel_lifecycle, which is this field's ONE claim site and re-adopts
-- whenever it reads nil. quit_panel and prune_panels (below) may clear it at
-- any moment, which is safe precisely because nothing treats the cleared
-- state as "no conversation exists" -- reading it directly is what stacked a
-- second pane under the operator's sidebar.
S.primary_panel = nil
S._panel_seq = 0
S.cancel_inflight = nil   -- defined after S.submit_panel; used by scope rejection cap
S.submit_panel = nil      -- defined below; forward-declared so on_done can drain the queue
S.maybe_drain_queue = nil -- defined below; review-close drain after release_shadow_turn
S.finalize_shadow_turn = nil -- confirmed-exit overlay consume; also used by on_done spawn-fail
S.render_note = nil

-- Late-bound function registry: every cross-cluster call goes through this
-- table instead of a direct upvalue read. ui.lua assigns F.x = x as each
-- function is defined (local or from a child module); children call
-- deps.fn.<name>(...) which resolves at CALL time, so extraction order no
-- longer matters and no child needs to require its parent.
local F = {}

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
  -- Conv alone is enough: a stacked upper panel retires its prompt window
  -- while a newer panel owns the column's single bottom input slot. Visible
  -- in AT LEAST ONE tab -- what streaming/queue/turn-end guards want to know
  -- ("is there anywhere for output to land").
  return ui_panel_views.count(p) > 0
end

local function panel_open_in(p, tab)
  -- Visible in THIS tab -- what layout, toggle and close want to know
  -- ("is it in front of me").
  return ui_panel_views.get(p, tab) ~= nil
end

local function new_panel_state()
  S._panel_seq = S._panel_seq + 1
  return {
    id = S._panel_seq,
    conv_buf = nil,
    prompt_buf = nil,
    -- Per-tabpage window records, owned solely by yana.ui_panel_views; a
    -- panel visible in three tabs has three. Replaces the old scalar
    -- window-handle fields, which held exactly one window pair and could
    -- not represent "shown in more than one tabpage at once".
    views = {},
    session_id = nil,
    session_seats = {}, -- seat-keyed vendor conversation ids (O1/O6); not mode-keyed
    model_actual = nil,    -- the model the VENDOR said it ran, set only by
    title = nil,           -- short session title (from the first prompt)
    mode = nil,
    job = nil,
    turn_gen = 0,          -- bumped on every submit/cancel; stale on_event/on_done no-op
    job_spawn_gen = nil,   -- turn_gen at which p.job was spawned; the correlation token
                           -- for on_exit_confirmed/escalation timers, so a late old
                           -- exit can never clear bookkeeping for a newer job (I2).
    pending_redirect = nil, -- steer text waiting for the old process to die (I4,
                           -- last-wins: a second steer while waiting replaces this).
    awaiting_exit = false, -- cancelled, exit not yet observed (spawn barrier, I1).
    busy = false,
    queue = {},            -- prompts submitted while busy; sent in order once the
                           -- in-flight turn finishes. Only ever emptied by draining
                           -- or by explicit user action in the queue picker — a
                           -- cancel (stop/new_chat/scope-cap) returns queued items
                           -- to the prompt buffer instead of dropping them.
    cancelled = false,     -- true when we jobstop()'d; on_done must not treat as error
    got_result = false,
    turn_errored = false,  -- did the turn that just finished render an agent error?
                           -- (agent-level `is_error`/`error` event, or a failed
                           -- process exit) — gates queue.pause_on_error.
    rendered_any = false,  -- did this turn render any text/tool output?
    stream_text = "",
    assistant_start = 0,   -- 0-based line where the streaming answer begins
    pending_selection = nil,
    active_turn_scope = nil,
    turn_scopes = {}, -- turn_gen -> scope table or false (explicitly unscoped)
    changes = {},          -- file changes made by the agent this session
    review_epoch = 0,      -- bumped on new_chat; owners stamped at batch time must
                           -- match or flush must not enqueue (H4).
    review_batch = {},     -- inline mode: owning changes for this turn, insertion
                           -- order, flushed into the review queue at turn end.
                           -- cursor-agent self-applies to disk and keeps going, so
                           -- afterFullFileContent is a PER-EDIT snapshot: the moment it
                           -- touches one file twice, every earlier change's `after` is
                           -- permanently unmatchable and the CAS in open_review_buffer
                           -- refuses it forever. See flush_review_batch.
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

-- Drop panels whose buffers were wiped out from under us. Everything a dead panel has
-- to hand back, in one place. This is the single destruction site, and the invariant
-- "whoever unsubscribes also nils the field" is enforced here rather than by comment.
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
      -- The panel's real destruction. close_panel keeps the panel alive on
      -- purpose (it only closes windows), so unsubscribing there froze claims
      -- across a toggle -- which is why release happens here and nowhere else.
      destroy_panel(panels[i])
      table.remove(panels, i)
    else
      -- Drop this survivor's dead view records (closed tabs, closed
      -- windows). V.prune only removes view records -- never a panel, never
      -- destroy_panel -- so this stays the single panel-destruction site.
      ui_panel_views.prune(panels[i])
    end
  end
  if S.last_panel and not panel_alive(S.last_panel) then
    S.last_panel = nil
  end
  -- Mirror the S.last_panel staleness check above: a destroyed panel must not
  -- be able to resurrect via a stale <C-c> target.
  if S.last_focused_panel and not panel_alive(S.last_focused_panel) then
    S.last_focused_panel = nil
  end
  -- Same mirror for the sidebar's primary conversation.
  if S.primary_panel and not panel_alive(S.primary_panel) then
    S.primary_panel = nil
  end
end

local function panel_for_buf(buf)
  for _, p in ipairs(panels) do
    if p.conv_buf == buf or p.prompt_buf == buf then
      return p
    end
  end
  return nil
end

-- Global (not per-panel) half of the <C-c> focus tracking: entering any NORMAL buffer
-- (buftype "") that isn't a panel's own buffer means the user has genuinely moved away
-- from yana, so <C-c> should stop claiming them. Deliberately does NOT fire for
-- transient/plugin buffers (buftype ~= "" — e.g. a noice message window, popups,
-- quickfix): those must neither grant nor revoke panel focus, which is the whole point
-- of tracking focus instead of sampling the current buffer at keypress time.
--
-- WinEnter-only would miss that swap entirely and leave a stale panel focus pointed at
-- a window the user has since filled with an unrelated file. buftype is re-checked on
-- the buffer actually entered either way, so a transient buffer still never triggers
-- this.
--
-- buftype "terminal" is included alongside "" ("normal" file buffers): a :terminal
-- buffer is somewhere the user has genuinely moved to (unlike a transient popup), and
-- it owns its own <C-c> — see install_stop_on_key below.
vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  group = vim.api.nvim_create_augroup("YanaFocusTrack", { clear = true }),
  callback = function(ev)
    log.guard("yana.ui YanaFocusTrack", function()
      local bt = vim.bo[ev.buf].buftype
      if (bt == "" or bt == "terminal") and not panel_for_buf(ev.buf) then
        S.last_focused_panel = nil
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
  if S.last_panel then
    return S.last_panel
  end
  if S.primary_panel and panel_alive(S.primary_panel) then
    return S.primary_panel
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

-- Render primitives (set_lines/append/streaming/error/greeting), split into
-- yana.ui_render: closes over buf_valid/win_valid/ui_ns via deps, everything
-- else it needs it requires directly. Instantiated here, early, because
-- `append`/`set_lines` are the highest fan-in helpers in the file -- every
-- later local in this file that needs them gets a plain function reference.
local ui_render_factory = require("yana.ui_render")
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

-- A chat's mode is fixed at its first turn and cannot be changed afterwards.
--
-- This is not a policy choice, it is a workaround for cursor-agent. Mode is a
-- per-message field upstream (`agent.v1.AgentMode`), and an explicit `--mode` always
-- wins -- but OMITTING it inherits the previous message's mode rather than defaulting
-- to agent. The CLI only accepts `--mode plan|ask`; there is no `--mode agent` to emit
-- (verified: `--mode agent` is a hard CLI error, and `--force` is an approval policy,
-- not a mode).
--
-- Locking the mode per chat makes that unreachable: an ask chat stays ask, an agent
-- chat never inherits ask. To change mode, start a new chat (which starts a new
-- upstream session, and a fresh session's mode chain starts clean). Lock once an
-- upstream session identity exists (init received or restored on resume).
local update_winbar
local ui_modes_factory = require("yana.ui_modes")
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
-- Still required directly here: used outside the mode-lock cluster (event/
-- submit code not yet split) at several other call sites in this file.
local renewal = require("yana.renewal")

----------------------------------------------------------------------
-- turn liveness: elapsed, last event, stall notice
----------------------------------------------------------------------
--
-- A spinner says "something is happening". The vendor does not forward a subagent's
-- output into the parent stream-json, so from the panel's side "working" and "hung"
-- were the same picture, and nothing on screen named an action the operator could take.
--
-- What this adds is the smallest honest report: how long the turn has run,
-- how long since the last event the agent produced, a short label for that
-- event, and -- once the silence passes a fixed threshold -- the word
-- `stalled` next to the command that ends it.
--
-- WHAT IT DELIBERATELY DOES NOT DO: kill anything. A live process is not a
-- dead one because its output paused; a nested task can legitimately run for
-- minutes without the parent stream saying a word. Automatic classification
-- of a turn as dead has exactly one owner, the claims-concurrency rules, and
-- it requires the process set to be EMPTY, never a statistic about quietness.
-- This surface reports; :YanaStop acts.
--
-- The cadence is free: the spinner timer already ticks every 100 ms for the
-- whole life of a turn and already calls update_winbar. Silence does not
-- block the loop, so the elapsed and quiet-for counters keep moving exactly
-- when they matter.

-- PRODUCT POLICY, NOT AN OPERATOR OPTION (project ruling: constants are policy). 90 s
-- is about four times the widest gap that turn ever produced -- wide enough that an
-- ordinary turn never accuses itself, narrow enough that an operator is not left
-- guessing for minutes.

local ui_liveness_factory = require("yana.ui_liveness")
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


-- Winbar / chip rendering -- split into yana.ui_winbar (see that file for
-- the fit/drop-order rationale). `single_file_banner` stays a forward
-- reference HERE in the parent (assigned later by the review cluster), so
-- ui_winbar is handed a closure over this local rather than a value
-- snapshot -- otherwise the winbar would freeze on whatever
-- single_file_banner was (nil) at instantiation time.
local single_file_banner
local ui_winbar = ui_winbar_factory.new({
  panels = panels,
  panel_index = panel_index,
  win_valid = win_valid,
  liveness_text = liveness_text,
  reconcile_pending = reconcile_pending,
  single_file_banner = function(p)
    return single_file_banner(p)
  end,
})
update_winbar = ui_winbar.update_winbar
local winbar_text = ui_winbar.winbar_text
local prompt_winbar_text = ui_winbar.prompt_winbar_text
local fit_winbar = ui_winbar.fit_winbar
local mode_chip = ui_winbar.mode_chip
local model_chip = ui_winbar.model_chip
local trunc_display = ui_winbar.trunc_display

-- Instantiated here, early, so every later cluster (the not-yet-split event/turn state
-- machine, the small command utilities) keeps reading these as plain in-scope locals --
-- the same "facade instantiated before every later cluster" placement ui_render uses.
local ui_claims_factory = require("yana.ui_claims")
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

local ui_review_factory = require("yana.ui_review")
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

local ui_changes_factory = require("yana.ui_changes")
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

-- render_user, backend_label, start_assistant_block, render_stream, append_stream,
-- commit_stream, tool_activity, render_tool_note: moved to yana.ui_render (facade
-- locals above).
S.render_note = function(p, text)
  append(p, { "  " .. notify.flatten(text), "" }, "note")
end

single_file_banner = function(p)
  local sfm = p and p.shadow_turn and p.shadow_turn.single_file
  if not sfm then
    return nil
  end
  local name = vim.fn.fnamemodify(sfm.real_path or sfm.copy_path or "file", ":t")
  -- The old ALL-CAPS "EDITS" carried real information (the restriction is on WRITES,
  -- not reads), so that emphasis moves to a dedicated highlight
  -- (YanaSingleFileBannerEmphasis, config.lua) on just that word, instead of living in
  -- the letters.
  return "%#YanaSingleFileBanner# Single-file mode · agent %#YanaSingleFileBannerEmphasis#edits%#YanaSingleFileBanner# only "
    .. name
    .. " · multi-file/create/delete refused · :Yana --workspace DIR to widen %*"
end

-- `extra` is optional and additive; every existing call site (msg only) still renders
-- exactly as before. UTF-8-safe prefix of at most max_bytes bytes: never returns a
-- slice that ends mid multibyte sequence (a lone leading byte with its continuation
-- bytes cut off), which would leave message an invalid UTF-8 string for the JSON
-- encoder below. utf8_safe_truncate, render_error: moved to yana.ui_render (facade
-- locals above); the M._test seam below now resolves against the facade local.

-- Pure-function boundary probe for the headless row (no panel needed).
M._test = M._test or {}
M._test.utf8_safe_truncate = utf8_safe_truncate

----------------------------------------------------------------------
-- event handling / refusal recording / turn completion (yana.ui_events,
-- yana.ui_turn_shadow, yana.ui_turn_end): together these are cluster 6, the event/turn
-- state machine -- split into three files because the combined span (turn_evidence_dir
-- through the F.on_exit_confirmed assignment) is ~1330 lines. `shadow_turn_gen` is
-- exposed on the shared state table S (assigned right after ui_events is instantiated,
-- below) because BOTH ui_turn_shadow and ui_turn_end call it -- the same mechanism
----------------------------------------------------------------------
local ui_events_factory = require("yana.ui_events")
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
local apply_single_file_filter = ui_events.apply_single_file_filter
local write_through_ignored = ui_events.write_through_ignored
local record_artifact_refusals = ui_events.record_artifact_refusals
local record_confinement_refusals = ui_events.record_confinement_refusals

local ui_turn_shadow_factory = require("yana.ui_turn_shadow")
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
  apply_single_file_filter = apply_single_file_filter,
  write_through_ignored = write_through_ignored,
  record_artifact_refusals = record_artifact_refusals,
  record_control_plane_refusals = record_control_plane_refusals,
})

local ui_turn_end_factory = require("yana.ui_turn_end")
local ui_turn_end = ui_turn_end_factory.new({
  state = S,
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
  panel_open_in = panel_open_in,
  stop_spinner = stop_spinner,
  buf_valid = buf_valid,
  M = M,
})
local last_stderr_line = ui_turn_end.last_stderr_line
local on_done = ui_turn_end.on_done
local on_exit_confirmed = ui_turn_end.on_exit_confirmed
local set_model_actual = ui_turn_end.set_model_actual

-- Late-bound registry entries for the turn/event state machine above:
-- yana.ui_submit's submit_panel (agent.run callbacks) and yana.ui_queue's
-- steer (via S.submit_panel) call these through F rather than closing over
-- them directly, so this cluster's own extraction order never matters.
F.on_event = on_event
F.set_model_actual = set_model_actual
F.on_done = on_done
F.on_exit_confirmed = on_exit_confirmed
----------------------------------------------------------------------
-- submit / queue
----------------------------------------------------------------------

-- submit_panel, M.submit, M.resend: yana.ui_submit. cancel_inflight,
-- M.stop, M.steer, M.pick_queue: yana.ui_queue (the combined cluster was
-- ~830 lines, over the 700-line ceiling on its own; see each module's
-- header for the cross-file S.submit_panel/S.cancel_inflight wiring).
local ui_submit_factory = require("yana.ui_submit")
local ui_submit_deps = {
  state = S,
  fn = F,
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
S.submit_panel = ui_submit.submit_panel
M.submit = ui_submit.submit
M.resend = ui_submit.resend

local ui_queue_factory = require("yana.ui_queue")
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
M.stop = ui_queue.stop
M.steer = ui_queue.steer
M.pick_queue = ui_queue.pick_queue

-- Read-only accessor for the panel <C-c> currently targets (nil if the user
-- last focused something outside yana). Exposed so tests/fixtures can
-- assert on tracked focus without reaching into module-local state.
-- Read-only accessor + paste/stop-key: yana.ui_input (facade before ui_panel).
M._stop_key_probe = { seen = 0, mode = nil, had_panel = nil, had_job = nil, scheduled = false, error = nil }
local ui_input_factory = require("yana.ui_input")
local ui_input = ui_input_factory.new({
  state = S,
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


-- mode / chat management: M.toggle_mode, M.set_mode, M.panel_write_capable,
-- M.ensure_agent_mode moved to yana.ui_modes (facade instantiated above,
-- near the rest of this cluster).
M.toggle_mode = ui_modes.toggle_mode
M.set_mode = ui_modes.set_mode
M.panel_write_capable = ui_modes.panel_write_capable
M.ensure_agent_mode = ui_modes.ensure_agent_mode

-- LAYER 1 (backend/vendor) and LAYER 2 (model) pickers -- split into
-- yana.ui_pickers (see that file for the layer-1/layer-2 rationale). This
-- wires the module's parent-local upvalues via `deps` and re-exports the
-- three commands under their original M.* names so no call site changes.
local ui_pickers = ui_pickers_factory.new({
  panels = panels,
  current_panel = current_panel,
  update_winbar = update_winbar,
})
M.pick_model = ui_pickers.pick_model
M.pick_backend = ui_pickers.pick_backend
M.pick_vendor_then_model = ui_pickers.pick_vendor_then_model


-- Panel greeting hook: moved to yana.ui_render (facade below).
M.render_greeting = ui_render.render_greeting

----------------------------------------------------------------------
-- window construction / panel lifecycle (yana.ui_panel): compute_width through M.toggle
-- -- cluster 8. The panel bookkeeping block itself
-- (buf_valid/win_valid/panel_open/current_panel/panel_index/panel_for_buf/
-- prune_panels/destroy_panel/new_panel_state, all above this point) stays here: every
-- other already-split module already depends on those as plain values, so moving them
-- now would mean re-wiring every sibling's deps table for no correctness gain. `deps.M
----------------------------------------------------------------------
local ui_panel_factory = require("yana.ui_panel")
local ui_panel = ui_panel_factory.new({
  state = S,
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
-- WINDOW OWNERSHIP, as a fact and not an inference. `panels` is a private
-- local, so until now the only way to ask "which panel owns this window" from
-- outside was to compare geometry -- equal column, equal width -- and that
-- inference is exactly the defect that let one panel's review resize and
-- destroy a sibling panel's panes. This is the named answer: one entry per
-- conversation visible in `tab`, in panel creation order, with the window ids
-- that panel and no other owns.
--
--   for _, v in ipairs(require("yana.ui").panel_views()) do
--     print(v.index, v.conv, v.prompt)
--   end
--
-- Read-only: the returned tables are fresh copies, so mutating them changes
-- nothing. `prompt` is nil for every panel but the one holding the column's
-- single prompt slot.
function M.panel_views(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local views = require("yana.ui_panel_views")
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
-- Small panel/claim command utilities (yana.ui_commands): new_chat, diary/
-- turn-key debug dumps, claim status/release, ask/inline_edit, refusal
-- listings -- cluster 10. `deps.M = M` lets it call other clusters' M.*
-- commands (open, panel_write_capable, set_mode, render_greeting)
-- regardless of extraction order -- see that module's own header.
local ui_commands_factory = require("yana.ui_commands")
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


-- Live-daemon session attachment moved to yana.ui_sessions.
local ui_sessions_factory = require("yana.ui_sessions")
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
    return require("yana.yanad_recover").recover(row.session_id, {
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
M._test.force_turn_edits = nil -- row85 mutation: number overrides turn_edits witness
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
-- Exported so a row can prove the REFUSALS fire, not merely that a switch succeeds: a
-- precondition that never blocks is the same defect as a check that never fails.
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
-- Liveness seams. The threshold stays product policy -- there is no operator
-- option for it -- but a row cannot sit through 90 real seconds of silence, so
-- the one number is movable from here and from nowhere else. `liveness`
-- exposes the per-turn state (open nested tasks by call_id, counts, the last
-- described event) so a row can assert the PAIRING rather than only the text
-- that pairing produces.
M._test.set_stall_threshold_ms = ui_liveness.set_stall_threshold_override
M._test.stall_threshold_ms = stall_threshold_ms
M._test.liveness = function(p)
  return p and liveness_for(p) or nil
end

return M
