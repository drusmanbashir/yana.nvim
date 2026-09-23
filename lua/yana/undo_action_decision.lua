-- UndoActionDecision. Row
-- `{kind="decision", rel, workspace, turn_id, count}` -- the per-hunk
-- accept/reject replay, one file, buffer only, never disk.
--
-- Pure wrap: the bodies already exist as `pop_decision`
-- (review_undo_replay.lua:249) and `redo_local` (review_undo_replay.lua:117),
-- reachable off the resolved target as `target_state._pop_decision` /
-- `target_state._redo_local`. This module adds no logic of its own besides
-- the `count`-loop lifted verbatim from the old switch
-- (review_undo.lua:442-453 for reverse, :369-380 for forward).
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
    local ok, reason = move_operation(row.operation, forward, row)
    if not ok then
      return false, reason
    end
    ok, reason = move_mode(row.mode, forward, row)
    if not ok then
      move_operation(row.operation, not forward, row)
      return false, reason
    end
    return true
  end

  --- `count` x `target_state._pop_decision()`, stopping on the first result
  --- that is not `true` -- identical break rules to review_undo.lua's old
  --- `undo_key` loop, including the missing-method guard (a target resolved
  --- to something that never wired `_pop_decision`).
  local function reverse(row, target_state)
    local moved = move_verdicts(row, false)
    if moved ~= true then
      return false
    end
    local count = row.count or 1
    for _ = 1, count do
      if not target_state._pop_decision then
        break
      end
      local ok = target_state._pop_decision()
      if ok ~= true then
        break
      end
    end
    return true
  end

  --- `count` x `target_state._redo_local()`, same stop rule, mirroring the
  --- old `redo_key` loop (review_undo.lua:369-380).
  local function forward(row, target_state)
    local moved = move_verdicts(row, true)
    if moved ~= true then
      return false
    end
    local count = row.count or 1
    for _ = 1, count do
      if not target_state._redo_local then
        break
      end
      local ok = target_state._redo_local()
      if ok ~= true then
        break
      end
    end
    return true
  end

  return { reverse = reverse, forward = forward }
end

return Factory
