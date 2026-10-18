-- Workspace/root resolution and on-disk pruning helpers, split out of
-- shadow/preview.lua. Reached from the facade under the original names;
-- `preview_turn.lua` and `preview_settle.lua` also call into this module
-- directly (never through the facade, to avoid a load-time require cycle).
local M = {}

local capture_areas = require("yana.shadow.capture_areas")
local config = require("yana.config")
local diff = require("yana.diff")
local path_key = require("yana.paths.path_key")
local repo_root = require("yana.paths.repo_root")
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
		local git = repo_root.git_root(abs)
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
		-- WI-3. Reverting this ONE line to `return candidate` is the pre-WI-3 shape.
		return I.resolve_workspace(candidate)
	end

	--- F-CLAIM-KEYS (S3). The per-turn state directories below are named by the
	--- REAL PATH of the root they belong to, through the same rule
	--- `bin/lib/yanad/claims.py` applies, so the editor's scratch and the layers
	--- the daemon mints cannot drift apart.
	---
	--- This replaces the old repository key, which hashed the nearest `.git`
	--- directory's `(dev, ino)`. That keyed state by REPOSITORY, so two roots in
	--- one repository shared a directory, and the same tree keyed differently
	--- once `git init` ran. Neither is a property state identity may have.
	function I.path_key(workspace)
		return path_key.of(workspace)
	end

	-- Absolute overlay layer directory path for one turn.
	function I.layer_dir(workspace, stream, turn_id)
		return table.concat({
			state_root(),
			"layers",
			I.path_key(workspace),
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
			I.path_key(workspace),
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

	--- Every root this turn writes, in claim order: the workspace first, then each
	--- capture area (`capture_areas.lua`: home folder, writable data disks) that
	--- neither contains nor sits inside it. The area containing the workspace is
	--- the broad root instead (`broad_root_for`). Filesystem position only; no
	--- configuration and nothing a turn produced selects a root.
	function I.resolve_roots(workspace)
		local primary = diff.abs_path(workspace)
		local primary_real = uv.fs_realpath(primary) or primary
		local roots = { primary_real }
		for _, area in ipairs(capture_areas.list()) do
			if not I.paths_overlap(area, primary_real) then
				roots[#roots + 1] = area
			end
		end
		return roots
	end

	--- THE BROAD ROOT: the ONE directory the workspace's overlay is mounted at -- the
	--- capture area containing the workspace, else the workspace itself. Everything
	--- beneath it lands in the turn's private upper layer: the opened repository, a
	--- sibling repository, a directory that did not exist when the turn started.
	---
	--- Yana's state root may be inside it: the launcher binds the real state root
	--- read-only on top of every overlay that covers it
	--- (`bin/lib/yana-overlay/mount.sh` `mount_state_root_shield`).
	function I.broad_root_for(workspace)
		local ws = diff.abs_path(workspace)
		local ws_real = uv.fs_realpath(ws) or ws
		for _, area in ipairs(capture_areas.list()) do
			if I.contains_path(area, ws_real) then
				return area, "capture_area"
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
