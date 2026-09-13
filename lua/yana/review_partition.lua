-- Pure ownership partition: maximal stretches of agent-owned rows.
--
-- This module survives as the name -- same signature, same answers, one implementation.
--
-- Kept, not deleted, because that check is what pins "one implementation"; it is a
-- retirement candidate the moment something else pins that.
--
-- The original design read a per-row owner cache (`block.incoming_row_owners`) that the
-- painter kept live. The painter rewrite deleted that cache's only writers
-- (`review_paint .set_incoming`/`remap_incoming_row_owners` -- a dumb renderer plants
-- one extmark per pending hunk and tracks no per-row owner), so the cache was silently
-- always empty: `partition` returning `{}` made `try_split` refuse every split,
-- unconditionally, forever.
--
-- Pure over its inputs: no buffer reads, no `block` field, no mutation. A caller with
-- no live classifier (a bare unit-test double) gets `{}`, same as before.
local extent = require("yana.hunk_extent")

local M = {}

--- partition(range, classify) -> runs[]
---
--- `range` is `{first = row, last = row}`, 1-indexed, inclusive -- the rows
--- to scan (the block's LIVE extent; the caller's to compute). `classify`
--- is `function(row) -> boolean`, true when that row is agent-owned.
--- Each run is `{first = row, last = row}`, ascending, maximal: a run ends
--- the moment `classify` answers false or the range ends. `range == nil` or
--- `classify == nil` yields `{}`.
function M.partition(range, classify)
	return extent.runs_in(range, classify)
end

return M
