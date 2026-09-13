-- Owns ONE FILE's hunk list and every verdict on it.
--
-- The header this replaces said "one review's hunk list". It still gets a ledger,
-- because the ruling makes cA decide every yana hunk of the turn and an absorbed human
-- edit is yana's to store. So the unit this object scopes to is the FILE.
--
-- The one deliberate exception: `log.lifecycle_info`, so the three mutators that change
-- MEMBERSHIP (split/merge/rebuild) record it at the seam that actually knows it,
-- instead of every caller re-deriving the same fact.
local log = require("yana.log")
local extent = require("yana.hunk_extent")
local lifecycle = require("yana.hunk_ledger_lifecycle")
local buffer_history = require("yana.hunk_ledger_buffer_history")
local buffer_replay = require("yana.hunk_ledger_buffer_replay")
local settle = require("yana.hunk_ledger_settle")
local M = {}

local REBUILD_REASONS = { disk_reload = true, applier_refusal = true }

local Ledger = {}
Ledger.__index = Ledger

local function assert_open(self, verb)
	if self.phase ~= "open" then
		error("hunk_ledger: " .. verb .. " on a " .. self.phase .. " ledger", 3)
	end
end

local function assert_action(action)
	if action ~= "accept" and action ~= "reject" then
		error("hunk_ledger: invalid action: " .. tostring(action), 3)
	end
end

local function index_of(hunks, block)
	for i, candidate in ipairs(hunks) do
		if candidate == block then
			return i
		end
	end
	return nil
end

-- remove_block's shift, kept byte-compatible (review_geometry.lua:365-384):
-- later hunks slide by the rejection's line delta; accept shifts only when an
-- explicit delta is passed.
--
-- The arithmetic does not: it fans out onto `extent.shift`, the single body that writes
-- new_start_line/new_end_line for a hunk already on a ledger (hunk_extent.lua's APPLY
-- tier).
local function shift_later(hunks, idx, delta)
	if delta == 0 then
		return
	end
	for i = idx + 1, #hunks do
		extent.shift(hunks[i], delta)
	end
end

-- The ledger stays vim-free -- it never schedules or repaints itself -- so the callback
-- is where a real caller coalesces (debounce / vim.schedule) into ONE repaint per tick.
-- No caller repaints by hand (review_watch.lua's on_lines route: ledger update first,
-- then this signal).
local function signal_dirty(self)
	self.dirty = true
	if self.dirty_callback then
		self.dirty_callback()
	end
end

-- Registers the ONE callback fired on every mutation. The opener (vim-aware) owns
-- coalescing; this method just remembers the closure.
function Ledger:on_dirty(callback)
	self.dirty_callback = callback
	if self.dirty and callback then
		callback()
	end
end

-- A repaint with no field change behind it: the buffer's marks were thrown
-- away by something that is not a ledger mutation (a reload, a retrace
-- rebuild, a park/resume that re-enters the same buffer), so the ledger is
-- asked to re-emit its ONE signal. Paint still comes from the ledger and
-- nowhere else -- this is the only way a caller may ask for one.
function Ledger:request_paint()
	signal_dirty(self)
end

function Ledger:count(verdict)
	verdict = verdict or "pending"
	local n = 0
	for _, block in ipairs(self.hunks) do
		if block.verdict == verdict then
			n = n + 1
		end
	end
	return n
end

function Ledger:empty()
	return self:count() == 0
end

-- `clear` is TERMINAL (A7), so a caller that can be reached AFTER a teardown has
-- to be able to ASK rather than raise on the next mutation. One such caller
-- exists: the applier-refusal rebuild, which resurrects a review the bulk
-- teardown already cleared (`review_finalize._ledger_rebuild`).
function Ledger:is_open()
	return self.phase == "open"
end

-- Every mutator raises on one; the replay sites prefer to fall back rather than crash.
function Ledger:owns(block)
	return index_of(self.hunks, block) ~= nil
end

