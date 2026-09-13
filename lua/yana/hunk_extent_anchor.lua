-- The ANCHOR tier of `yana.hunk_extent`: per-row ownership identity, stored ON
-- the block.
--
-- Positions move by the one transform (hunk_anchor_splice.lua); nothing here reads text.
--
-- This state belongs to the BLOCK, not to the extent -- an extent lives for one flush,
-- the anchors outlive it -- which is why these are plain functions over a block and
-- never touch an Extent instance. Vim-free, and it reads no buffer at all, which is
-- what lets the ledger require `hunk_extent` for this tier alone
-- (hunk_ledger.lua:11-13).
--
-- Re-exported verbatim onto `hunk_extent`'s own M, so `hunk_extent.seed_anchors`,
-- `.row_is_owned` and `.reanchor` keep working for every existing caller
-- (contract C2: no public signature moves).
local splice = require("yana.hunk_anchor_splice")
local M = {}

-- The block owns this per-row state; it is stored on the block so it outlives the
-- extent, which is per-flush.
function M.seed_anchors(block, force)
	-- `force` is the explicit re-seed those two lifecycle mutators need; every other
	-- caller keeps the idempotent behaviour it has always had.
	if block.owned_rows ~= nil and not force then
		return false
	end
	local owners = {}
	for offset, source in ipairs(block.new_lines or {}) do
		owners[#owners + 1] = {
			row = (block.new_start_line or 1) + offset - 1,
			source = source,
		}
	end
	block.owned_rows = owners
	return true
end

-- EXACT per-row ownership replacement for a NAMED set of touched rows, and no
-- others. `decisions` is a list of `{ row, owned, source }`: an `owned` row gets
-- (or keeps) an anchor with its source, a non-`owned` row loses any anchor it
-- held, and every row ABSENT from the list keeps whatever anchor it already had.
--
-- Unlike `seed_anchors`, this NEVER rebuilds the block's whole span. The caller
-- has classified each touched row through the one ownership authority
-- (review_watch_ownership) and this writes exactly that verdict, so a human row
-- that a temporary absorb extent swept in is not blindly owned -- the defect a
-- full-span reseed left durable across redo (WO-1 correction).
--
-- `provisional` marks a flush's claim that no InsertLeave has re-judged yet
-- (F-OWN-PROVISION); an owned decision without it is settled.
function M.replace_row_decisions(block, decisions)
	local by_row = {}
	for _, owner in ipairs(block.owned_rows or {}) do
		by_row[owner.row] = { source = owner.source, provisional = owner.provisional }
	end
	for _, decision in ipairs(decisions or {}) do
		if type(decision.row) == "number" then
			if decision.owned then
				local prior = by_row[decision.row]
				by_row[decision.row] = {
					source = decision.source ~= nil and decision.source or (prior and prior.source) or "",
					provisional = decision.provisional or nil,
				}
			else
				by_row[decision.row] = nil
			end
		end
	end
	local rows = {}
	for row in pairs(by_row) do
		rows[#rows + 1] = row
	end
	table.sort(rows)
	local owners = {}
	for _, row in ipairs(rows) do
		owners[#owners + 1] = { row = row, source = by_row[row].source, provisional = by_row[row].provisional }
	end
	block.owned_rows = owners
	return true
end

function M.row_is_owned(block, row)
	for _, owner in ipairs(block.owned_rows or {}) do
		if owner.row == row then
			return true
		end
	end
	return false
end

-- The anchors of `block` through ONE edit -- a splice, or a change that carries
-- one -- by the one transform (hunk_anchor_splice.lua): each anchor is a
-- right-gravity point at its row's start, so Return at column 0 takes the row's
-- anchor down with it whatever the row holds, and no text is ever read to decide
-- where an anchor goes. Seeds a never-seeded block first. True when any anchor
-- moved, merged or was consumed.
function M.reanchor(block, change)
	M.seed_anchors(block, false)
	local owners, changed = splice.owners(splice.of(change), block.owned_rows)
	block.owned_rows = owners
	return changed
end

return M
