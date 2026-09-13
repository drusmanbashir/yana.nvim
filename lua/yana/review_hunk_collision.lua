-- A ROW TWO PENDING HUNKS' ANCHORS SHARE (F-SPLIT-MERGE, ledger identity
-- rule 1). The one transform leaves both hunks' anchors on a row a splice
-- joined (`Ledger:take_anchor_collisions`, hunk_ledger_transport.lua); a row
-- cannot belong to two hunks, so the merge authority fuses them -- never a
-- winner picked by table order. Each record has `try_merge`'s shape
-- (review_hunk_split.lua), one per `Ledger:merge` call, and rides the joining
-- change's native sequence (review_watch_flush.lua).
local anchor_bounds = require("yana.hunk_ledger_settle").anchor_bounds

local M = {}

-- The base rows between the two hunks' old spans. The human deleted them to
-- join the rows, and reject puts them back, exactly as `try_merge` folds the gap
-- it merged across.
local function base_gap(state, a, b)
	local before = type(state.change) == "table" and state.change.before or ""
	local lines = vim.split(before, "\n", { plain = true })
	local out = {}
	for row = (a.end_line or ((a.start_line or 1) - 1)) + 1, (b.start_line or 0) - 1 do
		out[#out + 1] = lines[row]
	end
	return out
end

-- Both blocks' anchors, one entry per row (the upper block's on the shared row).
local function union(a, b)
	local by_row, rows = {}, {}
	for _, block in ipairs({ a, b }) do
		for _, owner in ipairs(block.owned_rows or {}) do
			if not by_row[owner.row] then
				by_row[owner.row] = { row = owner.row, source = owner.source, provisional = owner.provisional }
				rows[#rows + 1] = owner.row
			end
		end
	end
	table.sort(rows)
	local out = {}
	for i, row in ipairs(rows) do
		out[i] = by_row[row]
	end
	return out
end

--- Merge every still-pending pair that still shares its row. Returns the
--- structural records, in mutation order.
function M.merge(state, collisions)
	local ledger, records = state.hunk_ledger, {}
	for _, hit in ipairs(collisions or {}) do
		local a, b = hit.blocks[1], hit.blocks[2]
		if ledger:owns(a) and ledger:owns(b) and a.verdict == "pending" and b.verdict == "pending"
			and ledger:row_is_owned(a, hit.row) and ledger:row_is_owned(b, hit.row)
		then
			local lo_a, hi_a = anchor_bounds(a)
			local lo_b, hi_b = anchor_bounds(b)
			if lo_b < lo_a then
				a, b, lo_a, hi_a, lo_b, hi_b = b, a, lo_b, hi_b, lo_a, hi_a
			end
			local old_lines = vim.list_extend(vim.list_extend(vim.deepcopy(a.old_lines or {}), base_gap(state, a, b)),
				b.old_lines or {})
			local start_line = math.min(a.start_line or math.huge, b.start_line or math.huge)
			local hi = math.max(hi_a, hi_b)
			local merged = {
				old_lines = old_lines,
				new_lines = vim.api.nvim_buf_get_lines(state.bufnr, lo_a - 1, hi, false),
				start_line = start_line,
				end_line = start_line + #old_lines - 1,
				new_start_line = lo_a,
				new_end_line = hi,
				owned_rows = union(a, b),
			}
			local record = ledger:merge({ a, b }, merged)
			if type(record) == "table" then
				records[#records + 1] = {
					record = record,
					members = record.members,
					before = record.before,
					merged = merged,
					after = { model_index = merged.model_index, model_join = merged.model_join },
					change = hit.change,
				}
			end
		end
	end
	return records
end

return M
