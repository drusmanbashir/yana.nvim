-- Immutable turn-start overlay for `U`.
-- Owns the retained bytes and hunk membership; Turn remains lifecycle-only.
local hunk_ledger = require("yana.hunk_ledger")

local M = {}
local Overlay = {}
Overlay.__index = Overlay

local function copy_blocks(ledger)
	local out = {}
	if not ledger then
		return out
	end
	for i, block in ipairs(ledger:members()) do
		out[i] = hunk_ledger.scrub_paint(vim.deepcopy(block))
	end
	return out
end

function M.new(files)
	local self = setmetatable({ by_path = {} }, Overlay)
	for _, file in ipairs(files or {}) do
		self:add_file(file)
	end
	return self
end

-- Capture once. A later open/materialize refreshes the live ledger but MUST
-- NOT replace the start overlay with already-mutated state. Intake captures
-- before the review exists; the file's first attached review then supplies
-- the change model its start hunks join (`U` re-stamps them against it).
function Overlay:add_file(file)
	local path = file and file.path
	local saved = type(path) == "string" and self.by_path[path] or nil
	if saved then
		if saved.model == nil and file.review_state and file.review_state.model_hunks then
			saved.model = require("yana.review_hunk_split").snapshot_model(file.review_state.model_hunks)
			saved.model_source = file.review_state.model_source
		end
		return
	end
	if type(path) ~= "string" then
		return
	end
	self.by_path[path] = {
		text = file.overlay_text,
		has_text = file.overlay_text ~= nil,
		blocks = copy_blocks(file.ledger),
		model = file.review_state and require("yana.review_hunk_split").snapshot_model(file.review_state.model_hunks),
		model_source = file.review_state and file.review_state.model_source,
	}
end

function Overlay:get(path)
	local saved = self.by_path[path]
	if not saved then
		return nil
	end
	local blocks = {}
	for i, block in ipairs(saved.blocks) do
		blocks[i] = hunk_ledger.scrub_paint(vim.deepcopy(block))
	end
	return {
		text = saved.text,
		has_text = saved.has_text,
		blocks = blocks,
		model = vim.deepcopy(saved.model),
		model_source = saved.model_source,
	}
end

function Overlay:remove_file(path)
	if self.by_path[path] == nil then
		return false
	end
	self.by_path[path] = nil
	return true
end

return M
