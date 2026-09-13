-- Turn-wide undo, redo, action policy, and refusal bookkeeping.
local M = {}
local review_turn_reset_factory = require("yana.review_turn_reset")

function M.new(deps)
  local M = deps.facade
  local pool_for = deps.pool_for
  local queue_remove_change = deps.queue_remove_change
  local queue_insert_original = deps.queue_insert_original
  local freeze_review_owner = deps.freeze_review_owner
  local diff = deps.diff
  local break_undo_block = deps.break_undo_block
  local buffer_lines = deps.buffer_lines
  local notify = deps.notify
  local notify_one_line = deps.notify_one_line
  local log = deps.log
  local announce_state = deps.announce_state
  local land_on = deps.land_on
  local park_and_open_state = deps.park_and_open_state
  local model_target = deps.model_target
  local stamp_model_index = deps.stamp_model_index
  local change_ledger = deps.change_ledger
  local ledger = deps.ledger
  local attribute_drift = deps.attribute_drift
  local schedule_queue_advance = deps.schedule_queue_advance

local function notify_owner(cb, change, label)
  if not cb then
    return true
  end
  local ok, err = pcall(cb, change)
  if not ok then
    notify_one_line(
      "yana: " .. label .. " handler failed for `" .. (change.rel or change.path or "?")
        .. "`: " .. tostring(err) .. " (review state was still torn down cleanly)",
      vim.log.levels.ERROR
    )
    return false
  end
  return true
end

----------------------------------------------------------------------
--
-- `u` is unchanged: the last step, per hunk, in the file under the cursor.
-- `U` is the RESET, and there is no separate command for it: every file the
-- turn touched goes back to the state the operator was FIRST SHOWN, and the
-- cursor lands on the turn's first pending hunk.
--
-- The two hard cases are the ones the ruling names: (a) A file already settled and
-- CLOSED has no buffer to pop and no review to unwind. It is REOPENED -- put back in
-- the queue at its original position with its decision cleared -- so the operator gets
-- the review they were shown, not an empty one. (b) A file already ACCEPTED may already
-- be on disk.
--
-- Created/deleted members follow the same rule: `U` changes memory only.
----------------------------------------------------------------------

--- THIS turn, and only this turn. The pool's `order` is never cleared between turns --
--- it is the panel's whole review history for that workspace -- so a sweep over it
--- reaches changes the operator settled in EARLIER turns, whose bytes `U` has no
--- business putting back.
	local reset = review_turn_reset_factory.new(deps)
	local load_turn_start = reset.load_turn_start
	local undo_rest_of_turn = reset.undo_rest_of_turn
  local redo_staged_restores = reset.redo_staged_restores
  M.mark_turn_closed = reset.mark_turn_closed
  local turn_change_count = reset.turn_change_count
	M._load_turn_start = load_turn_start
	M._undo_rest_of_turn = undo_rest_of_turn
  M._redo_staged_restores = redo_staged_restores

local function mode_perm(mode)
  return mode and (mode % 4096) or nil
end

local function compound_mode_text(change)
  if not change or not change.base_mode or not change.after_mode then
    return nil
  end
  if mode_perm(change.base_mode) == mode_perm(change.after_mode) then
    return nil
  end
  return string.format("mode %o → %o", mode_perm(change.base_mode), mode_perm(change.after_mode))
end

--- Every durable accept waits for the turn's classified bundle to publish.
local function review_action_allowed(state, change)
  local pass = state.opts and state.opts.turn_pass
  if not pass then
    return true
  end
  local lifecycle = require("yana.turn_lifecycle")
  if not lifecycle.is_actionable(pass) then
    return false, "refused: the classified bundle for this turn has not published yet"
  end
  return lifecycle.action_allowed(pass, change and (change.rel or change.path))
end

