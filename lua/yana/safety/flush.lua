-- Durable flushes, taken OFF the operator's event loop.
--
-- WHY THIS FILE EXISTS. Every fsync Yana performs is kept; not one is batched,
-- deferred, deleted or reordered here. What moves is WHERE the caller waits for it.
--
-- `uv.fs_fsync(fd, callback)` runs the same flush on the libuv threadpool and
-- calls back on the loop thread. Awaiting it with `vim.wait(..., fast_only)`
-- lets the loop keep turning for the whole flush. The bytes reach the platter
-- at exactly the same moment they did before, in exactly the same order,
-- because the caller still does not proceed until the callback has arrived.
--
-- This satisfies it by option 1 — moving the work off the loop — rather than by
-- withdrawing a flush.
--
--
--   delivered   libuv fs callbacks (this file's own), and raw `uv` timer
--               callbacks, both in FAST context
--   NOT run     `vim.schedule` continuations; job (`jobstart`) callbacks;
--               typed keys and therefore every review keymap
--
-- Every entry into the applier is a review keymap, a `vim.schedule`d
-- continuation, or a job callback, so none of them can land inside this wait.
-- The product's only two raw `uv` timers — `ui.lua`'s spinner and
-- `shadow/preview.lua`'s claim poll — hand off through `vim.schedule` on their
-- first line and so cannot re-enter either.
--
-- This is also not a new re-entrancy class: `safety/hash.lua` computes every
-- fingerprint with `vim.system({"sha256sum"}):wait()`, and Neovim implements
-- that wait as `vim.wait(..., nil, true)` — the same fast-only re-entry, on the
-- same accept path, already there for every hash the applier takes.
--
-- FAST CONTEXT. The callback below runs in libuv fast context, where CORE
-- forbids touching the buffer or the UI. It therefore captures the error value
-- and a boolean and does nothing else. There is no scheduled continuation to
-- generation-check, because nothing here is observable outside the one call
-- that is blocked on it.

local M = {}

local uv = vim.uv or vim.loop

--- An fsync that has not returned in this long is not a slow disk. The bound
--- exists so a wedged filesystem halts the sequence instead of hanging the
--- editor forever; it is never expected to be reached, and reaching it is
--- reported as a failure, which keeps everything and stays retryable.
M.timeout_ms = 600000

M._test = {
	--- Take the on-loop path, for a caller that wants the old timing.
	force_sync = false,
	--- Injected failures. `fail_fsync` — refuse before any request is made.
	--- `fail_async_fsync` — the message the libuv callback reports, which is the ONLY way
	--- to fail a flush that is already off the loop, and so the only honest way to prove
	--- the failure path of this seam.
	fault = {},
	--- Counters, so a row can prove which path a flush actually took.
	stats = { async = 0, sync = 0 },
	--- Called on the loop AFTER the request is queued and BEFORE the wait, so a
	--- row can act inside the window the flush is off the loop.
	on_wait = nil,
}

local function count(kind)
	local s = M._test.stats
	s[kind] = (s[kind] or 0) + 1
end

--- fsync one open descriptor.
---
--- Returns `true`, or `false` plus a named reason, exactly like `uv.fs_fsync`,
--- so every existing caller's failure handling — which stops the sequence,
--- keeps everything, and stays retryable — applies unchanged.
function M.fsync(fd)
	if M._test.fault.fail_fsync then
		return false, "injected durable flush failure"
	end
	-- `vim.wait` may not be called from fast context, and a flush requested
	-- from inside another flush's callback would be exactly that. Falling back
	-- to the on-loop form there is correct rather than merely safe: the loop is
	-- already not turning.
	if M._test.force_sync or vim.in_fast_event() then
		count("sync")
		return uv.fs_fsync(fd)
	end

	local nth = (M._test.stats.async or 0) + 1
	local done, ok, err = false, false, nil
	local queued, req = pcall(uv.fs_fsync, fd, function(cb_err)
		-- libuv fast context. Bytes and state only: no buffer, no UI, nothing
		-- that could reach the applier.
		local injected = M._test.fault.fail_async_fsync
		if injected and (not M._test.fault.fail_async_nth or M._test.fault.fail_async_nth == nth) then
			cb_err = injected
		end
		ok = cb_err == nil
		err = cb_err
		done = true
	end)
	if not queued or not req then
		-- The request could not even be made (out of handles, a stubbed uv).
		-- Fall back rather than claim a flush that never happened.
		count("sync")
		return uv.fs_fsync(fd)
	end
	count("async")

	if M._test.on_wait then
		M._test.on_wait()
	end

	local started = uv.hrtime()
	local wait_err = nil
	while not done do
		local remaining = math.floor(M.timeout_ms - (uv.hrtime() - started) / 1e6)
		if remaining < 1 then
			break
		end
		-- Protected: a `vim.wait` that raises (a context this function's own
		-- fast-event guard did not anticipate) must become a NAMED refusal that
		-- halts the sequence with everything retained, not an exception thrown
		-- out of the middle of a durable write.
		local called, settled, reason = pcall(vim.wait, remaining, function()
			return done
		end, 1, true)
		if not called then
			wait_err = tostring(settled)
			break
		end
		if settled then
			break
		end
		-- -2 is an interrupt (the operator pressed Ctrl-C). `vim.wait` clears
		-- and consumes it before returning, so re-entering the wait cannot
		-- spin: the flush we already asked for is still owed an answer, and
		-- abandoning it here would report a failure for a flush that is about
		-- to succeed. Anything else (-1, a real timeout) stops.
		if reason ~= -2 then
			break
		end
	end

	if not done then
		if wait_err then
			return false, "the durable flush could not be awaited: " .. wait_err
		end
		return false, "the durable flush did not complete within " .. tostring(M.timeout_ms) .. " ms"
	end
	if not ok then
		return false, err
	end
	return true
end

return M
