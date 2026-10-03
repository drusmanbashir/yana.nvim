-- turn/turn_cycle.lua -- the Turn's cycle owner (plan followup-addendum-turn.md "## Design" component table,
-- "### Reconciliation" steps 1-5, "### M0: history mapping" B5/B6/B7, run reconciliation and the S1 record
-- schema; panel rules F-ADDENDUM-TURN, -B0, -DECISIONS, -HISTORY-RUNNING, -RECOMPUTE, -FALLBACK).
-- A cycle is one agent run and its result. Held by the Turn (`Turn:cycles()`): run records, each holding its
-- turn_lifecycle pass (the run identity; no generation is minted here), the immutable CycleInput captured at
-- submit, the result record (the stopped run's effective view), and the Turn's cycle state. No second history
-- stack: positions are register EpRefs. `prepare_publication` derives the next review per file and installs
-- nothing (S3 commits it). Reading the world is turn_cycle_view.lua; the per-file derivation is
-- turn_cycle_reconcile.lua.
local view = require("yana.turn.turn_cycle_view")
local reconcile = require("yana.turn.turn_cycle_reconcile")
local settle_snapshot = require("yana.turn.turn_settle_snapshot")
local uv = vim.uv or vim.loop

local M = {}
local SCHEMA = 1

M.capture_input = view.capture_input
M.input_files = view.input_files
M.canonical_path = view.canonical_path

-- CycleState = reviewing | preparing | running | publishing | recovery_required.
local NEXT = {
	reviewing = { running = true, recovery_required = true },
	running = { preparing = true, reviewing = true, recovery_required = true },
	-- preparing -> preparing: newer edits invalidated a preparation; -> reviewing: it failed, result kept to retry.
	preparing = { preparing = true, publishing = true, reviewing = true, recovery_required = true },
	publishing = { reviewing = true, recovery_required = true },
	recovery_required = { reviewing = true },
}
local ACTIVE = { running = true, preparing = true, publishing = true }

-- Run records, keyed by the run's overlay session (one session per run): run-once flags live here, not on an
-- object that outlives one run. Weak keys, and a record never holds its session strongly, so it dies with it.
local runs = setmetatable({}, { __mode = "k" })

function M.run_of(session)
	assert(type(session) == "table", "turn_cycle.run_of: the run's overlay session is required")
	local run = runs[session]
	if run == nil then
		run = { schema_version = SCHEMA, turn_id = session.turn_id, flags = {}, held = {},
			session_ref = setmetatable({ s = session }, { __mode = "v" }) }
		runs[session] = run
	end
	return run
end

-- True the first time `flag` (e.g. "review_finalized") is asked for this run, false after.
function M.once(session, flag)
	local run = M.run_of(session)
	if run.flags[flag] then return false end
	run.flags[flag] = true
	return true
end

-- The run a cycle owner began on `session` and still awaits a result for, or nil (a first run: no owner began it).
function M.recording_run(session)
	local run = runs[session]
	if run and run.owner and run.result == nil then return run end
	return nil
end

----------------------------------------------------------------------
-- Step 3: the stopped run's effective private view
----------------------------------------------------------------------

local function upper_of(root)
	if root.upper_dir and root.upper_dir ~= "" then return root.upper_dir end
	if root.layer_dir and root.layer_dir ~= "" then return root.layer_dir .. "/upper" end
	return nil
end

-- The base the upper layer is keyed by: the broad root for the primary root, else the root's workspace (the
-- key the change-set walk uses, shadow/ops_decode.lua `walk_base`).
local function base_of(session, root)
	local primary = root.primary == true or (root.index or 1) == 1
	if primary and type(session.broad_root) == "string" and session.broad_root ~= "" then return session.broad_root end
	return root.workspace
end

local function whiteout(st)
	return st.type == "char" and st.rdev == 0
end

