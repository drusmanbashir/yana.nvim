-- Preview mode turn lifecycle: jailed agent → typed op report → discard.
--
-- There is no snapshot step. CORE, "No whole-repository work": the overlay
-- lower layer IS the before-picture, so copying the workspace at turn start
-- re-derived information the kernel already held. Starting a turn now costs
-- three mkdirs regardless of how large the repository is.
local M = {}

local config = require("yana.config")
local diff = require("yana.diff")
local hash = require("yana.safety.hash")
local jail = require("yana.shadow.jail")
local manifest = require("yana.manifest")
local ops = require("yana.shadow.ops")
local claim_identity = require("yana.claim_identity")
local uv = vim.uv or vim.loop

local REFUSED_MAX_FILE_BYTES = 8 * 1024 * 1024
local REFUSED_MAX_TURN_BYTES = 64 * 1024 * 1024
local REFUSED_KEEP_TURNS = 5
local REFUSED_KEEP_SECONDS = 7 * 24 * 60 * 60

M.REFUSED_LIMITS = {
	file_bytes = REFUSED_MAX_FILE_BYTES,
	turn_bytes = REFUSED_MAX_TURN_BYTES,
	turns = REFUSED_KEEP_TURNS,
	seconds = REFUSED_KEEP_SECONDS,
}

M._config = {
	state_root = vim.fn.expand("~/.local/state/yana"),
}

M._test = {
	force_state_root = nil,
}

--- Where per-turn state lives. Matches `bin/yana-turn`'s `$STATE_ROOT`, so
--- a claim taken by the editor and one taken by the CLI collide as they should.
---
--- Precedence, byte-compatible with bin/yana-turn's shell resolver: YANA_STATE_ROOT,
--- then XDG_STATE_HOME/yana, then $HOME/.local/state/yana. A host with a
--- writable XDG_STATE_HOME but a read-only/minimal $HOME must still land the
--- editor on the same directory as the CLI.
function M.state_root()
	if M._test.force_state_root then
		return M._test.force_state_root
	end
	local env = vim.env.YANA_STATE_ROOT
	if env and env ~= "" then
		return env
	end
	local xdg = vim.env.XDG_STATE_HOME
	if xdg and xdg ~= "" then
		return xdg .. "/yana"
	end
	return M._config.state_root
end

function M.enabled()
	local mode = config.overlay_mode() and "apply" or "off"
	return mode == "preview" or mode == "apply"
end

function M.apply_enabled()
	return config.review_mode_active()
end

function M.mode()
	return config.overlay_mode() and "apply" or "off"
end

--- Which directory the turn is ABOUT, from the editor's own position.
---
--- The candidate is the open buffer's directory, else the origin's directory,
--- else cwd -- unchanged from the shape this function has always had, and read
--- only from the editor, never from anything a turn produced.
local function workspace_candidate(opts)
	local cwd = diff.abs_path(opts.cwd or vim.fn.getcwd())
	local selection = opts.selection
	local origin = opts.origin

	if selection and selection.buf and vim.api.nvim_buf_is_valid(selection.buf) then
		local name = vim.api.nvim_buf_get_name(selection.buf)
		if name ~= "" then
			return vim.fn.fnamemodify(diff.abs_path(name), ":h")
		end
	end
	if origin and origin.name and origin.name ~= "" then
		local abs = origin.name:match("^/") and origin.name or diff.abs_path(origin.name)
		if vim.fn.isdirectory(abs) == 1 then
			return abs
		end
		return vim.fn.fnamemodify(abs, ":h")
	end
	return cwd
end

