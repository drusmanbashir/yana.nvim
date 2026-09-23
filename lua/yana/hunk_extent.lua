-- ONE pending hunk's EXTENT: where it lives, which rows it owns, and how an
-- edit sits against it.
--
-- NOTHING is cached across flushes -- the per-row anchors keep living ON the block,
-- exactly as they do today. Anything cached here between flushes would recreate the
-- very staleness this class exists to remove.
--
-- An extent is reachable ONLY from a block the caller already holds. There is
-- deliberately no registry, no cache keyed by bufnr, and no module-level state -- one file's
-- extent can never be reached from another file's.
--
-- Vim-free by construction. The SOURCE tier needs a live reader; it is
-- INJECTED (`opts.live_range_fn`) and lazily resolved from `yana.inline_diff`
-- only when an extent is actually asked for a live range. `hunk_ledger`
-- requires this module for the ANCHOR tier alone and never trips that path,
-- so the ledger stays vim-free (hunk_ledger.lua:11-13).
--
local geometry = require("yana.hunk_extent_geometry")
local anchor = require("yana.hunk_extent_anchor")

local M = {}

local Extent = {}
Extent.__index = Extent

-- Re-exported here so `review_partition.partition`, the class's own methods and every
-- test keep the names they already import.
M.runs_in = geometry.runs_in
M.overlapping = geometry.overlapping
M.relation = geometry.relation
M.allocate = geometry.allocate

