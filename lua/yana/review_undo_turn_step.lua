-- Split out of `review_undo.lua` (same seam as `review_undo_replay`), which owns the
-- KEYS; this module owns what one `cA` ROW means going backwards (`u`) and forwards
-- (`<C-r>`).
--
-- Neither direction touches the register itself. Whether a press CONSUMES
-- the row is `redo_key`/`undo_key`'s decision in review_undo.lua, and
-- `redo` reports what actually happened by returning true only when every
-- file of the step was reselected.
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

  local function move_operation(entry, forward)
    local transition = entry and entry.operation
    if transition == nil then
      return true
    end
    local file = transition.file
    if type(file) ~= "table"
      or not rawequal(file.change, transition.change)
      or file.path ~= transition.file_path
      or file.change_id ~= transition.change_id
    then
      return false, "operation decision no longer names the same File"
    end
    local expected = forward and transition.previous or transition.next
    local verdict = forward and transition.next or transition.previous
    if file.operation_verdict ~= expected then
      return false, "operation verdict moved since cA"
    end
    return file:decide_operation(verdict)
  end

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
    --- `st.queue = {}` and requeued only files it refused before selection. The
    --- selected files' hunks come back pending under `u`, so their original queue
    --- items must come back too or neither navigation nor a second `cA` can reach them.
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

    --- The mirror of `requeue_undone`: a file whose verdicts redo reselected must
    --- leave the queue again, or queue advance reopens an already-resolved change.
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
        local operation_ok, operation_err = move_operation(row.active, false)
        if not operation_ok then
          undo_refuse(tostring(operation_err))
          return false
        end
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
      -- Memory only. The press this reverses moved no disk bytes, so its
      -- reverse changes only verdicts and queue membership.
      for _, entry in ipairs(row.files or {}) do
        local operation_ok, operation_err = move_operation(entry, false)
        if not operation_ok then
          undo_refuse(tostring(operation_err))
          return false
        end
        for _, block in ipairs(entry.blocks or {}) do
          if entry.ledger and entry.ledger:owns(block) and block.verdict ~= "pending" then
            entry.ledger:undo_decision(block)
          end
        end
        if type(entry.change) == "table" then
          entry.change.status = "pending"
          entry.change.review_error = nil
        end
        requeue_undone(entry)
        touched[#touched + 1] = entry.rel
      end
      -- B8: restore the exact permission record cA replaced (nil included).
      for _, mode_entry in ipairs(row.modes or {}) do
        local file, transition = mode_entry.file, mode_entry.mode
        if type(file) == "table" and type(transition) == "table"
          and rawequal(file.change, mode_entry.change)
          and type(file.mode_verdict) == "table" and file.mode_verdict.verdict == transition.next
        then
          file.mode_verdict = transition.previous_record
        end
      end
      local summary = string.format(
        "yana: took back cA's remaining-hunks step -- %d file(s) back to pending: %s",
        #touched,
        table.concat(touched, ", ")
      )
      log.write("WARN", summary)
      notify_one_line(summary, vim.log.levels.INFO)
      record_decision(state, "undo_accept_turn_step", { files_undone = #touched, files_refused = 0 })
      return true
    end

    --- Symmetric `<C-r>`: re-decide exactly the same hunks `cA` decided.
    --- This is memory-only like the `u` it mirrors; a step that moves no bytes
    --- needs no applier call or per-file claim gathering.
    local function apply_row(row)
      local touched = {}
      local refused = {}
      if row.active and row.active.rel then
        local operation_ok, operation_err = move_operation(row.active, true)
        if not operation_ok then
          refused[#refused + 1] = tostring(row.active.rel) .. ": " .. tostring(operation_err)
        end
        local target_state = resolve_target(row.active.rel)
        if operation_ok and target_state and target_state.hunk_ledger then
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
          refused[#refused + 1] = tostring(row.active.rel) .. ": could not reach it to reapply cA's own hunks"
        end
      end
      for _, entry in ipairs(row.files or {}) do
        local operation_ok, operation_err = move_operation(entry, true)
        if operation_ok then
          for _, block in ipairs(entry.blocks or {}) do
            if entry.ledger and entry.ledger:owns(block) and block.verdict == "pending" then
              entry.ledger:redo_decision(block, "accept")
            end
          end
          if type(entry.change) == "table" then
            entry.change.status = "accepted"
          end
          dequeue_redone(entry)
          touched[#touched + 1] = entry.rel
        else
          refused[#refused + 1] = tostring(entry.rel) .. ": " .. tostring(operation_err)
        end
      end
      -- B8: re-apply cA's unasked Keep records; never asks.
      for _, mode_entry in ipairs(row.modes or {}) do
        local file, transition = mode_entry.file, mode_entry.mode
        local mode_ok, mode_err = false, "permission record no longer names the same File"
        if type(file) == "table" and type(transition) == "table" and rawequal(file.change, mode_entry.change) then
          if rawequal(file.mode_verdict, transition.previous_record) then
            mode_ok, mode_err = require("yana.review_decisions").record_mode_decision(file, {
              proposal_key = transition.proposal_key,
              previous = transition.previous,
              next = transition.next,
              policy = transition.policy,
              asked = transition.asked,
            }, { history = false })
          else
            mode_err = "permission verdict moved since cA"
          end
        end
        if mode_ok ~= true then
          refused[#refused + 1] = tostring(mode_entry.file_path) .. ": " .. tostring(mode_err)
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

    --- `<C-r>` for one `cA` row. Always synchronous now that the step is
    --- memory-only; `opts.on_complete` remains part of the caller contract.
    local function redo_accept_turn_step(row, opts)
      local on_complete = type(opts) == "table" and opts.on_complete or nil
      local applied = apply_row(row)
      if on_complete then
        on_complete(applied)
      end
      return applied
    end

  return {
    undo = undo_accept_turn_step,
    redo = redo_accept_turn_step,
  }
end

return Factory
