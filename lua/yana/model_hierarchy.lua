--
-- Builds family rows from raw list / JSON / static catalogue. Never invents
-- effort or speed from an unknown suffix; preserves every raw id.

local M = {}

local PROVIDER_NAMES = {
	claude = "Anthropic",
	gpt = "OpenAI",
	cursor = "Cursor",
	gemini = "Google",
	kimi = "Moonshot",
	glm = "Zhipu",
	composer = "Cursor Composer",
	grok = "xAI",
}

-- Closed set of known Cursor effort tokens peeled from the id suffix.
local EFFORT_NAMES = {
	low = true,
	medium = true,
	high = true,
	xhigh = true,
	max = true,
	ultra = true,
	none = true,
}

local COLUMNS = {
	cursor = { "provider", "model", "effort", "speed" },
	codex = { "model", "reasoning", "speed" },
	claude = { "model", "effort" },
}

-- Capability column → family-row field. Non-listed columns are always shown.
local CAPABILITY_FIELDS = {
	effort = "efforts",
	reasoning = "efforts",
	speed = "speeds",
}

function M.capability_field(col)
	return CAPABILITY_FIELDS[col]
end

--- True when at least one row carries data for this capability column.
function M.column_live(col, rows)
	local field = CAPABILITY_FIELDS[col]
	if not field then
		return true
	end
	for _, row in ipairs(rows or {}) do
		if next(row[field] or {}) ~= nil then
			return true
		end
	end
	return false
end

