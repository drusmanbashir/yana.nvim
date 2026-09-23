-- Do not extend. Refusal-retention, layer recovery, and claim release, split out of
-- shadow/preview.lua. Reached from the facade under the original names.
local M = {}

local diff = require("yana.diff")
local hash = require("yana.safety.hash")
local jail = require("yana.shadow.jail")
local manifest = require("yana.paths.manifest")
local uv = vim.uv or vim.loop

function M.new(deps)
	local I = {}

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

--- Preserve one individually refused agent file before the overlay settles. The fixed
--- limits are product policy, not configuration. A repeated callback is idempotent only
--- against the digest recorded in this live session.
---
--- Named by a digest of the absolute path so two files with the same basename
--- in different folders cannot collide, and so no component of the operator's
--- own path is re-interpreted as a directory here.
---
--- RETENTION: `M.discard` deletes `private_dir` when the turn finishes, so a
--- staged copy dies with the turn's evidence. That is deliberate and is what
--- makes this redo-scoped recovery rather than an archive; the caller says so
--- to the operator.
function I.stage_undo_removal(session, abs_path, content)
	if type(session) ~= "table" or type(session.private_dir) ~= "string" or session.private_dir == "" then
		return nil, "this turn has no private evidence directory to stage a removal into"
	end
	if type(abs_path) ~= "string" or abs_path == "" or type(content) ~= "string" then
		return nil, "a staged removal needs an absolute path and its bytes"
	end
	local base = abs_path:gsub(".*/", ""):gsub("[^%w%.%-_]", "_")
	local staged = session.private_dir .. "/undo-staged/" .. hash.hash_bytes(abs_path):sub(1, 16) .. "-" .. base
	vim.fn.mkdir(vim.fn.fnamemodify(staged, ":h"), "p")
	local ok, err = diff.write_file(staged, content)
	if not ok then
		return nil, err
	end
	return staged
end

-- Durably save a refused change's bytes to disk; mutates change status.
function I.retain_system_refused(session, change)
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
	-- vim.fn.sha256() over Neovim's Lua bridge: a Lua string with an embedded NUL is
	-- always converted to a VimL Blob (confirmed empirically on 0.10.4, 0.11.2, 0.12.4
	-- alike — `type()` reports 10/Blob in all three). hash.hash_bytes() is the existing N7
	-- content-hash authority built for exactly this: NUL-free input still goes through
	-- vim.fn.sha256 (a plain VimL String on every version), NUL-containing input falls
	-- back to `sha256sum` via vim.system() — a formulation both versions accept, so no
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
	if #bytes > deps.limits.file_bytes or turn_bytes + #bytes > deps.limits.turn_bytes then
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
	deps.workspace.prune_refused_turns(vim.fn.fnamemodify(session.turn_dir, ":h"))
	return true, "durable"
end

--- Persist only refusal metadata for an aggregate group. Artifact bytes stay
--- in the overlay and remain momentary; the complete per-op listing survives.
function I.retain_refusal_group(session, group)
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
	deps.workspace.prune_refused_turns(vim.fn.fnamemodify(session.turn_dir, ":h"))
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
		deps.state_root(),
		"recovered",
		deps.workspace.path_key(root.workspace),
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
	deps.workspace.prune_recovered(base)
	return target
end

--- Move an unsafe proposal out of the reusable layer namespace before claim
--- release, for EVERY root the turn wrote. The primary's target is returned so
--- the single-root callers that predate declared write roots are unchanged;
--- `session.recovered_paths` carries one entry per root that had a layer.
function I.recover_layer(session)
	if type(session) ~= "table" then
		return nil, "turn has no layer to recover"
	end
	local roots = deps.turn.session_roots(session)
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

