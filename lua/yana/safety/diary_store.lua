-- Where diaries live and when an old one may go: one folder per project under
-- Yana's state root, never inside the project.
local M = {}

local uv = vim.uv or vim.loop

local KEEP_SECONDS = 30 * 24 * 60 * 60

local function root()
	return require("yana.shadow.preview").state_root() .. "/diary"
end

--- The folder holding every diary of one workspace.
function M.project_dir(workspace)
	return root() .. "/" .. vim.fn.fnamemodify(workspace, ":t") .. "-" .. vim.fn.sha256(workspace):sub(1, 12)
end

--- A new session folder for one stream of one workspace.
function M.new_session_dir(workspace, stream)
	local flat_stream = stream:gsub("/", "%%")
	return string.format("%s/%s/%d-%d", M.project_dir(workspace), flat_stream, os.time(), math.random(1, 1e6))
end

local function child_dirs(dir)
	local found = {}
	for name, kind in vim.fs.dir(dir) do
		if kind == "directory" then
			found[#found + 1] = dir .. "/" .. name
		end
	end
	return found
end

local function expired(session_dir, cutoff, diary)
	local st = uv.fs_stat(session_dir .. "/journal.jsonl")
	if not st or st.mtime.sec > cutoff then
		return false
	end
	local session = diary.open(session_dir)
	if not session or session.truncated_journal_tail then
		return false
	end
	local ok, summary = pcall(diary.status_summary, session)
	return ok and not summary.error and summary.pending == 0
end

--- Delete every diary unchanged for 30 days with nothing unfinished; a journal
--- that cannot be read in full is kept.
function M.prune(diary)
	local cutoff = os.time() - KEEP_SECONDS
	for _, project in ipairs(child_dirs(root())) do
		for _, stream in ipairs(child_dirs(project)) do
			for _, session_dir in ipairs(child_dirs(stream)) do
				if expired(session_dir, cutoff, diary) then
					vim.fn.delete(session_dir, "rf")
				end
			end
			uv.fs_rmdir(stream)
		end
		uv.fs_rmdir(project)
	end
end

return M
