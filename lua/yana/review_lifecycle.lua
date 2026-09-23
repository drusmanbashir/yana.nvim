-- Session settlement and the PUBLIC TEARDOWN FACADE for one inline review.
--
-- Teardown mechanics are NOT here. They live in `yana.review_resources`, which
-- owns the single buffer-owner table and is the only thing entitled to decide
-- whether this state may still touch a shared resource. This file used to carry
-- its own copy of that body, keyed on `state.bufnr` alone: it cleared the paint,
-- authority, anchor and hint namespaces and every `state.keys` entry on that
-- buffer with no currency or owner test at all, so a review closing after a
-- NEWER review had attached to the same buffer stripped the live one's marks and
-- maps. The two functions below are the whole of what remains: a name callers
-- already use, pointed at the owner.
local Factory = {}
local apply_sessions = require("yana.shadow.apply_sessions")
local hunk_ledger = require("yana.hunk_ledger")
-- The review leg owns the watcher and hands the applier its splice door.
local review_watch = require("yana.review_watch")

--- Terminal teardown of one review attachment. Idempotent, and safe to call on a
--- state that has already been superseded: `review_resources.close` releases the
--- state's own augroup either way and every SHARED resource only while this state
--- is still the recorded owner of its buffer.
---
--- Public on the module (not only on the facade table below) because the close
--- is a lifecycle door in its own right: the queue's abandon path, the preview
--- and the lifetime rows all reach it by name.
function Factory.cleanup(state)
  if not state then
    return
  end
  return require("yana.review_resources").close(state)
end

--- Park: navigation away from this review while it stays alive (R7).
---
--- NONTERMINAL. `review_resources.park` keeps the owner entry, the augroup and
--- therefore the save handlers, the ledger, the marks and the window
--- highlighting; it releases only the active watcher attachment, this review's
--- buffer-local keys and any preview tab. It never sets `state.closed`, so the
--- parked review is still the current owner of its buffer and still resumable.
function Factory.park_review(state)
  if not state then
    return
  end
  return require("yana.review_resources").park(state)
end