--- THE REBUILD OWNER'S EXPLICIT ANCESTOR MAPPING. `Ledger:rebuild` re-derives
--- geometry and hands membership to the list it is given; it will not guess
--- which old hunk a new one continues, and it must not -- guessing by bytes is
--- what restored a recorded frame into a stranger. So the owner says it here,
--- because only this site knows both sides.
---
--- The case that matters is a SPLIT. `M.build_diff_blocks` re-derives the
--- MODEL's hunks, one per model index; this review may have carved one of them
--- into children on ownership runs (review_hunk_split.lua), and each child
--- recorded the parent it came from (`split_parent_model_index`, stamped in
--- hunk_ledger_lifecycle.lua's `Ledger:split`). Handing the whole model hunk
--- back would drop those children table-and-all: their verdicts, their row
--- anchors and their names all go, and every recorded undo frame that names one
--- resolves to nothing -- a keystroke-reachable undo that simply refuses. The
--- children ARE the current geometry of that model hunk, so they go back into
--- the rebuild as THEMSELVES, boundaries and identity intact, and the fresh
--- whole-hunk block for that index is dropped.
---
--- A model index with no surviving children rebuilds as it always did: the
--- fresh block carries the index, and `Ledger:rebuild` carries the name across
--- on that.
---
--- THE ORDINARY INDEXLESS CONTINUATION is the case that used to fall through.
--- `review_model.stamp_model_index` leaves `model_index = nil` on whole classes
--- of perfectly ordinary hunks -- a pure deletion, a block no payload run
--- starts at, a block spanning several runs, and every hunk of a
--- `model_unavailable` change -- so those hunks have no index to ride across.
--- Bytes used to carry them, badly; with that carrier gone they arrived fresh,
--- and the frames naming them stopped resolving
--- (`INDEXLESS_REBUILD old=lin-1 fresh=lin-2 inherited=false undo_ok=false`).
---
--- So this owner names them, and the name it uses is ORDINAL, not content: both
--- lists are in buffer order and both come out of the SAME derivation over the
--- same `change.before` and the same target, so the k-th indexless hunk on the
--- ledger is the k-th indexless block in the fresh geometry. That is a
--- structural fact about the pipeline; it never looks at a line.
---
--- AND WHEN THE ORDINALS DO NOT LINE UP IT REFUSES. Different counts mean the
--- derivation disagrees with the membership, and this site can no longer say
--- which old hunk each new one continues. Guessing is what put a rejected
--- verdict on a stranger; dropping the mapping silently is what left an undo
--- frame pointing at nothing. So it raises BEFORE `Ledger:rebuild` is called
--- and the old membership is still standing.
local function rebuild_geometry_with_genealogy(state, fresh)
  local ledger = state.hunk_ledger
  if not ledger then
    return fresh
  end
  local children_of = {}
  local indexless_members = {}
  for _, member in ipairs(ledger:members()) do
    local parent = member.split_parent_model_index
    if parent ~= nil then
      children_of[parent] = children_of[parent] or {}
      table.insert(children_of[parent], member)
    elseif member.model_index == nil then
      indexless_members[#indexless_members + 1] = member
    end
  end
  local blocks = fresh
  if next(children_of) ~= nil then
    blocks = {}
    for _, block in ipairs(fresh) do
      local kin = block.model_index ~= nil and children_of[block.model_index] or nil
      if kin then
        for _, child in ipairs(kin) do
          blocks[#blocks + 1] = child
        end
      else
        blocks[#blocks + 1] = block
      end
    end
  end
  if #indexless_members == 0 then
    return blocks
  end
  -- Only the genuinely NEW tables are candidates: a member handed back as
  -- itself (a split child) already is its own ancestor and must not be paired
  -- with somebody else's.
  local owned = {}
  for _, member in ipairs(ledger:members()) do
    owned[member] = true
  end
  local indexless_fresh = {}
  for _, block in ipairs(blocks) do
    if block.model_index == nil and not owned[block] then
      indexless_fresh[#indexless_fresh + 1] = block
    end
  end
  if #indexless_fresh ~= #indexless_members then
    error(string.format(
      "review_turn: cannot name the continuation of %d model-indexless hunk(s) in a rebuild that derived %d "
        .. "-- refusing rather than guessing or dropping their lineage",
      #indexless_members, #indexless_fresh), 2)
  end
  for i, block in ipairs(indexless_fresh) do
    block.rebuild_ancestor = indexless_members[i]
  end
  return blocks
end

--- Per-hunk accept marks its hunk decided before the shadow applier runs. When the
--- applier refuses (human drift, mode mismatch, …), `change.after` still holds the
--- agent proposal in the private layer — only this review's geometry went stale.
local function restore_agent_proposal_after_refusal(state)
  local change = state.change
  if not change then
    return
  end
  local target = model_target(change)
  local fresh = stamp_model_index(M.build_diff_blocks(change.before or "", target), state.model_hunks or {})
  M._ledger_rebuild(state, rebuild_geometry_with_genealogy(state, fresh), "applier_refusal")
  local bufnr = state.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return
  end
  -- This site asks for the ONE coalesced repaint instead of calling the painter itself.
  state.hunk_ledger:request_paint()
end

function M._record_shadow_accept_refusal(state, err)
  local change = state.change
  local turn_log = change_ledger(change, state.opts)
  change.review_error = tostring(err or "accept failed")
  local raw_detail = change.shadow_refusal
  ledger.record_decision(turn_log, {
    action = "review_refused",
    actor = "system",
    -- a claim conflict raised in this engine).
    reason = (type(raw_detail) == "table" and raw_detail.reason_code) or "shadow_accept_failed",
    detail = tostring(err),
    change_id = change.id,
    rel = change.rel or change.path,
  })
  local detail = change.shadow_refusal
  if type(detail) == "table" and type(detail.actual_fp) == "string" then
    local origin, drift_reason = attribute_drift(change, detail.reason or "stale_file", detail.actual_fp)
    detail = vim.tbl_extend("force", {}, detail)
    if origin then
      detail.origin = origin
    end
    if drift_reason then
      detail.reason = drift_reason
    end
  end
  ledger.attach_refusal(turn_log, detail)
  -- DURABLY, not only in the in-memory ledger (issue: a refusal's evidence lived only
  -- in the turn journal and the in-memory ledger; the operator reads the session log
  -- (yana.log), and evidence that never reaches it does not exist in practice). Gated
  -- by YANA_LIFECYCLE_LOG exactly like every other `review.decision` row, so a
  -- clean/quiet turn still writes nothing. Hashes only cross this boundary, already
  -- truncated to 16 hex characters by the diary (`diary.lua`'s stale-file record): no
  log.lifecycle_later("review.decision", {
    turn_id = change and (change.turn_id or change.turn_gen),
    generation = change and change.turn_gen,
    action = "review_refused",
    actor = "system",
    path = change.rel or change.path,
    change_id = change.id,
    -- Mutation seam (gate): `omit_session_log_reason_code` reproduces the
    -- pre-this-delta session log line, which never carried the diary's
    -- machine-readable slug at all (issue: "the session log line showed none
    -- of them").
    reason_code = (not M._test.fault.omit_session_log_reason_code)
      and (type(detail) == "table" and detail.reason_code or nil)
      or nil,
    reason = (type(detail) == "table" and detail.reason) or "shadow_accept_failed",
    expected_fp = type(detail) == "table" and detail.expected_fp or nil,
    actual_fp = type(detail) == "table" and detail.actual_fp or nil,
    expected_state = type(detail) == "table" and detail.expected_state or nil,
    found_state = type(detail) == "table" and detail.found_state or nil,
    base_hash_captured_ts = type(detail) == "table" and detail.base_hash_captured_ts or nil,
  })
  change.status = "pending"
  notify_one_line(
    "yana: shadow accept failed for " .. (change.rel or change.path) .. ": " .. tostring(err),
    vim.log.levels.ERROR
  )
  restore_agent_proposal_after_refusal(state)
  -- Every review state carries one (`review_open.lua`'s single `hunk_ledger.open`
  -- constructor), and the rebuild above installs a fresh one even when a bulk teardown
  -- had already cleared it (`_ledger_rebuild`'s A7 branch). A state arriving here
  -- without one is a hand-built caller, and it must say so rather than read a nil field
  -- and get `attempt to index a nil value` three frames away.
  if not state.hunk_ledger then
    error("review_turn: _record_shadow_accept_refusal needs a state with a hunk_ledger", 2)
  end
  if state.hunk_ledger:count() > 0 then
    announce_state()
    schedule_queue_advance(state)
    return true
  end
  return false
end

  -- The rebuild owner's mapping, on the facade beside `_ledger_rebuild`, so a
  -- gate can drive the REAL pairing instead of hand-building two ledgers -- the
  -- shortcut that let both halves of this defect hide behind a green row.
  M._rebuild_geometry_with_genealogy = rebuild_geometry_with_genealogy

  return {
    notify_owner = notify_owner,
    compound_mode_text = compound_mode_text,
    review_action_allowed = review_action_allowed,
  }
end

return M
