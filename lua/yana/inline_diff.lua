-- yana: in-buffer per-hunk diff review (Avante replace_in_file parity).
-- Restores the pre-edit snapshot on disk, previews agent edits as extmarked hunks,
-- and writes the resolved buffer only after the user accepts.
local diff = require("yana.diff")
local config = require("yana.config")
local control_plane = require("yana.safety.control_plane")
local log = require("yana.log")
local ledger = require("yana.ledger")
local render_check = require("yana.render_check")
local review_model = require("yana.review_model")
local review_observer_factory = require("yana.review_observer")
local review_paint_factory = require("yana.review_paint")
local review_buffer_factory = require("yana.review_buffer")
local review_watch_factory = require("yana.review_watch")
local review_lifecycle_factory = require("yana.review_lifecycle")
local review_api_factory = require("yana.review_api")
local review_abort_factory = require("yana.review_abort")
local review_geometry_factory = require("yana.review_geometry")
local review_open_factory = require("yana.review_open")
local review_open_watchers_factory = require("yana.review_open_watchers")
local review_open_actions_factory = require("yana.review_open_actions")
local review_open_display_factory = require("yana.review_open_display")
local review_open_hints_factory = require("yana.review_open_hints")
local review_queue_factory = require("yana.review_queue")
local review_navigate_factory = require("yana.review_navigate")
local review_ownership_factory = require("yana.review_ownership")
local review_marks_factory = require("yana.review_marks")
local review_turn_factory = require("yana.review_turn")
local review_context_factory = require("yana.review_context")
local review_finalize_factory = require("yana.review_finalize")
local notify = require("yana.notify")
local notify_one_line = notify.one_line

local M = {}
M._review_decisions_factory = require("yana.review_decisions")
M._review_undo_factory = require("yana.review_undo")
M._review_bulk_factory = require("yana.review_bulk")

local NS = vim.api.nvim_create_namespace("YanaInlineDiff")
local HINT_NS = vim.api.nvim_create_namespace("YanaInlineHint")
-- N8-A: the PAINT span and the POSITION AUTHORITY are two different questions
-- and one extmark cannot answer both.
--
-- Paint wants an EXCLUSIVE end at (last_new_row + 1, col 0), because that is the only
-- encoding that colours the hunk's last new row even when that row is empty (the N8
-- fix). That is silent edit loss, and it happens at EOF too.
--
-- So the authority is its own extmark, in its own namespace, carrying the
-- PRE-N8 geometry: end at (last_new_row, col 0), right_gravity = false,
-- end_right_gravity = true. That end position is strictly BEFORE the row after
-- the hunk, so a boundary insert cannot move it, while an insert or delete
-- INSIDE the hunk still shifts/shrinks it exactly as before. It carries no
-- hl_group, no virt_lines and no priority: it decorates nothing.
--
-- A separate namespace, not a bare unhighlighted mark in NS, because NS is the
-- namespace render_check sweeps for `leaked_decoration` and that the N8 gate
-- counts marks in. An authority mark there would be a leak to one and an extra
-- hunk mark to the other. Everything that clears NS clears AUTH_NS beside it.
local AUTH_NS = vim.api.nvim_create_namespace("YanaInlineDiffAuthority")
-- A THIRD namespace, and it exists because highlight_blocks clears the other two. This
-- namespace is never cleared by a repaint: one mark per DECIDED hunk, spanning the
-- range that hunk occupied at the moment it was decided, deleted when the decision is
-- taken back or when the review closes. It paints nothing.
local ANCHOR_NS = vim.api.nvim_create_namespace("YanaInlineDiffDecisionAnchor")
local INCOMING_PRIO = (vim.hl or vim.highlight).priorities.user

local function park_decision_anchor(bufnr, start_line, end_line)
  if not (start_line and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local last = vim.api.nvim_buf_line_count(bufnr) - 1
  local srow = math.min(math.max(start_line - 1, 0), math.max(last, 0))
  local erow = math.min(math.max((end_line or start_line) - 1, srow), math.max(last, 0))
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ANCHOR_NS, srow, 0, {
    end_row = erow,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = true,
  })
  return ok and id or nil
end

local review_context = review_context_factory.new({ facade = M, diff = diff, config = config, log = log })
local MAX_RENDER_WARNS = review_context.max_render_warns
local pools = review_context.pools
local pool_for = review_context.pool_for
local pool_for_state = review_context.pool_for_state
local state_for_rel = review_context.state_for_rel
local owners_match = review_context.owners_match

