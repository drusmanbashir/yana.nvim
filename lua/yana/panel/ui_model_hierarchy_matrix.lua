-- Pure dimension-axis derivation for the model picker matrix.
-- The UI owns drawing/input; this module owns reachability and dim state.

local M = {}

-- F-MODEL-PICKER: presentation preference, independent of supported tokens.
local EFFORT_ORDER = {
	ultra = 1, max = 2, xhigh = 3, high = 4, medium = 5,
	low = 6, minimal = 7, none = 8,
}
local MODEL_FAMILIES = {
	astra = 1, sol = 2, terra = 3, luna = 4,
	fable = 1, opus = 2, sonnet = 3, haiku = 4,
}

local function model_preference(model)
	local rank = model:match("^gpt%-%d") and 3 or 99
	for token in model:gmatch("[^-]+") do
		if MODEL_FAMILIES[token] then rank = MODEL_FAMILIES[token]; break end
	end
	local version = {}
	for number in model:gmatch("%d+") do version[#version + 1] = tonumber(number) end
	return rank, version
end

local function sort_values(values, col)
	table.sort(values, function(a, b)
		if a == b then return false end
		if a == "-" then return false end
		if b == "-" then return true end
		if col == "model" then
			if a == "auto" then return false end
			if b == "auto" then return true end
			local ar, av = model_preference(a)
			local br, bv = model_preference(b)
			if ar ~= br then return ar < br end
			for i = 1, math.max(#av, #bv) do
				local an, bn = av[i] or 0, bv[i] or 0
				if an ~= bn then return an > bn end
			end
		end
		if col == "effort" or col == "reasoning" then
			local ar, br = EFFORT_ORDER[a] or 99, EFFORT_ORDER[b] or 99
			if ar ~= br then return ar < br end
		end
		return a < b
	end)
	return values
end

local function sorted_keys(set, col)
	local out = {}
	for value in pairs(set or {}) do
		out[#out + 1] = value
	end
	return sort_values(out, col)
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
		local values = sorted_keys(row.efforts, col)
		return #values > 0 and values or { "-" }
	end
	if col == "speed" then
		local values = sorted_keys(row.speeds, col)
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
	-- Descriptors constrain supported values; display preference orders them.
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
			return sort_values(out, col)
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
	return sorted_keys(set, col)
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
