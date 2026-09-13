-- Same name, same behaviour, same write order, moved verbatim.
--
-- Split out of `diary_apply.lua`'s own extraction rather than left inside
-- it: the applier's refusal/delete/apply helpers were ~720 lines as one
-- file, over the 700 ceiling by themselves. `apply_delete` has exactly one
-- caller (`apply_operation`, in `diary_apply.lua`) and needs exactly one
-- name back from there (`refuse_if_substituted`), so the two files share
-- one shape of `deps` rather than one being nested inside the other.
local M = {}

function M.new(deps)
	local uv = deps.uv
	local diff = deps.diff
	local append_jsonl = deps.append_jsonl
	local journal_path = deps.journal_path
	local fsync_dir = deps.fsync_dir
	local refuse_if_substituted = deps.refuse_if_substituted
	-- Live reference (not a copy): a test that mutates
	-- `diary._test.fault.x` at runtime is still seen here.
	local test_state = deps.test_state

	--- Journaled unlink — the deletion half of the applier.
	---
	--- Same contract as the replacement path below and it must stay that way: the
	--- intent row is already flushed, the displaced copy is already a real copy of
	--- the whole file in the diary, and what remains is act, verify, record.
	---
	--- The one thing that genuinely differs is verification. A replacement verifies
	--- by reading the landed bytes; an unlink verifies by ABSENCE, and absence has
	--- to be decided with lstat rather than a read. read_bytes reports a missing
	--- file and an unreadable-but-present one alike, and a dangling symlink still
	--- occupies the path while reading as gone.
	local function apply_delete(session, op, path, displaced_path, state)
		local dir = vim.fn.fnamemodify(path, ":h")
		session.touched_dirs[dir] = true

		if test_state.fault.skip_unlink then
			return false, "fault: unlink skipped"
		end

		-- THE DURABLE MARKER GOES BEFORE THE ACTION IT LICENSES.
		--
		-- `unlink_done` is written after the unlink, so a crash in the window between
		-- them leaves no record that the applier ever acted. If the path is recreated
		-- with the original bytes in that window, replay cannot tell "never unlinked"
		-- from "unlinked, and someone put a file back" — it reads the old fingerprint
		-- as "still the file we agreed to delete" and deletes the human's new file.
		--
		-- This marker is durable BEFORE the unlink and carries the identity of the
		-- object the check passed on, so replay may redo only while that VERY object
		-- is still at the path. A different object carrying the same bytes is a
		-- terminal conflict, which is the whole point: bytes cannot tell them apart
		-- and `(dev, ino)` can.
		if not test_state.fault.skip_unlink_start_marker then
			local ok_start, start_err = append_jsonl(journal_path(session), {
				kind = "unlink_start",
				op_id = op.op_id,
				path = op.path,
				checked_dev = state.dev,
				checked_ino = state.ino,
				checked_type = state.kind,
				ts = os.time(),
			})
			if not ok_start then
				return false, start_err
			end
			-- LOAD-BEARING, AND NOT FOR THE ROW ABOVE. The marker itself is already durable from
			-- `append_jsonl`'s file fsync. This flush is here for the ENTRY `apply_operation`
			-- created a moment ago: `displaced/` is a new name inside the diary directory, and
			-- `fsync_dir(diary_dir/displaced)` covers what is inside it, never the entry FOR it.
			local ok_sync, sync_err = fsync_dir(session.diary_dir)
			if not ok_sync then
				return false, sync_err
			end
		end

		-- Crash point: the marker is durable and nothing has happened yet. Replay
		-- must find the original object untouched and redo the deletion.
		if test_state.fault.crash_before_unlink then
			session.simulated_crash = op.op_id
			return true
		end

		-- NOTHING BETWEEN THIS CHECK AND THE UNLINK.
		local sub, sub_detail = refuse_if_substituted(session, op, path, state, "generic_pre_apply")
		if sub then
			return false, sub, sub_detail
		end

		local un_ok, un_err = uv.fs_unlink(path)
		if not un_ok then
			return false, tostring(un_err)
		end

		-- Crash point: the object is gone and `unlink_done` is not durable yet.
		if test_state.fault.crash_after_unlink then
			if test_state.inject and test_state.inject.recreate_after_unlink_from then
				-- Renamed in from an object that already existed while the original
				-- did, so its identity provably differs from the freed one. Writing a
				-- fresh file here can be handed the just-released inode number, which
				-- would make the probe describe inode reuse rather than recreation.
				uv.fs_rename(test_state.inject.recreate_after_unlink_from, path)
			elseif test_state.inject and test_state.inject.recreate_after_unlink then
				diff.write_file(path, test_state.inject.recreate_after_unlink)
			end
			session.simulated_crash = op.op_id
			return true
		end

		ok, err = append_jsonl(journal_path(session), {
			kind = "unlink_done",
			op_id = op.op_id,
			path = op.path,
			ts = os.time(),
		})
		if not ok then
			return false, err
		end
		-- NO `fsync_dir(session.diary_dir)` HERE, AND PUTTING ONE BACK BUYS NOTHING.
		--
		-- The row above is already durable: `append_jsonl` fsynced the journal FILE,
		-- and an append changes that file's contents, not the directory entry that
		-- names it. Process crash: durable at `fs_write`. Power loss: durable at that
		-- fsync. A directory fsync defends neither, because nothing about the
		-- directory changed.
		--
		-- The other reason a diary-directory fsync is ever needed here — making the
		-- `displaced/` entry created by `apply_operation` reachable — was already paid by the
		-- `unlink_start` site above, which fsyncs the diary directory BEFORE the unlink,
		-- where the barrier belongs. Between that fsync and this point the only things that
		-- happened were an append to the existing journal and an unlink of a path in the
		-- WORKSPACE — no name in the diary directory was created, so this call had nothing
		--
		-- DO NOT DELETE THE NEIGHBOURS BY ANALOGY. The `unlink_start` fsync above,
		-- `fsync_dir(dir)` below (the unlink is a directory operation and that is
		-- what makes the removal itself durable), `fsync_dir(diary_dir/displaced)`
		-- after the displaced copy, the two in `M.begin`, and the one after the
		-- `done` row of a REPLACE are all load-bearing for a reason this comment does
		-- not cover.

		if test_state.inject and test_state.inject.recreate_after_unlink then
			diff.write_file(path, test_state.inject.recreate_after_unlink)
		end

		if test_state.fault.crash_before_delete_conflict then
			session.simulated_crash = op.op_id
			return true
		end

		ok, err = fsync_dir(dir)
		if not ok then
			return false, err
		end

		if uv.fs_lstat(path) ~= nil then
			-- A REAPPEARING PATH IS A CONFLICT, NOT A ROLLBACK DESTINATION.
			local msg = path
				.. ": the accepted deletion was applied, but this path was recreated immediately afterwards."
				.. " The new file is left untouched and the version this turn removed is kept in the diary"
				.. " (recover it with `yana-apply recover --op "
				.. tostring(op.op_id)
				.. "`). Resolve which one you want before re-running the turn."
			local ok_log, log_err = append_jsonl(journal_path(session), {
				kind = "conflict",
				op_id = op.op_id,
				path = op.path,
				reason = "path recreated after the accepted unlink",
				displaced_path = displaced_path,
				ts = os.time(),
			})
			if not ok_log then
				return false, log_err
			end
			local ok_sync, sync_err = fsync_dir(session.diary_dir)
			if not ok_sync then
				return false, sync_err
			end
			return false, msg
		end

		-- Crash point: the file is gone and fsynced but no `done` row exists yet.
		-- Recovery must read that as already-unlinked and complete it, which is the
		-- case M.replay's delete verdict exists to get right.
		if test_state.fault.crash_before_done then
			session.simulated_crash = op.op_id
			return true
		end

		ok, err = append_jsonl(journal_path(session), {
			kind = "done",
			op_id = op.op_id,
			path = op.path,
			ts = os.time(),
		})
		if not ok then
			return false, err
		end
		-- NO `fsync_dir(session.diary_dir)` HERE EITHER, for the same two reasons.
		--
		-- The `done` row is durable from `append_jsonl`'s file fsync — process crash
		-- and power loss alike — and the `displaced/` entry was made reachable by the
		-- `unlink_start` fsync earlier in this function, before the destructive act
		-- rather than after it. Nothing between the two creates a name in the diary
		-- directory.
		--
		-- The REPLACE path's `done` row is NOT the same case and keeps its fsync:
		-- that path has no pre-action diary-directory fsync at all, so its trailing
		-- one is the only barrier that makes `displaced/` reachable.

		op.applied = true
		return true
	end

	return {
		apply_delete = apply_delete,
	}
end

return M
