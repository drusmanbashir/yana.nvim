-- Preview mode turn lifecycle: jailed agent → typed op report → discard.
--
-- There is no snapshot step. CORE, "No whole-repository work": the overlay
-- lower layer IS the before-picture, so copying the workspace at turn start
-- re-derived information the kernel already held. Starting a turn now costs
-- three mkdirs regardless of how large the repository is.
local M = {}

local config = require("yana.config")
local diff = require("yana.diff")
local jail = require("yana.shadow.jail")
local manifest = require("yana.manifest")
local ops = require("yana.shadow.ops")
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

--- Narrow the turn workspace to the file tree under edit, not all of cwd.
function M.workspace_for_turn(opts)
	opts = opts or {}
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

--- Workspace slug, byte-identical to the one `bin/yana-turn` computes
--- (sha256 of the filesystem identity, first 16 hex chars) so a claim taken by the
--- editor and a claim taken by the CLI collide as they should.
local claim_identity = require("yana.claim_identity")

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

	return {
		workspace = workspace,
		stream = stream,
		turn_id = turn_id,
		turn_gen = opts.turn_gen,
		turn_dir = turn_dir,
		private_dir = private_dir,
		layer_dir = layer_dir,
		upper_dir = layer_dir .. "/upper",
		claim_dir = M.claim_dir(workspace),
		refused_bytes = 0,
		refused_retained = {},
	}, nil
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
	local digest = vim.fn.sha256(bytes)
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
	group.layer_path = session.upper_dir .. "/" .. group.root
	prune_refused_turns(vim.fn.fnamemodify(session.turn_dir, ":h"))
	return path
end

--- Move an unsafe proposal out of the reusable layer namespace before claim
--- release. The rename stays inside state_root, so it is atomic.
function M.recover_layer(session)
	if type(session) ~= "table" or not session.layer_dir then
		return nil, "turn has no layer to recover"
	end
	local base = table.concat({
		M.state_root(),
		"recovered",
		workspace_slug(session.workspace),
		session.stream,
	}, "/")
	vim.fn.mkdir(base, "p")
	local unique = string.format("%s-%d-%s", session.turn_id, uv.os_getpid(), tostring(uv.hrtime()))
	local target = base .. "/" .. unique
	local ok, err = uv.fs_rename(session.layer_dir, target)
	if not ok then
		session.preserve_layer = true
		session.recovered_path = session.layer_dir
		return session.layer_dir, "atomic recovery move failed: " .. tostring(err)
	end
	session.layer_dir = nil
	session.upper_dir = nil
	session.recovered_path = target
	prune_recovered(base)
	return target
end

--- Record that this turn's review is open, once the overlay has actually taken
--- the claim. The overlay creates the claim directory itself (an atomic mkdir
--- that refuses a directory already there), so the editor cannot pre-create it;
--- the marker is polled in instead, landing while the agent is still running
--- and therefore before it exits.
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
		if jail.mark_review_open(claim_dir) then
			session.review_open_marked = true
			finish()
			if on_marked then
				on_marked()
			end
			return
		end
		waited = waited + interval
		if waited >= limit then
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
function M.release(session)
	if not session or session.released then
		return true
	end
	session.released = true
	if not session.claim_dir or session.claim_dir == "" then
		return true
	end
	return jail.release_claim(session.claim_dir)
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
	local report_ops, err = ops.typed_ops(session.workspace, session.upper_dir or (session.layer_dir .. "/upper"))
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
	if session.layer_dir and not session.preserve_layer then
		pcall(vim.fn.delete, session.layer_dir, "rf")
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
