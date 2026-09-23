-- ONE END REQUEST, ONE ANSWER. Split out of `turn.lua` at 506 lines: this is a
-- single concern -- what a caller asked for, and the one reply it gets -- and
-- `turn.lua` owns the SEQUENCE that decides which reply, not the record.
--
-- `end_turn` returning `true` has always meant STARTED, never finished: an
-- asynchronous settlement can still cancel, refuse or complete long after it
-- returned, and every caller that read the truthy answer as "done" dropped live
-- work. A caller registers `on_result` with its own `source` and `owner` and
-- hears the terminal status exactly once -- `cancelled`, `completed`, or
-- `refused` with a reason (F-HONEST-OUTCOME). Provenance travels with the
-- REQUEST, not with whichever key fires later, so an End that completes through
-- an async continuation still reports the source that began it.
local M = {}

--- The record a Turn holds for the End currently running. Built before any
--- collaborator runs, so every exit has something to answer.
function M.request(cause, context)
	return {
		source = type(context) == "table" and context.source or nil,
		owner = type(context) == "table" and context.owner or nil,
		on_result = type(context) == "table" and context.on_result or nil,
		cause = cause,
		delivered = false,
	}
end

--- Deliver `request`'s one answer. Returns the result table, or nil when the
--- request was already answered -- a second delivery is a silent no-op, never
--- a second callback.
function M.deliver(request, status, extra)
	if request == nil or request.delivered then
		return nil
	end
	request.delivered = true
	local result = {
		status = status,
		source = request.source,
		owner = request.owner,
		cause = request.cause,
	}
	for key, value in pairs(extra or {}) do
		result[key] = value
	end
	if type(request.on_result) == "function" then
		pcall(request.on_result, result)
	end
	return result
end

--- Answer a caller whose request never BECAME the turn's End request, from the
--- context it supplied. It reads and writes no turn state, which is the whole
--- point: the in-flight request belongs to someone else.
function M.refuse(context, cause, reason)
	if type(context) ~= "table" or type(context.on_result) ~= "function" then
		return false
	end
	pcall(context.on_result, {
		status = "refused",
		source = context.source,
		owner = context.owner,
		cause = cause,
		reason = reason,
	})
	return true
end

return M
