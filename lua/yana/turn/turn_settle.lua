-- Turn settlement at End/abort: ONE projection calculation, two write doors.
--
-- F-APPLY-JOURNAL. The operator's `:w` never comes here: saving is Neovim's
-- (CORE "Saving is Neovim's", LEDGER N51).
--
--   snapshot -> turn_projection.compute -> then either
--   accepted content: final text into the buffer -> Neovim's `:write`, or
--   an accepted deletion, an accepted permission change:
--   acquire the existing file claim -> the diary-backed apply path
--   -> File:record_projection, only after the write has actually succeeded.
--
-- `yana.turn.turn_projection` is the only calculation of the final bytes:
-- nothing here re-derives an action, target bytes or a mode.
local projection = require("yana.turn.turn_projection")
local diff = require("yana.diff")
local hash = require("yana.safety.hash")

local M = {}

local snapshot = require("yana.turn.turn_settle_snapshot")

--- The `{turn, path, mode}` key named by the File's current change. This stays
--- available after a successful write resets the base mode, so undo can still
--- redo the same proposal. A product Turn has no id, so its table identity is
--- used; unit Turns carry `id`.
function M.change_proposal_key(f)
  local change = type(f) == "table" and f.change or {}
  local turn = f.turn
  return {
    turn = turn == nil and "no-turn" or (turn.id or turn.turn_id or tostring(turn)),
    path = f.path or change.path or "?",
    mode = tostring((f.proposal or change).after_mode),
  }
end

--- THE proposal key, `{turn, path, mode}`, of the File's CURRENT change (its
--- selected version's proposal), or nil when it proposes no mode of its own: none
--- differing from the effective mode (the accepted mode an earlier cycle carried,
--- else the original). A fresh mode change thus waits for its own decision.
function M.mode_proposal_key(f)
  local change = type(f) == "table" and f.change or nil
  local proposed = type(change) == "table" and (f.proposal or change).after_mode or nil
  local effective = type(f) == "table" and f.accepted_mode or nil
  if effective == nil and proposed ~= nil then effective = change.base_mode or change.before_mode end
  if proposed == nil or proposed == effective then
    return nil
  end
  return M.change_proposal_key(f)
end

--- THE key-match owner: the File's `mode_verdict` when it records the CURRENT
--- proposal by content, else nil. A record for a revised-away proposal stays on
--- the File and in history but authorises nothing.
function M.current_mode_verdict(f)
  local key = M.mode_proposal_key(f)
  return key and require("yana.turn.turn_file").mode_verdict_for(f, key) or nil
end

local function claim_context(f)
  local opts = f.review_opts or {}
  local change = f.change or {}
  return {
    review_turn = opts.review_turn,
    turn_id = change.turn_id or change.turn_gen,
    yanad_session_id = opts.yanad_session_id,
    session_id = opts.session_id,
    workspace = opts.workspace,
  }
end

-- The cached settlement evidence -- the stamp and the still-current comparison
-- -- lives in `turn_settle_snapshot`. Re-exported so the settler interface the
-- Turn deps table and every caller already use is unchanged.
M.settled_current = snapshot.settled_current

--- `File:record_projection` is the ONLY door that advances rebased applier
--- evidence. A turn entry that is not yet a `turn_file` File has no such door;
--- the write still committed, so the settlement still succeeded, and the caller
--- is told what could not be recorded rather than being handed a false red.
local function record(f, projection_record)
  if type(f.record_projection) ~= "function" then
    return false, "this turn entry has no record_projection door"
  end
  return f:record_projection(projection_record)
end

