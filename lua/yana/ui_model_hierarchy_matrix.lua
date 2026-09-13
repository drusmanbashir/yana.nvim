-- Pure dimension-axis derivation for the model picker matrix.
-- The UI owns drawing/input; this module owns reachability and dim state.

local M = {}

local function sorted_keys(set)
	local out = {}
	for value in pairs(set or {}) do
		out[#out + 1] = value
	end
	table.sort(out)
	return out
end

local function contains(values, wanted)
	for _, value in ipairs(values or {}) do
		if value == wanted then
			return true
		end
	end
	return false
end

function M.values_for_row(row, col)
	if col == "provider" then
		return row.provider and { row.provider } or {}
	end
	if col == "model" then
		return row.model and { row.model } or {}
	end
	if col == "effort" or col == "reasoning" then
		local values = sorted_keys(row.efforts)
		return #values > 0 and values or { "-" }
	end
	if col == "speed" then
		local values = sorted_keys(row.speeds)
		return #values > 0 and values or { "-" }
	end
	return {}
end

local function bare_raw(row)
	for _, raw in ipairs(row.raw_ids or {}) do
		if raw == row.model or raw == row.identity then
			return true
		end
	end
	return false
end

local function value_dim(row, col, value)
	if value == "-" and (col == "effort" or col == "reasoning") then
		return true
	end
	return value == "-" and col == "speed" and not bare_raw(row)
end

local function matches_before(session, row, col)
	for _, prior in ipairs(session.columns or {}) do
		if prior == col then
			break
		end
		local fixed = session.fixed[prior]
		if fixed and not contains(M.values_for_row(row, prior), fixed) then
			return false
		end
	end
	return true
end

function M.axis_values(session, col)
	-- Descriptor-declared ordered lists (e.g. claude --effort levels) win over
	-- alphabetical set order so the picker matches the vendor spelling table.
	do
		local ok, config = pcall(require, "yana.config")
		local bd = ok and session and config.backend_descriptor and config.backend_descriptor(session.backend)
		local tok = bd and bd.mode_tokens and bd.mode_tokens[col]
		local declared = tok and (tok.values or tok.levels)
		if type(declared) == "table" and #declared > 0 then
			local reachable = {}
			for _, row in ipairs(session.rows or {}) do
				if matches_before(session, row, col) then
					for _, value in ipairs(M.values_for_row(row, col)) do
						reachable[value] = true
					end
				end
			end
			local out = {}
			for _, value in ipairs(declared) do
				if reachable[value] then
					out[#out + 1] = value
				end
			end
			return out
		end
	end
	local set = {}
	for _, row in ipairs(session.rows or {}) do
		if matches_before(session, row, col) then
			for _, value in ipairs(M.values_for_row(row, col)) do
				set[value] = true
			end
		end
	end
	return sorted_keys(set)
end

function M.axis_dim(session, col, value)
	for _, row in ipairs(session.rows or {}) do
		if matches_before(session, row, col)
			and contains(M.values_for_row(row, col), value)
			and not value_dim(row, col, value) then
			return false
		end
	end
	return true
end

function M.rebuild_axes(session)
	session.axes = {}
	local longest = 1
	for _, col in ipairs(session.columns or {}) do
		session.axes[col] = M.axis_values(session, col)
		longest = math.max(longest, #session.axes[col])
	end
	session.data_rows = longest
	return session.axes
end

return M
