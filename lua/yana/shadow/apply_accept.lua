-- Reconcile-and-accept core of the shadow accept pass; apply.lua's facade
-- re-exports it.
local M = {}

-- The facade overwrites this with apply.lua's own `M._test`, so an injected
-- fault reaches the reads below.
M._test = { inject = {}, fault = {} }

local diary = require("yana.safety.diary")
local diff = require("yana.diff")
local log = require("yana.log")
local hash = require("yana.safety.hash")
local apply_sessions = require("yana.shadow.apply_sessions")

--- Did this one path move between the applier's write and the buffer reconcile?
--- Size, mode, inode, mtime, ctime at nanosecond resolution.
local function stat_unmoved(a, b)
	if not a or not b then
		return false
	end
	local am, bm = a.mtime or {}, b.mtime or {}
	local ac, bc = a.ctime or {}, b.ctime or {}
	return a.size == b.size
		and a.mode == b.mode
		and a.ino == b.ino
		and am.sec == bm.sec
		and am.nsec == bm.nsec
		and ac.sec == bc.sec
		and ac.nsec == bc.nsec
end

--- Bring the review buffer for a just-applied path back in step with the file
--- the applier wrote, so a stale mtime cannot raise the BLOCKING W12/W13
--- changed-on-disk dialog on the next `checktime`. Called per file; disk ->
--- buffer only, so the diary stays the sole real-tree writer.
---
--- `own_splice(bufnr, fn)` comes from the accept caller and carries EVERY
--- buffer replacement below; absent, they splice plain.
function M.reconcile_applied_buffer(applied, own_splice)
	if not applied or applied.kind ~= "replace" then
		-- Nothing to reconcile against, and a vanished file is the
		-- non-blocking E211 message, never a dialog.
		return true
	end
	local bufnr = vim.fn.bufnr(applied.path, false)
	if bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
		return true
	end
	local uv = vim.uv or vim.loop
	local now = uv.fs_stat(applied.path)
	if not applied.stat or not now then
		return false, "the applied file could not be stat-ed; the buffer was left unreconciled"
	end
	if not stat_unmoved(applied.stat, now) then
		return false, "the file moved on disk after the applier wrote it; the buffer was left unreconciled"
	end

	local tick_pinned = vim.api.nvim_buf_get_changedtick(bufnr)

	-- THE UNSAVED-EDITS GUARD. A modified buffer matching `applied.base_hash`
	-- (the pre-turn file), `applied.target_hash` (the turn's own result) or
	-- `applied.staged_hash` (the exact proposal this review had painted, pinned
	-- by the caller before its claim) loses nothing by replacement. Matching
	-- NONE of them is an independent human edit: refuse, leaving disk accepted
	-- and their bytes untouched. A caller carrying no fingerprint at all
	-- reconciles unconditionally.
	--
	-- `staged_hash` is why a turn-exit reconcile is possible at all. At End the
	-- review buffer is SUPPOSED to differ from both disk fingerprints -- it
	-- still shows the proposal -- so without it every End with a visible hunk
	-- was refused as a human edit that never happened. It is a third exact
	-- value, not a relaxation: the buffer is re-read here, AFTER the claim, and
	-- an edit made since the pin does not match it.
	-- A PINNED TURN BUFFER IS JUDGED BY ITS PIN, AND ONLY BY ITS PIN. When the
	-- caller supplied `staged_tick` this is a turn-exit reconcile of one exact
	-- buffer, so the edit counter must still be that one. Matching bytes are
	-- not enough (changed during the claim wait and put back) and the generic
	-- base-hash allowance must not rescue it either: a deliberate return to the
	-- pre-turn text during the wait is a new action, not permission to
	-- overwrite. Refuse, and leave the buffer and its tick exactly as they are.
	if applied.staged_tick ~= nil and not (M._test.fault and M._test.fault.skip_unsaved_guard) then
		local live_tick = vim.api.nvim_buf_get_changedtick(bufnr)
		if live_tick ~= applied.staged_tick then
			return false,
				"the buffer has unsaved edits of its own; disk was updated with the accepted change "
					.. "but the buffer was left untouched so your edits are not lost -- save or discard them, "
					.. "then reload to see the accepted change"
		end
		local snap = diff.buffer_bytes_snapshot(bufnr)
		if snap == nil or hash.hash_bytes(snap) ~= applied.staged_hash then
			return false,
				"the review buffer no longer matches the proposal this turn pinned; "
					.. "the buffer was left untouched"
		end
	elseif
		vim.bo[bufnr].modified
		and (applied.base_hash or applied.target_hash or applied.staged_hash)
		and not (M._test.fault and M._test.fault.skip_unsaved_guard)
	then
		local snap, snap_err = diff.buffer_bytes_snapshot(bufnr)
		if snap == nil then
			return false,
				"the buffer has unsaved edits that could not be read to check against the accepted change: "
					.. tostring(snap_err)
					.. "; the buffer was left untouched"
		end
		local snap_hash = hash.hash_bytes(snap)
		if
			snap_hash ~= applied.base_hash
			and snap_hash ~= applied.target_hash
			and snap_hash ~= applied.staged_hash
		then
			return false,
				"the buffer has unsaved edits of its own; disk was updated with the accepted change but the buffer was left untouched so your edits are not lost -- save or discard them, then reload to see the accepted change"
		end
	end

	local views = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == bufnr then
			local vok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
			if vok then
				views[win] = view
			end
		end
	end

	-- One undo-atomic edit installing bytes disk already holds.
	local disk, derr = diff.read_file_bytes(applied.path)
	if disk == nil then
		return false, tostring(derr or "the applied file could not be read for buffer reconcile")
	end

	if M._test.inject and M._test.inject.disk_write_after_stat then
		diff.write_file(applied.path, M._test.inject.disk_write_after_stat)
	end

	local now_after_read = uv.fs_stat(applied.path)
	if not applied.stat or not now_after_read or not stat_unmoved(applied.stat, now_after_read) then
		return false, "the file moved on disk during buffer reconcile; the buffer was left unreconciled"
	end

	if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick_pinned then
		return false, "the review buffer changed during reconcile; the buffer was left unreconciled"
	end

	-- Disk can move while the buffer is replaced: mutate first, observe after.
	if M._test.inject and M._test.inject.disk_write_after_second_stat then
		diff.write_file(applied.path, M._test.inject.disk_write_after_second_stat)
	end

	local wants_eol = disk:match("\n$") ~= nil
	local verified_lines = vim.split(disk, "\n", { plain = true })
	if disk:sub(-1, -1) == "\n" and #verified_lines > 0 and verified_lines[#verified_lines] == "" then
		table.remove(verified_lines)
	elseif disk == "" then
		verified_lines = {}
	end
	-- THE ONE WAY THE VERIFIED BYTES ENTER THE BUFFER: yana's own splice, not a
	-- human edit; both replacements below owe the review the same door.
	local function own_replacement()
		local replace = function()
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, verified_lines)
		end
		if type(own_splice) == "function" then
			own_splice(bufnr, replace)
		else
			replace()
		end
	end
	local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
		-- `:undojoin` acts on the CURRENT buffer, so this injection must sit
		-- inside the `nvim_buf_call` or it joins the wrong undo tree.
		if M._test.fault and M._test.fault.force_undojoin then
			vim.cmd("keepjumps silent! undojoin")
		end
		own_replacement()
		vim.bo[bufnr].fixendofline = wants_eol
		vim.bo[bufnr].endofline = wants_eol
	end)

	for win, view in pairs(views) do
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_call, win, function()
				vim.fn.winrestview(view)
			end)
		end
	end

	if not ok then
		return false, tostring(err)
	end

	-- THE AGREEMENT IS PROVEN AFTER THE MUTATION, AGAINST CURRENT DISK: the
	-- earlier stat and read say what the buffer was built FROM, not what the
	-- file is now. A refusal leaves the buffer modified, prompt armed.
	local skip_final = M._test.fault and M._test.fault.reconcile_skip_final_verify
	local buf_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	if wants_eol then
		buf_text = buf_text .. "\n"
	end
	if not skip_final then
		local final_stat = uv.fs_stat(applied.path)
		if not final_stat or not stat_unmoved(applied.stat, final_stat) then
			return false, "the file moved on disk while the buffer was reconciled; the buffer was left modified"
		end
		local final_disk, ferr = diff.read_file_bytes(applied.path)
		if final_disk == nil then
			return false, tostring(ferr or "the applied file could not be re-read to confirm the buffer matches it")
		end
		if buf_text ~= final_disk then
			return false, "the reconciled buffer does not match the file on disk; the buffer was left modified"
		end
	elseif buf_text ~= disk then
		return false, "buffer bytes diverged from disk before clearing modified"
	end

	vim.bo[bufnr].modified = false
	-- Re-stamp the buffer's view of the file mtime: bytes already match disk,
	-- only the stamp is stale. EVERY event is ignored across it -- 'autoread'
	-- sends `:checktime` down its silent-reload branch, which would otherwise
	-- run yana's own review autocmds.
	local ei = vim.o.eventignore
	vim.o.eventignore = "all"
	pcall(vim.cmd, "silent! checktime " .. bufnr)
	vim.o.eventignore = ei

	-- THE RESTAMP IS NOT ALLOWED TO MOVE THE BYTES: a buffer disagreeing with
	-- disk while flagged clean is what clearing `modified` promises against.
	-- Prove it again, repair by re-splicing, refuse if that fails.
	local restamped = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	if wants_eol then
		restamped = restamped .. "\n"
	end
	if restamped ~= buf_text then
		local repaired = pcall(own_replacement)
		if not repaired then
			return false, "the buffer was reloaded away from the file during the mtime restamp"
		end
		vim.bo[bufnr].modified = false
	end

	if vim.bo[bufnr].modified then
		return false, "the review buffer is still flagged modified after reload"
	end
	return true
