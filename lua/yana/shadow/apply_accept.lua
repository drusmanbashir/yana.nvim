-- The reconcile-and-accept core of the shadow accept pass, split out of
-- shadow/apply.lua. Reachable under apply.lua's original names via its
-- facade; standalone/scope-revert accept calls into this module the same
-- way it always called these functions on the parent table.
local M = {}

-- Overwritten by the facade with the SAME table `apply.lua` exposes as
-- `M._test`, so a fault the parent's callers inject is the one
-- `reconcile_applied_buffer` here actually reads. This default only serves
-- apply_accept.lua required in isolation, e.g. by a unit test of its own.
M._test = { inject = {}, fault = {} }

local diary = require("yana.safety.diary")
local diff = require("yana.diff")
local log = require("yana.log")
local hash = require("yana.safety.hash")
local apply_sessions = require("yana.shadow.apply_sessions")

--- Did this path move between the applier's own write and the buffer reconcile? Size,
--- mode, inode, and mtime and ctime at nanosecond resolution: movement in ANY of them
--- is movement. This is a two-stat comparison over ONE path the applier has just
--- written — not a workspace pass — and it exists only so the reconcile refuses to
--- touch a buffer whose file something else has changed since.
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
--- the applier wrote.
---
--- Without this, accepting a file in shadow-apply mode stalls the rest of the turn. The
--- applier renames new bytes over the real path; a review buffer the human refined is
--- left `modified`, against the mtime Vim recorded before the rename. The next bare
--- `checktime` — and `diff.reload_file` runs one every time a review opens — then finds
--- that buffer changed on disk AND changed in Vim, and raises the BLOCKING W12 dialog
--- (W13 for an agent-created file).
---
--- Two things this is deliberately not:
---
--- * Not a second door into the real tree. Bytes travel disk -> buffer only. No write,
--- no save, no create; the diary stays the sole real-tree writer.
---
--- Called from `accept_composed` itself rather than returned to the caller to
--- perform. That was the first shape, and the Oracle adapter found the flaw in
--- it within one run: a harness that dropped the extra return value turned the
--- whole fix into a silent no-op. Nothing a caller can forget to propagate can
--- leave the applier having written underneath a buffer that still describes
--- the pre-write file.
---
--- Per-file, not once when the pass completes. The applier acts per file and
--- the next review opens immediately after, so a reconcile owed until pass end
--- is owed across exactly the review opens that deadlock. And review-apply
--- states that multi-file acceptance is resumable, not atomic: a pass can be
--- refused or abandoned half way and never complete, so an end-of-pass
--- reconcile is a debt that may never be paid on the runs that need it most.
function M.reconcile_applied_buffer(applied)
	if not applied or applied.kind ~= "replace" then
		-- An accepted deletion leaves no file to reconcile against. Neovim
		-- reports a vanished file as the non-blocking E211 message, never a
		-- dialog, so nothing is owed here.
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

	-- THE UNSAVED-EDITS GUARD. What actually distinguishes a genuine independent edit is
	-- disagreeing with BOTH fingerprints this turn knows about:
	--
	--   * `applied.base_hash` (== `change.base_hash`, the drift guard in
	--     accept_composed already refuses to accept without it) -- the
	--     buffer is exactly the pre-turn file, untouched.
	--   * `applied.target_hash` -- the buffer already IS the turn's own
	--     result, whether because inline review put it there or because a
	--     caller passed a buffer already carrying it.
	--
	-- Matching either means replacing it with the applier's bytes discards nothing (the
	-- second case does not even change anything visible). Matching NEITHER means the human
	-- changed this buffer independently of this turn, and `nvim_buf_set_lines` below would
	-- silently overwrite their work the instant it ran. Refuse instead: disk already
	-- carries the accepted change (the diary is the sole real-tree writer and already
	-- wrote it), but the buffer -- and the human's bytes in it -- are left exactly as they
	--
	-- Neither fingerprint present at all (not "both absent because they happen to be nil",
	-- but a CALLER that never carries this turn's context, e.g. `timeline/walk_impl.lua`'s
	-- post-revert reconcile) is a caller that has not opted into this guard, not a caller
	-- with something to hide -- it gets the pre-guard behaviour, unconditional reconcile,
	-- unchanged. Row 70 owns the ACCEPT path (`accept_composed`, `accept_standalone`),
	-- which always supplies `base_hash`; a walk step reconciling the buffer to a disk
	if
		vim.bo[bufnr].modified
		and (applied.base_hash or applied.target_hash)
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
		if snap_hash ~= applied.base_hash and snap_hash ~= applied.target_hash then
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

	-- Buffer-native reconcile: one undo-atomic edit that installs the applier's
	-- verified bytes, without `edit!` reload churn. Disk was already written by
	-- the journaled rename; this is presentation only.
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

	-- Disk can move while the buffer is being replaced, which is why nothing is
	-- decided from the bytes read above. The mutation happens first; the
	-- observation that licenses clearing `modified` happens after it.
	if M._test.inject and M._test.inject.disk_write_after_second_stat then
		diff.write_file(applied.path, M._test.inject.disk_write_after_second_stat)
	end

	local wants_eol = disk:match("\n$") ~= nil
	local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
		-- `:undojoin` acts on the CURRENT buffer, which is why the fault
		-- injection lives inside this `nvim_buf_call` rather than beside it:
		-- outside, "current" could be whatever buffer the editor happened to
		-- be on, not `bufnr`, and the join would land on the wrong undo tree.
		if M._test.fault and M._test.fault.force_undojoin then
			vim.cmd("keepjumps silent! undojoin")
		end
		local lines = vim.split(disk, "\n", { plain = true })
		if disk:sub(-1, -1) == "\n" and #lines > 0 and lines[#lines] == "" then
			table.remove(lines)
		elseif disk == "" then
			lines = {}
		end
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
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

	-- THE AGREEMENT IS PROVEN AFTER THE MUTATION, AGAINST CURRENT DISK.
	--
	-- review-apply: "afterwards buffer and disk agree". The earlier stat and read
	-- are what the buffer was built FROM; they say nothing about the file now.
	-- Comparing the new buffer against those cached bytes proved only that
	-- `nvim_buf_set_lines` did what it was told, so anything that landed on disk
	-- during the replacement left buffer and disk different while the buffer was
	-- marked clean — the one thing clearing `modified` is a promise against.
	--
	-- So: re-stat for identity, re-read for bytes, compare the buffer to THAT,
	-- and only then clear the flag. A refusal leaves the buffer modified, which
	-- keeps the human's changed-on-disk prompt armed and their text unsaved but
	-- intact.
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
	-- The buffer is now backed by a real file from the START -- the touch happens at
	-- proposal time -- so the stamp is never that, and a created file takes the same
	-- silent `checktime` restamp every existing file takes, just below. Re-stamp the
	-- buffer's view of the file mtime without reloading or raising changed-on-disk
	-- prompts. `edit!` did this implicitly; here the bytes already match disk and only the
	-- timestamp cache is stale.
	--
	-- KNOWN RESIDUAL (documented, not fixed here -- see SYNC-70 in tests/tests.md):
	-- 'autoread' defaults ON in Neovim, so this unmodified buffer takes `:checktime`'s
	-- SILENT-RELOAD branch regardless of whether the FileChangedShell autocmd fired -- it
	-- re-reads the file and replaces the buffer wholesale. Bytes come out identical (we
	-- just wrote them ourselves), but the replace registers as a second, redundant undo
	-- state on top of the one this function just made. Fixing this belongs beside that
	local ei = vim.o.eventignore
	vim.o.eventignore = "FileChangedShell,FileChangedShellPost"
	pcall(vim.cmd, "silent! checktime " .. bufnr)
	vim.o.eventignore = ei

	if vim.bo[bufnr].modified then
		return false, "the review buffer is still flagged modified after reload"
	end
	return true
