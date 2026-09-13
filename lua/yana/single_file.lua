local M = {}

local diff = require("yana.diff")
local hash = require("yana.safety.hash")
local workspace_identity = require("yana.workspace_identity")
local uv = vim.uv or vim.loop

local SECRET_DIRS = {
	".ssh",
	".gnupg",
	".aws",
	".azure",
	".kube",
	".config/gcloud",
	".config/sops",
	".local/share/keyrings",
	".gnome2/keyrings",
	".password-store",
}

local SECRET_FILES = {
	".netrc",
	".pgpass",
	".docker/config.json",
	".git-credentials",
	".npmrc",
	".pypirc",
	".config/gh/hosts.yml",
}

local next_flags = nil

local function real(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	return uv.fs_realpath(path) or vim.fn.resolve(vim.fn.fnamemodify(diff.abs_path(path), ":p")):gsub("/+$", "")
end

local function parent(path)
	return vim.fn.fnamemodify(path, ":h")
end

local function basename(path)
	return vim.fn.fnamemodify(path, ":t")
end

local function contains(root, path)
	return root == path or path:sub(1, #root + 1) == root .. "/"
end

local function passwd_home()
	local out = vim.fn.system({ "getent", "passwd", vim.env.USER or vim.fn.system("id -un"):gsub("%s+$", "") })
	if vim.v.shell_error ~= 0 then
		return nil
	end
	return real((out:match("^[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:]+):") or ""))
end

local function depth(path)
	local n = 0
	for part in tostring(path or ""):gmatch("[^/]+") do
		if part ~= "" then
			n = n + 1
		end
	end
	return n
end

local function sanity_refused(candidate)
	local c = real(candidate)
	if not c then
		return false
	end
	if c == "/" then
		return true
	end
	local env_home = real(vim.env.HOME or "")
	if env_home and c == env_home then
		return true
	end
	local pw_home = passwd_home()
	if pw_home and c == pw_home then
		return true
	end
	return depth(c) < 2
end

local function count_over(dir, max_entries)
	local iter = uv.fs_scandir(dir)
	if not iter then
		return false
	end
	local n = 0
	while true do
		local name = uv.fs_scandir_next(iter)
		if not name then
			return false
		end
		n = n + 1
		if n > max_entries then
			return true
		end
	end
end

local function secret_roots()
	local roots = {}
	local homes = {}
	local seen = {}
	for _, home in ipairs({ real(vim.env.HOME or ""), passwd_home() }) do
		if home and not seen[home] then
			seen[home] = true
			homes[#homes + 1] = home
		end
	end
	for _, home in ipairs(homes) do
		for _, entry in ipairs(SECRET_DIRS) do
			roots[#roots + 1] = home .. "/" .. entry
		end
		for _, entry in ipairs(SECRET_FILES) do
			roots[#roots + 1] = home .. "/" .. entry
		end
	end
	return roots
end

-- Return absolute paths of secret dirs/files under every known $HOME.
function M.secret_roots()
	return secret_roots()
end

-- Stash flags for the next M.decide call to consume.
function M.set_next_flags(flags)
	next_flags = flags
end

-- Return and clear the flags stashed by M.set_next_flags.
function M.consume_next_flags()
	local flags = next_flags or {}
	next_flags = nil
	return flags
end

local function forced_workspace(flags)
	return flags and flags.workspace and flags.workspace ~= ""
end

-- Return the real on-disk path mapped for a scratch-buffer path.
function M.real_path(map, path)
	local p = real(path) or diff.abs_path(path)
	return map and (map[p] or map[diff.abs_path(path)]) or nil
end

-- Return the scratch-buffer path mapped to a given real path.
function M.scratch_path(map, path)
	local p = real(path) or diff.abs_path(path)
	if type(map) ~= "table" then
		return nil
	end
	for scratch, target in pairs(map) do
		if target == p then
			return scratch
		end
	end
	return nil
end

-- Return the records directory path for a decision's real path.
function M.records_workspace(decision, state_root)
	local base = state_root .. "/single-file/" .. hash.hash_bytes(decision.real_path):sub(1, 16)
	return base .. "/records"
end

-- Classify a saved path into a single-file-mode trigger, or refuse/skip it.
function M.decide(opts)
	opts = opts or {}
	local cfg = require("yana.config").options.single_file or {}
	if cfg.enabled == false then
		return nil
	end
	local flags = opts.flags or {}
	if forced_workspace(flags) then
		return nil
	end
	local rp = real(opts.real_path or "")
	if not rp then
		return nil
	end
	local candidate = real(opts.candidate_dir or parent(rp)) or parent(rp)
	local name = basename(rp)
	for _, root in ipairs(secret_roots()) do
		local sr = real(root) or root
		if contains(sr, rp) then
			return nil, "single-file mode: " .. name .. " is behind the secrets wall"
		end
	end
	if vim.fn.filereadable(rp) ~= 1 then
		return nil, "single-file mode: save " .. name .. " first"
	end
	if flags.file then
		return { trigger = "flag", real_path = rp, candidate_dir = candidate }
	end
	if sanity_refused(candidate) then
		return { trigger = "home", real_path = rp, candidate_dir = candidate }
	end
	local home = real(vim.env.HOME or "") or ""
	local git = workspace_identity.git_root(rp, home)
	if git and real(git) ~= home then
		return nil
	end
	local cand = real(candidate) or candidate or ""
	local below_home = home ~= "" and (cand == home or cand:sub(1, #home + 1) == home .. "/")
	if not below_home then
		return nil
	end
	if not git then
		return { trigger = "loose", real_path = rp, candidate_dir = candidate }
	end
	if count_over(candidate, tonumber(cfg.max_entries) or 2000) then
		return { trigger = "huge", real_path = rp, candidate_dir = candidate }
	end
	return nil
end

-- Create the scratch workspace, copy the file in, and write meta.json.
function M.materialise(decision, state_root)
	local slug = hash.hash_bytes(decision.real_path):sub(1, 16)
	local base = state_root .. "/single-file/" .. slug
	local ws = base .. "/ws"
	local records = base .. "/records"
	local name = basename(decision.real_path)
	local copy = ws .. "/" .. name
	vim.fn.delete(ws, "rf")
	vim.fn.mkdir(ws, "p")
	vim.fn.mkdir(records, "p")
	local bytes, rerr = diff.read_file_bytes(decision.real_path)
	if bytes == nil then
		return nil, rerr or "single-file mode: could not read " .. name
	end
	local ok, werr = diff.write_file(copy, bytes)
	if not ok then
		return nil, werr
	end
	diff.write_file(base .. "/meta.json", vim.json.encode({
		real_path = decision.real_path,
		real_workspace = parent(decision.real_path),
		records = records,
		copy_path = copy,
	}) .. "\n")
	local st = uv.fs_stat(decision.real_path)
	if st and st.mode then
		pcall(uv.fs_chmod, copy, st.mode)
	end
	return {
		workspace = ws,
		copy_path = copy,
		records = records,
		map = { [copy] = decision.real_path },
		base = base,
	}
end

local function state_root()
	local state = vim.env.YANA_STATE_ROOT
	if not state or state == "" then
		local ok, preview = pcall(require, "yana.shadow.preview")
		state = ok and preview.state_root() or nil
	end
	if not state or state == "" then
		return nil
	end
	return state
end

local function each_meta(state)
	local paths = vim.fn.globpath(state, "single-file/*/meta.json", 0, 1) or {}
	local i = 0
	return function()
		while true do
			i = i + 1
			local meta_path = paths[i]
			if not meta_path then
				return nil
			end
			local body = diff.read_file_bytes(meta_path)
			if body then
				local ok, meta = pcall(vim.json.decode, body)
				if ok and type(meta) == "table" then
					return meta
				end
			end
		end
	end
end

-- Return the records dir for a real path or workspace, scanning meta.json.
function M.records_for_real(workspace, rel)
	local path = workspace
	if type(rel) == "string" and rel ~= "" then
		path = (diff.abs_path(workspace):gsub("/$", "")) .. "/" .. rel
	end
	local rp = real(path)
	if not rp then
		return nil
	end
	local state = state_root()
	if not state then
		return nil
	end
	for meta in each_meta(state) do
		if real(meta.real_path or "") == rp or (not rel and real(meta.real_workspace or "") == rp) then
			return meta.records
		end
	end
	return nil
end

local function meta_for_workspace(workspace)
	local ws = real(workspace) or diff.abs_path(workspace)
	if not ws then
		return nil
	end
	local state = state_root()
	if not state then
		return nil
	end
	for meta in each_meta(state) do
		local rec = meta.records and real(meta.records)
		local rws = meta.real_workspace and real(meta.real_workspace)
		if (rec and rec == ws) or (rws and rws == ws) then
			return meta
		end
	end
	return nil
end

--- The real workspace directory for timeline/retrace buffer work. SFM
--- journals live under `.../records/`; the buffer always names the real tree.
function M.real_workspace_for(workspace)
	local meta = meta_for_workspace(workspace)
	if meta and meta.real_workspace then
		return real(meta.real_workspace) or diff.abs_path(meta.real_workspace)
	end
	return diff.abs_path(workspace or vim.fn.getcwd())
end

--- Absolute on-disk path for a timeline row's file (scratch map -> real path).
function M.buffer_abs_path(workspace, rel)
	local meta = meta_for_workspace(workspace)
	if meta and type(rel) == "string" and rel ~= "" then
		local rp = meta.real_path and real(meta.real_path)
		if rp and vim.fn.fnamemodify(rp, ":t") == rel then
			return rp
		end
		local base = meta.real_workspace and real(meta.real_workspace)
		if base then
			return diff.abs_path(base:gsub("/+$", "") .. "/" .. rel)
		end
	end
	local rw = M.real_workspace_for(workspace)
	if type(rel) ~= "string" or rel == "" then
		return diff.abs_path(rw)
	end
	return diff.abs_path(rw:gsub("/+$", "") .. "/" .. rel)
end

-- Delete a turn's single-file scratch workspace directory.
function M.cleanup(turn)
	local sfm = turn and turn.single_file
	if sfm and sfm.base then
		pcall(vim.fn.delete, sfm.base .. "/ws", "rf")
	end
end

return M
