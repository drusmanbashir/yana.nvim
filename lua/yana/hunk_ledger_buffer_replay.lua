-- Size split of hunk_ledger_buffer_history.lua: the Ledger methods that replay buffer history.
local hunk_identity = require("yana.hunk_identity")
local transport = require("yana.hunk_ledger_transport")
local frame = require("yana.hunk_ledger_buffer_frame")

local M = {}

local copy_owners = frame.copy_owners
local copied = frame.copied

local function count_keys(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

function M.install(Ledger, env)
	local assert_open = env.assert_open

	function Ledger:observe_buffer_seq(seq)
		self.buffer_history:observe(seq)
	end

	-- The transport of one buffer edit onto the ledger's blocks
	-- (`record_buffer_change`, `carry_through`) is hunk_ledger_transport.lua.
	transport.install(Ledger, env)

	-- A completed edit (`hunk_ledger_settle.lua`) records through `before_for`,
	-- `remember` and `group_seq` above: the partitioned InsertLeave absorb dates
	-- its frame from the sequence the burst departed from, and a flush that
	-- interprets an EARLIER sequence's group keys its frame on that group's own
	-- sequence rather than the live one.

	-- ONE atomic close for one absorbed watcher cycle: the explicit record and
	-- the reachability prune, in that order, under one call. They were two
	-- calls, and between them the ledger held records for native states the
	-- buffer had already discarded.
	--
	-- `reachable` comes from the caller because the caller owns the buffer.
	-- `hunk_ledger.open` deliberately takes no `bufnr`: this layer is pure
	-- bookkeeping and reads no editor state. Omitted or unreadable, every
	-- record is retained and the failed check is reported (`prune`).
	function Ledger:finish_buffer_changes(undo_seq, reachable)
		-- Before the group is closed and its capture dropped: every hunk this
		-- group's shift pass MOVED gets its absolute pre-edit band remembered
		-- against the group's own causal sequence (`remember_shifted_geometry`).
		-- Absorbed and destroyed hunks already hold a whole-state frame from
		-- their own `remember` and keep it.
		local history = self.buffer_history
		history:remember_shifted_geometry(history:group_seq(undo_seq), function(block)
			return self:owns(block)
		end)
		return history:finish(undo_seq, reachable)
	end

	--- Open the capture group for ONE native undo sequence before interpreting
	--- its changes. The watcher calls this once per sequence group in a flush;
	--- `finish_buffer_changes` for the same sequence closes it.
	--- The native sequence this ledger last finished a buffer group on. The
	--- watcher needs it to tell a sealed boundary marker from one still in
	--- flight (review_watch.lua); nothing here reads a buffer to answer it.
	function Ledger:observed_buffer_seq()
		return self.buffer_history.current_seq
	end

	function Ledger:begin_buffer_group(marker, undo_seq)
		return self.buffer_history:begin_group(marker, undo_seq)
	end

	--- Drop every record for a native undo state the buffer can no longer reach.
	--- The reachable set is the buffer's, so the caller that owns the buffer
	--- passes it (review_watch.lua); the ledger holds no buffer of its own.
	function Ledger:prune_buffer_history(reachable)
		return self.buffer_history:prune(reachable)
	end

	-- The destroy counterpart of `complete_buffer_edit`. An absorbed edit records
	-- itself through that function; a hunk deleted outright absorbs nothing, so
	-- without this call `remember` is never reached for it and the keyed history
	-- holds NO record of the destruction -- leaving the replay nothing to restore
	-- and the hunk outside the pending set after one undo. Same `remember`, same
	-- keying by undo sequence: the destruction is just another transition.
	function Ledger:record_destroyed_hunk(block, undo_seq)
		local before = self.buffer_history.last_before and self.buffer_history.last_before[block] or nil
		if not before then
			return false
		end
		self.buffer_history:remember(
			block, before, self.buffer_history.last_before_seq,
			self.buffer_history:group_seq(undo_seq))
		return true
	end

	-- The recorded state of `block` as it stood BEFORE the current buffer
	-- change, or nil if this ledger has recorded none. The destroyed-hunk
	-- decision runs after the shift pass, so its own `block.new_start_line` is
	-- already the post-shift number; this is the only route back to the
	-- geometry a single undo has to restore. Identity is the block itself, never
	-- a row anchor, which is exactly what a shift invalidates.
	function Ledger:pre_edit_state(block)
		local frames = self.buffer_history.last_before
		local value = frames and frames[block] or nil
		if not value then
			return nil
		end
		return copied(value)
	end

	-- Which live hunk a recorded frame belongs to. Identity first, because the
	-- same table surviving the move is proof. After a park/resume rebuild the
	-- recorded table is gone, and then the answer is `hunk_identity`'s -- THE one
	-- rule, the same one the redo's decision rebind uses
	-- (undo_action_buffer_edit.lua), so the two can never disagree about the same
	-- recorded hunk.
	local function resolve_frame(self, value)
		if self:owns(value.block) then
			return { block = value.block, provenance = "identity" }
		end
		-- The FRAME, not `value.block`. The block is the dead hunk's own table and
		-- stays mutable after the frame is taken -- a rebuild, a split or a
		-- membership move can rewrite the very fields the resolution reads. The
		-- frame froze them at capture, which is the whole reason it exists.
		local found, matches = hunk_identity.resolve_unique(self.hunks, value)
		if not found or not self:owns(found) then
			return { block = nil, provenance = "missing", matches = matches }
		end
		return { block = found, provenance = "identity_rule" }
	end

	-- One native history move reverses ONE atomic ledger transition, so the
	-- frames it carries are a group and are restored ALL OR NOTHING: every frame
	-- is resolved to a live hunk FIRST, and only a transition that resolves
	-- whole is applied. Restoring the resolvable half would leave the ledger in a
	-- state no forward edit ever produced -- some hunks back at their pre-edit
	-- verdict and geometry, their siblings still at the post-edit one -- which is
	-- precisely the re-decomposition an atomic group must never suffer.
	function Ledger:restore_buffer_history(direction, undo_seq, on_restore)
		local transition = self.buffer_history:transition(direction, undo_seq)
		-- A HOLE IS NOT AN EMPTY TRANSITION. An edit this ledger watched and
		-- absorbed into no hunk HAS a record -- an empty one, written by
		-- `finish` -- and advancing over it is right. A sequence with no record
		-- at all is the other thing: nothing is known about what that native
		-- move did on this side, and advancing anyway moved bytes and history
		-- while the ledger stood still, leaving every later transition read
		-- against the wrong sequence. Refuse, exactly like a transition that
		-- cannot be named whole below.
		local at = direction == "undo" and self.buffer_history.current_seq or undo_seq
		if not self.buffer_history:knows(at) then
			error(string.format(
				"hunk_ledger: %s has no recorded transition for sequence %s",
				tostring(direction), tostring(at)), 0)
		end
		local resolved, unresolved = {}, 0
		for key, value in pairs(transition.values or {}) do
			local resolution = resolve_frame(self, value)
			if resolution.provenance == "missing" then
				-- A GEOMETRY-ONLY frame is refused like any other. It names a hunk
				-- this transition really did move, and a move that cannot put every
				-- band back leaves the same half-reversed state the all-or-nothing
				-- rule below exists to forbid -- skipping it quietly would advance
				-- the observed sequence over geometry nobody restored.
				unresolved = unresolved + 1
			else
				resolved[key] = resolution
			end
		end
		-- ALL OR NOTHING, and "nothing" means the MOVE does not stand. Suppressing
		-- the hunk writes while `apply` advanced the observed sequence -- and the
		-- caller went on to move its decisions, repaint and report success -- left
		-- bytes, history position and decisions forward of a ledger that had not
		-- moved: the same re-decomposition the group law exists to forbid, one
		-- level up. So a transition that cannot be named WHOLE raises, and
		-- `undo_action_native.lua`'s settle transaction puts the bytes back.
		--
		-- A transition with no frames at all is not this case: an edit the ledger
		-- absorbed into no hunk has nothing to restore and legitimately advances.
		if unresolved > 0 then
			error(string.format(
				"hunk_ledger: %s cannot name %d of %d recorded hunk(s) in this transition",
				tostring(direction), unresolved, unresolved + count_keys(resolved)), 0)
		end
		self.buffer_history:apply(transition, function(value, key)
			local resolution = resolved[key]
			if resolution then
				self:restore_buffer_state(resolution.block, value)
				if on_restore then on_restore(resolution.block, resolution.provenance) end
			end
		end)
	end

	-- Writes the recorded block back WHOLESALE. The frame is a copy of the hunk's
	-- own table, so this restores every field it had -- including ones added to a
	-- block after this function was written, which is the point: the previous
	-- version restored four named fields and silently dropped the rest.
	--
	-- The geometry and proposal still go through their own writers so `set_span`
	-- keeps its span bookkeeping; everything else is a plain field the ledger
	-- owns. Extmark handles were never captured (see EXTMARK_HANDLES) and so are
	-- left alone for the repaint to recreate.
	function Ledger:restore_buffer_state(block, value)
		-- Exact frame restoration wins over a carried departure (`carry_through`).
		if self.frame_restored then
			self.frame_restored[block] = true
		end
		if value.geometry_only then
			-- The bystander's band and nothing else -- see
			-- `remember_shifted_geometry`.
			--
			-- AND THE BAND IS TWO FACTS, NOT ONE. The span says where the hunk
			-- sits; the per-row anchors say which rows inside it are its own, and
			-- the paint is derived from THOSE (`hunk_extent_anchor`,
			-- `hunk_extent.runs`). The ownership boundary is part of the record
			-- for exactly this reason. Restoring
			-- the span alone left the reverse native move's walk of the anchors
			-- standing -- measured on the split-undo bounce, the parent came back
			-- spanning rows 1-3 while owning only row 1 -- so the band and the
			-- text disagreed and the next Enter could not split.
			--
			-- Verdict, proposal and membership are still untouched: they were
			-- never part of this frame, and this is the geometry it always was.
			local fields = value.fields or {}
			local first = value.start_line
			if first ~= nil then
				self:set_span(block, first, value.end_line or (first - 1))
			end
			if fields.owned_rows ~= nil then
				block.owned_rows = copy_owners(fields.owned_rows)
			end
			return
		end
		local fields = value.fields
		if not fields then
			-- A frame from before frames carried the whole block.
			self:set_new_lines(block, value.new_lines or {})
			if value.start_line ~= nil then
				self:set_span(block, value.start_line, value.end_line or (value.start_line - 1))
			end
			return
		end
		for key, field in pairs(fields) do
			if key ~= "new_lines" and key ~= "new_start_line" and key ~= "new_end_line" and key ~= "verdict" then
				-- Same reason as the geometry branch: the owner entries are tables,
				-- and handing the hunk the frame's own entries makes the record
				-- writable through the hunk.
				block[key] = key == "owned_rows" and copy_owners(field) or field
			end
		end
		self:set_new_lines(block, fields.new_lines or {})
		if fields.new_start_line ~= nil then
			self:set_span(block, fields.new_start_line, fields.new_end_line or (fields.new_start_line - 1))
		end
		-- Last, because it can move the hunk back INTO the pending set and the
		-- writers above refuse nothing on a decided hunk: the restored hunk stays
		-- consistent at every intermediate step.
		if fields.verdict ~= nil and block.verdict ~= fields.verdict then
			self:restore_verdict(block, fields.verdict)
		end
	end

	-- A park/resume that cannot reuse the parked state builds a NEW ledger over
	-- the SAME buffer, and Neovim's undo history for that buffer is untouched by
	-- the park -- so a `u` after the resume asks this ledger to reverse a
	-- sequence the OLD one recorded. A fresh `buffer_history` holds no record of
	-- it, `transition` answers "none", and the bytes move with nothing following
	-- them on the ledger side. The resumed ledger therefore ADOPTS the parked
	-- one's history, frames and observed sequence intact; the frames name dead
	-- block tables, which is exactly what `resolve_frame` is for.
	function Ledger:adopt_buffer_history(history)
		if type(history) ~= "table" or type(history.transition) ~= "function" then
			return false
		end
		self.buffer_history = history
		return true
	end

	-- Everything a native history move can move on THIS side of the buffer,
	-- taken before that move. Ledger-owned because only the ledger may read a
	-- hunk's fields; the caller holds the return value opaquely and hands it
	-- straight back to `restore_buffer_snapshot`.
	function Ledger:capture_buffer_snapshot()
		local frames = {}
		for _, block in ipairs(self:members()) do
			frames[#frames + 1] = self.buffer_history:snapshot(block)
		end
		return { seq = self.buffer_history.current_seq, frames = frames }
	end

	-- The inverse: every framed hunk this ledger still owns is written back
	-- through the SAME `restore_buffer_state` the history replay uses, then the
	-- observed sequence is rewound. `on_restore(block)` is the caller's hook for
	-- state the ledger does not own (the model mirror), same shape as
	-- `restore_buffer_history`'s.
	function Ledger:restore_buffer_snapshot(snapshot, on_restore)
		for _, value in ipairs(snapshot and snapshot.frames or {}) do
			if self:owns(value.block) then
				self:restore_buffer_state(value.block, value)
				if on_restore then on_restore(value.block) end
			end
		end
		self.buffer_history:rewind(snapshot and snapshot.seq or nil)
	end
end

return M
