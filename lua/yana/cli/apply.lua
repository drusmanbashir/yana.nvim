-- yana-apply — CLI entry for safety/diary.lua. No write logic here.
io.stdout:setvbuf("no")

local src = debug.getinfo(1, "S").source:sub(2)
local repo = src:gsub("/lua/yana/cli/apply%.lua$", "")
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path

if #vim.api.nvim_list_uis() ~= 0 then
	io.stderr:write("yana-apply: must run headless with --clean (editor UI detected)\n")
	os.exit(66)
end

local diff = require("yana.diff")
local diary = require("yana.safety.diary")
local manifest = require("yana.manifest")
local control_plane = require("yana.safety.control_plane")
local shadow_ops = require("yana.shadow.ops")
local uv = vim.uv or vim.loop
local EXIT_USAGE = 64
local EXIT_REFUSE = 65

local function die_usage(msg)
	io.stderr:write("yana-apply: " .. msg .. "\n")
	os.exit(EXIT_USAGE)
end

-- The before-fingerprints for this change set's touched paths, written beside
-- the staged content by `yana-turn finish`. There is no `--base-manifest`
-- any more: a whole-tree hash file was O(repo) per turn, and every entry in it
-- except the touched ones was never read.
local BASE_HASHES = ".yana-base-hashes"
local BASE_EVIDENCE = ".yana-base-evidence"

local function read_base_hashes(changes_dir)
	local path = changes_dir .. "/" .. BASE_HASHES
	if vim.fn.filereadable(path) ~= 1 then
		die_usage("change set has no " .. BASE_HASHES .. ": " .. changes_dir)
	end
	local map, err = manifest.read_file(path)
	if not map then
		die_usage(err)
	end
	return map
end

local function read_base_evidence(changes_dir)
	local path = changes_dir .. "/" .. BASE_EVIDENCE
	if vim.fn.filereadable(path) ~= 1 then
		die_usage("change set has no " .. BASE_EVIDENCE .. ": " .. changes_dir)
	end
	local map, err = manifest.read_base_evidence(path)
	if not map then
		die_usage(err)
	end
	return map
end

--- Which mode does the applier install for one accepted path?
---
--- The change set's staged copy is NOT the answer, and reading it was the
--- defect: the producer wrote that copy itself, so its mode is the producer
--- process's umask, and accepting a content-only edit of a 0755 script
--- installed 0664 — a mode change nobody proposed, reviewed or journaled, on
--- the one operation that is destructive without touching a byte.
---
--- Three provenances, in order:
---   1. A DELIBERATE mode decision. The producer records the after-mode on the
---      operation's evidence when the mode itself changed (`new-mode` in
---      `bin/yana-changeset`), which is what makes `chmod+modify` one
---      reviewed compound operation. When the evidence carries it, it wins:
---      pinning the old mode unconditionally would silently drop the chmod
---      half of the compound, which `the filesystem operations contract`
---      forbids as half-acceptance. NOT YET WIRED END TO END: the producer
---      emits `new-mode`, but `cli/turn.lua`'s `evidence_from_op` drops it
---      when it builds the evidence row, so no change set carries
---      `after_mode` today. The consumer is here and correct; the carrier is
---      one field in the producer away, and until it lands a chmod cannot
---      reach disk through this door at all — which is honest, where reading
---      the staged copy's umask was a mode change on every accept.
---   2. A CREATE has no target to inherit from, so the staged copy remains the
---      only provenance there.
---   3. Otherwise the mode is the TARGET's, and the authority is the target on
---      real disk, NOT `base_mode` from the prep-time evidence. `the fixed safety contract`
---      requires object identity AND content at the last instant before the
---      write, and `base_mode` is a prep-time observation of a value the
---      applier is about to re-read anyway: `state_matches` in
---      `safety/diary.lua` compares mode as well as type, target and content,
---      so a human chmod between preparation and accept is a named STALE
---      refusal, not something either mode source could overwrite. Returning
---      nil hands the decision to the journaled applier, which stats the
---      target immediately before installing the temp, so the read and the
---      write share one instant and no second source can disagree with the
---      staleness check that just ran.
local function mode_for_apply(ev, change_path)
	local declared = ev.after_mode
	if type(declared) == "number" then
		return declared
	end
	if ev.base_state == "absent" then
		local st = uv.fs_stat(change_path)
		return st and st.mode or nil
	end
	return nil
end