-- The hunk tables inside are the shared live records; membership and verdict change
-- only through here.
function Ledger:pending()
	local out = {}
	for _, block in ipairs(self.hunks) do
		if block.verdict == "pending" then
			out[#out + 1] = block
		end
	end
	return out
end

function Ledger:members()
	local out = {}
	for i, block in ipairs(self.hunks) do
		out[i] = block
	end
	return out
end

function Ledger:decide(block, action, line_delta)
	assert_open(self, "decide")
	assert_action(action)
	local idx = index_of(self.hunks, block)
	if not idx then
		error("hunk_ledger: decide on a hunk this ledger does not own", 2)
	end
	if block.verdict ~= "pending" then
		error("hunk_ledger: hunk is already " .. tostring(block.verdict), 2)
	end
	self:note_decided(block)
	block.verdict = action == "accept" and "accepted" or "rejected"
	local delta
	if line_delta ~= nil then
		delta = line_delta
	elseif action == "reject" then
		delta = #(block.old_lines or {}) - #(block.new_lines or {})
	else
		delta = 0
	end
	shift_later(self.hunks, idx, delta)
	self.last_batch = { block }
	signal_dirty(self)
end

-- Two shapes:
--
-- set_span(block, start_line, end_line) -- the block's OWN band, read fresh
-- off its live authority extmark by the caller (review_watch.lua's absorb).
--
-- shift_span(first_changed_row, delta, geometry_only, blocks) -- every hunk (or every
-- one of `blocks`) whose stored start sits after the row moves by `delta`; shift_later
-- (above) is the same mover keyed by HUNK INDEX. A buffer edit does NOT come here: it
-- moves every position through the one transform (hunk_ledger_transport.lua).
--
-- set_span fans out onto its absolute sibling `extent.set_bounds`.
function Ledger:set_span(block, start_line, end_line)
	assert_open(self, "set_span")
	if not index_of(self.hunks, block) then
		error("hunk_ledger: set_span on a hunk this ledger does not own", 2)
	end
	extent.set_bounds(block, start_line, end_line)
	signal_dirty(self)
end

function Ledger:shift_span(first_changed_row, delta, geometry_only, blocks)
	assert_open(self, "shift_span")
	if delta == 0 then
		return {}
	end
	local moved = {}
	for _, b in ipairs(blocks or self.hunks) do
		if b.new_start_line and b.new_start_line > first_changed_row then
			if extent.shift(b, delta) then
				moved[#moved + 1] = b
			end
		end
	end
	if not geometry_only then
		signal_dirty(self)
	end
	return moved
end

-- Shifts every PENDING hunk from position `at` (1-based, in the ledger's own
-- `pending()` order) onward by `delta`.
function Ledger:shift_pending_from(at, delta)
	assert_open(self, "shift_pending_from")
	if not at or (delta or 0) == 0 then
		return
	end
	local pending = self:pending()
	for i = at, #pending do
		extent.shift(pending[i], delta)
	end
	signal_dirty(self)
end

function Ledger:set_new_lines(block, new_lines)
	assert_open(self, "set_new_lines")
	if not index_of(self.hunks, block) then
		error("hunk_ledger: set_new_lines on a hunk this ledger does not own", 2)
	end
	block.new_lines = new_lines
	signal_dirty(self)
end

-- The RED half. Its own writer for the same reason `new_lines` has one: a
-- history reversal has to put the virtual red rows back, and only the ledger
-- may write a hunk's fields.
function Ledger:set_old_lines(block, old_lines)
	assert_open(self, "set_old_lines")
	if not index_of(self.hunks, block) then
		error("hunk_ledger: set_old_lines on a hunk this ledger does not own", 2)
	end
	block.old_lines = old_lines
	signal_dirty(self)
end

-- Restores a verdict a history reversal recorded. `decide` is the forward door
-- and refuses a hunk that is already decided; this is the inverse, and it is
-- deliberately NOT `decide`: reversing an auto-reject puts a hunk back into the
-- pending set, which no forward action is allowed to do.
function Ledger:restore_verdict(block, verdict)
	assert_open(self, "restore_verdict")
	if not index_of(self.hunks, block) then
		error("hunk_ledger: restore_verdict on a hunk this ledger does not own", 2)
	end
	if verdict ~= "pending" and verdict ~= "accepted" and verdict ~= "rejected" then
		error("hunk_ledger: restore_verdict needs a known verdict, got " .. tostring(verdict), 2)
	end
	block.verdict = verdict
	signal_dirty(self)
end

--
--
-- `force` is new and OPTIONAL. Those two lifecycle mutators now pass `force = true`;
-- every other caller keeps the idempotent behaviour.
function Ledger:seed_row_owners(block, force)
	assert_open(self, "seed_row_owners")
	if not index_of(self.hunks, block) then
		error("hunk_ledger: seed_row_owners on a hunk this ledger does not own", 2)
	end
	return extent.seed_anchors(block, force)
end

function Ledger:row_is_owned(block, row)
	return extent.row_is_owned(block, row)
end

-- Carries one block's row anchors through `edits` (splices) by the one transform.
function Ledger:remap_row_owners(block, edits)
	assert_open(self, "remap_row_owners")
	if not index_of(self.hunks, block) then
		error("hunk_ledger: remap_row_owners on a hunk this ledger does not own", 2)
	end
	for _, edit in ipairs(edits or {}) do
		extent.reanchor(block, edit)
	end
end

-- One row per PENDING hunk, in ledger order; `block` rides along only so the caller can
-- stamp extmark ids back onto the SAME table other readers (render_check,
-- live_block_range) already key off -- the painter itself consults nothing on `block`
-- but the four named fields.
-- F-OWN-PAINT-PARITY. A pending hunk paints as one member span per CONTIGUOUS
-- run of its owned-row anchors -- one run or many, never the stored band. A
-- human gap row holds no anchor, so it falls between runs and stays unpainted
-- (F-OWN-GAP); an all-blank run of member rows is painted like any other.
-- Paint performs no classification of its own (F-OWN-ONE). Deletion
-- virt_lines ride the FIRST emitted span only. A hunk that owns no row (a pure
-- deletion) paints its deletion at its own span.
local function membership_runs(block)
	local owners = block.owned_rows
	if type(owners) ~= "table" or #owners == 0 then
		return nil
	end
	local sorted = {}
	for _, owner in ipairs(owners) do
		if type(owner.row) == "number" then
			sorted[#sorted + 1] = owner
		end
	end
	table.sort(sorted, function(a, b)
		return a.row < b.row
	end)
	local runs = {}
	local current = nil
	for _, owner in ipairs(sorted) do
		if current and owner.row == current.last + 1 then
			current.last = owner.row
			current.lines[#current.lines + 1] = owner.source or ""
		else
			current = {
				first = owner.row,
				last = owner.row,
				lines = { owner.source or "" },
			}
			runs[#runs + 1] = current
		end
	end
	if #runs == 0 then
		return nil
	end
	return runs
end

function Ledger:paint_membership()
	local out = {}
	for _, block in ipairs(self.hunks) do
		if block.verdict == "pending" then
			local runs = membership_runs(block)
			if runs then
				for i, run in ipairs(runs) do
					out[#out + 1] = {
						block = block,
						start_row = run.first,
						end_row = run.last,
						new_lines = run.lines,
						-- The deletion is painted above the hunk's first painted
						-- row; lower spans of the SAME hunk carry no deletion.
						old_lines = i == 1 and block.old_lines or {},
					}
				end
			else
				out[#out + 1] = {
					block = block,
					start_row = block.new_start_line,
					end_row = block.new_end_line,
					new_lines = block.new_lines,
					old_lines = block.old_lines,
				}
			end
		end
	end
	return out
end

-- The cA / panel door. Bulk REJECT is a door loop over decide() so a refused
-- hunk (verdict still pending after the door's attempt) stays detectable (A5).
function Ledger:decide_all(action)
	assert_open(self, "decide_all")
	if action ~= "accept" then
		error("hunk_ledger: decide_all only accepts; bulk reject is a door loop (A5)", 2)
	end
	local batch = {}
	for _, block in ipairs(self.hunks) do
		if block.verdict == "pending" then
			block.verdict = "accepted"
			batch[#batch + 1] = block
		end
	end
	self.last_batch = batch
	signal_dirty(self)
end

-- The verdicts ONE door recorded, taken back. An applier refusal is the only
-- caller: the write it was asked for never happened, so the action that asked
-- for it must be retryable, while every decision made before that door stands
-- (the operator's `3,2,1,4`). Reject deltas are not reversed here because a
-- reject-only completion writes nothing and so is never refused.
function Ledger:take_back_last_batch()
	local n = 0
	for _, block in ipairs(self.last_batch or {}) do
		if block.verdict ~= nil and block.verdict ~= "pending" and index_of(self.hunks, block) then
			block.verdict = "pending"
			n = n + 1
		end
	end
	self.last_batch = nil
	signal_dirty(self)
	return n
end

-- Reverses one decision; re-arms the edge so a later all-decided fires again
-- (A1 — the once-per-review latch was defeated by undo, amendment log).
function Ledger:undo_decision(block)
	assert_open(self, "undo_decision")
	local idx = index_of(self.hunks, block)
	if not idx then
		error("hunk_ledger: undo_decision on a hunk this ledger does not own", 2)
	end
	if block.verdict == "pending" then
		error("hunk_ledger: undo_decision on a pending hunk", 2)
	end
	block.verdict = "pending"
	self.last_batch = nil
	signal_dirty(self)
end

function Ledger:redo_decision(block, action)
	assert_open(self, "redo_decision")
	assert_action(action)
	local idx = index_of(self.hunks, block)
	if not idx then
		error("hunk_ledger: redo_decision on a hunk this ledger does not own", 2)
	end
	if block.verdict ~= "pending" then
		error("hunk_ledger: redo_decision on a decided hunk", 2)
	end
	block.verdict = action == "accept" and "accepted" or "rejected"
	self.last_batch = { block }
	signal_dirty(self)
end

-- The four MEMBERSHIP-LIFECYCLE mutators (load_snapshot / rebuild / split / merge) live
-- in `yana.hunk_ledger_lifecycle` and are installed onto the SAME `Ledger` metatable
-- here, so `ledger:rebuild(...)` and friends keep the exact call shape every caller
-- already uses.
lifecycle.install(Ledger, {
	assert_open = assert_open,
	index_of = index_of,
	signal_dirty = signal_dirty,
	rebuild_reasons = REBUILD_REASONS,
})
buffer_replay.install(Ledger, { assert_open = assert_open })
settle.install(Ledger, { assert_open = assert_open, index_of = index_of })

-- Takes OWNERSHIP of a built, stamped block list (A2). Parked resume: the
-- caller deep-copies, runs scrub_paint, and comes through here too.
function M.open(blocks)
	local self = setmetatable({
		hunks = blocks or {},
		buffer_history = buffer_history.new(),
		-- The blocks the most recent door decided, so an applier refusal can take
		-- exactly that door's verdicts back (`take_back_last_batch`).
		last_batch = nil,
		phase = "open",
		-- Opening IS a mutation: these hunks did not exist a moment ago and nothing has
		-- painted them.
		dirty = true,
	}, Ledger)
	local hunk_identity = require("yana.hunk_identity")
	for _, block in ipairs(self.hunks) do
		-- Every hunk that enters a ledger gets its immutable name here if it does
		-- not already carry one (a resumed hunk arrives with the one it was born
		-- with). Identity has to exist BEFORE the first frame is taken, or a
		-- reversal has nothing but bytes to resolve with.
		hunk_identity.stamp(block)
		block.initial_new_count = block.initial_new_count or #(block.new_lines or {})
		if block.verdict == nil then
			block.verdict = "pending"
		end
		self:seed_row_owners(block)
	end
	return self
end

-- The one paint scrub (A2): replaces the five near-copies named in the
-- amendment log. Field set = the seven the fullest copy nils today
-- (review_open.lua parked-resume loop).
local PAINT_FIELDS = {
	"incoming_extmark_id",
	"incoming_extmark_ids",
	"incoming_row_owners",
	"incoming_orphaned_sources",
	"delete_extmark_id",
	"authority_extmark_id",
	"nav_fallback_stated",
}

function M.scrub_paint(block)
	for _, field in ipairs(PAINT_FIELDS) do
		block[field] = nil
	end
	return block
end

return M
