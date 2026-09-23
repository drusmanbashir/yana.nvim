-- The nearest repository root at or above a path.
--
-- Split out of the Git-derived workspace-identity module S3 deleted. That file
-- held two unrelated things: the state key F-CLAIM-KEYS retires, and this walk,
-- which answers "which repository is this" for workspace resolution and
-- change-set attribution. Only the first was S3's to retire, so this moved
-- rather than dying with it.
--
-- It is still a Git walk, and it is still on the retirement list for the
-- tracked-file pass. The no-Git launch work is what makes a turn work with no
-- `git` and no `.git` at all; until then this is the one implementation, so
-- nothing re-derives the answer inline.
local M = {}

local diff = require("yana.diff")

--- THE nearest repository root at or above `path`, or nil when there is none.
---
--- ONE implementation of "which repository is this" for the whole product.
--- Turn-workspace resolution (`shadow/preview_workspace.lua`'s
--- `resolve_workspace`, WI-3), the change-set walk's per-repository
--- attribution (`shadow/ops_decode.lua`) and single-file mode all ask here, so
--- no caller re-derives the answer inline.
---
--- Claim identity NO LONGER asks: S3 keyed it to the actual path
--- (`lua/yana/paths/path_key.lua`), so a claim cannot be keyed by a repository at
--- all, let alone a different one.
---
--- `.git` is a DIRECTORY in an ordinary clone and a FILE in a worktree or a
--- submodule; both mean "this is the repository root". `stop` optionally
--- bounds the walk (the broad root, for the finalize walk): the answer is
--- never a directory above it.
function M.git_root(path, stop)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local abs = vim.fn.resolve(vim.fn.fnamemodify(diff.abs_path(path), ":p")):gsub("/+$", "")
	if abs == "" then
		abs = "/"
	end
	local dir = abs
	local depth = 0
	while dir and dir ~= "" and dir ~= "/" and depth < 128 do
		if vim.fn.isdirectory(dir .. "/.git") == 1 or vim.fn.filereadable(dir .. "/.git") == 1 then
			return dir
		end
		if stop and stop ~= "" and dir == stop then
			return nil
		end
		dir = vim.fn.fnamemodify(dir, ":h")
		depth = depth + 1
	end
	return nil
end

return M
