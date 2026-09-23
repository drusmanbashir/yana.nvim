-- Artifact classification (build-output/aggregate detection, review-kind and
-- mode-change evidence for one op), split out of shadow/ops.lua. Reached from
-- the facade under the original names. Self-contained: no facade closures to
-- thread, so this is a plain module, not an `M.new(deps)` factory.
local M = {}
local I = M

local diff = require("yana.diff")
local config = require("yana.config")
local hash = require("yana.safety.hash")
local manifest = require("yana.paths.manifest")
local PAIRED_REFUSAL_REASON = require("yana.shadow.ops_decode").PAIRED_REFUSAL_REASON
local uv = vim.uv or vim.loop

function I.read_tree_bytes(root, rel)
	local path = root .. "/" .. rel
	if vim.fn.filereadable(path) ~= 1 then
		return nil
	end
	return diff.read_file_bytes(path)
end

function I.contains_nul(bytes)
	return type(bytes) == "string" and bytes:find("\0", 1, true) ~= nil
end

--- The lower layer's TAGGED before-state for one touched path.
---
--- The before-state is "absent" or "a regular file with these bytes", and those are the
--- only two the applier can act on. It also made an absent create target
--- indistinguishable from a human-created empty file.
---
--- Anything present that is not a regular file refuses here rather than at
--- accept: the applier's `resolve_target` rejects a symlink component including
--- the final one, so a review built over such a path could only ever end in a
--- refusal, and the honest place to say so is before the hunks are drawn.
function I.lower_state(path)
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

function I.review_kind(op, ev)
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
--- That is the same defect as the CLI applier's: a content-only edit carries no mode
--- decision, so an accept that installs a mode read off the agent's copy is a chmod
--- nobody proposed or reviewed.
---
--- So: a mode is returned only when the producer DECLARED one. * `new-mode` is the
--- producer's compound-operation field, appended to the record when the mode changed as
--- well as the bytes. It is the only thing that makes a `chmod+modify` one whole
--- decision, and dropping it would be the half-acceptance `the filesystem operations
--- contract` forbids.
function I.after_mode_for(upper, op)
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
	if not upper then
		return nil
	end
	-- `op.rel` is relative to the operation's own REPOSITORY once the walk has
	-- been regrouped; `op.upper_rel` is the one the upper layer is keyed by.
	local path = upper .. "/" .. (op.upper_rel or op.rel)
	local st = uv.fs_lstat(path)
	if st and st.type == "file" then
		return mode_perm(st.mode)
	end
	return nil
end

--- The producer's before-EVIDENCE for one operation, read out of the record.
---
--- Nothing here observes the real tree. State, mode and fingerprint were taken by the
--- read that CLASSIFIED the operation, they travel on the record, and this route's job
--- is to carry them to the applier unchanged. Observing the workspace again to build
--- them — which is what this function replaced — puts a window between classification
--- and evidence, and a file created in that window becomes the recorded before-state of
--- a change prepared against its absence.
---
--- Missing or malformed fields refuse by name. A record with no tag, or a file
--- tag with no mode, cannot be compared at accept time, and the honest place to
--- say so is before the hunks are drawn.
function I.evidence_from_op(op)
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
function I.cross_check(path, ev)
	local state, serr = I.lower_state(path)
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

local PRODUCT_ARTIFACT_COMPONENTS = {
	["node_modules"] = true,
	["target"] = true,
	["__pycache__"] = true,
	["build"] = true,
	["dist"] = true,
	[".venv"] = true,
	["CMakeFiles"] = true,
	[".cache"] = true,
	[".gradle"] = true,
	["zig-out"] = true,
}