--- What the accept is about to do to the mode, said out loud.
---
--- The CLI door used to print `applied tool.sh` whether or not the accept also
--- re-moded the file, so an operator could watch 0755 become 0664 with nothing
--- naming it. The inline door already discloses its mode change; this is that
--- parity. It is disclosure, NOT a veto: a `chmod+modify` is one decision and
--- the mode travels with the bytes, which is the contract
--- `the filesystem operations contract` states and this does not touch.
--- The product cannot separate a deliberate chmod from a umask artifact left
--- by an agent that replaced the file rather than rewriting it, so it reports
--- what it observed instead of guessing which one it was. Nothing is appended
--- when no mode change is in the operation, so a content-only accept still
--- prints exactly `applied <rel>`.
local function mode_note(ev, target_mode)
	if type(target_mode) ~= "number" or type(ev.base_mode) ~= "number" then
		return ""
	end
	local before, after = ev.base_mode % 4096, target_mode % 4096
	if before == after then
		return ""
	end
	return string.format(" (mode %o → %o)", before, after)
end

local function collect_relpaths(root)
	local staged = root .. "/.yana-staged-files"
	if vim.fn.filereadable(staged) == 1 then
		local rels, err = manifest.read_staged_list(staged)
		if not rels then
			die_usage("invalid staged file list: " .. tostring(err))
		end
		return rels
	end
	local out = {}
	local function walk(prefix)
		local dir = prefix == "" and root or (root .. "/" .. prefix)
		for _, name in ipairs(vim.fn.readdir(dir) or {}) do
			if name ~= "." and name ~= ".." then
				local rel = prefix == "" and name or (prefix .. "/" .. name)
				local full = root .. "/" .. rel
				if vim.fn.isdirectory(full) == 1 then
					walk(rel)
				elseif vim.fn.filereadable(full) == 1 then
					if name:match("^%.yana%-") then
						goto continue_walk
					end
					out[#out + 1] = rel
				end
				::continue_walk::
			end
		end
	end
	walk("")
	table.sort(out)
	return out
end

local function contains_nul(bytes)
	return type(bytes) == "string" and bytes:find("\0", 1, true) ~= nil
end

local function read_file(path)
	local content, err = diff.read_file_bytes(path)
	if content == nil and vim.fn.filereadable(path) ~= 1 then
		return "", nil
	end
	return content, err
end

local function parse_flag(args, i, name)
	if args[i] == name then
		if not args[i + 1] then
			die_usage(name .. " requires a value")
		end
		return args[i + 1], i + 2
	end
	return nil, i
end

local function cmd_apply(args)
	local changes_dir, target_dir, diary_dir, stream = nil, nil, nil, "default"
	local i = 1
	while i <= #args do
		local v
		v, i = parse_flag(args, i, "--changes")
		if v then
			changes_dir = v
		else
			v, i = parse_flag(args, i, "--target")
			if v then
				target_dir = v
			else
				v, i = parse_flag(args, i, "--diary")
				if v then
					diary_dir = v
				else
					v, i = parse_flag(args, i, "--stream")
					if v then
						stream = v
					else
						die_usage("unknown argument: " .. tostring(args[i]))
					end
				end
			end
		end
	end
	if not changes_dir or not target_dir or not diary_dir then
		die_usage("--changes, --target, and --diary are required")
	end

	changes_dir = diff.abs_path(changes_dir)
	target_dir = diff.abs_path(target_dir)
	diary_dir = diff.abs_path(diary_dir)

	local base_map = read_base_hashes(changes_dir)
	local evidence_map = read_base_evidence(changes_dir)
	local rels = collect_relpaths(changes_dir)
	-- `--diary` is operator-supplied, so a SECOND run against a directory that
	-- already holds a journal is reachable — it is what re-running after a
	-- partial refusal looks like. `diary.begin` on such a directory appends a
	-- second `begin` row and restarts `op_seq` at 0, so the new session issues
	-- op ids the finished one already used. The symptom is not an error: the
	-- reused id is already `done`, so `apply_pending` answers "no pending intent
	-- for path" and the operation is NEITHER APPLIED NOR REFUSED BY NAME, while
	-- `displaced/<seq>.bin` is keyed on that same seq and would be overwritten
	-- by whichever writer got there second. `diary.open` is the entry for an
	-- existing journal: it reconstructs `op_seq` from the rows so ids continue.
	local session, serr
	if vim.fn.filereadable(diary_dir .. "/journal.jsonl") == 1 then
		session, serr = diary.open(diary_dir)
		if session and diff.abs_path(session.workspace) ~= target_dir then
			io.stderr:write(
				"yana-apply: this diary already journals "
					.. tostring(session.workspace)
					.. "; refusing to continue it against "
					.. target_dir
					.. "\n"
			)
			os.exit(EXIT_REFUSE)
		end
	else
		session, serr = diary.begin({
			workspace = target_dir,
			stream = stream,
			diary_dir = diary_dir,
		})
	end
	if not session then
		io.stderr:write("yana-apply: " .. tostring(serr) .. "\n")
		os.exit(EXIT_REFUSE)
	end

	local any_refused = false
	local planned = {}
	local cp_typed = {}
	for _, rel in ipairs(rels) do
		local change_path = changes_dir .. "/" .. rel
		local target_path = target_dir .. "/" .. rel
		local ok_rel, rel_err = manifest.validate_rel(rel)
		if not ok_rel then
			io.stdout:write("refused " .. rel .. ": " .. tostring(rel_err) .. "\n")
			any_refused = true
		elseif control_plane.is_control_plane(rel) then
			-- Diagnostic guard at the CLI boundary:
			-- an early, clearly-named refusal. It is NOT the sole enforcement —
			-- diary.intent → resolve_target refuses independently below — but a
			-- forged staged list naming `.git/config` should say so here first.
			io.stdout:write("refused " .. tostring(control_plane.refusal(rel)) .. "\n")
			cp_typed[#cp_typed + 1] = { control_plane = true, rel = rel }
			any_refused = true
		elseif vim.fn.filereadable(change_path) ~= 1 then
			io.stdout:write("refused " .. rel .. ": missing staged content\n")
			any_refused = true
		else
		local content, rerr = read_file(change_path)
		if content == nil then
			io.stdout:write("refused " .. rel .. ": " .. tostring(rerr) .. "\n")
			any_refused = true
		else
			local before_bytes = nil
			if vim.fn.filereadable(target_path) == 1 then
				before_bytes = select(1, read_file(target_path))
			end
			if contains_nul(content) or contains_nul(before_bytes) then
				io.stdout:write("refused " .. rel .. ": binary_content — both versions kept\n")
				any_refused = true
				goto continue_rel
			end
			-- Absence is a producer defect, not an agent-created file. The change
			-- set records one fingerprint per touched path, including the empty
			-- one for a path that did not exist; a missing entry means the
			-- before-state was never examined, and defaulting it to the empty
			-- hash would authorise overwriting a file nothing has read.
			local base_hash = base_map[rel]
			if base_hash == nil then
				io.stdout:write("refused " .. rel .. ": no before-fingerprint in the change set\n")
				any_refused = true
				goto continue_rel
			end
			-- The tagged prep-time record. `read_base_evidence` has already
			-- refused anything incomplete, so what is left is to prove the two
			-- files in the change set describe the SAME observation: a
			-- fingerprint and a state that disagree are two looks at the path,
			-- and only one of them can be the one the change was prepared
			-- against.
			local ev = evidence_map[rel]
			if not ev then
				io.stdout:write("refused " .. rel .. ": no base evidence in the change set\n")
				any_refused = true
				goto continue_rel
			end
			if ev.hash ~= base_hash then
				io.stdout:write(
					"refused " .. rel .. ": the change set's before-fingerprint and its base evidence disagree\n"
				)
				any_refused = true
				goto continue_rel
			end
			local target_mode = mode_for_apply(ev, change_path)
			local ok, err = diary.intent({
				session = session,
				path = target_path,
				target = content,
				base_hash = base_hash,
				base_state = ev.base_state,
				base_mode = ev.base_mode,
				base_link_target = ev.base_link_target,
				target_mode = target_mode,
				record_only = true,
			})
			if not ok then
				io.stdout:write("refused " .. rel .. ": " .. tostring(err) .. "\n")
				any_refused = true
			else
				planned[#planned + 1] = { rel = rel, path = target_path, mode_note = mode_note(ev, target_mode) }
			end
		end
		end
		::continue_rel::
	end

	if #cp_typed > 0 then
		shadow_ops.record_control_plane_refusals(shadow_ops.control_plane_warn_scope({
			workspace = target_dir,
			stream = stream,
			turn_id = session.created_at,
		}, { recorder = "cli-apply" }), cp_typed)
	end

	for _, op in ipairs(planned) do
		local ok, err = diary.apply_pending({ session = session, path = op.path })
		if ok then
			io.stdout:write("applied " .. op.rel .. (op.mode_note or "") .. "\n")
		else
			io.stdout:write("refused " .. op.rel .. ": " .. tostring(err) .. "\n")
			any_refused = true
		end
	end

	if any_refused then
		os.exit(EXIT_REFUSE)
	end
	os.exit(0)
end

local function cmd_status(args)
	local diary_dir
	if args[1] ~= "--diary" or not args[2] then
		die_usage("status requires --diary DIR")
	end
	diary_dir = diff.abs_path(args[2])
	local session, err = diary.open(diary_dir)
	if not session then
		io.stderr:write("yana-apply: " .. tostring(err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	local summary = diary.status_summary(session)
	for op_id, info in pairs(summary.states) do
		io.stdout:write(string.format("%s %s %s\n", op_id, info.state, info.rel))
	end
	io.stdout:write(
		string.format(
			"%d done, %d pending, %d refused of %d\n",
			summary.done,
			summary.pending,
			summary.refused,
			summary.total
		)
	)
	os.exit(0)
end

local function cmd_replay(args)
	local diary_dir, do_apply = nil, false
	local i = 1
	while i <= #args do
		if args[i] == "--diary" then
			if not args[i + 1] then
				die_usage("--diary requires DIR")
			end
			diary_dir = diff.abs_path(args[i + 1])
			i = i + 2
		elseif args[i] == "--apply" then
			do_apply = true
			i = i + 1
		else
			die_usage("unknown argument: " .. tostring(args[i]))
		end
	end
	if not diary_dir then
		die_usage("replay requires --diary DIR")
	end
	local session, err = diary.open(diary_dir)
	if not session then
		io.stderr:write("yana-apply: " .. tostring(err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	local result = diary.replay({ session = session, apply_pending = do_apply })
	for _, path in ipairs(result.swept or {}) do
		io.stdout:write("swept orphan " .. path .. "\n")
	end
	for _, ref in ipairs(result.sweep_refused or {}) do
		io.stdout:write(
			string.format(
				"refused sweep %s (%s): %s\n",
				tostring(ref.path or "?"),
				tostring(ref.op_id or "?"),
				tostring(ref.reason or "identity mismatch")
			)
		)
	end
	for _, op in ipairs(result.conflicts or {}) do
		io.stdout:write("conflict " .. vim.fn.fnamemodify(op.path, ":.") .. "\n")
	end
	for _, op in ipairs(result.reverts or {}) do
		io.stdout:write("reverted " .. vim.fn.fnamemodify(op.path, ":.") .. "\n")
	end
	-- An accept whose verification failed and whose rollback recovery finished.
	-- It is neither applied nor pending, and it is never retried, so it has to be
	-- said out loud: silence here reads as "nothing happened to this file", and
	-- what happened is that the applier undid its own write.
	for _, op in ipairs(result.rollbacks or {}) do
		io.stdout:write(
			"rolled back "
				.. vim.fn.fnamemodify(op.path, ":.")
				.. " (its accept failed verification; the pre-accept version was restored)\n"
		)
	end
	for _, fail in ipairs(result.failures or {}) do
		local rel = fail.path and vim.fn.fnamemodify(fail.path, ":.") or "?"
		io.stdout:write(string.format("failure %s %s: %s\n", tostring(fail.op_id or "?"), rel, tostring(fail.error)))
	end
	io.stdout:write(string.format("replay %d/%d done\n", result.done, result.total))
	if (result.reverted or 0) > 0 then
		io.stdout:write(string.format("replay %d reverted\n", result.reverted))
	end
	if (result.rolled_back or 0) > 0 then
		io.stdout:write(string.format("replay %d rolled back\n", result.rolled_back))
	end
	if #(result.conflicts or {}) > 0 then
		os.exit(EXIT_REFUSE)
	end
	if #(result.failures or {}) > 0 then
		os.exit(EXIT_REFUSE)
	end
	if #(result.sweep_refused or {}) > 0 then
		os.exit(EXIT_REFUSE)
	end
	-- A finished revert is a settled frontier, not an unapplied one: the accept it
	-- undid is gone by the human's own decision, so it counts as resolved.
	if do_apply and (result.done + (result.reverted or 0)) < result.total then
		os.exit(EXIT_REFUSE)
	end
	os.exit(0)
end

local function cmd_recover(args)
	local diary_dir, op_id, out_path, list = nil, nil, nil, false
	local i = 1
	while i <= #args do
		if args[i] == "--diary" then
			diary_dir = diff.abs_path(args[i + 1])
			i = i + 2
		elseif args[i] == "--op" then
			op_id = args[i + 1]
			i = i + 2
		elseif args[i] == "--out" then
			out_path = args[i + 1]
			i = i + 2
		elseif args[i] == "--list" then
			list = true
			i = i + 1
		else
			die_usage("unknown argument: " .. tostring(args[i]))
		end
	end
	if not diary_dir then
		die_usage("recover requires --diary DIR")
	end
	local session, err = diary.open(diary_dir)
	if not session then
		io.stderr:write("yana-apply: " .. tostring(err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	if list then
		for _, row in ipairs(diary.list_displaced(session)) do
			io.stdout:write(
				string.format(
					"%s %s %s %s %s\n",
					row.op_id,
					vim.fn.fnamemodify(row.path, ":."),
					row.displaced_hash,
					tostring(row.bytes or 0),
					row.displaced_path
				)
			)
		end
		os.exit(0)
	end
	if not op_id or not out_path then
		die_usage("recover requires --op ID --out FILE (or --list)")
	end
	local ok, rerr = diary.recover_displaced(session, op_id, out_path)
	if not ok then
		io.stderr:write("yana-apply: " .. tostring(rerr) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	os.exit(0)
end

local function cmd_clear_sweep_refused(args)
	local diary_dir, op_id = nil, nil
	local i = 1
	while i <= #args do
		if args[i] == "--diary" then
			if not args[i + 1] then
				die_usage("--diary requires DIR")
			end
			diary_dir = diff.abs_path(args[i + 1])
			i = i + 2
		elseif args[i] == "--op" then
			if not args[i + 1] then
				die_usage("--op requires ID")
			end
			op_id = args[i + 1]
			i = i + 2
		else
			die_usage("unknown argument: " .. tostring(args[i]))
		end
	end
	if not diary_dir or not op_id then
		die_usage("clear-sweep-refused requires --diary DIR --op ID")
	end
	local session, err = diary.open(diary_dir)
	if not session then
		io.stderr:write("yana-apply: " .. tostring(err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	local ok, cerr = diary.clear_sweep_refused(session, op_id)
	if not ok then
		io.stderr:write("yana-apply: " .. tostring(cerr) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	io.stdout:write("cleared sweep refusal for " .. op_id .. "\n")
	os.exit(0)
end

local function cmd_revert(args)
	local diary_dir, op_id = nil, nil
	local i = 1
	while i <= #args do
		if args[i] == "--diary" then
			if not args[i + 1] then
				die_usage("--diary requires DIR")
			end
			diary_dir = diff.abs_path(args[i + 1])
			i = i + 2
		elseif args[i] == "--op" then
			if not args[i + 1] then
				die_usage("--op requires ID")
			end
			op_id = args[i + 1]
			i = i + 2
		else
			die_usage("unknown argument: " .. tostring(args[i]))
		end
	end
	if not diary_dir then
		die_usage("revert requires --diary DIR")
	end
	local session, err = diary.open(diary_dir)
	if not session then
		io.stderr:write("yana-apply: " .. tostring(err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	local ok, rerr, n = diary.revert_operation({ session = session, op_id = op_id })
	if not ok then
		io.stderr:write("yana-apply: " .. tostring(rerr) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	io.stdout:write(string.format("reverted %d operation(s)\n", n or 0))
	os.exit(0)
end

local function script_args()
	local argv = vim.v.argv
	for i, v in ipairs(argv) do
		if v:match("/yana/cli/apply%.lua$") then
			local out = {}
			for j = i + 1, #argv do
				out[#out + 1] = argv[j]
			end
			return out
		end
	end
	return {}
end

local args = script_args()
if #args == 0 then
	die_usage("subcommand required (apply|status|replay|recover|revert|clear-sweep-refused)")
end

local sub = args[1]
table.remove(args, 1)
if sub == "apply" then
	cmd_apply(args)
elseif sub == "status" then
	cmd_status(args)
elseif sub == "replay" then
	cmd_replay(args)
elseif sub == "recover" then
	cmd_recover(args)
elseif sub == "revert" then
	cmd_revert(args)
elseif sub == "clear-sweep-refused" then
	cmd_clear_sweep_refused(args)
else
	die_usage("unknown subcommand: " .. tostring(sub))
end
