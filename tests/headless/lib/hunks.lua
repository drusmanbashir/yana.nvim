-- Single seam for tests that read a review state's pending-hunk list.
--
-- `state.diff_blocks` -- the field on the table `inline_diff.active_state()`
-- returned, and on `.active` inside a pool -- has been RETIRED (R3,
-- it "ceases to exist. Not a view, not a mirror, not a compatibility alias").
-- `state.hunk_ledger` owns
-- the hunks and every verdict on them now.
--
-- This file is why that rename cost one edit instead of ninety. Every test
-- that used to read `.diff_blocks` off a state table goes through `hunks(state)`
-- / `pending_count(state)` here, so the day the field actually changed, this
-- was the ONE file to repoint. That day was the kill seam.
--
-- WHAT CHANGED FOR CALLERS: nothing about the VALUE. `Ledger:pending()` returns
-- the still-undecided hunks in buffer order -- the same membership the old field
-- carried, since a decision used to DELETE its entry and now sets its `verdict`
-- instead (R5). What changed is that the returned table is a FRESH membership
-- vector per call (amended R4): inserting into or removing from it changes
-- nothing. The hunk tables inside are still the same live records, so reading
-- (or painting) their fields works exactly as before.
--
-- NIL-SHAPE IS PRESERVED EXACTLY, and that is load-bearing -- several callers
-- depend on each half of it:
--   * `state` itself nil  -> both error, as indexing nil always did. Call sites
--     keep whatever `state`-nil guard they already had.
--   * `state` present, no ledger (`hunks_lib.hunks((active_state() or {}))`,
--     the idiom for "the review may be gone") -> `hunks` returns NIL, exactly
--     as reading an absent `.diff_blocks` field did, so the caller's trailing
--     `or {}` still fires. A caller may rely on the nil to reach its fallback.
--     `pending_count` still errors on that state, as `#nil` did -- but by name.
local M = {}

-- The ordered pending-hunk list for `state` (an active_state()-shaped review
-- state), or nil if it carries no ledger. A fresh vector per call; the hunks
-- inside are the live records.
function M.hunks(state)
	local L = state.hunk_ledger
	if L == nil then
		return nil
	end
	return L:pending()
end

-- The pending-hunk COUNT for `state`. `count()` defaults to the "pending"
-- verdict, so this is `#hunks(state)` without building the vector.
function M.pending_count(state)
	local L = state.hunk_ledger
	if L == nil then
		error("tests/headless/lib/hunks.lua: review state carries no hunk_ledger", 2)
	end
	return L:count()
end

return M
