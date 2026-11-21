-- UndoActionDecision. Row
-- `{kind="decision", rel, workspace, turn_id, count}` -- the per-hunk
-- accept/reject replay, one file, buffer only, never disk.
--
-- Pure wrap: the bodies already exist as `pop_decision`
-- (review_undo_replay.lua:249) and `redo_local` (review_undo_replay.lua:117),
-- reachable off the resolved target as `target_state._pop_decision` /
-- `target_state._redo_local`. This module adds the `count`-loop of the old
-- switch and the row's own redo payload (`row.undone`, set by reverse).
--
-- `env` carries nothing this class needs: unlike its siblings it never calls
-- `resolve_target` itself (contract: "the only class that needs a resolved
-- target buffer before it can run" -- the ROUTER resolves it, per Four Laws
-- #2/#3, and hands it in as `target_state`, this pair's second argument).
local Factory = {}

function Factory.new(env) -- luacheck: no unused args
  -- Operation transitions carry the File identity themselves; a mode row
  -- (`record_mode_decision`) carries it on the Register row around `row.mode`.
  local function file_identity(transition, row)
    local source = transition
    if type(transition) == "table" and transition.file == nil and type(row) == "table" then
      source = row
    end
    local file = source and source.file
    if type(file) ~= "table"
      or not rawequal(file.change, source.change)
      or file.path ~= source.file_path
      or file.change_id ~= source.change_id
    then
      return nil, "decision no longer names the same File"
    end
    return file
  end

  local function proposal_is_current(file, proposal_key)
    if type(proposal_key) ~= "table" then
      return true
    end
    local current = require("yana.turn.turn_settle").change_proposal_key(file)
    return require("yana.turn.turn_file").same_proposal_key(proposal_key, current)
  end

  local function move_operation(transition, forward, row)
    if transition == nil then
      return true
    end
    local file, identity_err = file_identity(transition, row)
    if not file then
      return false, identity_err
    end
    local expected = forward and transition.previous or transition.next
    local verdict = forward and transition.next or transition.previous
    if file.operation_verdict ~= expected then
      return false, "operation verdict moved since this history row"
    end
    return file:decide_operation(verdict)
  end

  local function move_mode(transition, forward, row)
    if transition == nil then
      return true
    end
    local file, identity_err = file_identity(transition, row)
    if not file then
      return false, identity_err
    end
    if forward and not proposal_is_current(file, transition.proposal_key) then
      return false, "mode proposal changed since this history row"
    end
    local current = type(file.mode_verdict) == "table" and file.mode_verdict.verdict or "keep"
    local expected = forward and transition.previous or transition.next
    if current ~= expected then
      return false, "mode verdict moved since this history row"
    end

    local prior = not forward and transition.previous_record or nil
    local proposal_key = prior and prior.proposal_key or transition.proposal_key
    local verdict = forward and transition.next or (prior and prior.verdict or transition.previous)
    local policy = forward and transition.policy or (prior and prior.policy or transition.policy)
    local asked = forward and transition.asked or (prior and prior.asked or transition.asked)
    local ok, reason = file:decide_mode({
      proposal_key = proposal_key,
      previous = current,
      next = verdict,
      policy = policy,
      asked = asked,
    })
    if ok and not forward then
      -- Undo restores the exact record this row replaced, nil included.
      file.mode_verdict = prior
    end
    return ok, reason
  end

  local function move_verdicts(row, forward)
    local operations = row.operations or (row.operation and { row.operation } or {})
    local moved = {}
    for _, operation in ipairs(operations) do
      local ok, reason = move_operation(operation, forward, row)
      if not ok then
        for i = #moved, 1, -1 do move_operation(moved[i], not forward, row) end
        return false, reason
      end
      moved[#moved + 1] = operation
    end
    local ok, reason
    ok, reason = move_mode(row.mode, forward, row)
    if not ok then
      for i = #moved, 1, -1 do move_operation(moved[i], not forward, row) end
      return false, reason
    end
    return true
  end

  --- `count` x `target_state._pop_decision()`, stopping on the first result
  --- that is not `true` -- identical break rules to review_undo.lua's old
  --- `undo_key` loop, including the missing-method guard (a target resolved
  --- to something that never wired `_pop_decision`). The row keeps each entry
  --- it took back (`row.undone`), its redo payload. A refused first pop
  --- (`false`) takes nothing back: the verdicts return and the row refuses with
  --- the reason `pop_decision` announced, which `undo_refuse` keeps on the change.
  local function reverse(row, target_state, native_branch)
    local moved, why = move_verdicts(row, false)
    if moved ~= true then
      return false, why
    end
    local count = row.count or 1
    local undone = {}
    for _ = 1, count do
      if not target_state._pop_decision then
        break
      end
      local ok = target_state._pop_decision(native_branch)
      if ok == false and #undone == 0 then
        move_verdicts(row, true)
        local change = target_state.change
        return false, change and change.review_error or "the review refused to take it back"
      end
      if ok ~= true then
        break
      end
      local stack = target_state.undone_decisions
      undone[#undone + 1] = stack and stack[#stack]
    end
    row.undone = undone
    return true
  end

  --- `target_state._redo_local()` once per entry this row's undo took back,
  --- newest first. A redone publication installs its endpoint's empty undone
  --- stack, so the row puts its entry back there first (F-ADDENDUM-REDO), but
  --- only when this review's ledger owns the entry's hunk: a file the
  --- publication added rejoins as a new review, and the entry names the old
  --- one's hunk. A resumed review's rebound copies stay as they are. Nothing
  --- re-applied is a refusal with its reason, and takes back what it put there.
  local function forward(row, target_state, native_branch)
    local moved, why = move_verdicts(row, true)
    if moved ~= true then
      return false, why
    end
    local entries = row.undone or {}
    local ledger = target_state.hunk_ledger
    for i = #entries, 1, -1 do
      if not target_state._redo_local then
        break
      end
      local entry, stack = entries[i], target_state.undone_decisions
      local ok, reason, pushed
      if stack and #stack == 0 then
        if ledger and ledger:owns(entry.block) then
          stack[1], pushed = entry, true
        else
          ok, reason = false, tostring(row.rel) .. "'s review no longer has that hunk"
        end
      end
      if reason == nil then
        ok, reason = target_state._redo_local(native_branch)
      end
      if ok ~= true then
        if pushed and stack[#stack] == entry then
          table.remove(stack)
        end
        if i == #entries then
          move_verdicts(row, false)
          return false, reason
        end
        break
      end
    end
    return true
  end

  return { reverse = reverse, forward = forward }
end

return Factory