--- The buffer End saves a file through: the Turn file's own buffer, else the
--- buffer snapshotted at submit, else a buffer loaded for the path now. The
--- second answer says whether this module loaded it, so it can be wiped after.
local function save_buffer_for(f, change, path, fixed_bufnr)
  local bufnr = fixed_bufnr or f.bufnr
  if snapshot.valid_buffer(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    return bufnr, false
  end
  local capture = type(change.buffer_capture) == "table" and change.buffer_capture or nil
  local captured = capture and capture.bufnr
  if snapshot.valid_buffer(captured) and vim.api.nvim_buf_is_loaded(captured) then
    return captured, false
  end
  local existing = vim.fn.bufnr(path, false)
  if existing > 0 and vim.api.nvim_buf_is_loaded(existing) then
    return existing, false
  end
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  return bufnr, true
end

--- End saves through Neovim's ordinary write. A declined changed-file question
--- returns without throwing and can even fire BufWritePost; the modified flag
--- must therefore remain set until Neovim actually saves the buffer.
local function write_through_buffer(f, change, path, plan, fixed_bufnr)
  local bufnr, loaded_here = save_buffer_for(f, change, path, fixed_bufnr)
  if not vim.bo[bufnr].modifiable then
    return false, "nomodifiable"
  end
  local lines = plan.buffer_lines
  if lines == nil or bufnr ~= (fixed_bufnr or f.bufnr) then
    lines = snapshot.lines_of_bytes(bufnr, plan.bytes)
  end
  local wants_eol = plan.bytes:sub(-1) == "\n"
  local ok, err = pcall(function()
    if not vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), lines) then
      require("yana.review_watch").own_splice(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      end)
    end
    vim.bo[bufnr].fixendofline = wants_eol
    vim.bo[bufnr].endofline = wants_eol
    local dir = vim.fn.fnamemodify(path, ":h")
    if dir ~= "" then
      vim.fn.mkdir(dir, "p")
    end
    -- A proposal can be visible with 'modified' clear. Mark the terminal
    -- projection unsaved so a declined write cannot masquerade as success.
    vim.bo[bufnr].modified = true
    local wrote, write_err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("silent keepalt keepjumps write")
    end)
    if not wrote then
      error(write_err, 0)
    end
    if vim.bo[bufnr].modified then
      error("Neovim did not write the buffer", 0)
    end
  end)
  if ok and loaded_here and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  if not ok then
    return false, tostring(err)
  end
  return true
end