--- Publish the complete review only after process exit, turn settlement, and
--- classification. The saved bundle is the evidence R-b recovery reuses.
--- `on_marked` fires after the daemon accepts (or immediately on ask/no-session).
function I.arm_review_open(session, on_marked)
	if not session or not session.yanad_session_id then
		if on_marked then
			on_marked(false)
		end
		return
	end
	if session.mode == "ask" then
		-- Ask turns take no claim; tell the daemon there is no review.
		require("yana.runtime.yanad").review_none({
			session_id = session.yanad_session_id,
			turn_id = tostring(session.turn_id),
		}, tostring(session.turn_id) .. ":review.none", function()
			if on_marked then
				on_marked(true)
			end
		end)
		return
	end
	local files = session.review_files or {}
	if type(files) ~= "table" or #files == 0 then
		-- Walk found nothing: review.none releases the claim.
		require("yana.runtime.yanad").review_none({
			session_id = session.yanad_session_id,
			turn_id = tostring(session.turn_id),
		}, tostring(session.turn_id) .. ":review.none", function(ok)
			session.review_open_marked = ok and true or false
			if on_marked then
				on_marked(ok)
			end
		end)
		return
	end
	local abs = {}
	local ws = session.workspace or ""
	for _, rel in ipairs(files) do
		if type(rel) == "string" and rel:sub(1, 1) == "/" then
			abs[#abs + 1] = rel
		else
			abs[#abs + 1] = ws .. "/" .. tostring(rel)
		end
	end
	session.review_open_requested = true
	require("yana.runtime.yanad").review_open({
		session_id = session.yanad_session_id,
		turn_id = tostring(session.turn_id),
		files = abs,
		tabs = session.review_tabs or {},
		bundle = session.review_bundle or {},
	}, tostring(session.turn_id) .. ":review.open", function(ok)
		session.review_open_marked = ok and true or false
		if on_marked then
			on_marked(ok)
		end
	end)
end

function I.release(session, on_released)
	if not session then
		if on_released then on_released(true) end
		return true
	end
	if session.released then
		if on_released then on_released(true) end
		return true
	end
	local active_attempt = session._release_attempt
	if active_attempt and not active_attempt.settled then
		if on_released then
			active_attempt.waiters[#active_attempt.waiters + 1] = on_released
		end
		return true
	end
	session._release_attempt_seq = (session._release_attempt_seq or 0) + 1
	local command = session.review_open_requested and "review.close" or "review.none"
	local identity = session.yanad_session_id or session.turn_id or "local"
	local attempt = {
		id = string.format(
			"%s:%s:%s:%d",
			tostring(identity),
			command,
			tostring(uv.hrtime()),
			session._release_attempt_seq
		),
		waiters = on_released and { on_released } or {},
		settled = false,
	}
	session._release_attempt = attempt
	session._release_pending = attempt

	local function complete(ok, detail)
		-- A daemon reconnect may replay an answer and a hostile/test transport
		-- may call twice. Only this attempt's first answer can release its owner;
		-- a late answer can never consume a retry's waiters.
		if attempt.settled or session._release_attempt ~= attempt then return end
		attempt.settled = true
		session._release_attempt = nil
		session._release_pending = nil
		if not ok then
			session.release_error = detail or "review_close_refused"
			for _, waiter in ipairs(attempt.waiters) do
				pcall(waiter, false, session.release_error)
			end
			return
		end

		session.release_error = nil
		session.released = true
		if session.turn_pass then
			local log = require("yana.log")
			local lifecycle = require("yana.turn.turn_lifecycle")
			if session.claim_open_logged then
				log.lifecycle_later("claim.release", {
					turn_id = session.turn_pass.turn_id,
					panel = session.turn_pass.panel,
					generation = session.turn_pass.generation,
					reason = "preview.release",
				})
			end
			lifecycle.finish_turn(session.turn_pass)
			session.turn_pass = nil
		end
		for _, waiter in ipairs(attempt.waiters) do
			pcall(waiter, true)
		end
	end

	if not session.yanad_session_id then
		complete(true)
		return true
	end
	local sender = session.review_open_requested
		and require("yana.runtime.yanad").review_close
		or require("yana.runtime.yanad").review_none
	local args
	if session.review_open_requested then
		args = {
			session_id = session.yanad_session_id,
		}
	else
		args = {
			session_id = session.yanad_session_id,
			turn_id = tostring(session.turn_id),
		}
	end
	local sent, send_err = pcall(sender, args, attempt.id, complete)
	if not sent then
		if attempt.settled then
			return session.released == true, session.release_error
		end
		complete(false, tostring(send_err))
		return false, tostring(send_err)
	end
	return true
end

	return I
end

return M
