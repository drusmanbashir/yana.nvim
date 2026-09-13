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
  --- `count` x `target_state._pop_decision()`, stopping on the first result
  --- that is not `true` -- identical break rules to review_undo.lua's old
  --- `undo_key` loop, including the missing-method guard (a target resolved
  --- to something that never wired `_pop_decision`).
  local function reverse(row, target_state)
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
