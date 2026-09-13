-- Buffer-driven ledger history. One instance belongs to one HunkLedger.
-- It remembers only ledger state changed by an absorbed buffer edit; Neovim
-- remains the byte-history owner.
local frame = require("yana.hunk_ledger_buffer_frame")
local transition = require("yana.hunk_ledger_buffer_transition")

local M = {}
local History = {}
History.__index = History

local snapshot = frame.snapshot
local snapshot_ref = frame.snapshot_ref
local copied = frame.copied

-- BOUNDED BY REACHABILITY, AND BY NOTHING ELSE. Records are keyed by Neovim
-- undo sequence and a long editing session makes one per absorbed edit, so the
-- set does need a bound -- but a COUNT is the wrong one, and was actively
-- unsafe. A fixed cap of 256 dropped the oldest records while Neovim could
-- still land on their sequences, and the loss did not stay quiet: an evicted
-- sequence falls BELOW the retained span, `knows` reads "outside my
-- bookkeeping, unknown-but-legitimate", and a native move over a transition
-- this history really did record then advances with nothing following it --
-- exactly the absent-versus-frame-free hole that `finish`'s explicit empty
-- record exists to close. Measured on this tree: 300 recorded transitions left
-- `records=256`, `records[1]=nil`, `knows(1)=true`.
--
-- The undo tree already supplies the correct bound: a record dies with the
-- native state it describes and not one edit sooner (`prune`). When the
-- reachable set cannot be read, records are RETAINED and the failed check is
-- reported; a guess would either leak or delete reachable history.

function M.new()
	return setmetatable({ current_seq = nil, records = {}, record_seqs = {} }, History)
end

