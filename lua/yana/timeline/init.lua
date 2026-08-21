-- Timeline — the PINNED INTERFACE. Frozen before fan-out; lanes build against
-- this and nothing else.
--
-- WHAT THIS IS. A display INDEX over two existing authorities: Neovim's undo
-- tree for buffer states, and the diary for durable ones. It stores how to ASK
-- each authority to go back. It never decides what the bytes were, and it never
-- holds a byte snapshot — that would create a second authority and this module must not
-- reintroduce it (the timeline design contract).
--
-- THREE FACTS THE IMPLEMENTATION MUST NOT CONTRADICT, measured and reviewed:
--   1. a hunk decision moves no buffer bytes, so there is no undo state to
--      attach a boundary to;
--   2. `u`/`U`/`<C-r>` are released when the review closes;
--   3. an ACCEPTED review writes the real file BEFORE it closes; a REJECTED one
--      closes and writes nothing. `review_closed` NEVER implies `durable`.
--
-- THE CONSTRAINT THAT SHAPES THE SURFACE. `diary.revert_operation` verifies the
-- path still equals that operation's accepted result, so durable revert is
-- PER-PATH LIFO — newest-first for that path. Out-of-order same-path revert is
-- intentionally impossible and is presented as blocked, never attempted.
local M = {}

--- An entry. Bytes never appear here.
--- @class TimelineEntry
--- @field id string            correlation id, minted at intent
--- @field kind string          review_opened|hunk_accepted|hunk_rejected|human_edit|review_closed|applied
--- @field label string         what the operator reads
--- @field regime string        "buffer" | "durable" -- set where the event is recorded, never inferred
--- @field rel string           workspace-relative path this entry concerns
--- @field buffer_epoch string|nil  buffer rows: identifies the undo tree this
---   seq belongs to. CORRECTED 2026-08-19: the pin said `number` and the record
---   lane shipped an opaque per-buffer-lifetime STRING minted into a b:
---   variable, which is the better carrier -- it lives exactly as long as the
---   undo tree it describes and dies with :bwipeout, which is what makes
---   break-test T06's recreated-buffer refusal possible. The pin follows the
---   implementation here because the implementation is right and the pin was
---   arbitrary; the edit-capture lane built to the pin and was rewired at
---   integration, which is the cost of pinning a detail nobody had built yet.
--- @field undo_seq number|nil      buffer rows: the sequence to return to
--- @field expected_hash string|nil buffer rows: content expected at that seq; a mismatch REFUSES
--- @field diary_dir string|nil     durable rows: the diary this op lives in (op_id alone is not unique)
--- @field op_id string|nil         durable rows: `stream:sequence` within that diary

--- Append an entry in the `pending` state and return its correlation id.
--- Two-phase: the caller puts the SAME id into the diary intent, and the action
--- runs after. A failure here HALTS the action, like every durable record.
--- @return string|nil id, string|nil err
function M.intent(entry)
	return require("yana.timeline.record").intent(entry)
end

--- Append an already-true event and finish its fsync sequence asynchronously.
--- Durable actions must continue to use intent(), because they cannot start
--- until their intent is durable.
function M.intent_async(entry, callback)
	return require("yana.timeline.record").intent_async(entry, callback)
end

--- Entries for one file, oldest first. State is DERIVED, never stored: durable
--- rows are resolved against the diary's markers, which is the record that
--- survives a crash. The ledger cannot answer this -- it is in-memory with
--- bounded rings that DROP entries at capacity.
--- @return TimelineEntry[] entries   each with a resolved `state` field
function M.entries(workspace, rel)
	return require("yana.timeline.record").entries(workspace, rel)
end

--- Can this entry be walked to right now?
--- @return boolean ok, string|nil blocked_by  the id of the row that must go first
function M.reachable(workspace, rel, id)
	return require("yana.timeline.record").reachable(workspace, rel, id)
end

--- True while any review is open for this file. The ENTIRE surface is disabled
--- then: a raw `:undo` into an open review bypasses the decision unwind and
--- desynchronises buffer, decisions, authority marks and paint.
function M.review_open_for(workspace, rel)
	return require("yana.timeline.record").review_open_for(workspace, rel)
end

--- ADDITIVE (FIX-UNDO lane, 2026-08-21): the single most recent
--- not-yet-reverted row across every file in this workspace, or nil when
--- there is nothing left to undo. This is what cross-file `u`/`<C-r>` (once
--- a file's own review has closed) retrace against; see
--- `lua/yana/timeline/record.lua`'s `M.next_undo` for the full account. It
--- does not change the shape of anything already pinned above.
--- @return table|nil {rel, id, kind, global_seq}, string|nil err
function M.next_undo(workspace, exclude)
	return require("yana.timeline.record").next_undo(workspace, exclude)
end

--- ADDITIVE (FIX-UNDO lane, 2026-08-21): read-only head position -- see
--- `record.lua`'s `M.buffer_head` for the full account. Used by the
--- post-review `u`/`<C-r>` dispatcher to decide, precisely, whether a press
--- belongs to it or to Neovim's own undo.
function M.buffer_head(bufnr)
	return require("yana.timeline.record").buffer_head(bufnr)
end

--- ADDITIVE: the exact live position to compare against `buffer_head`.
--- Wraps `record.observe_buffer`, already public, for symmetry.
function M.observe_buffer(bufnr)
	return require("yana.timeline.record").observe_buffer(bufnr)
end

--- ADDITIVE: every workspace root this process has recorded a row for.
function M.known_workspaces()
	return require("yana.timeline.record").known_workspaces()
end

return M
