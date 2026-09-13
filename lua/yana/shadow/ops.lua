-- Typed change set, read directly from the overlay upper layer.
--
-- CORE, "No whole-repository work": a turn's cost depends on the number of
-- files the agent touched, never on the size of the repository. There is no
-- snapshot copy and no manifest pass. The producer is `bin/yana-changeset`,
-- which walks the UPPER layer only; the before-content of a touched path is
-- read from the lower layer, which is the real tree.
--
-- This module is the Lua consumer of that producer. It decodes the tool's
-- NUL-delimited records and builds the review payload, whose schema is
-- unchanged from the manifest-diff route it replaces: review and apply were not
-- touched by the migration.
local M = {}

local diff = require("yana.diff")
local control_plane = require("yana.safety.control_plane")
local log = require("yana.log")
local hash = require("yana.safety.hash")

M._test = {
	fault = {},
	inject = {},
}

-- One durable WARN owner per (workspace, stream, turn, panel|recorder).
local control_plane_warn_recorded = {}

--- Canonical scope for durable control-plane WARN. UI finalize passes
--- `panel_id`; headless paths pass an explicit `recorder` label. Missing both
--- is an error — never coerce to "" and build a different key silently.
function M.control_plane_warn_scope(session, opts)
	opts = opts or {}
	assert(type(session) == "table", "control_plane_warn_scope: session required")
	local workspace = session.workspace
	local stream = session.stream
	local turn_id = session.turn_id
	assert(type(workspace) == "string" and workspace ~= "", "control_plane_warn_scope: session.workspace required")
	assert(type(stream) == "string" and stream ~= "", "control_plane_warn_scope: session.stream required")
	assert(turn_id ~= nil, "control_plane_warn_scope: session.turn_id required")
	local scope = {
		workspace = workspace,
		stream = stream,
		turn_id = turn_id,
	}
	if opts.panel_id ~= nil then
		local panel_id = tostring(opts.panel_id)
		assert(panel_id ~= "", "control_plane_warn_scope: panel_id must be non-empty")
		scope.panel_id = panel_id
	elseif opts.recorder ~= nil then
		assert(type(opts.recorder) == "string" and opts.recorder ~= "", "control_plane_warn_scope: recorder must be non-empty")
		scope.recorder = opts.recorder
	else
		error("control_plane_warn_scope: panel_id or recorder required")
	end
	return scope
end

local function control_plane_warn_key(scope)
	scope = scope or {}
	local owner = scope.panel_id or scope.recorder
	assert(owner ~= nil and owner ~= "", "control_plane_warn_key: scope missing panel_id and recorder")
	return table.concat({
		tostring(scope.workspace),
		tostring(scope.stream),
		tostring(scope.turn_id),
		tostring(owner),
	}, "\0")
end

--- Durable Wall-3 record: control-plane ops are counted and WARN-persisted.
--- Scope must come from `control_plane_warn_scope`. Returns cp_count.
function M.record_control_plane_refusals(scope, typed)
	local key = control_plane_warn_key(scope)
	if control_plane_warn_recorded[key] ~= nil then
		return control_plane_warn_recorded[key]
	end
	local cp_count = 0
	for _, op in ipairs(typed or {}) do
		if op.control_plane then
			cp_count = cp_count + 1
		end
	end
	if cp_count > 0 then
		local persisted = log.write(
			"WARN",
			string.format(
				"yana: turn %s wrote %d control-plane path(s) (.git/.hg/.svn) -- recorded and discarded with the overlay, never applied",
				tostring(scope.turn_id),
				cp_count
			)
		)
		if not persisted then
			error(
				"control-plane WARN could not be persisted durably: "
					.. tostring(log.durable_unhealthy_reason() or "log.write failed")
			)
		end
	end
	control_plane_warn_recorded[key] = cp_count
	return cp_count
end

-- Test-only: clear the per-scope control-plane WARN dedup cache.
function M._test.reset_control_plane_warn_recorded()
	control_plane_warn_recorded = {}
end


