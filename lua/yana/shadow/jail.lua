-- Shadow confinement launcher: `wrap_cmd` runs the agent under `bin/yana-overlay`.
-- The real workspace is the read-only lower layer; the agent's writes land in a
-- private upper layer, and yanad owns turn lifecycle and file arbitration.
local M = {}

local diff = require("yana.diff")
local uv = vim.uv or vim.loop

M.UNAVAILABLE_MSG = "shadow sandbox unavailable (bwrap missing or denied)"
M.OVERLAY_UNAVAILABLE_MSG = "overlay confinement unavailable (bwrap or yana-overlay missing)"

M._test = {
	force_bwrap = nil,
}

local STRIP_ENV = {
	VIM = true,
	VIMRUNTIME = true,
	YANA_JAIL_WORKSPACE = true,
	YANA_JAIL_SHADOW_DIR = true,
	YANA_JAIL_PRIVATE_DIR = true,
	YANA_JAIL_BWRAP = true,
	YANA_OVERLAY_BWRAP = true,
	YANA_OVERLAY_INNER = true,
	-- Neovim running as git's editor: the agent's git must use its own working folder (CAPTURE.md OC-GIT).
	GIT_DIR = true,
	GIT_WORK_TREE = true,
	GIT_COMMON_DIR = true,
	GIT_INDEX_FILE = true,
}

local function bwrap_bin()
	if M._test.force_bwrap == false then
		return nil
	end
	if M._test.force_bwrap then
		return M._test.force_bwrap
	end
	if vim.fn.executable("bwrap") == 1 then
		return "bwrap"
	end
	return nil
end

local function repo_dir()
	local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
	return source:gsub("/lua/yana/shadow/jail%.lua$", "")
end

-- Path to bin/yana-overlay if it exists, else nil.
function M.overlay_bin()
	local candidate = repo_dir() .. "/bin/yana-overlay"
	if vim.fn.filereadable(candidate) == 1 then
		return candidate
	end
	return nil
end

--- True when the turn path (overlay confinement) can run.
function M.available()
	return bwrap_bin() ~= nil and M.overlay_bin() ~= nil
end

function M.mcp_runtime_dir()
	return require("yana.shadow.preview").state_root() .. "/mcp-runtime"
end

