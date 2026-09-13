-- Overlay upper-layer change decoding (yana-changeset consumer).
-- Split from shadow/ops.lua; facade re-exports under original names.
local M = {}

local EXPECTED_PRODUCER = "yana-changeset-v1"

local control_plane = require("yana.safety.control_plane")
local workspace_identity = require("yana.workspace_identity")

local function changeset_bin()
	local src = debug.getinfo(1, "S").source:sub(2)
	local repo = src:gsub("/lua/.*%.lua$", "")
	return repo .. "/bin/yana-changeset"
end

--- Decode the producer's stdout.
---
--- Wire format (bin/yana-changeset `encode_record`): the fields of one record joined by
--- a single NUL, then TWO NULs. Splitting the stream on NUL therefore yields the fields
--- followed by one empty piece per record, and an empty piece is the record terminator.
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
--- The producer tags every record with the kind of the object the operation acts on:
--- the upper entry for a create or a modify, the lower object for a delete. A `create
--- dir`, a `create symlink` and a whiteout over a directory are content-kind records
--- with no whole-file content, so they belong in the report beside mode changes, not in
--- the review.
local function reviewable(op)
	return CONTENT_KINDS[op.kind] and op.detail == "file"
end

--- How many non-control-plane typed operations landed on each path, within
--- ONE root's walk.
---
--- A count above 1 is therefore the producer's own signal that these operations are
--- only meaningful together, independent of what kind either one carries. Keyed by
--- (root, rel), never `rel` alone: `unreviewable_ops` is handed the FLATTENED,
--- all-roots `typed` list `changes_from_session` returns, and two different roots
--- holding a same-named path (the collision `changes_from_session`'s own docstring
--- names) must never pair across that boundary. `classify_artifacts` calls this once
local function count_rel_ops(typed)
	local counts = {}
	for _, op in ipairs(typed or {}) do
		if not op.control_plane then
			local key = tostring(op.root_index or op.root or "") .. "\0" .. op.rel
			counts[key] = (counts[key] or 0) + 1
		end
	end
	return counts
end

local function rel_op_key(op)
	return tostring(op.root_index or op.root or "") .. "\0" .. op.rel
end

--- Why a paired op is withheld — shared by `classify_artifacts` (which
--- withholds it from `changes`) and `unreviewable_ops` (which names it),
--- so the two never drift apart on which halves are paired.
local PAIRED_REFUSAL_REASON = "part of a paired filesystem change (file-type "
	.. "change) — the matching half has no applier route, so neither half is "
	.. "offered as an independent review decision"

--- Turn decoded records into typed operations with absolute paths.
function M.typed_ops(workspace, upper)
	local records, err = M.read_records(workspace, upper)
	if not records then
		return nil, err
	end
	-- WHEN the producer's classifying read ran. This is the field a stale-file refusal
	-- needs to tell a human edit from a stale capture, and today nothing upstream of this
	-- line records it at all.
	local base_hash_captured_ts = os.time()
	local ops = {}
	-- Proven once: a bare-repository workspace exposes control-plane files at its
	-- root with no `.git` segment. Independent of the producer.
	local ws_bare = control_plane.workspace_is_bare(workspace)
	for _, rec in ipairs(records) do
		local kind, rel = rec[1], rec[2]
		if kind and rel and (control_plane.is_control_plane(rel) or (ws_bare and control_plane.is_bare_entry(rel))) then
			-- Control-plane refusal at the consumer, INDEPENDENT of the producer (defense in
			-- depth). Even a forged or older producer that emitted `create file .git/objects/…`
			-- cannot make it reviewable: the kind is forced to the non-content `control-plane`,
			-- so `reviewable()` is false and `changes_from_session` never offers it. The path is
			-- still carried in `typed` (with its original kind kept) so the turn report can
			-- count it — recorded, never offered.
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
				-- Word keys, plus ONE hyphenated key by name. The producer's compound-operation
				-- field is spelled `new-mode`, and `[%w_]+` could never match it, so the after-mode
				-- of a `chmod+modify` was parsed away here and BOTH readers of `ev["new-mode"]`
				-- were dead code. Admitting hyphens generally would have let `-` and `a--b` through
				-- as silently-ignored keys, so the one field that needs one is named instead.
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
				base_hash_captured_ts = base_hash_captured_ts,
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

