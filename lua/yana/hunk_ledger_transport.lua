-- Size split of hunk_ledger_buffer_replay.lua: THE transport of one buffer edit
-- onto the ledger's blocks (ledger identity rule 1 and the reload barrier,
-- F-OWN-SHIFT and F-SPLIT-MERGE). Every block the ledger holds, and every block
-- `carry_through` carries off it, moves by the one pure transform
-- (hunk_anchor_splice.lua) -- band and row anchors alike -- and by nothing else;
-- the reload composition's own rewrite is the one barrier, relocated whole.
-- Vim-free like the ledger.
local extent = require("yana.hunk_extent")
local splice = require("yana.hunk_anchor_splice")
local copy_owners = require("yana.hunk_ledger_buffer_frame").copy_owners

local M = {}

-- One edit through one block: its row anchors (`hunk_extent_anchor.reanchor`)
-- and its band (`splice.band`, written by the one absolute bound writer). True
-- when either moved.
local function transport(block, change)
	local changed = extent.reanchor(block, change)
	local first = block.new_start_line
	if first ~= nil then
		local nfirst, nlast = splice.band(splice.of(change), first, block.new_end_line or first - 1)
		if nfirst ~= first or nlast ~= block.new_end_line then
			extent.set_bounds(block, nfirst, nlast)
			changed = true
		end
	end
	return changed
end

-- Rows owned by two pending blocks after a transport: kept on BOTH (no winner
-- by table order) and queued for the merge authority (review_hunk_collision.lua).
local function note_collisions(self, change)
	local at = {}
	for _, block in ipairs(self:pending()) do
		for _, owner in ipairs(block.owned_rows or {}) do
			local other = at[owner.row]
			if other and other ~= block then
				self.anchor_collisions = self.anchor_collisions or {}
				table.insert(self.anchor_collisions, { row = owner.row, blocks = { other, block }, change = change })
			end
			at[owner.row] = block
		end
	end
end

