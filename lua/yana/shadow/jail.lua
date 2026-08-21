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

	-- THE BROAD ROOT (PLAN-R1-capture.md WI-1's argv contract, chosen by
	-- `preview.broad_root_for`): ONE overlay mounted at an ANCESTOR of the
	-- workspace instead of at the workspace, so a write into a sibling
	-- repository or a directory that does not exist yet lands in this turn's
	-- private upper layer rather than dying EROFS. The launcher validates it
	-- (must exist, must be an ancestor of the workspace) and refuses it
	-- alongside `--extra-root`.
	--
	-- Emitted only when it is BROADER than the workspace: a turn whose broad
	-- root IS its workspace builds exactly the argv it always built, so the
	-- single-root launch path -- and its measured latency -- is untouched.
	-- Read from the session `preview.begin_turn` built out of filesystem
	-- position and operator configuration; nothing in this process may widen
	-- it, and nothing a turn produced can reach it.
	local broad_root = session.broad_root
	if type(broad_root) == "string" and broad_root ~= "" and broad_root ~= workspace then
		vim.list_extend(out, { "--broad-root", broad_root })
	end

	-- One repeated group per operator-declared write root beyond the workspace,
	-- in the order `preview.resolve_roots` fixed (canonical-path order, which is
	-- also the launcher's claim order). A turn that declared none adds nothing
	-- here, so its argv is exactly the argv this function has always built.
	--
	-- The launcher, not this function, decides what happens when a root cannot
	-- be claimed: it takes the whole set or none of it, and exits 65 naming the
	-- root. Nothing in this process may widen the set — it is read from the
	-- session `preview.begin_turn` built out of operator configuration.
	local roots = require("yana.shadow.ops").session_roots(session)
	for i = 2, #roots do
		local root = roots[i]
		local paths = M.root_layer_paths(root)
		if not paths then
			return nil, "overlay layer directory missing for declared write root " .. tostring(root.workspace)
		end
		vim.fn.mkdir(paths.upper, "p")
		vim.fn.mkdir(paths.work, "p")
		vim.list_extend(out, {
			"--extra-root",
			diff.abs_path(root.workspace),
			"--extra-upper",
			paths.upper,
			"--extra-work",
			paths.work,
		})
		if root.claim_dir and root.claim_dir ~= "" then
			vim.list_extend(out, { "--extra-claim", root.claim_dir })
		end
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
		-- The turn's private dir and its overlay layer are SIBLINGS under the
		-- state root (`turns/...` and `layers/...`), never nested, so the test
		-- is containment in the state root -- not in the layer.
		local state_root = require("yana.shadow.preview").state_root()
		local base = session.private_dir
		if type(base) ~= "string" or base == "" then
			base = (type(layer.root) == "string" and layer.root or "") .. "/private"
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

	vim.list_extend(out, { "--", "sh", "-c", 'cd "$1" && shift && exec "$@"', "_", workspace })
	vim.list_extend(out, argv)

	local env = {
		YANA_OVERLAY_BWRAP = bwrap_bin(),
	}
	if inline_exec_allowlist_active then
		env.YANA_INLINE_EXEC_ALLOWLIST_ACTIVE = "1"
		env.YANA_INLINE_EXEC_ALLOW_PATH = session.inline_exec_allow_path
	end
	return out, env
end

----------------------------------------------------------------------
-- confinement refusals: a write the jail refused, kept as evidence
----------------------------------------------------------------------
--
-- The jail binds ONLY the claimed workspace writable. `bin/yana-overlay`
-- binds the whole host `--ro-bind / /` and `bin/yana-overlay-inner` mounts
-- exactly one overlay, at the workspace's own absolute path, so anything
-- beside the workspace is reachable through the read-only bind and nothing
-- else: a write into it fails EROFS by construction of the mount table, with
-- no per-path check anywhere. That refusal is correct. What was wrong is that
-- it happened in SILENCE — the operator's editor showed a turn that "worked"
-- while the half of the work that lived in a sibling repository never
-- happened, and the only account of it was the agent's own narration, which
-- is not a yana surface.
--
-- This module is the one place in the editor process that holds the
-- confinement's OWN result for a command yana launched into it: the exit
-- status, and the failing process's `strerror`. `run_overlay_shell` records
-- that here; `ui.lua`'s turn-completion path forwards it into the same
-- `system_refused` machinery every other refusal already uses.

--- Why the write died, in the product's voice.
M.OUT_OF_WORKSPACE_REASON = "the path is outside the claimed workspace, which yana confines by design"

--- What the operator can do about it TODAY. THE SINGLE PLACE this is written.
---
--- Every surface that shows a refused write (panel note, `:YanaRefusals` row,
--- ledger decision, the durable WARN) reads its remedy from here, so
--- operator-declared write roots landed as ONE new entry in this list rather
--- than as four drifting copies of a sentence. Nothing is promised here that
--- does not exist today: `write_roots` ships (`lua/yana/config.lua` and the
--- external-roots module doc), and the other two lines are what they
--- always were.
---
--- The first entry carries a `<dir>` placeholder because the actionable
--- remedy names a REAL directory, and which directory that is can only be
--- known per refusal. `out_of_workspace_remedy` fills it from filesystem
--- state; when nothing can be derived the entry is dropped rather than
--- printed with a placeholder in it, which leaves exactly the two-line
--- message this list carried before.
M.WRITE_ROOT_REMEDY = 1
M.OUT_OF_WORKSPACE_REMEDIES = {
	'declare it in your yana setup: write_roots = { "<dir>" }',
	"run the turn from that repository",
	"or ask for the change as a patch and apply it there yourself",
}

--- The directory the operator would actually declare to make this write legal.
---
--- DERIVED FROM THE FILESYSTEM, NEVER FROM TEXT. The refused path itself comes
--- from the confinement's own errno message and is checked against what yana
--- knows (see `nameable_paths`); this function then walks that path's real
--- ancestors and answers with the nearest one that is a repository — the unit
--- an operator thinks in and the unit a claim is taken on. With no repository
--- above it the answer is the containing directory, which is the smallest root
--- that would have allowed the write. Nothing the agent said can reach this
--- decision, which is the cardinal principle applied to a REMEDY as well as to
--- a boundary: the sentence is only a suggestion, but a suggestion assembled
--- out of agent text is how scope creep starts.
---
--- Returns nil rather than "/" or an empty string: a remedy that proposes the
--- filesystem root is not a remedy.
function M.declarable_write_root(path)
	if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" then
		return nil
	end
	local dir = path
	if vim.fn.isdirectory(dir) ~= 1 then
		dir = vim.fn.fnamemodify(dir, ":h")
	end
	local probe, depth = dir, 0
	while probe and probe ~= "" and probe ~= "/" and depth < 64 do
		-- `.git` is a directory in a normal clone and a FILE in a worktree or a
		-- submodule; both mean "this is the repository root".
		if vim.fn.isdirectory(probe .. "/.git") == 1 or vim.fn.filereadable(probe .. "/.git") == 1 then
			return probe
		end
		probe = vim.fn.fnamemodify(probe, ":h")
		depth = depth + 1
	end
	if dir == "" or dir == "/" or vim.fn.isdirectory(dir) ~= 1 then
		return nil
	end
	return dir
end

--- The remedy sentence, specialised to the paths this refusal names.
---
--- Called with no argument it returns exactly the sentence it always returned,
--- so every caller that has not been taught about roots is unchanged.
function M.out_of_workspace_remedy(paths)
	local root
	for _, path in ipairs(paths or {}) do
		root = M.declarable_write_root(path)
		if root then
			break
		end
	end
	local lines = {}
	for i, line in ipairs(M.OUT_OF_WORKSPACE_REMEDIES) do
		if i == M.WRITE_ROOT_REMEDY then
			if root then
				lines[#lines + 1] = (line:gsub("<dir>", (root:gsub("%%", "%%%%"))))
			end
		else
			lines[#lines + 1] = line
		end
	end
	return "remedy: " .. table.concat(lines, ", ")
end

--- `strerror(EROFS)` as any libc renders it, and the errno's own symbol as the
--- runtimes that print symbols use it (node's `EROFS: read-only file system`).
---
--- THIS IS THE ONLY THING THAT MAY RAISE A REFUSAL RECORD. The selection is
--- the confinement's own errno, carried out of a process yana itself launched
--- into the jail — never the agent's event stream. `diff.tool_summary` prose
--- can neither create a record here nor suppress one.
local EROFS_TOKENS = { "read-only file system", "erofs" }

local MAX_REFUSALS_PER_TURN = 20
local MAX_PATHS_PER_REFUSAL = 8
local MAX_EVIDENCE = 200

--- The failure's own line, normalised for a one-line surface.
local function erofs_evidence(output)
	if type(output) ~= "string" or output == "" then
		return nil
	end
	for line in output:gmatch("[^\r\n]+") do
		local low = line:lower()
		for _, token in ipairs(EROFS_TOKENS) do
			if low:find(token, 1, true) then
				local clean = line:gsub("%c", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
				if #clean > MAX_EVIDENCE then
					clean = clean:sub(1, MAX_EVIDENCE) .. "…"
				end
				return clean
			end
		end
	end
	return nil
end

local function under(path, root)
	if not root or root == "" then
		return false
	end
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- Which absolute paths this refusal may NAME.
---
--- Candidates are read from the failure's own text (the confined process's
--- message first, then the command yana handed the jail), and every one of
--- them is then CHECKED against what yana knows for itself:
---
---   * it must lie outside the claimed workspace — the classification is
---     yana's, not the text's, so no message from any source can make an
---     in-workspace path look refused;
---   * it must not be this turn's own confinement machinery (layer, claim,
---     private dir), which is yana's plumbing and not the operator's work;
---   * its parent must be a directory THIS USER really owns, which is what
---     makes the remedy actionable at all;
---   * it must not be an executable the command invoked — the interpreter or
---     tool the jail ran is reached through the read-only bind and was never
---     a write target. `/usr/bin/python3` appearing in a failing command is
---     not a refused write, and naming it would be a falsehood on an
---     operator surface.
---
--- The last rule can under-name (a write to an existing executable file in a
--- sibling repo is not listed). That is the deliberate direction of the
--- trade: the refusal is still recorded and still carries its reason, remedy
--- and the confinement's own evidence line — only the path list is shorter.
--- Over-naming would put a write the turn never attempted on the record.
local function under_any(paths, roots)
	for _, path in ipairs(paths) do
		for _, root in ipairs(roots) do
			if under(path, root) then
				return true
			end
		end
	end
	return false
end

local function root_list(...)
	local roots = {}
	-- `select("#", ...)` rather than `ipairs{...}`: a nil in the middle (a turn
	-- whose layer was already recovered away) must skip that root, not truncate
	-- the list and silently stop excluding the ones after it.
	for i = 1, select("#", ...) do
		local root = select(i, ...)
		if type(root) == "string" and root ~= "" then
			roots[#roots + 1] = root
		end
	end
	return roots
end

local function nameable_paths(texts, session)
	-- Both the resolved and the literal form of every root: a workspace reached
	-- through a symlink must still count as inside itself, or its own files
	-- would be named as "outside the claimed workspace".
	local ws = type(session.workspace) == "string" and session.workspace or ""
	local ws_roots = ws ~= "" and root_list(diff.abs_path(ws), vim.fs.normalize(ws)) or {}
	local machinery_roots =
		root_list(session.layer_dir, session.upper_dir, session.claim_dir, session.private_dir)
	local seen, out = {}, {}
	for _, text in ipairs(texts) do
		if type(text) == "string" then
			for token in text:gmatch("/[^%s'\"`,;:%(%)%[%]<>|]+") do
				local cand = token:gsub("[%.,;:%)%]]+$", "")
				if #out < MAX_PATHS_PER_REFUSAL and #cand > 1 and not seen[cand] then
					seen[cand] = true
					local forms = { cand, diff.abs_path(cand) }
					if
						not under_any(forms, ws_roots)
						and not under_any(forms, machinery_roots)
						and vim.fn.filewritable(vim.fn.fnamemodify(cand, ":h")) == 2
						and vim.fn.executable(cand) ~= 1
					then
						out[#out + 1] = cand
					end
				end
			end
		end
	end
	return out
end

--- Attach one refusal to the turn it happened in.
---
--- Kept on the session because the session IS the turn: `ui.lua`'s
--- `finalize_shadow_turn` already holds it, so the record needs no new channel
--- and no new lifetime. Created lazily and bounded, so a turn with no refused
--- write carries no field at all and behaves exactly as it did before.
local function record_confinement_refusal(session, cmd, output, code)
	if type(session) ~= "table" or type(code) ~= "number" or code <= 0 then
		return nil
	end
	local evidence = erofs_evidence(output)
	if not evidence then
		return nil
	end
	local rows = session.confinement_refusals
	if not rows then
		rows = {}
		session.confinement_refusals = rows
	end
	if #rows >= MAX_REFUSALS_PER_TURN then
		session.confinement_refusals_dropped = (session.confinement_refusals_dropped or 0) + 1
		return nil
	end
	local row = {
		turn = session.turn_id,
		workspace = diff.abs_path(session.workspace or ""),
		paths = nameable_paths({ output, cmd }, session),
		evidence = evidence,
		exit_code = code,
	}
	rows[#rows + 1] = row
	local ok_record, record = pcall(require, "yana.record")
	if ok_record and record.enabled() and type(session.private_dir) == "string" and session.private_dir ~= "" then
		if #row.paths > 0 then
			for _, path in ipairs(row.paths) do
				record.append_stream_line(session.private_dir, {
					type = "refusal",
					status = "system_refused",
					path = path,
					evidence = evidence,
					exit_code = code,
				})
			end
		else
			record.append_stream_line(session.private_dir, {
				type = "refusal",
				status = "system_refused",
				evidence = evidence,
				exit_code = code,
			})
		end
	end
	local ok_log, log = pcall(require, "yana.log")
	if ok_log and #row.paths > 0 then
		for _, path in ipairs(row.paths) do
			log.lifecycle("refusal.system_refused", {
				status = "system_refused",
				path = path,
				evidence = evidence,
				exit_code = code,
				turn_id = session.turn_id,
			})
		end
	end
	return row
end

local function log_jail_writes(session, cmd)
	if type(session) ~= "table" or type(cmd) ~= "string" or cmd == "" then
		return
	end
	local ok_record, record = pcall(require, "yana.record")
	if not ok_record or not record.enabled() then
		return
	end
	local private_dir = session.private_dir
	if not private_dir or private_dir == "" then
		return
	end
	for target in cmd:gmatch("[>]+%s*['\"]?([^'\"%s;|&]+)") do
		target = target:gsub("^['\"]", ""):gsub("['\"]$", "")
		if target ~= "" and not target:match("^%-") then
			record.append_stream_line(private_dir, {
				type = "tool_call",
				subtype = "completed",
				tool_call = { writeToolCall = { args = { path = target } } },
			})
		end
	end
end

--- Run one shell command inside this turn's overlay and wait for it.
---
--- Exactly the argv the editor spawns through `jobstart`, waited on instead —
--- so a caller that is not the job runner (a headless test, a recovery tool)
--- exercises the production confinement rather than a second, weaker one.
---
--- The `(ok, output, code)` triple is also the confinement's own account of a
--- write it refused. A failing command whose output carries `strerror(EROFS)`
--- leaves a record on the turn (see above) so the turn-completion path can
--- surface it. The triple itself is unchanged: recording is a side effect on
--- the session, never a change of return shape, and a command that did not
--- die read-only leaves nothing behind.
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
	local output = (result.stderr or "") .. (result.stdout or "")
	-- The launcher has been and gone, so every root's claim -- and therefore
	-- every root's acquisition token -- is on disk now if this launch took it.
	-- Recorded here because this is the one launch path that runs to completion
	-- inside the editor process; the job-runner path records the same tokens
	-- from `preview.arm_review_open`'s poll, at the equivalent moment.
	pcall(M.capture_root_nonces, session)
	-- Never let bookkeeping about a refusal change the outcome of the command
	-- it describes: fix-8's guarantee is that a surfaced refusal cannot wedge a
	-- turn, and that starts here.
	pcall(record_confinement_refusal, session, cmd, output, result.code)
	if result.code == 0 then
		pcall(log_jail_writes, session, cmd)
	end
	return result.code == 0, output, result.code
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

--- Read each root's acquisition token out of the claim the launcher committed.
---
--- The token is minted by `bin/yana-overlay` at acquisition -- the editor is
--- not the acquirer -- so it does not exist until a launch has happened, and it
--- changes when a claim is reacquired. This refreshes rather than fills once:
--- the record is evidence about the acquisition the turn holds NOW, and a stale
--- token would be a worse record than none.
---
--- Best effort and never decisive. Release stays path-keyed, which is what
--- fix-8's "the claim always releases" depends on; nothing here can wedge a
--- turn, and a root whose token cannot be read keeps the value it had.
function M.capture_root_nonces(session)
	local roots = require("yana.shadow.ops").session_roots(session)
	for _, root in ipairs(roots) do
		if root.claim_dir and root.claim_dir ~= "" then
			local f = io.open(root.claim_dir .. "/nonce", "r")
			if f then
				local token = (f:read("l") or ""):gsub("%s+$", "")
				f:close()
				if token ~= "" then
					root.nonce = token
				end
			end
		end
	end
	return session
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
