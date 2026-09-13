-- Turn — the review lifecycle unit. The unit is the ENTIRE TURN, encapsulating
-- all files of one agent handover.
--
--
-- States: "live" -> "gone".
local signals = require("yana.turn_signals")
local log = require("yana.log")

local M = {}

local Turn = {}
Turn.__index = Turn

-- Init trigger: the agent's handover ("overlay worked, look at hunks"). `files` = { {
-- path=abs, ledger=HunkLedger, base_text=string, bufnr=int? }, ...
--
-- The constructor emits nothing: `turn_start` fires from `start()`, called by
-- the owner AFTER collaborators registered, so the signal is observable.
function M.new(files, deps)
	deps = deps or {}
	assert(type(deps.ask) == "function", "Turn.new: deps.ask is required")
	assert(deps.settler and deps.settler.settle, "Turn.new: deps.settler is required")
	return setmetatable({
		state = "live",
		files = files or {},
		bus = signals.new(),
		deps = deps,
		-- The one edge memory for "is there a pending review hunk to work
		-- on". Derived from the ledgers, never a second count: the field
		-- only remembers which EDGE was last announced so a render and a
		-- teardown are each emitted once.
		review_alive = false,
		close_error = nil,
		-- Re-entrancy guard: the dialog and settlement both pump the event
		-- loop; a nested end_turn must be a no-op.
		ending = false,
	}, Turn)
end

function Turn:start()
	self.bus:emit("turn_start", { turn = self })
end

-- Files join the live Turn as their reviews open (W1: the pool grows the
-- Turn; a path already present is refreshed, not duplicated).
function Turn:add_file(f)
	for i, existing in ipairs(self.files) do
		if existing.path == f.path then
			self.files[i] = f
			return
		end
	end
	self.files[#self.files + 1] = f
end

function Turn:file(path)
	for _, file in ipairs(self.files) do
		if file.path == path then
			return file
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
		n = n + f.ledger:count()
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

function Turn:end_turn(cause)
	if self.state ~= "live" or self.ending then
		return false
	end
	-- Deferral, not inversion: reached from inside a bus callback, our own
	-- emits would queue and settlement would outrun `before_turn_end`.
	-- Re-enter on the next tick, outside the drain.
	if self.bus.draining then
		vim.schedule(function()
			self:end_turn(cause)
		end)
		return false
	end

	self.ending = true

	-- Step 1 — the ask.
	local ok_ask, answer = pcall(self.deps.ask, cause, { pending = self:pending_count() })
	if not ok_ask or answer ~= "end" then
		self.ending = false
		return false
	end

	-- Step 2 — settle, then scrub. Order matters: settlement reads the ledgers
	-- and buffers that teardown destroys.
	self.bus:emit("before_turn_end", { turn = self, cause = cause })

	local refused = {}
	for _, f in ipairs(self.files) do
		-- A file the operator deleted mid-turn is a veto — no write. A third-party
		-- edit inside a hunk refuses THIS file only, loudly. The settler itself is isolated:
		-- one file's error must not strand the Turn half-ended with earlier files already
		-- written.
		local ok, settled, err = pcall(self.deps.settler.settle, f)
		if not ok then
			refused[#refused + 1] = { path = f.path, err = tostring(settled) }
		elseif not settled then
			refused[#refused + 1] = { path = f.path, err = err or "?" }
		end
	end
	-- `settle` above already covers end-of-turn for a creation with zero accepted hunks;
	-- abort covers it whatever was decided, because an abort decides nothing.
	-- Only-if-still-empty, like every other reverse: accepted bytes that reached disk make
	-- the file non-empty and it REFUSES rather than removing them.
	if cause == "abort" and type(self.deps.settler.reverse_turn_creations) == "function" then
		local ok_rev, rev = pcall(self.deps.settler.reverse_turn_creations, self.files)
		if ok_rev then
			for _, r in ipairs(rev or {}) do
				refused[#refused + 1] = { path = r.path, err = r.err }
			end
		end
	end

	for _, r in ipairs(refused) do
		-- Loudly: the operator sees it, not only the log.
		log.write("WARN", string.format("turn settle refused for %s: %s", r.path, r.err))
		pcall(vim.notify, string.format("yana: settle refused for %s: %s", r.path, r.err), vim.log.levels.WARN)
	end

	local close_completed = false
	local function finish_close(ok, err)
		if close_completed then return end
		close_completed = true
		if not ok then
			self.close_error = err or "review_close_refused"
			self.ending = false
			return
		end
		self.close_error = nil
		self.state = "gone"

		-- All owned by collaborators reacting to the signal — Turn holds no byte- or
		-- vim-level teardown logic of its own. The durable close collaborator has
		-- acknowledged before this signal, so every teardown observer sees a claim
		-- that is actually released rather than merely requested.
		self.bus:emit("turn_end", { turn = self, cause = cause, refused = refused })
		if self.deps.on_gone then
			pcall(self.deps.on_gone, self)
		end
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
	return true
end

-- The Turn only routes it into the one End process; it never asks or ends by itself.
function Turn:on_undo_exhausted()
	if self.state ~= "live" then
		return
	end
	self.bus:emit("undo_exhausted", { turn = self })
	self:end_turn("undo_exhausted")
end

-- A decision was recorded on some file's ledger.
function Turn:on_decision()
	-- Turn-wide zero finishes the review whatever the dialog then
	-- answers. Announced before step 1 asks, so "Keep reviewing" -- which
	-- decides nothing and leaves nothing pending -- keeps the panel gone.
	self:refresh_review_liveness()
	if self:pending_count() == 0 then
		self:end_turn("decided")
	end
end

return M