end

--- THE EXPLICIT WRITE DESCRIPTION both accept routes consume:
--- `{action, bytes, mode, purpose, preserve_review}`. `turn.turn_projection`
--- is the ONE calculation of final bytes, existence and mode; this only
--- NORMALISES it, never reading `change.kind` or `change.after_mode`.
--- `opts.projection`'s `mode` is the ONLY thing that can authorise a
--- permission change; a bare `composed` keeps the original mode.
function M.write_plan(change, composed, opts)
	if type(change) ~= "table" then
		return nil, "an accept needs a change record"
	end
	local supplied = opts and opts.projection
	if type(supplied) == "table" then
		local action = supplied.action
		if action ~= "replace" and action ~= "delete" and action ~= "none" then
			return nil, "projection action must be replace, delete or none, got " .. tostring(action)
		end
		local bytes = ""
		if action == "replace" then
			bytes = supplied.bytes
			if type(bytes) ~= "string" then
				return nil, "projection action replace carries no bytes for " .. tostring(change.path)
			end
		end
		return {
			action = action,
			bytes = bytes,
			mode = supplied.mode,
			purpose = supplied.purpose,
			preserve_review = supplied.preserve_review == true,
		}
	end
	return {
		action = composed == nil and "delete" or "replace",
		bytes = composed or "",
		mode = change.base_mode,
		purpose = nil,
		preserve_review = false,
	}