-- `opaque`: the producer's opaque directories (absolute paths), or nil when that evidence is missing.
local function observe(path, session, roots, artifacts, opaque)
	for _, root in ipairs(roots) do
		local base, upper = base_of(session, root), upper_of(root)
		if base and upper and path:sub(1, #base + 1) == base .. "/" then
			local rel, dir, real = path:sub(#base + 2), upper, base
			local parts = vim.split(rel, "/", { plain = true })
			local hidden, unproven = false, nil
			for i = 1, #parts - 1 do
				dir, real = dir .. "/" .. parts[i], real .. "/" .. parts[i]
				local st = uv.fs_lstat(dir)
				if st and st.type ~= "directory" then
					if whiteout(st) then return { exists = false, source = "whiteout" } end
					return { unreadable = "the private view holds a " .. st.type .. " over " .. dir }
				elseif st and opaque == nil then
					unproven = unproven or dir
				elseif st and opaque[real] then
					hidden = true
				end
			end
			local st = uv.fs_lstat(upper .. "/" .. rel)
			if st and st.type == "file" then
				local bytes = artifacts.read_tree_bytes(upper, rel)
				if bytes == nil then return { unreadable = "the private file is unreadable" } end
				return { exists = true, bytes = bytes, mode = st.mode % 4096, source = "upper" }
			elseif st and whiteout(st) then
				return { exists = false, source = "whiteout" }
			elseif st then
				return { unreadable = "the private view holds a " .. st.type .. " at " .. path }
			end
			-- An opaque upper directory hides every lower entry below it; unproven opacity is missing evidence.
			if hidden then return { exists = false, source = "opaque" } end
			if unproven then return { unreadable = "no opacity evidence for the private directory " .. unproven } end
			local lower, why = artifacts.lower_state(path)
			if not lower then return { unreadable = why } end
			if lower.kind == "absent" then return { exists = false, source = "lower" } end
			return { exists = true, bytes = lower.bytes, mode = lower.mode % 4096, source = "lower" }
		end
	end
	return { unreadable = "no overlay root of the run holds " .. path }
end

-- Per path, what the stopped run left (step 3): the upper entry (a file: bytes and mode; a whiteout over it or
-- an ancestor: absent), else the lower file (`ops_artifacts.lower_state`) unless an opaque upper ancestor hides
-- it; `unreadable` names evidence that could not be read. Upper absence alone is never file absence. Roots from
-- `ops_decode.session_roots`; opacity from the producer's own `opaque` records (`typed`, else the producer's
-- read of the session through `ops_decode.typed_ops_from_session`).
function M.read_run_view(session, paths, typed)
	local decode = require("yana.shadow.ops_decode")
	local roots = decode.session_roots(session)
	local artifacts = require("yana.shadow.ops_artifacts")
	if typed == nil then typed = decode.typed_ops_from_session(session) end
	local opaque = typed and {} or nil
	for _, op in ipairs(typed or {}) do
		if op.kind == "opaque" and op.path then opaque[op.path] = true end
	end
	local out = {}
	for _, path in ipairs(paths) do out[path] = observe(path, session, roots, artifacts, opaque) end
	return out
end

local Cycles = {}
Cycles.__index = Cycles

function M.new(turn)
	return setmetatable({ turn = turn, state = "reviewing", runs = {} }, Cycles)
end

function Cycles:set_state(to)
	assert(NEXT[to], "turn_cycle: unknown cycle state " .. tostring(to))
	if not NEXT[self.state][to] then
		return false, string.format("cycle state %s cannot become %s", self.state, to)
	end
	local from = self.state
	self.state = to
	require("yana.turn.turn_cycle_log").state(self, from, to)
	return true
end

function Cycles:next_cycle_id()
	return #self.runs + 1
end

function Cycles:current()
	return self.runs[#self.runs]
end

function Cycles:run(generation)
	for i = #self.runs, 1, -1 do
		if self.runs[i].run_generation == generation then return self.runs[i] end
	end
	return nil
end

local function same_turn(a, b)
	return a == nil or b == nil or tostring(a) == tostring(b)
end

-- Begin cycle k+1 on `session` under `pass` (turn_lifecycle's pass, held as the run identity; its generation
-- must be newer than the last run's) with the CycleInput captured for it. Refused while a run is active, for a
-- session that already began one, or for a pass/input of another run or Turn. The run that opened the Turn
-- (cycle 1) is adopted the same way once the Turn exists, with no input, then set back to "reviewing".
function Cycles:begin_run(session, pass, input)
	local run = M.run_of(session)
	if run.owner ~= nil then return nil, "this run's session already began a run" end
	if ACTIVE[self.state] or self.state == "recovery_required" then return nil, "the Turn's cycle is " .. self.state end
	if type(pass) ~= "table" or type(pass.generation) ~= "number" then return nil, "a run needs its lifecycle pass" end
	local last = self.runs[#self.runs]
	if last and type(last.run_generation) == "number" and pass.generation <= last.run_generation then
		return nil, "stale generation " .. tostring(pass.generation)
	end
	if not same_turn(pass.turn_id, run.turn_id) then return nil, "the pass belongs to another Turn" end
	local turn_id = run.turn_id or pass.turn_id or (input and input.turn_id)
	if turn_id == nil or not same_turn(self.turn_id, turn_id) then return nil, "the run belongs to another Turn" end
	if input and (input.run_generation ~= pass.generation or input.cycle_id ~= #self.runs + 1
		or not same_turn(input.turn_id, run.turn_id)) then
		return nil, "the input was captured for another run"
	end
	self.turn_id = self.turn_id or turn_id
	run.owner, run.cycle_id, run.pass, run.run_generation, run.input = self, #self.runs + 1, pass, pass.generation, input
	run.started_ns = uv.hrtime()
	self.runs[#self.runs + 1] = run
	assert(self:set_state("running")) -- after the run is recorded, so cycle.state carries its correlation
	return run
end

-- The run's result (step 3): per path of the input files and the change records, the stopped run's effective
-- private view (`opts.view`, else read through the run's session) with the change's classification. Only the
-- current running run moves the cycle to "preparing"; a late or foreign result is kept on its run without
-- touching the state.
function Cycles:record_result(run, changes, opts)
	opts = opts or {}
	if run.owner ~= self then return nil, "not a run of this Turn" end
	if run.result ~= nil then return run.result, "the result was already recorded" end
	local paths, classified = {}, {}
	for path in pairs(run.input and run.input.files or {}) do paths[#paths + 1] = path end
	for _, change in ipairs(changes or {}) do
		if type(change.path) == "string" then
			local path = view.canonical_path(change.path)
			if classified[path] == nil and not (run.input and run.input.files[path]) then paths[#paths + 1] = path end
			classified[path] = change
		end
	end
	table.sort(paths)
	local session = opts.session or run.session_ref.s
	local seen = opts.view or (session and M.read_run_view(session, paths, opts.typed)) or {}
	local files = {}
	for _, path in ipairs(paths) do
		local o = seen[path] or { unreadable = "the run's view was not read" }
		files[path] = { exists = o.exists, bytes = o.bytes, mode = o.mode, source = o.source, unreadable = o.unreadable,
			kind = classified[path] and classified[path].kind, change = classified[path] }
	end
	run.result = { schema_version = SCHEMA, turn_id = run.turn_id, cycle_id = run.cycle_id,
		result_id = string.format("result:%s:%s", tostring(run.turn_id), tostring(run.cycle_id)),
		run_generation = run.run_generation, input_id = run.input and run.input.input_id, files = files,
		stopped = opts.stopped == true }
	if run == self.runs[#self.runs] and self.state == "running" then
		self:set_state("preparing")
		return run.result
	end
	return run.result, "a late result is kept; the cycle state is unchanged"
end

-- B7 retention hook: pin every endpoint current for the run's input files (call on each register position
-- change while the run's input is held; preparation calls it too). `release` drops the input's marks and pins
-- once history mapping no longer needs them.
function Cycles:retain(run, register)
	if register and run.input then view.pin_current(register, run.input, run.held) end
end

function Cycles:release_run(run, register)
	if run.input then view.release_input(run.input, register, run.held) end
end

function Cycles:prepare_publication(run, current_view)
	assert(run and run.input and run.result, "turn_cycle.prepare_publication: the run has no input or result")
	self:retain(run, current_view and current_view.register)
	return M.prepare_publication(run.result, current_view, run.input)
end

----------------------------------------------------------------------
-- prepare_publication
----------------------------------------------------------------------

-- The evidence S3 revalidates before installing: position, buffer, bytes, decisions, operation and mode
-- verdicts, and the attachment.
local function against(cur, ep, live)
	local file, st = cur and cur.file, cur and cur.review_state
	local bufnr = live and cur.bufnr or nil
	return { ep = ep, bufnr = bufnr, tick = bufnr and vim.api.nvim_buf_get_changedtick(bufnr) or nil,
		seq = bufnr and require("yana.undo_action_followup_cycle").seq_of(bufnr) or nil,
		bytes_ref = bufnr and require("yana.diff").buffer_bytes_snapshot(bufnr) or nil,
		stamp = settle_snapshot.decision_stamp(file or cur or {}), operation_verdict = file and file.operation_verdict,
		mode_verdict = file and file.mode_verdict, attachment = st, watch_generation = st and st._watch_generation }
end

local function first_run_file(f, out)
	local change = out.change or {}
	local base = change.review_before
	if base == nil then base = change.before end
	if base == nil and change.kind == "create" then base = "" end
	if base == nil then return nil, "no base for the newly classified path" end
	f.mode, f.change = "first_run", out.change
	f.lines = out.exists and view.rows_of(out.bytes) or {}
	f.blocks = require("yana.review_open").fallback_blocks(base, out.exists and out.bytes or "")
	return f
end

-- Step 3-5 for one file through its B5 path: the identity, the live submit extmarks (forward edges in one
-- incarnation) or the composed recorded splices; else FALLBACK over the retained accepted/operator view.
local function tracked_result(input, path, rec, cur, rows_now, facts, edits, now, register, f)
	local p = view.history_path(register, rec.key, input.positions[path], now[rec.key], (input.splice_watermark[path] or {}).splices)
	f.path_type = p.kind
	local rows, why
	if p.kind == "same" or p.kind == "forward" or (p.kind == "revision" and p.steps == nil) then
		if cur.bufnr ~= rec.bufnr then return nil, "another buffer holds the file now" end
		rows = view.marked_rows(rec, input.ns)
		if not rows then return nil, "Neovim tracking of the input rows was lost (reload or whole-buffer replacement)" end
	elseif p.kind == "revision" or p.kind == "composed" then
		rows, why = reconcile.compose(#rec.lines, #rows_now, p.steps)
		if not rows then return nil, why end
	else
		return nil, "history path unknown: " .. tostring(p.reason)
	end
	local runs, runs_err = view.pending_runs(facts)
	if not runs then return nil, runs_err end
	local regions, transport_err = reconcile.transport(edits, rows, #rec.lines)
	if not regions then return nil, transport_err end
	return reconcile.tracked(rows_now, runs, regions)
end

-- `C` for FALLBACK: the current rows with pending runs taken back to their prior text; with no retained rows,
-- the input rows with every contribution not accepted now taken back.
local function fallback_base(rec, rows_now, facts, resolved)
	if rows_now then
		local runs, why = view.pending_runs(facts or {})
		if not runs then return nil, why end
		return view.comparison(rows_now, runs)
	end
	local back = {}
	for _, c in ipairs(resolved) do
		if c.verdict_now ~= "accepted" then back[#back + 1] = { a = c.first, b = c.last + 1, old = c.old } end
	end
	return view.comparison(rec.lines, back)
end

local function prepare_file(input, path, rec, out, cur, now, register)
	local f = { path = path, file_id = path, key = (rec and rec.key) or (cur and cur.key) or path,
		member = (rec and rec.member) or (cur ~= nil and cur.ledger ~= nil) or false }
	if out == nil or out.unreadable then
		return nil, "the run's view of this path is unreadable: " .. tostring(out and out.unreadable or "not observed")
	end
	f.exists, f.file_mode = out.exists, out.mode
	if rec == nil then return first_run_file(f, out) end
	f.eol = rec.eol
	local agent = out.exists and view.rows_of(out.bytes, rec.eol) or {}
	local edits = reconcile.edits(rec.lines, agent)
	local rows_now, live = view.current_rows(cur, rec.eol)
	local facts = cur and cur.ledger and view.facts(cur.ledger, rows_now or rec.lines) or nil
	if cur and cur.ledger and facts == nil then return nil, "the file's retained decisions are gone (its ledger closed)" end
	f.prepared_against = against(cur, now[f.key], live)
	if #edits == 0 and out.exists == (rec.existence ~= false) then
		-- The agent left this file: its current rows, members and decisions stand as they are.
		f.mode, f.lines, f.blocks = "unchanged", rows_now or rec.lines, {}
		return f
	end
	local result, reason
	if not live then
		reason = "the buffer captured at submit is gone"
	elseif out.exists == false then
		reason = "the agent deleted the file (typed operations across cycles: M3)"
	else
		result, reason = tracked_result(input, path, rec, cur, rows_now, facts, edits, now, register, f)
	end
	if result then
		f.mode = "tracked"
	else
		local resolved, accounted = view.resolve_contributions(rec.contributions, facts)
		local unplaced = view.unplaced_rejections(facts, accounted, rec.submit_members or {})
		for _, c in ipairs(resolved) do
			if #unplaced > 0 and c.unresolved and reconcile.untouched(c, edits) then
				return nil, string.format("FALLBACK cannot place rejection %s on the input contribution %s it may descend "
					.. "from (genealogy not recorded); refused rather than resurrected", table.concat(unplaced, ", "),
					tostring(c.unresolved))
			end
		end
		local base, base_err = fallback_base(rec, rows_now, facts, resolved)
		if base == nil then return nil, base_err end
		result = reconcile.fallback(base, agent, resolved, edits, reason, rows_now and #rows_now or #rec.lines)
		f.mode, f.reason = "fallback", reason
	end
	f.lines, f.blocks = result.lines, result.blocks
	f.lineage = { schema_version = SCHEMA, workspace_id = input.workspace_id, turn_id = input.turn_id,
		lineage_id = input.input_id .. ":" .. path, file_id = path, from_ep = now[f.key], segments = result.segments,
		coverage = result.coverage, failure = result.failure,
		valid_for = { tick = f.prepared_against.tick, bytes_ref = f.prepared_against.bytes_ref } }
	return f
end

-- PreparedPublication for one result (steps 3-5): per canonical path the next visible rows `lines`, the hunk
-- `blocks` (first-run shape), `mode` (tracked | fallback | unchanged | first_run) with its `reason`, the B5
-- `path_type`, the result's `exists`/`file_mode`/`eol`, typed V -> T `lineage`, and `prepared_against` for S3's
-- revalidation. current_view = M.view_of(turn, register). Members stay even with zero blocks (no zero-block
-- auto-accept); an input-only file the agent left alone is omitted. Installs nothing; a file that cannot be
-- prepared is in `failures`.
function M.prepare_publication(result, current_view, input)
	current_view = current_view or {}
	local register = current_view.register
	local now = register and register:position() or {}
	local prepared = { schema_version = SCHEMA, turn_id = input.turn_id, workspace_id = input.workspace_id,
		input_id = input.input_id, result_id = result.result_id, cycle_id = input.cycle_id,
		run_generation = input.run_generation, files = {}, order = {}, failures = {}, commit = "prepared",
		idem_key = tostring(result.result_id) .. "@" .. tostring(input.input_id) }
	local paths, seen = {}, {}
	for path in pairs(input.files) do paths[#paths + 1], seen[path] = path, true end
	for path in pairs(result.files) do
		if not seen[path] then paths[#paths + 1] = path end
	end
	table.sort(paths)
	for _, path in ipairs(paths) do
		local rec, out = input.files[path], result.files[path]
		local f, why = prepare_file(input, path, rec, out, (current_view.files or {})[path], now, register)
		if f == nil then
			prepared.failures[path] = why
		elseif f.member or f.mode ~= "unchanged" then
			prepared.files[path] = f
			prepared.order[#prepared.order + 1] = path
		end
	end
	return prepared
end

-- The current view of a Turn's members: {register, files = {[canonical path] = {bufnr, ledger, file,
-- review_state, key}}}.
function M.view_of(turn, register)
	local files = {}
	for _, e in ipairs(view.input_files(turn)) do
		files[e.path] = { bufnr = e.bufnr, ledger = e.ledger, file = e.file, review_state = e.review_state,
			key = e.file and e.file.change and e.file.change.rel or e.path }
	end
	return { register = register, files = files }
end

-- Drop an input's marks and pins (no run record: a refused or abandoned capture).
M.release_input = view.release_input

return M
