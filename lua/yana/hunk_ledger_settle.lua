-- The completed-edit operation for one HunkLedger: after the watcher has
-- classified a buffer edit, ONE call writes the classifier's membership
-- decisions, derives the hunk's extent from its members, reads the proposal
-- text off the live rows over that extent, and records the history frame for
-- the transition -- in that order.
--
-- The extent is DERIVED, never computed beside the membership (F-OWN-PAINT-
-- PARITY): an anchored hunk spans [first member row, last member row], so a
-- hunk whose rows moved without any row changing owner follows them, and a
-- human row outside the members is outside the hunk (F-OWN-SHIFT). A hunk that
-- owns no row -- a pure deletion, or one whose rows were all removed -- keeps
-- the band the position remap left it.
--
-- Vim-free like the ledger: the caller hands in `lines(first, last)`.
local extent = require("yana.hunk_extent")

local M = {}

--- [first, last] member row of `block`, or nil when it owns no row.
function M.anchor_bounds(block)
	local lo, hi = nil, nil
	for _, owner in ipairs(block.owned_rows or {}) do
		local row = owner.row
		if type(row) == "number" then
			if lo == nil or row < lo then
				lo = row
			end
			if hi == nil or row > hi then
				hi = row
			end
		end
	end
	return lo, hi
end

local function same_lines(a, b)
	a, b = a or {}, b or {}
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function same_owners(a, b)
	a, b = a or {}, b or {}
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i].row ~= b[i].row or a[i].source ~= b[i].source or a[i].provisional ~= b[i].provisional then
			return false
		end
	end
	return true
end

function M.install(Ledger, env)
	local assert_open = env.assert_open
	local index_of = env.index_of

	--- Complete one buffer edit for `block`. `opts`:
	---   changes     the on_lines changes whose captured frames date the before side
	---   decisions   { row, owned, source, provisional? } from the one classifier
	---   lines       function(first, last) -> string[] over live rows
	---   undo_seq    live buffer sequence; the selected capture group's wins
	---   before_seq  the sequence this transition departed from, when the caller knows it
	---   span        { first, last, lines }: an explicit band instead of the derived one
	--- Returns changed, before, after. Records nothing when nothing changed.
	function Ledger:complete_buffer_edit(block, opts)
		assert_open(self, "complete_buffer_edit")
		if not index_of(self.hunks, block) then
			error("hunk_ledger: complete_buffer_edit on a hunk this ledger does not own", 2)
		end
		opts = opts or {}
		local history = self.buffer_history
		-- The before side is read FIRST: with no captured frame it is the block as
		-- it stands now, and every write below would otherwise leak into it.
		local before, before_seq = history:before_for(block, opts.changes)
		if type(opts.before_seq) == "number" then
			before_seq = opts.before_seq
		end
		local prior_owners = block.owned_rows
		if opts.decisions and #opts.decisions > 0 then
			extent.replace_row_decisions(block, opts.decisions)
		end
		local first, last, lines
		if opts.span then
			first, last, lines = opts.span[1], opts.span[2], opts.span[3] or {}
		else
			first, last = M.anchor_bounds(block)
			if first == nil then
				first, last, lines = block.new_start_line, block.new_end_line, block.new_lines or {}
			else
				lines = opts.lines(first, last)
			end
		end
		if not opts.span
			and first == block.new_start_line
			and last == block.new_end_line
			and same_lines(lines, block.new_lines)
			and same_owners(prior_owners, block.owned_rows)
		then
			return false
		end
		self:set_new_lines(block, lines)
		self:set_span(block, first, last)
		history:remember(block, before, before_seq, history:group_seq(opts.undo_seq))
		return true, before, history:snapshot(block)
	end

	--- The explicit-band form, kept for callers that already hold the band a
	--- transition produced. Same writer, same frame, same ordering.
	function Ledger:absorb_buffer_change(block, changes, new_lines, start_line, end_line, undo_seq, before_seq)
		local _, before, after = self:complete_buffer_edit(block, {
			changes = changes,
			span = { start_line, end_line, new_lines },
			undo_seq = undo_seq,
			before_seq = before_seq,
		})
		return before, after
	end
end

return M
