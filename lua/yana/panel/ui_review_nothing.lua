-- Intake binds every pending file into the Turn
-- before its review opens; a terminal pre-review refusal withdraws that unopened
-- member. The refusal of the last member writes the findings record and keeps that
-- member until the refusal's scheduled close has released the overlay; only then
-- does the Turn retire and the conversation say so, once.
local diff = require("yana.diff")
local log = require("yana.log")

local M = {}

-- Under Yana's protected state root, so the daemon's session reap never takes it.
-- Nothing prunes it.
function M.findings_dir()
	local root = require("yana.shadow.preview").state_root()
	if type(root) ~= "string" or root == "" then
		return nil
	end
	return root .. "/findings"
end

local function record_lines(session, refused)
	local turn_id = tostring(session.turn_id or "unknown")
	local lines = {
		"# Yana review with nothing to show",
		"",
		"- turn: " .. turn_id,
		"- started: " .. (turn_id:match("^(%d+T%d+Z)") or "unknown"),
		"- mode: " .. tostring(session.mode or "unknown"),
		"- workspace: " .. tostring(session.workspace or "unknown"),
		"- recorded: " .. os.date("!%Y-%m-%dT%H:%M:%SZ"),
		"",
		"Every change was refused before review. Nothing was written to the real files.",
	}
	for _, c in ipairs(refused) do
		lines[#lines + 1] = ""
		lines[#lines + 1] = "## " .. diff.abs_path(c.path)
		lines[#lines + 1] = "- reason: " .. tostring(c.reason_class or "refused")
		lines[#lines + 1] = "- detail: " .. tostring(c.review_error or "none")
		lines[#lines + 1] = c.retained_path and ("- agent version kept at: " .. c.retained_path)
			or ("- agent version not kept: " .. tostring(c.retention_error or "no copy was made"))
	end
	return lines
end

local function write_record(session, refused)
	local dir = M.findings_dir()
	if not dir then
		return nil, "no Yana state root"
	end
	local path = dir .. "/" .. tostring(session.turn_id or os.time()):gsub("[^%w%-_.]", "_") .. ".md"
	local ok, err = diff.write_file(path, table.concat(record_lines(session, refused), "\n") .. "\n")
	if not ok then
		return nil, tostring(err)
	end
	return path
end

--- After the panel retained a refused change's bytes. `note(text)` writes one
--- transcript line. Withdraws the file; the last member waits for `after_release`.
function M.on_refused(p, change, note)
	if type(change) ~= "table" or change.status ~= "system_refused" or type(change.path) ~= "string" then
		return
	end
	local turn_bind = require("yana.turn.turn_bind")
	local live = turn_bind.get()
	-- A Turn with follow-up history keeps its refused members: a follow-up's join,
	-- its redo and a failed undo all assert the file is a member, and such a Turn
	-- already holds the first review's files, so it can never be left empty.
	local cycles = live and live.cycle_owner
	if cycles and (cycles.state ~= "reviewing" or #(cycles.runs or {}) > 0) then
		return
	end
	local abs = diff.abs_path(change.path)
	if not turn_bind.sole_member(abs) then
		turn_bind.withdraw_unopened(abs)
		return
	end
	local refused = {}
	for _, c in ipairs(p.changes or {}) do
		if c.status == "system_refused" and tostring(c.turn_id) == tostring(change.turn_id) then
			refused[#refused + 1] = c
		end
	end
	local session = p.shadow_turn or (p.shadow_pass and p.shadow_pass.shadow_turn) or {}
	local wrote, record, record_err = pcall(write_record, session, refused)
	p.nothing_to_show = {
		turn = live,
		path = abs,
		turn_id = session.turn_id,
		count = #refused,
		record = wrote and record or nil,
		record_err = wrote and record_err or record,
		note = note,
	}
end

--- The refusal's scheduled close calls this once its overlay release answered
--- (`ok` true also when no release was owed; `why` names a failure). Retires the
--- Turn only after a release that succeeded, so "closed" is never said over a
--- held overlay. A failure is said once and keeps the record pending: a later
--- release that succeeds still closes the review.
function M.after_release(p, ok, why)
	local pending = p.nothing_to_show
	if pending == nil then
		return
	end
	local turn_bind = require("yana.turn.turn_bind")
	-- Tied to its own Turn: one ending or ended another way (Abort, End) leaves nothing to close.
	if turn_bind.get() ~= pending.turn or pending.turn.ending or not turn_bind.sole_member(pending.path) then
		p.nothing_to_show = nil
		return
	end
	local closed, close_err = false, why or "the overlay was not released"
	if ok then
		p.nothing_to_show = nil
		closed, close_err = turn_bind.withdraw_unopened(pending.path, { cause = "nothing_to_show" })
	elseif pending.told then
		return
	end
	pending.told = true
	log.lifecycle_info("review.nothing_to_show", {
		panel = p.id,
		turn_id = pending.turn_id,
		refused = pending.count,
		record = pending.record,
		record_error = pending.record_err,
		closed = closed == true,
		close_error = closed ~= true and close_err or nil,
	})
	local findings = pending.record and ("findings: " .. pending.record)
		or ("findings record not written: " .. tostring(pending.record_err))
	if closed == true then
		pending.note(string.format("review closed — nothing to review: %d file(s) refused before review; %s",
			pending.count, findings))
	else
		pending.note(string.format("review still open — nothing to review, but it could not close (%s); %s. Abort with cR",
			tostring(close_err), findings))
	end
end

return M
