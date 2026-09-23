----------------------------------------------------------------------
-- confinement refusals: a write the jail refused, kept as evidence
----------------------------------------------------------------------
--
-- The jail binds ONLY the claimed workspace writable. That refusal is correct.
--
-- This module is the one place in the editor process that holds the
-- confinement's OWN result for a command yana launched into it: the exit
-- status, and the failing process's `strerror`. `run_overlay_shell` records
-- that here; `ui.lua`'s turn-completion path forwards it into the same
-- `system_refused` machinery every other refusal already uses.
--
-- Split out of shadow/jail.lua. `run_overlay_shell` reaches back into
-- jail.lua for `wrap_cmd` with a lazy require
-- (jail.lua requires this module at load time to build its facade, so a
-- top-level require back here would be a cycle).
local M = {}

local diff = require("yana.diff")
local path_key = require("yana.paths.path_key")

--- Why the write died, in the product's voice.
M.OUT_OF_WORKSPACE_REASON = "the path is outside the claimed workspace, which yana confines by design"

--- What the operator can do about it TODAY. THE SINGLE PLACE this is written.
---
--- Every surface that shows a refused write (panel note, `:YanaRefusals` row, ledger
--- decision, the durable WARN) reads its remedy from here, so operator-declared write
--- roots landed as ONE new entry in this list rather than as four drifting copies of a
--- sentence. Nothing is promised here that does not exist today: `write_roots` ships
--- (`lua/yana/config.lua` and the external-roots module doc), and the other two lines
--- are what they always were.
---
--- The first entry carries a `<dir>` placeholder because the actionable
--- remedy names a REAL directory, and which directory that is can only be
--- known per refusal. `out_of_workspace_remedy` fills it from filesystem
--- state; when nothing can be derived the entry is dropped rather than
--- printed with a placeholder in it, which leaves exactly the two-line
--- message this list carried before.
M.WRITE_ROOT_REMEDY = 1
M.OUT_OF_WORKSPACE_REMEDIES = {
	'declare it in your yana setup: write_roots = { "<dir>" }',
	"run the turn from that repository",
	"or ask for the change as a patch and apply it there yourself",
}

--- The directory the operator would actually declare to make this write legal.
---
--- DERIVED FROM THE FILESYSTEM, NEVER FROM TEXT. With no repository above it the answer
--- is the containing directory, which is the smallest root that would have allowed the
--- write. Nothing the agent said can reach this decision, which is the cardinal
--- principle applied to a REMEDY as well as to a boundary: the sentence is only a
--- suggestion, but a suggestion assembled out of agent text is how scope creep starts.
---
--- Returns nil rather than "/" or an empty string: a remedy that proposes the
--- filesystem root is not a remedy.
function M.declarable_write_root(path)
	if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" then
		return nil
	end
	local dir = path
	if vim.fn.isdirectory(dir) ~= 1 then
		dir = vim.fn.fnamemodify(dir, ":h")
	end
	local probe, depth = dir, 0
	while probe and probe ~= "" and probe ~= "/" and depth < 64 do
		-- `.git` is a directory in a normal clone and a FILE in a worktree or a
		-- submodule; both mean "this is the repository root".
		if vim.fn.isdirectory(probe .. "/.git") == 1 or vim.fn.filereadable(probe .. "/.git") == 1 then
			return probe
		end
		probe = vim.fn.fnamemodify(probe, ":h")
		depth = depth + 1
	end
	if dir == "" or dir == "/" or vim.fn.isdirectory(dir) ~= 1 then
		return nil
	end
	return dir
end

