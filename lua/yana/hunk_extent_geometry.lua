-- The DERIVE tier of `yana.hunk_extent`: PURE geometry over an extent.
--
-- Nothing here is new and nothing here changed.
--
-- Every function is pure over its arguments: no buffer reads, no vim API, no module
-- state, no mutation of what it is handed.
--
-- Re-exported verbatim onto `hunk_extent`'s own M, so `hunk_extent.runs_in`,
-- `.overlapping`, `.relation` and `.allocate` keep working for every existing
-- caller (contract C2: no public signature moves).
local M = {}

-- ---------------------------------------------------------------- DERIVE --- Pure and
-- module-level so `review_partition.partition` can delegate without owning an extent: a
-- caller that holds a range but no extent passes it in.
--
-- `range` is `{first = row, last = row}`, 1-indexed inclusive. `classify` is
-- `function(row) -> boolean`, true when that row is agent-owned. Each run is `{first =
-- row, last = row}`, ascending, maximal: a run ends the moment `classify` answers false
-- or the range ends.
function M.runs_in(range, classify)
	local runs = {}
	if not range or type(classify) ~= "function" then
		return runs
	end
	local current = nil
	for row = range.first, range.last do
		if classify(row) then
			if current and row == current.last + 1 then
				current.last = row
			else
				current = { first = row, last = row }
				runs[#runs + 1] = current
			end
		else
			current = nil
		end
	end
	return runs
end

-- Deciding that zero or two overlapping runs is unacceptable is the CALLER's policy,
-- not this class's.
function M.overlapping(runs, first, last)
	local out = {}
	for _, run in ipairs(runs or {}) do
		if first == nil or last == nil or (run.last >= first and run.first <= last) then
			out[#out + 1] = run
		end
	end
	return out
end

-- The placement arithmetic, lifted VERBATIM from review_watch.lua:457-525.
--
-- `bounds` is `{first = start_line, last = end_line}` 1-indexed inclusive --
-- the EFFECTIVE bounds, i.e. after the caller's own running leading_shift /
-- extra_lines. `batch` is one `on_lines` change `{first, last_orig, last_new}`
-- with `first`/`last_orig`/`last_new` 0-indexed, exactly as Neovim delivers.
--
-- Returns (label, relation). Collapsing that to one label would change behaviour, so
-- the label picks leading-first and the caller reads the table. One arithmetic site,
-- two views.
--
-- NOT included, deliberately: review_watch's `merge_gap` veto. That is caller POLICY
-- (the MERGE veto), not geometry.
function M.relation(bounds, batch)
	local rel = {
		pure_insert = false,
		leading_insert = false,
		trailing_insert = false,
		interior = false,
		placement = "disjoint",
	}
	local start_line = bounds and bounds.first
	local end_line = bounds and bounds.last
	if start_line == nil or end_line == nil or batch == nil or batch.first == nil then
		return rel.placement, rel
	end
	local first = batch.first
	local last_orig = batch.last_orig or first
	rel.pure_insert = last_orig == first
	rel.leading_insert = rel.pure_insert and first == start_line - 1
	rel.trailing_insert = rel.pure_insert and first == end_line
	-- Interior bound MUST use the caller's LIVE effective range.
	rel.interior = first >= start_line - 1
		and first <= end_line - 1
		and not rel.leading_insert
		and not rel.trailing_insert
	if rel.leading_insert then
		rel.placement = "top_edge"
	elseif rel.trailing_insert then
		rel.placement = "bottom_edge"
	elseif rel.interior then
		rel.placement = "interior"
	else
		-- Not exercised by product code in this phase -- review_watch reads the three labels
		-- above and the relation table.
		local h_first = start_line - 1
		local h_last = end_line - 1
		if last_orig <= h_first and first < h_first then
			rel.placement = "above"
		elseif first > h_last then
			rel.placement = "below"
		elseif first < h_first and last_orig > h_last then
			rel.placement = "spans"
		else
			rel.placement = "disjoint"
		end
	end
	return rel.placement, rel
end

-- When a member splits, each block of deleted rows goes to the child whose run starts
-- directly below it. With ONE deletion block -- the normal case -- ALL of `old_lines`
-- goes to the TOPMOST child and every lower child becomes a pure insert. Consistent
-- with the painter, which renders deleted rows ABOVE their member
-- (review_paint.lua:54).
--
-- Accepted cost: rejecting the upper child restores the
-- base line ABOVE the lower child's text.
--
--
-- OLD-SIDE COORDINATES. `old_start` is the parent's own `start_line` (its first line in
-- the BASE file). Given it, each child also gets `old_start_line` / `old_end_line`, the
-- base range its `old_lines` occupies -- contiguous, ascending, jointly exactly the
-- parent's.
function M.allocate(runs, old_lines, old_start)
	local children = {}
	local deleted = old_lines or {}
	for index, run in ipairs(runs or {}) do
		local old = {}
		if index == 1 then
			for i, line in ipairs(deleted) do
				old[i] = line
			end
		end
		local child = {
			new_start_line = run.first,
			new_end_line = run.last,
			old_lines = old,
		}
		if old_start ~= nil then
			-- DELETED-BELOW in base coordinates: the topmost child starts where
			-- the parent did and covers the whole deletion; every lower child is
			-- an empty range parked immediately after it.
			child.old_start_line = index == 1 and old_start or (old_start + #deleted)
			child.old_end_line = child.old_start_line + #old - 1
		end
		children[#children + 1] = child
	end
	return children
end

return M
