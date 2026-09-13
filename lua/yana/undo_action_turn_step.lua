-- UndoActionTurnStep. Row
-- `{kind="accept_turn_step", rel, workspace, turn_id,
-- active={rel,ledger,blocks}, files=[...]}` -- the `cA` giant step, many
-- files, writes disk.
--
-- Rename-only adapter: `review_undo_turn_step.lua` already IS this class'
-- body and already returns the pair, just under its own key names (`undo`,
-- `redo`). Nothing is copied or reimplemented here -- `Factory.new(env)`
-- builds the existing factory unchanged and remaps `undo` -> `reverse`,
-- `redo` -> `forward`. Zero behaviour change.
--
-- SPECIAL RULE (contract #2, the `r_ca_redo_*` family): this row is consumed by the
-- OUTCOME, not the press. Carried over verbatim, not re-derived.
local Factory = {}

function Factory.new(env)
  local inner = require("yana.review_undo_turn_step").new(env)
  return {
    reverse = inner.undo,
    forward = inner.redo,
  }
end

return Factory
