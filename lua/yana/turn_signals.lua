-- SignalBus — the Turn's callback registry: run-to-completion FIFO, per-callback
-- pcall isolation, no veto, registration order is execution order.
--
-- Collaborators see only `turn:register(cb)`, which delegates here.
local M = {}

local Bus = {}
Bus.__index = Bus

function M.new()
	return setmetatable({ callbacks = {}, queue = {}, draining = false }, Bus)
end

-- Registration order is execution order (v1 design decision, unchallenged).
-- `cb` is a plain table of named hook functions plus a `name` for the log.
function Bus:register(cb)
	self.callbacks[#self.callbacks + 1] = cb
end

-- One callback, fully isolated: the hook AND the error report are inside the
-- pcall so a failing logger cannot poison the drain.
local function call_one(cb, signal, ctx)
	local ok, err = pcall(cb[signal], cb, ctx)
	if not ok then
		pcall(function()
			require("yana.log").write(
				"ERROR",
				string.format("turn callback %s.%s failed: %s", cb.name or "?", signal, err)
			)
		end)
	end
end

-- Run-to-completion: an emit that arrives while another emit is still walking
-- its callbacks is queued and drained afterwards, never nested (LOCKED 4 —
-- gen_statem next_event / SCXML macrostep / pytransitions queued=true all
-- converge on this shape). Re-entry via autocmds firing inside a callback is
-- therefore solved by construction.
--
-- The roster for one event is SNAPSHOTTED before its walk: a callback
-- registered mid-drain first hears the NEXT event, never the in-flight one.
-- `draining` is reset on every exit path — nothing between
-- the two assignments can throw uncaught.
function Bus:emit(signal, ctx)
	self.queue[#self.queue + 1] = { signal = signal, ctx = ctx }
	if self.draining then
		return
	end
	self.draining = true
	while #self.queue > 0 do
		local ev = table.remove(self.queue, 1)
		local roster = {}
		for i, cb in ipairs(self.callbacks) do
			roster[i] = cb
		end
		for _, cb in ipairs(roster) do
			if cb[ev.signal] then
				call_one(cb, ev.signal, ev.ctx)
			end
		end
	end
	self.draining = false
end

return M
