-- yana-turn — headless compose helper. No writes to the real workspace.
io.stdout:setvbuf("no")

local src = debug.getinfo(1, "S").source:sub(2)
local repo = src:gsub("/lua/yana/cli/turn%.lua$", "")
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path

if #vim.api.nvim_list_uis() ~= 0 then
	io.stderr:write("yana-turn: must run headless with --clean (editor UI detected)\n")
	os.exit(66)
end

local diff = require("yana.diff")
local manifest = require("yana.manifest")
local ops = require("yana.shadow.ops")

local EXIT_USAGE = 64
local EXIT_REFUSE = 65
local STAGED_LIST = ".yana-staged-files"
local STAGING_MARKER = ".yana-staging-incomplete"
-- Before-fingerprints for the TOUCHED paths only, written beside the staged
-- content so the change set is self-describing. This is what replaced
-- `--base-manifest`: same file format, but O(touched) records produced from the
-- lower layer during the walk, never a pass over the workspace. This file copies
-- the producer's records verbatim; it does not re-derive them.
local BASE_HASHES = ".yana-base-hashes"
local BASE_EVIDENCE = ".yana-base-evidence"

local function die_usage(msg)
	io.stderr:write("yana-turn: " .. msg .. "\n")
	os.exit(EXIT_USAGE)
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

local function parse_common(args)
	local workspace, upper, changes_out, json = nil, nil, nil, false
	local i = 1
	while i <= #args do
		local v
		v, i = parse_flag(args, i, "--workspace")
		if v then
			workspace = v
		else
			v, i = parse_flag(args, i, "--upper")
			if v then
				upper = v
			else
				v, i = parse_flag(args, i, "--changes-out")
				if v then
					changes_out = v
				elseif args[i] == "--json" then
					json = true
					i = i + 1
				else
					die_usage("unknown argument: " .. tostring(args[i]))
				end
			end
		end
	end
	if not workspace or not upper then
		die_usage("--workspace and --upper are required")
	end
	return {
		workspace = diff.abs_path(workspace),
		upper = diff.abs_path(upper),
		changes_out = changes_out and diff.abs_path(changes_out) or nil,
		json = json,
	}
end

local function load_ops(opts)
	return ops.typed_ops(opts.workspace, opts.upper)
end

--- The before-fingerprint the producer recorded for one touched path.
---
--- It is read out of the operation, never re-derived here. `yana-changeset`
--- reads the lower layer once, to decide the path changed at all, and emits the
--- fingerprint of exactly those bytes; on a content operation that value arrives
--- as the record's trailing field. Reading the lower layer a second time at this
--- point would open a window for a human save to land between classification and
--- evidence, so the accept-time recheck would compare the agent's result against
--- the human's new bytes, match, and overwrite the save that CORE requires be
--- refused by name.
---
--- Missing or malformed evidence refuses. Incomplete base evidence is a named
--- refusal in change-model, not something to fill in with a fresh read.
local function staged_fingerprint(op)
	local fp = op.extra
	if type(fp) ~= "string" or #fp ~= 64 or not fp:match("^%x+$") then
		return nil, "producer emitted no before-fingerprint for this operation"
	end
	return fp
end

--- The producer's before-EVIDENCE for one touched path, read out of the record.
---
--- The same rule as the fingerprint, for the same reason. State, type, mode and
--- symlink target were observed by the read that classified the operation, and
--- they travel on the record; observing the workspace again here would put a
--- window between classification and evidence, and a file created in that window
--- is recorded as the before-state of a change that was prepared against its
--- absence. Absence and an empty file share a fingerprint, so the accept-time
--- recheck matches and the human's new file is overwritten — the exact failure
--- the tag exists to prevent, with a smaller window rather than none.
---
--- Incomplete evidence refuses. A record with no tag, no mode where the state
--- has one, or a lower object that is not a regular file cannot be compared at
--- accept time, and the honest place to say so is before anything is staged.
local function evidence_from_op(op, fp)
	local ev = op.base_evidence
	if type(ev) ~= "table" or ev.state == nil then
		return nil, "the producer recorded no before-state for this operation"
	end
	if ev.state == "absent" then
		return { rel = op.rel, hash = fp, base_state = "absent" }
	end
	if ev.state == "file" or ev.state == "link" then
		local mode = tonumber(ev.mode or "", 8)
		if not mode then
			return nil, "the producer recorded a " .. ev.state .. " before-state with no mode"
		end
		if ev.state == "link" then
			if type(ev.target) ~= "string" or ev.target == "" then
				return nil, "the producer recorded a symlink before-state with no target"
			end
			return {
				rel = op.rel,
				hash = fp,
				base_state = "link",
				base_mode = mode,
				base_link_target = ev.target,
			}
		end
		-- The AFTER mode, when this operation is a `chmod+modify` compound.
		-- The producer decides that — it compares the two objects' modes in the
		-- one classifying pass and appends `new-mode` to the same record — and
		-- the value is carried here verbatim, never re-derived. Without it the
		-- change set records no mode decision at all, and the applier has
		-- nothing to distinguish a deliberate chmod from an accept that must
		-- leave the target's mode alone; `filesystem-operations.md` calls
		-- shipping the content half without the mode half a forbidden
		-- half-acceptance. A malformed value refuses rather than being dropped:
		-- a compound whose mode half cannot be read is not a modify.
		-- Parsed AND range-checked. `tonumber(x, 8)` accepts a leading sign and
		-- has no upper bound, so a negative or oversized value would travel to
		-- the applier as a mode and reach `fs_chmod`; permission bits are
		-- 0..07777 and anything else is a malformed record, not a decision.
		local after_mode = nil
		if ev["new-mode"] ~= nil then
			after_mode = tonumber(ev["new-mode"], 8)
			if
				not after_mode
				or after_mode ~= math.floor(after_mode)
				or after_mode < 0
				or after_mode > 4095
			then
				return nil, "the producer recorded an unreadable after-mode for this operation"
			end
		end
		return { rel = op.rel, hash = fp, base_state = "file", base_mode = mode, after_mode = after_mode }
	end
	return nil,
		"the real path is a "
			.. tostring(ev.kind or ev.state)
			.. ", not a regular file — refusing to stage a whole-file change over it"
