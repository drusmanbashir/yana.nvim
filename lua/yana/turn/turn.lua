-- Turn — the review lifecycle unit. The unit is the ENTIRE TURN, encapsulating
-- all files of one agent handover.
--
--
-- States: "live" -> "gone".
local signals = require("yana.turn.turn_signals")
local turn_file = require("yana.turn.turn_file")
local end_result = require("yana.turn.turn_end_result")
local end_plan = require("yana.turn.turn_end_plan")
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
		-- Every path attached to this Turn, including a joined file later
		-- withdrawn by publication undo. History keys stay Turn-owned there.
		history_paths = {},
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

-- The Turn holds its one cycle owner: runs, inputs, results, cycle state (turn/turn_cycle.lua; F-ADDENDUM-TURN).
function Turn:cycles()
	self.cycle_owner = self.cycle_owner or require("yana.turn.turn_cycle").new(self)
	return self.cycle_owner
end

-- Files join the live Turn as their reviews open (W1: the pool grows the Turn).
-- The member is the STABLE `turn_file` record and the returned value is that
-- record, not the caller's entry: a path already present is REFRESHED in place,
-- so a partial re-add can no longer drop the baseline, the ledger, the review
-- options or the owner (R3). The old `self.files[i] = f` replacement is gone.
function Turn:add_file(entry)
	if self:is_frozen() then
		return false, "turn is frozen for End"
	end
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

function Turn:reviewed_paths()
	local paths = {}
	for path in pairs(self.history_paths) do paths[path] = true end
	return paths
end

-- A first-time follow-up attachment was provisional until its publication
-- committed. Rollback may forget it only after membership has been withdrawn.
function Turn:forget_uncommitted_review(path)
	if self:file(path) ~= nil then
		return false, "turn.forget_uncommitted_review: " .. tostring(path) .. " is still a member"
	end
	self.history_paths[path] = nil
	return true
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
	if self:is_frozen() then return false, "turn is frozen for End" end
	local f = self:file(path)
	if f == nil then
		return false, "turn.attach_review: " .. tostring(path) .. " is not a member of this Turn"
	end
	local ok, err = f:attach(state)
	if ok then self.history_paths[f.path] = true end
	return ok, err
end

function Turn:detach_review(path, expected_state)
	if self:is_frozen() then return false, "turn is frozen for End" end
	local f = self:file(path)
	if f == nil then
		return false, "turn.detach_review: " .. tostring(path) .. " is not a member of this Turn"
	end
	return f:detach(expected_state)
end

-- Terminal cleanup may retire only the attachment captured in the private plan.
function Turn:retire_planned_review(item, binding, expected_state)
	assert(self.frozen and binding.file == self:file(item.path), "End retirement is not a planned member")
	return binding.file:retire_attachment(expected_state)
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

function Turn:is_frozen()
	return self.frozen == true or self.sealing == true
end

-- This is one synchronous local boundary. A drain failure is terminal for this
-- confirmed End: the owning watcher remains closed to new input, with its
-- captured evidence retained, and no external collaborator is entered.
function Turn:freeze_for_end(cause)
	if self.frozen then return true end
	self.sealing = true
	local watch = require("yana.review_watch")
	local tokens = {}
	for _, f in ipairs(self.files) do
		local state = f.review_state
		if state ~= nil then
			local ok, token = watch.begin_end(f.bufnr, state)
			if not ok then return false, token end
			tokens[#tokens + 1] = token
		end
	end
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
				bomb = vim.bo[bufnr].bomb,
			}
		end
	end
	local candidate, reason = end_plan.prepare(self, cause)
	if candidate == false then return false, reason end
	end_plan.publish(self, candidate)
	self.frozen = true
	self.sealing = nil
	if self.deps.on_sealed then self.deps.on_sealed(self) end
	for _, token in ipairs(tokens) do
		local retired, retire_reason = watch.retire_end(token)
		if not retired then return false, retire_reason end
	end
	return true
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
	if self.state ~= "live" or self:is_frozen() or self:pending_count() == 0 then
		return
	end
	self.review_alive = true
	self.bus:emit("review_alive", { turn = self })
end

