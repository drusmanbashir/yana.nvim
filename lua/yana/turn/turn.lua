-- Turn — the review lifecycle unit. The unit is the ENTIRE TURN, encapsulating
-- all files of one agent handover.
--
--
-- States: "live" -> "gone".
local signals = require("yana.turn.turn_signals")
local turn_file = require("yana.turn.turn_file")
local end_result = require("yana.turn.turn_end_result")
local log = require("yana.log")

local M = {}

local Turn = {}
Turn.__index = Turn

-- One spelling for every refusal or throw a collaborator produces, so the last
-- line on disk always names the STAGE ("settle", "close", "cleanup") and, when
-- one is owed, the file (rule 7a). Nothing else in this module writes a notice.
local function name_failure(stage, reason, path)
	local msg
	if path then
		msg = string.format("yana: turn %s failed for %s: %s", stage, path, tostring(reason))
	else
		msg = string.format("yana: turn %s failed: %s", stage, tostring(reason))
	end
	log.write("WARN", msg)
	pcall(vim.notify, msg, vim.log.levels.WARN)
	return msg
end

-- Init trigger: the agent's handover ("overlay worked, look at hunks"). `files` = { {
-- path=abs, ledger=HunkLedger, base_text=string, bufnr=int? }, ...
--
-- The constructor emits nothing: `turn_start` fires from `start()`, called by
-- the owner AFTER collaborators registered, so the signal is observable.
function M.new(files, deps)
	deps = deps or {}
	assert(type(deps.ask) == "function", "Turn.new: deps.ask is required")
	assert(deps.settler and deps.settler.settle, "Turn.new: deps.settler is required")
	assert(type(deps.cleanup) == "function", "Turn.new: deps.cleanup is required")
	local self = setmetatable({
		state = "live",
		started = false,
		files = {},
		bus = signals.new(),
		deps = deps,
		-- R9 POLICY SNAPSHOT, RECONCILED (F-TRL09-02). The Turn OWNS the field;
		-- the single writer is the bind-time site in `review_open_bind`, which
		-- reads `yana.setup`'s stored configuration and nothing the agent sent.
		-- This constructor only gives that one writer a home on the Turn so the
		-- record cannot be invented per file. Adding a second writer here is
		-- exactly the competing-owners fault this refactor removes.
		review_opts = {},
		-- End attempt identity and completed phase (design :107). `attempt` is
		-- the identity every collaborator callback is checked against, so a
		-- duplicate or late reply cannot advance a newer attempt; `phase` is the
		-- last phase that COMPLETED, carried ACROSS attempts so a retry repeats
		-- only what is still owed.
		attempt = 0,
		phase = nil,
		-- `close_acked` is STEP control: the close is complete for the membership
		-- the settlement walk saw. `close_committed` is the irreversible record
		-- that a close was acknowledged at all -- it freezes the cause and
		-- retires the ask, and no later membership change may take it back.
		close_acked = false,
		close_committed = false,
		-- The paths the settlement walk actually settled. Cleanup may retire
		-- these and nothing else.
		settled_members = nil,
		cleanup_error = nil,
		-- The one edge memory for "is there a pending review hunk to work
		-- on". Derived from the ledgers, never a second count: the field
		-- only remembers which EDGE was last announced so a render and a
		-- teardown are each emitted once.
		review_alive = false,
		close_error = nil,
		settle_error = nil,
		settle_walk = nil,
		before_end_emitted = false,
		-- Re-entrancy guard: the dialog and settlement both pump the event
		-- loop; a nested end_turn must be a no-op.
		ending = false,
	}, Turn)
	for _, entry in ipairs(files or {}) do
		assert(self:add_file(entry) ~= nil, "Turn.new: every intake entry must become a stable File")
	end
	return self
end

function Turn:start()
	self.started = true
	self.bus:emit("turn_start", { turn = self })
end

