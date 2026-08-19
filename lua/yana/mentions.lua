-- yana: @mention registry (pure data, no UI/completion knowledge).
-- Mirrors commands.lua's shape and avante's mentions design
-- (avante/utils/init.lua get_chat_mentions / extract_mentions).
--
-- M.get_mentions(panel) -> { { description, command, details, callback? }, ... }
-- M.extract_mentions(text) -> { new_content, enable_diagnostics }
--
-- Deliberately NO @codebase: avante backs it with repo_map.lua; yana
-- has no equivalent, so shipping it would be a mention that lies.
--
-- Spec: the public command contract

local log = require("yana.log")

local M = {}

local function insert_paths(panel, paths)
	if not panel or not paths or #paths == 0 then
		return
	end
	require("yana.ui").insert_at_cursor(panel.prompt_buf, panel.prompt_win, table.concat(paths, " "))
end

local function relpath(name)
	if not name or name == "" then
		return nil
	end
	local rel = vim.fn.fnamemodify(name, ":.")
	return rel ~= "" and rel or name
end

-- @file: open a file picker (vim.ui.select, overridable by the user's own
-- picker plugin), insert the chosen path at the cursor. git-tracked files
-- first (fast, respects .gitignore); falls back to a glob outside a repo.
local function pick_file(panel)
	local files = nil
	local ok = pcall(function()
		local out = vim.fn.systemlist({ "git", "ls-files" })
		if vim.v.shell_error == 0 and out and #out > 0 then
			files = out
		end
	end)
	if not ok or not files then
		local ok_glob, globbed = pcall(vim.fn.glob, "**/*", false, true)
		if ok_glob and globbed then
			files = vim.tbl_filter(function(p)
				return vim.fn.isdirectory(p) ~= 1
			end, globbed)
		end
	end
	if not files or #files == 0 then
		vim.notify("yana: no files found to mention", vim.log.levels.INFO)
		return
	end
	vim.ui.select(files, { prompt = "yana: @file" }, function(choice)
		if not choice then
			return
		end
		insert_paths(panel, { choice })
	end)
end

local function buffer_paths()
	local out = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
			local name = vim.api.nvim_buf_get_name(buf)
			local rel = relpath(name)
			if rel then
				out[#out + 1] = rel
			end
		end
	end
	return out
end

local function quickfix_paths()
	local seen, out = {}, {}
	for _, item in ipairs(vim.fn.getqflist()) do
		if item.bufnr and item.bufnr > 0 then
			local rel = relpath(vim.api.nvim_buf_get_name(item.bufnr))
			if rel and not seen[rel] then
				seen[rel] = true
				out[#out + 1] = rel
			end
		end
	end
	return out
end

function M.get_mentions(panel)
	return {
		{
			description = "file",
			command = "file",
			details = "Insert a project file path",
			callback = function(p)
				pick_file(p or panel)
			end,
		},
		{
			description = "buffers",
			command = "buffers",
			details = "Insert paths of open buffers",
			callback = function(p)
				insert_paths(p or panel, buffer_paths())
			end,
		},
		{
			description = "quickfix",
			command = "quickfix",
			details = "Insert paths from the quickfix list",
			callback = function(p)
				insert_paths(p or panel, quickfix_paths())
			end,
		},
		{
			description = "diagnostics",
			command = "diagnostics",
			details = "Attach current-buffer diagnostics as context",
			-- Strip-and-flag: no insert action of its own. extract_mentions
			-- below removes the token from the outgoing text and sets the
			-- flag context.build consumes.
		},
	}
end

-- Mirrors avante/utils/init.lua's extract_mentions, but @diagnostics is
-- strip-and-flag (unlike avante's own @diagnostics, which only sets the
-- flag and leaves the token in place) — this feature's contract removes it
-- from the text actually sent to the agent.
function M.extract_mentions(content)
	content = content or ""
	local enable_diagnostics = false
	local new_content = content
	if content:match("@diagnostics") then
		enable_diagnostics = true
		local ok, stripped = pcall(string.gsub, content, "@diagnostics", "")
		if ok then
			new_content = stripped
		else
			log.write("WARN", "yana.mentions: failed to strip @diagnostics")
		end
	end
	return {
		new_content = new_content,
		enable_diagnostics = enable_diagnostics,
	}
end

return M