-- Emit only when undo, redo or a decision crosses the pending-work edge.
function Turn:refresh_review_liveness()
	if self.state ~= "live" or self:is_frozen() then
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

function Turn:run_cleanup(attempt, cause, refused)
	if self.attempt ~= attempt or self.state ~= "live" then return end
	-- The private plan is the only close/cleanup membership authority.
	local members_ok, members_err = pcall(end_plan.bindings, self)
	if not members_ok then
		self.cleanup_error = name_failure("membership", members_err)
		self:deliver_end_result("partial", { phase = "local", reason = tostring(self.cleanup_error) })
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
	local first = end_plan.bindings(self)[1]
	local ws, turn_id = require("yana.turn.turn_settle_snapshot").register_key(first and first.binding.file) -- drop its history (B7)
	pcall(function() require("yana.turn.turn_register"):release_turn(ws, turn_id) end)
	self.bus:emit("turn_end", { turn = self, cause = cause, refused = refused or {} })
	if self.deps.on_gone then pcall(self.deps.on_gone, self) end
	if refused and #refused > 0 then
		self:deliver_end_result("partial", {
			phase = "settle", reason = tostring(refused[1].err), refused = refused, review_ended = true,
		})
	else
		self:deliver_end_result("completed", { refused = {} })
	end
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

	-- Step 1 — the ask. A confirmed End stays one-way, even on partial failure.
	local ok_ask, answer = pcall(self.deps.ask, cause, { pending = self:pending_count() })
	if not ok_ask or answer ~= "end" then
		self.ending = false
		self:deliver_end_result(ok_ask and "cancelled" or "refused",
			ok_ask and nil or { reason = tostring(answer) })
		return false
	end

	-- End confirmation barrier: freeze the Turn, stamp ledgers, capture buffer
	-- snapshots. After this point the only terminal results are completed and
	-- partial; the Turn never returns to interactive review.
	local called, froze, freeze_err = pcall(self.freeze_for_end, self, cause)
	if not called or not froze then
		self.frozen = true
		self.sealing = nil
		self:deliver_end_result("partial", { phase = "local", reason = tostring(called and freeze_err or froze) })
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
		-- Validate while this attempt still owns the walk. A failed private-plan
		-- identity check is a local invariant failure, not an unanswered End.
		local members_ok, members = pcall(end_plan.bindings, self)
		if not members_ok then
			self.settle_walk = nil
			self.settle_error = name_failure("membership", members)
			self:deliver_end_result("partial", { phase = "local", reason = tostring(self.settle_error) })
			return
		end
		self.settle_walk = nil
		if #refused == 0 and cause == "abort"
			and type(self.deps.settler.reverse_turn_creations) == "function"
		then
			local planned = {}
			for _, member in ipairs(members) do
				planned[#planned + 1] = member.binding.file
			end
			local ok_rev, rev = pcall(self.deps.settler.reverse_turn_creations, planned)
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
			for _, failure in ipairs(refused) do
				if failure.via ~= "buffer" then
					self:deliver_end_result("partial", { phase = "settle", reason = tostring(self.settle_error),
						refused = refused })
					return
				end
			end
		else
			self.settle_error = nil
		end
		self.phase = "settled"
		run_close()
	end

	step = function()
		index = index + 1
		local item, binding = end_plan.item(self, index)
		if item == nil then
			finish_settle()
			return
		end
		local f = binding.file
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
				local buffer_write = type(detail) == "table" and detail.via == "buffer" and detail.phase == "write"
				refused[#refused + 1] = { path = f.path, err = tostring(err or "?"), via = buffer_write and "buffer" or nil }
				if not buffer_write then
					finish_settle()
					return
				end
				-- A failed Neovim write does not stop independent files or review teardown.
				local continued, continue_err = pcall(step)
				if not continued and self.settle_walk == walk then
					refused[#refused + 1] = {
						path = f.path,
						err = "settle continuation failed: " .. tostring(continue_err),
					}
					finish_settle()
				end
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
		local settle_fn = self.deps.settler.settle_plan or self.deps.settler.settle
		local called, result, err
		if self.deps.settler.settle_plan then
			called, result, err = pcall(settle_fn, item, binding, on_settled)
		else
			called, result, err = pcall(settle_fn, f, on_settled)
		end
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
