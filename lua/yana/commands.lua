-- yana: slash-command registry (engine-agnostic, no UI/completion
-- knowledge). Mirrors avante's shape (avante/slashcommands.lua): a
-- declarative descriptor table `{ name, description, details }` beside a
-- SEPARATE `callbacks` table keyed by name, zipped by M.get_commands.
--
-- Callback contract: fun(panel, args, cb) — exactly two legal outcomes:
--   - local kind:   act on the panel, call cb(nil); nothing is sent.
--   - rewrite kind: call cb(text); text becomes the submitted prompt.
-- Every builtin below is "local" kind — each wraps an already-exported
-- ui.lua function. Disk-backed commands (below) are always "rewrite" kind.
--
-- Spec: the public command contract

local log = require("yana.log")

local M = {}

----------------------------------------------------------------------
-- builtins
----------------------------------------------------------------------

local builtin_descriptors = {
	{ name = "help", description = "List available commands", details = "Show every slash command" },
	{ name = "new", description = "Start a new chat", details = "Clear this panel's history and start fresh" },
	{ name = "model", description = "Pick a model", details = "Select the model used by this panel" },
	{ name = "mode", description = "Cycle agent/ask mode", details = "Only before this chat's first turn; a chat's mode is locked once it has run a turn" },
	{ name = "resume", description = "Resume a session", details = "Pick a previous session to resume" },
	{ name = "resend", description = "Resend last prompt", details = "here (default) | new = new chat | agent = new chat in agent mode" },
	{ name = "queue", description = "Manage queued prompts", details = "View, edit, delete or send a queued prompt" },
	{ name = "stop", description = "Stop the current turn", details = "Cancel the in-flight agent turn" },
	{ name = "review", description = "Review file changes", details = "Open the diff review for a pending change" },
}