--- One settlement attempt for `settle`.
---
--- `done(ok, reason, detail)` fires EXACTLY ONCE, including on synchronous
--- completion, and `detail` carries `{phase, written, diary_dir, op_id}` --
--- the commit receipt whenever the write committed, so a committed-but-
--- readback/reconcile-failed attempt is never mistaken for no write at all.
--- Returns `true`, `false, reason`, or `"pending"`.
local function run(f, purpose, done, end_item, end_binding)
  local has_done = type(done) == "function"
  local finished, result_ok, result_err = false, nil, nil
  local function finish(ok, err, detail)
    if finished then return end
    finished, result_ok, result_err = true, ok == true, err
    if result_ok then
      if end_item then
        -- Confirmed End has no retry walk. A live settlement_state read here
        -- would re-read verdicts after an asynchronous claim despite the plan.
        f:record_settlement({ plan_index = end_item.index, path = end_item.path },
          f.settled_at_exit)
      else
        local stamped, stamp = pcall(snapshot.settlement_state, f)
        f:record_settlement(stamped and stamp or nil, f.settled_at_exit)
      end
    else
      f:record_settlement(nil, f.settled_at_exit)
    end
    if has_done then done(result_ok, result_err, detail) end
  end
  local function answer()
    if finished then return result_ok, result_err end
    return "pending"
  end

  local change = end_item and vim.deepcopy(end_item.route.change)
    or (type(f.change) == "table" and f.change or {})
  local path = end_item and end_item.path or change.path or f.path
  local bufnr = end_binding and end_binding.bufnr or f.bufnr

  -- SNAPSHOT, then CALCULATE. Both are pure; neither touches disk or the claim.
  local snapshot_ok, input
  if end_item then
    snapshot_ok, input = true, vim.deepcopy(end_item.input)
  else
    snapshot_ok, input = pcall(snapshot.snapshot_of, f, purpose)
  end
  if not snapshot_ok then
    finish(false, tostring(input), { phase = "snapshot", written = false })
    return answer()
  end
  local plan, reason = projection.compute(input)
  if plan == nil then
    finish(false, reason, { phase = "projection", written = false })
    return answer()
  end

  -- End reconciles the buffer to the terminal projection.
  --
  -- ONLY A CONFIRMED OUTCOME MAY DO THIS, so it is a function called from the
  -- two places that have one -- a confirmed no-op and a committed write -- and
  -- never before the write door below. Running it first meant a refusal (a
  -- missing door, a lost claim, a failed apply) left the operator looking at
  -- the terminal text of an End that never happened, with a pending hunk
  -- silently decided for them (F-APPLY-JOURNAL, F-HONEST-OUTCOME).
  --
  -- Not when the terminal projection is ABSENCE. Emptying the buffer of a file
  -- that is about to be removed leaves a modified buffer over a path with no
  -- file, and the next save door writes that empty buffer straight back --
  -- which is how a removed zero-accepted creation reappeared as a one-byte
  -- file. The buffer is left alone; the file goes.
  local function reconcile_buffer()
    if plan.action == "delete" or plan.buffer_lines == nil then return true end
    if not snapshot.valid_buffer(bufnr) then return true end
    if not vim.bo[bufnr].modifiable then return false, "nomodifiable" end
    local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if vim.deep_equal(current, plan.buffer_lines) then return true end
    -- THROUGH THE WATCHER'S OWN DOOR. This is Yana replacing the displayed
    -- proposal with the terminal text, and the review watcher has to know that:
    -- a bare `set_lines` reaches its timeline as an unexplained change and is
    -- interpreted as the operator's. `own_splice` mutes interpretation only --
    -- the ledger still transports the geometry exactly once. Resolved at call
    -- time, not captured, so the door is whichever one is installed now.
    local set_ok, set_err = pcall(function()
      return require("yana.review_watch").own_splice(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, plan.buffer_lines)
      end)
    end)
    if not set_ok then return false, tostring(set_err) end
    return true
  end

  -- A RETAINED COMMIT RECEIPT means an earlier attempt committed this operation
  -- through the journaled writer and only its readback or buffer reconcile
  -- failed. The operation is NOT repeated when the retry would write exactly
  -- what that commit wrote: the receipt carries the action, bytes and mode it
  -- committed, and they are compared with this projection. The file on disk is
  -- not read.
  -- A projection that now differs falls through to the write below.
  local receipt = type(f.commit_receipt) == "table" and f.commit_receipt or nil
  local committed = receipt and type(receipt.committed) == "table" and receipt.committed or nil
  local committed_already = committed ~= nil
    and plan.action ~= "none"
    and committed.action == plan.action
    and committed.bytes == plan.bytes
    and committed.mode == plan.mode

  local save_kept = false
  if plan.action == "none" or committed_already then
    -- A confirmed no-op IS an outcome: nothing to write, so the terminal text
    -- is already decided and the buffer may be reconciled to it.
    local reconciled, reconcile_err = reconcile_buffer()
    if not reconciled then
      finish(false, reconcile_err, { phase = "buffer", written = false })
      return answer()
    end
    if plan.action == "none" then
      if end_item then
        -- A plain :w clears 'modified' after saving the visible proposal.
        -- End still owes a save if its frozen terminal bytes differ from that
        -- frozen buffer, even when Neovim considered the proposal saved.
        save_kept = plan.bytes ~= nil and (end_item.buffer_modified
          or (end_item.buffer_bytes ~= nil and end_item.buffer_bytes ~= plan.bytes))
      else
        save_kept = snapshot.buffer_owes_save(f, plan)
      end
    end
  end
  if (plan.action == "none" or committed_already) and not save_kept then
    if plan.action == "none" and input.original.present == true then
      -- A creation that ends absent over a file its buffer did not write (N51).
      require("yana.turn.turn_save_record").report_kept(change.rel or path)
    end
    local detail = {
      -- `write` when this settlement is spending a commit the earlier attempt
      -- made: the operation DID happen, and a reader must not see `settled`
      -- and conclude nothing was written.
      phase = committed_already and "write" or "settled",
      written = receipt ~= nil,
      diary_dir = receipt and receipt.diary_dir or nil,
      op_id = receipt and receipt.op_id or nil,
    }
    f:clear_receipt()
    finish(true, nil, detail)
    return answer()
  end

  -- END SAVES ACCEPTED CONTENT THROUGH THE BUFFER, and a kept file whose final
  -- buffer owes a save (above). Only an accepted deletion and an accepted
  -- permission change stay on the journaled writer below.
  if save_kept or (plan.action == "replace" and plan.mode == input.original.mode) then
    local wrote, write_err = write_through_buffer(f, change, path, plan, bufnr)
    if not wrote then
      finish(false, write_err, { phase = "write", written = false, via = "buffer" })
      return answer()
    end
    local detail = { phase = "write", written = true, via = "buffer" }
    -- What was written is known exactly, so the change's evidence moves to it
    -- without reading the file back.
    local recorded, record_err = record(f, {
      path = path,
      bytes = plan.bytes,
      base_hash = hash.hash_bytes(plan.bytes),
      base_state = "file",
    })
    if not recorded then
      detail.unrecorded = record_err
    end
    f:clear_receipt()
    finish(true, nil, detail)
    return answer()
  end

  local opts = f.review_opts or {}
  local accept = end_binding and end_binding.accept or opts.on_shadow_accept
  local shadow_apply = end_item ~= nil and end_item.route.shadow_apply or nil
  if end_item == nil then shadow_apply = opts.shadow_apply end
  if shadow_apply ~= true or type(accept) ~= "function" then
    finish(false, "no journaled write door for this file at turn " .. purpose, { phase = "door", written = false })
    return answer()
  end

  -- THE EXPLICIT WRITE DESCRIPTION. The apply routes consume this and derive
  -- nothing of their own: not the action from `change.kind`, not the mode from
  -- `change.after_mode`.
  -- THE PINNED REVIEW BUFFER. At End the review buffer legitimately differs
  -- from BOTH fingerprints the applier's unsaved-edits guard knows: it is
  -- neither pre-turn disk nor the terminal bytes, because it still shows the
  -- proposal the review painted. The guard therefore called Yana's own staged
  -- proposal a human edit and refused its own reconcile, leaving disk accepted
  -- and the buffer showing a pending hunk that no longer exists.
  --
  -- The pin is taken HERE, before the asynchronous claim. The guard re-reads
  -- the buffer AFTER the claim and accepts it only if it is still byte-identical
  -- to this pin. That is one more EXACTLY KNOWN value, not a wildcard: a human
  -- edit in that window changes the hash and is refused exactly as before.
  local staged_proof
  if snapshot.valid_buffer(bufnr) then
    local staged_bytes = diff.buffer_bytes_snapshot(bufnr)
    if staged_bytes ~= nil then
      staged_proof = {
        hash = hash.hash_bytes(staged_bytes),
        tick = vim.api.nvim_buf_get_changedtick(bufnr),
        seq = vim.api.nvim_buf_call(bufnr, vim.fn.changenr),
      }
    end
  end

  local accept_opts = {
    staged_bufnr = bufnr,
    -- The proof handed down to the guard; an argument only, like `own_splice`,
    -- never part of the write description below.
    staged_proof = staged_proof,
    -- The splice door handed down to the applier's reconcile; an argument
    -- only, never on the projection below.
    own_splice = require("yana.review_watch").own_splice,
    projection = {
      action = plan.action,
      bytes = plan.bytes,
      mode = plan.mode,
      purpose = purpose,
    },
  }
  local composed = plan.action == "delete" and nil or plan.bytes

  local function commit_result(called, ok, err, applied)
    if not called then
      finish(false, tostring(ok), { phase = "apply", written = false })
      return
    end
    if ok ~= true then
      finish(false, err, { phase = "apply", written = false })
      return
    end
    local detail = {
      phase = "write",
      written = true,
      diary_dir = type(applied) == "table" and applied.diary_dir or nil,
      op_id = type(applied) == "table" and applied.op_id or nil,
      -- The operation this commit performed, as the projection described it:
      -- a retry spends this receipt only while it would write the same thing.
      committed = { action = plan.action, bytes = plan.bytes, mode = plan.mode },
    }
    if type(applied) == "table" and applied.reconcile_error ~= nil then
      -- COMMITTED, BUT NOT READ BACK. The receipt is retained on the File so
      -- the retry reuses it instead of writing again.
      detail.phase = "readback"
      record(f, { path = path, receipt = detail })
      f:hold_commit(detail)
      finish(false, applied.reconcile_error, detail)
      return
    end
    -- CONFIRMED. Only now does rebased applier evidence advance, and only now
    -- may the buffer be moved to the terminal projection. A reconcile failure
    -- here does NOT unwrite the file: the receipt still reports the write, so
    -- the retry sees its own committed operation rather than repeating it.
    local reconciled, reconcile_err = reconcile_buffer()
    if not reconciled then
      detail.phase = "buffer"
      record(f, { path = path, receipt = detail })
      f:hold_commit(detail)
      finish(false, reconcile_err, detail)
      return
    end
    -- The applier verified what it committed; the evidence moves to those
    -- known values without this module reading the file back.
    local deleted = plan.action == "delete"
    local recorded, record_err = record(f, {
      path = path,
      bytes = (not deleted) and plan.bytes or nil,
      base_hash = hash.hash_bytes(deleted and "" or plan.bytes),
      base_state = deleted and "absent" or "file",
      base_mode = (not deleted) and plan.mode or nil,
      receipt = detail,
    })
    if not recorded then
      detail.unrecorded = record_err
    end
    f:clear_receipt()
    finish(true, nil, detail)
  end

  -- ACQUIRE THE EXISTING CLAIM, then take the existing diary-backed apply path.
  local apply_sessions = require("yana.shadow.apply_sessions")
  local context = end_item and vim.deepcopy(end_item.route.context) or claim_context(f)
  local token = {}
  -- The decisions this projection was built from; see `decision_stamp` and the
  -- re-ask inside the claim callback below.
  local decisions_at_projection = not end_item and snapshot.decision_stamp(f) or nil

  local started, start_err = apply_sessions.request_file_claim(context, change,
    function(ok, value, code, refusal, frozen)
      if not ok then
        apply_sessions.record_file_claim_refusal(change, code, refusal)
        finish(false, value, { phase = "claim", written = false })
        return
      end
      local live = end_item and vim.deepcopy(end_item.route.context) or claim_context(f)
      if apply_sessions.grant_file_claim(change, token, value, frozen or context, live) == false then
        finish(false, "the yanad file.claim answer does not name this settlement attempt",
          { phase = "claim", written = false })
        return
      end
      -- RE-ASKED AFTER THE WAIT, before anything is written: the operator keeps
      -- reviewing while the claim is awaited, and a decision made in that window
      -- moves the projection without touching a byte. Refusing leaves the Turn
      -- live, the review open and every decision intact, so a fresh End projects
      -- all of them; the grant must not stay installed.
      if not end_item and snapshot.decision_stamp(f) ~= decisions_at_projection then
        apply_sessions.clear_file_claim_grant(change)
        finish(false,
          "a review decision changed while this End waited for the file claim; "
            .. "nothing was written -- end the turn again to apply every decision",
          { phase = "decision_drift", written = false })
        return
      end
      -- THE LAST-INSTANT PROVENANCE RE-STAT, inside the claim: a creation's file
      -- goes only while it is still its review buffer's own save; else it is kept.
      if plan.action == "delete" and not input.original.exists
        and not require("yana.turn.turn_save_record").matches(path) then
        apply_sessions.clear_file_claim_grant(change)
        -- Gone during the wait: nothing was kept, so nothing to say (critic N51 L2).
        if require("yana.turn.turn_save_record").identity(path) ~= nil then
          require("yana.turn.turn_save_record").report_kept(change.rel or path)
        end
        finish(true, nil, { phase = "kept", written = false })
        return
      end
      local called, a1, a2, a3 = pcall(accept, change, composed, accept_opts)
      if not called or a1 ~= true then
        apply_sessions.clear_file_claim_grant(change)
      end
      commit_result(called, a1, a2, a3)
    end)
  if not started then
    apply_sessions.record_file_claim_refusal(change, "claim_unavailable", nil)
    finish(false, start_err, { phase = "claim", written = false })
  end
  return answer()
end

--- Settle one Turn file at End or abort. Accepted content is saved through
--- the buffer, synchronously. An accepted deletion or permission change is
--- asynchronous because its file.claim is won at the journaled write door,
--- then consumed immediately by the applier. `done` is called once; a pending
--- return is not success.
function M.settle(f, done)
  return run(f, "exit", done)
end

-- Confirmed End consumes only the private plan's detached value item. The File
-- binding is an output destination for receipt/rebased evidence, never a source
-- for the projection, owner or claim route.
function M.settle_plan(item, binding, done)
  return run(binding.file, "exit", done, item, binding)
end

return M
