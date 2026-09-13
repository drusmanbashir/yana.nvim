-- Same names, same behaviour, moved verbatim.
--
-- `record_completion` is the SOLE appender of `rollback_done` and `revert_done` journal
-- rows, gated by `rollback_record_complete` (itself gated by
-- `checked_record_complete`/`displaced_record_complete` from
-- `diary_restore_checks.lua`). `complete_rollback` is the recovery-path caller of
-- `record_completion` used by `M.replay` and `revert_operation`, both of which stay in
-- the parent.
local M = {}

function M.new(deps)
	local checked_record_complete = deps.checked_record_complete
	local rollback_purpose = deps.rollback_purpose
	local displaced_record_complete = deps.displaced_record_complete
	local hash_bytes = deps.hash_bytes
	local read_bytes = deps.read_bytes
	local identity_of = deps.identity_of
	local mode_perm = deps.mode_perm
	local resolve_target = deps.resolve_target
	local fsync_dir = deps.fsync_dir
	local journal_path = deps.journal_path
	local append_jsonl = deps.append_jsonl
	local accepted_state_for_revert = deps.accepted_state_for_revert
	local revert_refusal_message = deps.revert_refusal_message
	local journaled_restore = deps.journaled_restore
	-- Live reference (not a copy): a test that mutates
	-- `diary._test.fault.x` at runtime is still seen here.
	local test_state = deps.test_state


	--- Is the pre-accept state this operation displaced the state at the path now?
	---
	--- Kept because it is precisely the test that is NOT sufficient for a file: it
	--- names bytes and cannot name an object. The mutation seam in
	--- `complete_rollback` restores it as the classifier.
	local function displaced_state_present(disp, state)
		if disp.displaced_state == "absent" then
			return state.kind == "absent"
		end
		if disp.displaced_state == "file" then
			return state.kind == "file" and state.hash == disp.displaced_hash
		end
		return false
	end

	--- Is what is at the path THIS ROLLBACK'S OWN RESTORED OUTPUT?
	---
	--- Absence has no identity — an unlink either happened or it did not, and there is no
	--- second absence a substitution could supply — so a restored absence is classified by
	--- absence alone. A restored FILE does have an identity, and it is the one the
	--- restore-temp marker recorded before its rename. Identity, fingerprint, type and
	--- mode must all agree with THAT record: a different object carrying the displaced
	--- bytes is not this applier's output, whatever it contains, and calling it one writes
	---
	--- The same demand `checked_record_complete` makes of the rollback marker, made of the
	--- marker on the other side of the action.
	local function restore_record_complete(restored, op)
		if type(restored) ~= "table" then
			return false
		end
		-- Mutation seam (gate): the pre-fix reader, which took the record apart
		-- rather than validating it, and asked nothing of the fields it did not use.
		if test_state.fault.restore_record_partial then
			return true
		end
		if restored.restored_state ~= "file" then
			return false
		end
		if type(restored.temp_dev) ~= "number" or type(restored.temp_ino) ~= "number" then
			return false
		end
		if
			type(restored.restored_hash) ~= "string"
			or #restored.restored_hash ~= 64
			or not restored.restored_hash:match("^%x+$")
		then
			return false
		end
		if type(restored.restored_mode) ~= "number" then
			return false
		end
		-- A complete record of SOME OTHER restore is not this one's output. Recovery
		-- indexes these rows by operation, so a mismatch here is a journal that does
		-- not mean what the index assumed, not a lookup that can be trusted anyway.
		if restored.op_id ~= op.op_id or restored.target_path ~= op.path then
			return false
		end
		return true
	end

	--- THE ONE GATE EVERY ROLLBACK ROW PASSES THROUGH.
	---
	--- Not a check per branch. Each of those routes was individually defensible and the
	--- set of them was not, because "every route is guarded" was never a property of the
	--- code, only a claim about it. One gate in front of the whole state machine makes it
	--- a property: a branch that is not gated is a branch that cannot be reached.
	---
	--- What the gate demands, of a completion no less than of a classification:
	---
	--- * a marker at all — an absent one licenses nothing; * a purpose from the enum,
	--- EXACTLY. `rollback_start` carries "auto" and `revert_start` carries "revert"; a
	--- record that says neither is not a record with a default, it is a record that cannot
	--- say whether the accept it undoes was ever meant to stand. A completion resting on
	--- no record of what was displaced is a completion recovery cannot check, not one with
	--- nothing to check; * and, when that validated record says `file`, the restore-temp
	---
	--- Any failure is conflict, and conflict appends nothing: the journal comes out
	--- byte-identical to the one recovery found.
	---
	--- It is the gate at BOTH ends of the state machine. `record_completion` below
	--- is the sole appender of `rollback_done` and `revert_done` and calls this
	--- first, so a completion row is not merely honoured through one gate, it is
	--- written through the same one.
	local function rollback_record_complete(marker, op, path, disp, restored, completion_claimed)
		if type(marker) ~= "table" then
			return false,
				path
					.. ": no rollback marker licenses this operation, so recovery cannot say what was checked or why"
					.. " — refusing; nothing was changed"
		end
		if not rollback_purpose(marker.purpose) then
			return false,
				path
					.. ": the marker licensing this rollback records no purpose it could be recovered under (found "
					.. tostring(marker.purpose)
					.. "), so recovery cannot tell a user revert from the rollback of a failed accept — refusing;"
					.. " nothing was changed"
		end
		if marker.op_id ~= op.op_id or marker.path ~= op.path then
			return false,
				path
					.. ": the marker licensing this rollback was written for a different operation ("
					.. tostring(marker.op_id)
					.. " at "
					.. tostring(marker.path)
					.. ") — refusing; nothing was changed"
		end
		local ok_rec, rec_err = checked_record_complete({
			kind = marker.checked_type,
			dev = marker.checked_dev,
			ino = marker.checked_ino,
			hash = marker.checked_hash,
		}, path)
		if not ok_rec then
			return false, rec_err
		end
		-- Mutation seam (gate): the pre-fix demand, made conditional on the very
		-- record it was meant to check. `disp and disp.displaced_state == "file"`
		-- asked for the restore-temp record only when a displaced record happened to
		-- be present and happened to say `file`, so a journal whose `displaced` row
		-- was missing answered neither question and fell straight through.
		local lax_disp = test_state.fault.completion_disp_unchecked
		local restore_required = completion_claimed and disp ~= nil and disp.displaced_state == "file"
		if completion_claimed and not lax_disp then
			-- THE DISPLACED RECORD, WHOLE, BEFORE ANYTHING IS DECIDED FROM IT.
			--
			-- Silence deciding its own sufficiency is exactly how the resumed `rollback_done`
			-- route reached a `revert_done` with neither row on disk. Absent is conflict, never
			-- fall-through.
			if type(disp) ~= "table" then
				return false,
					path
						.. ": this rollback claims a completion and the diary records nothing it displaced, so recovery"
						.. " cannot say what the completion is supposed to have restored — refusing; nothing was changed"
			end
			local ok_disp, disp_err = displaced_record_complete(disp)
			if not ok_disp then
				return false, disp_err
			end
			-- Recovery indexes these rows by operation. A complete record of some
			-- OTHER operation's displacement decides this completion against the wrong
			-- object, which is a journal that does not mean what the index assumed.
			if disp.op_id ~= op.op_id or disp.path ~= op.path then
				return false,
					path
						.. ": the displaced record this completion rests on was written for a different operation ("
						.. tostring(disp.op_id)
						.. " at "
						.. tostring(disp.path)
						.. ") — refusing; nothing was changed"
			end
			-- Decided from the VALIDATED state, so "no restore-temp record required"
			-- is something the journal said and not something its silence allowed.
			restore_required = disp.displaced_state == "file"
		end
		if restore_required and not restore_record_complete(restored, op) then
			return false,
				path
					.. ": this rollback claims a completed file restore and the record of the object it installed is"
					.. " missing or incomplete, so recovery cannot recognise its own output — refusing; nothing was"
					.. " changed"
		end
		return true
	end

	--- APPEND A COMPLETION ROW. THE ONLY PLACE EITHER KIND IS APPENDED.
	---
	--- The gate above was in front of every route recovery could take and in front
	--- of none of the routes that WRITE. A fresh automatic rollback appended
	--- `rollback_done` from inside the restore, a fresh user revert appended
	--- `revert_done` straight after it, and each recovery branch appended its own —
	--- five appenders, one gate, and "every completion is validated" was again a
	--- claim about the code rather than a property of it.
	---
	--- So the appender and the gate are one function. A completion row exists only
	--- because this returned true, and this returns true only for a marker that
	--- names its operation, its purpose from the enum, the object it checked, and —
	--- for a file restore — the object the applier installed. A completion is always
	--- claimed here: something is about to assert one on disk.
	---
	--- The refusal is the caller's to report. On a fresh rollback it aborts the
	--- rollback; on recovery it becomes the conflict. Either way nothing is
	--- appended: a journal that cannot license a completion comes out unchanged.
	local function record_completion(session, kind, op, path, ctx)
		-- Mutation seam (gate): the pre-fix writers, each branch appending its own
		-- completion row with nothing in front of it.
		if not test_state.fault.completion_writer_bypassed then
			local ok_gate, gate_err =
				rollback_record_complete(ctx.marker, op, path, ctx.disp, ctx.restored, true)
			if not ok_gate then
				return false, gate_err
			end
		end
		local ok, err = append_jsonl(journal_path(session), {
			kind = kind,
			op_id = op.op_id,
			path = op.path,
			ts = os.time(),
		})
		if not ok then
			return false, err
		end
		return fsync_dir(session.diary_dir)
	end

	local function restore_output_present(disp, restored, st, state)
		if disp.displaced_state == "absent" then
			return st.kind == "absent"
		end
		if disp.displaced_state ~= "file" or st.kind ~= "file" or state == nil then
			return false
		end
		-- Classification only.
		if type(restored) ~= "table" then
			return false
		end
		if st.dev ~= restored.temp_dev or st.ino ~= restored.temp_ino then
			return false
		end
		if state.hash ~= restored.restored_hash then
			return false
		end
		if state.hash ~= disp.displaced_hash then
			return false
		end
		return mode_perm(st.mode) == mode_perm(restored.restored_mode)
	end

	--- Finish, or refuse, a rollback that a crash caught mid-flight.
	---
	--- ONE state machine for both purposes, because a crash leaves the same rows either
	--- way and only the marker says which it was. A user revert ends at `revert_done`; an
	--- automatic rollback of a failed accept ends at `rollback_done`, with the accept
	--- undone and no `done` row. Neither is ever routed through the ordinary accept
	--- three-way — that reads the restored pre-accept bytes as "equals old, redo" and
	--- applies the very accept whose verification failed, a second time.
	---
	--- Four outcomes, decided from the markers plus the state on disk, and never
	--- more than one action:
	---
	---
	--- "Still the checked object" is decided against the MARKER's recorded identity,
	--- not against a fresh idea of what the accepted result looked like. A different
	--- inode carrying the same bytes is a conflict: content cannot tell those apart
	--- and `(dev, ino)` can.
	local function complete_rollback(session, op, disp, marker, opts)
		opts = opts or {}
		local path, perr = resolve_target(session.workspace, op.path, op.raw_rel)
		if not path then
			return "failure", perr
		end

		-- THE GATE, ONCE, IN FRONT OF EVERY BRANCH BELOW.
		--
		-- The redo route has no such record and demands none: nothing was installed there,
		-- which is exactly why it is redone.
		local completion_claimed = opts.rollback_done
			or opts.settled
			or (disp ~= nil and disp.displaced_state == "file" and opts.restored ~= nil)
		-- Mutation seam (gate): the pre-fix replay entry, which classified first and
		-- asked what the marker recorded only if it got as far as the restore.
		if not test_state.fault.replay_entry_unvalidated then
			local ok_gate, gate_err =
				rollback_record_complete(marker, op, path, disp, opts.restored, completion_claimed and true or false)
			if not ok_gate then
				return "conflict", gate_err
			end
		end

		-- Never defaulted. The gate above refused any marker that could not say this,
		-- and this reads it through the SAME admitting function rather than taking
		-- the field raw — one enum, one place, both ends.
		local purpose = rollback_purpose(marker and marker.purpose)

		-- The evidence this operation's completions are written against, assembled
		-- once. Every `record_completion` below passes it unchanged.
		local completion_ctx = { marker = marker, disp = disp, restored = opts.restored }

		if opts.settled then
			-- Already finished, and the evidence that says so has just been validated
			-- whole. Counting it appends nothing and touches no file.
			return "reverted"
		end

		if opts.rollback_done then
			-- The restore landed and was verified before `rollback_done` was written.
			-- Only bookkeeping is missing, so this touches no file at all.
			if purpose ~= "revert" then
				return "rolled_back"
			end
			local ok, err = record_completion(session, "revert_done", op, path, completion_ctx)
			if not ok then
				return "failure", err
			end
			return "reverted"
		end

		-- The marker's own record, carried forward into the classification and the
		-- restore below. Rebuilt from nothing the gate did not already prove.
		local checked = {
			kind = marker and marker.checked_type,
			dev = marker and marker.checked_dev,
			ino = marker and marker.checked_ino,
			hash = marker and marker.checked_hash,
		}

		if not disp or not disp.displaced_path then
			return "failure", "no displaced copy recorded for " .. tostring(op.op_id)
		end

		-- Observed without insisting the object be readable: an automatic rollback
		-- exists precisely because the applier could not read what it had just
		-- written, and refusing to recover that would strand it for ever.
		local st = identity_of(path)
		local state = nil
		if st.kind == "absent" then
			state = { kind = "absent" }
		elseif st.kind == "file" then
			local content = read_bytes(path)
			if content ~= nil then
				state = { kind = "file", hash = hash_bytes(content), mode = st.mode, dev = st.dev, ino = st.ino }
			end
		end

		local already
		if test_state.fault.restored_by_bytes then
			-- Mutation seam (gate): the pre-fix classifier — the displaced state and
			-- its fingerprint, with no idea which object carries them.
			already = state ~= nil and displaced_state_present(disp, state)
		else
			already = restore_output_present(disp, opts.restored, st, state)
		end
		if already then
			local ok, err = record_completion(session, "rollback_done", op, path, completion_ctx)
			if not ok then
				return "failure", err
			end
			if purpose ~= "revert" then
				return "rolled_back"
			end
			ok, err = record_completion(session, "revert_done", op, path, completion_ctx)
			if not ok then
				return "failure", err
			end
			return "reverted"
		end

		local licensed = false
		if test_state.fault.revert_identity_blind then
			-- Mutation seam (gate): the pre-fix test, which asked only whether the
			-- bytes at the path were the accepted result's. A different inode holding
			-- those bytes answered yes.
			licensed = state ~= nil and accepted_state_for_revert(op, state)
		elseif marker and marker.checked_type then
			licensed = st.kind == marker.checked_type
				and (
					st.kind == "absent"
					or (
						marker.checked_dev ~= nil
						and marker.checked_ino ~= nil
						and st.dev == marker.checked_dev
						and st.ino == marker.checked_ino
					)
				)
				-- MANDATORY EQUALITY, NOT AN OPTIONAL ONE. Entry validation above has
				-- already refused any file marker without a fingerprint, so there is no
				-- hashless marker left here to accommodate; a nil that still arrived
				-- would name bytes nobody checked, and treating it as agreement is
				-- precisely how an in-place human save passed for the checked object.
				-- A restored absence compares nil to nil and needs no special case.
				and (
					(state ~= nil and state.hash == marker.checked_hash)
					-- Mutation seam (gate): the pre-fix classifier, the other half of the
					-- pre-fix marker — the fingerprint was optional to record, and a
					-- marker that lacked one compared equal to whatever it found.
					or (test_state.fault.rollback_marker_no_hash and marker.checked_hash == nil)
				)
		end
		if not licensed then
			local seen = state or { kind = st.kind }
			if purpose == "revert" then
				return "conflict", revert_refusal_message(op, path, seen)
			end
			return "conflict",
				path
					.. ": the rollback of this failed accept cannot be completed — the path no longer holds the object it"
					.. " was licensed against, so it is left exactly as found and the retained copy stays in the diary"
		end

		if not opts.apply_pending then
			return "pending"
		end

		local restore_op = {
			op_id = op.op_id,
			path = op.path,
			displaced_state = disp.displaced_state,
			displaced_hash = disp.displaced_hash,
			displaced_mode = disp.displaced_mode,
		}
		local ok, rerr, restored = journaled_restore(session, restore_op, disp.displaced_path, path, "rollback recovery after crash", {
			accepted_op = purpose == "revert" and op or nil,
			purpose = purpose,
			-- THE MARKER'S RECORD, AND ONLY IT. They agree — `licensed` above is exactly that
			-- agreement — and carrying the marker's own fields forward keeps the licence and the
			-- last-instant check anchored to one recorded object rather than to two separate
			-- looks at the path. Nothing is filled in from this observation: a field the marker
			-- lacks is a field nobody checked, and replay inventing it from what it finds now
			-- would make the rollback license itself against the state it is meant to refuse.
			checked = checked,
		})
		if not ok then
			return "failure", rerr
		end
		if purpose ~= "revert" then
			return "rolled_back"
		end
		-- The restore that just ran installed a NEW object and recorded it; the
		-- completion is written against THAT record, not against the one this replay
		-- entered with — which, on the redo route, is the record of nothing.
		ok, rerr = record_completion(session, "revert_done", op, path, {
			marker = marker,
			disp = disp,
			restored = restored,
		})
		if not ok then
			return "failure", rerr
		end
		return "reverted"
	end

	return {
		record_completion = record_completion,
		complete_rollback = complete_rollback,
	}
end

return M