-- Append the command list to the conversation buffer. Deliberately
-- self-contained (no new ui.lua export beyond insert_at_cursor, per the
-- feature's single deliberate interface widening) — toggles modifiable the
-- same way ui.lua's own append() does.
local function render_help(panel, list)
	if not panel or not panel.conv_buf or not vim.api.nvim_buf_is_valid(panel.conv_buf) then
		return
	end
	local lines = { "", "**Commands:**" }
	for _, c in ipairs(list) do
		lines[#lines + 1] = string.format("- `/%s` — %s", c.name, c.description or "")
	end
	lines[#lines + 1] = ""
	local buf = panel.conv_buf
	local was_modifiable = vim.bo[buf].modifiable
	vim.bo[buf].modifiable = true
	local last = vim.api.nvim_buf_line_count(buf)
	vim.api.nvim_buf_set_lines(buf, last, last, false, lines)
	vim.bo[buf].modifiable = was_modifiable
end

local builtin_callbacks = {
	help = function(panel, _args, cb)
		render_help(panel, M.get_commands(panel))
		cb(nil)
	end,
	new = function(_panel, _args, cb)
		require("yana.ui").new_chat()
		cb(nil)
	end,
	model = function(_panel, _args, cb)
		require("yana.ui").pick_model()
		cb(nil)
	end,
	mode = function(_panel, _args, cb)
		require("yana.ui").toggle_mode()
		cb(nil)
	end,
	resend = function(_panel, args, cb)
		local where = (args or ""):match("%S+") or "here"
		if where ~= "here" and where ~= "new" and where ~= "agent" then
			where = "here"
		end
		require("yana.ui").resend({ where = where })
		if cb then
			cb()
		end
	end,
	resume = function(_panel, _args, cb)
		require("yana.ui").pick_session()
		cb(nil)
	end,
	queue = function(_panel, _args, cb)
		require("yana.ui").pick_queue()
		cb(nil)
	end,
	stop = function(_panel, _args, cb)
		require("yana.ui").stop()
		cb(nil)
	end,
	review = function(_panel, _args, cb)
		require("yana.ui").review_changes()
		cb(nil)
	end,
}

----------------------------------------------------------------------
-- disk-backed custom commands (.cursor/commands/*.md)
----------------------------------------------------------------------
-- Scan order, first hit wins on name collision (project overrides global):
--   1. <git-root-or-cwd>/.cursor/commands/*.md
--   2. ~/.cursor/commands/*.md
-- Descriptor name = file basename. Callback = rewrite whose text is the file
-- body. `---`-fenced frontmatter is parsed for `description`; a malformed or
-- unterminated fence degrades to "whole file is the body" — never errors,
-- never drops the command from the menu.

local function project_root()
	local cwd = vim.fn.getcwd()
	local ok, root = pcall(vim.fs.root, cwd, ".git")
	if ok and root and root ~= "" then
		return root
	end
	return cwd
end

-- Returns description (or nil), body (string). Never throws.
local function parse_command_file(lines)
	if lines[1] ~= "---" then
		return nil, table.concat(lines, "\n")
	end

	local close = nil
	for i = 2, #lines do
		if lines[i] == "---" then
			close = i
			break
		end
	end
	if not close then
		-- Unterminated fence: degrade to whole-file-is-body.
		return nil, table.concat(lines, "\n")
	end

	local description = nil
	for i = 2, close - 1 do
		local d = lines[i]:match("^description:%s*(.*)$")
		if d then
			description = vim.trim(d)
		end
	end
	local body_lines = {}
	for i = close + 1, #lines do
		body_lines[#body_lines + 1] = lines[i]
	end
	return description, table.concat(body_lines, "\n")
end

-- path -> { mtime, name, description, body }, so re-reading/re-parsing a
-- file is skipped unless its mtime changed (edited command files are picked
-- up without restarting nvim; unchanged ones are cheap to re-glob).
local disk_file_cache = {}

local function file_mtime(path)
	local ok, stat = pcall((vim.uv or vim.loop).fs_stat, path)
	if ok and stat then
		return stat.mtime.sec
	end
	return 0
end

local function scan_dir(dir, out, seen)
	if vim.fn.isdirectory(dir) ~= 1 then
		return
	end
	local ok_glob, files = pcall(vim.fn.glob, dir .. "/*.md", false, true)
	if not ok_glob or not files then
		return
	end
	for _, path in ipairs(files) do
		local name = vim.fn.fnamemodify(path, ":t:r")
		if not seen[name] then
			seen[name] = true
			local mtime = file_mtime(path)
			local cached = disk_file_cache[path]
			if not cached or cached.mtime ~= mtime then
				local ok_read, lines = pcall(vim.fn.readfile, path)
				if ok_read then
					local description, body = parse_command_file(lines)
					cached = { mtime = mtime, description = description, body = body }
					disk_file_cache[path] = cached
				end
			end
			if cached then
				out[#out + 1] = {
					name = name,
					description = cached.description or ("custom command: " .. name),
					details = path,
					callback = function(_panel, _args, cb)
						cb(cached.body)
					end,
				}
			end
		end
	end
end

----------------------------------------------------------------------
-- skills (~/.cursor/skills, ~/.cursor/skills-cursor, ~/.claude/skills,
-- .codex/skills, + project-local .cursor/skills)
----------------------------------------------------------------------
-- Layout differs from disk commands: each skill is a DIRECTORY containing a
-- SKILL.md whose YAML frontmatter carries `name:` and `description:`.
-- Scan order, first hit wins on name collision (mirrors the commands scan):
--   1. <git-root-or-cwd>/.cursor/skills/*/SKILL.md
--   2. config.options.skill_dirs, in list order (default: ~/.cursor/skills,
--      ~/.cursor/skills-cursor, ~/.claude/skills, .codex/skills)
-- Precedence with commands: commands are scanned into `seen` FIRST in
-- M.get_commands below, so a command and a skill sharing a name always
-- resolves to the command — skills never shadow a command.
--
-- EXPANSION SEMANTICS: selecting a skill injects the SKILL.md BODY (the
-- text after the closing `---` fence) as the submitted prompt, exactly like
-- a disk command's "rewrite" kind. Rationale: yana drives `cursor-agent
-- --print` headless, so whatever client-side skill-resolution mechanism the
-- interactive Cursor CLI has (if any) is not reachable from a headless
-- --print process — `cursor-agent --help` lists no skill-related flag, and
-- there is no evidence in this binary or repo of headless /skillname
-- resolution. Body-injection is the only semantics guaranteed to work
-- headless.

-- Returns name (or nil), description (or nil), body (string). Never throws
-- — a broken/missing frontmatter degrades to "no name/description, whole
-- file is the body" so a malformed SKILL.md can never break the menu, same
-- discipline as parse_command_file above.
local function parse_skill_file(lines)
	if lines[1] ~= "---" then
		return nil, nil, table.concat(lines, "\n")
	end

	local close = nil
	for i = 2, #lines do
		if lines[i] == "---" then
			close = i
			break
		end
	end
	if not close then
		-- Unterminated fence: degrade to whole-file-is-body.
		return nil, nil, table.concat(lines, "\n")
	end

	local name, description
	for i = 2, close - 1 do
		local n = lines[i]:match("^name:%s*(.*)$")
		if n then
			name = vim.trim(n):gsub("^[\"']", ""):gsub("[\"']$", "")
			if name == "" then
				name = nil
			end
		end
		local d = lines[i]:match("^description:%s*(.*)$")
		if d then
			description = vim.trim(d)
		end
	end
	local body_lines = {}
	for i = close + 1, #lines do
		body_lines[#body_lines + 1] = lines[i]
	end
	return name, description, table.concat(body_lines, "\n")
end

-- path -> { mtime, name, description, body }. Same mtime-cache shape as
-- disk_file_cache above, keyed separately since skill/command paths never
-- collide.
local skill_file_cache = {}

-- Scans `root` for `*/SKILL.md` and appends any new (unseen-by-name) skill
-- into `out`, first hit wins (mirrors scan_dir's seen-table contract).
-- Directory-name fallback when frontmatter `name:` is missing/malformed.
local function scan_skill_dir(dir, out, seen)
	if vim.fn.isdirectory(dir) ~= 1 then
		return
	end
	local ok_glob, paths = pcall(vim.fn.glob, dir .. "/*/SKILL.md", false, true)
	if not ok_glob or not paths then
		return
	end
	for _, path in ipairs(paths) do
		local dirname = vim.fn.fnamemodify(path, ":h:t")
		local mtime = file_mtime(path)
		local cached = skill_file_cache[path]
		if not cached or cached.mtime ~= mtime then
			local ok_read, lines = pcall(vim.fn.readfile, path)
			if ok_read then
				local ok_parse, name, description, body = pcall(parse_skill_file, lines)
				if not ok_parse then
					name, description, body = nil, nil, table.concat(lines, "\n")
				end
				cached = { mtime = mtime, name = name, description = description, body = body }
				skill_file_cache[path] = cached
			end
		end
		if cached then
			local final_name = (cached.name and cached.name ~= "") and cached.name or dirname
			if not seen[final_name] then
				seen[final_name] = true
				out[#out + 1] = {
					name = final_name,
					description = cached.description or ("skill: " .. final_name),
					details = path,
					kind = "skill",
					callback = function(_panel, _args, cb)
						cb(cached.body)
					end,
				}
			end
		end
	end
end

-- Full-tree skill scan result, throttled: directory globbing (readdir per
-- root, stat per SKILL.md) is cheap per-root but these roots hold 100+
-- entries combined, and get_commands() runs on every completion keystroke
-- (the `/` source re-derives the list each time, same as the disk-command
-- scan above). Re-glob at most once per SKILL_SCAN_TTL_MS; individual file
-- reads/parses are additionally mtime-cached above so a rescan inside the
-- TTL window is still cheap once it does fire. Edits are picked up within
-- one TTL window without restarting nvim.
local SKILL_SCAN_TTL_MS = 2000
local skill_scan_cache = { at = -math.huge, list = {} }

local function build_skill_list()
	local list = {}
	local seen = {}
	scan_skill_dir(project_root() .. "/.cursor/skills", list, seen)
	for _, dir in ipairs(require("yana.config").options.skill_dirs) do
		scan_skill_dir(dir, list, seen)
	end
	return list
end

local function get_skill_list()
	local now = (vim.uv or vim.loop).now()
	if now - skill_scan_cache.at < SKILL_SCAN_TTL_MS then
		return skill_scan_cache.list
	end
	local ok, list = pcall(build_skill_list)
	skill_scan_cache.at = now
	if ok then
		skill_scan_cache.list = list
	end
	return skill_scan_cache.list
end

----------------------------------------------------------------------
-- public
----------------------------------------------------------------------

function M.get_commands(panel)
	local list = {}
	local seen = {}
	for _, d in ipairs(builtin_descriptors) do
		list[#list + 1] = {
			name = d.name,
			description = d.description,
			details = d.details,
			kind = "command",
			callback = builtin_callbacks[d.name],
		}
		seen[d.name] = true
	end

	local ok_disk, err = pcall(function()
		local disk = {}
		scan_dir(project_root() .. "/.cursor/commands", disk, seen)
		scan_dir(vim.fn.expand("~/.cursor/commands"), disk, seen)
		for _, c in ipairs(disk) do
			c.kind = "command"
		end
		vim.list_extend(list, disk)
	end)
	if not ok_disk then
		log.write("WARN", "yana.commands: disk scan failed: " .. tostring(err))
	end

	-- Skills share the `/` namespace with commands. `seen` already carries
	-- every builtin + disk-command name from above, so a skill with a
	-- colliding name is silently dropped here — commands win, per the
	-- design note above scan_skill_dir.
	local ok_skills, skills_or_err = pcall(function()
		local skills = {}
		for _, s in ipairs(get_skill_list()) do
			if not seen[s.name] then
				seen[s.name] = true
				skills[#skills + 1] = s
			end
		end
		return skills
	end)
	if ok_skills then
		vim.list_extend(list, skills_or_err)
	else
		log.write("WARN", "yana.commands: skill scan failed: " .. tostring(skills_or_err))
	end

	return list
end

function M.find(panel, name)
	local list = M.get_commands(panel)
	for _, c in ipairs(list) do
		if c.name == name then
			return c
		end
	end
	return nil
end

return M
