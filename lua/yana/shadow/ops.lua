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

local EXPECTED_PRODUCER = "yana-changeset-v1"

local diff = require("yana.diff")
local hash = require("yana.safety.hash")
local control_plane = require("yana.safety.control_plane")
local log = require("yana.log")
local uv = vim.uv or vim.loop

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

function M._test.reset_control_plane_warn_recorded()
	control_plane_warn_recorded = {}
end

local function changeset_bin()
	local src = debug.getinfo(1, "S").source:sub(2)
	local repo = src:gsub("/lua/yana/shadow/ops%.lua$", "")
	return repo .. "/bin/yana-changeset"
end

--- Decode the producer's stdout.
---
--- Wire format (bin/yana-changeset `encode_record`): the fields of one
--- record joined by a single NUL, then TWO NULs. Splitting the stream on NUL
--- therefore yields the fields followed by one empty piece per record, and an
--- empty piece is the record terminator. Fields are raw bytes: a path may hold
--- anything but NUL, which is why this is not a line protocol.
function M.decode(data)
	local records = {}
	local fields = {}
	local pos = 1
	local n = #data
	while pos <= n + 1 do
		local nul = data:find("\0", pos, true)
		if not nul then
			break
		end
		local chunk = data:sub(pos, nul - 1)
		pos = nul + 1
		if chunk == "" then
			if #fields > 0 then
				records[#records + 1] = fields
				fields = {}
			end
		else
			fields[#fields + 1] = chunk
		end
	end
	if #fields > 0 then
		records[#records + 1] = fields
	end
	return records
end

--- Run the producer over one turn's upper layer.
--- Returns a list of records, each `{ kind, rel, extra... }`.
function M.read_records(workspace, upper)
	local bin = changeset_bin()
	if vim.fn.filereadable(bin) ~= 1 then
		return nil, "yana-changeset not found at " .. bin
	end
	if vim.fn.isdirectory(upper) ~= 1 then
		-- No upper layer means no confined turn ran. That is not "no changes":
		-- refuse rather than report a clean turn on missing evidence.
		return nil, "no overlay upper layer at " .. tostring(upper)
	end
	local meta_out = vim.fn.fnamemodify(upper, ":h") .. "/changeset.meta"
	local result = vim.system({
		bin,
		"--workspace",
		workspace,
		"--upper",
		upper,
		"--meta-out",
		meta_out,
	}, { text = false }):wait()
	if result.code ~= 0 then
		local err = (result.stderr or "")
		if type(err) ~= "string" then
			err = ""
		end
		err = err:gsub("%s+$", "")
		return nil, err ~= "" and err or ("yana-changeset failed (exit " .. tostring(result.code) .. ")")
	end
	local declared
	if vim.fn.filereadable(meta_out) == 1 then
		for _, line in ipairs(vim.fn.readfile(meta_out)) do
			declared = declared or line:match("^#%s*(%S+)")
		end
	end
	if declared ~= EXPECTED_PRODUCER then
		return nil, "refusing a change set from an unknown producer: " .. tostring(declared)
	end
	return M.decode(result.stdout or "")
end

--- Which typed operations the review payload can carry today.
---
--- The payload schema is whole-file content: `modify` (create or rewrite) and
--- `delete`. Mode bits, symlink targets, directory creation and overlay opaque
--- markers are real typed operations that the producer reports and the review
--- surface has no representation for. They are NOT dropped silently — the
--- manifest route could not even see them — they are carried into the report
--- and named, so the gap is visible rather than invented away.
local CONTENT_KINDS = {
	create = true,
	modify = true,
	delete = true,
}

--- ...and of those, only the ones whose object is a REGULAR FILE.
---
--- The producer tags every record with the kind of the object the operation
--- acts on: the upper entry for a create or a modify, the lower object for a
--- delete. A `create dir`, a `create symlink` and a whiteout over a directory
--- are content-kind records with no whole-file content, so they belong in the
--- report beside mode changes, not in the review. `create symlink` used to slip
--- through this filter, be reviewed as a file, and take the symlink's TARGET
--- bytes as its "after".
local function reviewable(op)
	return CONTENT_KINDS[op.kind] and op.detail == "file"
end

--- Turn decoded records into typed operations with absolute paths.
function M.typed_ops(workspace, upper)
	local records, err = M.read_records(workspace, upper)
	if not records then
		return nil, err
	end
	local ops = {}
	-- Proven once: a bare-repository workspace exposes control-plane files at its
	-- root with no `.git` segment. Independent of the producer.
	local ws_bare = control_plane.workspace_is_bare(workspace)
	for _, rec in ipairs(records) do
		local kind, rel = rec[1], rec[2]
		if kind and rel and (control_plane.is_control_plane(rel) or (ws_bare and control_plane.is_bare_entry(rel))) then
			-- Control-plane refusal at the consumer, INDEPENDENT of the producer
			-- (defense in depth). Even a forged or older producer
			-- that emitted `create file .git/objects/…` cannot make it reviewable:
			-- the kind is forced to the non-content `control-plane`, so
			-- `reviewable()` is false and `changes_from_session` never offers it.
			-- The path is still carried in `typed` (with its original kind kept)
			-- so the turn report can count it — recorded, never offered.
			ops[#ops + 1] = {
				kind = "control-plane",
				original_kind = kind,
				rel = rel,
				path = workspace .. "/" .. rel,
				detail = rec[3],
				extra = rec[4],
				control_plane = true,
			}
		elseif kind and rel then
			-- Trailing `key=value` fields are the producer's before-EVIDENCE for a
			-- whole-file content operation, taken by the same observation that
			-- classified it. They are carried verbatim; nothing downstream may
			-- re-derive them from a later look at the real tree.
			local evidence = nil
			for i = 5, #rec do
				-- Word keys, plus ONE hyphenated key by name. The producer's
				-- compound-operation field is spelled `new-mode`, and `[%w_]+`
				-- could never match it, so the after-mode of a `chmod+modify`
				-- was parsed away here and BOTH readers of `ev["new-mode"]`
				-- were dead code. Admitting hyphens generally would have let
				-- `-` and `a--b` through as silently-ignored keys, so the one
				-- field that needs one is named instead.
				local key, value = rec[i]:match("^([%w_]+)=(.*)$")
				if not key then
					key, value = rec[i]:match("^(new%-mode)=(.*)$")
				end
				if key then
					evidence = evidence or {}
					evidence[key] = value
				end
			end
			ops[#ops + 1] = {
				kind = kind,
				rel = rel,
				path = workspace .. "/" .. rel,
				detail = rec[3],
				extra = rec[4],
				base_evidence = evidence,
			}
		end
	end
	table.sort(ops, function(a, b)
		if a.rel == b.rel then
			return a.kind < b.kind
		end
		return a.rel < b.rel
	end)
	return ops
end

local function upper_dir(session)
	if session.upper_dir then
		return session.upper_dir
	end
	if session.layer_dir then
		return session.layer_dir .. "/upper"
	end
	return nil
end

local function read_tree_bytes(root, rel)
	local path = root .. "/" .. rel
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	return diff.read_file_bytes(path)
end

local function contains_nul(bytes)
	return type(bytes) == "string" and bytes:find("\0", 1, true) ~= nil
end

--- The lower layer's TAGGED before-state for one touched path.
---
--- The before-state is "absent" or "a regular file with these bytes", and those
--- are the only two the applier can act on. Mapping anything else onto the empty
--- fingerprint — which is what `read_tree_bytes` returning nil used to mean —
--- made a present-but-unreadable file indistinguishable from nothing-there, so
--- an accepted deletion of it passed its check with an empty displaced copy and
--- destroyed every byte. It also made an absent create target indistinguishable
--- from a human-created empty file.
---
--- Anything present that is not a regular file refuses here rather than at
--- accept: the applier's `resolve_target` rejects a symlink component including
--- the final one, so a review built over such a path could only ever end in a
--- refusal, and the honest place to say so is before the hunks are drawn.
local function lower_state(path)
	local st = uv.fs_lstat(path)
	if not st then
		return { kind = "absent" }
	end
	if st.type ~= "file" then
		return nil,
			path
				.. ": the real path is a "
				.. tostring(st.type)
				.. ", not a regular file — refusing to review a whole-file change over it"
	end
	local content = diff.read_file_bytes(path)
	if content == nil then
		return nil,
			path
				.. ": the real file exists but could not be read, so the change has no before-state"
				.. " to be reviewed or checked against — refusing"
	end
	return { kind = "file", bytes = content, hash = hash.hash_bytes(content), mode = st.mode }
end

local function mode_perm(mode)
	return mode and (mode % 4096) or nil
end

local function mode_octal(mode)
	if not mode then
		return "?"
	end
	return string.format("%o", mode_perm(mode))
end

local function review_kind(op, ev)
	if op.kind == "delete" then
		return "delete"
	end
	if ev.kind == "absent" then
		return "create"
	end
	return "modify"
end

--- The mode an inline accept installs, or nil to leave the target's alone.
---
--- This used to stat the overlay upper for ANY operation and hand the result to
--- `shadow/apply.lua`, which passes it to the diary as `target_mode`. That is
--- the same defect as the CLI applier's: a content-only edit carries no mode
--- decision, so an accept that installs a mode read off the agent's copy is a
--- chmod nobody proposed or reviewed. Copy-up usually makes that mode equal to
--- the target's, which hides it — but "usually equal" is not the contract, and
--- an agent that replaces a file rather than rewriting it (unlink-and-create,
--- what `sed -i` and `mv` do) leaves an upper object created under the agent's
--- umask, whose mode is then installed over the real file.
---
--- So: a mode is returned only when the producer DECLARED one.
---   * `new-mode` is the producer's compound-operation field, appended to the
---     record when the mode changed as well as the bytes. It is the only thing
---     that makes a `chmod+modify` one whole decision, and dropping it would be
---     the half-acceptance `the filesystem operations contract` forbids. A
---     value that will not parse, or one outside the permission range, is not a
---     declaration and does not become one.
---   * A CREATE has no target whose mode could survive, so the upper object
---     remains the only provenance there. `state=absent` is the producer's tag
---     for exactly that case.
---   * Everything else returns nil, and the journaled applier reads the real
---     target immediately before the write (`safety/diary.lua`).
local function after_mode_for(session, op)
	local ev = op.base_evidence
	if type(ev) == "table" and ev["new-mode"] then
		local parsed = tonumber(ev["new-mode"], 8)
		if parsed and parsed == math.floor(parsed) and parsed >= 0 and parsed <= 4095 then
			return parsed
		end
		return nil
	end
	if op.kind == "delete" then
		return nil
	end
	if type(ev) ~= "table" or ev.state ~= "absent" then
		return nil
	end
	local upper = upper_dir(session)
	if not upper then
		return nil
	end
	local path = upper .. "/" .. op.rel
	local st = uv.fs_lstat(path)
	if st and st.type == "file" then
		return mode_perm(st.mode)
	end
	return nil
end

--- The producer's before-EVIDENCE for one operation, read out of the record.
---
--- Nothing here observes the real tree. State, mode and fingerprint were taken
--- by the read that CLASSIFIED the operation, they travel on the record, and
--- this route's job is to carry them to the applier unchanged. Observing the
--- workspace again to build them — which is what this function replaced — puts
--- a window between classification and evidence, and a file created in that
--- window becomes the recorded before-state of a change prepared against its
--- absence. Absence and an empty file share the empty fingerprint, so the
--- accept-time recheck then matches and the human's new file is overwritten.
---
--- Missing or malformed fields refuse by name. A record with no tag, or a file
--- tag with no mode, cannot be compared at accept time, and the honest place to
--- say so is before the hunks are drawn.
local function evidence_from_op(op)
	local fp = op.extra
	if type(fp) ~= "string" or #fp ~= 64 or not fp:match("^%x+$") then
		return nil,
			op.path .. ": the change set carries no before-fingerprint for this " .. tostring(op.kind) .. " — refusing"
	end
	local ev = op.base_evidence
	if type(ev) ~= "table" or ev.state == nil then
		return nil,
			op.path
				.. ": the change set carries no recorded before-state for this "
				.. tostring(op.kind)
				.. ", so whether the real file is the one it was prepared against cannot be judged — refusing."
				.. " Re-run the turn to produce evidence for it"
	end
	if ev.state == "absent" then
		return { kind = "absent", hash = fp }
	end
	if ev.state == "file" then
		local mode = tonumber(ev.mode or "", 8)
		if not mode then
			return nil,
				op.path
					.. ": the change set records a file before-state with no mode for it, so a mode-only human change"
					.. " cannot be seen — refusing"
		end
		return { kind = "file", hash = fp, mode = mode }
	end
	return nil,
		op.path
			.. ": the real path is a "
			.. tostring(ev.state == "link" and "symlink" or (ev.kind or ev.state))
			.. ", not a regular file — refusing to review a whole-file change over it"
end

--- Cross-check the record against the tree as it is NOW — and only that.
---
--- The review needs the before-BYTES to draw hunks, so the lower layer is read
--- here whatever happens. That later read may agree with the record or refuse
--- it; it may never become the record. A mismatch is exactly the case this
--- route exists to catch — the human saved between the producer's classifying
--- read and the review — and it is a named refusal, not a re-basing.
local function cross_check(path, ev)
	local state, serr = lower_state(path)
	if not state then
		return nil, serr
	end
	if state.kind ~= ev.kind then
		if ev.kind == "absent" then
			return nil,
				path
					.. ": this file did not exist when the change set was produced and something has created it since"
					.. " — refusing to review a change that would overwrite it"
		end
		return nil,
			path
				.. ": this file existed when the change set was produced and has been removed since"
				.. " — refusing; re-run the turn to decide against the current tree"
	end
	if ev.kind == "absent" then
		return state
	end
	if mode_perm(state.mode) ~= mode_perm(ev.mode) then
		return nil,
			path
				.. ": this file's mode differs from the copy the change set was produced against"
				.. " — refusing; both versions are kept"
	end
	if state.hash ~= ev.hash then
		return nil,
			path
				.. ": this file differs from the copy the change set was produced against — your edit landed"
				.. " between the agent's turn and this review; both versions are kept, re-run the turn to"
				.. " diff against your current file"
	end
	return state
end

--- Large dependency trees are counted per path in `typed` but offered as one
--- review decision under the directory prefix (shortlist 8b).
local AGGREGATE_DIR_PREFIXES = {
	["node_modules"] = true,
}

local function aggregate_directory_changes(workspace, changes)
	local buckets = {}
	local rest = {}
	for _, change in ipairs(changes) do
		local rel = change.rel or ""
		local dir = rel:match("^([^/]+)/")
		if dir and AGGREGATE_DIR_PREFIXES[dir] then
			local bucket = buckets[dir]
			if not bucket then
				bucket = { members = {} }
				buckets[dir] = bucket
			end
			bucket.members[#bucket.members + 1] = change
		else
			rest[#rest + 1] = change
		end
	end
	for dir, bucket in pairs(buckets) do
		if #bucket.members > 0 then
			local summary = string.format(
				"%d file(s) under %s/ (aggregated for one review decision)",
				#bucket.members,
				dir
			)
			rest[#rest + 1] = {
				id = "shadow-agg-" .. dir,
				rel = dir,
				path = workspace .. "/" .. dir,
				kind = "aggregate",
				before = summary,
				after = summary,
				aggregated_dir = dir,
				aggregated_count = #bucket.members,
				aggregated_members = bucket.members,
				shadow_apply = true,
				status = "pending",
			}
		end
	end
	table.sort(rest, function(a, b)
		return (a.rel or "") < (b.rel or "")
	end)
	return rest
end

--- Build inline review change objects for one turn.
---
--- `before` comes from the LOWER layer — the real tree — and `after` from the
--- upper layer. Neither is copied anywhere: both are read on demand, at
--- O(touched). `base_hash` is the PRODUCER's fingerprint of the before-bytes,
--- cross-checked against the read above; the applier re-reads the real file and
--- compares against it immediately before the write, which is where a human
--- change landing later still is detected.
---
--- Returns nil, err when the producer fails (never an empty list masking one).
function M.changes_from_session(session)
	local upper = upper_dir(session)
	if not upper then
		return nil, "turn has no overlay upper layer"
	end
	local typed, err = M.typed_ops(session.workspace, upper)
	if not typed then
		return nil, err or "reading the change set failed"
	end

	-- The window this route exists to close, driven at exactly its instant: the
	-- producer has classified the tree, and the human saves before the review is
	-- built. Test-only; production never sets it.
	if M._test.inject.human_save_after_classify then
		for p, bytes in pairs(M._test.inject.human_save_after_classify) do
			diff.write_file(p, bytes)
		end
	end

	local changes = {}
	for _, op in ipairs(typed) do
		-- `create dir`, `create symlink` and a whiteout over a directory are
		-- typed operations with no whole-file content, so they cannot become
		-- review changes. They stay in `typed` and are reported by format_lines.
		if reviewable(op) then
			local lower = session.workspace .. "/" .. op.rel
			local ev, state, err
			if M._test.fault.reobserve_base_evidence then
				-- Mutation seam (gate): the pre-fix route, where the workspace was
				-- observed AGAIN here, after classification, and that later look
				-- became the recorded before-state.
				state, err = lower_state(lower)
				if not state then
					return nil, err
				end
				ev = {
					kind = state.kind,
					hash = state.kind == "file" and state.hash or hash.hash_bytes(""),
					mode = state.mode,
				}
			else
				ev, err = evidence_from_op(op)
				if not ev then
					return nil, err
				end
				state, err = cross_check(lower, ev)
				if not state then
					return nil, err
				end
			end
			local before = state.bytes
			local after = op.kind ~= "delete" and read_tree_bytes(upper, op.rel) or nil
			local after_mode = after_mode_for(session, op)
			local change = {
				id = "shadow-" .. tostring(session.turn_id) .. "-" .. op.rel,
				path = op.path,
				rel = op.rel,
				kind = review_kind(op, ev),
				before = op.kind == "delete" and (before or "") or before,
				after = after,
				-- The PRODUCER's tag, fingerprint and mode, carried unchanged.
				-- `base_hash` is the empty hash for an absent path so every
				-- existing consumer keeps working; the tag is what makes absence
				-- distinguishable from an empty file at accept time.
				base_state = ev.kind,
				base_hash = ev.hash,
				base_mode = ev.mode,
				after_mode = after_mode,
				shadow_apply = true,
				status = "pending",
			}
			-- Named refusal at ingestion: NUL bytes never become a review.
			-- Both versions stay on the change (and in the upper layer); the
			-- change is still listed so a same-turn text file can still review.
			if contains_nul(change.before) or contains_nul(change.after) then
				change.reason_class = "binary_content"
				change.review_error = op.rel .. ": binary_content — both versions kept"
			end
			changes[#changes + 1] = change
		end
	end
	changes = aggregate_directory_changes(session.workspace, changes)
	return changes, nil, typed
end

function M.unreviewable_ops(typed)
	local out = {}
	for _, op in ipairs(typed or {}) do
		if not op.control_plane and not reviewable(op) then
			out[#out + 1] = op
		end
	end
	return out
end

function M.classified_bundle_entries(typed)
	local entries = {}
	local agg_dirs = {}
	for _, op in ipairs(typed or {}) do
		entries[#entries + 1] = {
			rel = op.rel,
			class = op.control_plane and "control-plane" or (op.kind or "unknown"),
			hash = type(op.extra) == "string" and op.extra or nil,
		}
		local dir = (op.rel or ""):match("^([^/]+)/")
		if dir and AGGREGATE_DIR_PREFIXES[dir] then
			agg_dirs[dir] = true
		end
	end
	for dir in pairs(agg_dirs) do
		entries[#entries + 1] = { rel = dir, class = "aggregate" }
	end
	return entries
end

--- The mode half of a compound operation, spelled out for the operator.
---
--- A `chmod+modify` is ONE decision (`the filesystem operations contract`),
--- and accepting the bytes accepts the mode with them. That is the contract and
--- it is not in question — what was wrong is that the report said only
--- `- **modify** \`tool.sh\` _file_`, so the operator approved a mode change
--- nothing had told them about. The product cannot tell a deliberate `chmod`
--- from a umask artifact left by an agent that replaced the file instead of
--- rewriting it; nothing on the wire separates them. So it stops guessing and
--- shows what it observed, and the operator — who knows what they asked for —
--- decides. Disclosure replacing inference: the same move CORE already makes
--- where side-effect provenance ships EMPTY rather than invented.
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