end

local function stage_file(src, dst, rel)
	local ok_path, perr = manifest.validate_rel(rel)
	if not ok_path then
		return false, perr
	end
	local dir = vim.fn.fnamemodify(dst, ":h")
	vim.fn.mkdir(dir, "p")
	local content, err = diff.read_file_bytes(src)
	if content == nil then
		return false, err or ("missing shadow file: " .. src)
	end
	return diff.write_file(dst, content)
end

local function remove_tree(path)
	if vim.fn.isdirectory(path) == 1 then
		vim.fn.delete(path, "rf")
	elseif vim.fn.filereadable(path) == 1 then
		vim.fn.delete(path)
	end
end

local function cmd_finish(args)
	local opts = parse_common(args)
	if not opts.changes_out then
		die_usage("finish requires --changes-out DIR")
	end
	if vim.fn.isdirectory(opts.changes_out) == 1 then
		local existing = vim.fn.readdir(opts.changes_out) or {}
		for _, name in ipairs(existing) do
			if name ~= "." and name ~= ".." then
				die_usage("changes-out is not empty: " .. opts.changes_out)
			end
		end
	end

	local typed, err = load_ops(opts)
	if not typed then
		io.stderr:write("yana-turn: " .. tostring(err) .. "\n")
		os.exit(EXIT_REFUSE)
	end

	local staging = opts.changes_out .. ".staging-" .. tostring(vim.fn.localtime()) .. "-" .. tostring(math.random(100000, 999999))
	vim.fn.mkdir(staging, "p")
	local marker = staging .. "/" .. STAGING_MARKER
	local f = io.open(marker, "w")
	if not f then
		io.stderr:write("yana-turn: cannot create staging marker\n")
		os.exit(EXIT_REFUSE)
	end
	f:write("incomplete\n")
	f:close()

	local staged_rels = {}
	local base_entries = {}
	local evidence_rows = {}
	for _, op in ipairs(typed) do
		-- Only whole-file content operations are stageable. `mode`, `symlink`,
		-- `opaque` and directory creation are typed operations the producer
		-- reports and this payload has no representation for; they are listed
		-- in the report rather than silently dropped.
		if (op.kind == "create" or op.kind == "modify") and op.detail == "file" then
			local ok_path, perr = manifest.validate_rel(op.rel)
			if not ok_path then
				remove_tree(staging)
				io.stderr:write("yana-turn: invalid operation path " .. op.rel .. ": " .. tostring(perr) .. "\n")
				os.exit(EXIT_REFUSE)
			end
			-- Evidence first, and carried through untouched. It was taken by the
			-- producer's classifying read, so nothing below can move it, and a
			-- change set whose evidence is incomplete refuses before staging.
			local fp, ferr = staged_fingerprint(op)
			if not fp then
				remove_tree(staging)
				io.stderr:write("yana-turn: before-fingerprint missing for " .. op.rel .. ": " .. tostring(ferr) .. "\n")
				os.exit(EXIT_REFUSE)
			end
			-- The whole evidence record, off the operation, BEFORE anything is
			-- copied — one observation, taken by the producer, carried verbatim.
			local ev, everr = evidence_from_op(op, fp)
			if not ev then
				remove_tree(staging)
				io.stderr:write("yana-turn: base evidence failed for " .. op.rel .. ": " .. tostring(everr) .. "\n")
				os.exit(EXIT_REFUSE)
			end
			local src = opts.upper .. "/" .. op.rel
			local dst = staging .. "/" .. op.rel
			local ok, serr = stage_file(src, dst, op.rel)
			if not ok then
				remove_tree(staging)
				io.stderr:write("yana-turn: stage failed for " .. op.rel .. ": " .. tostring(serr) .. "\n")
				os.exit(EXIT_REFUSE)
			end
			staged_rels[#staged_rels + 1] = op.rel
			base_entries[#base_entries + 1] = { rel = op.rel, hash = fp }
			evidence_rows[#evidence_rows + 1] = ev
		end
	end

	if #staged_rels == 0 then
		remove_tree(staging)
		io.stderr:write("yana-turn: refusing finish with no stageable changes\n")
		os.exit(EXIT_REFUSE)
	end

	local ok_list, list_err = manifest.write_staged_list(staging .. "/" .. STAGED_LIST, staged_rels)
	if not ok_list then
		remove_tree(staging)
		io.stderr:write("yana-turn: staged list write failed: " .. tostring(list_err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	local ok_base, base_err = manifest.write_file(staging .. "/" .. BASE_HASHES, base_entries)
	if not ok_base then
		remove_tree(staging)
		io.stderr:write("yana-turn: before-fingerprint write failed: " .. tostring(base_err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	local ok_ev, ev_err = manifest.write_base_evidence(staging .. "/" .. BASE_EVIDENCE, evidence_rows)
	if not ok_ev then
		remove_tree(staging)
		io.stderr:write("yana-turn: base evidence write failed: " .. tostring(ev_err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	vim.fn.delete(marker)

	if vim.fn.isdirectory(opts.changes_out) ~= 1 then
		vim.fn.mkdir(opts.changes_out, "p")
	end
	for _, rel in ipairs(staged_rels) do
		local src = staging .. "/" .. rel
		local dst = opts.changes_out .. "/" .. rel
		local dir = vim.fn.fnamemodify(dst, ":h")
		vim.fn.mkdir(dir, "p")
		local content = diff.read_file_bytes(src)
		local wok, werr = diff.write_file(dst, content)
		if not wok then
			remove_tree(staging)
			io.stderr:write("yana-turn: publish failed for " .. rel .. ": " .. tostring(werr) .. "\n")
			os.exit(EXIT_REFUSE)
		end
	end
	local wbase_ok, wbase_err = manifest.write_file(opts.changes_out .. "/" .. BASE_HASHES, base_entries)
	if not wbase_ok then
		remove_tree(staging)
		io.stderr:write("yana-turn: publish before-fingerprints failed: " .. tostring(wbase_err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	local wev_ok, wev_err = manifest.write_base_evidence(opts.changes_out .. "/" .. BASE_EVIDENCE, evidence_rows)
	if not wev_ok then
		remove_tree(staging)
		io.stderr:write("yana-turn: publish base evidence failed: " .. tostring(wev_err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	local wlist_ok, wlist_err = manifest.write_staged_list(opts.changes_out .. "/" .. STAGED_LIST, staged_rels)
	remove_tree(staging)
	if not wlist_ok then
		io.stderr:write("yana-turn: publish staged list failed: " .. tostring(wlist_err) .. "\n")
		os.exit(EXIT_REFUSE)
	end

	if opts.json then
		io.stdout:write(vim.json.encode({ ops = typed }) .. "\n")
	else
		for _, line in ipairs(ops.format_lines(typed)) do
			io.stdout:write(line .. "\n")
		end
	end
	os.exit(0)
end

local function cmd_check_deletes(args)
	local opts = parse_common(args)
	local typed, err = load_ops(opts)
	if not typed then
		io.stderr:write("yana-turn: " .. tostring(err) .. "\n")
		os.exit(EXIT_REFUSE)
	end
	local any = false
	for _, op in ipairs(typed) do
		if op.kind == "delete" then
			io.stderr:write("yana-turn: refusing delete: " .. op.path .. "\n")
			any = true
		end
	end
	if any then
		os.exit(EXIT_REFUSE)
	end
	os.exit(0)
end

local function script_args()
	local argv = vim.v.argv
	for i, v in ipairs(argv) do
		if v:match("/yana/cli/turn%.lua$") then
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
	die_usage("subcommand required (finish|check-deletes)")
end

local sub = args[1]
table.remove(args, 1)
if sub == "finish" then
	cmd_finish(args)
elseif sub == "check-deletes" then
	cmd_check_deletes(args)
else
	die_usage("unknown subcommand: " .. tostring(sub))
end
