-- Control-plane path matcher — the single Lua authority for "this path belongs
-- to another program's own state machine, so it is never a review offer and
-- never an apply target".
--
-- the fixed safety contract control-plane invariant ("A control-plane path … is never
-- offered as a review change and is refused by name at the applier, by
-- invariant, not by configuration"); the immutable control-plane rules "Wall 4 —
-- applier fail-safe (control-plane refusal)".
--
-- The classification is LEXICAL and workspace-relative and runs BEFORE any
-- symlink resolution: a `.git` symlink must not lose its name to resolution.
-- This module is the sole home of the rule; ops.lua (producer consumer),
-- diary.lua (applier choke point `resolve_target`) and cli/apply.lua all call
-- here rather than re-deriving it. The producer `bin/yana-changeset` keeps
-- an intentionally identical Python mirror of the same immutable floor, because
-- the two live on opposite sides of a process boundary; both cite this spec as
-- the single source of truth.
local M = {}

-- Immutable floor, compiled into the product. Config may ADD segments and may
-- NEVER remove one (the immutable control-plane rules "Standing rule — config
-- within immutable floors": Control plane | `.git/`, `.hg/`, `.svn/` always
-- refused | **add** segments only). A config typo that drops `.git` is exactly
-- the incident that started this work, so removal is structurally impossible:
-- the floor is unioned in unconditionally, last, below.
M.FLOOR = { ".git", ".hg", ".svn" }

--- Build the effective segment set: operator-added segments (if any) plus the
--- immutable floor. Segments are compared case-folded, so every key is stored
--- lower-cased and callers lower-case the path segment before lookup. The floor
--- is added last and unconditionally; nothing an operator passes can remove it.
function M.segments(extra)
	local set = {}
	if type(extra) == "table" then
		for _, seg in ipairs(extra) do
			if type(seg) == "string" and seg ~= "" then
				set[seg:lower()] = true
			end
		end
	end
	for _, seg in ipairs(M.FLOOR) do
		set[seg:lower()] = true -- floor wins; cannot be removed by config
	end
	return set
end

--- The control-plane segment this path matches, or nil.
---
--- Match is by whole path SEGMENT, case-folded, anywhere in the path — the
--- segment itself or any ancestor/descendant. It is a segment match, never a
--- prefix match: `.gitignore`, `.github`, `foo.git` are ALLOWED; `.git`,
--- `.git/config`, `a/.GIT/b` are refused.
---
--- `rel` is the LEXICAL workspace-relative path. Separators other than `/`
--- (backslash) and absolute/dot components are the province of
--- `manifest.validate_rel` and `resolve_target`; this classifier only asks
--- whether any `/`-delimited segment names a control-plane directory.
function M.match(rel, opts)
	if type(rel) ~= "string" or rel == "" then
		return nil
	end
	local set
	if opts and opts.segments then
		-- A caller may pass a precomputed set for speed, but the immutable floor
		-- is unioned in unconditionally so a supplied (even empty) set can never
		-- drop `.git`/`.hg`/`.svn` (an empty supplied set once removed the
		-- floor). We copy rather than mutate the caller's table.
		set = {}
		for k in pairs(opts.segments) do
			set[k] = true
		end
		for _, seg in ipairs(M.FLOOR) do
			set[seg:lower()] = true
		end
	else
		set = M.segments(opts and opts.extra)
	end
	for seg in rel:gmatch("[^/]+") do
		if set[seg:lower()] then
			return seg
		end
	end
	return nil
end

--- Predicate form of `match`.
function M.is_control_plane(rel, opts)
	return M.match(rel, opts) ~= nil
end

-- Top-level entries of a BARE repository. A bare repo has no `.git/` segment to
-- catch, so its `HEAD`/`objects/`/`refs/`/`config` sit at the workspace root.
-- These are refused ONLY when the caller has PROVEN the workspace root is bare
-- (git `core.bare = true` plus the HEAD/objects/refs triad); an ordinary project
-- with a stray top-level `HEAD` is never refused. The safety rule is to refuse
-- bare-repository roots — but only after PROVING the root is bare … refusing on
-- names alone manufactures false refusals."
M.BARE_NAMES = {
	["head"] = true,
	["config"] = true,
	["objects"] = true,
	["refs"] = true,
	["packed-refs"] = true,
	["hooks"] = true,
	["info"] = true,
	["branches"] = true,
	["description"] = true,
	["orig_head"] = true,
	["fetch_head"] = true,
	["logs"] = true,
	["worktrees"] = true,
	["index"] = true,
}

--- The first path segment of a workspace-relative path, lower-cased, or nil.
function M.first_segment(rel)
	if type(rel) ~= "string" then
		return nil
	end
	local seg = rel:match("^([^/]+)")
	return seg and seg:lower() or nil
end

--- Classify a name as a bare-repo top-level entry. The caller MUST have proven
--- bareness first; this only asks whether the name is a git-internal root entry.
function M.is_bare_entry(rel)
	local seg = M.first_segment(rel)
	return seg ~= nil and M.BARE_NAMES[seg] == true
end

--- Proof (not a name-guess) that a workspace root is a BARE repository: the
--- HEAD/objects/refs triad plus a `config` marked `core.bare = true`. An ordinary
--- project with a stray top-level `HEAD` lacks the triad and the marker, so it is
--- NOT treated as bare — no false refusal. The single home of this
--- proof, reused by the applier and the change consumer.
function M.workspace_is_bare(workspace)
	local uv = vim.uv or vim.loop
	local function exists(p)
		return uv.fs_stat(p) ~= nil
	end
	if not (exists(workspace .. "/HEAD") and exists(workspace .. "/objects") and exists(workspace .. "/refs")) then
		return false
	end
	local fd = uv.fs_open(workspace .. "/config", "r", 292)
	if not fd then
		return false
	end
	local st = uv.fs_fstat(fd)
	local data = st and uv.fs_read(fd, st.size, 0) or nil
	uv.fs_close(fd)
	if type(data) ~= "string" then
		return false
	end
	return data:match("bare%s*=%s*true") ~= nil
end

--- A refusal message naming the path and the offending segment, for the
--- applier's fail-safe.
function M.refusal(rel, opts)
	local seg = M.match(rel, opts)
	if not seg then
		return nil
	end
	return string.format(
		"%s: refused — control-plane path (segment %q). Repository-internal paths owned by "
			.. "another program (git/hg/svn) are never applied; they are recorded and discarded with the overlay",
		tostring(rel),
		seg
	)
end

return M