end

local function accept_preflight(pass, change)
	-- Detail from a PREVIOUS attempt: a refusal is labelled only by evidence
	-- this attempt gathered.
	change.shadow_refusal = nil
	-- THE DRIFT EVIDENCE, per touched path (CORE): a human-changed target is
	-- refused by name, detected by content fingerprint read immediately before
	-- the write. `change.base_hash` is that fingerprint. Absent evidence
	-- refuses: an empty-hash default would overwrite a file nobody examined.
	if change.base_hash == nil then
		return false,
			"refusing to accept "
				.. tostring(change.path)
				.. ": the change set carries no before-fingerprint for it, so drift cannot be judged"
	end

	-- THE FILE CLAIM, at the SAME accept step as the drift guard: is anybody
	-- else already reviewing this file?
	local claim_refusal = apply_sessions.file_claim_refusal(pass, change)
	if claim_refusal then
		return false, claim_refusal
	end
	return true
end

M.accept_preflight = accept_preflight

--- THE ONE GUARDED DIARY WRITE: both accept routes reach disk through exactly
--- this body -- intent row with the drift CAS, displaced copy, post-rename
--- verification, receipt. `plan.preserve_review` withholds the BUFFER
--- RECONCILE only, never a disk identity or content check. `own_splice` is an
--- argument only: never onto `plan` or `applied`.
---
--- Returns `true, nil, applied` or `false, reason`. `applied.reconcile_error`
--- marks the committed-but-unreadable case: it IS on disk, so keep the
--- `{diary_dir, op_id}` receipt, never blindly repeat it.
function M.commit(session, change, plan, own_splice, staged_proof)
	if plan.action == "none" then
		-- No shortcut around a write: the projection owner compared the
		-- target against verified disk evidence.
		return true, nil, { path = change.path, kind = "none", written = false }
	end
	local is_delete = plan.action == "delete"
	-- Predicted as diary.next_op_id mints it, so the timeline can revert by
	-- (diary_dir, op_id).
	local predicted_op_id = string.format("%s:%d", session.stream, (session.op_seq or 0) + 1)
	local ok, err = diary.intent({
		session = session,
		path = change.path,
		target = plan.bytes,
		op_kind = is_delete and "delete" or "replace",
		base_hash = change.base_hash,
		-- WHEN it was captured, so a stale-file refusal tells a human edit
		-- from a stale capture.
		base_hash_captured_ts = change.base_hash_captured_ts,
		-- Absence and an empty file are different states; only this tag
		-- separates them at accept time.
		base_state = change.base_state,
		base_mode = change.base_mode,
		base_link_target = change.base_link_target,
		-- THE MODE VERDICT, AND NOTHING ELSE: `change.after_mode` is the
		-- agent's PROPOSAL and is never read here.
		target_mode = plan.mode,
		record_only = true,
	})
	if not ok then
		return false, err
	end
	-- The structured mismatch, carried out of the diary onto the change: the
	-- review engine never sees the diary's own evidence.
	local detail
	ok, err, detail = diary.apply_pending({
		session = session,
		path = change.path,
	})
	if not ok then
		if type(detail) == "table" then
			change.shadow_refusal = detail
		end
		return false, err
	end
	-- Read immediately after the diary's post-rename verification, so the
	-- reconcile can prove nothing else touched the path.
	local uv = vim.uv or vim.loop
	local applied = {
		path = change.path,
		kind = is_delete and "delete" or "replace",
		stat = (not is_delete) and uv.fs_stat(change.path) or nil,
		-- op_id alone is not unique across diaries, so the directory travels
		-- with it.
		diary_dir = session.diary_dir,
		op_id = predicted_op_id,
		-- What the unsaved-edits guard checks a modified buffer against:
		-- what the review was built FROM, and what this call installs.
		base_hash = change.base_hash,
		target_hash = hash.hash_bytes(plan.bytes),
		-- The exact bytes the review had staged when the caller pinned them,
		-- just before the claim. Present only for a turn-exit settlement.
		staged_hash = type(staged_proof) == "table" and staged_proof.hash or nil,
		-- The pin's edit counter. Bytes alone cannot prove the buffer was
		-- untouched: an operator can change it during the claim wait and put it
		-- back, and the hash would agree while the undo history, marks and
		-- extmarks have all moved underneath the review.
		staged_tick = type(staged_proof) == "table" and staged_proof.tick or nil,
		written = true,
		purpose = plan.purpose,
	}
	if plan.preserve_review then
		-- Buffer and file are SUPPOSED to differ here, so reconciling would
		-- overwrite the live review. The diary's own checks already ran.
		applied.preserved_review = true
		return true, nil, applied
	end
	local rok, rerr = M.reconcile_applied_buffer(applied, own_splice)
	if not rok then
		applied.reconcile_error = rerr
		log.write(
			log.levels.WARN,
			string.format(
				"yana: applied %s but could not reconcile its buffer: %s",
				change.path,
				tostring(rerr)
			)
		)
	end
	return true, nil, applied
end

--- Accept a change on an apply pass: preflight, open this root's journal and
--- checkpoint, then take the one guarded diary write. No transfer-only
--- shortcut: a staged buffer holding the bytes is not an accept.
function M.accept_composed(pass, change, composed, opts)
	local plan, perr = M.write_plan(change, composed, opts)
	if not plan then
		return false, perr
	end
	local ok, err = accept_preflight(pass, change)
	if not ok then
		return false, err
	end
	if plan.action == "none" then
		-- A pass that writes nothing opens neither journal nor checkpoint.
		return M.commit(nil, change, plan, opts and opts.own_splice, opts and opts.staged_proof)
	end
	-- The journal opens BEFORE the checkpoint, which writes inside the diary
	-- directory the `begin` row names. A failure here leaves the accept
	-- retryable.
	local root = apply_sessions.change_root(pass, change)
	local session, serr = apply_sessions.session_for_root(pass, root)
	if not session then
		return false, serr
	end
	ok, err = apply_sessions.ensure_checkpoint(pass, root)
	if not ok then
		return false, err
	end
	return M.commit(session, change, plan, opts and opts.own_splice, opts and opts.staged_proof)
end

return M
