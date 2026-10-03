-- turn/turn_cycle_log.lua -- the follow-up path's INFO events (diagnostics rule F-LOGGING "N-cycle
-- follow-up events"; design followup-addendum-turn.md "### Publication and history"). One canonical event per unit
-- of work, written through `yana.log.lifecycle_info` (the one logger): codes, counts and sha8 digests, never
-- payload bytes. Every event carries log_session (stamped by the logger), turn_id, generation, panel_id, cycle_id.
local log = require("yana.log")

local M = {}

local function sha8(s)
	return vim.fn.sha256(tostring(s)):sub(1, 8)
end
M.sha8 = sha8

local function rel_in_workspace(path, ws)
	if type(ws) == "string" and ws ~= "" and path:sub(1, #ws + 1) == ws .. "/" then return path:sub(#ws + 2) end
	return path
end

-- Correlation of one run: turn_id, generation, panel_id, cycle_id.
local function corr(run, extra)
	local pass = run and run.pass or {}
	local out = { turn_id = run and run.turn_id or pass.turn_id and tostring(pass.turn_id),
		generation = run and run.run_generation or pass.generation, panel_id = pass.panel,
		cycle_id = run and run.cycle_id }
	if out.turn_id ~= nil then out.turn_id = tostring(out.turn_id) end
	for k, v in pairs(extra or {}) do out[k] = v end
	return out
end

local function write_event(kind, fields)
	log.lifecycle_info(kind, fields)
end

-- followup.submit, started: the captured CycleInput. `facts` = { resume_id, prefix, rejected }.
function M.submit_started(run, input, facts)
	local files = {}
	local rels = vim.tbl_keys(input.files)
	table.sort(rels)
	for _, path in ipairs(rels) do
		local rec = input.files[path]
		files[#files + 1] = { rel = rel_in_workspace(path, run.workspace), sha8 = sha8(rec.bytes_ref or table.concat(rec.lines or {}, "\n")),
			exists = rec.existence ~= false, input_only = rec.input_only == true }
	end
	write_event("followup.submit", corr(run, { outcome = "started", resume_id_present = facts.resume_id ~= nil
		and facts.resume_id ~= "", resume_id_sha8 = facts.resume_id and facts.resume_id ~= "" and sha8(facts.resume_id)
		or nil, prefix_line = facts.prefix == true, rejected_paths = facts.rejected, input_files = #files,
		files = files }))
end

-- followup.submit, refused (or held): `ctx` = { turn_id, generation, panel_id, resume_id, held }.
function M.submit_refused(code, ctx)
	write_event("followup.submit", { outcome = "refused", code = code, held = ctx.held == true, turn_id = ctx.turn_id
		and tostring(ctx.turn_id), generation = ctx.generation, panel_id = ctx.panel_id,
		resume_id_present = ctx.resume_id ~= nil and ctx.resume_id ~= "", resume_id_sha8 = ctx.resume_id
		and ctx.resume_id ~= "" and sha8(ctx.resume_id) or nil })
end

-- followup.launch_failed: the run began (followup.submit started) but its launch was refused; never a second submit.
function M.submit_launch_refused(run, code)
	write_event("followup.launch_failed", corr(run, { code = code or "launch_refused" }))
end

function M.changed_count(run, changes)
	if changes then return #changes end
	local n = 0
	for _, f in pairs(run.result and run.result.files or {}) do
		if f.change ~= nil then n = n + 1 end
	end
	return n
end

-- followup.result: the run's result recorded (or an unconfirmed writer exit).
function M.result(run, turn, p, changes, writer_unconfirmed)
	local ms = run.started_ns and math.floor((vim.uv.hrtime() - run.started_ns) / 1e6) or nil
	write_event("followup.result", corr(run, { exit_code = turn and tonumber(turn.agent_exit_code), cancelled = p and
		p.cancelled == true, stopped = run.result and run.result.stopped or false,
		writer_unconfirmed = writer_unconfirmed == true, duration_ms = ms, changed_paths = M.changed_count(run, changes) }))
end

-- followup.publish: one publication attempt. `prepared` (may be nil), `outcome`, `code`, `event_id`.
function M.publish(run, outcome, code, prepared, event_id)
	local files = {}
	for _, path in ipairs(prepared and prepared.order or {}) do
		local f = prepared.files[path]
		-- carried accepted: rows of unchanged segments no pending contribution owns (accepted or operator text).
		local carried = 0
		for _, seg in ipairs(f.lineage and f.lineage.segments or {}) do
			if seg.kind == "unchanged" and #(seg.src_origins or {}) == 0 and seg.dst and seg.dst.first then
				carried = carried + seg.dst.last - seg.dst.first + 1
			end
		end
		local pending = #(f.blocks or {})
		local coverage = f.lineage and f.lineage.coverage
		files[#files + 1] = { rel = rel_in_workspace(path, run.workspace), mode = f.mode, pending_hunks = pending,
			carried_accepted = carried, fallback = f.mode == "fallback",
			fallback_reason = f.reason, lineage_coverage = coverage }
	end
	write_event("followup.publish", corr(run, { outcome = outcome, code = code, files = files, publication_event_id = event_id }))
end

-- cycle.state: one transition of the Turn's cycle state.
function M.state(cycles, from, to)
	local run = cycles.runs[#cycles.runs]
	write_event("cycle.state", corr(run, { turn_id = cycles.turn_id and tostring(cycles.turn_id), from = from, to = to }))
end

-- followup.door_refused: a closing door refused. door = end|abort|reject_all|reset|undo_across.
function M.door_refused(door, state)
	local ok, bind = pcall(require, "yana.turn.turn_bind")
	local t = ok and bind.get() or nil
	local cycles = t and t.cycle_owner
	local run = cycles and cycles.runs[#cycles.runs]
	write_event("followup.door_refused", corr(run, { turn_id = cycles and cycles.turn_id and tostring(cycles.turn_id),
		door = door, cycle_state = state or (cycles and cycles.state) }))
end

return M
