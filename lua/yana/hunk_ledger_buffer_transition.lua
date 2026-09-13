-- Size split of hunk_ledger_buffer_history.lua: sequence transitions and reachability (transition, knows, prune, apply).
local copied = require("yana.hunk_ledger_buffer_frame").copied

local M = {}
-- Installed onto the History metatable of hunk_ledger_buffer_history.lua.
local History = {}

-- "none" is a PROVEN frame-free transition -- an edit this ledger watched and
-- absorbed into no hunk -- and it legitimately advances the observed sequence.
-- A sequence this history has no record of at all is not that: it is a hole,
-- and answering "none" for it let a move advance history over a transition
-- nobody can replay. So a missing record INSIDE the recorded span answers
-- "absent", which the caller refuses. Every absorbed cycle writes its record,
-- empty or not (`finish`), so a hole is a genuine loss of the record.
local function transition_for(self, direction, observed_seq)
	if type(observed_seq) ~= "number" or type(self.current_seq) ~= "number" then
		return { direction = "none", seq = observed_seq }
	end
	if direction == "undo" then
		local record = self.records[self.current_seq]
		if record and record.before_seq == observed_seq then
			return { direction = "undo", seq = observed_seq, values = record.before }
		end
	elseif direction == "redo" then
		local record = self.records[observed_seq]
		if record and record.before_seq == self.current_seq then
			return { direction = "redo", seq = observed_seq, values = record.after }
		end
	end
	return { direction = "none", seq = observed_seq }
end

--- Does this history KNOW what happened at `seq`? Three answers, not two:
---  * it holds a record -- frames or an explicit empty one -- and knows.
---  * it holds records, and `seq` sits inside the span of the ones it holds
---    but has none of its own: a HOLE. Nothing is known about it and the
---    caller must refuse.
---  * `seq` lies outside that span, or this history has records for nothing at
---    all and never watched a single edit. Sequences older or newer than a
---    ledger's own bookkeeping are not its to explain -- a review attaches to a
---    buffer that already has a history -- so they are unknown-but-legitimate
---    and a move over them advances. A history holding NOTHING is the one
---    exception: it has no bookkeeping to be outside of, so it can honour no
---    move at all.
function History:knows(seq)
	if type(seq) ~= "number" then
		return true
	end
	if self.records[seq] ~= nil then
		return true
	end
	local lo, hi = nil, nil
	for _, s in ipairs(self.record_seqs or {}) do
		if self.records[s] ~= nil then
			if lo == nil or s < lo then lo = s end
			if hi == nil or s > hi then hi = s end
		end
	end
	if lo == nil then
		return false
	end
	return seq < lo or seq > hi
end

--- Records die with the native undo states they describe, and this is THE
--- bound on the record set. `reachable` is the set of sequences the buffer's
--- own undo tree can still land on (`undotree()`, `alt` branches included):
--- everything else names a transition no native move can ever ask for again,
--- and holding it keeps whole hunk snapshots alive for nothing.
---
--- NO REACHABLE SET, NO PRUNING. The caller owns the buffer and may fail to
--- read `undotree()` (an invalid buffer, a failed `nvim_buf_call`). Every
--- guess available here is wrong: dropping the oldest deletes history the tree
--- may still reach, and dropping nothing silently is a leak nobody can see. So
--- the records are RETAINED and the failed check is recorded on the history
--- (`prune_failed`, and `prune_failures` counting how often) for the caller and
--- any diagnostic to read. Returns `dropped, ok`.
--- `protect` is the sequence the buffer is sitting on at the moment of the
--- call: it is reachable by construction and is never pruned, so a record and
--- the prune that follows it in one `finish` cannot cancel each other out.
function History:prune(reachable, protect)
	if type(reachable) ~= "table" then
		self.prune_failed = true
		self.prune_failures = (self.prune_failures or 0) + 1
		return 0, false
	end
	self.prune_failed = false
	local dropped = 0
	for seq in pairs(self.records) do
		if not reachable[seq] and seq ~= protect then
			self.records[seq] = nil
			dropped = dropped + 1
		end
	end
	if dropped > 0 then
		local kept = {}
		for _, seq in ipairs(self.record_seqs or {}) do
			if self.records[seq] ~= nil then
				kept[#kept + 1] = seq
			end
		end
		self.record_seqs = kept
	end
	return dropped, true
end

-- Total query: always names the transition, including "none".
function History:transition(direction, observed_seq)
	return transition_for(self, direction, observed_seq)
end

-- Command: restore the transition selected above, then advance the observed
-- sequence. `restore` is HunkLedger's writer; this object never writes hunks.
function History:apply(transition, restore)
	if transition.direction ~= "none" then
		for key, value in pairs(transition.values or {}) do
			-- The key travels with the value so the writer can carry a decision
			-- it made about this frame BEFORE the loop started -- see the
			-- all-or-nothing resolution in `restore_buffer_history`.
			restore(copied(value), key)
		end
	end
	if type(transition.seq) == "number" then
		self.current_seq = transition.seq
		-- A native move dates nothing: see `observe`. Undo never calls it, so
		-- without this the orphan survives the whole walk.
		self.open_group_marker = nil
	end
end

function M.install(target)

	for name, fn in pairs(History) do

		target[name] = fn

	end

end



return M
