--
-- A park deep-copies tables, clears extmarks, and may wipe the buffer -- after that,
-- nothing on disk says what the ledger held, and a re-run cannot recover it. This
-- module computes and writes the one `review.park.census` row that captures it: pure
-- observation over an already-built ledger/state, no vim APIs, no control flow, nothing
-- here decides anything. See the call site in review_navigate.lua's
-- `park_and_open_state` for what it is called with and why.
local M = {}

--- `pending_blocks` is what actually goes into `parked.blocks` (pending-only);
--- `sealed_decisions` is the list about to become `parked.sealed_decisions`.
function M.emit(change, state, bufnr, pending_blocks, sealed_decisions, direction)
  local log = require("yana.log")
  local L = state and state.hunk_ledger
  local ledger_total = L and (L:count("pending") + L:count("accepted") + L:count("rejected")) or nil
  log.lifecycle_info("review.park.census", {
    rel = change.rel or change.path,
    turn_id = change.turn_id or change.turn_gen,
    park_seq = change._park_seq,
    bufnr = bufnr,
    ledger_total = ledger_total,
    pending = L and L:count("pending") or nil,
    accepted = L and L:count("accepted") or nil,
    rejected = L and L:count("rejected") or nil,
    blocks_sealed = #pending_blocks,
    decisions_sealed = #sealed_decisions,
    -- Sealed alongside decisions/blocks above, `state.undone_decisions` is
    -- NOT part of `_parked_review` (observed, not changed here) -- logging
    -- its size at park time so a later resume's `undone_resumed` of 0 reads
    -- as a real drop rather than "there was nothing to carry".
    undone_sealed = #((state and state.undone_decisions) or {}),
    direction = direction,
  })
end

return M
