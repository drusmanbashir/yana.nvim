-- Turn settlement: ONE projection calculation, ONE journaled write door.
--
-- F-APPLY-JOURNAL, F-HUMAN-SAVE. Ordinary own-file `:w` and End/abort
-- both come here, and both take exactly the same steps in exactly the same
-- order:
--
--   snapshot -> turn_projection.compute -> acquire the existing file claim
--   -> invoke the existing diary-backed apply path -> File:record_projection,
--      and only after the write has actually succeeded.
--
-- The composition bodies this module used to carry (its own line splitter,
-- renderer, disk differ, hunk sorter, `compose_disk` and `compose_buffer`) are
-- GONE: they were the second calculation of the final bytes, and
-- `yana.turn.turn_projection` is the only one now. Nothing here re-derives an
-- action, target bytes or a mode.
local projection = require("yana.turn.turn_projection")
local creation_touch = require("yana.paths.creation_touch")
local diff = require("yana.diff")
local hash = require("yana.safety.hash")

local M = {}

local uv = vim.uv or vim.loop

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
    mode = tostring(change.after_mode),
  }
end

--- THE proposal key, `{turn, path, mode}`, of the File's CURRENT change, or nil
--- when the change proposes no mode of its own.
function M.mode_proposal_key(f)
  local change = type(f) == "table" and f.change or nil
  local proposed = type(change) == "table" and change.after_mode or nil
  if proposed == nil or proposed == (change.base_mode or change.before_mode) then
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

-- Defined below, with the other `record_projection` callers; named here so the
-- two reversal sites above it can reach it.
local record_own_removal

--- Rejecting every hunk of a creation must leave the path ABSENT, and it goes
--- through the touch owner's own only-if-still-empty REVERSE -- R6's "existing
--- safe removal rule" -- not through a delete the applier would journal.
local function reverse_untouched_creation(f, change, path)
  local ok, err = creation_touch.remove(path)
  if not ok then
    return false, err
  end
  record_own_removal(f, path)
  if type(change) == "table" and change.status == "pending" then
    change.status = "rejected"
  end
  return true
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

--- THE REVERSE of the forward rebase `creation_touch.on_proposal` performs.
--- The touch brings the path into existence and stamps the change with
--- `base_state = "file"`; removing that touch has to put the stamp back, or the
--- change still claims a world this Turn itself dismantled. A later accepted
--- decision then prepares its write against that stale claim and the applier
--- refuses Yana's own removal as if a stranger had done it -- "this file
--- existed when the change was prepared and has been removed since".
---
--- Written through `File:record_projection`, the one door for rebased applier
--- evidence: no second writer of change evidence. `base_hash` is restated as
--- the empty hash because the applier requires a well-formed fingerprint for
--- every tag; for an absent base it compares nothing else, so the touch-time
--- mode is simply no longer consulted.
---
--- ONLY after the path is OBSERVED absent. `creation_touch.remove` answering
--- yes is not the same as the path being gone, and a base of "absent" recorded
--- over a path something still occupies would license exactly the overwrite
--- general drift refusal exists to stop.
function record_own_removal(f, path)
  local ok, err
  if uv.fs_lstat(path) ~= nil then
    ok, err = false, "the path still exists"
  else
    ok, err = record(f, {
      path = path,
      base_state = "absent",
      base_hash = hash.hash_bytes(""),
    })
  end
  if not ok then
    -- Never a settle refusal: the removal itself succeeded. It is a LATER
    -- accept that will refuse, so say here why, or that refusal arrives with
    -- no trace of the decision that caused it.
    pcall(function()
      require("yana.log").write("WARN", string.format(
        "turn settle removed its own creation at %s but did not record the absent base: %s",
        tostring(path), tostring(err)))
    end)
  end
  return ok, err
end