function M.install(Ledger, env)
	local assert_open = env.assert_open

	-- ONE EDIT, from the watcher's `on_bytes` callback (review_watch.lua): the
	-- change carries its splice. A change holding only on_lines' three numbers
	-- is the whole-line splice they name (`splice.of`).
	function Ledger:record_buffer_change(change)
		assert_open(self, "record_buffer_change")
		if type(change) ~= "table"
			or type(change.first) ~= "number"
			or type(change.last_orig) ~= "number"
			or type(change.last_new) ~= "number"
		then
			error("hunk_ledger: invalid buffer change", 2)
		end
		-- `change.undo_marker` is the boundary marker the watcher's callback read
		-- while the change was still in flight. It partitions the capture groups
		-- and is NOT a sequence number; a change without one falls into the single
		-- unkeyed group, which is exactly the un-partitioned behaviour.
		self.buffer_history:capture(change, self:pending(), change.undo_marker)
		-- THE RELOAD BARRIER. The reload composition's own whole-buffer rewrite
		-- says nothing about where a hunk went; the composition does
		-- (`relocate_membership`), so these bytes move no position.
		if change.barrier then
			self.barrier_change = change
			return {}
		end
		-- EXACTLY the blocks the transport moved -- band or anchors -- so the
		-- recorded set and the moved set can never disagree.
		local moved = {}
		for _, block in ipairs(self.hunks) do
			if transport(block, change) then
				moved[#moved + 1] = block
			end
		end
		self.buffer_history:note_shifted(change.undo_marker, moved)
		-- A CARRIED block (`carry_through`) is off the ledger, so it is neither
		-- framed nor reported moved -- but it takes the same transport a member
		-- takes, so it stays in the frame the bytes are in.
		for _, block in ipairs(self.carried or {}) do
			transport(block, change)
		end
		if #moved > 0 then
			note_collisions(self, change)
		end
		return moved
	end

	--- A block leaving the pending set by a decision records its exact anchors
	--- (`Ledger:decide`). The undo of that decision puts the bytes back into the
	--- frame it was decided in (review_undo_replay's `:undo pre_seq`), where the
	--- block wears them again (`wear_decided`): a reject's own line rewrite
	--- consumed them, and the transform never resurrects an identity.
	function Ledger:note_decided(block)
		self.decided_anchors = self.decided_anchors or setmetatable({}, { __mode = "k" })
		self.decided_anchors[block] = copy_owners(block.owned_rows)
	end

	function Ledger:wear_decided(block)
		local owners = self.decided_anchors and self.decided_anchors[block]
		if owners and self:owns(block) then
			block.owned_rows = copy_owners(owners)
		end
	end

	--- The rows two pending hunks' anchors share, taken once by the flush.
	function Ledger:take_anchor_collisions()
		local out = self.anchor_collisions or {}
		self.anchor_collisions = nil
		return out
	end

	--- THE RELOAD BARRIER'S OTHER HALF. `relocated` maps a block to the first
	--- row the composition put its rows at
	--- (review_ownership.apply_review_blocks_to_reloaded_disk); each such block's
	--- anchors and band move by that ONE delta, so its human gaps stay gaps. The
	--- moved set is noted under the barrier change's group, as a transport's is.
	function Ledger:relocate_membership(relocated)
		assert_open(self, "relocate_membership")
		local moved = {}
		for block, first in pairs(relocated or {}) do
			local delta = type(block.new_start_line) == "number" and first - block.new_start_line or 0
			if delta ~= 0 and self:owns(block) then
				local owners = copy_owners(block.owned_rows) or {}
				for _, owner in ipairs(owners) do
					owner.row = owner.row + delta
				end
				block.owned_rows = owners
				extent.shift(block, delta)
				moved[#moved + 1] = block
			end
		end
		local change = self.barrier_change
		self.barrier_change = nil
		if change then
			self.buffer_history:note_shifted(change.undo_marker, moved)
		end
		return moved
	end

	-- THE BLOCKS A STRUCTURAL RECORD TOOK OFF THE LEDGER RIDE THE TEXT MOVE THE
	-- RECORD RIDES (F-SPLIT-MERGE). `u` and `<C-r>` both move membership BEFORE
	-- the text (`review_undo.spend_buffer_edit`), so a block leaves the ledger on
	-- one side of a native move and the opposite press puts it back on the other:
	-- a split's children leave on `u` in the post-edit frame and return on `<C-r>`
	-- onto pre-edit bytes; the parent does the reverse. Carried, a block takes
	-- every transport `fn` causes exactly as a member does, so it re-enters in the
	-- frame the bytes are in. Members are skipped and a block named twice is
	-- carried once.
	--
	-- EXACT CARRIED STATE. Carrying cannot resurrect an identity a deletion
	-- consumed while the block was away (the transform never does). So a block
	-- leaves with its exact anchors and band recorded (`departures`), and when the
	-- opposite press brings it back it wears exactly those values once that
	-- press's native move has landed -- the bytes are then in the frame it left
	-- from. A block a history frame restored during the move keeps the frame's
	-- values: exact frame restoration wins. Returns what `pcall(fn)` returns.
	function Ledger:carry_through(blocks, fn)
		self.departures = self.departures or setmetatable({}, { __mode = "k" })
		local carried, returning, seen = {}, {}, {}
		for _, block in ipairs(blocks or {}) do
			if type(block) == "table" and not seen[block] then
				seen[block] = true
				if not self:owns(block) then
					carried[#carried + 1] = block
					self.departures[block] = {
						owned_rows = copy_owners(block.owned_rows),
						first = block.new_start_line,
						last = block.new_end_line,
					}
				elseif self.departures[block] then
					returning[#returning + 1] = block
				end
			end
		end
		local prior, prior_restored = self.carried, self.frame_restored
		self.carried = #carried > 0 and carried or nil
		self.frame_restored = {}
		local ok, value = pcall(fn)
		local restored = self.frame_restored
		self.carried, self.frame_restored = prior, prior_restored
		for _, block in ipairs(returning) do
			local departure = self.departures[block]
			self.departures[block] = nil
			if ok and not restored[block] and self:owns(block) then
				block.owned_rows = copy_owners(departure.owned_rows)
				extent.set_bounds(block, departure.first, departure.last)
			end
		end
		return ok, value
	end
end

return M
