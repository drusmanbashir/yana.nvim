--- THE IGNORE LIST — the one thing that keeps an agent-created file out of
--- review.
---
---
--- The ruling has two halves and this module is the second one. The first half is that
--- Yana INFERS NOTHING: there is no manifest, no tool-walk, no vendor knowledge, and no
--- list of "directories agents tend to write". A path the turn wrote is reviewable
--- unless the OPERATOR said otherwise, which is the same shape the provenance partition
--- already has: that provenance set ships EMPTY, so every undeclared path reviews.
---
--- SYNTAX IS GITIGNORE'S, deliberately. The operator already maintains one of
--- these per repository and should not have to learn a second dialect to say
--- ".agent". Matched on the WORKSPACE-RELATIVE path, the same string the review
--- surface shows.
---
--- TWO SOURCES, merged in this order: 1. `setup({ review = { ignore = { ... } } })` —
--- the project's own list, checked into whatever the operator's config lives in.
---
--- WHAT IS NOT IGNORABLE, ever, whatever the patterns say:
---   * control-plane paths (`.git/`, `.hg/`, `.svn/`) — refused by invariant
---     rather than by configuration, and this module returns
---     false for them before a pattern is even consulted.
---   * destructive and type-changing operations. See `M.ignorable`.
local M = {}

local uv = vim.uv or vim.loop

-- Compiled cache for the merged list, keyed by nothing: it is invalidated
-- wholesale whenever either source could have changed (`M.reset`, `M.add`, a
-- `setup()` whose list differs). Cheap to rebuild -- a handful of patterns --
-- and the matcher is asked once per touched path, not once per file in the
-- workspace.
local cache = nil

--- Where the per-machine list lives. Same state root as claims and layers.
function M.persisted_path()
	local ok, preview = pcall(require, "yana.shadow.preview")
	if not ok then
		return nil
	end
	local root = preview.state_root()
	if type(root) ~= "string" or root == "" then
		return nil
	end
	return root .. "/ignore"
end

--- Drop the compiled cache. Called by `M.add`, by tests, and whenever the
--- persisted file is rewritten by hand under a running editor.
function M.reset()
	cache = nil
end