local ops_decode = require("yana.shadow.ops_decode")
M.decode = ops_decode.decode
M.read_records = ops_decode.read_records
M.typed_ops = ops_decode.typed_ops
M.session_roots = ops_decode.session_roots
M.typed_ops_from_session = ops_decode.typed_ops_from_session
M._test.repo_root_for = ops_decode._test.repo_root_for

local count_rel_ops = ops_decode.count_rel_ops
local reviewable = ops_decode.reviewable
local rel_op_key = ops_decode.rel_op_key
local walks_for_session = ops_decode.walks_for_session

local ops_artifacts = require("yana.shadow.ops_artifacts")
ops_artifacts.count_rel_ops = count_rel_ops
ops_artifacts.reviewable = reviewable
ops_artifacts.rel_op_key = rel_op_key

M.classify_artifacts = ops_artifacts.classify_artifacts

--- Build ONE root's inline review change objects.
---
--- `before` comes from the LOWER layer — that root's real tree — and `after`
--- from that root's upper layer. Neither is copied anywhere: both are read on
--- demand, at O(touched). `base_hash` is the PRODUCER's fingerprint of the
--- before-bytes, cross-checked against the read above; the applier re-reads the
--- real file and compares against it immediately before the write, which is
--- where a human change landing later still is detected.
---
--- Returns nil, err when the evidence cannot be established (never an empty
--- list masking one).
local function changes_for_root(session, root, upper, typed)
	local changes = {}
	local root_index = root.index or 1
	-- `classify_artifacts` already withholds a paired op from the review for the correct,
	-- named reason (`PAIRED_REFUSAL_REASON`); this path must never reach
	-- `evidence_from_op` in the first place and manufacture a SECOND, unrelated-sounding
	-- refusal that takes the rest of the turn down with it.
	local rel_counts = count_rel_ops(typed)
	for _, op in ipairs(typed) do
		-- `create dir`, `create symlink` and a whiteout over a directory are
		-- typed operations with no whole-file content, so they cannot become
		-- review changes. They stay in `typed` and are reported by format_lines.
		if reviewable(op) and (rel_counts[rel_op_key(op)] or 0) <= 1 then
			-- The absolute path the operation is ABOUT. Once the walk is
			-- regrouped by touched repository, `root.workspace .. "/" .. op.rel`
			-- is the same string -- but `op.path` is the one the producer built
			-- and the one the journal is keyed by, so it is read directly.
			local lower = op.path
			local ev, state, err
			if M._test.fault.reobserve_base_evidence then
				-- Mutation seam (gate): the pre-fix route, where the workspace was
				-- observed AGAIN here, after classification, and that later look
				-- became the recorded before-state.
				state, err = ops_artifacts.lower_state(lower)
				if not state then
					return nil, err
				end
				ev = {
					kind = state.kind,
					hash = state.kind == "file" and state.hash or hash.hash_bytes(""),
					mode = state.mode,
				}
			else
				ev, err = ops_artifacts.evidence_from_op(op)
				if not ev then
					return nil, err
				end
				state, err = ops_artifacts.cross_check(lower, ev)
				if not state then
					return nil, err
				end
			end
			local before = state.bytes
			-- Bytes come out of the ONE upper layer, keyed by the path that
			-- layer is keyed by (`upper_rel`), not by the repository-relative
			-- `rel` the review shows.
			local after = op.kind ~= "delete" and ops_artifacts.read_tree_bytes(upper, op.upper_rel or op.rel) or nil
			local after_mode = ops_artifacts.after_mode_for(upper, op)
			local change = {
				-- Root 1's ids are exactly the ids this function has always
				-- minted. A second root may hold the same relative path, so its
				-- ids carry the root index: an id that collided across roots
				-- would make two different files one review.
				id = root_index == 1
						and ("shadow-" .. tostring(session.turn_id) .. "-" .. op.rel)
					or ("shadow-" .. tostring(session.turn_id) .. "-r" .. tostring(root_index) .. "-" .. op.rel),
				path = op.path,
				rel = op.rel,
				-- The root this change belongs to. `rel` is relative to THIS
				-- root, never to the workspace; `path` (root .. "/" .. rel) is
				-- the only thing the journal and the applier are keyed by, so a
				-- bare `rel` can never reach a writer.
				root = root.workspace,
				root_index = root_index,
				root_is_primary = root_index == 1,
				turn_id = session.turn_id,
				turn_gen = session.turn_gen,
				kind = ops_artifacts.review_kind(op, ev),
				before = op.kind == "delete" and (before or "") or before,
				after = after,
				-- The PRODUCER's tag, fingerprint and mode, carried unchanged.
				-- `base_hash` is the empty hash for an absent path so every
				-- existing consumer keeps working; the tag is what makes absence
				-- distinguishable from an empty file at accept time.
				base_state = ev.kind,
				base_hash = ev.hash,
				base_mode = ev.mode,
					base_hash_captured_ts = op.base_hash_captured_ts,
					after_mode = after_mode,
					-- R-b recovery reads proposal bytes only from this daemon-kept
					-- turn layer; it never recomputes evidence from current disk.
					upper_path = op.kind ~= "delete" and (upper .. "/" .. (op.upper_rel or op.rel)) or nil,
					shadow_apply = true,
				status = "pending",
			}
			-- Named refusal at ingestion: NUL bytes never become a review. The
			-- real file stays unchanged and both byte strings stay on the change
			-- record long enough to explain the refusal.
			if ops_artifacts.contains_nul(change.before) or ops_artifacts.contains_nul(change.after) then
				change.reason_class = "binary_content"
				change.review_error = op.rel
					.. ": binary_content — real file unchanged; proposal is not reviewable"
			end
			changes[#changes + 1] = change
		end
	end
	return changes
end

--- Build inline review change objects for one turn, across every root it wrote.
---
--- ONE WALK AND ONE CLASSIFICATION PER ROOT. Two declared roots may hold the
--- same relative path, and `classify_artifacts` keys its exclusions by `rel`, so
--- a single pass over the merged list would let one root's `dist/` exclusion
--- silence the other root's file of the same name. Per root, the behaviour is
--- byte-for-byte what a single-root turn has always done; the results are then
--- concatenated in claim order.
---
--- Returns nil, err when the producer fails (never an empty list masking one).
function M.changes_from_session(session, context)
	local walks, werr = walks_for_session(session)
	if not walks then
		return nil, werr
	end

	-- The window this route exists to close, driven at exactly its instant: the
	-- producer has classified the tree, and the human saves before the review is
	-- built. Test-only; production never sets it.
	if M._test.inject.human_save_after_classify then
		for p, bytes in pairs(M._test.inject.human_save_after_classify) do
			diff.write_file(p, bytes)
		end
	end

	local all_typed = {}
	local merged = { changes = {}, groups = {}, individual = {}, unsafe = {}, ignored = {} }
	-- THE OPERATOR'S IGNORE LIST, applied here and nowhere else.
	--
	-- Here, because this is the one place that holds both a workspace-relative
	-- `rel` and the upper-layer path its bytes live at, which is exactly what a
	-- write-through needs. `classify_artifacts` is pure and stays pure: it reads
	-- `op.ignored` and never asks what the operator configured.
	--
	-- NOT in single-file mode. That mode's whole contract is "only this one
	-- tracked file may change", enforced by `apply_single_file_filter` further
	-- down; letting a pattern write a second path through underneath it would
	-- break the narrower promise to honour the wider one. An ignored path in an
	-- SFM turn therefore keeps SFM's own refusal, which names the file.
	local ignore = require("yana.ignore")
	local ignore_active = not (session and session.single_file)
	for _, walk in ipairs(walks) do
		local root, upper, typed = walk.root, walk.upper, walk.typed
		if ignore_active then
			for _, op in ipairs(typed) do
				if ignore.ignorable(op) and ignore.matches(op.rel, op.detail == "dir") then
					op.ignored = true
					merged.ignored[#merged.ignored + 1] = {
						rel = op.rel,
						kind = op.kind,
						detail = op.detail,
						root = root.workspace,
						real_path = op.path,
						upper_path = upper .. "/" .. (op.upper_rel or op.rel),
					}
				end
			end
		end
		local changes, cerr = changes_for_root(session, root, upper, typed)
		if not changes then
			return nil, cerr
		end
		local classification = M.classify_artifacts(
			typed,
			changes,
			nil,
			context and context.tracked_evidence or nil
		)
		-- A refusal group's bytes live in the layer of the root that produced
		-- it, so the group carries that root with it: `retain_refusal_group`
		-- reads the listing from here and would otherwise look for root 2's
		-- `dist/` under the workspace's upper layer. `group.root` is the
		-- artifact root's RELATIVE path and keeps that meaning.
		for _, group in ipairs(classification.groups) do
			group.root_workspace = root.workspace
			group.upper_dir = upper
			-- Where this group's bytes actually sit in the ONE upper layer:
			-- `group.root` is relative to the REPOSITORY, and the upper is keyed
			-- by the broad root, so the repository's own prefix travels with it.
			group.upper_prefix = root.upper_prefix or ""
		end
		for _, op in ipairs(classification.unsafe) do
			op.root = root.workspace
		end
		for _, op in ipairs(classification.individual) do
			op.root = root.workspace
		end
		vim.list_extend(all_typed, typed)
		vim.list_extend(merged.changes, classification.changes)
		vim.list_extend(merged.groups, classification.groups)
		vim.list_extend(merged.individual, classification.individual)
		vim.list_extend(merged.unsafe, classification.unsafe)
	end
	return merged.changes, nil, all_typed, merged
end

-- Return typed ops with no review route: non-file kinds, or paired halves.
function M.unreviewable_ops(typed)
	-- `typed` here is `changes_from_session`'s third return: every root's
	-- ops, flattened. `count_rel_ops`/`rel_op_key` key by (root, rel), so a
	-- pairing found in one root's walk cannot reach into another root that
	-- happens to hold the same relative path.
	local paired = count_rel_ops(typed)
	local out = {}
	for _, op in ipairs(typed or {}) do
		if not op.control_plane and (not reviewable(op) or (paired[rel_op_key(op)] or 0) > 1) then
			out[#out + 1] = op
		end
	end
	return out
end

-- Build {rel, class, hash} entries from typed ops for bundle recording.
function M.classified_bundle_entries(typed)
	local entries = {}
	for _, op in ipairs(typed or {}) do
		entries[#entries + 1] = {
			rel = op.rel,
			class = op.control_plane and "control-plane" or (op.kind or "unknown"),
			hash = type(op.extra) == "string" and op.extra or nil,
		}
	end
	return entries
end

--- The mode half of a compound operation, spelled out for the operator.
---
--- A `chmod+modify` is ONE decision (`the filesystem operations contract`), and
--- accepting the bytes accepts the mode with them. That is the contract and it is not
--- in question — what was wrong is that the report said only `- **modify** \`tool.sh\`
--- _file_`, so the operator approved a mode change nothing had told them about. The
--- product cannot tell a deliberate `chmod` from a umask artifact left by an agent that
--- replaced the file instead of rewriting it; nothing on the wire separates them.
local function mode_disclosure(op)
	local ev = op.base_evidence
	if type(ev) ~= "table" then
		return ""
	end
	local before, after = ev.mode, ev["new-mode"]
	if type(before) ~= "string" or type(after) ~= "string" or before == after then
		return ""
	end
	return string.format(" — mode %s → %s", before, after)
end

-- Render ops as markdown preview lines, one bullet per operation.
function M.format_lines(ops)
	local lines = {}
	if not ops or #ops == 0 then
		lines[#lines + 1] = "_Preview: no typed operations (the agent wrote nothing)._"
		return lines
	end
	lines[#lines + 1] = "_Preview report — read-only; accept is not wired in preview mode._"
	for _, op in ipairs(ops) do
		local detail = op.detail and (" _" .. op.detail .. "_") or ""
		lines[#lines + 1] = string.format("- **%s** `%s`%s%s", op.kind, op.path, detail, mode_disclosure(op))
	end
	return lines
end

return M
