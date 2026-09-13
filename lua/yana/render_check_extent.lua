-- Size split of render_check.lua: the EXTENT vs MEMBERS check (F-OWN-PAINT-PARITY).
-- A pending hunk that owns rows spans exactly [first member row, last member
-- row]. Accept, reject and navigation act on that band, so it is checked apart
-- from the paint: correct paint cannot hide a wrong band. Installed onto
-- render_check, which registers the kind and extends `evaluate` for every caller.
local anchor_bounds = require("yana.hunk_ledger_settle").anchor_bounds

local M = {}

M.KIND = "extent_anchors"

--- One entry per pending block whose stated band differs from its members.
--- A block that owns no row, or states no end row, makes no claim to compare.
function M.violations(blocks)
	local out = {}
	for _, block in ipairs(blocks or {}) do
		local lo, hi = anchor_bounds(block)
		if lo and type(block.new_start_line) == "number" and type(block.new_end_line) == "number"
			and (block.verdict == nil or block.verdict == "pending")
			and (block.new_start_line ~= lo or block.new_end_line ~= hi)
		then
			out[#out + 1] = {
				kind = M.KIND,
				hunk = block.index,
				expected = lo .. ":" .. hi,
				got = tostring(block.new_start_line) .. ":" .. tostring(block.new_end_line),
			}
		end
	end
	return out
end

--- Registers the kind and extends `RC.evaluate`; the result's verdict, count
--- and signature are recomputed so a violation here reads like any other.
function M.install(RC)
	RC.KIND.extent_anchors = M.KIND
	local evaluate = RC.evaluate
	RC.evaluate = function(input)
		local result = evaluate(input)
		local found = M.violations(input and input.blocks)
		if #found > 0 then
			for _, v in ipairs(found) do
				result.violations[#result.violations + 1] = v
			end
			result.ok = false
			result.counts.violations = #result.violations
			result.signature = RC.signature(result)
		end
		return result
	end
	return RC
end

return M