--- The remedy sentence, specialised to the paths this refusal names.
---
--- Called with no argument it returns exactly the sentence it always returned,
--- so every caller that has not been taught about roots is unchanged.
function M.out_of_workspace_remedy(paths)
	local root
	for _, path in ipairs(paths or {}) do
		root = M.declarable_write_root(path)
		if root then
			break
		end
	end
	local lines = {}
	for i, line in ipairs(M.OUT_OF_WORKSPACE_REMEDIES) do
		if i == M.WRITE_ROOT_REMEDY then
			if root then
				lines[#lines + 1] = (line:gsub("<dir>", (root:gsub("%%", "%%%%"))))
			end
		else
			lines[#lines + 1] = line
		end
	end
	return "remedy: " .. table.concat(lines, ", ")
end

--- `strerror(EROFS)` as any libc renders it, and the errno's own symbol as the
--- runtimes that print symbols use it (node's `EROFS: read-only file system`).
---
--- THIS IS THE ONLY THING THAT MAY RAISE A REFUSAL RECORD. The selection is
--- the confinement's own errno, carried out of a process yana itself launched
--- into the jail — never the agent's event stream. `diff.tool_summary` prose
--- can neither create a record here nor suppress one.
local EROFS_TOKENS = { "read-only file system", "erofs" }

local MAX_REFUSALS_PER_TURN = 20
local MAX_PATHS_PER_REFUSAL = 8
local MAX_EVIDENCE = 200

--- The failure's own line, normalised for a one-line surface.
local function erofs_evidence(output)
	if type(output) ~= "string" or output == "" then
		return nil
	end
	for line in output:gmatch("[^\r\n]+") do
		local low = line:lower()
		for _, token in ipairs(EROFS_TOKENS) do
			if low:find(token, 1, true) then
				local clean = line:gsub("%c", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
				local attribution_text = clean
				if #clean > MAX_EVIDENCE then
					clean = clean:sub(1, MAX_EVIDENCE) .. "…"
				end
				return clean, attribution_text
			end
		end
	end
	return nil
end

-- Extract the write subject from common kernel-backed shell/runtime errors.
-- Fall back to the complete EROFS line, never to unrelated vendor narration.
local function refusal_subject_text(line)
	if type(line) ~= "string" then
		return ""
	end
	local path = line:match("cannot create%s+['\"]?(/[^%s'\"]+)")
		or line:match("['\"]?(/[^%s'\":]+)['\"]?:%s*[Rr]ead%-only file system")
		or line:match("[Rr]ead%-only file system:%s*['\"]?(/[^%s'\"]+)")
	if path then
		return path:gsub("[,:]+$", "")
	end
	return line
end

local function under(path, root)
	if not root or root == "" then
		return false
	end
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- Which absolute paths this refusal may NAME.
---
--- Candidates are read from the failure's own text (the confined process's
--- message first, then the command yana handed the jail), and every one of
--- them is then CHECKED against what yana knows for itself:
---
--- `/usr/bin/python3` appearing in a failing command is not a refused write, and naming
--- it would be a falsehood on an operator surface.
---
--- The last rule can under-name (a write to an existing executable file in a
--- sibling repo is not listed). That is the deliberate direction of the
--- trade: the refusal is still recorded and still carries its reason, remedy
--- and the confinement's own evidence line — only the path list is shorter.
--- Over-naming would put a write the turn never attempted on the record.
local function under_any(paths, roots)
	for _, path in ipairs(paths) do
		for _, root in ipairs(roots) do
			if under(path, root) then
				return true
			end
		end
	end
	return false
end

--- F-EROFS-REFUSAL. WHY this write landed outside every layer, in one class.
---
--- `CONFINEMENT.md` "Outside capture" fixes four. They are tested here
--- most-specific first because a path can satisfy several at once: a protected
--- path is also, trivially, unseeded.
---
--- READ FROM THE PLAN AND MOUNTINFO, NEVER FROM CONFIGURATION -- which is the
--- point of having a class at all. The refusal this replaces answered "declare
--- it in write_roots", i.e. it told the operator to widen the boundary in
--- response to hitting it. A class states what the kernel and the plan make
--- true, and three of the four name no remedy, because none exists.
---
--- Returns `class, remedy`; `remedy` is nil when there is none.
M.OUTSIDE_CAPTURE_CLASSES = { "protected", "mount-kind", "host-mount", "unseeded" }

function M.outside_capture_class(path, plan, mounts)
	if type(path) ~= "string" or path == "" then
		return nil
	end
	plan = plan or {}
	mounts = mounts or {}

	-- `protected`: yana's own state, or a layer's upper or work directory --
	-- the change set this turn is reviewed out of. Handing an agent its own
	-- evidence is the thing confinement exists to prevent, so: no remedy.
	for _, root in ipairs(plan.protected or {}) do
		if under(path, root) then
			return "protected", nil
		end
	end
	for _, layer in ipairs(plan.layers or {}) do
		if under(path, layer.upper) or under(path, layer.work) then
			return "protected", nil
		end
	end

	-- The mount the path sits on: longest matching mountpoint wins.
	local mount
	for _, entry in ipairs(mounts) do
		if under(path, entry.mountpoint) and (not mount or #entry.mountpoint > #mount.mountpoint) then
			mount = entry
		end
	end

	-- `mount-kind`: read-only, pseudo, tmpfs, overlay, squashfs or FUSE. No
	-- layer can be built on one, so no remedy.
	if mount then
		local blocked = { proc = true, sysfs = true, devtmpfs = true, devpts = true, tmpfs = true, overlay = true, squashfs = true, fuse = true, fuseblk = true }
		local writable = false
		for _, option in ipairs(vim.split(mount.options or "", ",", { trimempty = true })) do
			if option == "rw" then
				writable = true
			end
		end
		if blocked[mount.fstype] or not writable then
			return "mount-kind", nil
		end
	end

	-- `host-mount`: something is mounted strictly below the path's own
	-- directory, so no layer can contain the path -- an unprivileged mount
	-- namespace cannot clone a tree carrying locked child mounts. Kernel
	-- limit, no remedy.
	local parent = vim.fn.fnamemodify(path, ":h")
	for _, entry in ipairs(mounts) do
		if entry.mountpoint ~= parent and under(entry.mountpoint, parent) then
			return "host-mount", nil
		end
	end

	-- `unseeded`: an ordinary writable directory the turn's seeds never
	-- reached. The only class with a remedy, and it is an editor action rather
	-- than a configuration line.
	return "unseeded", "open a file there and resend"
end

local function root_list(...)
	local roots = {}
	-- `select("#", ...)` rather than `ipairs{...}`: a nil in the middle (a turn
	-- whose layer was already recovered away) must skip that root, not truncate
	-- the list and silently stop excluding the ones after it.
	for i = 1, select("#", ...) do
		local root = select(i, ...)
		if type(root) == "string" and root ~= "" then
			roots[#roots + 1] = root
		end
	end
	return roots
end

local function nameable_paths(texts, session)
	-- Both the resolved and the literal form of every root: a workspace reached
	-- through a symlink must still count as inside itself, or its own files
	-- would be named as "outside the claimed workspace".
	local ws = type(session.workspace) == "string" and session.workspace or ""
	local ws_roots = ws ~= "" and root_list(diff.abs_path(ws), vim.fs.normalize(ws)) or {}
	local machinery_roots = root_list(session.layer_dir, session.upper_dir, session.private_dir)
	local seen, out = {}, {}
	for _, text in ipairs(texts) do
		if type(text) == "string" then
			for token in text:gmatch("/[^%s'\"`,;:%(%)%[%]<>|]+") do
				local cand = token:gsub("[%.,;:%)%]]+$", "")
				if #out < MAX_PATHS_PER_REFUSAL and #cand > 1 and not seen[cand] then
					seen[cand] = true
					local forms = { cand, diff.abs_path(cand) }
					if
						not under_any(forms, ws_roots)
						and not under_any(forms, machinery_roots)
						and vim.fn.filewritable(vim.fn.fnamemodify(cand, ":h")) == 2
						and vim.fn.executable(cand) ~= 1
					then
						out[#out + 1] = cand
					end
				end
			end
		end
	end
	return out
end

--- Attach one refusal to the turn it happened in.
---
--- Kept on the session because the session IS the turn: `ui.lua`'s
--- `finalize_shadow_turn` already holds it, so the record needs no new channel
--- and no new lifetime. Created lazily and bounded, so a turn with no refused
--- write carries no field at all and behaves exactly as it did before.
local function record_confinement_refusal(session, cmd, output, code, opts)
	opts = type(opts) == "table" and opts or {}
	if
		type(session) ~= "table"
		or type(code) ~= "number"
		or code < 0
		or (code == 0 and opts.allow_zero ~= true)
	then
		return nil
	end
	local evidence, attribution_text = erofs_evidence(output)
	if not evidence then
		return nil
	end
	local rows = session.confinement_refusals
	if not rows then
		rows = {}
		session.confinement_refusals = rows
	end
	if #rows >= MAX_REFUSALS_PER_TURN then
		session.confinement_refusals_dropped = (session.confinement_refusals_dropped or 0) + 1
		return nil
	end
	local row = {
		turn = session.turn_id,
		workspace = diff.abs_path(session.workspace or ""),
		-- For the real vendor-job path, the command is the vendor executable,
		-- not the failed child command. Name only paths carried by the EROFS
		-- evidence and then checked against Yana-owned filesystem facts.
		paths = nameable_paths({ refusal_subject_text(attribution_text), cmd }, session),
		evidence = evidence,
		exit_code = code,
		source = opts.source or "yana_shell",
	}
	rows[#rows + 1] = row
	local ok_record, record = pcall(require, "yana.record")
	if ok_record and record.enabled() and type(session.private_dir) == "string" and session.private_dir ~= "" then
		if #row.paths > 0 then
			for _, path in ipairs(row.paths) do
				record.append_stream_line(session.private_dir, {
					type = "refusal",
					status = "system_refused",
					path = path,
					evidence = evidence,
					exit_code = code,
					source = row.source,
				})
			end
		else
			record.append_stream_line(session.private_dir, {
				type = "refusal",
				status = "system_refused",
				evidence = evidence,
				exit_code = code,
				source = row.source,
			})
		end
	end
	local ok_log, log = pcall(require, "yana.log")
	if ok_log and #row.paths > 0 then
		for _, path in ipairs(row.paths) do
			log.lifecycle("refusal.system_refused", {
				status = "system_refused",
				path = path,
				evidence = evidence,
				exit_code = code,
				turn_id = session.turn_id,
				source = row.source,
			})
		end
	end
	return row
end

-- Real vendor processes can complete the model turn successfully after one
-- child tool receives EROFS. This narrow entrypoint admits exit 0 only for the
-- raw process-stderr channel; record_confinement_refusal still requires an
-- EROFS token and independently validates every path it names.
function M.record_vendor_job_refusal(session, cmd, stderr, code)
	return record_confinement_refusal(session, cmd, stderr, code, {
		allow_zero = true,
		source = "vendor_job_stderr",
	})
end

local function log_jail_writes(session, cmd)
	if type(session) ~= "table" or type(cmd) ~= "string" or cmd == "" then
		return
	end
	local ok_record, record = pcall(require, "yana.record")
	if not ok_record or not record.enabled() then
		return
	end
	local private_dir = session.private_dir
	if not private_dir or private_dir == "" then
		return
	end
	for target in cmd:gmatch("[>]+%s*['\"]?([^'\"%s;|&]+)") do
		target = target:gsub("^['\"]", ""):gsub("['\"]$", "")
		if target ~= "" and not target:match("^%-") then
			record.append_stream_line(private_dir, {
				type = "tool_call",
				subtype = "completed",
				tool_call = { writeToolCall = { args = { path = target } } },
			})
		end
	end
end

--- Run one shell command inside this turn's overlay and wait for it.
---
--- Exactly the argv the editor spawns through `jobstart`, waited on instead —
--- so a caller that is not the job runner (a headless test, a recovery tool)
--- exercises the production confinement rather than a second, weaker one.
---
--- The `(ok, output, code)` triple is also the confinement's own account of a
--- write it refused. A failing command whose output carries `strerror(EROFS)`
--- leaves a record on the turn (see above) so the turn-completion path can
--- surface it. The triple itself is unchanged: recording is a side effect on
--- the session, never a change of return shape, and a command that did not
--- die read-only leaves nothing behind.
function M.consume_answer(session)
	local answer_path = session and session.yanad_answer_out
	if type(answer_path) ~= "string" or answer_path == "" or vim.fn.filereadable(answer_path) ~= 1 then
		return nil
	end
	local raw = table.concat(vim.fn.readfile(answer_path), "\n")
	local ok, answer = pcall(vim.json.decode, raw)
	if not ok or type(answer) ~= "table" then
		return nil
	end
	if type(answer.session_id) == "string" and answer.session_id ~= "" then
		session.yanad_session_id = answer.session_id
	end
	if answer.launch and type(answer.launch.layers) == "table" then
		local layers = answer.launch.layers
		local ws_layer = layers.workspace
		if type(ws_layer) == "string" and ws_layer ~= "" then
			session.layer_dir = ws_layer
			session.upper_dir = ws_layer .. "/upper"
			session.turn_dir = answer.launch.turn_dir or session.turn_dir
			if session.roots and session.roots[1] then
				session.roots[1].layer_dir = ws_layer
				session.roots[1].upper_dir = ws_layer .. "/upper"
				session.roots[1].work_dir = ws_layer .. "/work"
			end
		end
		local root_layers = layers.roots or {}
		if session.roots then
			for i = 2, #session.roots do
				local key = path_key.of(session.roots[i].workspace)
				local layer = root_layers[key]
				if type(layer) == "string" then
					session.roots[i].layer_dir = layer
					session.roots[i].upper_dir = layer .. "/upper"
					session.roots[i].work_dir = layer .. "/work"
				end
			end
		end
	end
	return answer
end

function M.run_overlay_shell(session, cmd)
	-- Lazy, not top-level: `jail.lua` requires this module to re-export
	-- `run_overlay_shell` under its own name, so a top-level require here
	-- back would be a load-time cycle. By the time this function actually
	-- runs, `jail.lua` has finished loading.
	local jail = require("yana.shadow.jail")
	local argv, env = jail.wrap_cmd({ "/bin/sh", "-c", cmd }, session)
	if not argv then
		return false, tostring(env), -1
	end
	local ok, result = pcall(function()
		return vim.system(argv, { text = true, env = env }):wait()
	end)
	if not ok then
		return false, tostring(result), -1
	end
	local output = (result.stderr or "") .. (result.stdout or "")
	-- refuse → render record first; launch → bind layer paths onto the session so
	-- walk/accept see daemon-minted dirs.
	local answer = M.consume_answer(session)
	if answer and answer.refuse then
		pcall(function()
			require("yana.runtime.yanad").render_refusal(result.stderr or output, answer)
		end)
	end
	-- Never let bookkeeping about a refusal change the outcome of the command
	-- it describes: fix-8's guarantee is that a surfaced refusal cannot wedge a
	-- turn, and that starts here.
	pcall(record_confinement_refusal, session, cmd, output, result.code)
	if result.code == 0 then
		pcall(log_jail_writes, session, cmd)
	end
	return result.code == 0, output, result.code
end

return M