-- Files join the live Turn as their reviews open (W1: the pool grows the Turn).
-- The member is the STABLE `turn_file` record and the returned value is that
-- record, not the caller's entry: a path already present is REFRESHED in place,
-- so a partial re-add can no longer drop the baseline, the ledger, the review
-- options or the owner (R3). The old `self.files[i] = f` replacement is gone.
function Turn:add_file(entry)
	if type(entry) ~= "table" then
		name_failure("membership", "entry must be a table")
		return nil
	end
	local existing = self:file(entry.path)
	if existing ~= nil then
		local ok, err = existing:refresh(entry)
		if not ok then
			name_failure("membership", err, entry.path)
		end
		return existing
	end
	local file, err = turn_file.new(entry, self)
	if file == nil then
		name_failure("membership", err, entry.path)
		return nil
	end
	self.files[#self.files + 1] = file
	return file
end

-- Intake creates membership before the corresponding review buffer attaches.
-- A terminal open refusal must undo only that unattached membership.
function Turn:withdraw_unopened_file(path)
	if self.state ~= "live" or self.ending or self.frozen then
		return false, "turn.withdraw_unopened_file: the Turn is not mutable"
	end
	local file, index = self:file(path)
	if file == nil then
		return true, #self.files == 0
	end
	if file.review_state ~= nil then
		return false, "turn.withdraw_unopened_file: " .. tostring(path) .. " has an attached review"
	end
	table.remove(self.files, index)
	return true, #self.files == 0
end

function Turn:retire_empty(cause)
	if self.state ~= "live" or #self.files ~= 0 then
		return false, "turn.retire_empty: the Turn is not live and empty"
	end
	self.state = "gone"
	if self.started then
		self.bus:emit("turn_end", { turn = self, cause = cause or "empty" })
	end
	if self.deps.on_gone then
		pcall(self.deps.on_gone, self)
	end
	return true
end

-- The review attachment is the File's, not the Turn's: the Turn only routes by
-- path. `detach_review` retires ONLY the attachment the caller still believes is
-- current, so an older owner's teardown never retires a newer review (R4).
function Turn:attach_review(path, state)
	local f = self:file(path)
	if f == nil then
		return false, "turn.attach_review: " .. tostring(path) .. " is not a member of this Turn"
	end
	return f:attach(state)
end

function Turn:detach_review(path, expected_state)
	local f = self:file(path)
	if f == nil then
		return false, "turn.detach_review: " .. tostring(path) .. " is not a member of this Turn"
	end
	return f:detach(expected_state)
end

function Turn:file(path)
	for i, file in ipairs(self.files) do
		if file.path == path then
			return file, i
		end
	end
	return nil
end

function Turn:register(cb)
	self.bus:register(cb)
end

function Turn:is_live()
	return self.state == "live"
end

-- Binding to the Turn's turn-scope count is an integration item.
function Turn:pending_count()
	local n = 0
	for _, f in ipairs(self.files) do
		n = n + f:pending_count()
	end
	return n
end

-- Review surfaces follow pending work independently of the Turn lifetime.
function Turn:announce_review()
	if self.state ~= "live" or self:pending_count() == 0 then
		return
	end
	self.review_alive = true
	self.bus:emit("review_alive", { turn = self })
end

-- Emit only when undo, redo or a decision crosses the pending-work edge.
function Turn:refresh_review_liveness()
	if self.state ~= "live" then
		return
	end
	local alive = self:pending_count() > 0
	if alive == self.review_alive then
		return
	end
	self.review_alive = alive
	self.bus:emit(alive and "review_alive" or "review_finished", { turn = self })
end

--- THE END REQUEST. One record per End, owned here and nowhere else. `cause` is
--- the requested outcome; once this End has COMMITTED anything -- a file whose
--- settlement receipt reports a write, or an acknowledged close -- the cause is
--- frozen. A retry that arrives through another entry key then resumes the End
--- that is already part-done instead of reinterpreting the committed half as
--- something the operator never asked for (F-HONEST-OUTCOME).
function Turn:end_request(cause)
	local committed = self.close_committed == true
	if not committed then
		for _, f in ipairs(self.files) do
			if type(f.settle_receipt) == "table" and f.settle_receipt.written == true then
				committed = true
				break
			end
		end
	end
	if committed and self.end_cause ~= nil then
		return self.end_cause, true
	end
	self.end_cause = cause
	return cause, false
end

--- Step 5 -- the ONE mandatory cleanup collaborator, owned by the Turn so that
--- BOTH the first attempt and a post-ACK resume reach it by the same path. Not a
--- no-veto Bus listener: it may refuse, and a throw is a NAMED failure that
--- halts the attempt before publication. It runs only after the durable close
--- has been acknowledged, and publication happens only after it succeeds.
--- REQUIRED CLEANUP a collaborator owes before this Turn may publish. Keyed, so
--- a repeated registration replaces rather than duplicates, and every owner --
--- one per file receipt -- is tracked separately and run exactly once on
--- success.
---
--- This is not a `turn_end` listener and not a replacement for `deps.cleanup`.
--- A listener fires only AFTER the Turn has already published `gone`, which is
--- too late to veto and, worse, can be registered after the emit has happened;
--- and it has no answer the Turn reads. Required cleanup is fallible: a refusal
--- keeps the Turn live with its work owed, and the retry repeats only what is
--- still owed. The panel owns the receipt callback, the Turn owns when it runs.
function Turn:require_cleanup(key, fn)
	if key == nil or type(fn) ~= "function" then
		return false, "turn.require_cleanup: a key and a function are required"
	end
	self.required_cleanup = self.required_cleanup or {}
	self.required_cleanup_order = self.required_cleanup_order or {}
	if self.required_cleanup[key] == nil then
		self.required_cleanup_order[#self.required_cleanup_order + 1] = key
	end
	self.required_cleanup[key] = fn
	return true
end

--- Run every owed required cleanup, in registration order. A succeeded one is
--- forgotten so a retry cannot run it twice; the first refusal stops the walk
--- and leaves itself and everything after it owed.
function Turn:run_required_cleanup()
	for _, key in ipairs(self.required_cleanup_order or {}) do
		local fn = self.required_cleanup and self.required_cleanup[key]
		if fn ~= nil then
			local called, ok, reason = pcall(fn, self)
			if not called then
				return false, tostring(key) .. ": " .. tostring(ok)
			end
			if ok ~= true then
				return false, tostring(key) .. ": " .. tostring(reason or "refused")
			end
			self.required_cleanup[key] = nil
		end
	end
	return true
end

--- Files that joined the Turn AFTER the settlement walk fixed its membership.
--- Settlement and close are asynchronous, so another panel can bind a file into
--- the singleton Turn while this End waits for a close ACK. Cleanup is the
--- terminal sweep: it would retire that file -- mark it rejected and drop it --
--- without it ever having been settled or its owner ever having been asked to
--- close. A Turn may only retire what it settled.
function Turn:late_members()
	local late = {}
	if self.settled_members == nil then
		return late
	end
	for _, f in ipairs(self.files) do
		if self.settled_members[f.path] == nil then
			late[#late + 1] = f.path
		end
	end
	return late
end

--- ONE COMPARABLE VALUE for the review decisions a File carries. `false` means
--- the question could not be asked in this context -- a stubbed settler, a File
--- with no ledger -- and a `false` is only ever compared against another
--- `false`, so an unanswerable question never invents drift and never hides it.
---
--- Deliberately the DECISION stamp and not `settled_current`. That one answers
--- "is every input and output of this settlement still exactly what it was",
--- which is the right question for a retry walk deciding whether to re-settle
--- and the WRONG one here: it is false whenever the evidence merely cannot be
--- reproduced, and cleanup would then refuse a Turn nothing had decided again.
--- `decision_stamp` answers only "did a review decision move", which is the
--- question this boundary is asking.
---
--- If `decision_stamp` is ever renamed away, this quietly answers `false` for
--- everything and the boundary stops detecting. `r_end_decision_during_close`
--- is what makes that loud; keep it.
function Turn:decision_stamp(f)
	local stamp = type(self.deps.settler.decision_stamp) == "function"
		and self.deps.settler.decision_stamp or nil
	if stamp == nil then
		local loaded, snapshot = pcall(require, "yana.turn.turn_settle_snapshot")
		if loaded and type(snapshot) == "table" and type(snapshot.decision_stamp) == "function" then
			stamp = snapshot.decision_stamp
		end
	end
	if stamp == nil then return false end
	local asked, value = pcall(stamp, f)
	if not asked or value == nil then return false end
	return value
end

--- Files a review decided AGAIN after their settlement. The membership check
--- above catches a file that joined; this catches the same window moving a file
--- that was already there. The close ACK is asynchronous and the review keys
--- stay answerable until it lands, so a `ca` in that window can accept an
--- operation this End had just removed -- without touching the path set.
--- Cleanup would then publish `completed` over a decision it never wrote.
function Turn:drifted_members()
	local drifted = {}
	if self.settled_members == nil then
		return drifted
	end
	for _, f in ipairs(self.files) do
		local at_settle = self.settled_members[f.path]
		if at_settle ~= nil and self:decision_stamp(f) ~= at_settle then
			drifted[#drifted + 1] = f.path
		end
	end
	return drifted
end

function Turn:run_cleanup(attempt, cause, refused)
	if self.attempt ~= attempt or self.state ~= "live" then return end
	-- THE POST-SETTLEMENT BOUNDARY, before anything terminal runs. Two ways the
	-- Turn can no longer be the Turn that was settled: a file JOINED, or a
	-- settled file MOVED. Either is refused honestly and left live; the close
	-- ACK already banked stays banked (per owner, in `turn_bind`'s
	-- `review_close_acks`) and required cleanup stays owed, so the retry settles
	-- and closes only what is actually owed. `close_acked` goes back to false
	-- because the close step is NOT finished for this Turn; `close_committed`
	-- does not, because a close WAS acknowledged and the operator is not asked
	-- a second time.
	local late = self:late_members()
	local drifted = #late == 0 and self:drifted_members() or {}
	if #late > 0 or #drifted > 0 then
		self.close_acked = false
		local phase = #late > 0 and "membership" or "settlement_drift"
		self.cleanup_error = name_failure(phase, #late > 0
			and ("joined after settlement: " .. table.concat(late, ", "))
			or ("decided again after settlement: " .. table.concat(drifted, ", ")))
		self:deliver_end_result("partial", { phase = phase, reason = tostring(self.cleanup_error) })
		return
	end
	self.phase = "closed"
	self.close_acked = true
	self.close_committed = true
	-- BEFORE `deps.cleanup` and before publication: a collaborator that owes
	-- the Turn a release must have finished it, or the Turn is not done.
	local finalized, finalize_err = self:run_required_cleanup()
	if not finalized then
		self.cleanup_error = name_failure("finalize", finalize_err)
		self:deliver_end_result("partial", { phase = "finalize", reason = tostring(finalize_err) })
		return
	end
	local called, result, reason = pcall(self.deps.cleanup, self, cause)
	if not called then
		self.cleanup_error = name_failure("cleanup", result)
		self:deliver_end_result("partial", { phase = "cleanup", reason = tostring(self.cleanup_error) })
		return
	end
	if result ~= true then
		self.cleanup_error = name_failure("cleanup", reason or "cleanup_refused")
		self:deliver_end_result("partial", { phase = "cleanup", reason = tostring(self.cleanup_error) })
		return
	end
	self.cleanup_error = nil
	self.phase = "cleaned"

	-- Step 6 -- publish. Local finalisation and the queue drain hang off
	-- `turn_end`/`on_gone`, so they follow every collaborator, never precede one.
	self.state = "gone"
	self.bus:emit("turn_end", { turn = self, cause = cause, refused = refused or {} })
	if self.deps.on_gone then pcall(self.deps.on_gone, self) end
	self:deliver_end_result("completed", { refused = refused or {} })
end

--- The End request record and its one answer live in `yana.turn.turn_end_result`.
function Turn:refuse_end(context, cause, reason)
	return end_result.refuse(context, cause, reason)
end

function Turn:deliver_end_result(status, extra)
	local result = end_result.deliver(self.end_context, status, extra)
	if result == nil then return false end
	self.end_result = result
	return true
end

function Turn:end_turn(cause, context)
	if self.state ~= "live" or self.ending then
		-- A SECOND CALLER, answered from its OWN context: a bare `false` left it
		-- waiting for a callback nobody registered. NOT through
		-- `deliver_end_result` -- that record belongs to the End already
		-- running, and spending it here robs the first caller of its one answer.
		self:refuse_end(context, cause, self.ending
			and "an End is already running for this turn"
			or ("the turn is " .. tostring(self.state)))
		return false
	end
	-- Deferral, not inversion: reached from inside a bus callback, our own
	-- emits would queue and settlement would outrun `before_turn_end`.
	-- Re-enter on the next tick, outside the drain.
	if self.bus.draining then
		vim.schedule(function()
			self:end_turn(cause, context)
		end)
		return false
	end

	self.ending = true

	-- One request record per End, registered BEFORE any collaborator runs so
	-- every exit below has something to answer.
	self.end_context = end_result.request(cause, context)

	-- The requested outcome belongs to the End request, not to whichever key
	-- called last. A committed End keeps the cause its first write used.
	cause = self:end_request(cause)

	-- RESUME. An acknowledged close is a one-way boundary: the question was
	-- already answered and every file already settled, so a retry that only
	-- failed at cleanup repeats cleanup and nothing else. Asking again, or
	-- walking the files again, would re-question a decision the operator has
	-- made and re-enter settlement the close already passed.
	--
	-- A LATE MEMBER is the one thing that reopens the walk: `close_acked` was
	-- cleared because a file joined that no settlement covers. The walk skips
	-- what is already settled and `close_review_owners` skips owners that have
	-- already acknowledged, so the retry costs exactly the new member.
	if self.close_acked then
		self.attempt = self.attempt + 1
		self:run_cleanup(self.attempt, cause, self.end_refused)
		return true
	end

	-- Step 1 — the ask. An acknowledged close already carries the operator's
	-- answer: a late member owes settlement, not a second question.
	if not self.close_committed then
		local ok_ask, answer = pcall(self.deps.ask, cause, { pending = self:pending_count() })
		if not ok_ask or answer ~= "end" then
			self.ending = false
			self:deliver_end_result(ok_ask and "cancelled" or "refused",
				ok_ask and nil or { reason = tostring(answer) })
			return false
		end
	end

	-- End confirmation barrier: freeze the Turn, stamp ledgers, capture buffer
	-- snapshots. After this point the only terminal results are completed and
	-- partial; the Turn never returns to interactive review.
	local froze, freeze_err = pcall(function()
		if self.frozen then return end
		-- Set this before any fallible stamp or buffer read. A local failure is
		-- one-way: it may publish partial, but cannot return to live review.
		self.frozen = true
		for _, f in ipairs(self.files) do
			if f.ledger and type(f.ledger.stamp_frozen) == "function" then
				f.ledger:stamp_frozen()
			end
			local bufnr = f.bufnr
			if type(bufnr) == "number" and bufnr > 0
				and vim.api.nvim_buf_is_valid(bufnr)
				and (type(f.change) ~= "table" or f.change.kind ~= "delete") then
				f.frozen_buffer = {
					lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
					changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
					fileformat = vim.bo[bufnr].fileformat,
					endofline = vim.bo[bufnr].endofline,
				}
			end
		end
	end)
	if not froze then
		self:deliver_end_result("partial", { phase = "local", reason = tostring(freeze_err) })
		return true
	end

	-- Step 2 — the attempt identity and the completed phase, recorded BEFORE any
	-- collaborator runs (design :107). `phase` is deliberately NOT reset: it is
	-- the record that makes a retry repeat only what is still owed, and
	-- `attempt` is the identity every reply is checked against so a duplicate or
	-- a late one cannot advance a newer attempt.
	self.attempt = self.attempt + 1
	local attempt = self.attempt

	-- Step 3 — settle, then scrub. Settlement may wait for a file.claim; teardown
	-- cannot start until every journaled projection has reported success.
	if not self.before_end_emitted then
		self.before_end_emitted = true
		self.bus:emit("before_turn_end", { turn = self, cause = cause })
	end

	local walk = {}
	self.settle_walk = walk
	local refused = {}
	local index = 0
	local finish_settle
	local step

	local function run_cleanup()
		self:run_cleanup(attempt, cause, refused)
	end

	-- Step 4 — await the existing durable close. An ACKed close is never
	-- repeated: a later attempt that failed at cleanup resumes AT cleanup, with
	-- no second close and no second file write.
	local function run_close()
		if self.attempt ~= attempt then return end
		if self.close_acked then
			run_cleanup()
			return
		end
		local close_completed = false
		local function finish_close(ok, err)
			if close_completed then return end
			close_completed = true
			if not ok then
				self.close_error = name_failure("close", err or "review_close_refused")
				self:deliver_end_result("partial", { phase = "close", reason = tostring(self.close_error) })
				return
			end
			self.close_error = nil
			run_cleanup()
		end

		if self.deps.close then
			local ok_close, result, err = pcall(self.deps.close, self, cause, refused, finish_close)
			if not ok_close then
				finish_close(false, result)
			elseif result == false then
				finish_close(false, err)
			elseif result ~= "pending" then
				finish_close(true)
			end
		else
			finish_close(true)
		end
	end

	finish_settle = function()
		if self.settle_walk ~= walk then return end
		self.settle_walk = nil
		if #refused == 0 and cause == "abort"
			and type(self.deps.settler.reverse_turn_creations) == "function"
		then
			local ok_rev, rev = pcall(self.deps.settler.reverse_turn_creations, self.files)
			if ok_rev then
				for _, r in ipairs(rev or {}) do
					refused[#refused + 1] = { path = r.path, err = r.err }
				end
			else
				refused[#refused + 1] = { path = "turn creations", err = tostring(rev) }
			end
		end

		for _, r in ipairs(refused) do
			log.write("WARN", string.format("turn settle refused for %s: %s", r.path, r.err))
			pcall(vim.notify, string.format("yana: settle refused for %s: %s", r.path, r.err), vim.log.levels.WARN)
		end
		if #refused > 0 then
			self.settle_error = refused[1].err
			self:deliver_end_result("partial", { phase = "settle", reason = tostring(self.settle_error),
				refused = refused })
			return
		end
		self.settle_error = nil
		self.phase = "settled"
		-- The membership this walk settled AND the decisions each member carried
		-- when it did -- one record, two questions. A path absent from it joined
		-- late; a path whose stamp has moved was decided again.
		local members = {}
		for _, f in ipairs(self.files) do
			members[f.path] = self:decision_stamp(f)
		end
		self.settled_members = members
		-- Retained for a post-ACK resume, which has no walk of its own.
		self.end_refused = refused
		run_close()
	end

	step = function()
		index = index + 1
		local f = self.files[index]
		if f == nil then
			finish_settle()
			return
		end
		if f.settled_at_exit then
			local current = type(self.deps.settler.settled_current) == "function"
				and self.deps.settler.settled_current(f) == true
			if current then
				step()
				return
			end
			f:invalidate_settlement()
		end
		local answered = false
		-- `done(ok, reason, detail)` — the THIRD argument is the settler's
		-- receipt for work it already committed (`{phase, written, diary_dir,
		-- op_id}`). It is retained on the exact File so a retry of a
		-- committed-but-unreadable write can see its own receipt instead of
		-- blindly rewriting (R5). Kept whatever the verdict: a refusal AFTER the
		-- write committed is precisely the case the record exists for.
		local function on_settled(ok, err, detail)
			if answered or self.settle_walk ~= walk then return end
			answered = true
			if type(detail) == "table" then
				-- The File owns its receipt; the Turn asks, it does not assign.
				f:record_receipt(detail)
			end
			if not ok then
				refused[#refused + 1] = { path = f.path, err = tostring(err or "?") }
				finish_settle()
				return
			end
			-- The End's own answer. The stamp is turn_settle's and travels back unchanged.
			f:record_settlement(f.settlement_stamp, true)
			local continued, continue_err = pcall(step)
			if not continued and self.settle_walk == walk then
				refused[#refused + 1] = {
					path = f.path,
					err = "settle continuation failed: " .. tostring(continue_err),
				}
				finish_settle()
			end
		end
		local called, result, err = pcall(self.deps.settler.settle, f, on_settled)
		if not called then
			on_settled(false, result)
		elseif result ~= "pending" then
			on_settled(result == true, err)
		end
	end

	local started, start_err = pcall(step)
	if not started and self.settle_walk == walk then
		refused[#refused + 1] = { path = "turn settlement", err = tostring(start_err) }
		finish_settle()
	end
	return true
end

-- The Turn only routes it into the one End process; it never asks or ends by itself.
function Turn:on_undo_exhausted()
	if self.state ~= "live" then
		return
	end
	self.bus:emit("undo_exhausted", { turn = self })
	-- Named provenance: an End that began here must still say so if it
	-- completes long after, through an asynchronous settlement.
	self:end_turn("undo_exhausted", { source = "undo_exhausted" })
end

-- A decision was recorded on some file's ledger.
--- `trigger` is the name of the control that made the decision, and `owner` the
--- review it belongs to. `last_hunk` is the FALLBACK for a caller that truly
--- named nothing, not the label for every route.
function Turn:on_decision(trigger, owner)
	-- Turn-wide zero finishes the review whatever the dialog then
	-- answers. Announced before step 1 asks, so "Keep reviewing" -- which
	-- decides nothing and leaves nothing pending -- keeps the panel gone.
	self:refresh_review_liveness()
	if self:pending_count() == 0 then
		self:end_turn("decided", { source = trigger or "last_hunk", owner = owner })
	end
end

return M