--- Validate an ordinary own-file save request against the retained state.
--- `{bufnr, state, changedtick}`, and all three must match: another file's
--- buffer, a superseded review state or a buffer that has moved since the
--- request was raised are all refusals, not writes.
local function own_file_request(f, request)
  if type(request) ~= "table" then
    return false, "turn_settle.save: " .. tostring(f.path) .. " needs a {bufnr, state, changedtick} request"
  end
  if request.bufnr ~= f.bufnr then
    return false,
      "turn_settle.save: buffer " .. tostring(request.bufnr) .. " is not the retained buffer for " .. tostring(f.path)
  end
  if not snapshot.valid_buffer(f.bufnr) then
    return false, "turn_settle.save: " .. tostring(f.path) .. " has no live buffer to save"
  end
  local retained = f.review_state
  if request.state ~= nil and retained ~= nil and not rawequal(request.state, retained) then
    return false, "turn_settle.save: that review state is not the current one for " .. tostring(f.path)
  end
  local live = vim.api.nvim_buf_get_changedtick(f.bufnr)
  if request.changedtick ~= nil and request.changedtick ~= live then
    return false,
      "turn_settle.save: "
        .. tostring(f.path)
        .. " moved since the request (changedtick "
        .. tostring(request.changedtick)
        .. " != "
        .. tostring(live)
        .. ")"
  end
  return true
end

