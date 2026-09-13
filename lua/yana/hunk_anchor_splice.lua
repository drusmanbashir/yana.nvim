-- THE ONE POSITION TRANSFORM (ledger identity rule 1 and the trigger model,
-- F-OWN-SHIFT).
--
-- Every tracker that holds a buffer row across an edit moves through this module
-- and nothing else: a hunk's row anchors (on the ledger or carried off it), its
-- band, the InsertLeave dirty rows, a flush's provisional claims, and the batch's
-- pre-image inversion (`preimage`, NO_PREIMAGE). The edit is one `on_bytes`
-- splice (review_watch.lua): start S, old end E, new end N; 0-based rows, BYTE
-- columns.
--
-- A row is a right-gravity point at its row's start, P = (row - 1, 0):
--   P < S                        it keeps its place;
--   a pure insertion at P == S   it moves to N;
--   P >= E                       it translates with the text after E;
--   S <= P < E                   a fully consumed row loses its identity; a row
--                                that partially survives collapses onto N.
-- The answer is normalized back to column 0 after EVERY splice: this is a row
-- owner, so a prefix typed earlier cannot change what a later Return does.
-- Text is never read or compared here. Pure: no vim API, no state.
local M = {}

-- A row born inside a batch has no pre-batch line (review_hunk_split's deletion
-- evidence). A unique table: never a row and never nil.
M.NO_PREIMAGE = setmetatable({}, { __tostring = function() return "NO_PREIMAGE" end })

--- One splice from `on_bytes`' arguments: start row/col, old end row/col, new
--- end row/col, where an end column is relative to the start column only on the
--- start row.
function M.splice(sr, sc, oer, oec, ner, nec)
	return {
		sr = sr,
		sc = sc,
		er = sr + oer,
		ec = oer == 0 and sc + oec or oec,
		nr = sr + ner,
		nc = ner == 0 and sc + nec or nec,
	}
end

--- The splice an edit is: a splice itself, the splice a change carries, or --
--- for a change that holds only on_lines' three numbers (a unit row's synthetic
--- change) -- the whole-line splice they name.
function M.of(change)
	if change.sr then
		return change
	end
	if change.splice then
		return change.splice
	end
	local f = change.first
	return M.splice(f, 0, change.last_orig - f, 0, change.last_new - f, 0)
end

function M.is_noop(s)
	return s.er == s.sr and s.ec == s.sc and s.nr == s.sr and s.nc == s.sc
end

