-- Split out of `review_undo.lua` (same seam as `review_undo_replay`), which owns the
-- KEYS; this module owns what one `cA` ROW means going backwards (`u`) and forwards
-- (`<C-r>`).
--
-- Neither direction touches the register itself. Whether a press CONSUMES
-- the row is `redo_key`/`undo_key`'s decision in review_undo.lua, and
-- `redo` reports what actually happened by returning true only when EVERY
-- file of the step was reapplied.
local Factory = {}

--- `env` carries the review-local closures both directions need:
--- `deps` (the review factory's own deps: `pool_for`,
--- `queue_insert_original`, `queue_remove_change`), `facade` (the
--- inline-diff module table, for `_recompute_modified`), `state`, `log`,
--- `notify_one_line`, `record_decision`, `undo_refuse` and
--- `resolve_target`.
function Factory.new(env)
  local deps = env.deps
  local M = env.facade
  local state = env.state
  local log = env.log
  local notify_one_line = env.notify_one_line
  local record_decision = env.record_decision
  local undo_refuse = env.undo_refuse
  local resolve_target = env.resolve_target

    --- Taking it back means setting exactly those hunks back to pending -- nothing
    --- else. `Ledger:undo_decision` is used per hunk rather than `take_back_last_batch`
    --- because `last_batch` is clobbered by any later individual `decide()` on the same
    --- ledger (accept_block_at / reject_block_at both set it); a captured block LIST
    --- survives that. The pool this review belongs to, or nil under a bare unit-test
    --- double with no pool wiring (same degrade-quietly contract `pool_for_walk` above
    local function undo_pool()
      if type(deps.pool_for) ~= "function" then
        return nil
      end
      local ok, st = pcall(deps.pool_for, state.opts or {})
      if ok and type(st) == "table" and type(st.queue) == "table" then
        return st
      end
      return nil
    end

    --- Put a file `cA` swallowed back in the queue slot it came out of. `cA` did
    --- `st.queue = {}` (review_bulk.lua) and requeued only the files it REFUSED; the
    --- ones it accepted left the queue for good. Their hunks come back pending under
    --- `u`, and the Turn goes on counting them (`Turn:pending_count` derives from the
    --- member ledgers), but nothing can open them any more: `jump_to_rel` above
    --- searches `pool.queue`, and a second `cA` drains an empty one.
    ---
    --- It is idempotent (it removes any existing entry for the change first), so a
    --- retrace that later opens the file directly cannot leave a duplicate.
    local function requeue_undone(entry)
      local st = undo_pool()
      local insert = deps.queue_insert_original
      if not st or type(insert) ~= "function" or type(entry.item) ~= "table" then
        return false
      end
      if st.active and st.active.change == entry.change then
        return false
      end
      insert(st, entry.item)
      return true
    end

    --- The mirror of `requeue_undone` for `<C-r>`: a file the redo has just
    --- re-accepted must LEAVE the queue again, or `finish_session`'s
    --- `schedule_queue_advance` pops a stale entry and reopens an
    --- already-resolved change from scratch (review_navigate.lua documents
    --- that exact resurrection).
    local function dequeue_redone(entry)
      local st = undo_pool()
      local remove = deps.queue_remove_change
      if not st or type(remove) ~= "function" then
        return
      end
      remove(st, entry.change)
    end

    local function undo_accept_turn_step(row)
      local touched = {}
      if row.active and row.active.rel then
        local target_state = resolve_target(row.active.rel)
        if target_state and target_state.hunk_ledger then
          for _, block in ipairs(row.active.blocks or {}) do
            if target_state.hunk_ledger:owns(block) and block.verdict ~= "pending" then
              target_state.hunk_ledger:undo_decision(block)
            end
          end
          target_state.hunk_ledger:request_paint()
          if target_state._flush_paint then
            target_state._flush_paint("accept_turn_step_undo")
          end
          if M._recompute_modified and target_state.bufnr then
            M._recompute_modified(target_state.bufnr, target_state.hunk_ledger:pending(), target_state.change.path)
          end
          touched[#touched + 1] = row.active.rel
        else
          undo_refuse("could not reach " .. tostring(row.active.rel) .. " to take back cA's own hunks")
        end
      end
      local refused = {}
      for _, entry in ipairs(row.files or {}) do
        -- * `cA` ABSORBED an operator edit here (`pre_press_bytes` set by
        -- review_bulk.lua from `materialize`'s `absorbed_from`): those absorbed bytes
        -- ARE the pre-press disk state. Restoring turn-start instead would delete an
        -- edit the operator made themselves, before the press, which was never part of
        -- the step being taken back. * Nothing was absorbed: no one touched the file
        -- between turn start and the press, so `change.before` IS the pre-press disk
        local ok, err = true, nil
        if entry.pre_press_bytes ~= nil and entry.opts and entry.opts.on_shadow_revert_bytes then
          ok, err = entry.opts.on_shadow_revert_bytes(entry.change, entry.pre_press_bytes)
        elseif entry.pre_press_bytes == nil and entry.opts and entry.opts.on_shadow_revert then
          ok, err = entry.opts.on_shadow_revert(entry.change)
        else
          ok, err = false, "no journaled revert available for this review"
        end
        if ok == true then
          for _, block in ipairs(entry.blocks or {}) do
            if entry.ledger and entry.ledger:owns(block) and block.verdict ~= "pending" then
              entry.ledger:undo_decision(block)
            end
          end
          entry.change.status = "pending"
          entry.change.review_error = nil
          entry.change._accept_regime = nil
          entry.change._accept_bufnr = nil
          entry.change._accept_composed_hash = nil
          requeue_undone(entry)
          touched[#touched + 1] = entry.rel
        else
          refused[#refused + 1] = tostring(entry.rel) .. ": " .. tostring(err)
        end
      end
      local summary = string.format(
        "yana: took back cA's remaining-hunks step -- %d file(s) back to pending: %s",
        #touched,
        table.concat(touched, ", ")
      )
      log.write("WARN", summary)
      notify_one_line(summary, vim.log.levels.INFO)
      if #refused > 0 then
        local rmsg = "yana: could NOT take cA back for " .. #refused .. " file(s): " .. table.concat(refused, "; ")
        log.write("WARN", rmsg)
        notify_one_line(rmsg, vim.log.levels.WARN)
      end
      record_decision(state, "undo_accept_turn_step", { files_undone = #touched, files_refused = #refused })
      return true
    end

    --- Symmetric `<C-r>`: re-decide exactly the same hunks `cA` decided,
    --- replaying the identical `on_shadow_accept` call (with the SAME
    --- composed bytes) for a file that has no open review buffer.
    ---
    --- RETURNS true only when EVERY file of the step was reapplied. A row consumed for
    --- a step that was never reapplied is therefore a row the next `u` walks back over
    --- whatever a third party has since written there -- silently, since the revert
    --- cannot tell it apart from its own bytes. PARTIAL success counts as refusal here
    --- for exactly that reason: one file left un-reapplied is one file `u` must not be
    --- handed.
    ---
    --- What a refused redo should otherwise DO (retry the whole row later?
    --- refuse before writing anything? offer the operator the drifted file?)
    --- is NOT decided here and NOT YET RULED. This function's behaviour on
    --- the files it
    --- CAN reapply is unchanged; only the report to the caller is new.
    --- Every file of a `cA` row needs a yanad `file.claim` BEFORE the write loop
    --- starts. Collecting them first is what keeps `<C-r>`'s all-or-nothing redo
    --- intact: a claim refused halfway through the loop would leave some files
    --- reapplied and some not, and what a partial redo means is NOT YET RULED.
    --- Asking per file inside the
    --- loop is also what made a three-file replay block the editor for 22643ms --
    --- three synchronous 7.5s claim budgets back to back, one per file.
    ---
    --- So the row arms itself: the first press starts every claim asynchronously
    --- and reapplies nothing, and the press after the grants land runs the
    --- unchanged synchronous loop with every claim already in hand. A refused row
    --- is never consumed by the press (review_undo.lua consumes on the OUTCOME),
    --- so the row is still there to press again.
    local function claim_context_for(entry)
      local opts = entry.opts or {}
      local ws = opts.workspace
      if type(ws) ~= "string" or ws == "" then
        ws = state.opts and state.opts.workspace or nil
      end
      return {
        review_turn = opts.review_turn,
        turn_id = entry.change and (entry.change.turn_id or entry.change.turn_gen),
        yanad_session_id = opts.yanad_session_id,
        session_id = opts.session_id,
        workspace = ws,
      }
    end

    --- A file this row can even take a claim row for. `request_file_claim` needs a
    --- real root AND a non-empty `rel`, and rel has no fallback of its own -- the
    --- same gate `review_lifecycle.finish_session` applies. An entry that cannot be
    --- claimed is left to the applier's own fail-closed answer rather than being
    --- silently allowed here.
    local function apply_sessions_mod()
      return require("yana.shadow.apply_sessions")
    end

    local function entry_is_claimable(entry)
      return type(entry) == "table"
        and type(entry.opts) == "table"
        and entry.opts.on_shadow_accept ~= nil
        and type(entry.change) == "table"
        and type(entry.change.rel) == "string"
        and entry.change.rel ~= ""
    end

    --- Start every outstanding claim for `row`, or report why the loop may run now.
    --- Returns true when the write loop may proceed (every claimable file already
    --- holds a grant), false when the row is waiting on the daemon.
    local function gather_row_claims(row, on_ready)
      if row._yanad_claim_pending ~= nil then
        notify_one_line(
          "yana: cA redo is still waiting for its file claims -- press <C-r> again when they land",
          vim.log.levels.WARN
        )
        return false
      end
      local wanted = {}
      for _, entry in ipairs(row.files or {}) do
        -- A grant already on this change counts ONLY when it names this row's
        -- own attempt -- same root, rel, absolute path, session and turn. A
        -- leftover from an aborted bulk press names another attempt, so this
        -- file is claimed again rather than written on that press's authority.
        if entry_is_claimable(entry)
          and not apply_sessions_mod().claim_grant_matches(claim_context_for(entry), entry.change)
        then
          apply_sessions_mod().clear_file_claim_grant(entry.change)
          wanted[#wanted + 1] = entry
        end
      end
      if #wanted == 0 then
        return true
      end

      local apply_sessions = require("yana.shadow.apply_sessions")
      local token = {}
      row._yanad_claim_pending = token
      local outstanding = #wanted
      local refused = {}

      --- Exactly one completion per ATTEMPT. `token` is this attempt's identity;
      --- a callback from an abandoned attempt is already dropped by the token
      --- check in `settle_one`, and `fired` additionally makes a completion
      --- unrepeatable even if the same attempt reported twice.
      local fired = false
      local function finish(ready)
        if fired then
          return
        end
        fired = true
        if type(on_ready) == "function" then
          on_ready(ready)
        end
      end

      --- The row that asked must still be the row that answers, and each grant is
      --- consumed once (the applier clears `_yanad_claim_granted` as it reads it).
      local function settle_one(entry, ok, value, code, refusal, frozen)
        if row._yanad_claim_pending ~= token then
          log.write(
            "WARN",
            string.format(
              "yana.review_undo_turn_step: stale cA file.claim callback ignored for %s (expected token=%s, current=%s)",
              tostring(entry.rel),
              tostring(token),
              tostring(row._yanad_claim_pending)
            )
          )
          return
        end
        if ok and apply_sessions.grant_file_claim(
          entry.change,
          token,
          value,
          frozen or claim_context_for(entry),
          claim_context_for(entry)
        ) ~= false then
          -- granted against the record frozen before this file's request went out
        elseif ok then
          apply_sessions.record_file_claim_refusal(entry.change, "claim_path_mismatch", nil)
          refused[#refused + 1] = tostring(entry.rel) .. ": the yanad file.claim answer does not name this file"
        else
          apply_sessions.record_file_claim_refusal(entry.change, code, refusal)
          refused[#refused + 1] = tostring(entry.rel) .. ": " .. tostring(value or code)
        end
        outstanding = outstanding - 1
        if outstanding > 0 then
          return
        end
        row._yanad_claim_pending = nil
        if #refused > 0 then
          notify_one_line(
            "yana: could NOT claim " .. #refused .. " file(s) for cA redo: " .. table.concat(refused, "; "),
            vim.log.levels.WARN
          )
          finish(false)
          return
        end
        -- Every claim of THIS attempt is in hand, so the same press continues
        -- into the unchanged, all-or-nothing write loop. The row is not
        -- re-armed and the operator does not press again.
        finish(true)
      end

      for _, entry in ipairs(wanted) do
        local started, start_err = apply_sessions.request_file_claim(claim_context_for(entry), entry.change, function(ok, value, code, refusal, frozen)
          settle_one(entry, ok, value, code, refusal, frozen)
        end)
        if not started then
          settle_one(entry, false, start_err, "claim_unavailable", nil)
        end
      end
      return false
    end

    --- The write loop proper. Never entered until every claimable file of the
    --- row holds its grant, which is what keeps `<C-r>` all-or-nothing.
    local function apply_row(row)
      local touched = {}
      local refused = {}
      if row.active and row.active.rel then
        local target_state = resolve_target(row.active.rel)
        if target_state and target_state.hunk_ledger then
          for _, block in ipairs(row.active.blocks or {}) do
            if target_state.hunk_ledger:owns(block) and block.verdict == "pending" then
              target_state.hunk_ledger:redo_decision(block, "accept")
            end
          end
          target_state.hunk_ledger:request_paint()
          if target_state._flush_paint then
            target_state._flush_paint("accept_turn_step_redo")
          end
          touched[#touched + 1] = row.active.rel
        else
          -- Same shape as `undo_accept_turn_step`'s own unreachable-active
          -- branch: the file under the cursor when `cA` was pressed is part
          -- of the step, so a step that cannot reach it was not reapplied.
          refused[#refused + 1] = tostring(row.active.rel) .. ": could not reach it to reapply cA's own hunks"
        end
      end
      for _, entry in ipairs(row.files or {}) do
        if entry.opts and entry.opts.on_shadow_accept then
          local ok, err = entry.opts.on_shadow_accept(entry.change, entry.composed, entry.accept_opts)
          if ok == true then
            for _, block in ipairs(entry.blocks or {}) do
              if entry.ledger and entry.ledger:owns(block) and block.verdict == "pending" then
                entry.ledger:redo_decision(block, "accept")
              end
            end
            entry.change.status = "accepted"
            dequeue_redone(entry)
            touched[#touched + 1] = entry.rel
          else
            refused[#refused + 1] = tostring(entry.rel) .. ": " .. tostring(err)
          end
        else
          -- No journaled accept to replay -- the mirror of the revert side's
          -- "no journaled revert available for this review". Not reapplied,
          -- so not silently skipped either.
          refused[#refused + 1] = tostring(entry.rel) .. ": no journaled accept available for this review"
        end
      end
      notify_one_line(
        string.format("yana: reapplied cA's remaining-hunks step -- %d file(s)", #touched),
        vim.log.levels.INFO
      )
      if #refused > 0 then
        notify_one_line(
          "yana: could NOT reapply cA for " .. #refused .. " file(s): " .. table.concat(refused, "; "),
          vim.log.levels.WARN
        )
      end
      return #refused == 0
    end

    --- `<C-r>` for one `cA` row.
    ---
    --- Returns `true`/`false` when the answer is known synchronously (every
    --- claim already in hand), and the string `"pending"` when the daemon was
    --- asked for claims: in that case `opts.on_complete(applied)` is called
    --- exactly once, from the claim completion, with the same boolean the
    --- synchronous return would have carried. review_undo.lua consumes the
    --- register row on that boolean either way, so a single press applies and
    --- a refusal still keeps its row.
    local function redo_accept_turn_step(row, opts)
      local on_complete = type(opts) == "table" and opts.on_complete or nil
      local ready_now = gather_row_claims(row, function(ready)
        if not ready then
          if on_complete then
            on_complete(false)
          end
          return
        end
        local applied = apply_row(row)
        if on_complete then
          on_complete(applied)
        end
      end)
      if not ready_now then
        return "pending"
      end
      return apply_row(row)
    end

  return {
    undo = undo_accept_turn_step,
    redo = redo_accept_turn_step,
  }
end

return Factory