end

local function mode_perm(mode)
	return mode and (mode % 4096) or nil
end

function M.valid_loaded_buffer(bufnr)
	return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

function M.mode_delta(change)
	if not change or not change.base_mode or not change.after_mode then
		return false
	end
	return mode_perm(change.base_mode) ~= mode_perm(change.after_mode)
end

-- Refuse a single-file accept when its buffer is closed, stale, or retyped.
function M.single_file_accept_refusal(change, staged_bufnr)
	if not (change and change.single_file) then
		return nil
	end
	local name = vim.fn.fnamemodify(change.single_file.real_path or change.path or "file", ":t")
	if not M.valid_loaded_buffer(staged_bufnr) then
		return "single-file mode: the buffer is closed — reopen " .. name .. " and decide again"
	end
	-- Compared against change.after (the AGENT'S proposed full file), not the
	-- caller's just-taken snapshot of this same buffer.
	local live = diff.buffer_bytes_snapshot(staged_bufnr)
	if live ~= change.after then
		return "single-file mode: buffer differs from the composed review — decide again"
	end
	if change.kind == "delete" or change.before == nil or M.mode_delta(change) then
		return "single-file mode: only " .. name .. " may change (refused " .. tostring(change.rel or name) .. ")"
	end
	return nil
end

local function transfer_preflight(pass, change)
	-- Any structured refusal detail is from a PREVIOUS attempt on this change;
	-- clearing it here means a refusal is only ever labelled by evidence this
	-- attempt actually gathered.
	change.shadow_refusal = nil
	-- THE DRIFT EVIDENCE, per touched path. CORE: "A human-changed target is
	-- refused by name; both versions are retained. The human's change is
	-- detected per touched path, by content fingerprint, read immediately
	-- before the write."
	--
	-- `change.base_hash` is the fingerprint of the before-bytes the review was
	-- built on, captured by the change-set producer from the LOWER layer. The
	-- diary re-reads the real file and compares against it one step before the
	-- rename, which is the "immediately before the write" half. No turn-start
	-- whole-workspace record is consulted, because none is taken.
	--
	-- Absent evidence refuses. The previous route defaulted a missing entry to
	-- the empty hash, which was correct for an agent-created file under a
	-- whole-tree manifest — every existing file was in it, so absence MEANT
	-- non-existence. Under a per-path producer absence means the producer did
	-- not run, and defaulting to the empty hash would authorise overwriting a
	-- file whose contents were never examined.
	if change.base_hash == nil then
		return false,
			"refusing to accept "
				.. tostring(change.path)
				.. ": the change set carries no before-fingerprint for it, so drift cannot be judged"
	end

	-- THE FILE CLAIM, paired with the drift guard above at the SAME accept step:
	-- the fingerprint answers "is the file the one this review was prepared
	-- against", and this answers "is anybody else already reviewing it".
	-- Removing this one line is the mutation
	-- tests/suite/p108_second_editor_clobber.lua drives.
	local claim_refusal = apply_sessions.file_claim_refusal(pass, change)
	if claim_refusal then
		return false, claim_refusal
	end
	return true
end

-- Check drift/claim, then describe a transfer of a buffer's existing bytes.
function M.accept_transfer(pass, change, composed, bufnr)
	local ok, err = transfer_preflight(pass, change)
	if not ok then
		return false, err
	end
	return true, nil, {
		kind = "transfer",
		path = change.path,
		bufnr = bufnr,
		composed_hash = hash.hash_bytes(composed or ""),
	}
end

--- Accept composed file content (post-hunk review) through the diary.
function M.accept_apply(pass, change, composed)
	local ok, err = transfer_preflight(pass, change)
	if not ok then
		return false, err
	end
	-- THE ACTION WAITING FOR ITS DURABLE STATE. The journal is opened here, on
	-- the accept, rather than when the review opened. It is opened BEFORE the
	-- checkpoint, because the checkpoint writes inside the diary directory the
	-- `begin` row names; a failure here returns without touching anything, so
	-- the change stays offered and the accept stays retryable.
	local root = apply_sessions.change_root(pass, change)
	local session, serr = apply_sessions.session_for_root(pass, root)
	if not session then
		return false, serr
	end
	local ok, err = apply_sessions.ensure_checkpoint(pass, root)
	if not ok then
		return false, err
	end
	-- A deletion is a typed operation, not a write of empty content.
	local is_delete = change.kind == "delete"
	-- The op id this intent will take, predicted exactly as diary.next_op_id mints it
	-- (safety/diary.lua: `stream:op_seq+1`). Carried out on `applied` so the timeline can
	-- record a durable row the walk can later revert by (diary_dir, op_id).
	local predicted_op_id = string.format("%s:%d", session.stream, (session.op_seq or 0) + 1)
	local ok, err = diary.intent({
		session = session,
		path = change.path,
		target = is_delete and "" or (composed or ""),
		op_kind = is_delete and "delete" or "replace",
		base_hash = change.base_hash,
		-- WHEN that fingerprint was captured (shadow/ops.lua's producer read),
		-- carried through so a stale-file refusal can tell a human edit from a
		-- stale capture rather than punting on the distinction.
		base_hash_captured_ts = change.base_hash_captured_ts,
		-- The producer's before-state TAG travels with the fingerprint. Absence
		-- and an empty file are different states, and only the tag separates
		-- them at accept time.
		base_state = change.base_state,
		base_mode = change.base_mode,
		base_link_target = change.base_link_target,
		target_mode = change.after_mode,
		record_only = true,
	})
	if not ok then
		return false, err
	end
	-- The structured mismatch, carried out of the diary. The recording site for
	-- a refusal lives in the review engine, which never sees the diary's
	-- evidence; without this it recorded the generic `shadow_accept_failed`
	-- with no fingerprint pair, so the DEFAULT (shadow) drift refusal said less
	-- than the legacy in-place one. Attached to the change because the change is
	-- the one object both layers already hold.
	--
	-- Cleared first: a change can be retried, and a stale detail from an earlier
	-- attempt would label the next refusal with fingerprints nobody compared.
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
	-- The stat is read HERE, immediately after the diary's own post-rename
	-- verification, so the reconcile below can prove nothing else has touched
	-- the path since — and refuse if anything has.
	local uv = vim.uv or vim.loop
	local applied = {
		path = change.path,
		kind = is_delete and "delete" or "replace",
		stat = (not is_delete) and uv.fs_stat(change.path) or nil,
		-- Durable identity for the timeline. op_id alone is not unique across
		-- diaries (every new diary restarts the sequence at zero), so the
		-- directory travels with it.
		diary_dir = session.diary_dir,
		op_id = predicted_op_id,
		-- The two fingerprints the unsaved-edits guard in
		-- reconcile_applied_buffer checks a modified buffer against before
		-- overwriting anything: what the review was built FROM, and what
		-- this call is installing (inline review composes that INTO the
		-- buffer itself, so a modified buffer already carrying it is the
		-- normal case, not a divergent edit).
		base_hash = change.base_hash,
		target_hash = hash.hash_bytes(is_delete and "" or (composed or "")),
	}
	local rok, rerr = M.reconcile_applied_buffer(applied)
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

-- Accept a change: reuse a matching buffer via transfer, else full apply.
function M.accept_composed(pass, change, composed, opts)
	opts = opts or {}
	local staged_bufnr = opts.staged_bufnr
	if change and change.single_file then
		local refusal = M.single_file_accept_refusal(change, staged_bufnr)
		if refusal then
			return false, refusal
		end
		return M.accept_transfer(pass, change, composed, staged_bufnr)
	end
	if M.valid_loaded_buffer(staged_bufnr) then
		local live = diff.buffer_bytes_snapshot(staged_bufnr)
		if live == composed and change and change.kind ~= "delete" and not M.mode_delta(change) then
			return M.accept_transfer(pass, change, composed, staged_bufnr)
		end
		if live ~= composed then
			log.write(
				log.levels.WARN,
				"yana: staged buffer mismatch for " .. tostring(change and change.path or "?") .. " -- written at accept"
			)
		elseif M.mode_delta(change) then
			log.write(log.levels.WARN, "yana: mode change — written at accept (trash gate pending)")
		end
	end
	return M.accept_apply(pass, change, composed)
end

return M
