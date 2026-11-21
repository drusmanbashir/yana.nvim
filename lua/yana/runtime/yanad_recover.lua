-- Attach a frozen End record without reopening an interactive review.
local M = {}
local request_seq = 0

function M.recover(session_id, deps, done)
	deps = deps or {}
	done = done or function() end
	local panel = deps.panel
	if not panel or not session_id or session_id == "" then
		done(false, "recovery needs a session and panel")
		return false
	end
	local panel_id = panel.id
	request_seq = request_seq + 1
	local request_id = string.format("recovery:attach:%d:%d", vim.fn.getpid(), request_seq)
	-- Keep submit parked until the frozen-End attachment answers.
	panel.yanad_session_pending = true
	panel.yanad_start_session = function(p)
		M.recover(session_id, deps, done)
		return p
	end
	local function settle(err)
		panel.yanad_session_pending = false
		panel.yanad_session_err = err
	end
	require("yana.runtime.yanad").session_attach({ session_id = session_id }, request_id, function(ok, result)
		if deps.current_panel and (deps.current_panel() ~= panel or panel.id ~= panel_id) then
			-- Not this panel's answer any more; leave its flags to whoever owns it now.
			done(false, "stale recovery callback")
			return
		end
		if not ok or type(result) ~= "table" then
			local msg = "yana: recovery attach failed: " .. tostring(result)
			settle(tostring(result))
			if deps.notify then deps.notify(msg, vim.log.levels.ERROR) end
			done(false, msg)
			return
		end
		local recovery = result.recovery
		if type(recovery) == "table" and recovery.kind == "frozen_end" then
			panel.yanad_session_id = session_id
			settle(nil)
			if deps.recover_end then
				deps.recover_end(recovery.record, done)
			else
				done(false, "frozen End recovery requires its Turn recovery owner", recovery.record)
			end
			return
		end
		settle("no frozen End record")
		done(false, "no frozen End record")
	end)
	return true
end

return M