local function toml_value(value)
	if type(value) ~= "table" then return (vim.json.encode(value):gsub("\\/", "/")) end
	local parts = {}
	if vim.islist(value) then
		for _, item in ipairs(value) do parts[#parts + 1] = toml_value(item) end
		return "[" .. table.concat(parts, ", ") .. "]"
	end
	for _, key in ipairs(vim.fn.sort(vim.tbl_keys(value))) do parts[#parts + 1] = key .. " = " .. toml_value(value[key]) end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

-- TOML lines for a table: plain keys first, then each sub-table as a section.
local function toml_lines(value, prefix, out)
	local tables = {}
	for _, key in ipairs(vim.fn.sort(vim.tbl_keys(value))) do
		assert(key:match("^[%w_-]+$"), "yana: MCP config key is not a bare TOML key: " .. key)
		if type(value[key]) == "table" and not vim.islist(value[key]) then
			tables[#tables + 1] = key
		else
			out[#out + 1] = key .. " = " .. toml_value(value[key])
		end
	end
	for _, key in ipairs(tables) do
		local name = prefix and (prefix .. "." .. key) or key
		out[#out + 1] = "[" .. name .. "]"
		toml_lines(value[key], name, out)
	end
	return out
end

local function write_mcp_document(path, document, format)
	local encoded = format == "toml" and table.concat(toml_lines(document, nil, {}), "\n") .. "\n"
		or vim.json.encode(document)
	local fd, err = uv.fs_open(path, "w", 384)
	if not fd then return nil, err end
	local wrote, write_err = uv.fs_write(fd, encoded, 0)
	uv.fs_close(fd)
	return wrote, write_err
end

-- Write one run's MCP config from the backend's inline_mcp descriptor.
-- Returns the path to remove and the run's env;
-- format "cli" writes no file and returns the `<flag> key=<TOML value>` tokens.
function M.write_mcp_config(run_id, policy, runtime_dir)
	local spec = policy.config
	local repo = repo_dir()
	local server = { command = "python3", args = { "-m", "mcpyana" }, cwd = repo, env = { PYTHONPATH = repo } }
	if spec.server then server = vim.tbl_deep_extend("force", server, spec.server) end
	local document = vim.deepcopy(spec.settings or {})
	document[spec.servers_key] = { yana = server }
	local env, home, path = vim.deepcopy(policy.env or {}), nil, nil
	if spec.format == "cli" then
		local tokens = {}
		for _, key in ipairs(vim.fn.sort(vim.tbl_keys(document))) do
			vim.list_extend(tokens, { spec.flag, key .. "=" .. toml_value(document[key]) })
		end
		return tokens, env
	end
	if policy.home_env then
		home = runtime_dir .. "/home"
		local made, mkdir_err = uv.fs_mkdir(home, 448)
		if not made then return nil, mkdir_err end
		env[policy.home_env], path = home, home .. "/" .. spec.file
	else
		path = runtime_dir .. "/mcp.json"
	end
	local wrote, write_err = write_mcp_document(path, document, spec.format)
	if not wrote then M.remove_mcp_config(home or path); return nil, write_err end
	if spec.native_file then
		local native = { [spec.servers_key] = document[spec.servers_key] }
		wrote, write_err = write_mcp_document(vim.fs.joinpath(home, spec.native_file), native, spec.format)
		if not wrote then M.remove_mcp_config(home); return nil, write_err end
	end
	if home and policy.auth == "linked" then
		local native = vim.env[policy.home_env] or vim.fn.expand(policy.native_home)
		for name, access in pairs(policy.home_links) do
			local source = vim.fs.joinpath(native, name)
			if access == "write" then
				vim.fn.mkdir(source, "p", 448)
			end
			if uv.fs_stat(source) then
				local linked, link_err = uv.fs_symlink(source, vim.fs.joinpath(home, name))
				if not linked then M.remove_mcp_config(home); return nil, link_err end
			end
		end
	end
	return home or path, env
end

function M.remove_mcp_config(path)
	if type(path) == "string" then vim.fn.delete(path, "rf") end
end

-- The daemon turn's launcher options, appended to `out`. Editor never mints
-- layers/claims; the launcher asks the daemon (turn.request / turn.resume).
local function turn_args(session, out, buffer)
	local session_id = session.yanad_session_id or session.session_id
	local turn_id = session.turn_id
	local mode = require("yana.config").resolve_mode(session.mode) or "inline"
	if turn_id == nil or tostring(turn_id) == "" then
		return nil, "yanad turn_id missing"
	end
	vim.list_extend(out, { "--turn", tostring(turn_id), "--mode", tostring(mode) })
	if not buffer then
		local private = M.private_dir(session)
		vim.fn.mkdir(private, "p")
		session.yanad_answer_out = private .. "/yanad-answer.json"
		vim.list_extend(out, { "--answer-out", session.yanad_answer_out })
	end
	if type(session_id) == "string" and session_id ~= "" then
		vim.list_extend(out, { "--session", session_id })
	else
		table.insert(out, "--session-auto")
	end
	-- Touched files for turn.request intersection (absolute).
	for _, path in ipairs(session.touched_files or {}) do
		vim.list_extend(out, { "--touched", diff.abs_path(path) })
	end
	-- PANEL.md F-ADDENDUM-TURN: every run names its generation, the lifecycle
	-- pass's (none is minted here). A follow-up resumes the Turn (daemon `turn.resume`).
	local generation = buffer and session.generation or session.turn_pass and session.turn_pass.generation
	if generation ~= nil then
		vim.list_extend(out, { "--generation", tostring(generation) })
	end
	if session.resume then
		if generation == nil then
			return nil, "yanad turn.resume needs the run generation of the lifecycle pass"
		end
		table.insert(out, "--resume")
	end
	return out
end

function M.wrap_mcp_cmd(argv, session, socket_dir)
	local launcher = repo_dir() .. "/bin/yana-confine"
	if vim.fn.executable(launcher) ~= 1 then
		return nil, "MCP launcher unavailable (yana-confine missing)"
	end
	local workspace = diff.abs_path(session.workspace)
	local env = { YANA_STATE_ROOT = require("yana.shadow.preview").state_root() }
	local wrapped, turn_err = turn_args(session, { launcher, "--workspace", workspace, "--runtime-dir", socket_dir }, true)
	if not wrapped then return nil, turn_err end
	table.insert(wrapped, "--")
	vim.list_extend(wrapped, argv)
	return wrapped, env
end


-- Return the session's private directory path.
function M.private_dir(session)
	return session.private_dir
end

--- Wrap a cursor-agent argv for jobstart so the agent runs inside the kernel
--- overlay at the workspace's real absolute path.
---
--- The command is entered through `sh -c 'cd "$1" && shift && exec "$@"'` for
--- the same reason `bin/yana-turn` does it: the agent must start inside
--- the overlaid workspace, not wherever the editor's cwd happens to point.
--- Confinement fails closed — with no overlay launcher there is no fallback.
function M.wrap_cmd(argv, session)
	local ob = M.overlay_bin()
	if not ob or not bwrap_bin() then
		return nil, M.OVERLAY_UNAVAILABLE_MSG
	end
	local workspace = diff.abs_path(session.workspace)
	local out, turn_err = turn_args(session, { ob, "--workspace", workspace })
	if not out then return nil, turn_err end
	local private = M.private_dir(session)
	local generation = session.turn_pass and session.turn_pass.generation

	-- Overlay copies: the
	-- launcher puts each `from` (the buffer text at submit) in the upper layer at
	-- `path`, so the agent reads the buffer instead of the saved file.
	for _, seed in ipairs(session.seed_files or {}) do
		vim.list_extend(out, { "--seed", seed.path .. "=" .. seed.from })
	end

	-- A follow-up's layer edits make unopened files match the selected review view;
	-- the launcher records their inverse facts under private/.
	if session.resume then
		vim.list_extend(out, { "--layer-inverse", private .. "/layer-inverse/g" .. tostring(generation) })
		for _, edit in ipairs(session.layer_edits or {}) do
			if edit.op == "put" then
				vim.list_extend(out, { "--layer-put", edit.path .. "=" .. edit.from })
			elseif edit.op == "remove" then
				vim.list_extend(out, { "--layer-remove", edit.path })
			else
				return nil, "layer edit " .. tostring(edit.op) .. " is neither put nor remove"
			end
		end
	end

	--
	-- Read from the session `preview.begin_turn` built out of filesystem position and
	-- operator configuration; nothing in this process may widen it, and nothing a turn
	-- produced can reach it.
	-- Every turn takes the broad-root launch shape, even when the broad root is the
	-- workspace itself: only that shape mounts writable-host exceptions after every
	-- overlay, so neither an extra root nor a workspace that holds them (the home
	-- folder) can hide them (CAPTURE.md OC-HOME).
	local broad_root = session.broad_root
	if type(broad_root) == "string" and broad_root ~= "" then
		vim.list_extend(out, { "--broad-root", broad_root })
	end

	-- One repeated group per capture area beyond the workspace and its broad root
	-- (home folder, writable data disks), in the order `preview.resolve_roots`
	-- fixed. Under yanad the daemon mints each root's layer; the editor only names
	-- the root path.
	local roots = require("yana.shadow.ops").session_roots(session)
	for i = 2, #roots do
		local root = roots[i]
		vim.list_extend(out, {
			"--extra-root",
			diff.abs_path(root.workspace),
		})
	end

	local cfg = require("yana.config")
	local inline_exec_allowlist_active = cfg.resolve_mode(session.mode) == "inline"
		and type(cfg.options.inline_exec_allowlist) == "table"
	if inline_exec_allowlist_active then
		-- The ONE recursive delete on this path, and the reason this block is
		-- pinned in the mutation inventory. It clears the previous turn's
		-- symlink farm, so it must be provably inside THIS turn's jail scratch
		-- before it runs: an empty or absent layer root would otherwise resolve
		-- to an absolute path of the launcher's choosing. Fail closed instead --
		-- an inline turn that cannot prepare its exec directory does not run.
		local state_root = require("yana.shadow.preview").state_root()
		local base = session.private_dir
		if type(base) ~= "string" or base == "" then
			base = private
		end
		if
			type(state_root) ~= "string"
			or state_root == ""
			or state_root:sub(1, 1) ~= "/"
			or (base ~= state_root and base:sub(1, #state_root + 1) ~= state_root .. "/")
		then
			return nil, "inline_exec_allowlist: the turn's exec directory would fall outside its jail scratch"
		end
		local bindir = base .. "/exec-allow"
		vim.fn.delete(bindir, "rf")
		vim.fn.mkdir(bindir, "p")
		for _, path in ipairs(cfg.options.inline_exec_allowlist) do
			vim.list_extend(out, { "--exec-allow", path })
			local link = bindir .. "/" .. vim.fn.fnamemodify(path, ":t")
			pcall(vim.loop.fs_symlink, path, link)
			if vim.fn.fnamemodify(path, ":t") == "dash" then
				pcall(vim.loop.fs_symlink, path, bindir .. "/sh")
			end
		end
		session.inline_exec_allow_path = bindir
	end

	-- The active backend's declared writable state directories
	-- (`backends.<name>.state_dirs`). The launcher binds exactly these, and nothing else
	-- under $HOME becomes writable: config.lua refuses a state_dirs entry outside $HOME or
	-- under ~/.ssh, ~/.gnupg, ~/.aws at SETUP, by name, so no turn can widen this list.
	--
	-- `backend_descriptor` is the single reader of `options.backends[name]`
	-- in this codebase (config.lua:1515) and already defaults the name to
	-- the active backend, so a session that names none resolves the same way
	-- every other consumer does.
	local backend = cfg.backend_descriptor(session.backend)
	for _, path in ipairs(cfg.options.ignore_folders) do
		if vim.fn.isdirectory(path) == 1 then
			vim.list_extend(out, { "--ignore-folder", path })
		end
	end
	if backend and type(backend.state_dirs) == "table" then
		for _, dir in ipairs(backend.state_dirs) do
			local path = cfg.expand_state_dir(dir)
			if path then
				vim.list_extend(out, { "--state-dir", path })
			end
		end
	end

	-- CAPTURE.md OC-GIT: the starting repository's `.git` folder is read-only.
	local git_dir = require("yana.shadow.git_shield").dir(session)
	if git_dir then
		vim.list_extend(out, { "--read-only", git_dir })
	end

	vim.list_extend(out, { "--", "sh", "-c", 'cd "$1" && shift && exec "$@"', "_", workspace })
	vim.list_extend(out, argv)

	local env = {
		YANA_OVERLAY_BWRAP = bwrap_bin(),
		YANA_STATE_ROOT = require("yana.shadow.preview").state_root(),
	}
	if vim.env.XDG_RUNTIME_DIR and vim.env.XDG_RUNTIME_DIR ~= "" then
		env.XDG_RUNTIME_DIR = vim.env.XDG_RUNTIME_DIR
	end
	if inline_exec_allowlist_active then
		env.YANA_INLINE_EXEC_ALLOWLIST_ACTIVE = "1"
		env.YANA_INLINE_EXEC_ALLOW_PATH = session.inline_exec_allow_path
	end
	-- vim.system replaces the whole environment when `env` is set; inherit PATH etc.
	return out, M.merge_spawn_env(env)
end

local jail_refusal = require("yana.shadow.jail_refusal")

M.OUT_OF_WORKSPACE_REASON = jail_refusal.OUT_OF_WORKSPACE_REASON
M.OUT_OF_WORKSPACE_REMEDIES = jail_refusal.OUT_OF_WORKSPACE_REMEDIES
M.out_of_workspace_remedy = jail_refusal.out_of_workspace_remedy
M.consume_answer = jail_refusal.consume_answer
M.run_overlay_shell = jail_refusal.run_overlay_shell
M.record_vendor_job_refusal = jail_refusal.record_vendor_job_refusal

local function merge_env(base, extra)
	local out = {}
	for k, v in pairs(vim.env) do
		if not STRIP_ENV[k] then
			out[k] = v
		end
	end
	if extra then
		for k, v in pairs(extra) do
			out[k] = v
		end
	end
	return out
end

-- Merge jail_env over the stripped host environment; returns a new table.
function M.merge_spawn_env(jail_env)
	return merge_env({}, jail_env)
end

return M