--- The line-shaped change the classifiers read (on_lines' `first, last_orig,
--- last_new`), derived from the SAME splice so classification and transport can
--- never describe two different edits. A splice of whole rows names exactly
--- those rows -- Return at column 0 is a row inserted ABOVE the row -- and any
--- other splice names every row it touched.
function M.line_change(s)
	if s.sc == 0 and s.ec == 0 and s.nc == 0 then
		return s.sr, s.er, s.nr
	end
	return s.sr, s.er + 1, s.nr + 1
end

--- [lo, hi] (1-based) of the rows holding bytes the splice wrote or joined, or
--- nil when it only removed whole rows. A row that only moved is not touched.
function M.touched(s)
	local hi = s.nr
	if s.nc == 0 and s.ec == 0 then
		hi = hi - 1
	end
	if hi < s.sr then
		return nil
	end
	return s.sr + 1, hi + 1
end

local function before_start(s, p)
	return p < s.sr or (p == s.sr and s.sc > 0)
end

local function pure_insert_at(s, p)
	return s.er == s.sr and s.ec == s.sc and p == s.sr and s.sc == 0
end

local function at_or_after_end(s, p)
	return p > s.er or (p == s.er and s.ec == 0)
end

--- Where the anchor of 1-based `row` goes: the new row, or nil when the splice
--- consumed it. The second value is true when a partially surviving row
--- collapsed onto N (its bytes changed; the settled re-judgement decides it).
---
--- Consumption is an interval rule, never a key rule: a row is consumed when the
--- replaced bytes cover its text AND its own newline, (row-1, 0) up to (row, 0)
--- -- Neovim's own rule for a point extmark with `invalidate`
--- (tests/headless/u_anchor_splice_differential.lua). A row whose newline
--- survives keeps a candidate identity even when every visible byte went, and
--- the only line of a buffer, deleted, is replaced by Neovim's mandatory empty
--- row, which owns nothing.
function M.point(s, row)
	local p = row - 1
	if before_start(s, p) then
		return row
	end
	if pure_insert_at(s, p) then
		return s.nr + 1
	end
	if at_or_after_end(s, p) then
		return p + s.nr - s.er + 1
	end
	if p < s.er then
		return nil
	end
	return s.nr + 1, true
end

-- Where the start of 0-based row `x` goes as a LEFT-gravity point: at or before
-- S it stays (text written exactly there lands after it), past E it translates,
-- and inside the replaced bytes -- or exactly at their end, which Neovim counts
-- as inside -- it collapses onto S, where the insertion does not move it.
local function left_point(s, x)
	if x <= s.sr then
		return x, 0
	end
	if x > s.er then
		return x + s.nr - s.er, 0
	end
	return s.sr, s.sc
end

--- A band [first, last] (1-based; empty when last < first) through one splice,
--- as Neovim moves a range mark (tests/headless/u_anchor_splice_differential.lua):
--- its start is a row-start point with RIGHT gravity (collapsing onto N when
--- consumed, never vanishing), its end the start of the row after it with LEFT
--- gravity. Rows inserted exactly at either edge land outside; rows inserted
--- inside grow it; a hunk that owns no row still has a place.
function M.band(s, first, last)
	local nfirst = M.point(s, first) or (s.nr + 1)
	if last == nil or last < first then
		return nfirst, nfirst - 1
	end
	local row, col = left_point(s, last)
	local nlast = col == 0 and row or row + 1
	return nfirst, math.max(nlast, nfirst - 1)
end

--- One block's owner list through one splice: each owner is a point, a consumed
--- one is dropped, and owners of this ONE list that land on one row coalesce
--- into the one whose row was the upper (its text starts the joined row).
--- Returns the new list, sorted by row, and whether anything changed. Owners of
--- DIFFERENT blocks meeting on one row are not decided here
--- (`Ledger:transport` hands them to the merge authority).
function M.owners(s, owners)
	local moved, changed = {}, false
	for _, owner in ipairs(owners or {}) do
		local row = type(owner.row) == "number" and M.point(s, owner.row) or nil
		if row == nil then
			changed = true
		else
			changed = changed or row ~= owner.row
			moved[#moved + 1] = { from = owner.row, owner = owner, row = row }
		end
	end
	table.sort(moved, function(a, b)
		if a.row ~= b.row then
			return a.row < b.row
		end
		return a.from < b.from
	end)
	local out = {}
	for _, m in ipairs(moved) do
		if out[#out] and out[#out].row == m.row then
			changed = true
		else
			out[#out + 1] = { row = m.row, source = m.owner.source, provisional = m.owner.provisional }
		end
	end
	return out, changed
end

--- A table keyed by 1-based row (the InsertLeave dirty stamps) through one
--- splice: rows move as points, consumed rows drop, and when two land on one row
--- the upper one's value is kept.
function M.rows(s, map)
	local out, from = {}, {}
	for row, value in pairs(map or {}) do
		if type(row) == "number" then
			local to = M.point(s, row)
			if to and (from[to] == nil or row < from[to]) then
				out[to], from[to] = value, row
			end
		end
	end
	return out
end

--- The row (1-based) a post-splice row held before the splice, or NO_PREIMAGE
--- for a row the splice wrote or joined: it has no pre-splice line.
function M.preimage(s, row)
	local lo, hi = M.touched(s)
	if lo and row >= lo and row <= hi then
		return M.NO_PREIMAGE
	end
	if row - 1 < s.sr then
		return row
	end
	return row - (s.nr - s.er)
end

return M
