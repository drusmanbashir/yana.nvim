-- Yana-owned UI state under stdpath("state"). Never rewrites the operator's neovim
-- config.
local M = {}

local override_path

local function state_path()
	if type(override_path) == "string" and override_path ~= "" then
		return override_path
	end
	return vim.fn.stdpath("state") .. "/yana/ui_state.json"
end

local function read_all()
	local path = state_path()
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	local lines = vim.fn.readfile(path)
	local raw = table.concat(lines, "\n")
	if raw == "" then
		return {}
	end
	local ok, decoded = pcall(vim.json.decode, raw)
	if not ok or type(decoded) ~= "table" then
		return {}
	end
	return decoded
end

local function write_all(data)
	local path = state_path()
	local dir = vim.fn.fnamemodify(path, ":h")
	vim.fn.mkdir(dir, "p")
	local encoded = vim.json.encode(data)
	local tmp = path .. ".tmp." .. tostring(vim.uv.hrtime())
	vim.fn.writefile({ encoded }, tmp)
	vim.fn.rename(tmp, path)
end

function M.get(key)
	local all = read_all()
	return all[key]
end

function M.set(key, value)
	local all = read_all()
	all[key] = value
	write_all(all)
end

--- Merge a saved model_selection onto config.options (UI-owned keys only).
function M.apply_model_selection(options)
	options = options or {}
	local sel = M.get("model_selection")
	if type(sel) ~= "table" then
		return false
	end
	if type(sel.backend) == "string" and sel.backend ~= "" then
		-- A test double or removed vendor may have written this selection in a
		-- prior session. Never restore a backend that this setup cannot resolve.
		if type(options.backends) == "table" and type(options.backends[sel.backend]) ~= "table" then
			return false
		end
		options.backend = sel.backend
	end
	if sel.model == nil or type(sel.model) == "string" then
		options.model = sel.model
	end
	if sel.model_modes == nil or type(sel.model_modes) == "table" then
		options.model_modes = sel.model_modes and vim.deepcopy(sel.model_modes) or nil
	end
	return true
end

function M.save_model_selection(options)
	options = options or {}
	M.set("model_selection", {
		backend = options.backend,
		model = options.model,
		model_modes = options.model_modes and vim.deepcopy(options.model_modes) or nil,
	})
end

--- Merge saved capture roots onto the hand-authored setup defaults.
function M.apply_write_roots(options)
	options = options or {}
	local saved = M.get("write_roots")
	if type(saved) ~= "table" then
		return false
	end
	local merged, seen = {}, {}
	for _, path in ipairs(options.write_roots or {}) do
		if type(path) == "string" and path ~= "" and not seen[path] then
			seen[path], merged[#merged + 1] = true, path
		end
	end
	for _, path in ipairs(saved) do
		if type(path) == "string" and path ~= "" and not seen[path] then
			seen[path], merged[#merged + 1] = true, path
		end
	end
	options.write_roots = merged
	return true
end

function M.save_write_roots(options)
	options = options or {}
	M.set("write_roots", vim.deepcopy(options.write_roots or {}))
end

M._test = {
	set_path = function(path)
		override_path = path
	end,
	path = function()
		return state_path()
	end,
	reset = function()
		override_path = nil
	end,
}

return M