--- Every root this turn wrote, in claim order, whatever shape the session is in.
---
--- A session from `preview.begin_turn` carries `roots`; a session built by hand
--- -- the headless rows, the recovery paths and every caller that predates
--- operator-declared write roots do exactly that -- carries only the primary's
--- aliases. Both answer here, so a single-root turn reaches the identical code
--- path either way and no caller has to know which shape it holds.
function M.session_roots(session)
	if type(session) ~= "table" then
		return {}
	end
	if type(session.roots) == "table" and #session.roots > 0 then
		return session.roots
	end
	local layer = session.layer_dir
	return {
		{
			index = 1,
			primary = true,
			workspace = session.workspace,
			layer_dir = layer,
			upper_dir = upper_dir(session),
			work_dir = layer and (layer .. "/work") or nil,
		},
	}
end

--- The upper layer of one root, however the root was built.
local function root_upper(root)
	if not root then
		return nil
	end
	if root.upper_dir and root.upper_dir ~= "" then
		return root.upper_dir
	end
	if root.layer_dir and root.layer_dir ~= "" then
		return root.layer_dir .. "/upper"
	end
	return nil
end

--- The base a root's upper layer is keyed by.
---
--- WI-4: with a BROAD ROOT the turn has ONE overlay, mounted at an ancestor of
--- the workspace, so every relative path in its upper is relative to THAT
--- directory -- not to the workspace. Without one it is the workspace, which
--- is byte-for-byte what this walk has always used.
local function walk_base(session, root)
	local primary = root and (root.primary == true or (root.index or 1) == 1)
	if primary and session then
		local broad = session.broad_root
		if type(broad) == "string" and broad ~= "" then
			return broad
		end
	end
	return root and root.workspace or nil
end

