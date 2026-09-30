--
-- Verbatim: "per-file doors decide ALL yana hunks (queued files' hunks
-- materialized; absorbed human edits are yana's and cA MUST store them) ...
-- hunk build stays sync in-process."
--
-- This module runs the SAME build a review open runs -- `build_diff_blocks` over
-- (B0, `model_target(change)`) -- synchronously, in this process, no review.
--
-- THE USER'S VERSION OF A QUEUED FILE IS B1, the buffer as it was when the agent
-- finished (`change.buf_updated`), never the file on disk. Each agent edit is
-- placed on B1 by the extmarks set at submit (`review_ownership.place_on_b1`),
-- so an edit you made while the agent worked is kept and never refused. When
-- the extmarks cannot be used the file falls back to B0 against the agent's
-- revision.
--
-- It writes no verdict and touches no disk. The caller records the decision;
-- End later saves it through the buffer.
local hunk_ledger = require("yana.hunk_ledger")

local M = {}

-- Text as buffer lines: a final newline ends the last line, it is not a line.
local function lines_of(text)
	local lines = vim.split(text, "\n", { plain = true })
	if text:sub(-1) == "\n" then
		table.remove(lines)
	end
	return lines
end

-- B1 with every placed block's new lines in its place: the text the file
-- shows when every agent edit is taken.
-- The blocks are in file order, and a restored parent's lines may be inserted at
-- the same B1 row as the agent's edit, so the last block is applied first.
local function compose(b1, blocks)
	local lines = lines_of(b1)
	for index = #blocks, 1, -1 do
		local block = blocks[index]
		local first, count = block.start_line, #(block.old_lines or {})
		local out = {}
		for index = 1, first - 1 do out[#out + 1] = lines[index] end
		for _, line in ipairs(block.new_lines or {}) do out[#out + 1] = line end
		for index = first + count, #lines do out[#out + 1] = lines[index] end
		lines = out
	end
	local text = table.concat(lines, "\n")
	if #lines > 0 and b1:sub(-1) == "\n" then
		text = text .. "\n"
	end
	return text
end

-- B1 for this record: `buf_updated`, read again from the buffer when it moved
-- after the agent finished, because the extmarks follow the buffer as it is
-- now (the same rule a review open applies to a queued file).
local function b1_of(change)
	local snap = change.buffer_capture
	local bufnr = snap.bufnr
	if type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
		and change.tick_done ~= nil and vim.api.nvim_buf_get_changedtick(bufnr) ~= change.tick_done
	then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local text = table.concat(lines, "\n")
		if vim.bo[bufnr].endofline and #lines > 0 then
			text = text .. "\n"
		end
		return text
	end
	return change.buf_updated
end

--- Buffer drift stage 3 (INTERFACE.md sections 2, 3 and 5), shared with a
--- review open: after placement, a parent the operator deleted around an agent
--- edit comes back with it. Only where there is a conflict: a snapshot with no B0
--- line flagged deleted returns `placed` with no Tree-sitter work at all. Each
--- placed edit asks `parent_decision`; edits whose restored parents share the same
--- outermost one form one group, and every block of it carries its `group_id`.
--- Returns the blocks in file order, new-file rows recomputed.
function M.restore_parents(placed, snap, b1_lines)
	local deleted = false
	for _, m in ipairs(vim.api.nvim_buf_get_extmarks(snap.bufnr, snap.ns, 0, -1, { details = true })) do
		if m[4].invalid then
			deleted = true
			break
		end
	end
	if not deleted then
		return placed
	end
	local ownership = require("yana.review_ownership")
	local lang = vim.treesitter.language.get_lang(vim.bo[snap.bufnr].filetype)
	local groups, keys = {}, {}
	for _, block in ipairs(placed) do
		-- The rules take the edit in its original B0 rows, which the placed copy
		-- keeps only in `b0_span` (stamped before placement).
		local b0_edit = setmetatable({ start_line = block.b0_span.start_line, end_line = block.b0_span.end_line },
			{ __index = block })
		local decision = ownership.parent_decision(b0_edit, snap, snap.bufnr, lang)
		local parents = decision and decision.kind == "restore" and decision.parents or {}
		if #parents > 0 then
			local key = "restore:" .. parents[#parents].header_row
			if not groups[key] then
				groups[key] = { kind = "restore", parents = {}, edits = placed }
				keys[#keys + 1] = key
			end
			vim.list_extend(groups[key].parents, parents)
			block.group_id = key
		end
	end
	if #keys == 0 then
		return placed
	end
	local out, restored = vim.list_slice(placed), {}
	for _, key in ipairs(keys) do
		for _, block in ipairs(ownership.restore_blocks(groups[key], snap, b1_lines)) do
			block.group_id = key
			restored[block] = true
			out[#out + 1] = block
		end
	end
	-- File order: by B1 row, then by B0 line; at one spot the agent's insertion
	-- before a B0 line goes ahead of a restored run starting at that line.
	table.sort(out, function(a, b)
		if a.start_line ~= b.start_line then
			return a.start_line < b.start_line
		end
		if a.b0_span.start_line ~= b.b0_span.start_line then
			return a.b0_span.start_line < b.b0_span.start_line
		end
		return not restored[a] and restored[b] == true
	end)
	local base = 0
	for _, block in ipairs(out) do
		block.new_start_line = block.start_line + base
		block.new_end_line = block.new_start_line + #(block.new_lines or {}) - 1
		base = base + #(block.new_lines or {}) - #(block.old_lines or {})
	end
	return out
end

--- Builds one queued change's ledger and the text it shows with every agent
--- edit taken.
---
--- @return table|nil ledger    every materialized hunk, all still pending
--- @return string|nil composed text with every hunk taken (nil for a delete)
--- @return string|nil err      why no ledger could be built
--- @return string base         the text the ledger's rows are counted in: B1
---         when the edits were placed on it, else B0. End starts from it.
function M.materialize(deps, change)
	local facade = deps.facade
	local model_target = deps.model_target
	local b0 = change.buf_org or change.review_before or change.before or ""

	if change.kind == "delete" then
		-- A deletion has no target side to diff: there are no yana hunks to decide,
		-- and the empty ledger is still adopted so the turn counts it as settled.
		return hunk_ledger.open({}), nil, nil, b0
	end
	if change.after == nil then
		return nil, nil, "queued change has no after content", b0
	end
	local blocks = facade.build_diff_blocks(b0, model_target(change))
	-- The B0 rows each edit was built on, as a review open stamps them.
	for _, block in ipairs(blocks) do
		block.b0_span = { start_line = block.start_line, end_line = block.end_line }
	end

	if type(change.buffer_capture) == "table" and type(change.buf_updated) == "string" then
		local b1 = b1_of(change)
		local placed = require("yana.review_ownership").place_on_b1(blocks, change.buffer_capture, lines_of(b1))
		if placed ~= nil then
			placed = M.restore_parents(placed, change.buffer_capture, lines_of(b1))
			-- With no drift the placed blocks are B0's, and `change.after` is the
			-- composition byte for byte: returned verbatim so an untouched file
			-- receives exactly what it always did.
			local composed = b1 == b0 and change.after or compose(b1, placed)
			return hunk_ledger.open(placed), composed, nil, b1
		end
	end

	-- NO SNAPSHOT, OR THE EXTMARKS COULD NOT BE USED: B0 against the agent's
	-- revision. `change.after` is the composition, returned verbatim --
	-- `model_target` strips a created file's trailing newline for the DIFF's
	-- sake (lua/yana/review_model.lua's own note), and writing that stripped
	-- string would silently drop the newline off every queued create.
	return hunk_ledger.open(blocks), change.after, nil, b0
end

return M
