-- Canonical workspace identity for claim keys. Shared contract: the CLI copies
-- these rules byte-for-byte in `bin/yana-turn` (`workspace_slug`).
local M = {}

local diff = require("yana.diff")

--- THE nearest repository root at or above `path`, or nil when there is none.
---
--- ONE implementation of "which repository is this" for the whole product:
--- claim identity (below) and turn-workspace resolution
--- (`shadow/preview.lua`'s `workspace_for_turn`, WI-3) both ask here, so a
--- claim can never be keyed by a different repository than the one whose
--- overlay the turn ran in.
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

--- Repository/workspace root used for claim identity. Walks up to a `.git`
--- directory when present; otherwise uses the resolved workspace path.
function M.canonical_workspace(workspace)
	local abs = vim.fn.resolve(vim.fn.fnamemodify(diff.abs_path(workspace), ":p"))
	return M.git_root(abs) or abs
end

--- 16-hex slug from filesystem identity `(dev, ino)` of the canonical workspace.
function M.workspace_slug(workspace)
	local target = M.canonical_workspace(workspace)
	local loop = vim.uv or vim.loop
	local st = loop.fs_stat(target)
	if st then
		return vim.fn.sha256(string.format("%d:%d", st.dev, st.ino)):sub(1, 16)
	end
	return vim.fn.sha256(target):sub(1, 16)
end

return M
