-- Canonical workspace identity for claim keys. Shared contract: the CLI copies
-- these rules byte-for-byte in `bin/yana-turn` (`workspace_slug`).
local M = {}

local diff = require("yana.diff")

--- Repository/workspace root used for claim identity. Walks up to a `.git`
--- directory when present; otherwise uses the resolved workspace path.
function M.canonical_workspace(workspace)
	local abs = vim.fn.resolve(vim.fn.fnamemodify(diff.abs_path(workspace), ":p"))
	local dir = abs
	while dir and dir ~= "" and dir ~= "/" do
		if vim.fn.isdirectory(dir .. "/.git") == 1 then
			return dir
		end
		dir = vim.fn.fnamemodify(dir, ":h")
	end
	return abs
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
