-- Workspace/root resolution and on-disk pruning helpers, split out of
-- shadow/preview.lua. Reached from the facade under the original names;
-- `preview_turn.lua` and `preview_settle.lua` also call into this module
-- directly (never through the facade, to avoid a load-time require cycle).
local M = {}

local config = require("yana.config")
local diff = require("yana.diff")
local workspace_identity = require("yana.workspace_identity")
local uv = vim.uv or vim.loop

--- Build one instance bound to the parent's `state_root()` (which reads the
--- facade's own `M._test`/`M._config`, so it must stay defined there) and its
--- `REFUSED_LIMITS` table (so the retention/prune knobs have one source).
function M.new(deps)
	local state_root = deps.state_root
	local limits = deps.limits

	local I = {}

	--- Which directory the turn is ABOUT, from the editor's own position.
	---
	--- The candidate is the open buffer's directory, else the origin's directory,
	--- else cwd -- unchanged from the shape this function has always had, and read
	--- only from the editor, never from anything a turn produced.
	function I.workspace_candidate(opts)
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

	function I.buffer_real_path(opts)
		opts = opts or {}
		local selection = opts.selection
		if selection and selection.buf and vim.api.nvim_buf_is_valid(selection.buf) then
			local name = vim.api.nvim_buf_get_name(selection.buf)
			if name ~= "" then
				return diff.abs_path(name)
			end
		end
		local origin = opts.origin
		if origin and origin.name and origin.name ~= "" and vim.fn.isdirectory(origin.name) ~= 1 then
			return origin.name:match("^/") and diff.abs_path(origin.name) or diff.abs_path(origin.name)
		end
		local name = vim.api.nvim_buf_get_name(0)
		if name ~= "" then
			return diff.abs_path(name)
		end
		return nil
	end

	--- THE TURN'S WORKSPACE: the repository the candidate directory belongs to.
	---
	--- The repository is the unit a claim is taken on and the unit an operator thinks in,
	--- so it is the unit a turn runs in.
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
	function I.resolve_workspace(candidate)
		local abs = diff.abs_path(candidate)
		local git = workspace_identity.git_root(abs)
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
	function I.workspace_for_turn(opts)
		opts = opts or {}
		local candidate = I.workspace_candidate(opts)
		-- WI-3. Reverting this ONE line to `return candidate` is the pre-WI-3
		-- shape and is exactly the mutation
		-- tests/headless/workspace_resolution.lua drives.
		return I.resolve_workspace(candidate)
	end

	--- Workspace slug, byte-identical to the one `bin/yana-turn` computes
	--- (sha256 of the filesystem identity, first 16 hex chars) so a claim taken by the
	--- editor and a claim taken by the CLI collide as they should.
	function I.workspace_slug(workspace)
		return workspace_identity.workspace_slug(workspace)
	end

	-- Absolute overlay layer directory path for one turn.
	function I.layer_dir(workspace, stream, turn_id)
		return table.concat({
			state_root(),
			"layers",
			I.workspace_slug(workspace),
			stream,
			tostring(turn_id),
		}, "/")
	end

	--- Per-turn scratch that is not the layer: the private directory the agent's
	--- relocated caches land in. Nothing about the workspace is copied here.
	function I.turn_dir(workspace, stream, turn_id)
		return table.concat({
			state_root(),
			"turns",
			I.workspace_slug(workspace),
			stream,
			tostring(turn_id),
		}, "/")
	end

	--- True when two absolute paths are the same directory or one contains the
	--- other. Pathnames only: the launcher repeats the same question by filesystem
	--- identity, which is what catches a bind alias, and refuses there.
	function I.contains_path(root, path)
		if not root or root == "" or not path or path == "" then
			return false
		end
		return path == root or path:sub(1, #root + 1) == root .. "/"
	end

	function I.paths_overlap(a, b)
		if not a or not b or a == "" or b == "" then
			return false
		end
		return I.contains_path(a, b) or I.contains_path(b, a)
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
	--- The resolved set is the maximal canonical path set from `{workspace} ∪
	--- write_roots`: if one path contains another, the larger path absorbs the
	--- smaller. This happens before any claim or mount is built. Refusals name only
	--- non-overlap invalid roots, and happen at TURN START before launch.
	---
	--- Returns `roots` (a list of absolute paths, the workspace first, the declared
	--- roots after it in canonical-path order) or `nil, reason`.
	function I.resolve_roots(workspace, declared)
		local primary = diff.abs_path(workspace)
		local primary_real = uv.fs_realpath(primary) or primary
		local state = uv.fs_realpath(state_root()) or state_root()

		local candidates = { primary_real }
		local seen = { [primary_real] = true }
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
			if I.paths_overlap(real, state) then
				return nil,
					string.format(
						"declared write root '%s' resolves inside yana's state root (%s) — declare a project directory instead",
						entry,
						state
					)
			end
			if not seen[real] then
				seen[real] = true
				candidates[#candidates + 1] = real
			end
		end

		local maximal = {}
		for _, candidate in ipairs(candidates) do
			local contained = false
			for _, other in ipairs(candidates) do
				if other ~= candidate and I.contains_path(other, candidate) then
					contained = true
					break
				end
			end
			if not contained then
				maximal[#maximal + 1] = candidate
			end
		end
		table.sort(maximal)

		local primary_scope = primary_real
		for _, root in ipairs(maximal) do
			if I.contains_path(root, primary_real) then
				primary_scope = root
				break
			end
		end
		local roots = { primary_scope }
		for _, root in ipairs(maximal) do
			if root ~= primary_scope then
				roots[#roots + 1] = root
			end
		end
		return roots
	end

	--- THE BROAD ROOT: the ONE directory this turn's single overlay is mounted at.
	---
	--- Everything beneath it is writable inside the jail and lands in the turn's private
	--- upper layer -- the opened repository, a sibling repository, a directory that did
	--- not exist when the turn started -- and everything outside it stays the plain
	--- read-only host bind. The kernel charges the same ~31 ms to mount an overlay over a
	--- broad root as over one directory, so breadth is free; what is not free is a SECOND
	--- mount and a SECOND claim, and there is exactly one of each.
	---
	--- Chosen, in order:
	---   1. `capture_root`, the operator's explicit choice;
	---   2. each configured `capture_root_candidates` entry in order;
	---   3. the workspace itself.
	---
	--- `write_roots` is resolved separately as a maximal set. When an ancestor
	--- write_root absorbs the opened workspace, that ancestor becomes root 1 rather
	--- than a `broad_root` override.
	---
	--- THE STATE ROOT IS NEVER INSIDE IT. yana's layers, claims and journals are the
	--- evidence this turn's review is read from; an overlay covering them would hand the
	--- agent its own change set. A default candidate that contains the state root is
	--- skipped (which is why an ordinary `~/.local/state/yana` install lands on `~/code`
	--- and not on `$HOME`); an explicitly configured one refuses the turn BY NAME, because
	--- silently narrowing an operator's own setting is worse than saying so.
	---
	--- CARDINAL PRINCIPLE: config and filesystem position only. No step reads
	--- anything a turn produced.
	---
	--- Returns the absolute broad root, or nil plus a reason.
	function I.broad_root_for(workspace, declared)
		local ws = diff.abs_path(workspace)
		local ws_real = uv.fs_realpath(ws) or ws
		local state = uv.fs_realpath(state_root()) or state_root()

		local override, override_key = config.options.capture_root, "capture_root"
		if override then
			local real = uv.fs_realpath(override)
			if not real or vim.fn.isdirectory(real) ~= 1 then
				return nil,
					string.format("%s '%s' does not exist or is not a directory", override_key, override)
			end
			if not I.contains_path(real, ws_real) then
				return nil,
					string.format(
						"%s '%s' is not an ancestor of this turn's workspace (%s) — the capture root must contain the "
							.. "repository the turn runs in",
						override_key,
						real,
						ws_real
					)
			end
			if I.contains_path(real, state) then
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

		for _, candidate in ipairs(config.options.capture_root_candidates or {}) do
			local real = uv.fs_realpath(candidate)
			if real and vim.fn.isdirectory(real) == 1 and I.contains_path(real, ws_real) and not I.contains_path(real, state) then
				return real, "capture_root_candidates"
			end
		end
		return ws, "workspace"
	end

	function I.directory_empty(path)
		local scan = uv.fs_scandir(path)
		if not scan then
			return true
		end
		return uv.fs_scandir_next(scan) == nil
	end

	--- Remove expired durable refusal trees without touching any sibling feature
	--- data in the same turn directories. Ordering is by filesystem mtime because
	--- editor-local turn ids reset and do not define a global chronology.
	function I.prune_refused_turns(stream_turns_dir)
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
			if i > limits.turns or now - item.mtime > limits.seconds then
				pcall(vim.fn.delete, item.refused_path, "rf")
				if I.directory_empty(item.turn_path) then
					pcall(vim.fn.delete, item.turn_path, "d")
				end
			end
		end
	end

	function I.prune_recovered(stream_recovery_dir)
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
			if i > limits.turns or now - row.mtime > limits.seconds then
				pcall(vim.fn.delete, row.path, "rf")
			end
		end
	end

	return I
end

return M
