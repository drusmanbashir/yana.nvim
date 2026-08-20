-- Accept-from-shadow pass: diary + checkpoint are the only real-tree writers.
local M = {}

local diary = require("yana.safety.diary")
local checkpoint = require("yana.safety.checkpoint")
local preview = require("yana.shadow.preview")
local diff = require("yana.diff")
local log = require("yana.log")

M._test = {
	inject = {},
	fault = {},
}

function M.enabled()
	return preview.apply_enabled()
end

--- Path of `abs` relative to the turn workspace.
--- Returns nil when `abs` is outside the workspace, so a caller cannot silently
--- look up the wrong entry.
function M.workspace_rel(workspace, abs)
	if not workspace or not abs then
		return nil
	end
	local root = diff.abs_path(workspace)
	local target = diff.abs_path(abs)
	if target == root then
		return nil
	end
	local prefix = root:gsub("/$", "") .. "/"
	if target:sub(1, #prefix) ~= prefix then
		return nil
	end
	return target:sub(#prefix + 1)
end

--- Start an accept pass for a completed shadow turn.
---
--- The pass does NOT open the durable journal. `diary.begin` writes a `begin`
--- row, fsyncs it, and fsyncs two directories; measured inside a real turn on
--- a workspace the agent has just written, that is ~450 ms of syscall held on
--- the main loop (S7a localised it as the single 727 ms / 456 ms gap between
--- `change_set_read` and `apply_pass_began`). This function runs on the DISPLAY
--- path -- `ui.lua` calls it immediately before the first review opens -- and
--- CORE forbids exactly that: "a synchronous await on the DISPLAY path where
--- async was possible is a defect", while "every ACTION that changes durable
--- state must wait for the complete, classified, durably-published bundle" and
--- the ACTION, not the OPEN, is what may be gated.
---
--- So the pass carries the ARGUMENTS for the journal instead of the journal,
--- and `ensure_session` below opens it on the first operation that intends to
--- change durable state. Nothing about the journal's own ordering moves: the
--- `begin` row is still written and fsynced IN SEQUENCE -- this function does
--- not advance until that flush has answered, though since 2026-08-19 the flush
--- itself runs on the libuv threadpool (`safety/flush.lua`) -- still before any
--- `intent` row; it is only started later. A turn the operator rejects
--- now never creates a diary directory at all.
function M.begin_pass(shadow_turn, changes)
	if not M.enabled() then
		return nil, "apply mode disabled"
	end
	local paths = {}
	for _, change in ipairs(changes or {}) do
		if change.path then
			paths[#paths + 1] = change.path
		end
	end
	return {
		shadow_turn = shadow_turn,
		diary_begin = {
			workspace = shadow_turn.workspace,
			stream = shadow_turn.stream,
		},
		turn_id = tostring(shadow_turn.turn_id),
		paths = paths,
		checkpoint_started = false,
	}, nil
end

--- The pass's durable journal, opened on demand.
---
--- Every caller is on the ACTION side (accept, checkpoint, revert). The first
--- one pays for `diary.begin`; the rest reuse the session. A failure is
--- recorded ON THE PASS -- the object being resolved -- before it is returned,
--- so a later predicate can ask "did opening the journal halt?" without
--- re-deriving it from the session that does not exist. The record does not
--- make the pass dead: the caller's own sequence stops and keeps everything,
--- and the next accept attempts the open again, which is what "stays
--- retryable" requires.
local function ensure_session(pass)
	if pass.diary_session then
		return pass.diary_session
	end
	if not pass.diary_begin then
		local err = "the apply pass carries no way to open its durable journal"
		pass.diary_begin_halted = err
		return nil, err
	end
	local session, berr = diary.begin(pass.diary_begin)
	if not session then
		pass.diary_begin_halted = berr or "opening the durable journal failed"
		return nil, pass.diary_begin_halted
	end
	pass.diary_begin_halted = nil
	pass.diary_session = session
	return session
end

--- The pass's journal if it has already been opened, without opening one.
--- For read-only introspection (`dump`, `journal_rows`): asking what the pass
--- has written must never be the thing that makes it write.
function M.opened_session(pass)
	return pass and pass.diary_session or nil
end

local function ensure_checkpoint(pass)
	if pass.checkpoint_started then
		return true
	end
	local session, serr = ensure_session(pass)
	if not session then
		return false, serr
	end
	local cp, err = checkpoint.begin_turn({
		session = session,
		turn_id = pass.turn_id,
		paths = pass.paths,
	})
	if not cp then
		return false, err
	end
	pass.checkpoint_started = true
	return true
end

--- Did this path move between the applier's own write and the buffer reconcile?
--- Size, mode, inode, and mtime and ctime at nanosecond resolution: movement in
--- ANY of them is movement. This is a two-stat comparison over ONE path the
--- applier has just written — not a workspace pass — and it exists only so the
--- reconcile refuses to touch a buffer whose file something else has changed
--- since. `nil` on either side reads as moved: the reconcile has no business
--- proceeding on a file it could not stat.
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
--- Without this, accepting a file in shadow-apply mode stalls the rest of the
--- turn. The applier renames new bytes over the real path; a review buffer the
--- human refined is left `modified`, against the mtime Vim recorded before the
--- rename. The next bare `checktime` — and `diff.reload_file` runs one every
--- time a review opens — then finds that buffer changed on disk AND changed in
--- Vim, and raises the BLOCKING W12 dialog (W13 for an agent-created file).
--- That dialog holds the main loop, so every review still queued behind the
--- accepted file never opens. Multi-file turns are the normal case for this
--- product, so this is the normal case.
---
--- Two things this is deliberately not:
---
---  * Not a second door into the real tree. Bytes travel disk -> buffer only.
---    No write, no save, no create; the diary stays the sole real-tree writer.
---  * Not a blanket suppression of the changed-on-disk prompt. That prompt is
---    genuine whenever something OUTSIDE this turn moved the file. We are
---    entitled to reconcile exactly the bytes this turn's applier just wrote to
---    this path, so we reconcile only while disk still carries the exact stat
---    identity the applier's post-rename verification left behind. Anything
---    that landed in the window since has MOVED the stat, and the buffer is
---    then left untouched with the prompt still armed. Content is never
---    consulted as a second opinion: per CORE, matching content does not clear
---    a refusal.
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

	if M._test.fault and M._test.fault.force_undojoin then
		vim.cmd("keepjumps silent! undojoin")
	end

	-- Disk can move while the buffer is being replaced, which is why nothing is
	-- decided from the bytes read above. The mutation happens first; the
	-- observation that licenses clearing `modified` happens after it.
	if M._test.inject and M._test.inject.disk_write_after_second_stat then
		diff.write_file(applied.path, M._test.inject.disk_write_after_second_stat)
	end

	local wants_eol = disk:match("\n$") ~= nil
	local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
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
	-- Re-stamp the buffer's view of the file mtime without reloading or raising
	-- changed-on-disk prompts. `edit!` did this implicitly; here the bytes
	-- already match disk and only the timestamp cache is stale.
	local ei = vim.o.eventignore
	vim.o.eventignore = "FileChangedShell,FileChangedShellPost"
	pcall(vim.cmd, "silent! checktime " .. bufnr)
	vim.o.eventignore = ei

	if vim.bo[bufnr].modified then
		return false, "the review buffer is still flagged modified after reload"
	end
	return true
end

--- Accept composed file content (post-hunk review) through the diary.
function M.accept_composed(pass, change, composed)
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

	-- THE ACTION WAITING FOR ITS DURABLE STATE. The journal is opened here, on
	-- the accept, rather than when the review opened. It is opened BEFORE the
	-- checkpoint, because the checkpoint writes inside the diary directory the
	-- `begin` row names; a failure here returns without touching anything, so
	-- the change stays offered and the accept stays retryable.
	local session, serr = ensure_session(pass)
	if not session then
		return false, serr
	end
	local ok, err = ensure_checkpoint(pass)
	if not ok then
		return false, err
	end
	-- A deletion is a typed operation, not a write of empty content. Handing the
	-- diary `target = ""` used to leave a ZERO-BYTE FILE where the user asked
	-- for a deletion and journal it as done; diary.lua now carries a real
	-- journaled unlink and picks it by op_kind.
	local is_delete = change.kind == "delete"
	-- The op id this intent will take, predicted exactly as diary.next_op_id
	-- mints it (safety/diary.lua: `stream:op_seq+1`). Captured before the call
	-- because diary.intent returns only ok/err, not the id it consumed -- the
	-- record lane documented this seam. Carried out on `applied` so the timeline
	-- can record a durable row the walk can later revert by (diary_dir, op_id).
	local predicted_op_id = string.format("%s:%d", session.stream, (session.op_seq or 0) + 1)
	local ok, err = diary.intent({
		session = session,
		path = change.path,
		target = is_delete and "" or (composed or ""),
		op_kind = is_delete and "delete" or "replace",
		base_hash = change.base_hash,
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

--- Journaled accept when no apply-mode shadow_pass exists (preview-mode inline
--- review). Checkpoint is omitted: preview turns discard the overlay without a
--- pass, but a real-tree accept during review still routes through the diary.
function M.accept_standalone(panel, change, composed)
	if not panel then
		return false, "no panel"
	end
	if change.base_hash == nil then
		return false,
			"refusing to accept "
				.. tostring(change.path)
				.. ": the change set carries no before-fingerprint for it, so drift cannot be judged"
	end
	if not panel._standalone_diary then
		local ws = change.review_workspace or panel.cwd or vim.fn.getcwd()
		local session, err = diary.begin({
			workspace = ws,
			stream = panel.session_id or ("panel-" .. tostring(panel.id or "inline")),
		})
		if not session then
			return false, err
		end
		panel._standalone_diary = session
	end
	local session = panel._standalone_diary
	local is_delete = change.kind == "delete"
	local predicted_op_id = string.format("%s:%d", session.stream, (session.op_seq or 0) + 1)
	local ok, err = diary.intent({
		session = session,
		path = change.path,
		target = is_delete and "" or (composed or ""),
		op_kind = is_delete and "delete" or "replace",
		base_hash = change.base_hash,
		base_state = change.base_state,
		base_mode = change.base_mode,
		base_link_target = change.base_link_target,
		target_mode = change.after_mode,
		record_only = true,
	})
	if not ok then
		return false, err
	end
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
	local uv = vim.uv or vim.loop
	local applied = {
		path = change.path,
		kind = is_delete and "delete" or "replace",
		stat = (not is_delete) and uv.fs_stat(change.path) or nil,
		diary_dir = session.diary_dir,
		op_id = predicted_op_id,
	}
	local rok, rerr = M.reconcile_applied_buffer(applied)
	if not rok then
		applied.reconcile_error = rerr
	end
	return true, nil, applied
end

--- Scope-revert an out-of-zone edit through the journaled applier.
function M.scope_revert(panel, change)
	if not panel or not change or not change.path or change.before == nil then
		return false, "scope revert requires a before snapshot"
	end
	if not panel._standalone_diary then
		local ws = change.review_workspace or panel.cwd or vim.fn.getcwd()
		local session, err = diary.begin({
			workspace = ws,
			stream = panel.session_id or ("panel-" .. tostring(panel.id or "scope")),
		})
		if not session then
			return false, err
		end
		panel._standalone_diary = session
	end
	return diary.restore_workspace_bytes({
		session = panel._standalone_diary,
		path = change.path,
		content = change.before,
		base_hash = change.base_hash,
		base_state = change.base_state,
		base_mode = change.base_mode,
		base_link_target = change.base_link_target,
	})
end

function M.revert_pass(pass)
	-- A pass with no journal has nothing captured and nothing to put back.
	if not pass or not pass.diary_session then
		return true
	end
	-- NOT `pass.checkpoint_started`: that boolean is process-local state on the
	-- pass OBJECT, and a retried or resumed pass is a new object over the same
	-- diary directory and turn id. Reading it there would answer "no checkpoint"
	-- for a checkpoint that is on disk, and this function would return `true` —
	-- a whole-turn revert reporting success having restored nothing, which is
	-- the same silent shape `checkpoint.begin_turn`'s guard exists to stop. The
	-- durable artefact decides.
	if vim.fn.filereadable(checkpoint.manifest_path(pass.diary_session, pass.turn_id)) ~= 1 then
		return true
	end
	return checkpoint.revert_turn({
		session = pass.diary_session,
		turn_id = pass.turn_id,
	})
end

function M.finish_pass(pass)
	if pass and pass.shadow_turn then
		preview.discard(pass.shadow_turn)
	end
end

function M.journal_rows(pass)
	local session = M.opened_session(pass)
	if not session then
		-- No accept has happened on this pass, so no journal exists. Reading it
		-- must not open one: introspection is not an action.
		return {}
	end
	local path = session.diary_dir .. "/journal.jsonl"
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	local rows = {}
	for _, line in ipairs(vim.fn.readfile(path)) do
		if line ~= "" then
			rows[#rows + 1] = vim.json.decode(line)
		end
	end
	return rows
end

function M.read_real_bytes(path)
	return diff.read_file_bytes(path)
end

return M