--- One settlement attempt, shared verbatim by `settle` and `save`.
---
--- `done(ok, reason, detail)` fires EXACTLY ONCE, including on synchronous
--- completion, and `detail` carries `{phase, written, diary_dir, op_id}` --
--- the commit receipt whenever the write committed, so a committed-but-
--- readback/reconcile-failed attempt is never mistaken for no write at all.
--- Returns `true`, `false, reason`, or `"pending"`.
local function run(f, purpose, request, done)
  local has_done = type(done) == "function"
  local finished, result_ok, result_err = false, nil, nil
  local function finish(ok, err, detail)
    if finished then return end
    finished, result_ok, result_err = true, ok == true, err
    if result_ok then
      local stamped, stamp = pcall(snapshot.settlement_state, f)
      -- The stamp is this module's verdict; the exit flag is the End's and is
      -- handed straight back, so a direct save never speaks for an End.
      f:record_settlement(stamped and stamp or nil, f.settled_at_exit)
    else
      f:record_settlement(nil, f.settled_at_exit)
    end
    if has_done then done(result_ok, result_err, detail) end
  end
  local function answer()
    if finished then return result_ok, result_err end
    return "pending"
  end

  if purpose == "save" then
    local allowed, why = own_file_request(f, request)
    if not allowed then
      finish(false, why, { phase = "request", written = false })
      return answer()
    end
  end

  local change = type(f.change) == "table" and f.change or {}
  local path = change.path or f.path

  -- SNAPSHOT, then CALCULATE. Both are pure; neither touches disk or the claim.
  local snapshot_ok, input = pcall(snapshot.snapshot_of, f, purpose)
  if not snapshot_ok then
    finish(false, tostring(input), { phase = "snapshot", written = false })
    return answer()
  end
  local capture = change.home_buffer_capture
  if purpose == "exit" and capture and change.status == "rejected" then
    local expected_identity = tostring(capture.ino) .. ":" .. tostring(capture.dev)
    if not input.disk.exists or input.disk.bytes ~= capture.disk_bytes or input.disk.identity ~= expected_identity then
      finish(false, "buffer-only target changed on disk before rejected review could close", {
        phase = "projection", written = false,
      })
      return answer()
    end
    local live = snapshot.valid_buffer(f.bufnr) and diff.buffer_bytes_snapshot(f.bufnr) or nil
    if live ~= capture.buffer_bytes then
      finish(false, "buffer-only human baseline changed before rejected review could close", {
        phase = "projection", written = false,
      })
      return answer()
    end
    -- Rejecting every agent hunk is not permission to save the operator's
    -- pre-existing unsaved buffer. Preserve it and close with no write door.
    vim.bo[f.bufnr].modified = capture.buffer_bytes ~= capture.disk_bytes
    finish(true, nil, { phase = "settled", written = false })
    return answer()
  end
  local plan, reason = projection.compute(input)
  if plan == nil then
    finish(false, reason, { phase = "projection", written = false })
    return answer()
  end

  -- End reconciles the buffer to the terminal projection; an ordinary save keeps
  -- the displayed pending proposal, ledger and undo history exactly as they are.
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
    if purpose ~= "exit" or plan.action == "delete" or plan.buffer_lines == nil then return true end
    if not snapshot.valid_buffer(f.bufnr) then return true end
    if not vim.bo[f.bufnr].modifiable then return false, "nomodifiable" end
    local current = vim.api.nvim_buf_get_lines(f.bufnr, 0, -1, false)
    if vim.deep_equal(current, plan.buffer_lines) then return true end
    -- THROUGH THE WATCHER'S OWN DOOR. This is Yana replacing the displayed
    -- proposal with the terminal text, and the review watcher has to know that:
    -- a bare `set_lines` reaches its timeline as an unexplained change and is
    -- interpreted as the operator's. `own_splice` mutes interpretation only --
    -- the ledger still transports the geometry exactly once. Resolved at call
    -- time, not captured, so the door is whichever one is installed now.
    local set_ok, set_err = pcall(function()
      return require("yana.review_watch").own_splice(f.bufnr, function()
        vim.api.nvim_buf_set_lines(f.bufnr, 0, -1, false, plan.buffer_lines)
      end)
    end)
    if not set_ok then return false, tostring(set_err) end
    return true
  end

  -- A CREATION NOBODY ACCEPTED disappears through the touch owner's own
  -- only-if-still-empty reverse, which is the existing safe removal rule R6
  -- names. The projection decided that it must be absent; this is how.
  if plan.action == "delete" and snapshot.creation(f, change) then
    local removed, remove_err = reverse_untouched_creation(f, change, path)
    finish(removed, remove_err, { phase = "reverse_creation", written = removed == true })
    return answer()
  end

  -- A RETAINED COMMIT RECEIPT means an earlier attempt committed this operation
  -- and only its readback or reconcile failed. The operation is NOT repeated.
  local receipt = type(f.commit_receipt) == "table" and f.commit_receipt or nil

  -- THE PROJECTION CANNOT ALWAYS SEE THAT COMMIT. `turn_projection` compares
  -- the target against `last_verified_disk`, and a write whose readback failed
  -- never got to refresh that record -- it still describes the file from BEFORE
  -- the write. So the projection says `replace` for an operation already on
  -- disk, and the write door runs a second time for one End.
  --
  -- THE PROOF, AND IT IS THE WHOLE FILE. The retained receipt says an operation
  -- committed and carries `postcommit`: exactly what that commit left on disk.
  -- The retry re-reads disk NOW and every part must still agree -- existence,
  -- bytes, permissions and file IDENTITY -- and the terminal projection's own
  -- mode must agree too, so a projection that now wants different permissions
  -- is not silently satisfied by the old ones.
  --
  -- Bytes alone were not enough, and that was the earlier mistake here: a file
  -- can hold the right text with the wrong mode, and a different inode can hold
  -- an identical copy. Neither is the operation we committed. A receipt is
  -- never proof by itself; it only says which operation to look for.
  --
  -- Anything short of full agreement falls through to the guarded write door
  -- below, where a real refusal is still a real refusal.
  local committed_already = false
  if receipt ~= nil and plan.action == "replace" and type(receipt.postcommit) == "table" then
    local landed, now = receipt.postcommit, input.disk
    committed_already = type(now) == "table"
      and now.exists == true
      and landed.exists == true
      and now.bytes == plan.bytes
      and now.bytes == landed.bytes
      and now.mode == landed.mode
      and now.identity == landed.identity
      and (plan.mode == nil or plan.mode == now.mode)
  end

  if plan.action == "none" or committed_already then
    -- A confirmed no-op IS an outcome: nothing to write, so the terminal text
    -- is already decided and the buffer may be reconciled to it.
    local reconciled, reconcile_err = reconcile_buffer()
    if not reconciled then
      finish(false, reconcile_err, { phase = "buffer", written = false })
      return answer()
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
    local recorded, record_err = record(f, {
      path = path,
      last_verified_disk = input.disk,
    })
    if not recorded then
      detail.unrecorded = record_err
    end
    f:clear_receipt()
    finish(true, nil, detail)
    return answer()
  end

  local opts = f.review_opts or {}
  local accept = opts.on_shadow_accept
  if opts.shadow_apply ~= true or type(accept) ~= "function" then
    finish(false, "no journaled write door for this file at turn " .. purpose, { phase = "door", written = false })
    return answer()
  end

  -- THE EXPLICIT WRITE DESCRIPTION. The apply routes consume this and derive
  -- nothing of their own: not the action from `change.kind`, not the mode from
  -- `change.after_mode`. `preserve_review` withholds only the buffer reconcile
  -- on an ordinary save, never a disk identity or content check.
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
  if snapshot.valid_buffer(f.bufnr) then
    local staged_bytes = diff.buffer_bytes_snapshot(f.bufnr)
    if staged_bytes ~= nil then
      staged_proof = {
        hash = hash.hash_bytes(staged_bytes),
        tick = vim.api.nvim_buf_get_changedtick(f.bufnr),
      }
    end
  end

  local accept_opts = {
    staged_bufnr = f.bufnr,
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
      preserve_review = purpose == "save",
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
    }
    if type(applied) == "table" and applied.reconcile_error ~= nil then
      -- COMMITTED, BUT NOT READ BACK. Disk holds the operation; the receipt is
      -- retained on the File so the retry reuses it instead of writing again.
      -- WHAT THE COMMIT LEFT ON DISK is captured here, in full -- existence,
      -- bytes, permissions and file identity -- because on the retry that is
      -- the only description of the operation we actually performed. Bytes
      -- alone cannot stand for it: a file can carry the right text with the
      -- wrong mode, or be a different inode holding an identical copy.
      detail.phase = "readback"
      detail.postcommit = snapshot.disk_evidence(path)
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
    local on_disk = snapshot.disk_evidence(path)
    local recorded, record_err = record(f, {
      path = path,
      bytes = on_disk.exists and on_disk.bytes or nil,
      base_hash = on_disk.exists and on_disk.bytes and hash.hash_bytes(on_disk.bytes) or nil,
      base_state = on_disk.exists and "file" or nil,
      base_mode = on_disk.mode,
      last_verified_disk = on_disk,
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
  local context = claim_context(f)
  local token = {}
  -- The decisions this projection was built from; see `decision_stamp` and the
  -- re-ask inside the claim callback below.
  local decisions_at_projection = snapshot.decision_stamp(f)

  local started, start_err = apply_sessions.request_file_claim(context, change,
    function(ok, value, code, refusal, frozen)
      if not ok then
        apply_sessions.record_file_claim_refusal(change, code, refusal)
        finish(false, value, { phase = "claim", written = false })
        return
      end
      local live = claim_context(f)
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
      if snapshot.decision_stamp(f) ~= decisions_at_projection then
        apply_sessions.clear_file_claim_grant(change)
        finish(false,
          "a review decision changed while this End waited for the file claim; "
            .. "nothing was written -- end the turn again to apply every decision",
          { phase = "decision_drift", written = false })
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

--- Settle one Turn file at End or abort. A real-tree projection is
--- asynchronous because its file.claim is won at this write door, then consumed
--- immediately by the journaled applier. `done` is called once; a pending
--- return is not success.
function M.settle(f, done)
  return run(f, "exit", nil, done)
end

--- Ordinary own-file `:w`. Same steps, same order, same single projection
--- calculation and same journaled write door as `settle`; only the purpose and
--- the withheld buffer reconcile differ.
function M.save(f, request, done)
  return run(f, "save", request, done)
end

--- Remove the creation touches of files an Abort leaves UNDECIDED. An ACCEPTED
--- creation is a decision the Abort preserves.
---
--- BOTH questions are answered by the File, never by `change.before`. That
--- field is REBASED -- by an accepted write, and by an ordinary save -- so
--- `creation_touch.is_creation`, which reads it, silently changes its answer
--- under both. It hid two opposite defects: a non-empty accepted creation
--- survived only because its write had rebased it, while a zero-byte accepted
--- one was deleted, and a saved unaccepted empty creation was left behind.
--- `f.operation` is fixed from `change.kind` when the change is first seen and
--- never replaced; `f:accepted()` is the verdict. `is_creation` remains only as
--- the fallback for a turn entry that never became a File.
function M.reverse_turn_creations(files)
  local refused = {}
  for _, f in ipairs(files or {}) do
    local change = f.change
    local accepted = type(f.accepted) == "function" and f:accepted() == true
    local created_here = (f.operation == "create") or creation_touch.is_creation(change)
    if created_here and not accepted then
      local path = (type(change) == "table" and change.path) or f.path
      local ok, err = creation_touch.remove(path)
      if not ok then
        refused[#refused + 1] = { path = path, err = tostring(err) }
      else
        record_own_removal(f, path)
      end
    end
  end
  return refused
end

return M