-- `before_members` IS THE RECORD'S MEMBERSHIP AT THE MOMENT IT BEGAN, and it is
-- the only thing that tells a legitimate late before-frame from an impossible
-- one. ONE native undo sequence is interpreted by SEVERAL watcher cycles, and
-- each cycle after the first opens its OWN capture group (measured: seq 6 cycle
-- 1 opens `before_seq=5`, cycle 2 opens `before_seq=6`) while `ensure_record`
-- hands them all the SAME record. That accumulation is required -- seq 5's
-- record gets all sixteen of its before-frames from its SECOND cycle -- so
-- "written by a later cycle" cannot be the test, and neither can `before_seq`,
-- which mismatches in the legitimate case too.
--
-- What separates the two is membership. A cycle's capture is `self:pending()`,
-- EVERY pending hunk (`capture`), so the group open when the record was created
-- names exactly the hunks that existed at the transition's start. A bystander
-- first shifted in a later cycle is in that set and keeps its before-frame; a
-- split child the transition itself created is not, and framing it wrote a
-- before-frame for a hunk that did not exist at `before_seq`. The undo reverses
-- the split first, destroys that child, and `resolve_frame` can then never name
-- it: all-or-nothing refuses, the settle transaction re-applies the split, and
-- every further `u` repeats it -- the split-undo bounce. The child is owed no
-- before-frame, because reversing the split is what restores it.
--
-- BEFORE-SIDE ONLY. The after side is membership at FINISH and legitimately
-- names the children, which is what a redo re-creates. And when no group is
-- open (`finish`'s empty record) the field is nil and nothing is gated, which
-- is the behaviour of every caller that predates capture groups.
local function ensure_record(self, after_seq, before_seq)
	local record = self.records[after_seq]
	if record then
		return record
	end
	--- KEYS ONLY: the gate asks membership, never state, and a record outlives the
	--- group whose frames it would otherwise pin alive.
	local before_members = nil
	if self.last_before ~= nil then
		before_members = {}
		for block in pairs(self.last_before) do
			before_members[block] = true
		end
	end
	record = { before_seq = before_seq, before = {}, after = {}, before_members = before_members }
	self.records[after_seq] = record
	self.record_seqs = self.record_seqs or {}
	self.record_seqs[#self.record_seqs + 1] = after_seq
	return record
end

-- ONE OWNER FOR `before_seq`. `open_group_marker` dates the NEXT capture group
-- and means nothing once the observed position moves, so every function that
-- moves it clears the marker -- here, `apply` and `rewind`. The undo's own
-- `on_lines` opens a group the suspended watcher never `finish`es, and that
-- orphan dated a 2->3 record `before_seq=2`: the second `u` read
-- `APPLY dir=none frames=0` and the band stayed narrow (LEDGER.md N20).
function History:observe(seq)
	if type(seq) == "number" then
		self.current_seq = seq
		self.open_group_marker = nil
	end
end

-- members must be every pending hunk; a decided hunk is never absorbed and
-- must get no frame entry.
--- Groups are keyed by the caller's BOUNDARY MARKER, not by a sequence number:
--- the marker is what the watcher can read while a change is still in flight
--- (review_watch.lua, `callback_undo_marker`), and the sequence the group ends
--- on is only knowable once the group is closed. `false` is the key for a
--- caller that supplies no marker at all -- one group, the un-partitioned
--- behaviour.
local function group_key(marker)
	if marker == nil then
		return false
	end
	return marker
end

function History:capture(change, members, marker)
	local before = {}
	for _, block in ipairs(members) do
		before[block] = snapshot_ref(block)
	end
	change._ledger_before = before
	-- Also held off the change, keyed by block, for callers that arrive AFTER
	-- the shift pass with no change list in hand -- the destroyed-hunk decision
	-- is the one that matters. Without this the only route to the pre-edit
	-- geometry is the live fields, which the shift has already moved.
	--
	-- FIRST CAPTURE OF THE CYCLE WINS, and that is the whole point. One native
	-- undo sequence can carry SEVERAL changes (`:g/.../d` deletes three rows in
	-- one ex command, hence one sequence), and each `record_buffer_change` runs
	-- its own shift pass -- so the second and third captures already hold spans
	-- the earlier deletions moved. A destroyed hunk restored from those lands
	-- one or two rows short of where the group began, which is the group law's
	-- "same boundaries" broken on the way OUT
	-- (r_atomic_group_reverses_with_same_boundaries). The state ONE undo has to
	-- restore is the state before the WHOLE cycle, so the first capture is kept
	-- and later ones add NOTHING. `finish` closes the cycle and clears it; a
	-- single-change cycle is unaffected, its first capture being its only one.
	--
	-- AND THE FIRST CAPTURE IS THE GROUP'S MEMBERSHIP, NOT A SPARSE MAP OF THE
	-- HUNKS THAT MOVED: the caller passes `self:pending()`, every pending hunk,
	-- so a bystander first shifted in a LATER cycle is already here with its
	-- pre-transition geometry. The only block a later capture can add is one
	-- that became pending DURING the transition -- a split child or a merge
	-- result the transition itself created -- and adding it wrote a before-frame
	-- for a hunk that did not exist when the record began, holding cycle-2
	-- state. The undo then reverses the split FIRST, destroying that child, and
	-- `resolve_frame` can never name it: all-or-nothing refuses, the settle
	-- transaction re-applies the split, and every further `u` repeats it (the
	-- split-undo bounce). The child needs no before-frame: reversing the split
	-- is what restores it. Its AFTER frame is untouched -- redo needs that one,
	-- and only the before-side is membership-bound.
	--
	-- ONE ACCUMULATION PER NATIVE SEQUENCE, NOT PER SCHEDULED FLUSH. "First
	-- capture wins" is the law WITHIN one native undo sequence and a bug ACROSS
	-- two. A synchronous mapping can close sequence N and open N+1 before the
	-- scheduled flush ever runs, and a single accumulator then handed the
	-- SECOND sequence's destroyed-hunk decision geometry from BEFORE the first
	-- sequence -- boundaries the group law says belong to the earlier group.
	-- Measured on the real watcher before this partition:
	-- `SEQ_BATCH base=1 first=2 second=3 record_first=false
	-- record_second_before=1 rows=1` -- two sequences, one record, one register
	-- row. So the accumulator is keyed by the after-sequence the caller stamps
	-- on the change (`after_seq`), and `begin_group` selects one for the flush
	-- that interprets it.
	local key = group_key(marker)
	self.before_groups = self.before_groups or {}
	local group = self.before_groups[key]
	if group == nil then
		-- The state this group began from is the state the PREVIOUS group in the
		-- same flush ended on, not `current_seq`: a new marker appears only once
		-- that group's sequence was sealed, and nothing has advanced
		-- `current_seq` yet -- `finish` runs per group at flush time, and these
		-- captures all happen before it.
		local before_seq = self.current_seq
		if type(self.open_group_marker) == "number" then
			before_seq = self.open_group_marker
		end
		group = { before = before, before_seq = before_seq, marker = marker, shifted = {} }
		self.before_groups[key] = group
		if type(marker) == "number" then
			self.open_group_marker = marker
		end
	end
	change._ledger_before_seq = group.before_seq
	self.last_before = group.before
	self.last_before_seq = group.before_seq
	self.last_shifted = group.shifted
end

--- THE BLOCKS `shift_span` ACTUALLY MOVED, and no others.
---
--- The recorder below writes an absolute band for exactly this set. A hunk the
--- shift pass skipped -- one sitting ABOVE the edit -- did not move and needs no
--- inverse; recording it anyway would put a frame into the transition that names
--- a hunk the edit never touched, and the all-or-nothing rule would then refuse a
--- move over an unrelated death. `Ledger:record_buffer_change` hands the return
--- value of its own `shift_span` call straight in, so the recorded set is the
--- moved set by construction and cannot drift from it.
function History:note_shifted(marker, blocks)
	local group = self.before_groups and self.before_groups[group_key(marker)]
	if not group then
		return
	end
	for _, block in ipairs(blocks or {}) do
		group.shifted[block] = true
	end
	self.last_shifted = group.shifted
end

--- Select the capture group belonging to ONE native undo sequence, for the
--- flush that is about to interpret that sequence's changes. `last_before` and
--- `last_before_seq` -- what `record_destroyed_hunk` and `finish` read -- then
--- describe THAT sequence and no other.
--- A sequence with no captures at all (the ledger was closed when the callback
--- ran) selects nothing and dates its record from the observed sequence, which
--- is what a capture-free cycle did before this partition existed.
function History:begin_group(marker, seq)
	local key = group_key(marker)
	local group = self.before_groups and self.before_groups[key]
	self.current_group = key
	self.current_group_seq = seq
	if group then
		self.last_before = group.before
		self.last_before_seq = group.before_seq
		self.last_shifted = group.shifted
	else
		self.last_before = nil
		self.last_before_seq = self.current_seq
		self.last_shifted = nil
	end
	return group ~= nil
end

--- The sequence of the selected group, for callers that only have the LIVE
--- buffer sequence to hand (review_watch_batch reads it at flush time, by which
--- point a later sequence may already be current). Falls back to that reading
--- when no group is selected.
function History:group_seq(fallback)
	if type(self.current_group_seq) == "number" then
		return self.current_group_seq
	end
	return fallback
end

function History:before_for(block, changes)
	for _, change in ipairs(changes or {}) do
		local value = change._ledger_before and change._ledger_before[block]
		if value then
			return copied(value), change._ledger_before_seq
		end
	end
	return snapshot(block), self.current_seq
end

function History:remember(block, before, before_seq, after_seq)
	if type(after_seq) ~= "number" then
		return
	end
	local record = ensure_record(self, after_seq, before_seq)
	-- Several watcher flushes may belong to one Neovim undo sequence. Keep the
	-- first before-state and advance only the after-state -- and only for a hunk
	-- the transition began with (`before_members`).
	if record.before[block] == nil
		and (record.before_members == nil or record.before_members[block] ~= nil)
	then
		record.before[block] = copied(before)
	end
	record.after[block] = snapshot(block)
end

-- THE BYSTANDER'S OWN ABSOLUTE GEOMETRY, and only its geometry.
--
-- `record_buffer_change` shifts every pending hunk by ONE (row, delta) pair, and
-- that pair is not invertible. Neovim reports a native undo as the coarsest
-- change it can -- five restored rows arrive as one insert at the first of them
-- -- so a hunk sitting INSIDE the reported region is moved by the whole delta
-- when only part of it landed above the hunk. Measured on r_breaker_32 at seed
-- 70659: the gap row between the two `mid_c` children was deleted at row 7
-- (`delta=-1`, correct), and the undo that put it back arrived as
-- `first=3 last_orig=3 last_new=8` -- one uniform `delta=+5` that moved BOTH
-- hunks, closing the gap the restored row had just reopened.
--
-- So the inverse cannot be arithmetic; it has to be the remembered ABSOLUTE
-- band. It is written for EXACTLY the blocks `shift_span` returned
-- (`note_shifted`), keyed like an absorbed hunk's record -- which is also why it
-- cannot double-shift. `record_buffer_change`'s external shift still runs first
-- and this write lands ON TOP of it with absolute numbers, so the result is the
-- same whether the shift compensated correctly or not.
--
-- GEOMETRY, NOT STATE. A bystander was not absorbed and not destroyed: its
-- verdict, proposal and membership were never part of this transition, and
-- restoring those from a frame would undo decisions the buffer edit never made.
-- The flag rides on the frame so `restore_buffer_state` writes the span alone.
--
-- MEMBERSHIP AT FORWARD FINISH DOES NOT SELECT THE BEFORE-FRAMES. A forward
-- merge MUST finish with its parents absent -- `Ledger:merge` replaces them
-- (hunk_ledger_lifecycle.lua) -- so gating the record on "the ledger still owns
-- this block" threw away the frames of precisely the hunks whose bands the
-- merging edit had just moved. The parents are absent because the merge
-- succeeded, not because they are irrelevant, and the sequence they belong to is
-- the CAUSAL one: the group the shift happened in, which is what `group_seq`
-- names. BOTH directions restore membership before the native text moves
-- (`review_undo.lua`, `spend_buffer_edit`), so by the time these frames are
-- replayed the parents -- and, going forward, the split children -- are owned.
--
-- The AFTER side is the opposite case and is still gated on ownership: an absent
-- parent has no live band to snapshot, and a redo must not be handed a frame
-- naming a hunk the redone state does not contain.
function History:remember_shifted_geometry(after_seq, owns)
	if type(after_seq) ~= "number" or not self.last_shifted then
		return
	end
	local before_frames = self.last_before or {}
	local record = ensure_record(self, after_seq, self.last_before_seq)
	for block in pairs(self.last_shifted) do
		local before = before_frames[block]
		if before ~= nil and record.before[block] == nil
			and (record.before_members == nil or record.before_members[block] ~= nil)
		then
			local value = copied(before)
			value.geometry_only = true
			record.before[block] = value
		end
		-- An absorbed hunk's own `remember` owns the whole-state after-frame and
		-- must not be demoted to a geometry-only one.
		if owns(block) and (record.after[block] == nil or record.after[block].geometry_only) then
			local value = snapshot(block)
			value.geometry_only = true
			record.after[block] = value
		end
	end
end

-- Sequence transitions and reachability (`transition_for`, `knows`, `prune`,
-- `transition`, `apply`) live in hunk_ledger_buffer_transition.lua.
transition.install(History)

-- The end of one absorbed watcher cycle, and the ONE call that closes it. An
-- edit that moved the buffer but reached no hunk gets an EMPTY record here, so
-- its sequence is a proven frame-free transition rather than a hole (see
-- `transition_for`); the record set is then pruned against `reachable` in the
-- same call, so no observable moment exists in which the new record is written
-- but the dead ones are still held, or the reverse.
--
-- `reachable` is the CALLER's reading of the editor (`undotree()`): this object
-- holds no buffer and must not learn to. Omitting it -- or handing over a
-- failed read -- retains every record and reports the failed check rather than
-- guessing (see `prune`). Returns `dropped, pruned_ok`.
function History:finish(seq, reachable)
	if type(seq) == "number"
		and type(self.last_before_seq) == "number"
		and seq ~= self.last_before_seq
		and self.records[seq] == nil
	then
		ensure_record(self, seq, self.last_before_seq)
	end
	self:observe(seq)
	-- THIS SEQUENCE's group is over, so the capture it accumulated is over too:
	-- the next sequence's first `capture` starts a fresh one (see `capture`).
	-- Holding it would hand the NEXT group's destroyed-hunk decision geometry
	-- from a group that has already been recorded and pruned. A sibling group
	-- for a DIFFERENT sequence queued in the same flush survives untouched --
	-- its own `finish` closes it.
	if self.before_groups then
		if self.current_group ~= nil then
			self.before_groups[self.current_group] = nil
		else
			-- No group was selected: a caller that does not partition at all
			-- (which is every caller that predates `begin_group`) still gets the
			-- old whole-cycle clear.
			self.before_groups[false] = nil
		end
		if next(self.before_groups) == nil then
			self.open_group_marker = nil
		end
	end
	self.current_group = nil
	self.current_group_seq = nil
	self.last_before = nil
	self.last_shifted = nil
	return self:prune(reachable, seq)
end

-- `observe` ADVANCES to a real sequence and ignores anything else, because a
-- caller that cannot name one must not blank the observation. `rewind` is the
-- other direction: a move that did not stand puts the observed sequence back
-- to whatever it was, `nil` included.
function History:rewind(seq)
	self.current_seq = seq
	self.open_group_marker = nil
end

function History:snapshot(block)
	return snapshot(block)
end

return M