-- Walk plumbing published as PRODUCT facade fields, next to
-- `M._park_and_open_state`/`M._ordered_target_for_state` (review_navigate.lua) which
-- the same cross-file `u` walk already uses.
M._pool_for = pool_for
M._state_for_rel = state_for_rel
local queue_item_owner = review_context.queue_item_owner
local freeze_review_owner = review_context.freeze_review_owner
local find_active_for_change = review_context.find_active_for_change
local stamp_review_workspace = review_context.stamp_review_workspace
local PALETTE = review_context.palette
local EXT_HL = review_context.ext_hl
local FAULT = review_context.fault
local apply_palette_highlights = review_context.apply_palette_highlights
local wins_for_buf = review_context.wins_for_buf
local apply_review_winhl = review_context.apply_review_winhl
local ensure_review_render_chrome = review_context.ensure_review_render_chrome
local restore_review_winhl = review_context.restore_review_winhl

local late = {}
local live_block_range
local review_geometry = review_geometry_factory.new({
  facade = M,
  diff = diff,
  review_buffer_factory = review_buffer_factory,
  ns = NS,
  notify_one_line = notify_one_line,
  log = log,
  fn = late,
})
local split_lines = review_geometry.split_lines
local buffer_lines = review_geometry.buffer_lines
local win_for_buf = review_geometry.win_for_buf
local focus_buf = review_geometry.focus_buf
local fingerprint = review_geometry.fingerprint
local base_fingerprint = review_geometry.base_fingerprint
local stale_refusal = review_geometry.stale_refusal
local attribute_drift = review_geometry.attribute_drift
local break_undo_block = review_geometry.break_undo_block
local buf_undo_seq = review_geometry.buf_undo_seq
local replace_line_span = review_geometry.replace_line_span
local lines_after_pending_withheld = review_geometry.lines_after_pending_withheld
local lines_after_sealed_accepts = review_geometry.lines_after_sealed_accepts
local review_buffer = review_geometry.review_buffer
local open_review_buffer = review_geometry.open_review_buffer
local current_block = review_geometry.current_block
local nav_start_line = review_geometry.nav_start_line
local nearest_block = review_geometry.nearest_block
local land_on = review_geometry.land_on
local insert_new_lines = review_geometry.insert_new_lines
local review_ownership = review_ownership_factory.new({
  diff = diff,
  buffer_lines = buffer_lines,
  base_fingerprint = base_fingerprint,
})
local reject_restoration = review_ownership.reject_restoration
local resolve_disk_unchanged = review_ownership.resolve_disk_unchanged
local staged_snapshot_unchanged = review_ownership.staged_snapshot_unchanged
local apply_review_blocks_to_reloaded_disk = review_ownership.apply_review_blocks_to_reloaded_disk
local absorb_review_blocks_over_drift = review_ownership.absorb_review_blocks_over_drift
local review_marks = review_marks_factory.new({
  facade = M,
  diff = diff,
  ns = NS,
  authority_ns = AUTH_NS,
  late = late,
  reject_restoration = reject_restoration,
})
live_block_range = review_marks.live_block_range
-- The sidebar button strip must use the same live authority decoder as the
-- keyboard decision and navigation paths.
M.live_block_range = live_block_range
local lines_equal = review_marks.lines_equal
local review_paint_deps = {
  ns = NS,
  authority_ns = AUTH_NS,
  ext_hl = EXT_HL,
  incoming_priority = INCOMING_PRIO,
  fault = FAULT,
  live_block_range = live_block_range,
  notify_one_line = notify_one_line,
}
local review_paint = review_paint_factory.new(review_paint_deps)
local render = review_paint.render

----------------------------------------------------------------------
-- rung-1 invariant capture (logging only — never changes control flow)
----------------------------------------------------------------------

local model_target = review_model.model_target
local payload_model = review_model.payload_model
local recomposed_model = review_model.recomposed_model
local stamp_model_index = review_model.stamp_model_index