local function artifact_component_kind(component)
	if PRODUCT_ARTIFACT_COMPONENTS[component] or component:match("%.egg%-info$") then
		return "product"
	end
	for _, configured in ipairs(config.options.artifact_dir_prefixes or {}) do
		local lua_pattern = { "^" }
		for i = 1, #configured do
			local char = configured:sub(i, i)
			if char == "*" then
				lua_pattern[#lua_pattern + 1] = ".*"
			elseif char == "?" then
				lua_pattern[#lua_pattern + 1] = "."
			elseif char:match("[%^%$%(%)%%%.%[%]%+%-]") then
				lua_pattern[#lua_pattern + 1] = "%" .. char
			else
				lua_pattern[#lua_pattern + 1] = char
			end
		end
		lua_pattern[#lua_pattern + 1] = "$"
		if component:match(table.concat(lua_pattern)) then
			return "operator"
		end
	end
	return nil
end

local function named_artifact_root(rel)
	local prefix = {}
	for component in rel:gmatch("[^/]+") do
		prefix[#prefix + 1] = component
		local kind = artifact_component_kind(component)
		if kind then
			return table.concat(prefix, "/"), kind
		end
	end
	return nil
end

local function tracked_at_or_below(tracked, rel)
	for path in pairs((tracked and tracked.paths) or {}) do
		if path == rel or path:sub(1, #rel + 1) == rel .. "/" then
			return true
		end
	end
	return false
end

local function inside_submodule(tracked, rel)
	for root in pairs((tracked and tracked.submodules) or {}) do
		if rel == root or rel:sub(1, #root + 1) == root .. "/" then
			return true
		end
	end
	return false
end

--- A NEW DIRECTORY IS NOT A DECISION OF ITS OWN.
---
--- `bin/yana-changeset` emits `["create", "dir"]` for every directory a turn brought
--- into existence. Nobody asked for that directory: it exists only because a file
--- inside it does. Accepting that file creates the directory; rejecting it leaves
--- nothing behind.
local function is_dir_create(op)
	return op.kind == "create" and op.detail == "dir"
end

--- Pure artifact/refusal classification. Filesystem and Git evidence are
--- captured by the caller before the agent runs; this function only combines
--- those facts with the producer's per-op base evidence.
---
--- The half of that ruling this function owns is the DIRECTORY half.
---
---   ⛔ create dicom_utils/.agent system-refused
---
--- and then queued `dicom_utils/.agent/INDEX.tsv` and `.../INDEX.lock` as
--- ordinary reviews anyway. The refusal was false in both directions: nothing
--- had been blocked, and accepting either child created the directory regardless.
---
--- The `virgin` / `structural_root` mechanism removed here could never have run in the
--- shipping product. It required `op.base_evidence.state == "absent"`, and
--- `compare_path` emits a `create dir` record with NO trailing evidence fields at all,
--- so `op.base_evidence` is nil for every directory create and the list was always
--- empty outside hand-built fixtures. `.agent` is in neither list and never was -- the
--- canonical artifact class is not what refused it.
function I.classify_artifacts(typed, changes, _base_evidence, tracked)
	tracked = tracked or { status = "unavailable", paths = {} }

	local groups_by_root, groups = {}, {}
	local unsafe, individual, excluded = {}, {}, {}
	-- Directory creates whose fate depends on what survives under them. Decided
	-- after the main loop, when the surviving set is known.
	local structural_dirs = {}
	local function add_group(root, root_kind, op)
		local group = groups_by_root[root]
		if not group then
			group = { root = root, root_kind = root_kind, count = 0, kind_counts = {}, members = {} }
			groups_by_root[root] = group
			groups[#groups + 1] = group
		end
		group.count = group.count + 1
		group.kind_counts[op.kind] = (group.kind_counts[op.kind] or 0) + 1
		group.members[#group.members + 1] = op
		op.status = "system_refused"
		op.retention_strength = "momentary"
		op.aggregate_root = root
		excluded[op.rel] = true
	end

	-- Scoped to THIS call's `typed` list, which is one root's walk (see
	-- `changes_from_session`): a pair's two halves always share a root, so
	-- this never reaches across a different root's claim to exclude an
	-- unrelated file that merely shares a relative path.
	local paired_rel = I.count_rel_ops(typed)

	for _, op in ipairs(typed or {}) do
		if op.ignored then
			-- ON THE OPERATOR'S IGNORE LIST (`lua/yana/paths/ignore.lua`, marked by
			-- `changes_from_session` which alone knows the workspace). Neither offered nor
			-- refused nor grouped: written through untouched at turn end and disclosed in one
			-- turn-summary line. It is still in `typed`, so the bundle and the durable record
			-- carry it like every other observed operation -- what the ignore list buys is
			-- silence on the review surface, never silence in the record.
			excluded[op.rel] = true
		elseif not op.control_plane then
			local canonical, canonical_error = manifest.validate_rel(op.rel)
			local named_root, named_kind = named_artifact_root(op.rel)
			local root = named_root
			local root_kind = named_kind
			local safety_root = (named_kind == "product" and named_root) or nil
			-- Inside an artifact root the existing bulk `add_group` below already decides both
			-- halves together (one group, one accept/refuse), so this only has work to do where
			-- that protection does not already reach.
			if not root and (paired_rel[I.rel_op_key(op)] or 0) > 1 then
				op.refusal_reason = PAIRED_REFUSAL_REASON
				op.status = "system_refused"
				op.retention_strength = "momentary"
				individual[#individual + 1] = op
				excluded[op.rel] = true
			elseif canonical and not root and is_dir_create(op) then
				-- STRUCTURAL, pending what survives under it. Deferred rather than
				-- decided here: "does an offered file live under this directory" is
				-- not answerable until every other operation in this walk has been
				-- classified.
				--
				-- STRICTLY AFTER the pairing check, and the order is load-bearing. A file→dir type
				-- change is produced as a `delete` of the old kind and a `create dir` sharing ONE
				-- rel, and both halves must be withheld with the SAME reason. Taking the dir half
				-- out of the pair here would refuse it as "inline review cannot represent this
				-- operation" while its sibling said `PAIRED_REFUSAL_REASON`: two reasons for one
				-- indivisible decision.
				--
				-- A non-canonical rel, or one inside a NAMED artifact root, never
				-- reaches here either: those keep the refusal/grouping they have
				-- always had.
				structural_dirs[#structural_dirs + 1] = op
			else
				-- A destructive op (delete or opaque) is safe only when canonical, git status
				-- is known (repo/no_repo) and it is not inside a submodule, AND one of:
				--   * it is a regular-file delete outside every artifact root (built-in or
				--     operator-configured): it falls through to per-file review below, and
				--     trackedness is not required because nothing is excluded silently;
				--   * it sits inside a built-in (product) root with nothing tracked at or
				--     below it: it is grouped, so trackedness must authorize that exclusion.
				-- Anything else is unsafe and refuses the whole turn.
				local is_destructive = op.kind == "opaque" or op.kind == "delete"
				local safe = canonical
				if is_destructive then
					local review_delete = op.kind == "delete" and op.detail == "file" and not root
					safe = safe
						and (tracked.status == "repo" or tracked.status == "no_repo")
						and not inside_submodule(tracked, op.rel)
						and (review_delete or (safety_root ~= nil and not tracked_at_or_below(tracked, op.rel)))
				end
				if not safe then
					op.refusal_reason = canonical and "unsafe destructive artifact operation" or canonical_error
					op.status = "system_refused"
					op.retention_strength = "recovered"
					unsafe[#unsafe + 1] = op
				elseif root then
					add_group(root, root_kind, op)
				elseif not I.reviewable(op) then
					op.refusal_reason = "inline review cannot represent this operation"
					op.status = "system_refused"
					op.retention_strength = "momentary"
					individual[#individual + 1] = op
					excluded[op.rel] = true
				end
			end
		end
	end
	table.sort(groups, function(a, b)
		return a.root < b.root
	end)
	local reviewable_changes = {}
	for _, change in ipairs(changes or {}) do
		if not excluded[change.rel] then
			reviewable_changes[#reviewable_changes + 1] = change
		end
	end

	-- WHAT SURVIVED, and therefore which new directories carry something. A path survives
	-- when it is still offered for review, OR when the ignore list will write it through
	-- -- both reach the real tree, so both need the directory to exist and neither wants a
	-- refusal note about it. Ancestor directories of a survivor are themselves survivors,
	-- so nested new directories (`pkg/.agent/idx/` under `pkg/.agent/`) all resolve on the
	-- one leaf.
	local survivors = {}
	for _, change in ipairs(reviewable_changes) do
		survivors[#survivors + 1] = change.rel
	end
	for _, op in ipairs(typed or {}) do
		if op.ignored then
			survivors[#survivors + 1] = op.rel
		end
	end
	local function carries_something(root)
		local prefix = root .. "/"
		for _, rel in ipairs(survivors) do
			if rel:sub(1, #prefix) == prefix then
				return true
			end
		end
		return false
	end
	for _, op in ipairs(structural_dirs) do
		if carries_something(op.rel) then
			op.structural = true
		else
			-- Nothing under it is offered, so accepting nothing would create it and
			-- the directory would be lost in silence. Disclose it exactly as
			-- before; the text is unchanged so an operator who has seen this note
			-- reads the same sentence it always meant.
			op.refusal_reason = "inline review cannot represent this operation"
			op.status = "system_refused"
			op.retention_strength = "momentary"
			individual[#individual + 1] = op
			excluded[op.rel] = true
		end
	end
	return {
		changes = reviewable_changes,
		groups = groups,
		individual = individual,
		unsafe = unsafe,
	}
end


return M
