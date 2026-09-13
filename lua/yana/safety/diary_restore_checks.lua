-- Same names, same behaviour, moved verbatim.
--
-- Pure classifiers and one journal writer (`record_intent`) that decide
-- whether a rollback/revert marker, a displaced record, or a restore-temp
-- record is complete enough to license a restore. No group elsewhere in
-- diary.lua depends on THESE beyond calling them; they depend only on the
-- diary_fs base layer and diary_state's `valid_mode`.
local M = {}

function M.new(deps)
	local uv = deps.uv
	local check_cap = deps.check_cap
	local append_jsonl = deps.append_jsonl
	local journal_path = deps.journal_path
	local hash_bytes = deps.hash_bytes
	local read_bytes = deps.read_bytes
	local valid_mode = deps.valid_mode
	-- Live reference (not a copy): a test that mutates
	-- `diary._test.fault.x` at runtime is still seen here.
	local test_state = deps.test_state

	local function record_intent(session, op)
		-- A deletion stores no target bytes, but it does retain the whole displaced
		-- file in the diary, so the cap must account for the file being removed.
		local extra = #op.target + 256
		if op.op_kind == "delete" then
			local st = uv.fs_lstat(op.path)
			extra = (st and st.size or 0) + 256
		end
		local ok, err = check_cap(session, extra)
		if not ok then
			return false, err
		end
		op.kind = "intent"
		op.ts = os.time()
		return append_jsonl(journal_path(session), op)
	end

	local function chmod_temp(tmp, target_mode, path)
		if not target_mode then
			return true
		end
		local ok, err = uv.fs_chmod(tmp, target_mode)
		if not ok then
			return false, "could not preserve mode before rename: " .. tostring(err)
		end
		local st = uv.fs_stat(tmp)
		if not st or (st.mode % 4096) ~= (target_mode % 4096) then
			return false, "mode preservation failed before rename for " .. path
		end
		return true
	end

	--- THE PURPOSE ENUM, AND THE ONE PLACE A VALUE IS ADMITTED TO IT.
	---
	--- `rollback_start` carries "auto" and `revert_start` carries "revert". A record that
	--- says neither is not a record with a default: it is a record that cannot say whether
	--- the accept it undoes was ever meant to stand.
	---
	--- One admitting function, used by the writer and by the gate alike, so the
	--- enum cannot be enforced in one place and defaulted in the other.
	local ROLLBACK_PURPOSES = { revert = true, auto = true }

	local function rollback_purpose(purpose)
		if ROLLBACK_PURPOSES[purpose] then
			return purpose
		end
		-- Mutation seam (gate): the pre-fix default, at both ends at once — a caller
		-- that named no purpose and a marker that recorded none were each read as a
		-- user revert, and the revert route completed on them.
		if test_state.fault.gate_purpose_defaulted then
			return "revert"
		end
		return nil
	end

	local function accepted_state_for_revert(op, state)
		if op.op_kind == "delete" then
			return state.kind == "absent"
		end
		if state.kind ~= "file" then
			return false
		end
		return state.hash == hash_bytes(op.target)
	end

	local function revert_refusal_message(op, path, state)
		if op.op_kind == "delete" then
			return path
				.. ": revert expected this accepted deletion to have removed the file, but something is present now"
				.. " — refusing; both versions are kept"
		end
		if state.kind ~= "file" then
			return path
				.. ": revert expected the accepted result's bytes at this path, but found a "
				.. tostring(state.kind)
				.. " — refusing; both versions are kept"
		end
		return path
			.. ": this file no longer holds the accepted result's bytes — refusing revert; both versions are kept"
	end

	--- Is the diary's record of what this operation displaced complete?
	---
	--- The record, not the copy. A rollback that cannot say WHAT it is restoring — absence
	--- or a file, with which fingerprint, at which mode — is not a rollback, it is a write
	--- of unexplained bytes over the human's current file. Each field is required because
	--- the restore uses it: the tag decides unlink versus rename, the fingerprint is the
	--- only proof the retained bytes are the ones this operation displaced, and the mode
	--- is what a restored file is set to.
	local function displaced_record_complete(op)
		local tag = op.displaced_state
		if tag == "link" then
			return false,
				tostring(op.path)
					.. ": the diary records a symlink as this operation's displaced state, and the applier cannot restore"
					.. " a symlink — it would write a regular file over it. Refusing rollback by name; nothing was changed,"
					.. " and the retained copy is in the diary"
		end
		if tag ~= "absent" and tag ~= "file" then
			return false,
				tostring(op.path)
					.. ": the diary records no valid displaced state for this operation (found "
					.. tostring(tag)
					.. "), so what it displaced is unknown — refusing rollback by name; nothing was changed"
		end
		if type(op.displaced_hash) ~= "string" or #op.displaced_hash ~= 64 or not op.displaced_hash:match("^%x+$") then
			return false,
				tostring(op.path)
					.. ": the diary records no usable fingerprint for the displaced copy, so it cannot be proven intact"
					.. " — refusing rollback by name; nothing was changed"
		end
		if tag == "file" and not valid_mode(op.displaced_mode) then
			return false,
				tostring(op.path)
					.. ": the diary records a displaced file whose mode is not a mode this applier can set (found "
					.. tostring(op.displaced_mode)
					.. "), so restoring it would invent permissions"
					.. " — refusing rollback by name; nothing was changed"
		end
		return true
	end

	--- Verify the displaced copy is a complete, intact record of what this
	--- operation displaced — BEFORE any rollback row is written and before the
	--- target is touched at all.
	---
	--- Fails closed in every direction: an incomplete journal record, a displaced object
	--- that is not a regular file, one that cannot be read, and one whose bytes do not
	--- hash to the recorded fingerprint.
	local function verify_displaced_copy(displaced_path, op)
		-- Mutation seam (gate): the pre-fix laxness — existence only, hash compared
		-- only when one happens to be recorded.
		local lax = test_state.fault.accept_incomplete_displaced
		if not lax then
			local ok_rec, rec_err = displaced_record_complete(op)
			if not ok_rec then
				return false, nil, rec_err
			end
		end
		local st = uv.fs_lstat(displaced_path)
		if st == nil then
			return false, nil, "displaced copy missing for rollback"
		end
		if st.type ~= "file" and not lax then
			return false,
				nil,
				"the retained copy for this rollback is a "
					.. tostring(st.type)
					.. ", not a regular file — refusing rollback by name; nothing was changed"
		end
		local content, rerr = read_bytes(displaced_path)
		if content == nil then
			return false, nil, rerr or "displaced copy unreadable for rollback"
		end
		local actual = hash_bytes(content)
		if not test_state.fault.skip_displaced_hash_check then
			if op.displaced_hash and actual ~= op.displaced_hash then
				return false, nil, "displaced copy is corrupted or stale — refusing rollback by name"
			end
		end
		return true, content, op.displaced_hash or actual
	end

	--- Is a rollback marker's record of the object it checked COMPLETE?
	---
	--- Every field, and for an automatic rollback no less than for a user revert. Identity
	--- alone licenses a restore over an IN-PLACE human save: a shell redirect, an editor
	--- that writes through the same inode, any writer that opens and truncates, all keep
	--- `(dev, ino)` while replacing every byte. The marker's own fingerprint is the only
	--- thing that separates "the object this applier installed, untouched" from "that same
	--- inode, since rewritten by the human".
	local function checked_record_complete(checked, path)
		local kind = checked and checked.kind
		if kind ~= "absent" and kind ~= "file" then
			return false,
				path
					.. ": the marker licensing this rollback records no restorable state for the object it checked (found "
					.. tostring(kind)
					.. ") — refusing; nothing was changed"
		end
		if kind == "absent" then
			return true
		end
		if type(checked.dev) ~= "number" or type(checked.ino) ~= "number" then
			return false,
				path
					.. ": the marker licensing this rollback records no identity for the object it checked, so a"
					.. " same-bytes substitution cannot be ruled out — refusing; nothing was changed"
		end
		-- Mutation seam (gate): the pre-fix marker, where the content fingerprint was
		-- optional and an automatic rollback never carried one at all.
		if test_state.fault.rollback_marker_no_hash then
			return true
		end
		if type(checked.hash) ~= "string" or #checked.hash ~= 64 or not checked.hash:match("^%x+$") then
			return false,
				path
					.. ": the marker licensing this rollback records no fingerprint for the object it checked, so a human"
					.. " save that kept the inode cannot be ruled out — refusing; nothing was changed"
		end
		return true
	end

	return {
		record_intent = record_intent,
		chmod_temp = chmod_temp,
		rollback_purpose = rollback_purpose,
		accepted_state_for_revert = accepted_state_for_revert,
		revert_refusal_message = revert_refusal_message,
		displaced_record_complete = displaced_record_complete,
		verify_displaced_copy = verify_displaced_copy,
		checked_record_complete = checked_record_complete,
	}
end

return M
