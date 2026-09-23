-- Inline review open coordinator.
--
-- The hunk list is born here and handed straight to the ledger: this file still
-- diffs and stamps, the ledger owns the result and every verdict on it. A
-- module-level local, not a `deps` entry, so it survives `setfenv(open, env)`
-- as a lexical upvalue rather than an env lookup.
local hunk_ledger = require("yana.hunk_ledger")

-- Hand-test tracing (tools/handtest). Inert unless YANA_HANDTEST_TRACE is set.
local function _ht_trace(msg)
  local p = os.getenv("YANA_HANDTEST_TRACE")
  if not p then return end
  local f = io.open(p, "a")
  if f then f:write(msg .. "\n"); f:close() end
end


local Factory = {}
local review_open_bind_factory = require("yana.review_open_bind")
local review_permissions = require("yana.review_permissions")


function Factory.new(deps)
  local env = setmetatable({}, {
    __index = function(_, key)
      local value = deps[key]
      if value ~= nil then
        return value
      end
      return _G[key]
    end,
  })
  local function child_deps(values)
    return setmetatable(values, { __index = deps })
  end

  local function open(change, opts)
  if not change or not change.path then
    -- Not one of the named refusal paths, but still a `return false` with a
    -- change object available (when change itself is non-nil): record it too
    -- so nothing downstream mistakes this for a healthy pending review.
    if change then
      change.review_error = "invalid change: missing path"
      log.buffer_event("review_staged", { change = change, outcome = "invalid_change",
        reason = "invalid change: missing path",
        engine = { not_reached = "the change carries no path, so no review was attempted" } })
    end
    -- A malformed payload must cost one change, not the session.
    announce_state()
    schedule_queue_advance(state)
    return false, "invalid change: missing path"
  end
  opts = opts or {}
  change._last_review_opts = M.carryable_review_opts(opts)

  local bin_class = binary_reason(change)
  if bin_class then
    if change.status ~= "pending" then
      announce_state()
      schedule_queue_advance({ opts = opts })
      log.buffer_event("review_staged", { change = change, outcome = "not_pending",
        reason = "change is no longer pending",
        engine = { not_reached = "the change left the pending state before review" } })
      return false, "change is no longer pending"
    end
    change.reason_class = bin_class
    local detail = (change.rel or change.path)
      .. ": "
      .. bin_class
      .. " — real file unchanged; proposal is not reviewable"
    change.review_error = detail
    ledger.record_decision(change_ledger(change, opts), {
      action = "review_refused",
      actor = "system",
      reason = bin_class,
      detail = detail,
      change_id = change.id,
      rel = change.rel or change.path,
    })
    change.status = "system_refused"
    notify_owner(opts.on_system_refused, change, "on_system_refused")
    if opts.on_close then
      vim.schedule(function()
        notify_owner(function()
          opts.on_close(nil, false)
        end, change, "on_close")
      end)
    end
    notify_one_line("yana: refused " .. detail, vim.log.levels.WARN)
    log.buffer_event("review_staged", { change = change, outcome = "system_refused", reason = detail,
      engine = { not_reached = "refused before review: " .. bin_class } })
    announce_state()
    schedule_queue_advance({ opts = opts })
    return false, detail
  end

  local bufnr, open_err, refusal = open_review_buffer(change, opts.preview)
  if not bufnr then
    -- A refusal is not a user decision, and the corpus showed the two being
    -- read as one. It is recorded as its own class, with the fingerprint pair
    -- that disagreed when the refusing site had both in hand — never the
    -- contents, per the module's redaction invariant.
    local L = change_ledger(change, opts)
    local actual_fp = refusal and refusal.actual_fp or nil
    -- The attribution the fingerprint pair was retained for: agent self-write,
    -- external save, or honestly unknown.
    local origin, reason = attribute_drift(change, (refusal and refusal.reason) or "other", actual_fp)
    ledger.record_decision(L, {
      action = "review_refused",
      actor = "system",
      reason = reason,
      origin = origin,
      detail = open_err,
      change_id = change.id,
      rel = change.rel or change.path,
      expected_fp = refusal and refusal.expected_fp or nil,
      actual_fp = actual_fp,
    })
    -- The "kept unreviewed, no pre-edit snapshot" branch is gone with E9. It
    -- existed because a missing `before` meant the agent's edit was already on
    -- disk with nothing to revert to; now a missing `before` is simply a
    -- create, reviewed against an empty base, and nothing is on disk to keep.
    --
    -- Retryable refusals stay pending. A dirty pre-existing buffer is
    -- different: Yana must preserve the operator's bytes and retire this
    -- proposal, because no review was attached that could ever be answered.
    if change.review_error == nil then
      change.review_error = open_err
    end
    if refusal and refusal.reason == "dirty_buffer" then
      local withdrew, withdraw_err = require("yana.turn.turn_bind").withdraw_unopened(
        diff.abs_path(change.path)
      )
      if withdrew then
        change.status = "system_refused"
        notify_owner(opts.on_system_refused, change, "on_system_refused")
        if opts.on_close then
          vim.schedule(function()
            notify_owner(function()
              opts.on_close(nil, false)
            end, change, "on_close")
          end)
        end
      else
        change.review_error = tostring(withdraw_err or open_err)
      end
    end
    -- BURST GUARD (DEFECT C): a refused target keeps getting retried -- `]x`/`[x` parks
    -- the current file and reopens the target on EVERY press, and a target whose
    -- refusal reason has not changed since the last attempt would otherwise re-announce
    -- the identical line every single press. Announce once per distinct reason; a later
    -- attempt that fails for a DIFFERENT reason (or succeeds, which clears this field
    -- below) is still reported.
    local open_err_text = tostring(open_err)
    local repeated_open_refusal = (change._open_refusal_announced == open_err_text)
    if not repeated_open_refusal then
      change._open_refusal_announced = open_err_text
      M._announce_open_failure(change, "could not open review buffer: " .. open_err_text, vim.log.levels.WARN)
    end
    if repeated_open_refusal and change.status == "pending" then
      -- Same refusal class, unchanged conditions: do not spin the queue.
      announce_state()
      return false, open_err
    end
    -- F13: M._requeue_change was tombstoned with W8 (review_queue.lua:451-454,
    -- ADJUDICATED 20/22/23) -- a file the Turn already saw stays a PARKED
    -- MEMBER, never requeued. Nothing replaces this call; the refusal path
    -- below (_announce_open_failure already fired above, announce_state,
    -- schedule_queue_advance) is what is left of it.
    -- A refused review must not strand every change still queued behind it.
    announce_state()
    schedule_queue_advance({ opts = opts or {} })
    return false, open_err
  end

  change.review_error = nil
  change._open_refusal_announced = nil

  -- An empty base is ZERO lines, but Vim cannot hold a zero-line buffer: the blank line
  -- it forces is not part of the base. For a modify the phantom trailing "" that
  -- split_lines produces sits on both sides and cancels, but for a create it would land
  -- inside the one hunk and add a blank line to the composed file. Drop it from the
  -- target here and drop the buffer's forced blank line after staging; match_eol
  -- restores the real final newline at accept.
  local review_before = change.review_before ~= nil and change.review_before or change.before
  if change._retrace_model == nil and type(review_before) == "string" and type(change.after) == "string" then
    change._retrace_model = { before = review_before, after = change.after }
  end
  local target = model_target(change)
  -- Model FIRST, blocks second, join last: the model must not be able to
  -- inherit anything from the block list.
  local model, model_source = payload_model(change, target)
  local parked = change._parked_review
  -- Fresh retrace geometry supersedes parked.blocks below, but T14's redo
  -- stack survives that rebuild and must be rebound to the fresh members.
  local parked_undone_decisions = parked and parked.undone_decisions
  local retrace_floor = parked and parked.undo_open_seq or change.undo_pre_stage_seq
  -- `_retrace_fresh` died with the retrace writer (S2 P-C): the parked
  -- snapshot below is never pre-empted by a fresh retrace pair anymore.
  -- One-shot: read now (before the staging pcall below), then clear, so a
  -- LATER, genuinely different reopen of this same change object never
  -- inherits a stale "already staged" verdict from a press that has
  -- nothing to do with it.
  local parked_already_staged = change._parked_already_staged
  change._parked_already_staged = nil
  local blocks = stamp_model_index(M.build_diff_blocks(review_before or "", target), model)
  if parked then
    local parked_blocks = {}
    for i, block in ipairs(parked.blocks or {}) do
      -- A2: one scrub, owned by the ledger module. The four near-copies
      -- (review_queue, review_open_watchers, review_lifecycle x2) migrate in a
      -- later seam; this is the fullest of the five and defines the field set.
      parked_blocks[i] = hunk_ledger.scrub_paint(vim.deepcopy(block))
    end
    blocks = parked_blocks
    model = vim.deepcopy(parked.model_hunks or model)
    model_source = parked.model_source or model_source
  end
  -- The study reads the operands this path actually used, never a recomputed
  -- approximation. `blocks` is the live table, so a later capture of the same
  -- facts sees the extmark ids painting adds to it.
  local engine_facts = { review_before = review_before, target = target, model = model,
    model_source = model_source, blocks = blocks, parked = parked ~= nil }

  -- Zero hunks means `before` equals `after`: disk already holds the accepted
  -- content, so there is nothing to write and nothing to review, and settling
  -- the change here is correct.
  --
  -- An agent-created EMPTY file is NOT that case, even though it also diffs to zero
  -- hunks. Its base is "no file at all" and the file still does not exist, so creating
  -- it is a real change that the user must be able to reject. Under shadow_apply it was
  -- worse: the write was skipped but the change was still marked accepted without
  -- calling on_shadow_accept, so the creation was silently dropped.
  --
  -- So a create falls through to the normal review below. It stages an empty
  -- buffer with no hunks; the file-level keys (accept-all / reject-file) still
  -- work, and the file is created only by finish_session at accept.
  --
  -- I4: settling here is only for a change with nothing else to decide. A
  -- delete/create operation or a mode proposal binds like any review, with an
  -- EMPTY ledger (the bind opens one over zero blocks), so the file doors and
  -- the permission question stay reachable.
  local carries_decision = change.kind == "delete"
    or change.kind == "create"
    or review_permissions.proposes_mode(change)
  if #blocks == 0 and change.before ~= nil and not carries_decision then
    log.buffer_event("review_staged", { change = change, bufnr = bufnr, outcome = "no_hunks", engine = engine_facts })
    vim.bo[bufnr].modified = false
    change.status = "accepted"
    notify_owner(opts.on_accept, change, "on_accept")
    focus_buf(change.path, bufnr)
    notify_one_line("yana: applied " .. change.rel, vim.log.levels.INFO)
    -- This M.open call may have come from process_next (queue-driven). With
    -- no diff blocks, `active` is never set here, so nothing would ever
    -- advance the queue. Safe for direct (non-queued) calls too: process_next
    -- no-ops when the queue is empty.
    schedule_queue_advance({ opts = opts or {} })
    return true
  end

  local pre_stage_lines = vim.deepcopy(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  log.buffer_event("proposal_stage_begin", { change = change, bufnr = bufnr, engine = engine_facts })
  local stage_ok, stage_err = pcall(function()
    -- `render` alone still paints correctly: `blocks`' positions were computed against
    -- `target`, which IS the buffer's current content in this path.
    _ht_trace(("OPEN rel=%s parked=%s already=%s staged_len=%s buflines=%d"):format(
      tostring(change.rel or change.path), tostring(parked ~= nil),
      tostring(parked_already_staged),
      tostring(parked and type(parked.staged_text) == "string" and #parked.staged_text or "nil"),
      vim.api.nvim_buf_line_count(bufnr)))
    if not parked_already_staged then
      insert_new_lines(bufnr, blocks)
      if parked and type(parked.staged_text) == "string" then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(parked.staged_text))
      end
      if change.before == nil then
        local n = vim.api.nvim_buf_line_count(bufnr)
        if n > 1 and (vim.api.nvim_buf_get_lines(bufnr, n - 1, n, false)[1] or "") == "" then
          vim.api.nvim_buf_set_lines(bufnr, n - 1, n, false, {})
        end
      end
      vim.bo[bufnr].modified = false
    end
  end)
  if not stage_ok then
    break_undo_block(bufnr)
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, pre_stage_lines)
    vim.bo[bufnr].modified = false
    change.review_error = tostring(stage_err)
    log.buffer_event("review_staged", { change = change, bufnr = bufnr, outcome = "stage_failed",
      reason = tostring(stage_err), engine = engine_facts })
    do
      local L = change_ledger(change, opts)
      ledger.record_decision(L, {
        action = "review_refused",
        actor = "system",
        reason = "stage_failed",
        detail = tostring(stage_err),
        change_id = change.id,
        rel = change.rel or change.path,
      })
    end
    notify_one_line("yana: could not stage review: " .. tostring(stage_err), vim.log.levels.WARN)
    announce_state()
    schedule_queue_advance({ opts = opts or {} })
    return false, tostring(stage_err)
  end

  if parked then
    local restored = diff.buffer_bytes_snapshot(bufnr)
    local sig = {}
    for i, block in ipairs(blocks or {}) do
      sig[i] = table.concat({
        tostring(block.model_index or i),
        tostring(#(block.old_lines or {})),
        tostring(#(block.new_lines or {})),
        tostring(block.new_start_line or ""),
        tostring(block.new_end_line or ""),
      }, ":")
    end
    local got_sig = table.concat(sig, "|")
    if restored ~= parked.staged_text or got_sig ~= parked.pending_signature then
      break_undo_block(bufnr)
      pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, pre_stage_lines)
      vim.bo[bufnr].modified = false
      change.review_error = "parked review restore mismatch"
      log.buffer_event("review_staged", { change = change, bufnr = bufnr, outcome = "restore_mismatch", engine = engine_facts })
      ledger.record_decision(change_ledger(change, opts), {
        action = "review_refused",
        actor = "system",
        reason = "park_restore_mismatch",
        detail = change.review_error,
        change_id = change.id,
        rel = change.rel or change.path,
      })
      notify_one_line("yana: refused to reopen parked review for " .. (change.rel or change.path) .. " -- restore mismatch", vim.log.levels.WARN)
      announce_state()
      schedule_queue_advance({ opts = opts or {} })
      return false, "parked review restore mismatch"
    end
    -- `change._parked_review` is NOT cleared here. It is the recovery snapshot,
    -- and a rebuild that fails below -- an unwatchable buffer, a keymap that
    -- throws half-way through the bind -- must still be recoverable from it
    -- (R7, design :87). It is dropped only once the replacement has bound.
  end

  -- Seal the staging into its own undo block and bookmark where it landed. THE REVIEW'S
  -- OPEN STATE: the buffer exactly as the operator was first shown it, every hunk still
  -- the agent's and nothing decided. `U` walks back to this integer once it has taken
  -- every decision off the stack, so what the operator gets is the review they opened.
  break_undo_block(bufnr)
  local undo_seq_now = buf_undo_seq(bufnr)
  local undo_open_seq = undo_seq_now

  -- The change model, and the rung-1 capture over the render that just ran.
  -- Recorded before the state exists, because the FIRST render is the one the
  -- reference defect appears in.
  do
    local L = change_ledger(change, opts)
    ledger.mark(L, "first_review_opened")
    -- `_retrace_reintegration` died with the retrace writer (S2 P-C): every
    -- first open of a review now bumps reviews_opened unconditionally.
    ledger.bump(L, "reviews_opened")
    local hunks = {}
    for i, b in ipairs(blocks) do
      hunks[i] = {
        index = i,
        old_count = #(b.old_lines or {}),
        new_count = #(b.new_lines or {}),
        new_start_line = b.new_start_line,
        new_end_line = b.new_end_line,
      }
    end
    -- Built AFTER the hunks table exists (unlike before), so the durable
    -- log carries the same geometry the in-memory ledger gets below --
    -- index/old_count/new_count/new_start_line/new_end_line, never line
    -- contents.
    require("yana.log").lifecycle_later("review.open", {
      turn_id = change.turn_id or change.turn_gen,
      generation = change.turn_gen,
      path = change.rel or change.path,
      hunks = hunks,
    })
    ledger.record_hunks(L, {
      change_id = change.id,
      rel = change.rel or change.path,
      path = change.path,
      kind = change.kind,
      added = change.added,
      removed = change.removed,
      bufnr = bufnr,
      hunks = hunks,
      model_source = model_source,
    })
  end
  ledger.mark(change_ledger(change, opts), "review_profile_hunks_ready")


  local bound, bound_state = review_open_bind_factory.new(child_deps({
    change = change,
    bufnr = bufnr,
    opts = opts,
    blocks = blocks,
    model = model,
    model_source = model_source,
    parked = parked,
    parked_undone_decisions = parked_undone_decisions,
    undo_open_seq = undo_open_seq,
    undo_seq_now = undo_seq_now,
    retrace_floor = retrace_floor,
    initial_landing_block = initial_landing_block,
  }))
  -- THE REPLACEMENT HAS BOUND. Only now does the recovery snapshot go: until
  -- this line a failed rebuild can still be recovered from it, which is the
  -- whole of R7's "keep `_parked_review` until a replacement has bound
  -- successfully".
  if bound and parked then
    change._parked_review = nil
  end
  log.buffer_event("review_staged", { change = change, bufnr = bufnr,
    outcome = bound and "opened" or "bind_failed", engine = engine_facts })
  return bound, bound_state

  end
  setfenv(open, env)
  return open
end

return Factory
