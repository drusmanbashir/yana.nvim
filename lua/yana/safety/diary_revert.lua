-- Same names, same behaviour, same write order, moved verbatim.
--
-- `M.revert_operation` reverts the most recent completed op (or one named op_id) to its
-- prior bytes, resuming an in-flight revert through the same `complete_rollback` state
-- machine `M.replay` uses so a retry and a `replay --apply` cannot disagree about what
-- a half-finished revert means.
local M = {}

function M.new(deps)
	local load_journal = deps.load_journal
	local op_seq_number = deps.op_seq_number
	local resolve_target = deps.resolve_target
	local append_jsonl = deps.append_jsonl
	local journal_path = deps.journal_path
	local fsync_dir = deps.fsync_dir
	local observe_state = deps.observe_state
	local accepted_state_for_revert = deps.accepted_state_for_revert
	local revert_refusal_message = deps.revert_refusal_message
	local complete_rollback = deps.complete_rollback
	local journaled_restore = deps.journaled_restore
	local record_completion = deps.record_completion
	-- Live reference (not a copy): a test that mutates
	-- `diary._test.fault.x` at runtime is still seen here.
	local test_state = deps.test_state

	local function revert_refused(session, op, reason)
		return append_jsonl(journal_path(session), {
			kind = "revert_refused",
			op_id = op.op_id,
			path = op.path,
			reason = reason,
			ts = os.time(),
		})
	end

	-- Revert the most recent completed op (or one op_id) to its prior bytes.
	local function revert_operation(opts)
		opts = opts or {}
		local session = opts.session
		if not session then
			return false, "no diary session"
		end
		local filter = opts.op_id

		local rows, _, err = load_journal(session)
		if not rows then
			return false, err
		end

		local intents = {}
		local displaced = {}
		local done = {}
		local reverted = {}
		local revert_started = {}
		local rollback_started = {}
		local rollback_done = {}
		local restore_temp = {}
		for _, row in ipairs(rows) do
			if row.kind == "intent" then
				intents[row.op_id] = row
			elseif row.kind == "displaced" then
				displaced[row.op_id] = row
			elseif row.kind == "done" then
				done[row.op_id] = true
			elseif row.kind == "revert_done" then
				reverted[row.op_id] = true
			elseif row.kind == "revert_start" then
				revert_started[row.op_id] = row
			elseif row.kind == "rollback_start" then
				rollback_started[row.op_id] = row
			elseif row.kind == "restore_temp" then
				restore_temp[row.op_id] = row
			elseif row.kind == "rollback_done" then
				rollback_done[row.op_id] = true
			end
		end

		local targets = {}
		for op_id, _ in pairs(done) do
			if not reverted[op_id] and intents[op_id] then
				if not filter or filter == op_id then
					targets[#targets + 1] = intents[op_id]
				end
			end
		end
		table.sort(targets, function(a, b)
			return op_seq_number(a.op_id) > op_seq_number(b.op_id)
		end)

		if #targets == 0 then
			return false, filter and ("no completed operation to revert for " .. filter) or "no completed operations to revert"
		end

		local reverted_n = 0
		for _, op in ipairs(targets) do
			local path, perr = resolve_target(session.workspace, op.path, op.raw_rel)
			if not path then
				return false, perr
			end

			local disp = displaced[op.op_id]
			if not disp or not disp.displaced_path then
				return false, "no displaced copy recorded for " .. tostring(op.op_id)
			end

			-- A revert already in flight is resumed through the SAME state machine replay uses,
			-- so a retry and a `replay --apply` cannot disagree about what a half-finished
			-- revert means.
			if revert_started[op.op_id] or rollback_started[op.op_id] or rollback_done[op.op_id] then
				local verdict, verr = complete_rollback(
					session,
					op,
					disp,
					rollback_started[op.op_id] or revert_started[op.op_id],
					{
						rollback_done = rollback_done[op.op_id] and true or false,
						restored = restore_temp[op.op_id],
						apply_pending = true,
					}
				)
				if verdict ~= "reverted" then
					local msg = verr or (path .. ": this revert cannot be completed automatically; both versions are kept")
					revert_refused(session, op, msg)
					return false, msg
				end
				reverted_n = reverted_n + 1
				goto continue_revert
			end

			local state, oerr = observe_state(path)
			if not state then
				revert_refused(session, op, oerr)
				return false, oerr
			end
			if not accepted_state_for_revert(op, state) then
				local msg = revert_refusal_message(op, path, state)
				revert_refused(session, op, msg)
				return false, msg
			end

			-- THE MARKER RECORDS WHAT WAS CHECKED, IDENTITY INCLUDED.
			--
			-- `state` above is the object this revert was licensed against. Recording only that
			-- it "held the accepted bytes" left the revert unable to tell, later, whether the
			-- file it is about to overwrite is that same object: a different inode carrying the
			-- same bytes read as "still accepted" and was restored over. Bytes cannot separate
			-- those; `(dev, ino, type)` can.
			local marker = {
				kind = "revert_start",
				op_id = op.op_id,
				path = op.path,
				displaced_path = disp.displaced_path,
				purpose = "revert",
				checked_type = state.kind,
				checked_dev = state.dev,
				checked_ino = state.ino,
				checked_hash = state.hash,
				ts = os.time(),
			}
			-- Mutation seam (gate): the pre-fix `revert_start`, which recorded that
			-- the path held the accepted BYTES and never which object held them. The
			-- restore below carries `state` directly, so this marker is read by
			-- exactly one thing — the gate in front of this route's `revert_done`.
			if test_state.fault.revert_marker_identity_blind then
				marker.checked_dev = nil
				marker.checked_ino = nil
			end
			local ok_log, log_err = append_jsonl(journal_path(session), marker)
			if not ok_log then
				return false, log_err
			end
			local ok_sync, sync_err = fsync_dir(session.diary_dir)
			if not ok_sync then
				return false, sync_err
			end

			-- Crash point: the revert is licensed and journaled, and nothing has been
			-- restored yet. Replay must find the accepted result still on disk and
			-- finish the revert rather than leave it half done for ever.
			if test_state.fault.crash_before_rollback then
				session.simulated_crash = op.op_id
				return true, nil, reverted_n
			end

			local restore_op = {
				op_id = op.op_id,
				path = op.path,
				displaced_state = disp.displaced_state,
				displaced_hash = disp.displaced_hash,
				displaced_mode = disp.displaced_mode,
			}
			local ok, rerr, restored = journaled_restore(session, restore_op, disp.displaced_path, path, "revert after accept", {
				accepted_op = op,
				purpose = "revert",
				-- The very observation that licensed the revert, carried into the
				-- marker and into the check one syscall before the rename.
				checked = state,
			})
			if not ok then
				return false, rerr
			end
			if test_state.fault.crash_before_revert_done then
				session.simulated_crash = op.op_id
				return true, nil, reverted_n
			end
			-- Through the one gate, exactly as the recovery routes are.
			ok, rerr = record_completion(session, "revert_done", op, path, {
				marker = marker,
				disp = disp,
				restored = restored,
			})
			if not ok then
				return false, rerr
			end
			reverted_n = reverted_n + 1
			::continue_revert::
		end

		return true, nil, reverted_n
	end

	return {
		revert_refused = revert_refused,
		revert_operation = revert_operation,
	}
end

return M
