-- Shadow confinement launchers.
--
-- Two launchers live here and they are not interchangeable.
--
-- `wrap_cmd` is the turn path: it runs the agent under `bin/yana-overlay`,
-- the kernel overlayfs confinement described by the isolation contract. The
-- real workspace is the read-only lower layer, the agent's writes land in a
-- private upper layer; yanad owns turn lifecycle and file arbitration.
--
-- `build_shell_argv` / `run_shell` remain on the older `bin/yana-jail`
-- bind-mount sandbox. That launcher shows the agent a pre-copied shadow tree
-- rather than an overlay, which is what the git isolation helper and its
-- headless tests expect. It is confined, but it is not the turn path.
local M = {}

local diff = require("yana.diff")

M.UNAVAILABLE_MSG = "shadow sandbox unavailable (bwrap missing or denied)"
M.OVERLAY_UNAVAILABLE_MSG = "overlay confinement unavailable (bwrap or yana-overlay missing)"

M._test = {
	force_bwrap = nil,
	force_jail_bin = nil,
	force_overlay_bin = nil,
}

local STRIP_ENV = {
	NVIM = true,
	VIM = true,
	VIMRUNTIME = true,
	YANA_JAIL_WORKSPACE = true,
	YANA_JAIL_SHADOW_DIR = true,
	YANA_JAIL_PRIVATE_DIR = true,
	YANA_JAIL_BWRAP = true,
	YANA_OVERLAY_BWRAP = true,
	YANA_OVERLAY_INNER = true,
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
	return debug.getinfo(1, "S").source:sub(2):gsub("/lua/yana/shadow/jail%.lua$", "")
end

local function jail_bin()
	if M._test.force_jail_bin then
		return M._test.force_jail_bin
	end
	local candidate = repo_dir() .. "/bin/yana-jail"
	if vim.fn.filereadable(candidate) == 1 then
		return candidate
	end
	return nil
end

-- Path to bin/yana-overlay if it exists (or the test override), else nil.
function M.overlay_bin()
	if M._test.force_overlay_bin then
		return M._test.force_overlay_bin
	end
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

--- True when the older bind-mount sandbox (run_shell) can run.
function M.jail_available()
	return bwrap_bin() ~= nil and jail_bin() ~= nil
end

-- Return the session's private directory path.
function M.private_dir(session)
	return session.private_dir
end

--- Build argv to run ``inner_cmd`` inside the jail (string passed to /bin/sh -c).
function M.build_shell_argv(opts)
	opts = opts or {}
	local workspace = diff.abs_path(opts.workspace or opts.shadow_root or vim.fn.getcwd())
	local shadow_dir = diff.abs_path(opts.shadow_dir or opts.shadow_root or workspace)
	local private_dir = diff.abs_path(opts.private_dir or (shadow_dir .. "/../private"))
	local inner = opts.cmd
	if not inner or inner == "" then
		inner = "true"
	end

	local jb = jail_bin()
	if not jb then
		return nil, M.UNAVAILABLE_MSG
	end
	if not bwrap_bin() then
		return nil, M.UNAVAILABLE_MSG
	end

	vim.fn.mkdir(private_dir, "p")
	vim.fn.mkdir(shadow_dir, "p")

	local env = {
		YANA_JAIL_WORKSPACE = workspace,
		YANA_JAIL_SHADOW_DIR = shadow_dir,
		YANA_JAIL_PRIVATE_DIR = private_dir,
		YANA_JAIL_BWRAP = bwrap_bin(),
		HOME = vim.env.HOME or private_dir,
	}
	if opts.git_env then
		for k, v in pairs(opts.git_env) do
			env[k] = v
		end
	end

	return {
		cmd = { jb, "/bin/sh", "-c", inner },
		env = env,
		workspace = workspace,
		shadow_dir = shadow_dir,
		private_dir = private_dir,
	}, nil
end

--- Layer sub-paths for a turn. The overlay refuses a layer root holding
--- anything other than `upper/`, `work/` and its own mount marker, so every
--- turn needs its own root — and, since operator-declared write roots landed,
--- every ROOT of every turn needs its own too.
---
--- This returns the PRIMARY root's layer, which is what every caller written
--- before declared write roots means by "the turn's layer". `root_layer_paths`
--- answers the same question for one root of the set.
function M.layer_paths(session)
	local root = session and session.layer_dir
	if not root or root == "" then
		return nil
	end
	return { root = root, upper = root .. "/upper", work = root .. "/work" }
end

--- Layer sub-paths for ONE root of a turn.
function M.root_layer_paths(root)
	local dir = root and root.layer_dir
	if not dir or dir == "" then
		return nil
	end
	return {
		root = dir,
		upper = root.upper_dir or (dir .. "/upper"),
		work = root.work_dir or (dir .. "/work"),
	}
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
	-- Editor never mints layers/claims; launcher asks the daemon and mounts from the
	-- answer file's launch.layers.
	local session_id = session.yanad_session_id or session.session_id
	local turn_id = session.turn_id
	local mode = require("yana.config").resolve_mode(session.mode) or "inline"
	if turn_id == nil or tostring(turn_id) == "" then
		return nil, "yanad turn_id missing"
	end
	local private = M.private_dir(session)
	vim.fn.mkdir(private, "p")
	local answer_out = private .. "/yanad-answer.json"
	session.yanad_answer_out = answer_out

	local out = {
		ob,
		"--workspace",
		workspace,
		"--turn",
		tostring(turn_id),
		"--mode",
		tostring(mode),
		"--answer-out",
		answer_out,
	}
	if type(session_id) == "string" and session_id ~= "" then
		vim.list_extend(out, { "--session", session_id })
	else
		table.insert(out, "--session-auto")
	end

	-- Touched files for turn.request intersection (absolute). Prefer an
	-- explicit list; otherwise scan a pre-staged upper if the test path left
	-- one (legacy staging under private/stage/).
	local touched = session.touched_files
	if type(touched) ~= "table" or #touched == 0 then
		touched = {}
		local stage = private .. "/stage"
		if vim.fn.isdirectory(stage) == 1 then
			local files = vim.fn.glob(stage .. "/**/*", false, true)
			for _, path in ipairs(files) do
				if vim.fn.filereadable(path) == 1 then
					local rel = path:sub(#stage + 2)
					touched[#touched + 1] = workspace .. "/" .. rel
				end
			end
		end
	end
	for _, path in ipairs(touched) do
		vim.list_extend(out, { "--touched", diff.abs_path(path) })
	end

	--
	-- Read from the session `preview.begin_turn` built out of filesystem position and
	-- operator configuration; nothing in this process may widen it, and nothing a turn
	-- produced can reach it.
	local broad_root = session.broad_root
	if type(broad_root) == "string" and broad_root ~= "" and broad_root ~= workspace then
		vim.list_extend(out, { "--broad-root", broad_root })
	end

	-- One repeated group per operator-declared write root beyond the workspace,
	-- in the order `preview.resolve_roots` fixed (canonical-path order, which is
	-- also the launcher's claim order). A turn that declared none adds nothing
	-- here, so its argv is exactly the argv this function has always built.
	--
	-- Under yanad the daemon mints each root's layer; the editor only names the
	-- declared root path.
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
	if backend and type(backend.state_dirs) == "table" then
		for _, dir in ipairs(backend.state_dirs) do
			vim.list_extend(out, { "--state-dir", vim.fn.expand(dir) })
		end
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
M.WRITE_ROOT_REMEDY = jail_refusal.WRITE_ROOT_REMEDY
M.OUT_OF_WORKSPACE_REMEDIES = jail_refusal.OUT_OF_WORKSPACE_REMEDIES
M.declarable_write_root = jail_refusal.declarable_write_root
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

--- Run a shell command inside the jail. Returns ok, err_or_output, exit_code.
function M.run_shell(opts)
	local spec, err = M.build_shell_argv(opts)
	if not spec then
		return false, err, nil
	end
	local merged = merge_env({}, spec.env)
	local out = {}
	local job = vim.fn.jobstart(spec.cmd, {
		cwd = spec.workspace,
		env = merged,
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if data then
				vim.list_extend(out, data)
			end
		end,
		on_stderr = function(_, data)
			if data then
				vim.list_extend(out, data)
			end
		end,
	})
	if not job or job <= 0 then
		return false, "jobstart failed", nil
	end
	local wait = vim.fn.jobwait({ job })
	local code = wait[1]
	if code == -1 or code == -2 then
		code = 1
	end
	local output = table.concat(out, "\n")
	return code == 0, output, code
end

return M