--- WHICH REPOSITORY A TOUCHED PATH BELONGS TO.
---
--- `.git` is a directory in an ordinary clone and a file in a worktree or submodule;
--- `workspace_identity.git_root` is the single implementation both this and claim
--- identity ask, so a hunk can never be grouped under one repository and claimed under
--- another.
---
--- With no repository above it the answer is the operator-visible unit that
--- still exists: the turn's own workspace when the path is inside it,
--- otherwise the outermost directory below the broad root that contains it
--- (`~/code/newthing` for `~/code/newthing/a/b.txt`) -- the same "nearest
--- repository, else the containing project" shape `jail.declarable_write_root`
--- already uses for a refusal remedy.
local function repo_root_for(abs, base, workspace)
	if type(abs) ~= "string" or abs == "" then
		return workspace or base
	end
	local dir = abs
	if vim.fn.isdirectory(abs) ~= 1 then
		dir = vim.fn.fnamemodify(abs, ":h")
	end
	local git = workspace_identity.git_root(dir, base)
	if git then
		return git
	end
	if workspace and workspace ~= "" and (dir == workspace or dir:sub(1, #workspace + 1) == workspace .. "/") then
		return workspace
	end
	if base and base ~= "" and dir ~= base and dir:sub(1, #base + 1) == base .. "/" then
		local first = dir:sub(#base + 2):match("^([^/]+)")
		if first then
			return base .. "/" .. first
		end
	end
	return base or dir
end

--- ONE WALK, REGROUPED BY TOUCHED REPOSITORY.
---
--- Returns a list of `{ root, upper, typed }`, one entry per repository the walk
--- actually found something in, the turn's own workspace first and the rest in path
--- order. Each `root` is the same descriptor shape `changes_for_root` has always been
--- handed; `root.upper_prefix` is the repository's path relative to the upper layer's
--- own base, which is what keeps `rel` repository-relative while the bytes are still
--- read out of the one upper.
---
--- A turn with no broad root produces exactly one group, containing exactly
--- the operations `typed_ops(workspace, upper)` has always produced, with the
--- same `rel` values and the same index -- so a single-repository turn reaches
--- identical code with identical results.
local function walks_for_session(session)
	local walks = {}
	for _, root in ipairs(M.session_roots(session)) do
		local upper = root_upper(root)
		if not upper then
			return nil, "turn has no overlay upper layer"
		end
		local base = walk_base(session, root)
		local typed, err = M.typed_ops(base, upper)
		if not typed then
			return nil, err or "reading the change set failed"
		end
		if base == root.workspace then
			-- Unchanged shape: one group, the root exactly as it was built.
			for _, op in ipairs(typed) do
				op.upper_rel = op.rel
				op.root = root.workspace
				op.root_index = root.index or 1
			end
			walks[#walks + 1] = {
				root = {
					index = root.index or 1,
					primary = root.primary,
					workspace = root.workspace,
					upper_prefix = "",
				},
				upper = upper,
				typed = typed,
			}
		else
			local groups, order = {}, {}
			for _, op in ipairs(typed) do
				local repo = repo_root_for(op.path, base, root.workspace)
				local bucket = groups[repo]
				if not bucket then
					bucket = {}
					groups[repo] = bucket
					order[#order + 1] = repo
				end
				op.upper_rel = op.rel
				-- `rel` is now relative to the operation's OWN repository, which
				-- is what makes it unambiguous on the review surface and what the
				-- journal for that repository is keyed by.
				if op.path == repo then
					op.rel = vim.fn.fnamemodify(op.path, ":t")
				elseif op.path:sub(1, #repo + 1) == repo .. "/" then
					op.rel = op.path:sub(#repo + 2)
				end
				bucket[#bucket + 1] = op
			end
			table.sort(order)
			-- The turn's own workspace is always index 1 when it was touched, so
			-- every change id a single-repository turn has ever minted is
			-- unchanged; the other repositories take 2..N in path order.
			local indexed = {}
			local next_index = 2
			for _, repo in ipairs(order) do
				if repo == root.workspace then
					indexed[repo] = 1
				else
					indexed[repo] = next_index
					next_index = next_index + 1
				end
			end
			local ordered = {}
			for _, repo in ipairs(order) do
				ordered[#ordered + 1] = repo
			end
			table.sort(ordered, function(a, b)
				return indexed[a] < indexed[b]
			end)
			for _, repo in ipairs(ordered) do
				local prefix = ""
				if repo ~= base and repo:sub(1, #base + 1) == base .. "/" then
					prefix = repo:sub(#base + 2)
				end
				for _, op in ipairs(groups[repo]) do
					op.root = repo
					op.root_index = indexed[repo]
				end
				walks[#walks + 1] = {
					root = {
						index = indexed[repo],
						primary = repo == root.workspace,
						workspace = repo,
						upper_prefix = prefix,
					},
					upper = upper,
					typed = groups[repo],
				}
			end
		end
	end
	return walks
end

--- The typed operations of EVERY repository a turn wrote, each tagged with the
--- repository it belongs to. Groups come first in index order, operations
--- within a group in the order `typed_ops` already sorts them, so the report
--- is deterministic.
function M.typed_ops_from_session(session)
	local walks, err = walks_for_session(session)
	if not walks then
		return nil, err
	end
	local out = {}
	for _, walk in ipairs(walks) do
		for _, op in ipairs(walk.typed) do
			out[#out + 1] = op
		end
	end
	return out
end

M.count_rel_ops = count_rel_ops
M.reviewable = reviewable
M.rel_op_key = rel_op_key
M.walks_for_session = walks_for_session
M.PAIRED_REFUSAL_REASON = PAIRED_REFUSAL_REASON
M._test = { repo_root_for = repo_root_for }

return M
