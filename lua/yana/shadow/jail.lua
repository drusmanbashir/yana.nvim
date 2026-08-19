-- Shadow confinement launchers.
--
-- Two launchers live here and they are not interchangeable.
--
-- `wrap_cmd` is the turn path: it runs the agent under `bin/yana-overlay`,
-- the kernel overlayfs confinement described by the isolation contract. The
-- real workspace is the read-only lower layer, the agent's writes land in a
-- private upper layer, and the workspace claim is taken and released explicitly
-- by that program.
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
--- turn needs its own root.
function M.layer_paths(session)
	local root = session and session.layer_dir
	if not root or root == "" then
		return nil
	end
	return { root = root, upper = root .. "/upper", work = root .. "/work" }
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
	local layer = M.layer_paths(session)
	if not layer then
		return nil, "overlay layer directory missing for this turn"
	end
	local workspace = diff.abs_path(session.workspace)
	vim.fn.mkdir(layer.upper, "p")
	vim.fn.mkdir(layer.work, "p")

	local out = {
		ob,
		"--workspace",
		workspace,
		"--upper",
		layer.upper,
		"--work",
		layer.work,
	}
	if session.claim_dir and session.claim_dir ~= "" then
		vim.list_extend(out, { "--claim", session.claim_dir })
	end
	vim.list_extend(out, { "--", "sh", "-c", 'cd "$1" && shift && exec "$@"', "_", workspace })
	vim.list_extend(out, argv)

	return out, {
		YANA_OVERLAY_BWRAP = bwrap_bin(),
	}
end

--- Run one shell command inside this turn's overlay and wait for it.
---
--- Exactly the argv the editor spawns through `jobstart`, waited on instead —
--- so a caller that is not the job runner (a headless test, a recovery tool)
--- exercises the production confinement rather than a second, weaker one.
function M.run_overlay_shell(session, cmd)
	local argv, env = M.wrap_cmd({ "/bin/sh", "-c", cmd }, session)
	if not argv then
		return false, tostring(env), -1
	end
	local ok, result = pcall(function()
		return vim.system(argv, { text = true, env = env }):wait()
	end)
	if not ok then
		return false, tostring(result), -1
	end
	return result.code == 0, (result.stderr or "") .. (result.stdout or ""), result.code
end

----------------------------------------------------------------------
-- claim lifecycle (the claims and concurrency contract)
----------------------------------------------------------------------

local function run_overlay_claim_cmd(args)
	local ob = M.overlay_bin()
	if not ob then
		return false, M.OVERLAY_UNAVAILABLE_MSG
	end
	local cmd = { ob }
	vim.list_extend(cmd, args)
	local ok, result = pcall(function()
		return vim.system(cmd, { text = true }):wait()
	end)
	if not ok then
		return false, tostring(result)
	end
	if result.code ~= 0 then
		local err = (result.stderr or ""):gsub("%s+$", "")
		return false, err ~= "" and err or ("yana-overlay exited " .. tostring(result.code))
	end
	return true, nil
end

--- Ordinary release: the review this claim was held for has closed.
function M.release_claim(claim_dir)
	if not claim_dir or claim_dir == "" then
		return false, "no claim directory"
	end
	return run_overlay_claim_cmd({ "release", "--claim", claim_dir })
end

--- Explicit, logged override. Only ever called from a deliberate user action —
--- never inferred from a dead process, per the module's "never guess dead".
function M.force_release_claim(claim_dir, reason)
	if not claim_dir or claim_dir == "" then
		return false, "no claim directory"
	end
	if not reason or reason == "" then
		return false, "force-release requires a reason"
	end
	return run_overlay_claim_cmd({ "force-release", "--claim", claim_dir, "--reason", reason })
end

--- This EDITOR's identity, in the same shape `bin/yana-overlay` writes for
--- a turn holder: `pid boot_id start_ticks`. The boot id makes the record
--- meaningless after a reboot, and the process start time makes it survive PID
--- reuse — a recycled pid has different start ticks, so a stale record can
--- never be mistaken for a live editor.
local function editor_identity()
	local pid = vim.fn.getpid()
	local boot = nil
	do
		local f = io.open("/proc/sys/kernel/random/boot_id", "r")
		if f then
			boot = (f:read("l") or ""):gsub("%s+$", "")
			f:close()
		end
	end
	local ticks = nil
	do
		local f = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
		if f then
			local line = f:read("l") or ""
			f:close()
			-- Field 22 is starttime, but the comm field can contain spaces and
			-- parentheses, so everything up to the LAST ')' is skipped first.
			local after = line:match("%)%s+(.*)$")
			if after then
				local fields = {}
				for w in after:gmatch("%S+") do
					fields[#fields + 1] = w
				end
				-- after the comm, starttime is field 20.
				ticks = fields[20]
			end
		end
	end
	if not boot or boot == "" or not ticks or ticks == "" then
		return nil
	end
	return string.format("%d %s %s", pid, boot, ticks)
end

--- Durable record that a review is open for this claim. Written while the
--- agent is still running so a crash leaves the claim recoverable rather than
--- looking abandoned. Mirrors the marker `bin/yana-turn --preview` writes.
---
--- IT CARRIES THE EDITOR'S IDENTITY, and that is the whole point of the record
--- rather than a detail of it. The claim's `holder` names the TURN process,
--- which legitimately exits when the agent finishes while the review
--- legitimately stays open here — so the holder being dead says nothing about
--- whether this review still exists. Until 2026-08-19 this marker was an empty
--- `touch`, so when an editor died with a review open there was no evidence
--- left behind that could prove it had gone, and the next session could only
--- fail closed and demand a force-release. Reported by the operator, who hit it
--- by closing nvim and reopening: "an owner that dies but lock stays".
---
--- With the identity here, a challenger can ask the question that matters — is
--- the editor that opened this review still running — and answer it the same
--- way the turn holder is already classified. A live editor still refuses, and
--- that is not a regression to route around: it is the pending change set being
--- protected.
function M.mark_review_open(claim_dir)
	if not claim_dir or claim_dir == "" or vim.fn.isdirectory(claim_dir) ~= 1 then
		return false
	end
	local ident = editor_identity()
	local f = io.open(claim_dir .. "/review-open", "w")
	if not f then
		return false
	end
	-- An identity that cannot be determined is written as nothing rather than
	-- as a guess. The reader treats a marker with no usable identity as
	-- unclassifiable and refuses, which is the same fail-closed answer the old
	-- empty marker produced -- so a host where /proc is unavailable is no worse
	-- off than before, and is never silently reclaimed.
	if ident then
		f:write(ident .. "\n")
	end
	f:close()
	return true
end

function M.review_open(claim_dir)
	return claim_dir ~= nil and claim_dir ~= "" and vim.fn.filereadable(claim_dir .. "/review-open") == 1
end

function M.claim_held(claim_dir)
	return claim_dir ~= nil and claim_dir ~= "" and vim.fn.isdirectory(claim_dir) == 1
end

--- Named holder of a claim, for refusal messages and force-release prompts.
function M.claim_holder(claim_dir)
	if not M.claim_held(claim_dir) then
		return nil
	end
	local f = io.open(claim_dir .. "/holder", "r")
	if not f then
		return "unknown"
	end
	local raw = f:read("*a") or ""
	f:close()
	raw = vim.trim(raw)
	return raw ~= "" and raw or "unknown"
end

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
