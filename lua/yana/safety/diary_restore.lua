-- Same names, same behaviour, same write order, moved verbatim.
--
-- `journaled_restore` is the sole caller of `diff.write_file` for a rollback/revert
-- (tier-1 wrapper; see `S.WRAPPER_ALLOW` in `tests/suite/round5_scan.lua`, same
-- exemption diary.lua itself carries, for the same reason: this IS the journaled
-- applier, moved to its own file). Two more `diff.write_file` call sites here are
-- test-injection seams (`_test.inject.human_save_before_restore` /
-- `..._during_restore_fsync`), simulating a human save mid-restore; they are gated by
local M = {}

function M.new(deps)
	local uv = deps.uv
	local diff = deps.diff
	local checked_record_complete = deps.checked_record_complete
	local chmod_temp = deps.chmod_temp
	local verify_displaced_copy = deps.verify_displaced_copy
	local revert_refusal_message = deps.revert_refusal_message
	local rollback_purpose = deps.rollback_purpose
	local hash_bytes = deps.hash_bytes
	local read_bytes = deps.read_bytes
	local fsync_dir = deps.fsync_dir
	local journal_path = deps.journal_path
	local append_jsonl = deps.append_jsonl
	local write_displaced = deps.write_displaced
	-- record_completion is defined in diary_rollback.lua, instantiated AFTER
	-- this module in the parent (diary_rollback needs nothing from here, so
	-- order does not matter for loading, but the parent wires this as a
	-- plain value since both modules load before either is first CALLED).
	local record_completion = deps.record_completion
	-- Live reference (not a copy): a test that mutates
	-- `diary._test.fault.x` at runtime is still seen here.
	local test_state = deps.test_state

	--- THE RESTORE'S OWN OUTPUT, RECORDED BEFORE ITS RENAME.
	---
	--- A completed rollback is not "the pre-accept bytes are at the path"; it is "the
	--- object THIS applier wrote is at the path". Recovery that classifies by content
	--- alone calls a different inode carrying those bytes a finished rollback — a
	--- checkout, a backup restore or a second tool can put them there — and writes
	--- `rollback_done` over a file it never read. Git draws the same line: it commits the
	--- specific tempfile it created, by renaming THAT inode, not any destination that
	---
	--- Durable BEFORE the rename, so no crash in the window can leave the applier
	--- unable to recognise its own output.
	---
	--- Returns the record it wrote, so the completion this restore is heading for
	--- is validated against the very row on disk rather than against a second,
	--- separately assembled idea of what was installed.
	local function record_restore_temp(session, op, tmp_path, info)
		-- Mutation seam (gate): the pre-fix restore, which installed an object and
		-- went on to claim the completion without ever recording WHICH object it
		-- installed. The completion gate is the only thing that notices.
		if test_state.fault.restore_temp_unrecorded then
			return true, nil
		end
		local st = uv.fs_lstat(tmp_path)
		if test_state.fault.fail_restore_temp_identity then
			st = nil
		end
		if not st or not st.dev or not st.ino then
			return false,
				tostring(op.path)
					.. ": the identity of the file this rollback is about to install could not be recorded, so recovery"
					.. " could not tell it from another object carrying the same bytes — refusing; nothing was changed"
		end
		local record = {
			kind = "restore_temp",
			op_id = op.op_id,
			path = tmp_path,
			target_path = op.path,
			purpose = info.purpose,
			temp_dev = st.dev,
			temp_ino = st.ino,
			restored_state = "file",
			restored_hash = info.hash,
			restored_mode = st.mode,
			ts = os.time(),
		}
		local ok, err = append_jsonl(journal_path(session), record)
		if not ok then
			return false, err
		end
		ok, err = fsync_dir(session.diary_dir)
		if not ok then
			return false, err
		end
		return true, record
	end

	--- THE LAST-INSTANT REVALIDATION OF A RESTORE, AGAINST THE MARKER'S RECORD.
	---
	--- Not a fresh derivation of what "still accepted" means. The marker that licensed
	--- this rollback says which object it checked — `(dev, ino, type)`, plus the
	--- fingerprint where one was known — and this compares the path against THAT.
	---
	--- Content is compared before identity so the ordinary case — the human saved —
	--- is named as itself rather than as a substitution.
	local function refuse_restore_drift(checked, path, accepted_op)
		-- EVERY FIELD, RE-CHECKED HERE TOO. The marker was validated before it was
		-- written; this is the same demand one syscall before the action, so no route
		-- into the rename can arrive with a record that licenses less than it claims.
		local ok_rec, rec_err = checked_record_complete(checked, path)
		if not ok_rec then
			return false, rec_err
		end
		if test_state.inject and test_state.inject.human_save_before_restore then
			diff.write_file(path, test_state.inject.human_save_before_restore)
		end
		local st = uv.fs_lstat(path)
		local kind = st and st.type or "absent"
		if kind ~= checked.kind then
			if accepted_op then
				return false, revert_refusal_message(accepted_op, path, { kind = kind })
			end
			return false,
				path
					.. ": this path holds a "
					.. tostring(kind)
					.. " and the rollback was licensed against a "
					.. tostring(checked.kind)
					.. " — refusing; it is left exactly as found"
		end
		if kind == "absent" then
			return true
		end
		if kind ~= "file" then
			return false,
				path
					.. ": this path is a "
					.. tostring(kind)
					.. ", not a regular file — the applier restores regular files only, so it refuses; nothing was changed"
		end
		-- Mandatory above, so this branch is always taken for a file; only the
		-- mutation seam in `checked_record_complete` can produce a hashless marker,
		-- and skipping the comparison then is exactly the pre-fix behaviour it
		-- reproduces.
		if checked.hash then
			local content, rerr = read_bytes(path)
			if content == nil then
				return false,
					path
						.. ": this file became unreadable after the rollback was licensed ("
						.. tostring(rerr or "unreadable")
						.. ") — refusing; nothing was changed"
			end
			local now = hash_bytes(content)
			if now ~= checked.hash then
				if accepted_op then
					return false, revert_refusal_message(accepted_op, path, { kind = "file", hash = now })
				end
				return false,
					path
						.. ": this file no longer holds the bytes the rollback was licensed against"
						.. " — refusing; both versions are kept"
			end
		end
		if test_state.fault.revert_identity_blind then
			-- Mutation seam (gate): the pre-fix check, content and nothing else, in
			-- the one place the swap is still visible.
			return true
		end
		if checked.dev == nil or checked.ino == nil then
			return false,
				path
					.. ": the marker licensing this rollback records no identity for the object it checked, so a"
					.. " same-bytes substitution cannot be ruled out — refusing; nothing was changed"
		end
		if st.dev ~= checked.dev or st.ino ~= checked.ino then
			return false,
				path
					.. ": this path resolves to a different object than the one the rollback was licensed against"
					.. " — it carries the same bytes but is not the same file; refusing, it is left exactly as found"
		end
		return true
	end

	--- The directory fsync that precedes the last drift check of a restore.
	---
	--- Ordering, not decoration. Durability first, the check last, the rename immediately
	--- after it. The injection below is that save, at exactly the instant the window is
	--- open.
	local function fsync_dir_before_restore(dir, path)
		local ok, err = fsync_dir(dir)
		if not ok then
			return false, err
		end
		if test_state.inject and test_state.inject.human_save_during_restore_fsync then
			diff.write_file(path, test_state.inject.human_save_during_restore_fsync)
		end
		return true
	end

	--- Restore what one operation displaced, through the journal.
	---
	--- `opts.purpose` is the half of the marker state machine that recovery cannot infer
	--- from the rows: a USER REVERT of a completed accept, or the AUTOMATIC rollback of an
	--- accept whose post-rename verification failed. They finish differently — a revert
	--- ends at `revert_done`, an automatic rollback ends at `rollback_done` with the
	--- accept undone and no `done` row ever written — and a crash in either is resolved
	--- from this field. Without it, recovery fell through to the ordinary accept
	---
	--- `opts.checked` is the object this rollback was licensed against. The caller
	--- supplies it when it has already observed the target (a revert has, and its
	--- observation is what licensed the revert at all); otherwise it is observed
	--- here, before the marker is written, so the marker records what was checked
	--- rather than what a later reader happens to find.
	---
	--- Returns `true, nil, restore_record` on success: the record of the object it
	--- installed, so a caller finishing a user revert on top of this restore passes
	--- the completion gate the same evidence this function did.
	local function journaled_restore(session, op, displaced_path, path, reason, opts)
		opts = opts or {}
		local accepted_op = opts.accepted_op

		-- THE PURPOSE, BEFORE ANY JOURNAL MUTATION AND BEFORE THE TARGET IS TOUCHED.
		--
		-- Every caller happening to pass one is a property of today's call sites, not of the
		-- marker; the marker is the only thing a later process has, so it is the marker that
		-- must be refused when it cannot say this.
		local purpose = rollback_purpose(opts.purpose)
		if not purpose then
			return false,
				path
					.. ": this rollback was requested with no purpose it could be recovered under (found "
					.. tostring(opts.purpose)
					.. "), so a later process could not tell a user revert from the rollback of a failed accept —"
					.. " refusing; nothing was changed"
		end

		-- COMPLETE, INTACT DISPLACED RECORD FIRST — before a single rollback row is
		-- written and before the target is touched. A rollback that cannot prove what
		-- it holds must leave no trace of having started one.
		local ok_copy, content, copy_info = verify_displaced_copy(displaced_path, op)
		if not ok_copy then
			return false, copy_info
		end
		local expected = copy_info

		-- THE CALLER'S OWN CHECK, AND NOTHING ELSE FILLS IT IN.
		--
		-- Evidence flows from what was checked into the marker, never back from a
		-- later look at the path. An identity observed HERE describes whatever is at
		-- the target now — including a human save that landed since the action this
		-- rollback undoes — and recording that as "what was checked" makes the marker
		-- license the very write it exists to refuse. A caller that cannot say what
		-- it checked cannot have a rollback row written for it.
		local checked = opts.checked
		local ok_chk, chk_err = checked_record_complete(checked, path)
		if not ok_chk then
			return false, chk_err
		end

		-- The marker is kept, not just written: the completion at the far end of this
		-- function is gated on THIS record, the one that licensed the action, rather
		-- than on a second look at anything.
		local marker = {
			kind = "rollback_start",
			op_id = op.op_id,
			path = op.path,
			purpose = purpose,
			reason = reason,
			displaced_path = displaced_path,
			displaced_state = op.displaced_state,
			displaced_hash = op.displaced_hash,
			-- WHAT WAS CHECKED, not what is there. The revalidation one syscall
			-- before the action compares against these fields, and so does recovery
			-- after a crash.
			checked_type = checked.kind,
			checked_dev = checked.dev,
			checked_ino = checked.ino,
			checked_hash = checked.hash,
			ts = os.time(),
		}
		local ok, err = append_jsonl(journal_path(session), marker)
		if not ok then
			return false, err
		end
		ok, err = fsync_dir(session.diary_dir)
		if not ok then
			return false, err
		end

		-- Crash point: the marker is durable, with its purpose and the identity it
		-- checked, and nothing has been restored yet. Recovery must finish THIS
		-- rollback and never route the operation through the accept three-way.
		if test_state.fault.crash_after_rollback_start then
			session.simulated_crash = op.op_id
			return false, "simulated crash after rollback_start"
		end

		-- ABSENCE IS RESTORED AS ABSENCE. For an agent-created path the displaced
		-- copy is empty because there was nothing to displace, and writing it back
		-- would leave a zero-byte file where the human had no file at all — the
		-- rollback inventing the very state review-apply promises an open review
		-- never creates. The undo of "we created this file" is an unlink.
		--
		-- Nothing is destroyed unwitnessed on the way: whatever is at the path is
		-- read and retained in the diary first, so both versions survive the
		-- rollback exactly as CORE requires. An object that cannot be read or is not
		-- a regular file is left exactly as found and the refusal names it — the
		-- applier will not remove what it could not copy.
		if op.displaced_state == "absent" then
			local now = uv.fs_lstat(path)
			if now then
				if now.type ~= "file" then
					return false,
						path
							.. ": rollback expected the file this accept created and found a "
							.. tostring(now.type)
							.. "; it is left exactly as found"
				end
				local found, ferr = read_bytes(path)
				if found == nil then
					return false,
						path
							.. ": rollback could not read the object at this path ("
							.. tostring(ferr or "unreadable")
							.. "), so it will not be removed; it is left exactly as found"
				end
				local kept = displaced_path .. ".rollback-found"

				-- THE RETAINED COPY IS DURABLE BEFORE THE UNLINK, AND SO IS ITS DIRECTORY ENTRY.
				-- Copy, then its directory, then the row that claims both, then the check, then the
				-- removal.
				local function retain_found()
					local keep_ok, keep_err = write_displaced(kept, found)
					if not keep_ok then
						return false, keep_err
					end
					local sync_ok, sync_err
					if test_state.fault.fail_retained_dir_fsync then
						sync_ok, sync_err = false, "injected retained-copy directory fsync failure"
					else
						sync_ok, sync_err = fsync_dir(vim.fn.fnamemodify(kept, ":h"))
					end
					if not sync_ok then
						return false,
							path
								.. ": the copy of the file this rollback is about to remove could not be made durable ("
								.. tostring(sync_err)
								.. ") — refusing to remove it; nothing was changed"
					end
					return append_jsonl(journal_path(session), {
						kind = "rollback_found",
						op_id = op.op_id,
						path = op.path,
						kept_path = kept,
						kept_hash = hash_bytes(found),
						bytes = #found,
						-- The identity of the object retained, so recovery can tell
						-- this copy from one of some later occupant of the path.
						found_dev = now.dev,
						found_ino = now.ino,
						ts = os.time(),
					})
				end

				-- Mutation seam (gate): the pre-fix ordering, where the object was
				-- removed first and the record of what it had been was written
				-- afterwards.
				local retain_late = test_state.fault.retain_after_unlink
				if not retain_late then
					local keep_ok, keep_err = retain_found()
					if not keep_ok then
						return false, keep_err
					end
					-- Crash point: the retained copy and its row are durable and the
					-- object is still there. Nothing is lost either way.
					if test_state.fault.crash_after_rollback_found then
						session.simulated_crash = op.op_id
						return false, "simulated crash between the retained copy and the unlink"
					end
				end
				local drift_ok, drift_err = refuse_restore_drift(checked, path, accepted_op)
				if not drift_ok then
					return false, drift_err
				end
				local un_ok, un_err = uv.fs_unlink(path)
				if not un_ok then
					return false, tostring(un_err)
				end
				if retain_late then
					-- Same gap, moved: under the mutation the crash lands between the
					-- removal and the record of what was removed.
					if test_state.fault.crash_after_rollback_found then
						session.simulated_crash = op.op_id
						return false, "simulated crash between the retained copy and the unlink"
					end
					local keep_ok, keep_err = retain_found()
					if not keep_ok then
						return false, keep_err
					end
				end
			end
			ok, err = fsync_dir(vim.fn.fnamemodify(path, ":h"))
			if not ok then
				return false, err
			end
			if uv.fs_lstat(path) ~= nil then
				return false, "rollback verify failed: " .. path .. " still exists"
			end
			return record_completion(session, "rollback_done", op, path, {
				marker = marker,
				-- The restore op carries the displaced record's own fields, and the
				-- gate reads `displaced_state` from it to decide whether a restore-temp
				-- record is required. A restored absence installs no object and has
				-- none to name.
				disp = op,
			})
		end

		local target_mode = op.displaced_mode
		if not target_mode then
			local st = uv.fs_stat(path)
			if st and st.mode then
				target_mode = st.mode
			end
		end

		-- One unique O_EXCL sibling temp, and the rename installs THAT inode.
		-- `diff.write_file` owns that temp-and-rename sequence already; the hooks below keep
		-- the mode check and the pre-rename directory fsync this path had.
		local dir = vim.fn.fnamemodify(path, ":h")
		local restored_record
		local ren_ok, ren_err = diff.write_file(path, content, {
			on_temp_created = function(tmp)
				local ok_mode, mode_err = chmod_temp(tmp, target_mode, path)
				if not ok_mode then
					return false, mode_err
				end
				-- The mode is final, so the marker describes the object exactly as the
				-- rename is about to install it. The record is kept as well as written:
				-- the completion below is gated on it.
				local ok_tmp, rec = record_restore_temp(session, op, tmp, {
					purpose = purpose,
					hash = expected,
				})
				if not ok_tmp then
					return false, rec
				end
				restored_record = rec
				return true
			end,
			on_before_rename = function()
				-- Mutation seam (gate): the pre-fix order, where the blocking
				-- directory fsync ran AFTER the check that licenses the rename.
				if test_state.fault.restore_fsync_after_revalidate then
					local drift_ok, drift_err = refuse_restore_drift(checked, path, accepted_op)
					if not drift_ok then
						return false, drift_err
					end
					return fsync_dir_before_restore(dir, path)
				end
				-- Durability first...
				local sync_ok, sync_err = fsync_dir_before_restore(dir, path)
				if not sync_ok then
					return false, sync_err
				end
				-- ...then the revalidation, with the rename the very next operation.
				local drift_ok, drift_err = refuse_restore_drift(checked, path, accepted_op)
				if not drift_ok then
					return false, drift_err
				end
				return true
			end,
		})
		if not ren_ok then
			return false, tostring(ren_err)
		end

		ok, err = fsync_dir(dir)
		if not ok then
			return false, err
		end

		local landed, lerr = read_bytes(path)
		if landed == nil then
			return false, lerr
		end
		if hash_bytes(landed) ~= expected then
			return false, "rollback verify failed"
		end

		-- Crash point: the restore landed and was verified, and `rollback_done` is
		-- not durable yet. Disk holds the PRE-ACCEPT bytes, which the accept
		-- three-way reads as "equals old, redo" — the failed accept applied a second
		-- time. Recovery must recognise this rollback instead.
		if test_state.fault.crash_before_rollback_done then
			session.simulated_crash = op.op_id
			return false, "simulated crash before rollback_done"
		end

		local done_ok, done_err = record_completion(session, "rollback_done", op, path, {
			marker = marker,
			disp = op,
			restored = restored_record,
		})
		if not done_ok then
			return false, done_err
		end
		return true, nil, restored_record
	end

	return {
		journaled_restore = journaled_restore,
	}
end

return M