function Factory.new(deps)
  local M = deps.facade
  local change_ledger = deps.change_ledger
  local ledger = deps.ledger
  local staged_snapshot_unchanged = deps.staged_snapshot_unchanged
  local review_action_allowed = deps.review_action_allowed
  local diff = deps.diff
  local notify_owner = deps.notify_owner
  local buf_undo_seq = deps.buf_undo_seq
  local break_undo_block = deps.break_undo_block
  local live_block_range = deps.live_block_range
  local reject_restoration = deps.reject_restoration
  local park_decision_anchor = deps.park_decision_anchor
  local record_decision = deps.record_decision
  local notify_one_line = deps.notify_one_line
  local pool_for_state = deps.pool_for_state
  local announce_state = deps.announce_state
  local schedule_queue_advance = deps.schedule_queue_advance
  -- `deps.restore_review_winhl` / `deps.ns` / `deps.authority_ns` /
  -- `deps.anchor_ns` / `deps.hint_ns` are deliberately not read here any more.
  -- Window restoration and namespace clearing are `review_resources.close`'s,
  -- reached through the hooks the binder registered at claim time, so the actual
  -- namespace ids and the state-bound restore callback arrive with the claim
  -- instead of being rediscovered from this factory's construction deps.

  -- `restore_blocks` (reject path only) names the hunks whose lines this close must put
  -- back. It captures the list before its own decide loop and hands it in. Every other
  -- reject caller leaves this nil and the branch asks the ledger itself.
  local function finish_session_now(state, accepted, restore_blocks, bulk, defer_close)
    local change = state.change
    local bufnr = state.bufnr
    local turn_log = change_ledger(change, state.opts)
    ledger.mark(turn_log, "review_resolved")
    require("yana.log").lifecycle_later("review.settle", {
      turn_id = change.turn_id or change.turn_gen,
      generation = change.turn_gen,
      path = change.rel or change.path,
      accepted = accepted and true or false,
    })
  
    -- Vim appends a trailing newline after the final line, so a buffer read back
    -- verbatim gains an EOL the agent never wrote. Mirror the agent's own
    -- trailing-newline shape before the buffer is snapshotted or saved.
    --
    -- Declared here, not further down: the shadow_apply branch below returns
    -- before the legacy path and so never ran this, which made every shadow
    -- accept of a file without a trailing newline write one anyway — and turned
    -- an agent-created EMPTY file into a one-byte "\n" file.
    local function match_eol(snapshot)
      local wants_eol = (snapshot or ""):match("\n$") ~= nil
      vim.bo[bufnr].fixendofline = wants_eol
      vim.bo[bufnr].endofline = wants_eol
    end
  
    if state.opts.shadow_apply then
      -- Success is explicit only: unset or false means the requested action did
      -- not complete. No default true — a skipped branch or missing callback
      -- must not inherit success from an earlier operation.
      local ok = false
      local err = nil
      local applied = nil
      if accepted then
        -- Accept options carry this review's splice door to the applier's reconcile.
        local accept_opts = { staged_bufnr = bufnr, own_splice = review_watch.own_splice }
        if change.kind == "delete" then
          -- Same guard the legacy accept path below carries, and it was missing here: a
          -- deletion accept never reads the review buffer, so human text typed into it
          -- during the review would vanish with no trace. This branch returns before
          -- that guard is reached, and it snapshotted the buffer regardless of kind,
          -- which made shadow-apply a third unguarded discard site once E9 routed every
          -- turn through it. Refuse by name and keep both versions: their text in the
          if not staged_snapshot_unchanged(state) then
            ok, err = false, "buffer holds edits that accepting this deletion would discard"
          else
            local allowed, why = review_action_allowed(state, change)
            if not allowed then
              ok, err = false, why
            elseif not state.opts.on_shadow_accept then
              ok, err = false, "shadow accept handler missing"
            else
              -- No composed content for a deletion: the applier unlinks, and
              -- passing buffer bytes here is what let an empty file be written in
              -- place of the delete.
              local aok, aerr, aapplied = state.opts.on_shadow_accept(change, nil, accept_opts)
              ok = aok == true
              err = aerr
              applied = aapplied
            end
          end
        else
          match_eol(change.after)
          local composed, cerr = diff.buffer_bytes_snapshot(bufnr)
          if composed == nil then
            ok, err = false, cerr
          else
            local allowed, why = review_action_allowed(state, change)
            if not allowed then
              ok, err = false, why
            elseif not state.opts.on_shadow_accept then
              ok, err = false, "shadow accept handler missing"
            else
              -- The Turn settler (F8) takes the SAME on_shadow_accept door for
              -- creations so apply_accept's write + save_buffer stamp stay the one
              -- implementation.
              local aok, aerr, aapplied = state.opts.on_shadow_accept(change, composed, accept_opts)
              ok = aok == true
              err = aerr
              applied = aapplied
            end
          end
        end
        if ok then
          change.status = "accepted"
          if type(applied) == "table" and applied.kind == "transfer" then
            vim.bo[bufnr].modified = true
            change._accept_regime = "transfer"
            change._accept_bufnr = applied.bufnr
            change._accept_composed_hash = applied.composed_hash
            ledger.mark(turn_log, "accept_transferred")
          else
            change._accept_regime = "durable"
            ledger.mark(turn_log, "accept_applied")
          end
          -- Durable outcome is decided by the applier alone. A throwing on_accept
          -- is a presentation problem only: report it, never flip status back to
          -- pending or treat the accept as refused after bytes are on disk.
          notify_owner(state.opts.on_accept, change, "on_accept")
        end
      else
        ok = true
        -- Reject restores THE AGENT'S LINES ONLY, hunk by hunk, through the same
        -- authority extmarks per-hunk reject reads (live_block_range).
        --
        -- `pending()` is the exact set the derived mirror held here -- it was refreshed
        -- after every ledger mutation. Never `all()`: a hunk already accepted keeps its
        -- bytes, and one already rejected had its lines put back by its own door.
        local blocks = restore_blocks
          or (state.hunk_ledger and state.hunk_ledger:pending())
          or {}
        -- Last hunk first: each range is resolved immediately before its own
        -- replacement, so a line-count change in one hunk cannot shift a range already
        -- read for another.
        for i = #blocks, 1, -1 do
          local block = blocks[i]
          local start_line, end_line, range_err = live_block_range(bufnr, block)
          if start_line then
            local restored = reject_restoration(bufnr, block, start_line, end_line)
            if not bulk then
              break_undo_block(bufnr)
            end
            local pre_seq = buf_undo_seq(bufnr)
            local replaced = (end_line >= start_line) and (end_line - start_line + 1) or 0
            -- THROUGH THE WATCHER'S OWN DOOR. This restoration is Yana putting
            -- the original side back, and a bare `set_lines` reaches the watch
            -- timeline as an unexplained change: the InsertLeave seal then finds
            -- captured bytes that do not match the live buffer and refuses the
            -- close, leaving the Turn live. `own_splice` mutes interpretation
            -- only -- the ledger still transports this geometry exactly once.
            local restore_ok, restore_err = pcall(function()
              return review_watch.own_splice(bufnr, function()
                vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, restored)
              end)
            end)
            if not bulk then
              break_undo_block(bufnr)
            end
            if not restore_ok then
              ok = false
              err = tostring(restore_err)
            else
              local delta = #restored - replaced
              local anchor = park_decision_anchor(
                bufnr,
                start_line,
                start_line + math.max(#restored, 1) - 1
              )
              state.decisions[#state.decisions + 1] = {
                action = "reject",
                idx = i,
                block = block,
                delta = delta,
                pre_seq = pre_seq,
                post_seq = buf_undo_seq(bufnr),
                anchor = anchor,
              }
              hunk_ledger.scrub_paint(block) -- A2: the same one scrub
              record_decision(state, "reject_hunk", {
                hunk = i,
                model_index = block.model_index,
                model_join = block.model_join,
                row = start_line,
                old_count = #(block.old_lines or {}),
                new_count = #(block.new_lines or {}),
                source = "bulk_reject",
              })
            end
          else
            -- Say so rather than falling back to the whole-buffer snapshot: that
            -- fallback is the defect above.
            ok = false
            err = range_err or "hunk invalidated"
            notify_one_line(
              "yana: reject left one hunk in place -- " .. tostring(range_err or "hunk invalidated"),
              vim.log.levels.WARN
            )
          end
        end
        if ok then
          -- Truthful modified flag: after a reject the buffer holds the human's text,
          -- and the file may already hold something else (a bare `:w` during the review
          -- persists the live composition). Clean only when buffer and file actually
          -- agree.
          M._recompute_modified(bufnr, blocks, change.path)
          change.status = "rejected"
          if bulk then
            pcall(function()
              require("yana.turn.turn_register"):push({
                kind = "decision",
                rel = change.rel or change.path,
                workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd(),
                turn_id = change.turn_id or change.turn_gen,
                count = #blocks,
              })
            end)
          end
          -- Reject completed once the buffer is restored. on_reject failure is
          -- presentation only — same rule as accept: do not undo a durable action.
          notify_owner(state.opts.on_reject, change, "on_reject")
        end
      end
      if not ok then
        change.review_error = tostring(err or (accepted and "accept failed" or "reject failed"))
        if accepted then
          -- Everything above `err` is a prose string by the time it reaches here, so
          -- the reason CLASS and the fingerprint pair the binding schema delta requires
          -- were both lost on the path that actually ships.
          --
          -- The evidence exists: safety/diary.apply_operation returns it as a third
          -- value, apply_pending tail-returns all three, and shadow/apply's
          -- accept_composed parks it on `change.shadow_refusal` -- the change being
          -- the one object the applier and this recording site both already hold.
          -- accept_composed clears it at entry, so what lands here was gathered by
          -- THIS attempt.
          --
          -- Merged into the record just written, not recorded separately: a drift
          -- refusal is one decision with more said about it, and two rows would
          -- double-count refusals in every report. ledger.attach_refusal copies only
          -- the allowlisted schema fields onto the last `review_refused` decision, so
          -- the applier cannot rewrite actor, identity or timestamps, and it is total:
          -- a nil detail (any non-drift failure) leaves the record exactly as it was
          if M._record_shadow_accept_refusal(state, err) then
            return false
          end
        else
          notify_one_line(
            "yana: reject failed for " .. (change.rel or change.path) .. ": " .. tostring(err),
            vim.log.levels.ERROR
          )
        end
      end
      if defer_close and not accepted then
        -- The RESTORE and the RECORD (one reversal entry per hunk plus the ONE
        -- file-level reject register row above) are done; the CLOSE is the
        -- caller's to defer. `cx` hands it to the bound Turn, which parks and
        -- advances or ends this review and owns its teardown -- the same division
        -- of labour the per-hunk `reject_block_at` door already keeps, restoring
        -- and recording itself and leaving the close to the Turn's leave edge. A
        -- second teardown here would blank `st.active` out from under the file the
        -- Turn just advanced to.
        return ok == true
      end
      if state.opts.on_close then
        notify_owner(function()
          state.opts.on_close(state, accepted)
        end, change, "on_close")
      end
      M.cleanup(state)
      local st = pool_for_state(state)
      st.active = nil
      if accepted and ok and applied and applied.reconcile_error then
        -- shadow/apply.lua has already brought this buffer back in step with the
        -- file it wrote, or named why it would not. Surface the refusal; do NOT
        -- downgrade the status, because the write HAPPENED and is journaled and
        -- only the buffer is out of step.
        notify_one_line(
          "yana: applied " .. (change.rel or change.path) .. " but could not reconcile its buffer: "
            .. tostring(applied.reconcile_error),
          vim.log.levels.WARN
        )
      end
      announce_state()
      if ok then
        -- `perform_whole_review_abort` sets `_abort_no_retrace` just before its own
        -- `finish_session(state, false)` call -- the ONLY caller that does -- so an
        -- abort is named `"abort"`, not `"reject_file"`, even though it reaches this
        -- exact same tail.
        M._emit_review_settled(
          bufnr,
          change.turn_id or change.turn_gen,
          state._abort_no_retrace and "abort" or (change.status == "accepted" and "accept_file" or "reject_file")
        )
      end
      schedule_queue_advance(state)
      return ok == true
    end
    if state.opts.preview then
      change.status = "rejected"
      -- Same contract as the accept/reject handlers below: a throwing owner callback
      -- must not skip teardown.
      if state.opts.on_close then
        notify_owner(function()
          state.opts.on_close(state, accepted)
        end, change, "on_close")
      end
      M.cleanup(state)
      local st = pool_for_state(state)
      st.active = nil
      announce_state()
      M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "reject_file")
      schedule_queue_advance(state)
      -- Return contract: true only when the requested action completed. Preview
      -- never applies bytes, so an accept request closes without applying.
      return not accepted
    end
    -- Real-tree writes route only through shadow_apply + on_shadow_accept (the
    -- journaled applier).
    change.review_error = "review reached the removed legacy accept path — shadow_apply was not configured"
    change.status = "pending"
    notify_one_line(
      "yana: refused to accept " .. (change.rel or change.path) .. " — legacy direct-write path is removed",
      vim.log.levels.ERROR
    )
    M.cleanup(state)
    local st = pool_for_state(state)
    st.active = nil
    announce_state()
    schedule_queue_advance(state)
    return false
  end
  
  local function claim_owner_snapshot(state)
    local opts = state.opts or {}
    local turn_pass = opts.turn_pass
    local review_turn = opts.review_turn
    local owner = opts.review_owner or {}
    return {
      pool = pool_for_state(state),
      change = state.change,
      turn_pass = turn_pass,
      review_turn = review_turn,
      panel_id = owner.panel_id,
      epoch = owner.epoch,
      -- The SESSION is part of who asked. Without it a session change while the
      -- claim was in flight left the stale-callback check silent.
      yanad_session_id = opts.yanad_session_id,
      session_id = opts.session_id,
      turn_id = state.change and (state.change.turn_id or state.change.turn_gen),
      generation = state.change and state.change.turn_gen,
      bundle_digest = turn_pass and turn_pass.bundle and turn_pass.bundle.bundle_digest or nil,
    }
  end

  local function claim_owner_is_current(state, token, owner)
    if state._yanad_claim_pending ~= token or owner.pool.active ~= state or state.change ~= owner.change then
      return false
    end
    local now = claim_owner_snapshot(state)
    return now.pool == owner.pool
      and now.yanad_session_id == owner.yanad_session_id
      and now.session_id == owner.session_id
      and now.turn_pass == owner.turn_pass
      and now.review_turn == owner.review_turn
      and now.panel_id == owner.panel_id
      and now.epoch == owner.epoch
      and now.turn_id == owner.turn_id
      and now.generation == owner.generation
      and now.bundle_digest == owner.bundle_digest
  end

  --- Accepted settlement pauses for yanad file.claim, then revalidates the
  --- owning review before entering the unchanged synchronous applier.
  local function finish_session(state, accepted, restore_blocks, bulk, defer_close)
    -- `apply_claims.request_file_claim` needs a real workspace (`root`, which falls
    -- back to `state.opts.workspace` when `change.root` is unset) AND a non-empty
    -- `change.rel` -- and unlike root, rel has no fallback of its own. That is not
    -- arbitration, it is a caller this gate cannot address, the same way an empty
    -- touched set takes no claim row.
    local claimable = state.opts
      and type(state.opts.workspace) == "string"
      and state.opts.workspace ~= ""
      and state.change
      and type(state.change.rel) == "string"
      and state.change.rel ~= ""
    -- PREVIEW IS NOT EXEMPT. A preview-mode accept is still a real-tree write:
    -- it routes through `shadow_apply.accept_standalone`, which asks the very
    -- same `file_claim_refusal`. Skipping the pre-grant here is what left that
    -- door to ask the daemon from inside the synchronous applier, and the
    -- applier could only ask by blocking the editor for the claim's whole 7.5s
    -- budget. The claim is requested HERE, asynchronously, for both regimes;
    -- `shadow_apply` (set by `ui_review.lua` whenever the panel is journaled)
    -- is the one gate that separates a real-tree accept from an overlay one.
    if not accepted or not (state.opts and state.opts.shadow_apply) or not claimable then
      return finish_session_now(state, accepted, restore_blocks, bulk, defer_close)
    end
    local token = {}
    local owner = claim_owner_snapshot(state)
    local context = {
      review_turn = state.opts.review_turn,
      turn_id = owner.turn_id,
      yanad_session_id = state.opts.yanad_session_id,
      session_id = state.opts.session_id,
      workspace = state.opts.workspace,
    }
    -- A GRANT ALREADY IN HAND IS SERVED ONLY IF IT IS THIS ATTEMPT'S.
    -- `claim_grant_matches` recomputes root, rel, absolute path, session and
    -- turn from the context above and compares them to what the grant froze. A
    -- leftover from an aborted bulk press names a different attempt and is
    -- refused here, so this door asks the daemon rather than treating another
    -- press's authority as its own.
    if state.change and apply_sessions.claim_grant_matches(context, state.change) then
      local grant = state.change._yanad_claim_granted
      -- Forward the caller's OWN arguments. The claim pre-grant is a pause, not a
      -- different settlement: a preview accept now takes this route too, and it
      -- carries `restore_blocks`/`bulk`/`defer_close` that dropping would silently
      -- change what the settle does.
      local settled = finish_session_now(state, accepted, restore_blocks, bulk, defer_close)
      if state.change._yanad_claim_granted == grant then
        state.change._yanad_claim_granted = nil
      end
      return settled
    end
    if state._yanad_claim_pending ~= nil then
      return true
    end

    state._yanad_claim_pending = token
    local started, start_err = apply_sessions.request_file_claim(context, state.change, function(ok, value, code, refusal, frozen)
      if not claim_owner_is_current(state, token, owner) then
        local now = claim_owner_snapshot(state)
        require("yana.log").write(
          "WARN",
          string.format(
            "yana.review_lifecycle: stale file.claim callback ignored (expected token=%s panel=%s epoch=%s turn=%s generation=%s bundle=%s; current token=%s panel=%s epoch=%s turn=%s generation=%s bundle=%s)",
            tostring(token),
            tostring(owner.panel_id),
            tostring(owner.epoch),
            tostring(owner.turn_id),
            tostring(owner.generation),
            tostring(owner.bundle_digest),
            tostring(state._yanad_claim_pending),
            tostring(now.panel_id),
            tostring(now.epoch),
            tostring(now.turn_id),
            tostring(now.generation),
            tostring(now.bundle_digest)
          )
        )
        return
      end
      state._yanad_claim_pending = nil
      if not ok then
        apply_sessions.record_file_claim_refusal(state.change, code, refusal)
        local restored = M._record_shadow_accept_refusal(state, value)
        if not restored then
          finish_session_now(state, false, restore_blocks, bulk, defer_close)
        end
        return
      end
      -- The grant is the record FROZEN BEFORE THE REQUEST WENT OUT, not a fresh
      -- read of `state.change`: the change may have been retargeted while the
      -- daemon was answering. A daemon that claimed a different path grants
      -- nothing, and this attempt settles as a refusal.
      -- The LIVE door context is rebuilt here, not reused from before the
      -- request, so the grant is checked against the session and turn that are
      -- current at the moment it would be stored.
      local live = {
        review_turn = state.opts.review_turn,
        turn_id = state.change and (state.change.turn_id or state.change.turn_gen),
        yanad_session_id = state.opts.yanad_session_id,
        session_id = state.opts.session_id,
        workspace = state.opts.workspace,
      }
      -- An EXPLICIT false is the refusal. The real `grant_file_claim` always
      -- answers with a boolean; keying on `false` rather than falsiness keeps a
      -- door fake that answers nothing from being read as a refusal.
      if apply_sessions.grant_file_claim(state.change, token, value, frozen or context, live) == false then
        local restored = M._record_shadow_accept_refusal(
          state,
          "refusing to accept " .. tostring(state.change and state.change.path) .. ": the yanad file.claim answer does not name this file"
        )
        if not restored then
          finish_session_now(state, false, restore_blocks, bulk, defer_close)
        end
        return
      end
      local granted = state.change._yanad_claim_granted
      finish_session_now(state, true, restore_blocks, bulk, defer_close)
      if state.change._yanad_claim_granted == granted then
        apply_sessions.clear_file_claim_grant(state.change)
      end
    end)
    if not started then
      state._yanad_claim_pending = nil
      apply_sessions.record_file_claim_refusal(state.change, "claim_unavailable", nil)
      local restored = M._record_shadow_accept_refusal(state, start_err)
      if not restored then
        finish_session_now(state, false, restore_blocks, bulk, defer_close)
      end
      return false
    end
    return true
  end

  -- One implementation, one name. Every existing caller reaches the close
  -- through the facade table (`review_queue`'s abandon path, `review_api`'s two
  -- discard doors, `review_open_bind`'s failure door, `diff_preview`'s preview
  -- teardown and `finish_session_now`'s three tails below), so the facade field
  -- is pointed at the module function rather than given a body of its own.
  M.cleanup = Factory.cleanup
  M.park_review = Factory.park_review

  -- The review buffer exists but focus_buf could not display it in any window, so its
  -- buffer-local keymaps are unreachable and the queue would stall forever waiting on a
  -- review the user can never resolve. Unlike finish_session, this must NOT write disk:
  -- `after` is already there and has to stay there. Status is left "pending" (not
  -- "rejected"/"accepted") so the panel keeps flagging it as unresolved, and the queue
  -- is allowed to drain past it.
  return {
    finish_session = finish_session,
    cleanup = M.cleanup,
  }
end

return Factory
