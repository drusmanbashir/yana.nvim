-- Size split of hunk_ledger_buffer_history.lua: the frame values one record holds (copy, snapshot, copied).
local M = {}

local function copy_lines(lines)
	local out = {}
	for i, line in ipairs(lines or {}) do
		out[i] = line
	end
	return out
end

-- Owner entries are TABLES, so an array copy still shares them with the frame.
-- Nothing writes through one today -- `hunk_extent_anchor` rebuilds the list
-- entry by entry -- and this keeps it that way: a restored hunk and the record
-- it came from share no mutable value at all.
local function copy_owners(owners)
	if owners == nil then
		return nil
	end
	local out = {}
	for i, owner in ipairs(owners) do
		out[i] = { row = owner.row, source = owner.source, provisional = owner.provisional }
	end
	return out
end

-- THE BLOCK IS THE LIVE RECORD. A hunk's whole state already lives on one
-- table, so a frame copies that table rather than naming fields one at a time.
-- An inclusion list is what made this defect: `shape` used to carry four of the
-- block's eighteen fields, and a reversal cannot restore what was never
-- recorded, so the verdict and the red half came back wrong however correct the
-- replay was. Adding fields to a list one bug at a time repeats that. Copying
-- the record cannot miss a field that does not exist yet.
--
-- EXCLUDED, and this is the only judgement in the frame: extmark IDS are live
-- handles owned by the buffer, not values. The marks a destroyed hunk had are
-- deleted, and writing a stale id back would point the hunk at a mark that no
-- longer exists. Paint is re-derived after a restore, which is what recreates
-- them.
local EXTMARK_HANDLES = {
	authority_extmark_id = true,
	delete_extmark_id = true,
	incoming_extmark_id = true,
	incoming_extmark_ids = true,
}

local function copy_value(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = v
	end
	return out
end

-- `deep` false borrows table fields by reference instead of copying them. Safe
-- only for a frame that lives for the one `on_lines` cycle it was taken in,
-- because the ledger's writers REPLACE those arrays wholesale and never mutate
-- them in place.
local function frame_of(block, deep)
	local fields = {}
	for key, value in pairs(block) do
		if not EXTMARK_HANDLES[key] then
			if deep and key == "owned_rows" then
				-- The one field whose entries are tables. `copy_value` copies the
				-- array and would leave the frame sharing every owner with the live
				-- hunk -- measured: writing `block.owned_rows[1].row` after a
				-- compensating restore reached into the frame.
				fields[key] = copy_owners(value)
			else
				fields[key] = deep and copy_value(value) or value
			end
		end
	end
	return {
		block = block,
		fields = fields,
		-- Named separately because callers read them as geometry rather than as
		-- hunk state: `pre_edit_state`, the destroyed-hunk decision and the
		-- restore all ask "where was this hunk", not "what were its fields".
		model_index = block.model_index,
		-- The FROZEN copy of the hunk's name. A frame is resolved through this
		-- table, never through `block`: `block` is the dead hunk's own mutable
		-- table and anything may have written to it since the frame was taken.
		lineage_id = block.lineage_id,
		new_lines = fields.new_lines,
		old_lines = fields.old_lines,
		verdict = fields.verdict,
		start_line = block.new_start_line,
		end_line = block.new_end_line,
	}
end

local function snapshot(block)
	return frame_of(block, true)
end

local function snapshot_ref(block)
	return frame_of(block, false)
end

local function copied(value)
	if not value then
		return nil
	end
	local fields = {}
	for key, field in pairs(value.fields or {}) do
		fields[key] = key == "owned_rows" and copy_owners(field) or copy_value(field)
	end
	return {
		block = value.block,
		fields = fields,
		geometry_only = value.geometry_only,
		model_index = value.model_index,
		lineage_id = value.lineage_id,
		new_lines = fields.new_lines,
		old_lines = fields.old_lines,
		verdict = fields.verdict,
		start_line = value.start_line,
		end_line = value.end_line,
	}
end

M.copy_lines = copy_lines
M.copy_owners = copy_owners
M.snapshot = snapshot
M.snapshot_ref = snapshot_ref
M.copied = copied

return M
