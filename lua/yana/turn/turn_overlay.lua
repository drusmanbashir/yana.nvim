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
-- NOT replace the start overlay with already-mutated state.
function Overlay:add_file(file)
	local path = file and file.path
	if type(path) ~= "string" or self.by_path[path] ~= nil then
		return
	end
	self.by_path[path] = {
		text = file.overlay_text,
		has_text = file.overlay_text ~= nil,
		blocks = copy_blocks(file.ledger),
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
