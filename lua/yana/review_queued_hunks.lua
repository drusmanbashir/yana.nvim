--
-- Verbatim: "per-file doors decide ALL yana hunks (queued files' hunks
-- materialized; absorbed human edits are yana's and cA MUST store them) ...
-- hunk build stays sync in-process."
--
-- Two things were wrong with that. The operator's edit was treated as an obstacle
-- rather than as content yana owns, and the file's hunks were never decided, so the
-- turn had no honest pending count to close on.
--
-- This module runs the SAME build a review open runs -- `build_diff_blocks` over
-- (`change.before`, `model_target(change)`) -- synchronously, in this process, no
-- buffer and no review.
--
-- It writes no verdict and touches no disk. The caller decides
-- (`ledger:decide_all("accept")`) only once the applier has actually taken the
-- bytes, so a refused write leaves the turn's pending count honest.
local hunk_ledger = require("yana.hunk_ledger")

local M = {}

-- THE OPERATOR'S VERSION OF A QUEUED FILE IS THE BYTES ON DISK. Deliberately
-- not the live buffer, even a modified one, and the reason is the applier: the
-- diary re-reads the file and validates `change.base_hash` one step before it
-- renames, so a composition built over buffer text the CAS never saw would be a
-- silent substitution of one source for another at the only point that checks.
-- Composing over what is actually there keeps the check meaningful.
--
-- Nothing of theirs is lost either way.
--
-- nil means unreadable (a create, a file the agent is deleting), which the
-- caller reads as "no drift to absorb".
function M.operator_text(diff, path)
	return diff.read_file_bytes(path)
end

--- Builds one queued change's ledger and the bytes accepting it must write.
---
--- @return table|nil ledger        every materialized hunk, all still pending
--- @return string|nil composed     bytes to write (nil for a delete)
--- @return table conflicted        hunks the operator's edit overlaps, by name
--- @return string|nil err          a composition that could not be relocated
--- @return string|nil absorbed_from the operator's own bytes, when there WAS an
---         edit to absorb — the caller advances the change's base evidence to
---         them, because the applier's CAS is against the file as it now is
function M.materialize(deps, change)
	local facade = deps.facade
	local diff = deps.diff
	local absorb = deps.absorb_review_blocks_over_drift
	local model_target = deps.model_target

	if change.kind == "delete" then
		-- A deletion has no target side to diff: there are no yana hunks to decide,
		-- and the empty ledger is still adopted so the turn counts it as settled.
		return hunk_ledger.open({}), nil, {}, nil
	end

	if change.after == nil then
		return nil, nil, {}, "queued change has no after content"
	end
	local target = model_target(change)
	local base = change.before or ""
	-- The same diff a review open runs (review_open.lua's `build_diff_blocks`
	-- call), minus the model stamp: nothing rebuilds a ledger that is decided and
	-- discarded inside one press, and `model_index` is a rebuild's identity key
	-- (A4). Geometry and verdicts are all this ledger is asked for.
	local blocks = facade.build_diff_blocks(base, target)

	local now = M.operator_text(diff, change.path)
	if now == nil or now == base then
		-- NO DRIFT. `change.after` IS the composition, byte for byte -- the path every
		-- unedited queued file has always taken, returned verbatim rather than recomposed so
		-- this seam cannot change what an untouched file receives. `target` is deliberately
		-- NOT used here: `model_target` strips a created file's trailing newline for the
		-- DIFF's sake (lua/yana/review_model.lua's own note), and writing that stripped
		-- string would silently drop the newline off every queued create.
		return hunk_ledger.open(blocks), change.after, {}, nil, nil
	end

	local composed, _, conflicted, err = absorb(base, now, blocks)
	if not composed then
		return nil, nil, {}, err or "conflict: could not absorb the operator's edit", nil
	end
	return hunk_ledger.open(blocks), composed, conflicted or {}, nil, now
end

-- The refusal text for the hunks an operator's edit sits inside.
function M.conflict_reason(change, conflicted)
	local rows = {}
	for _, block in ipairs(conflicted or {}) do
		rows[#rows + 1] = tostring(block.new_start_line or block.start_line or "?")
	end
	return string.format(
		"refused %d hunk(s) — your edit sits inside them (line %s); the rest of %s is untouched and still queued",
		#(conflicted or {}),
		table.concat(rows, ", "),
		change.rel or change.path or "?"
	)
end

return M
