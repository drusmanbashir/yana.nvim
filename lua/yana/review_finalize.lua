-- Review withdrawal, undisplayable abort, and final disposition.
local hunk_ledger = require("yana.hunk_ledger")

local M = {}

function M.new(deps)
  local facade = deps.facade
  local pool_for_state = deps.pool_for_state
  local finish_session = deps.finish_session
  local log = deps.log
  function facade._ledger_rebuild(state, blocks, reason)
    if not state.hunk_ledger then
      -- Every review state carries a ledger (`review_open.lua`'s one constructor), so
      -- this is a hand-built caller and it must say so by name.
      error("review_finalize: _ledger_rebuild needs a state with a hunk_ledger", 2)
    end
    state.hunk_ledger:rebuild(blocks, reason)
    return state.hunk_ledger:pending()
  end

  -- The A1 edge, polled at a door's TAIL and never fired inside `decide`: true exactly
  -- once per pending `>0 -> 0` transition.
  --
  -- What that fact MEANS -- end the turn, or merely advance past this file -- is a TURN
  -- question, answered by handing off to the Turn every time, never decided here by
  -- reading a second, per-file- scoped ledger. The old second-ledger fallback WAS the
  -- defect: an ordinary `ca`/`cr`/`dd` that emptied one file of a multi-file turn
  -- treated its own file's zero as the WHOLE turn's zero, firing the End dialog while
  -- siblings were still queued.
  --
  -- `Turn:on_decision` (turn.lua) asks `Turn:pending_count()` -- summed over EVERY file
  -- the Turn was seeded with at handover intake (ui_review.lua's flush_review_batch),
  -- opened or not -- and only ends the turn at genuine turn-wide zero. If the turn
  -- survives (other files still pending) but THIS file's ledger is empty,
  -- `turn_bind.on_decision` routes to the advance hook: park this file (nothing
  -- settles, nothing tears down) and open the next pending file (Action C / ADJUDICATED
  --
  -- Returns: false (this file still has its own pending hunks -- nothing to
  -- report), "stay" (the Turn/advance hook took over; caller's own
  -- finish_session must not run).
  function facade._poll_leave_edge(state, trigger)
    if not state or not state.hunk_ledger then
      return false
    end
    if state.hunk_ledger:count() > 0 then
      return false
    end
    local tb = require("yana.turn.turn_bind")
    local pool = pool_for_state(state)
    if pool and tb.get(pool) then
      -- The controls already name themselves -- `accept_turn`, `accept_file`,
      -- `accept_hunk`, `reject_hunk`, `reject_all`, `accept_turn_retry`. That
      -- name was dropped here, so every End result said `last_hunk` whatever
      -- the operator actually pressed. Forward it; do not invent one.
      tb.on_decision(pool, state, trigger)
      return "stay"
    end
    return "stay"
  end

  -- `cx`'s whole-file branch (`review_bulk.lua`'s `reject_all` on a review with no
  -- prior decision), brought onto the shape every other door already has: its verdicts
  -- are a door LOOP over `decide` (A5 -- never `decide_all("reject")`), then the same
  -- edge poll.
  --
  -- By the time the close runs, `pending()` is empty. So the list is taken here, one
  -- line before the verdicts, and threaded through.
  --
  -- A LOCAL, never a field: nothing outside this call may see it, which is the
  -- whole difference between this and the mirror it replaces.
  function facade._settle_bulk_reject(state, trigger)
    local restoring = state.hunk_ledger and state.hunk_ledger:pending() or {}
    for _, block in ipairs(restoring) do
      state.hunk_ledger:decide(block, "reject", 0)
    end
    -- The old shape polled the leave edge FIRST and returned on "stay" -- and the
    -- edge is "stay" the instant `pending` reaches zero (the decide loop above),
    -- whether a Turn is bound or not (`_poll_leave_edge`: `count() > 0` is false).
    -- So the return fired before `finish_session`, the ONLY route into the
    -- restore-and-record leg, and a fresh `cx` on a review with no prior decision
    -- restored nothing, wrote no reversal entries and pushed no register row --
    -- `u` afterwards walked back the PREVIOUS action. The "stay" return has to
    -- stop the CLOSE, not the RESTORE.
    --
    -- Restore the buffer bytes and record the reject BEFORE the edge, so a bound
    -- Turn -- which parks this file on that edge -- parks the RESTORED bytes, not
    -- the agent's. Hand the CLOSE to the Turn when one is bound (it parks and
    -- advances, or ends the turn, and owns the teardown, exactly as the per-hunk
    -- `reject_block_at` door leaves its own close to this same edge); own the
    -- close here only when there is no Turn to hand off to.
    local pool = pool_for_state(state)
    local turn_owns_close = pool ~= nil and require("yana.turn.turn_bind").get(pool) ~= nil
    local recorded = finish_session(state, false, restoring, true, turn_owns_close)
    facade._poll_leave_edge(state, trigger)
    return recorded
  end

  local function contains_nul(bytes)
    return type(bytes) == "string" and bytes:find("\0", 1, true) ~= nil
  end

  local function binary_reason(change)
    if type(change) ~= "table" then
      return nil
    end
    if change.reason_class == "binary_content" then
      return "binary_content"
    end
    if contains_nul(change.before) or contains_nul(change.after) then
      return "binary_content"
    end
    return nil
  end

  return { binary_reason = binary_reason }
end

return M