--- THE TURN'S WORKSPACE: the repository the candidate directory belongs to.
---
--- WI-3 (PLAN-R1-capture.md §3 and §8 row 3, issue-log row 3). This used to be
--- the candidate itself -- the FILE'S OWN DIRECTORY when a file was open -- so
--- a turn opened on `utilz/utilz/fileio.py` claimed `utilz/utilz`, mounted its
--- overlay there, and refused a write to a file one directory over IN THE SAME
--- REPOSITORY with EROFS. The repository is the unit a claim is taken on and
--- the unit an operator thinks in, so it is the unit a turn runs in.
---
--- Order, decided in PLAN §8 row 3:
---   1. the nearest `.git` root at or above the candidate
---   2. otherwise the configured `workspace_roots` entry that contains it
---      (nearest first -- `normalize_workspace_roots` sorts longest first)
---   3. otherwise the candidate itself, the local folder
---
--- A repository beats a configured entry deliberately: `workspace_roots` says
--- "this directory is a workspace even though it holds no `.git`", never "treat
--- these repositories as one".
---
--- CARDINAL PRINCIPLE. Every step is a filesystem or operator-configuration
--- question. Nothing an agent emitted can reach any of them.
function M.resolve_workspace(candidate)
	local abs = diff.abs_path(candidate)
	local git = claim_identity.git_root(abs)
	if git then
		return git
	end
	for _, root in ipairs((config.options and config.options.workspace_roots) or {}) do
		if abs == root or abs:sub(1, #root + 1) == root .. "/" then
			return root
		end
	end
	return abs
end

--- The turn workspace: the repository the file under edit lives in.
function M.workspace_for_turn(opts)
	opts = opts or {}
	local candidate = workspace_candidate(opts)
	-- WI-3. Reverting this ONE line to `return candidate` is the pre-WI-3
	-- shape and is exactly the mutation
	-- tests/headless/workspace_resolution.lua drives.
	return M.resolve_workspace(candidate)
end

--- Workspace slug, byte-identical to the one `bin/yana-turn` computes
--- (sha256 of the filesystem identity, first 16 hex chars) so a claim taken by the
--- editor and a claim taken by the CLI collide as they should.
local function workspace_slug(workspace)
	return claim_identity.workspace_slug(workspace)
end

function M.claim_dir(workspace)
	return M.state_root() .. "/claims/" .. workspace_slug(workspace)
end

function M.layer_dir(workspace, stream, turn_id)
	return table.concat({
		M.state_root(),
		"layers",
		workspace_slug(workspace),
		stream,
		tostring(turn_id),
	}, "/")
end

--- Per-turn scratch that is not the layer: the private directory the agent's
--- relocated caches land in. Nothing about the workspace is copied here.
function M.turn_dir(workspace, stream, turn_id)
	return table.concat({
		M.state_root(),
		"turns",
		workspace_slug(workspace),
		stream,
		tostring(turn_id),
	}, "/")
end

--- True when two absolute paths are the same directory or one contains the
--- other. Pathnames only: the launcher repeats the same question by filesystem
--- identity, which is what catches a bind alias, and refuses there.
local function paths_overlap(a, b)
	if not a or not b or a == "" or b == "" then
		return false
	end
	return a == b or a:sub(1, #b + 1) == b .. "/" or b:sub(1, #a + 1) == a .. "/"
end

--- Every root this turn may write, in the order their claims are taken.
---
--- THE SET IS THE OPERATOR'S, CANONICALISED HERE AND NOWHERE ELSE. CORE's
--- cardinal principle: nothing agent-influenced selects confinement scope, so
--- `declared` arrives from `config.options.write_roots` (setup, or an explicit
--- operator command) and every entry is judged against the filesystem, never
--- against anything a turn produced. A root read out of workspace content or
--- agent output is a defect, not a configuration.
---
--- Refusals name the root, and they happen at TURN START, before the agent is
--- launched: a turn that would silently drop half its work is refused instead,
--- which is the whole reported defect (packets/redrow-multiroot-20260820.md).
---
--- Returns `roots` (a list of absolute paths, the workspace first, the declared
--- roots after it in canonical-path order) or `nil, reason`.
function M.resolve_roots(workspace, declared)
	local primary = diff.abs_path(workspace)
	local primary_real = uv.fs_realpath(primary) or primary
	local state_root = uv.fs_realpath(M.state_root()) or M.state_root()

	local extras, seen = {}, {}
	for _, entry in ipairs(declared or {}) do
		local real = uv.fs_realpath(entry)
		if not real then
			return nil,
				string.format(
					"declared write root '%s' does not exist — create it or remove it from write_roots",
					entry
				)
		end
		if vim.fn.isdirectory(real) ~= 1 then
			return nil, string.format("declared write root '%s' is not a directory", entry)
		end
		-- The turn's own machinery is not a work root. A root at or inside the
		-- state root would hand the agent the very layers, claims and journals
		-- its own change set is read from.
		if paths_overlap(real, state_root) then
			return nil,
				string.format(
					"declared write root '%s' resolves inside yana's state root (%s) — declare a project directory instead",
					entry,
					state_root
				)
		end
		if paths_overlap(real, primary_real) or paths_overlap(real, primary) then
			return nil,
				string.format(
					"declared write root '%s' overlaps the opened workspace (%s) — the workspace is always root 1 and is never listed in write_roots",
					entry,
					primary
				)
		end
		for _, other in ipairs(extras) do
			if paths_overlap(real, other) then
				return nil,
					string.format(
						"declared write root '%s' overlaps declared write root '%s' — roots must be disjoint (equal, ancestor or descendant is refused)",
						entry,
						other
					)
			end
		end
		if not seen[real] then
			seen[real] = true
			extras[#extras + 1] = real
		end
	end
	table.sort(extras)

	local roots = { primary }
	vim.list_extend(roots, extras)
	return roots
end

--- THE BROAD ROOT: the ONE directory this turn's single overlay is mounted at.
---
--- WI-3/WI-4 (PLAN-R1-capture.md §1). Everything beneath it is writable inside
--- the jail and lands in the turn's private upper layer -- the opened
--- repository, a sibling repository, a directory that did not exist when the
--- turn started -- and everything outside it stays the plain read-only host
--- bind. The kernel charges the same ~31 ms to mount an overlay over a broad
--- root as over one directory, so breadth is free; what is not free is a
--- SECOND mount and a SECOND claim, and there is exactly one of each.
---
--- Chosen, in order:
---   1. `capture_root`, the operator's explicit choice;
---   2. a SINGLE `write_roots` entry that is an ancestor of the workspace --
---      the narrowing override the external-roots module doc describes (an
---      entry that is a SIBLING of the workspace is a declared write root in
---      the older sense and is left to `resolve_roots`);
---   3. `$HOME/code` when it is an ancestor of the resolved workspace;
---   4. `$HOME` when it is;
---   5. the workspace itself.
---
--- THE STATE ROOT IS NEVER INSIDE IT. yana's layers, claims and journals are
--- the evidence this turn's review is read from; an overlay covering them
--- would hand the agent its own change set. A default candidate that contains
--- the state root is skipped (which is why an ordinary `~/.local/state/yana`
--- install lands on `~/code` and not on `$HOME`); an explicitly configured one
--- refuses the turn BY NAME, because silently narrowing an operator's own
--- setting is worse than saying so.
---
--- CARDINAL PRINCIPLE: config and filesystem position only. No step reads
--- anything a turn produced.
---
--- Returns the absolute broad root, or nil plus a reason.
local function contains_path(root, path)
	if not root or root == "" or not path or path == "" then
		return false
	end
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

function M.broad_root_for(workspace, declared)
	local ws = diff.abs_path(workspace)
	local ws_real = uv.fs_realpath(ws) or ws
	local state = uv.fs_realpath(M.state_root()) or M.state_root()

	local override, override_key = config.options.capture_root, "capture_root"
	if not override and type(declared) == "table" and #declared == 1 then
		local only = uv.fs_realpath(declared[1]) or declared[1]
		-- A STRICT ancestor only. An entry EQUAL to the workspace says nothing
		-- ("the workspace is always root 1 and is never listed in
		-- `write_roots`") and keeps the named refusal `resolve_roots` has always
		-- raised for it; an entry that is a sibling is a declared write root in
		-- the older sense and is left to `resolve_roots` too.
		if only ~= ws_real and only ~= ws and contains_path(only, ws_real) then
			override, override_key = declared[1], "write_roots"
		end
	end

	if override then
		local real = uv.fs_realpath(override)
		if not real or vim.fn.isdirectory(real) ~= 1 then
			return nil,
				string.format("%s '%s' does not exist or is not a directory", override_key, override)
		end
		if not contains_path(real, ws_real) then
			return nil,
				string.format(
					"%s '%s' is not an ancestor of this turn's workspace (%s) — the capture root must contain the "
						.. "repository the turn runs in",
					override_key,
					real,
					ws_real
				)
		end
		if contains_path(real, state) then
			return nil,
				string.format(
					"%s '%s' contains yana's own state root (%s) — choose a directory that does not, or move the "
						.. "state root (YANA_STATE_ROOT / XDG_STATE_HOME)",
					override_key,
					real,
					state
				)
		end
		return real, override_key
	end

	local home = vim.env.HOME or ""
	if home ~= "" then
		home = home:gsub("/+$", "")
		for _, candidate in ipairs({ home .. "/code", home }) do
			local real = uv.fs_realpath(candidate)
			if real and vim.fn.isdirectory(real) == 1 and contains_path(real, ws_real) and not contains_path(real, state) then
				return real, "default"
			end
		end
	end
	return ws, "workspace"
end

local function directory_empty(path)
	local scan = uv.fs_scandir(path)
	if not scan then
		return true
	end
	return uv.fs_scandir_next(scan) == nil
end

--- Remove expired durable refusal trees without touching any sibling feature
--- data in the same turn directories. Ordering is by filesystem mtime because
--- editor-local turn ids reset and do not define a global chronology.
local function prune_refused_turns(stream_turns_dir)
	local scan = uv.fs_scandir(stream_turns_dir)
	if not scan then
		return
	end
	local retained = {}
	while true do
		local name, typ = uv.fs_scandir_next(scan)
		if not name then
			break
		end
		if typ == "directory" then
			local turn_path = stream_turns_dir .. "/" .. name
			local refused_path = turn_path .. "/refused"
			local stat = uv.fs_stat(refused_path)
			if stat and stat.type == "directory" then
				retained[#retained + 1] = {
					turn_path = turn_path,
					refused_path = refused_path,
					mtime = stat.mtime and stat.mtime.sec or 0,
				}
			end
		end
	end
	table.sort(retained, function(a, b)
		if a.mtime == b.mtime then
			return a.refused_path > b.refused_path
		end
		return a.mtime > b.mtime
	end)
	local now = os.time()
	for i, item in ipairs(retained) do
		if i > REFUSED_KEEP_TURNS or now - item.mtime > REFUSED_KEEP_SECONDS then
			pcall(vim.fn.delete, item.refused_path, "rf")
			if directory_empty(item.turn_path) then
				pcall(vim.fn.delete, item.turn_path, "d")
			end
		end
	end
end

local function prune_recovered(stream_recovery_dir)
	local scan = uv.fs_scandir(stream_recovery_dir)
	if not scan then
		return
	end
	local rows = {}
	while true do
		local name, typ = uv.fs_scandir_next(scan)
		if not name then
			break
		end
		if typ == "directory" then
			local path = stream_recovery_dir .. "/" .. name
			local stat = uv.fs_stat(path)
			rows[#rows + 1] = { path = path, mtime = stat and stat.mtime and stat.mtime.sec or 0 }
		end
	end
	table.sort(rows, function(a, b)
		return a.mtime > b.mtime
	end)
	local now = os.time()
	for i, row in ipairs(rows) do
		if i > REFUSED_KEEP_TURNS or now - row.mtime > REFUSED_KEEP_SECONDS then
			pcall(vim.fn.delete, row.path, "rf")
		end
	end
end

--- Evidence about a claim that is still held as a new turn begins, or nil.
---
--- Reads only: this decides nothing. `bin/yana-overlay` is the only thing that
--- may classify a holder or take a claim away from one, and it does so under
--- its own lock; this is the editor recording what it saw so the reclaim the
--- launcher performs can be reported afterwards instead of happening silently.
local function stale_claim_evidence(claim_dir)
	if not claim_dir or claim_dir == "" or vim.fn.isdirectory(claim_dir) ~= 1 then
		return nil
	end
	local pid
	local f = io.open(claim_dir .. "/holder", "r")
	if f then
		pid = tonumber(((f:read("l") or ""):match("^(%d+)")))
		f:close()
	end
	return { pid = pid, review_open = jail.review_open(claim_dir) }
end

function M.begin_turn(opts)
	opts = opts or {}
	-- Finalize runs after the agent exits and may outlive this runtime path
	-- during a plugin update. Pin its applier now, while the turn's code is
	-- known to exist, so a later directory rename cannot strand the claim.
	require("yana.shadow.apply")
	if not M.enabled() then
		return nil, "shadow mode disabled"
	end
	if not jail.available() then
		return nil, jail.OVERLAY_UNAVAILABLE_MSG
	end

	local workspace = diff.abs_path(opts.workspace or M.workspace_for_turn(opts))
	local stream = opts.stream or "default"
	local turn_id = tostring(opts.turn_id or opts.turn_gen or "0")

	-- Declared roots are resolved BEFORE any per-turn state is created: a turn
	-- that cannot have the set it declared must not leave a layer, a claim or a
	-- turn directory behind for the next one to trip over.
	local declared = opts.write_roots
	if declared == nil then
		declared = config.options.write_roots
	end

	-- THE BROAD ROOT IS CHOSEN BEFORE ANY PER-TURN STATE EXISTS, for the same
	-- reason the declared set is: a turn that cannot have the scope it was
	-- configured for must not leave a layer, a claim or a turn directory behind
	-- for the next one to trip over.
	local broad_root, broad_why = M.broad_root_for(workspace, declared)
	if not broad_root then
		return nil, broad_why
	end
	-- A single `write_roots` entry that is an ancestor of the workspace IS the
	-- broad root, not a second root to mount and claim.
	if broad_why == "write_roots" then
		declared = {}
	end

	local root_paths, roots_err = M.resolve_roots(workspace, declared)
	if not root_paths then
		return nil, roots_err
	end
	-- One kernel mount. A configured capture root and a declared write root are
	-- two answers to the same question, and the launcher refuses the pair in
	-- the same words (`--broad-root cannot be combined with --extra-root`).
	if #root_paths > 1 and config.options.capture_root then
		return nil,
			string.format(
				"capture_root '%s' cannot be combined with declared write_roots — the broad root already covers "
					.. "every directory beneath it",
				config.options.capture_root
			)
	end

	local turn_dir = M.turn_dir(workspace, stream, turn_id)
	local private_dir = turn_dir .. "/private"
	-- A panel-local turn id can be reused after an editor restart. Never let a
	-- same-id durable refusal from that earlier process authenticate this turn.
	pcall(vim.fn.delete, turn_dir .. "/refused", "rf")
	vim.fn.mkdir(private_dir, "p")
	prune_refused_turns(vim.fn.fnamemodify(turn_dir, ":h"))

	-- A stale layer root from a turn that died mid-flight would make the
	-- overlay refuse this one ("layer root must contain only upper/, work/").
	local layer_dir = M.layer_dir(workspace, stream, turn_id)
	pcall(vim.fn.delete, layer_dir, "rf")
	vim.fn.mkdir(layer_dir .. "/upper", "p")
	vim.fn.mkdir(layer_dir .. "/work", "p")

	-- One layer and one claim per declared root. Root 1 is the workspace and
	-- keeps the layer built above, so a single-root turn creates exactly what it
	-- always created; each extra root gets the same treatment under its own
	-- workspace slug, which is also what makes its claim collide with another
	-- editor's claim on that same repository, as it must.
	local roots = {
		{
			index = 1,
			primary = true,
			workspace = workspace,
			layer_dir = layer_dir,
			upper_dir = layer_dir .. "/upper",
			work_dir = layer_dir .. "/work",
			claim_dir = M.claim_dir(workspace),
			-- Filled in by capture_root_nonces once the launcher has committed
			-- this root's claim; empty until then, because the token is minted
			-- by the acquisition and the editor is not the acquirer.
			nonce = "",
		},
	}
	for i = 2, #root_paths do
		local root = root_paths[i]
		local root_layer = M.layer_dir(root, stream, turn_id)
		pcall(vim.fn.delete, root_layer, "rf")
		vim.fn.mkdir(root_layer .. "/upper", "p")
		vim.fn.mkdir(root_layer .. "/work", "p")
		roots[#roots + 1] = {
			index = i,
			primary = false,
			workspace = root,
			layer_dir = root_layer,
			upper_dir = root_layer .. "/upper",
			work_dir = root_layer .. "/work",
			claim_dir = M.claim_dir(root),
			nonce = "",
		}
	end

	local session = {
		workspace = workspace,
		-- The ONE directory this turn's overlay is mounted at, and the base the
		-- finalize walk's relative paths are read against. Equal to `workspace`
		-- when nothing broader was chosen, which is byte-for-byte the turn yana
		-- always ran. Nil when the turn has declared write roots, which is the
		-- older per-root shape and keeps its own launcher path.
		broad_root = (#root_paths == 1) and broad_root or nil,
		stream = stream,
		turn_id = turn_id,
		turn_gen = opts.turn_gen,
		turn_dir = turn_dir,
		private_dir = private_dir,
		layer_dir = layer_dir,
		upper_dir = layer_dir .. "/upper",
		claim_dir = M.claim_dir(workspace),
		-- What this turn will have to take the claim AWAY from, observed before
		-- the launcher runs. A claim directory still on disk at this moment
		-- belongs to a turn that never released -- the editor that owned it died
		-- with its review on screen -- so if this turn goes on to hold the claim,
		-- it reclaimed it, and that is a lifecycle event the operator's log had
		-- no row for. Two stats and one short read, and only when the directory
		-- is there at all: nothing is added to the path a free workspace takes.
		reclaimed_from = stale_claim_evidence(M.claim_dir(workspace)),
		-- roots[1] IS the primary, and the four fields above are its aliases, so
		-- every caller written before declared write roots reads exactly what it
		-- read before and nothing about a single-root turn changes.
		roots = roots,
		refused_bytes = 0,
		refused_retained = {},
	}
	local lifecycle = require("yana.turn_lifecycle")
	session.turn_pass = lifecycle.begin_turn({
		panel_id = opts.panel_id or 0,
		generation = opts.generation or opts.turn_gen or 0,
		stream = stream,
		turn_id = turn_id,
		workspace = workspace,
		claim_dir = session.claim_dir,
	})
	return session, nil
end

--- Every root of a turn, whatever shape the session is in.
---
--- Sessions built by `begin_turn` carry `roots`; sessions built by hand -- the
--- headless rows and recovery paths that predate declared write roots do
--- exactly that -- carry only the aliases. Both answer here, so no caller has
--- to know which it holds.
function M.session_roots(session)
	return ops.session_roots(session)
end

--- Read each root's acquisition token out of the claim the launcher committed.
--- The reading itself lives in `shadow/jail.lua`, beside the rest of the claim
--- lifecycle; this is the name the turn-lifecycle callers already reach for.
function M.capture_root_nonces(session)
	jail.capture_root_nonces(session)
	if session and session.turn_pass and not session.claim_open_logged then
		for _, root in ipairs(M.session_roots(session)) do
			if type(root.nonce) == "string" and root.nonce ~= "" then
				session.claim_open_logged = true
				require("yana.log").lifecycle_later("claim.open", {
					turn_id = session.turn_pass.turn_id,
					panel = session.turn_pass.panel,
					generation = session.turn_pass.generation,
					stream = session.turn_pass.stream,
				})
				break
			end
		end
	end
	return session
end

local function refusal_message(change, tail)
	return (change.rel or change.path or "?")
		.. ": binary_content — real file unchanged; "
		.. tail
end

local function momentary(change, message, reason)
	change.durable_retention = false
	change.retention_strength = "momentary"
	change.retained_path = nil
	change.retention_error = reason
	change.review_error = refusal_message(change, message)
	return false, reason
end

--- Preserve one individually refused agent file before the overlay settles.
--- The fixed limits are product policy, not configuration. A repeated callback
--- is idempotent only against the digest recorded in this live session.
function M.retain_system_refused(session, change)
	if type(session) ~= "table" or type(change) ~= "table" then
		return false, "durable retention has no active turn"
	end
	if change.status ~= "system_refused" then
		return false, "change is not system_refused"
	end
	if change.after == nil then
		change.durable_retention = false
		change.retention_strength = "none"
		change.retained_path = nil
		change.retention_error = nil
		change.review_error = refusal_message(change, "binary delete refused; no agent version exists to retain")
		return true, "delete"
	end
	if type(change.after) ~= "string" then
		return momentary(
			change,
			"durable retention failed and the agent's version was discarded at settlement",
			"agent version is not bytes"
		)
	end
	local rel = change.rel
	local valid, validation_error = manifest.validate_rel(rel)
	if not valid then
		return momentary(
			change,
			"durable retention failed and the agent's version was discarded at settlement",
			validation_error
		)
	end

	local bytes = change.after
	-- vim.fn.sha256() over Neovim's Lua bridge: a Lua string with an embedded
	-- NUL is always converted to a VimL Blob (confirmed empirically on
	-- 0.10.4, 0.11.2, 0.12.4 alike — `type()` reports 10/Blob in all three).
	-- What differs is whether sha256() itself ACCEPTS a Blob argument: its
	-- own bundled builtin.txt/vimfn.txt doc only gained "{expr} is a String
	-- or a Blob" on 0.12.4 — the 0.10.4 and 0.11.2 docs say String only, and
	-- both raise `E976: Using a Blob as a String` for exactly this call
	-- (refused binary content is never NUL-free). hash.hash_bytes() is the
	-- existing N7 content-hash authority built for exactly this: NUL-free
	-- input still goes through vim.fn.sha256 (a plain VimL String on every
	-- version), NUL-containing input falls back to `sha256sum` via
	-- vim.system() — a formulation both versions accept, so no version
	-- branch is needed here.
	local digest = hash.hash_bytes(bytes)
	session.refused_retained = session.refused_retained or {}
	local previous = session.refused_retained[rel]
	if previous and previous.digest == digest and previous.bytes == #bytes then
		change.durable_retention = true
		change.retention_strength = "durable"
		change.retained_path = previous.path
		change.retention_error = nil
		change.review_error = refusal_message(change, "both versions kept; agent version: " .. previous.path)
		return true, "durable"
	end

	local previous_bytes = previous and previous.bytes or 0
	local turn_bytes = (session.refused_bytes or 0) - previous_bytes
	if #bytes > REFUSED_MAX_FILE_BYTES or turn_bytes + #bytes > REFUSED_MAX_TURN_BYTES then
		return momentary(
			change,
			"agent's version exceeded the retention cap and was discarded at settlement",
			"retention_cap"
		)
	end

	local retained_path = session.turn_dir .. "/refused/" .. rel
	local wrote, write_error = diff.write_file(retained_path, bytes)
	if not wrote then
		return momentary(
			change,
			"durable retention failed and the agent's version was discarded at settlement",
			tostring(write_error)
		)
	end
	session.refused_bytes = turn_bytes + #bytes
	session.refused_retained[rel] = {
		bytes = #bytes,
		digest = digest,
		path = retained_path,
	}
	change.durable_retention = true
	change.retention_strength = "durable"
	change.retained_path = retained_path
	change.retention_error = nil
	change.review_error = refusal_message(change, "both versions kept; agent version: " .. retained_path)
	prune_refused_turns(vim.fn.fnamemodify(session.turn_dir, ":h"))
	return true, "durable"
end

--- Persist only refusal metadata for an aggregate group. Artifact bytes stay
--- in the overlay and remain momentary; the complete per-op listing survives.
function M.retain_refusal_group(session, group)
	if type(session) ~= "table" or type(group) ~= "table" or type(group.root) ~= "string" then
		return nil, "invalid refusal group"
	end
	local rows = {}
	for _, op in ipairs(group.members or {}) do
		rows[#rows + 1] = vim.json.encode({
			turn = session.turn_id,
			status = "system_refused",
			aggregate_root = group.root,
			kind = op.kind,
			rel = op.rel,
			detail = op.detail,
			reason = "artifact/build output excluded from review",
			retention_strength = "momentary",
		})
	end
	local name = vim.fn.sha256(group.root):sub(1, 16) .. ".jsonl"
	local path = session.turn_dir .. "/refused/_groups/" .. name
	local ok, err = diff.write_file(path, table.concat(rows, "\n") .. (#rows > 0 and "\n" or ""))
	if not ok then
		return nil, err
	end
	group.listing_path = path
	-- The group's bytes in THIS turn's one upper layer. `group.root` is
	-- relative to the repository the group belongs to, and with a broad root
	-- the upper is keyed by that broad root, so the repository's own prefix
	-- (recorded by the walk) sits between them. Empty for every turn whose
	-- upper is keyed by the workspace, which is byte-for-byte the old path.
	local prefix = type(group.upper_prefix) == "string" and group.upper_prefix or ""
	local layer_base = group.upper_dir or session.upper_dir
	group.layer_path = layer_base .. "/" .. (prefix ~= "" and (prefix .. "/") or "") .. group.root
	prune_refused_turns(vim.fn.fnamemodify(session.turn_dir, ":h"))
	return path
end

--- Move an unsafe proposal out of the reusable layer namespace before claim
--- release. The rename stays inside state_root, so it is atomic.
--- Move ONE root's layer out of the reusable namespace. The rename stays
--- inside state_root, so it is atomic.
local function recover_one_layer(session, root)
	if not root or not root.layer_dir then
		return nil, "turn has no layer to recover"
	end
	local base = table.concat({
		M.state_root(),
		"recovered",
		workspace_slug(root.workspace),
		session.stream,
	}, "/")
	vim.fn.mkdir(base, "p")
	local unique = string.format("%s-%d-%s", session.turn_id, uv.os_getpid(), tostring(uv.hrtime()))
	local target = base .. "/" .. unique
	local ok, err = uv.fs_rename(root.layer_dir, target)
	if not ok then
		session.preserve_layer = true
		local kept = root.layer_dir
		root.recovered_path = kept
		return kept, "atomic recovery move failed: " .. tostring(err)
	end
	root.layer_dir = nil
	root.upper_dir = nil
	root.recovered_path = target
	prune_recovered(base)
	return target
end

--- Move an unsafe proposal out of the reusable layer namespace before claim
--- release, for EVERY root the turn wrote. The primary's target is returned so
--- the single-root callers that predate declared write roots are unchanged;
--- `session.recovered_paths` carries one entry per root that had a layer.
function M.recover_layer(session)
	if type(session) ~= "table" then
		return nil, "turn has no layer to recover"
	end
	local roots = M.session_roots(session)
	if #roots == 0 or not roots[1].layer_dir then
		return nil, "turn has no layer to recover"
	end
	local primary_target, primary_err
	local recovered = {}
	for i, root in ipairs(roots) do
		if root.layer_dir then
			local target, err = recover_one_layer(session, root)
			recovered[#recovered + 1] = { workspace = root.workspace, path = target, error = err }
			if i == 1 then
				primary_target, primary_err = target, err
			end
		end
	end
	session.recovered_paths = recovered
	-- The aliases follow roots[1], which is what they are aliases of.
	session.layer_dir = roots[1].layer_dir
	session.upper_dir = roots[1].upper_dir
	session.recovered_path = roots[1].recovered_path or primary_target
	return primary_target, primary_err
end

--- Record that this turn's review is open, once the overlay has actually taken
--- the claim. The marker is polled in rather than written up front, so it lands
--- while the agent is still running and therefore before it exits.
---
--- THE POLL'S CONDITION IS "the claim directory exists", AND THAT IS NOT THE
--- SAME QUESTION AS "this turn holds it". This comment used to argue that it
--- was -- "the overlay creates the claim directory itself (an atomic mkdir that
--- refuses a directory already there), so the editor cannot pre-create it" --
--- which is true of a FREE workspace and false of the one case that matters:
--- after an editor dies with a review open, the dead turn's claim directory is
--- still there, so the first fire of this timer stamps THIS editor's live
--- identity onto a claim it does not yet hold, moments before the launcher
--- classifies it. Measured on 2026-08-20 (issue 29): the marker read at the
--- refusal named the challenger's own nvim, and every retry re-stamped it, so
--- the workspace was locked out until a human force-release.
---
--- The launcher is where that is now answered, because the launcher is the only
--- party holding the claim lock: `bin/yana-overlay:take_claim` treats a marker
--- naming its own editor's process as its own stray stamp rather than as a live
--- reviewer, clears it with a recorded reason, and still requires the previous
--- TURN to classify dead before it reclaims anything. Nothing here decides it.
---
--- The poll ALSO stopped guessing. When the caller knows this turn's launcher
--- pid (`session.launcher_pid`, the pid `jobstart` handed back), the marker is
--- written only once `<claim>/holder` names that launcher -- the claim is this
--- turn's, not merely a directory that exists. That has a second effect worth
--- stating: on the reclaim path the old poll marked the STALE claim, the
--- launcher then cleared that marker as part of reclaiming, and the turn that
--- resulted ran with NO review-open marker at all, so the next crash would have
--- looked like an abandoned claim. Waiting for ownership means the marker that
--- lands is the one that survives the turn.
---
--- A caller that cannot name its launcher, and a launcher pid that never turns
--- up within the poll's own window, both fall back to the old condition: this
--- can be better than it was, never worse.
function M.arm_review_open(session, on_marked)
	if not session or not session.claim_dir then
		return
	end
	local claim_dir = session.claim_dir
	local uv = vim.uv or vim.loop
	local timer = uv.new_timer()
	if not timer then
		jail.mark_review_open(claim_dir)
		return
	end
	local waited = 0
	local interval = 20
	local limit = 5000
	local launcher_pid = tonumber(session.launcher_pid)

	--- True when the claim in front of us is the one THIS turn's launcher took.
	--- The holder file is the launcher's commit point (`write_holder` writes it
	--- last, after the liveness record), so a claim naming our launcher is a
	--- claim whose acquisition has completed.
	local function claim_is_ours()
		if not launcher_pid then
			return true
		end
		local f = io.open(claim_dir .. "/holder", "r")
		if not f then
			return false
		end
		local pid = tonumber(((f:read("l") or ""):match("^(%d+)")))
		f:close()
		return pid == launcher_pid
	end

	-- The poll used to be a bare `vim.schedule_wrap`ped function handed straight
	-- to `timer:start`, which queues a FRESH callback on every 20 ms fire
	-- whether or not the previous one has drained. Any main-loop stall queues
	-- several: the first marks the claim and closes the handle, and the next one
	-- reaches an unguarded `timer:close()` on a handle that is already closing.
	-- That is the "handle 0x… is already closing" error users see, on the claims
	-- path of every turn.
	--
	-- Two invariants now make a second entry into the close impossible, and
	-- neither is a caught error:
	--
	--   * `in_flight` is set on the libuv thread at the moment of the fire and
	--     cleared only when that poll actually runs, so at most ONE poll is ever
	--     queued. The re-entrancy is removed, not tolerated.
	--   * `finish` flips `finished` BEFORE the stop/close it guards, and every
	--     exit branch goes through it, so stop/close runs exactly once.
	--
	-- Both flags are read and written only from nvim's main loop, which is also
	-- the libuv loop thread, so no interleaving can observe them half-updated.
	local finished = false
	local in_flight = false

	local function finish()
		if finished then
			return
		end
		finished = true
		timer:stop()
		timer:close()
	end

	local function poll()
		in_flight = false
		if finished then
			return
		end
		if session.review_open_marked or session.released then
			finish()
			return
		end
		-- Past the window, take the claim as it comes: the fallback is exactly
		-- the condition this poll used before, so a launcher pid that never
		-- appears costs nothing that was not already being paid.
		local own = claim_is_ours() or waited >= limit
		if own and jail.mark_review_open(claim_dir) then
			-- The claim exists and is this turn's, which is exactly the moment
			-- every root's acquisition token is readable: the launcher takes the
			-- whole declared set before the agent starts.
			pcall(M.capture_root_nonces, session)
			-- EVERY root's review marker, not just the workspace's. The marker is
			-- what tells the next editor that a review is open on a claim whose
			-- turn process has legitimately exited; without one on a declared
			-- root, that root's claim would look abandoned while its hunks are
			-- still on screen.
			for _, root in ipairs(M.session_roots(session)) do
				if root.claim_dir and root.claim_dir ~= claim_dir then
					pcall(jail.mark_review_open, root.claim_dir)
				end
			end
			session.review_open_marked = true
			-- The claim is this turn's now. If a previous turn's claim was still
			-- on disk when this one began, the launcher took it away from a dead
			-- holder -- report that, once, with the reason the launcher used.
			-- Reported rather than decided: by the time this runs the reclaim has
			-- already happened, under the launcher's lock, on the launcher's own
			-- evidence.
			local stale = session.reclaimed_from
			session.reclaimed_from = nil
			if stale then
				pcall(function()
					require("yana.log").lifecycle("claim.reclaim", {
						reason = stale.review_open and "dead-holder-review-open" or "dead-holder",
						pid = stale.pid,
						turn = session.turn_id,
					})
				end)
			end
			finish()
			if on_marked then
				on_marked()
			end
			return
		end
		waited = waited + interval
		-- Strictly greater, so the fire at exactly `limit` still gets to take
		-- the fallback branch above instead of being stopped one tick early.
		if waited > limit then
			finish()
		end
	end

	-- Deliberately NOT `vim.schedule_wrap`: the decision to queue has to be made
	-- on the loop thread at the instant of the fire, which is the only place
	-- that can refuse to queue a second poll. This callback touches no Vim API —
	-- `jail.mark_review_open` uses `vim.fn`, so it stays inside `poll`.
	timer:start(0, interval, function()
		if finished or in_flight then
			return
		end
		in_flight = true
		vim.schedule(poll)
	end)
end

--- Close the review this turn's claim was held for. Called from every path
--- that finishes or abandons a review — never from agent process exit alone,
--- which the module forbids while a review is still open.
--- Close the review this turn's claims were held for -- EVERY root's, not just
--- the workspace's. A root whose release fails does not stop the others: the
--- claims-and-concurrency contract's guarantee is that a claim always releases,
--- and holding root 3 back because root 2 refused would wedge a workspace over
--- a failure that has nothing to do with it. The first failure is what the
--- caller is told about.
function M.release(session)
	if not session or session.released then
		return true
	end
	session.released = true
	-- The finalize-time FILE claims go back with the turn claim, and BEFORE it:
	-- a turn whose per-file records outlived its claim would name a holder that
	-- no longer exists (PLAN-R1-capture.md §5). Never decisive -- a store that
	-- cannot be reached must not wedge the claim this function exists to give
	-- back.
	pcall(function()
		require("yana.shadow.apply").release_file_claims(session)
	end)
	if session.turn_pass and not session.claim_open_logged and jail.claim_held(session.claim_dir) then
		session.claim_open_logged = true
		require("yana.log").lifecycle_later("claim.open", {
			turn_id = session.turn_pass.turn_id,
			panel = session.turn_pass.panel,
			generation = session.turn_pass.generation,
			stream = session.turn_pass.stream,
		})
	end
	local ok_all, first_err = true, nil
	for _, root in ipairs(M.session_roots(session)) do
		if root.claim_dir and root.claim_dir ~= "" then
			local ok, err = jail.release_claim(root.claim_dir)
			if not ok then
				ok_all = false
				first_err = first_err or err
			end
		end
	end
	if session.turn_pass then
		local log = require("yana.log")
		local lifecycle = require("yana.turn_lifecycle")
		if session.claim_open_logged then
			log.lifecycle_later("claim.release", {
				turn_id = session.turn_pass.turn_id,
				panel = session.turn_pass.panel,
				generation = session.turn_pass.generation,
				reason = "preview.release",
			})
		end
		lifecycle.close_turn(session.turn_pass, "preview.release")
		session.turn_pass = nil
	end
	return ok_all, first_err
end

--- Explicit, logged override for a claim left behind by a crashed editor.
function M.force_release(claim_dir, reason)
	return jail.force_release_claim(claim_dir, reason)
end

--- Claim directory for a workspace with no turn in flight — the recovery path
--- after a restart, where there is no session object to read it from.
--- Returns claim directory, resolved workspace.
function M.claim_dir_for(workspace)
	workspace = diff.abs_path(workspace or M.workspace_for_turn({}))
	return M.claim_dir(workspace), workspace
end

--- What a restart finds: whether the claim is still held, who holds it, and
--- whether a review was open when the editor went away. A held claim with a
--- review-open record is recoverable, not dead — it is never auto-released.
function M.claim_status(workspace)
	local claim_dir, resolved = M.claim_dir_for(workspace)
	return {
		claim_dir = claim_dir,
		workspace = resolved,
		held = jail.claim_held(claim_dir),
		review_open = jail.review_open(claim_dir),
		holder = jail.claim_holder(claim_dir),
	}
end

function M.end_turn(session)
	if not session then
		return nil, "no preview session"
	end
	local report_ops, err = ops.typed_ops_from_session(session)
	if not report_ops then
		return nil, err
	end
	return {
		ops = report_ops,
		lines = ops.format_lines(report_ops),
	}, nil
end

--- Drop everything this turn created. There is no snapshot tree to remove:
--- the only per-turn state is the overlay layer and the private scratch, both
--- of which are O(what the agent wrote).
function M.discard(session)
	if not session then
		return true
	end
	local keep_private = false
	local ok_record, record = pcall(require, "yana.record")
	if ok_record and record.enabled() then
		keep_private = true
	end
	if session.private_dir and not keep_private then
		pcall(vim.fn.delete, session.private_dir, "rf")
	end
	if not session.preserve_layer then
		-- Every root's layer, not just the workspace's: a turn that wrote into a
		-- declared root and was discarded must leave nothing of that root's
		-- proposal behind either.
		for _, root in ipairs(M.session_roots(session)) do
			if root.layer_dir then
				pcall(vim.fn.delete, root.layer_dir, "rf")
			end
		end
	end
	local keep_refused = session.turn_dir
		and vim.fn.isdirectory(session.turn_dir .. "/refused") == 1
	if session.turn_dir and not keep_private and not keep_refused then
		pcall(vim.fn.delete, session.turn_dir, "rf")
	end
	return true
end

function M.render_report(panel, session)
	local report, err = M.end_turn(session)
	if not report then
		return false, err
	end
	if panel and panel.conv_buf and vim.api.nvim_buf_is_valid(panel.conv_buf) then
		local buf = panel.conv_buf
		local lines = report.lines
		local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local was_modifiable = vim.bo[buf].modifiable
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, #cur, #cur, false, lines)
		vim.bo[buf].modifiable = was_modifiable
	end
	return true, report
end

return M