--- Filter `columns` to live capability columns for `rows`.
function M.live_columns(backend, rows, columns)
	columns = columns or M.columns(backend)
	local out = {}
	for _, col in ipairs(columns) do
		if M.column_live(col, rows) then
			out[#out + 1] = col
		end
	end
	return out
end

function M.columns(backend)
	return vim.deepcopy(COLUMNS[backend] or { "model" })
end

--- Confirmed vendor model for display, or the literal "unknown".
--- Strict: never falls back to the operator's request (row 91).
function M.confirmed_identity(panel)
	if type(panel) == "table" and type(panel.model_actual) == "string" and panel.model_actual ~= "" then
		return panel.model_actual
	end
	return "unknown"
end

local function mode_display_suffix(modes)
	modes = modes or {}
	local parts = {}
	for _, key in ipairs({ "effort", "reasoning", "speed" }) do
		local v = modes[key]
		if type(v) == "string" and v ~= "" and v ~= "-" then
			parts[#parts + 1] = v
		end
	end
	if #parts == 0 then
		return ""
	end
	return " " .. table.concat(parts, " ")
end

--- Returns `{ text = <backend:label>, confirmed = <bool> }`. Confirmed → backend:actual
--- [modes] + normal model HL. Unconfirmed → backend:request [modes] or backend:auto +
--- dim HL.
function M.display_identity(panel, opts)
	opts = opts or {}
	local config = require("yana.config")
	local backend = opts.backend
	if type(backend) ~= "string" or backend == "" then
		backend = config.options and config.options.backend
	end
	if type(backend) ~= "string" or backend == "" then
		return { text = "unknown", confirmed = false }
	end
	local modes = opts.modes
	if modes == nil and config.options then
		modes = config.options.model_modes
	end
	local suffix = mode_display_suffix(modes)
	if type(panel) == "table" and type(panel.model_actual) == "string" and panel.model_actual ~= "" then
		return { text = backend .. ":" .. panel.model_actual .. suffix, confirmed = true }
	end
	local requested = opts.model
	if requested == nil and config.options then
		requested = config.options.model
	end
	if type(requested) == "string" and requested ~= "" then
		return { text = backend .. ":" .. requested .. suffix, confirmed = false }
	end
	return { text = backend .. ":auto", confirmed = false }
end

local function sorted_keys(set)
	local keys = {}
	for k in pairs(set or {}) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	return keys
end

local function build_cursor(raw_list)
	local grouped = {}
	for _, item in ipairs(raw_list or {}) do
		local id = item.id or item.slug
		if type(id) == "string" and id ~= "" then
			local prefix = id:match("^([^-]+)")
			local provider = PROVIDER_NAMES[prefix] or (id == "auto" and "Auto") or "Other"
			local base = id
			local speed
			if base:match("%-fast$") then
				base = base:gsub("%-fast$", "")
				speed = "fast"
			end
			local effort
			local suffix = base:match("%-([^-]+)$")
			if suffix and EFFORT_NAMES[suffix] then
				effort = suffix
				base = base:sub(1, #base - #suffix - 1)
			end
			-- Unknown tokens (e.g. extra-high, thinking) stay inside `base`.
			local key = provider .. "\0" .. base
			local row = grouped[key]
			if not row then
				row = {
					provider = provider,
					model = base,
					identity = base,
					efforts = {},
					speeds = {},
					raw_ids = {},
				}
				grouped[key] = row
			end
			row.raw_ids[#row.raw_ids + 1] = id
			if effort then
				row.efforts[effort] = true
			end
			if speed then
				row.speeds[speed] = true
			end
		end
	end
	local rows = {}
	for _, row in pairs(grouped) do
		rows[#rows + 1] = row
	end
	table.sort(rows, function(a, b)
		return (a.provider .. a.model) < (b.provider .. b.model)
	end)
	return rows
end

local function build_codex(payload)
	local models = payload
	if type(payload) == "table" and payload.models then
		models = payload.models
	end
	local rows = {}
	for _, item in ipairs(models or {}) do
		-- Cached list_models rows already dropped non-list entries and use
		-- `id`; raw debug-models JSON still carries visibility+slug.
		local slug = (type(item) == "table" and (item.slug or item.id)) or nil
		local visible = type(item) == "table" and (item.visibility == nil or item.visibility == "list")
		if visible and type(slug) == "string" and slug ~= "" then
			local efforts = {}
			for _, level in ipairs(item.supported_reasoning_levels or {}) do
				if type(level) == "table" and type(level.effort) == "string" and level.effort ~= "" then
					efforts[level.effort] = true
				elseif type(level) == "string" then
					efforts[level] = true
				end
			end
			local speeds = {}
			for _, speed in ipairs(item.additional_speed_tiers or {}) do
				if type(speed) == "string" and speed ~= "" then
					speeds[speed] = true
				end
			end
			rows[#rows + 1] = {
				model = slug,
				identity = slug,
				label = item.display_name or item.label or slug,
				efforts = efforts,
				speeds = speeds,
				raw_ids = { slug },
			}
		end
	end
	table.sort(rows, function(a, b)
		return a.model < b.model
	end)
	return rows
end

local function build_claude(catalogue)
	-- Effort levels are declared once on backends.claude.mode_tokens.effort.
	local effort_set = {}
	do
		local ok, config = pcall(require, "yana.config")
		local bd = ok and config.backend_descriptor and config.backend_descriptor("claude")
		local tok = bd and bd.mode_tokens and bd.mode_tokens.effort
		local levels = tok and (tok.values or tok.levels)
		if type(levels) == "table" then
			for _, level in ipairs(levels) do
				if type(level) == "string" and level ~= "" then
					effort_set[level] = true
				end
			end
		end
	end
	local rows = {}
	for _, item in ipairs(catalogue or {}) do
		local id = item.id or item.slug
		if type(id) == "string" and id ~= "" then
			local efforts = {}
			for level in pairs(effort_set) do
				efforts[level] = true
			end
			rows[#rows + 1] = {
				model = id,
				identity = id,
				label = item.label or id,
				efforts = efforts,
				speeds = {},
				raw_ids = { id },
			}
		end
	end
	return rows
end

--- Build hierarchy rows for a backend from a source payload.
function M.build(backend, source)
	if backend == "cursor" then
		return build_cursor(source)
	end
	if backend == "codex" then
		return build_codex(source)
	end
	if backend == "claude" then
		return build_claude(source)
	end
	-- Unknown backend: preserve ids flat, no invented modes.
	local rows = {}
	for _, item in ipairs(source or {}) do
		local id = item.id or item.slug
		if type(id) == "string" and id ~= "" then
			rows[#rows + 1] = {
				model = id,
				identity = id,
				efforts = {},
				speeds = {},
				raw_ids = { id },
			}
		end
	end
	return rows
end

-- Test/diagnostic helper: stable effort/speed key lists.
function M.effort_keys(row)
	return sorted_keys(row and row.efforts)
end

function M.speed_keys(row)
	return sorted_keys(row and row.speeds)
end

local function row_matches(row, fixed, col)
	if not fixed then
		return true
	end
	for key, want in pairs(fixed) do
		if key ~= col and want ~= nil and want ~= "" then
			if key == "provider" and row.provider ~= want then
				return false
			end
			if key == "model" and row.model ~= want then
				return false
			end
			if (key == "effort" or key == "reasoning") and not (row.efforts and row.efforts[want]) then
				-- Cursor families may omit effort entirely when only the bare id exists.
				if key == "effort" and want == "-" then
					if next(row.efforts or {}) ~= nil then
						return false
					end
				else
					return false
				end
			end
			if key == "speed" then
				if want == "-" then
					-- bare (no speed) remains valid for every matching family
				elseif not (row.speeds and row.speeds[want]) then
					return false
				end
			end
		end
	end
	return true
end

--- Values offered for `col` given already-fixed cells. Never invents modes.
function M.column_values(backend, rows, col, fixed)
	local cols = M.columns(backend)
	local allowed = false
	for _, c in ipairs(cols) do
		if c == col then
			allowed = true
			break
		end
	end
	if not allowed then
		return {}
	end
	local set = {}
	for _, row in ipairs(rows or {}) do
		if row_matches(row, fixed, col) then
			if col == "provider" and row.provider then
				set[row.provider] = true
			elseif col == "model" and row.model then
				set[row.model] = true
			elseif col == "effort" or col == "reasoning" then
				for k in pairs(row.efforts or {}) do
					set[k] = true
				end
			elseif col == "speed" then
				for k in pairs(row.speeds or {}) do
					set[k] = true
				end
				-- Bare (no speed suffix / no tier) is always a legal choice when
				-- the family exists; shown as "-" so it is not confused with a
				-- vendor token.
				set["-"] = true
			end
		end
	end
	return sorted_keys(set)
end

local function compose_cursor_id(row, effort, speed)
	local id = row.model
	if effort and effort ~= "" and effort ~= "-" then
		id = id .. "-" .. effort
	end
	if speed and speed ~= "" and speed ~= "-" then
		id = id .. "-" .. speed
	end
	for _, raw in ipairs(row.raw_ids or {}) do
		if raw == id then
			return id
		end
	end
	-- Prefer an exact raw match; if the bare model id is listed, allow it when
	-- no effort/speed were fixed.
	if (not effort or effort == "-" or effort == "") and (not speed or speed == "-" or speed == "") then
		for _, raw in ipairs(row.raw_ids or {}) do
			if raw == row.model or raw == row.identity then
				return raw
			end
		end
	end
	return nil
end

--- Columns that must be fixed before Enter can resolve a tuple.
function M.required_columns(backend)
	if backend == "cursor" then
		return { "provider", "model" }
	end
	return { "model" }
end

--- Names of required columns still unset in `fixed`.
function M.missing_required(backend, fixed)
	fixed = fixed or {}
	local missing = {}
	for _, col in ipairs(M.required_columns(backend)) do
		local v = fixed[col]
		if type(v) ~= "string" or v == "" then
			missing[#missing + 1] = col
		end
	end
	return missing
end

--- Decode a session model (+ optional modes) into fixed cells for the marker.
--- Returns nil when the id is absent / auto / unmatched.
function M.decode_current(backend, model_id, modes, rows)
	if type(model_id) ~= "string" or model_id == "" or model_id == "auto" then
		return nil
	end
	modes = modes or {}
	if backend == "cursor" then
		for _, row in ipairs(rows or {}) do
			for _, raw in ipairs(row.raw_ids or {}) do
				if raw == model_id then
					local fixed = { provider = row.provider, model = row.model }
					-- Peel effort/speed the same way build_cursor composed them.
					-- Only real values seed markers — never synthetic "-".
					local base = model_id
					if base:match("%-fast$") and row.speeds and row.speeds.fast then
						fixed.speed = "fast"
						base = base:gsub("%-fast$", "")
					end
					local suffix = base:match("%-([^-]+)$")
					if suffix and row.efforts and row.efforts[suffix] then
						fixed.effort = suffix
					end
					return fixed
				end
			end
		end
		return nil
	end
	if backend == "codex" then
		for _, row in ipairs(rows or {}) do
			if row.model == model_id then
				local fixed = { model = row.model }
				if type(modes.reasoning) == "string" and modes.reasoning ~= "" and modes.reasoning ~= "-" then
					fixed.reasoning = modes.reasoning
				end
				if type(modes.speed) == "string" and modes.speed ~= "" and modes.speed ~= "-" then
					fixed.speed = modes.speed
				end
				return fixed
			end
		end
		return nil
	end
	if backend == "claude" then
		for _, row in ipairs(rows or {}) do
			if row.model == model_id then
				local fixed = { model = row.model }
				if type(modes.effort) == "string" and modes.effort ~= "" and modes.effort ~= "-" then
					fixed.effort = modes.effort
				end
				return fixed
			end
		end
		return nil
	end
	for _, row in ipairs(rows or {}) do
		if row.model == model_id then
			local fixed = { model = row.model }
			if type(modes.effort) == "string" and modes.effort ~= "" and modes.effort ~= "-" then
				fixed.effort = modes.effort
			end
			return fixed
		end
	end
	return nil
end

--- Resolve a fixed-cell tuple into session model + vendor mode tokens.
--- Returns nil when the tuple is incomplete or matches no declared capability.
function M.resolve(backend, fixed, rows)
	fixed = fixed or {}
	if backend == "cursor" then
		if not fixed.provider or not fixed.model then
			return nil
		end
		for _, row in ipairs(rows or {}) do
			if row.provider == fixed.provider and row.model == fixed.model then
				local id = compose_cursor_id(row, fixed.effort, fixed.speed)
				if id then
					return { model = id, modes = nil }
				end
			end
		end
		return nil
	end
	if backend == "codex" then
		if not fixed.model then
			return nil
		end
		for _, row in ipairs(rows or {}) do
			if row.model == fixed.model then
				local modes = {}
				if fixed.reasoning and fixed.reasoning ~= "" and fixed.reasoning ~= "-" then
					if not (row.efforts and row.efforts[fixed.reasoning]) then
						return nil
					end
					modes.reasoning = fixed.reasoning
				end
				if fixed.speed and fixed.speed ~= "" and fixed.speed ~= "-" then
					if not (row.speeds and row.speeds[fixed.speed]) then
						return nil
					end
					modes.speed = fixed.speed
				end
				return { model = row.model, modes = next(modes) and modes or nil }
			end
		end
		return nil
	end
	-- claude: model required; optional effort from descriptor levels.
	if backend == "claude" then
		if not fixed.model then
			return nil
		end
		for _, row in ipairs(rows or {}) do
			if row.model == fixed.model then
				local modes = {}
				if fixed.effort and fixed.effort ~= "" and fixed.effort ~= "-" then
					if not (row.efforts and row.efforts[fixed.effort]) then
						return nil
					end
					modes.effort = fixed.effort
				end
				return { model = row.model, modes = next(modes) and modes or nil }
			end
		end
		return nil
	end
	-- unknown: model column only; no invented modes.
	if not fixed.model then
		return nil
	end
	for _, row in ipairs(rows or {}) do
		if row.model == fixed.model then
			return { model = row.model, modes = nil }
		end
	end
	return nil
end

return M