-- All three now keep their own SELECTION logic and fan out onto this body for the
-- arithmetic.
--
-- The three disagreed: `shift_span` read `b.new_end_line or b.new_start_line - 1`, the
-- other two read `b.new_end_line` bare and RAISED ("attempt to perform arithmetic on a
-- nil value") on a hunk with no stored end. A nil end means an EMPTY span -- a hunk
-- with no proposal rows, whose end is one above its start (the same convention
-- ui_review_buttons.lua:42, review_geometry.lua:358 and review_watch.lua:319 all encode
-- as `start - 1` / `max(end, start - 1)`). So a nil end is shifted AS an empty span and
--
-- Both bounds are read BEFORE either is written here, so an empty span stays exactly
-- empty (`new_end == new_start - 1`) after any shift. This is the ONE behaviour change
-- of the phase and the row that pins it is tests/headless/r_hunk_extent_one_mover.lua
-- section 2.
--
-- The three callers already skip blocks they do not want; nothing downstream reads the
-- return today.
function M.shift(block, delta)
	if block == nil or (delta or 0) == 0 then
		return false
	end
	local first = block.new_start_line
	if first == nil then
		return false
	end
	local last = block.new_end_line
	if last == nil then
		last = first - 1
	end
	block.new_start_line = first + delta
	block.new_end_line = last + delta
	return true
end

-- The absolute sibling of `shift`: the block's OWN band, read fresh off its live
-- authority extmark by the caller. `Ledger:set_span` fans out onto this, so the two
-- bound-writing shapes -- relative and absolute -- have exactly one implementation each
-- and both live in this class.
function M.set_bounds(block, first, last)
	if block == nil then
		return false
	end
	block.new_start_line = first
	block.new_end_line = last
	return true
end

-- Re-exported here so every existing caller -- hunk_ledger's seed_row_owners /
-- row_is_owned / remap_row_owners fan-outs included -- keeps the name it already
-- imports.
M.seed_anchors = anchor.seed_anchors
M.row_is_owned = anchor.row_is_owned
M.reanchor = anchor.reanchor
M.replace_row_decisions = anchor.replace_row_decisions

-- ------------------------------------------------------------------ CLASS ---
--- Extent.new(bufnr, block, classify, opts) -> extent
---
--- `classify(row) -> bool` is INJECTED policy (review_watch's treesitter
--- ancestor rule, reached as `state._row_is_yana_owned`); the class never
--- decides ownership itself. `bufnr` and `classify` may be nil for an
--- ANCHOR-only extent -- that is how the vim-free ledger uses this class.
--- `opts.live_range_fn(bufnr, block)` overrides the default live reader
--- (`yana.inline_diff.live_block_range`, itself review_marks.lua:24).
function M.new(bufnr, block, classify, opts)
	return setmetatable({
		bufnr = bufnr,
		block = block,
		classify = classify,
		_live_range_fn = opts and opts.live_range_fn or nil,
		_lines_fn = opts and opts.lines_fn or nil,
		_source = nil,
	}, Extent)
end

function Extent:_read_live()
	if self._source ~= nil then
		return
	end
	local fn = self._live_range_fn
	-- The DEFAULT reader is resolved only when there is a buffer to read: an
	-- ANCHOR-only extent (the vim-free ledger's) must never pull `inline_diff`
	-- in. An INJECTED reader is trusted with whatever bufnr it was given --
	-- that is how a unit row drives this tier with no buffer at all.
	if fn == nil and self.bufnr then
		local ok, inline = pcall(require, "yana.inline_diff")
		fn = ok and inline.live_block_range or nil
	end
	local first, last, err, collapsed = nil, nil, nil, false
	if fn then
		local ok_call, a, b, c, d = pcall(fn, self.bufnr, self.block)
		if ok_call then
			first, last, err, collapsed = a, b, c, d
		else
			err = "live reader raised: " .. tostring(a)
		end
	else
		err = "no live reader"
	end
	if first ~= nil then
		self._first, self._last, self._err = first, last, err
		-- It is not "stored", and it must not read as an ordinary live answer either.
		self._source = collapsed and "collapsed" or "live"
		self._collapsed = collapsed and true or false
		return
	end
	-- The authority mark is gone, so fall back to the block's STORED bounds and say so. A
	-- stored bound silently passing an alignment test is exactly the trap this flag exists
	-- to prevent: callers that need trust MUST check provenance() first. Never let
	-- "stored" masquerade as "live".
	self._first = self.block and self.block.new_start_line or nil
	self._last = self.block and (self.block.new_end_line or self._first) or nil
	self._err = err
	self._collapsed = false
	self._source = "stored"
end

--- :live_range() -> first, last, err, collapsed  (1-indexed, inclusive)
--- TOTAL: never raises. `first` is nil only when the block carries no stored
--- start either. Read :provenance() before trusting the answer.
function Extent:live_range()
	self:_read_live()
	return self._first, self._last, self._err, self._collapsed
end

function Extent:provenance()
	self:_read_live()
	return self._source
end

--- :rows(first, last) -> string[] -- ANY live row range, 1-indexed inclusive.
--- The one buffer reader in this class: `:lines()` and the RESOLVE tier both
--- go through it, so a unit row can drive both by injecting `opts.lines_fn`
--- (`lines_fn(bufnr, first, last) -> string[]`) with no buffer at all.
--- TOTAL: an empty or inverted range, a missing buffer and a raising reader
--- all answer `{}`.
function Extent:rows(first, last)
	if first == nil or last == nil or last < first then
		return {}
	end
	local fn = self._lines_fn
	if fn then
		local ok, out = pcall(fn, self.bufnr, first, last)
		return (ok and out) or {}
	end
	if not self.bufnr then
		return {}
	end
	local ok, out = pcall(vim.api.nvim_buf_get_lines, self.bufnr, first - 1, last, false)
	return (ok and out) or {}
end

--- :lines() -> string[] -- the live buffer rows under this extent.
function Extent:lines()
	local first, last = self:live_range()
	return self:rows(first, last)
end

function Extent:seed(force)
	return M.seed_anchors(self.block, force)
end

function Extent:owns(row)
	return M.row_is_owned(self.block, row)
end

function Extent:reanchor(batch)
	return M.reanchor(self.block, batch)
end

--- :runs() -> runs[] -- may be 0, 1 or many.
function Extent:runs()
	local first, last = self:live_range()
	if first == nil or last == nil then
		return {}
	end
	return M.runs_in({ first = first, last = last }, self.classify)
end

function Extent:runs_overlapping(first, last)
	return M.overlapping(self:runs(), first, last)
end

function Extent:placement(batch)
	local first, last = batch and batch.start_line, batch and batch.end_line
	if first == nil or last == nil then
		first, last = self:live_range()
	end
	return M.relation({ first = first, last = last }, batch)
end

function Extent:allocate(runs, old_lines, old_start)
	return M.allocate(runs, old_lines, old_start)
end

-- ALWAYS at least one entry.
---
--- Where the old `try_split` DECLINED -- no live range, fewer than two ownership runs,
--- a re-diff that would not line up -- resolve still answers with the bounds it can
--- justify.
---
---
--- `lines` is read from the live buffer for that span's OWN bounds in the same step
--- that computes them, exactly as the absorb branch pairs `set_new_lines` with
--- `set_span` (review_watch.lua:318-319). A caller therefore cannot write a bound from
--- here without the matching content being in its hand.
---
--- A caller that needs trust must test it. Content then comes from `block.new_lines`
--- rather than from the buffer, because a stored bound is not a claim about live rows.
---
--- It never changes the bounds.
function Extent:resolve(batch)
	local block = self.block or {}
	local old_lines = block.old_lines or {}
	local first, last = self:live_range()
	local provenance = self:provenance()

	local function whole(reason, runs_found)
		-- THE FLOOR. One span is always justifiable: the extent as it reads
		-- right now. Under "live" provenance its content is the live rows; under
		-- "stored"/"collapsed" it is the block's own recorded proposal, because
		-- those bounds make no claim about what the buffer holds.
		local lines
		if provenance == "live" then
			lines = self:rows(first, last)
		else
			lines = block.new_lines or {}
		end
		local spans = {
			{
				first = first,
				last = last,
				lines = lines,
				old_lines = old_lines,
				old_start_line = block.start_line,
				old_end_line = block.end_line,
			},
		}
		spans.provenance = provenance
		spans.runs = runs_found or 0
		spans.reason = reason
		if batch ~= nil then
			spans.placement = self:placement(batch)
		end
		return spans
	end

	if first == nil or last == nil then
		return whole("no bounds at all", 0)
	end
	local runs = self:runs()
	if #runs < 2 then
		-- ONE run (or none) is not a split; the member keeps its own extent.
		return whole(#runs == 1 and "single ownership run" or "no ownership run", #runs)
	end
	-- DELETED-BELOW allocates; the live buffer supplies every child's content.
	local children = M.allocate(runs, old_lines, block.start_line)
	local spans = {}
	for _, child in ipairs(children) do
		spans[#spans + 1] = {
			first = child.new_start_line,
			last = child.new_end_line,
			lines = self:rows(child.new_start_line, child.new_end_line),
			old_lines = child.old_lines,
			old_start_line = child.old_start_line,
			old_end_line = child.old_end_line,
		}
	end
	spans.provenance = provenance
	spans.runs = #runs
	spans.reason = "deleted-below allocation over " .. tostring(#runs) .. " ownership runs"
	if batch ~= nil then
		spans.placement = self:placement(batch)
	end
	return spans
end

--- Returns true when it wrote. The split route does not come through here --
--- `Ledger:split` gives each child a fresh table, which is a BIRTH site, not a move --
--- so this is for the caller that resolves ONE span onto an existing member. Pinned by
--- tests/headless/r_hunk_extent_class_contract.lua.
function Extent:apply(span)
	if span == nil or self.block == nil then
		return false
	end
	M.set_bounds(self.block, span.first, span.last)
	self.block.new_lines = span.lines or {}
	return true
end

--- See M.shift above.
function Extent:shift(delta)
	return M.shift(self.block, delta)
end

--- :set_bounds(first, last) -- the absolute sibling of :shift.
function Extent:set_bounds(first, last)
	return M.set_bounds(self.block, first, last)
end

return M