local review_observer = review_observer_factory.new({
  ns = NS,
  hint_ns = HINT_NS,
  ext_hl = EXT_HL,
  palette = PALETTE,
  max_render_warns = MAX_RENDER_WARNS,
  buf_undo_seq = buf_undo_seq,
  ensure_review_render_chrome = ensure_review_render_chrome,
  render = render,
  fault = FAULT,
})
local change_ledger = review_observer.change_ledger
local render_invariant = review_observer.render_invariant
local record_decision = review_observer.record_decision
local render_blocks = review_observer.render_blocks

-- Panels register here to be told when review state changed — opened, aborted,
-- refused, resolved, queue advanced. Without this the panel can only repaint at
-- the edges it happens to drive itself, so a change that was "queued" when its
-- block was written still SAYS queued for the whole time its review is open
-- (and a review aborted after the claim was stamped still says "open"). Fired
-- AFTER `active` is updated, so an observer always reads settled state.
local observers = {}

--- THE PARTS OF A REVIEW'S OPTS THAT OUTLIVE THE REVIEW.
---
--- A review can be reopened long after the session that first opened it is
--- gone: the cross-file retrace (`timeline/retrace.lua`) does exactly that on
--- every `u`/`<C-r>` press. The reopener cannot rebuild the caller's opts --
--- `on_shadow_accept` in particular MUST be replaced, because the write has to
--- route through the reopener's own journaled applier -- so it copies the
--- fields that belong to the OWNER rather than to the session.
---
--- ONE list, here, because there were two (`M.open`'s `_last_review_opts` stamp and
--- `retrace_review_opts`'s carry) and they drifted: both named `on_close`,
--- `review_tabs_state_path`, `review_owner`, `review_turn` and neither named the four
--- DECISION callbacks. Adding a field in one place and not the other is how that comes
--- back, so there is one place.
---
--- What is deliberately NOT here: `on_shadow_accept`, `on_shadow_revert`,
--- `on_shadow_restore_staged` and `shadow_apply`. Those describe HOW bytes
--- reach the real tree, which is the reopener's business and not the original
--- session's.
local review_queue = review_queue_factory.new({
  M = M,
  observers = observers,
  pools = pools,
  pool_for = pool_for,
  pool_for_state = pool_for_state,
  diff = diff,
  focus_buf = focus_buf,
  notify = notify,
  notify_one_line = notify_one_line,
  log = log,
  ledger = ledger,
  change_ledger = change_ledger,
  find_active_for_change = find_active_for_change,
  owners_match = owners_match,
  queue_item_owner = queue_item_owner,
  freeze_review_owner = freeze_review_owner,
  stamp_review_workspace = stamp_review_workspace,
  FAULT = FAULT,
})
local announce_state = review_queue.announce_state
local open_or_abandon = review_queue.open_or_abandon
local process_next_for = review_queue.process_next_for
local process_next = review_queue.process_next
local schedule_queue_advance = review_queue.schedule_queue_advance
local block_signature = review_queue.block_signature
local parked_pending_blocks = review_queue.parked_pending_blocks
local count_live_pending_blocks = review_queue.count_live_pending_blocks
local count_total_hunks_for_change = review_queue.count_total_hunks_for_change
local undecided_hunks_for_change = review_queue.undecided_hunks_for_change
local pending_hunk_count_for = review_queue.pending_hunk_count_for
local remember_batch_item = review_queue.remember_batch_item
local queue_remove_change = review_queue.queue_remove_change
local queue_insert_original = review_queue.queue_insert_original
local review_tabs = review_queue.review_tabs
local review_navigate = review_navigate_factory.new({
  facade = M,
  pools = pools,
  pool_for = pool_for,
  freeze_review_owner = freeze_review_owner,
  focus_buf = focus_buf,
  current_block = current_block,
  nearest_block = nearest_block,
  land_on = land_on,
  block_signature = block_signature,
  parked_pending_blocks = parked_pending_blocks,
  pending_hunk_count_for = pending_hunk_count_for,
  remember_batch_item = remember_batch_item,
  queue_remove_change = queue_remove_change,
  queue_insert_original = queue_insert_original,
  announce_state = announce_state,
  notify_one_line = notify_one_line,
  notify = notify,
  log = log,
  break_undo_block = break_undo_block,
  record_decision = record_decision,
  open_or_abandon = open_or_abandon,
  diff = diff,
})
local park_and_open_state = review_navigate.park_and_open_state

-- Owner callbacks belong to the panel, not to this engine, and the engine's own
-- teardown must not depend on them succeeding. That is the "days later I can't save /
-- reviews stop opening" shape.
local review_turn = review_turn_factory.new({
  facade = M,
  pool_for = pool_for,
  queue_remove_change = queue_remove_change,
  queue_insert_original = queue_insert_original,
  freeze_review_owner = freeze_review_owner,
  diff = diff,
  base_fingerprint = base_fingerprint,
  break_undo_block = break_undo_block,
  buffer_lines = buffer_lines,
  notify = notify,
  notify_one_line = notify_one_line,
  log = log,
  announce_state = announce_state,
  land_on = land_on,
  park_and_open_state = park_and_open_state,
  model_target = model_target,
  stamp_model_index = stamp_model_index,
  change_ledger = change_ledger,
  ledger = ledger,
  attribute_drift = attribute_drift,
  schedule_queue_advance = schedule_queue_advance,
})
local notify_owner = review_turn.notify_owner
local compound_mode_text = review_turn.compound_mode_text
local review_action_allowed = review_turn.review_action_allowed
local review_lifecycle = review_lifecycle_factory.new({
  facade = M,
  change_ledger = change_ledger,
  ledger = ledger,
  staged_snapshot_unchanged = staged_snapshot_unchanged,
  review_action_allowed = review_action_allowed,
  diff = diff,
  notify_owner = notify_owner,
  buf_undo_seq = buf_undo_seq,
  break_undo_block = break_undo_block,
  live_block_range = live_block_range,
  reject_restoration = reject_restoration,
  park_decision_anchor = park_decision_anchor,
  record_decision = record_decision,
  notify_one_line = notify_one_line,
  pool_for_state = pool_for_state,
  announce_state = announce_state,
  schedule_queue_advance = schedule_queue_advance,
  restore_review_winhl = restore_review_winhl,
  ns = NS,
  authority_ns = AUTH_NS,
  anchor_ns = ANCHOR_NS,
  hint_ns = HINT_NS,
})
local finish_session = review_lifecycle.finish_session
local review_watch = review_watch_factory.new({
  live_block_range = live_block_range,
  lines_equal = lines_equal,
  authority_ns = AUTH_NS,
  recompute_modified = M._recompute_modified,
  buf_undo_seq = buf_undo_seq,
  build_diff_blocks = M.build_diff_blocks,
})
local attach_buffer_watch = review_watch.attach

local review_finalize = review_finalize_factory.new({
  facade = M,
  pool_for_state = pool_for_state,
  finish_session = finish_session,
  log = log,
})
local binary_reason = review_finalize.binary_reason

-- `M._ledger_rebuild` is hung on this facade by `review_finalize.new` just above,
-- beside the other lifecycle helpers it belongs with.

local review_history_module = require("yana.review_history")
local review_history = review_history_module.new({
  facade = M,
  rerender = function(state) M.rerender(state) end,
  announce_state = announce_state,
  block_signature = block_signature,
  finish_session = finish_session,
  freeze_review_owner = freeze_review_owner,
  notify_one_line = notify_one_line,
  owners_match = owners_match,
  pool_for = pool_for,
  process_next_for = process_next_for,
  record_decision = record_decision,
  remember_batch_item = remember_batch_item,
})

M._rewind_suppress = review_history.suppress
M._rewind_hold = review_history.hold
M._rewind_hold_current = review_history.hold_current
M._rewind_own_transaction = review_history.own_transaction
M._rewind_forget_path = review_history.forget_path
M._rewind_forget_owner = review_history.forget_owner
review_queue.set_rewind_schedule(review_history.schedule)

M.open = review_open_factory.new({
  M = M,
  diff = diff,
  config = config,
  control_plane = control_plane,
  log = log,
  ledger = ledger,
  NS = NS,
  HINT_NS = HINT_NS,
  AUTH_NS = AUTH_NS,
  ANCHOR_NS = ANCHOR_NS,
  notify = notify,
  notify_one_line = notify_one_line,
  EXT_HL = EXT_HL,
  FAULT = FAULT,
  split_lines = split_lines,
  buffer_lines = buffer_lines,
  wins_for_buf = wins_for_buf,
  focus_buf = focus_buf,
  fingerprint = fingerprint,
  base_fingerprint = base_fingerprint,
  attribute_drift = attribute_drift,
  break_undo_block = break_undo_block,
  buf_undo_seq = buf_undo_seq,
  open_review_buffer = open_review_buffer,
  current_block = current_block,
  nav_start_line = nav_start_line,
  nearest_block = nearest_block,
  land_on = land_on,
  insert_new_lines = insert_new_lines,
  lines_equal = lines_equal,
  live_block_range = live_block_range,
  model_target = model_target,
  payload_model = payload_model,
  recomposed_model = recomposed_model,
  stamp_model_index = stamp_model_index,
  change_ledger = change_ledger,
  render_invariant = render_invariant,
  record_decision = record_decision,
  render_blocks = render_blocks,
  process_next_for = process_next_for,
  finish_session = finish_session,
  attach_buffer_watch = attach_buffer_watch,
  park_decision_anchor = park_decision_anchor,
  stamp_review_workspace = stamp_review_workspace,
  pool_for = pool_for,
  pool_for_state = pool_for_state,
  apply_review_winhl = apply_review_winhl,
  reject_restoration = reject_restoration,
  staged_snapshot_unchanged = staged_snapshot_unchanged,
  apply_review_blocks_to_reloaded_disk = apply_review_blocks_to_reloaded_disk,
  absorb_review_blocks_over_drift = absorb_review_blocks_over_drift,
  announce_state = announce_state,
  process_next = process_next,
  schedule_queue_advance = schedule_queue_advance,
  notify_owner = notify_owner,
  compound_mode_text = compound_mode_text,
  review_action_allowed = review_action_allowed,
  binary_reason = binary_reason,
  -- The pool queue's own primitives, for the `cA`-undo requeue in
  -- review_undo.lua (reached through review_open_actions' deps chain).
  queue_insert_original = queue_insert_original,
  queue_remove_change = queue_remove_change,
  review_open_watchers_factory = review_open_watchers_factory,
  review_open_actions_factory = review_open_actions_factory,
  review_open_display_factory = review_open_display_factory,
  review_open_hints_factory = review_open_hints_factory,
})

-- Queues change for review in opts' pool, opening it if none is active.
review_api_factory.new({
  facade = M,
  pool_for = pool_for,
  process_next = process_next,
  stamp_review_workspace = stamp_review_workspace,
  freeze_review_owner = freeze_review_owner,
  remember_batch_item = remember_batch_item,
  process_next_for = process_next_for,
  owners_match = owners_match,
  queue_item_owner = queue_item_owner,
  review_tabs = review_tabs,
  announce_state = announce_state,
  pools = pools,
  open_or_abandon = open_or_abandon,
  notify = notify,
  find_active_for_change = find_active_for_change,
  diff = diff,
  ns = NS,
  authority_ns = AUTH_NS,
  hint_ns = HINT_NS,
  finish_session = finish_session,
  land_on = land_on,
  focus_buf = focus_buf,
  apply_palette_highlights = apply_palette_highlights,
  apply_review_winhl = apply_review_winhl,
  render_invariant = render_invariant,
  render_check = render_check,
  ext_hl = EXT_HL,
  palette = PALETTE,
})
review_abort_factory.new({
  facade = M,
  diff = diff,
  ns = NS,
  authority_ns = AUTH_NS,
  anchor_ns = ANCHOR_NS,
  hint_ns = HINT_NS,
  queue_remove_change = queue_remove_change,
  notify_one_line = notify_one_line,
  change_ledger = change_ledger,
  ledger = ledger,
  finish_session = finish_session,
  pool_for = pool_for,
  review_tabs = review_tabs,
})
function M.process_next(opts)
  process_next_for(opts)
end

-- Counts batched paths in opts' pool, or across all pools.
function M.batched_count(opts)
  if opts then
    local n = 0
    for _ in pairs(pool_for(opts).batched) do
      n = n + 1
    end
    return n
  end
  local n = 0
  for _, st in pairs(pools) do
    for _ in pairs(st.batched) do
      n = n + 1
    end
  end
  return n
end

M._test = M._test or {}
M._test.fault = FAULT
M._test.pools = pools
M._test.pool_for = pool_for
M._test.state_for_rel = state_for_rel
M._test.discard_pool = M.discard_pool
M._test.discard_for_owner = M.discard_for_owner
M._test.process_next = M.process_next
M._test.owners_match = owners_match
M._test.prompt_close_owned_tabs = M.prompt_close_owned_tabs
M._test.close_owned_tabs = M.close_owned_tabs
M._test.review_tabs_state_path = M.review_tabs_state_path

return M