local function setup_patterns()
	local ok, config = pcall(require, "yana.config")
	if not ok then
		return {}
	end
	local review = config.options and config.options.review or nil
	local list = review and review.ignore or nil
	if type(list) ~= "table" then
		return {}
	end
	local out = {}
	for _, entry in ipairs(list) do
		if type(entry) == "string" then
			out[#out + 1] = entry
		end
	end
	return out
end

local function persisted_patterns()
	local path = M.persisted_path()
	if not path or vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok or type(lines) ~= "table" then
		return {}
	end
	return lines
end

--- The merged list, in source order (setup first, persisted second). Comments
--- and blank lines are kept verbatim here -- `compile` is what discards them --
--- so `:YanaIgnore` with no arguments can show the operator the file they
--- actually have.
function M.patterns()
	local out = {}
	for _, pat in ipairs(setup_patterns()) do
		out[#out + 1] = pat
	end
	for _, pat in ipairs(persisted_patterns()) do
		local trimmed = vim.trim(pat)
		if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
			out[#out + 1] = trimmed
		end
	end
	return out
end

--- Append one pattern to the per-machine file. Refuses an empty pattern and a
--- duplicate BY NAME rather than silently no-opping, so an operator who typed
--- the same thing twice learns it was already there.
---
--- @return boolean ok, string|nil err
function M.add(pattern)
	pattern = vim.trim(tostring(pattern or ""))
	if pattern == "" then
		return false, "an ignore pattern cannot be empty"
	end
	if pattern:sub(1, 1) == "#" then
		return false, "an ignore pattern cannot start with `#` (that is a comment); escape it as `\\#`"
	end
	for _, existing in ipairs(M.patterns()) do
		if existing == pattern then
			return false, "already on the ignore list: " .. pattern
		end
	end
	local path = M.persisted_path()
	if not path then
		return false, "no state root is available to persist the ignore list in"
	end
	local dir = vim.fn.fnamemodify(path, ":h")
	if vim.fn.isdirectory(dir) ~= 1 and vim.fn.mkdir(dir, "p") ~= 1 then
		return false, "cannot create the state directory " .. dir
	end
	local fh, ferr = io.open(path, "a")
	if not fh then
		return false, "cannot append to " .. path .. ": " .. tostring(ferr)
	end
	fh:write(pattern .. "\n")
	fh:close()
	M.reset()
	return true
end

----------------------------------------------------------------------
-- gitignore syntax
----------------------------------------------------------------------

local MAGIC = "[%^%$%(%)%%%.%[%]%*%+%-%?]"

--- One path SEGMENT's glob, as an anchored Lua pattern. `*` and `?` never
--- cross a `/` because a segment cannot contain one; `[...]` is passed through
--- as a character class with gitignore's `!` negation spelled Lua's `^`.
local function segment_pattern(seg)
	local out = { "^" }
	local i, n = 1, #seg
	while i <= n do
		local c = seg:sub(i, i)
		if c == "\\" and i < n then
			local nxt = seg:sub(i + 1, i + 1)
			out[#out + 1] = nxt:match(MAGIC) and ("%" .. nxt) or nxt
			i = i + 2
		elseif c == "*" then
			out[#out + 1] = "[^/]*"
			i = i + 1
		elseif c == "?" then
			out[#out + 1] = "[^/]"
			i = i + 1
		elseif c == "[" then
			local close = seg:find("]", i + 2, true)
			if close then
				local body = seg:sub(i + 1, close - 1)
				if body:sub(1, 1) == "!" then
					body = "^" .. body:sub(2)
				end
				out[#out + 1] = "[" .. body .. "]"
				i = close + 1
			else
				out[#out + 1] = "%["
				i = i + 1
			end
		else
			out[#out + 1] = c:match(MAGIC) and ("%" .. c) or c
			i = i + 1
		end
	end
	out[#out + 1] = "$"
	return table.concat(out)
end

--- Compile the merged pattern list into ordered rules. Comments, blanks and
--- surrounding whitespace go here, not in `M.patterns`.
---
--- @return table rules
function M.compile(patterns)
	local rules = {}
	for _, raw in ipairs(patterns or {}) do
		local line = vim.trim(tostring(raw or ""))
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local negate = false
			if line:sub(1, 1) == "!" then
				negate = true
				line = line:sub(2)
			elseif line:sub(1, 2) == "\\#" or line:sub(1, 2) == "\\!" then
				line = line:sub(2)
			end
			local dir_only = false
			if line:sub(-1) == "/" then
				dir_only = true
				line = line:sub(1, -2)
			end
			-- A pattern with no slash left in it matches at ANY depth, which is
			-- exactly a leading `**/`. A leading `/` means "anchored at the
			-- workspace root" and the anchor is the default here, so it is simply
			-- dropped.
			local anchored = line:find("/", 1, true) ~= nil
			if line:sub(1, 1) == "/" then
				line = line:sub(2)
			end
			if line ~= "" then
				local segs = {}
				for seg in line:gmatch("[^/]+") do
					segs[#segs + 1] = seg
				end
				local compiled = {}
				if not anchored then
					compiled[#compiled + 1] = "**"
				end
				for _, seg in ipairs(segs) do
					compiled[#compiled + 1] = (seg == "**") and "**" or segment_pattern(seg)
				end
				rules[#rules + 1] = { negate = negate, dir_only = dir_only, segs = compiled, source = raw }
			end
		end
	end
	return rules
end

--- `**` matches zero or more whole segments; every other entry matches exactly
--- one. Recursive because a trailing `**` and a middle `**` need the same rule,
--- and the segment counts here are single digits.
local function match_segs(pat, pi, segs, si)
	while true do
		if pi > #pat then
			return si > #segs
		end
		if pat[pi] == "**" then
			for k = si, #segs + 1 do
				if match_segs(pat, pi + 1, segs, k) then
					return true
				end
			end
			return false
		end
		if si > #segs then
			return false
		end
		if not segs[si]:match(pat[pi]) then
			return false
		end
		pi = pi + 1
		si = si + 1
	end
end

--- Does this rule set ignore `rel`?
---
--- Evaluated LEVEL BY LEVEL, outermost ancestor first, because that is how git
--- behaves and the difference is observable: "it is not possible to re-include
--- a file if a parent directory of that file is excluded". Each level's state
--- is decided by the LAST rule matching that level; once a level comes out
--- ignored, the answer is ignored and no deeper `!` rule can reopen it.
---
--- @param rules table from `M.compile`
--- @param rel string workspace-relative path
--- @param is_dir boolean|nil whether `rel` itself names a directory
function M.match(rules, rel, is_dir)
	if type(rel) ~= "string" or rel == "" then
		return false
	end
	local segs = {}
	for seg in rel:gmatch("[^/]+") do
		segs[#segs + 1] = seg
	end
	if #segs == 0 then
		return false
	end
	for level = 1, #segs do
		local prefix = {}
		for i = 1, level do
			prefix[i] = segs[i]
		end
		-- Every level except the last IS a directory; the last is one only if
		-- the caller said so.
		local level_is_dir = (level < #segs) or (is_dir == true)
		local ignored = false
		for _, rule in ipairs(rules or {}) do
			if (not rule.dir_only) or level_is_dir then
				if match_segs(rule.segs, 1, prefix, 1) then
					ignored = not rule.negate
				end
			end
		end
		if ignored then
			return true
		end
	end
	return false
end

local function rules()
	if cache == nil then
		cache = M.compile(M.patterns())
	end
	return cache
end

--- Is this workspace-relative path on the operator's ignore list?
function M.matches(rel, is_dir)
	local compiled = rules()
	if #compiled == 0 then
		return false
	end
	return M.match(compiled, rel, is_dir)
end

--- WHICH OPERATIONS THE IGNORE LIST MAY ACT ON AT ALL.
---
--- The ruling is about letting files agents CREATE through. Write-through is a
--- real-tree write that no human ever approves, so it is confined to the
--- operations where "untouched, as the agent left it" is a complete
--- description:
---
---   * `create`/`modify` of a regular file — the bytes are copied through.
---
--- A DIRECTORY CREATE IS NOT ON THAT LIST, and deliberately: a directory is not a
--- decision of its own (`shadow/ops.lua`'s `is_dir_create`), so it is not the ignore
--- list's to hide either. It needs no write-through -- creating a file's parent is part
--- of writing the file -- and counting it in the turn-summary line would report three
--- ignored paths for two ignored files. A NEW EMPTY directory the ignore list matches
--- therefore still reaches the structural-dir rule with nothing under it, and is still
---
--- Everything else on an ignored path keeps exactly the behaviour it has today, and the
--- reason is CORE's, not taste. A `delete` or an `opaque` is DESTRUCTIVE, and CORE
--- requires producer base evidence plus pre-turn trackedness before anything is
--- destroyed outside review; a line of text in `setup()` is not that evidence, and
--- honouring it would let one config entry silently delete tracked content. A `symlink`
--- retarget and a `mode` change are neither creations nor content, and a turn that
---
--- The operator may widen this, and if they do, only this function changes.
---
--- CONTROL PLANE FIRST, before any pattern is consulted: `.git/`, `.hg/` and
--- `.svn/` are refused by invariant and no configuration reaches them.
function M.ignorable(op)
	if type(op) ~= "table" or op.control_plane then
		return false
	end
	if type(op.rel) ~= "string" or op.rel == "" then
		return false
	end
	local ok, control_plane = pcall(require, "yana.safety.control_plane")
	if ok and control_plane.is_control_plane(op.rel) then
		return false
	end
	return (op.kind == "create" or op.kind == "modify") and op.detail == "file"
end

--- WRITE THROUGH one turn's ignored operations, in path order.
---
--- The bytes come from the overlay upper layer -- the same and only source the
--- review surface reads -- and are written to the real path with no
--- transformation and no accept-time recheck, because there is no review and
--- therefore no evidence to recheck against. This is the whole of "untouched".
---
--- Fails on the FIRST error and says which path, rather than writing some of a
--- turn's ignored paths and reporting success: a partial write-through is a
--- workspace nobody has a complete account of.
---
--- @param entries table list of { rel, kind, detail, real_path, upper_path }
--- @return table|nil written rels, string|nil err
function M.write_through(entries)
	local diff = require("yana.diff")
	local written = {}
	for _, entry in ipairs(entries or {}) do
		local real = entry.real_path
		local upper = entry.upper_path
		if type(real) ~= "string" or real == "" then
			return nil, "ignored path has no real destination: " .. tostring(entry.rel)
		end
		local parent = vim.fn.fnamemodify(real, ":h")
		if vim.fn.isdirectory(parent) ~= 1 and vim.fn.mkdir(parent, "p") ~= 1 then
			return nil, "cannot create the directory for the ignored path " .. tostring(entry.rel)
		end
		if entry.detail == "dir" then
			if vim.fn.isdirectory(real) ~= 1 and vim.fn.mkdir(real, "p") ~= 1 then
				return nil, "cannot create the ignored directory " .. tostring(entry.rel)
			end
		else
			if type(upper) ~= "string" or vim.fn.filereadable(upper) ~= 1 then
				return nil, "the private layer holds no bytes for the ignored path " .. tostring(entry.rel)
			end
			local bytes = diff.read_file_bytes(upper)
			if bytes == nil then
				return nil, "cannot read the private layer copy of the ignored path " .. tostring(entry.rel)
			end
			local ok_write, werr = pcall(diff.write_file, real, bytes)
			if not ok_write then
				return nil, "cannot write the ignored path " .. tostring(entry.rel) .. ": " .. tostring(werr)
			end
			-- The agent's mode travels with the bytes: an ignored `chmod +x` on a
			-- hook script the operator asked never to review would otherwise land
			-- as a non-executable file.
			local st = uv.fs_stat(upper)
			if st and st.mode then
				pcall(uv.fs_chmod, real, st.mode % 0x1000)
			end
		end
		written[#written + 1] = entry.rel
	end
	return written
end

return M
