-- Git and the agent: the repository a turn starts in has its `.git`
-- folder bound read-only, and the `.git` folder holding the folder open in Neovim is reviewed
-- like any folder.
local M = {}

local diff = require("yana.diff")

--- The `.git` folder holding the folder open in Neovim, or nil. Its paths are ordinary changes.
function M.open_git(session)
	local folder = session.open_folder and diff.abs_path(session.open_folder) or ""
	return folder:match("^(.-/%.git)/") or folder:match("^(.-/%.git)$")
end

--- The starting repository's `.git` folder to bind read-only, or nil when there is none or it holds the open folder.
function M.dir(session)
	if vim.fn.executable("git") == 0 then
		return nil
	end
	-- Neovim may run as git's editor with GIT_DIR set; the starting repository is the workspace's own.
	local result = vim.system({ "env", "-u", "GIT_DIR", "-u", "GIT_WORK_TREE", "-u", "GIT_COMMON_DIR", "git", "-C",
		session.opened_workspace or session.workspace, "rev-parse", "--path-format=absolute", "--git-common-dir" }, { text = true }):wait()
	local dir = result.code == 0 and vim.trim(result.stdout) or nil
	if dir and not vim.fs.relpath(dir, diff.abs_path(session.open_folder or session.workspace)) then
		return dir
	end
	return nil
end

return M
