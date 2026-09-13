-- Accept diary — sole writer of the real tree for shadow acceptance.
-- openat2 unavailable in Neovim runtime: lstat walk enforces RESOLVE_BENEATH|NO_SYMLINKS.
--
-- The safety invariant holds per-op (a done row is never durable before that op's
-- swap).
--
-- Not one flush is batched, deferred, removed or reordered — same descriptors, same
-- count, same positions, and no statement here runs before the flush ahead of it has
-- answered. Only the operator's editor stops being held for the disk. `the review and
-- apply contract`, "Durability posture".
local M = {}

local diff = require("yana.diff")
local hash = require("yana.safety.hash")
local control_plane = require("yana.safety.control_plane")
local flush = require("yana.safety.flush")
local manifest = require("yana.manifest")
local uv = vim.uv or vim.loop

M._config = {
	max_bytes = 50 * 1024 * 1024,
	aged_frontier_sec = 3600,
	min_free_bytes = 4096,
}

M._test = {
	force_diary_root = nil,
	force_no_space = false,
	force_cap_bytes = nil,
	fault = {},
	inject = {},
}

local CHECKPOINT_WRITE = false

-- Every name below stays a local of this file under its original name so no call site
-- changes.
local diary_fs_factory = require("yana.safety.diary_fs")
local diary_fs = diary_fs_factory.new({
	uv = uv,
	flush = flush,
	diff = diff,
	hash = hash,
	manifest = manifest,
	control_plane = control_plane,
	test_state = M._test,
	config = M._config,
})

local write_all_fd = diary_fs.write_all_fd
local hash_bytes = diary_fs.hash_bytes
local read_bytes = diary_fs.read_bytes
local journal_path = diary_fs.journal_path
local fsync_path = diary_fs.fsync_path
local fsync_dir = diary_fs.fsync_dir
local append_jsonl = diary_fs.append_jsonl
local read_jsonl = diary_fs.read_jsonl
local lexical_rel = diary_fs.lexical_rel
local resolve_target = diary_fs.resolve_target
local diary_usage = diary_fs.diary_usage
local check_cap = diary_fs.check_cap
local check_space = diary_fs.check_space
local write_displaced = diary_fs.write_displaced
local load_journal = diary_fs.load_journal
local next_op_id = diary_fs.next_op_id
local op_seq_number = diary_fs.op_seq_number
-- Every name below stays a local of this file under its original name so no call site
-- changes.
local diary_state_factory = require("yana.safety.diary_state")
local diary_state = diary_state_factory.new({
	uv = uv,
	read_bytes = read_bytes,
	hash_bytes = hash_bytes,
	test_state = M._test,
	refusal_message = function(path)
		return M.refusal_message(path)
	end,
})

local observe_state = diary_state.observe_state
local mode_perm = diary_state.mode_perm
local valid_mode = diary_state.valid_mode
local identity_of = diary_state.identity_of
local evidence_complete = diary_state.evidence_complete
local state_matches = diary_state.state_matches
local state_refusal = diary_state.state_refusal

-- Every name below stays a local (or `M.*` facade) of this file under its original name
-- so no call site changes.
local diary_session_factory = require("yana.safety.diary_session")
local diary_session = diary_session_factory.new({
	diff = diff,
	control_plane = control_plane,
	op_seq_number = op_seq_number,
	load_journal = load_journal,
	append_jsonl = append_jsonl,
	journal_path = journal_path,
	fsync_dir = fsync_dir,
	resolve_target = resolve_target,
	hash_bytes = hash_bytes,
	observe_state = observe_state,
	mode_perm = mode_perm,
	test_state = M._test,
	empty_hash = function()
		return M.empty_hash()
	end,
	intent = function(opts)
		return M.intent(opts)
	end,
	apply_pending = function(opts)
		return M.apply_pending(opts)
	end,
})

local displaced_path_for = diary_session.displaced_path_for

function M.open(diary_dir)
	return diary_session.open(diary_dir)
end

function M.begin(opts)
	return diary_session.begin(opts)
end

function M.validate_payload(opts)
	return diary_session.validate_payload(opts)
end

function M.write_bytes(opts)
	return diary_session.write_bytes(opts)
end

function M._checkpoint_write_begin()
	return diary_session._checkpoint_write_begin()
end

function M._checkpoint_write_end()
	return diary_session._checkpoint_write_end()
end

function M.restore_workspace_bytes(opts)
	return diary_session.restore_workspace_bytes(opts)
end

-- Every name below stays a local of this file under its original name so no call site
-- changes.
local diary_restore_checks_factory = require("yana.safety.diary_restore_checks")
local diary_restore_checks = diary_restore_checks_factory.new({
	uv = uv,
	check_cap = check_cap,
	append_jsonl = append_jsonl,
	journal_path = journal_path,
	hash_bytes = hash_bytes,
	read_bytes = read_bytes,
	valid_mode = valid_mode,
	test_state = M._test,
})

local record_intent = diary_restore_checks.record_intent
local chmod_temp = diary_restore_checks.chmod_temp
local rollback_purpose = diary_restore_checks.rollback_purpose
local accepted_state_for_revert = diary_restore_checks.accepted_state_for_revert
local revert_refusal_message = diary_restore_checks.revert_refusal_message
local displaced_record_complete = diary_restore_checks.displaced_record_complete
local verify_displaced_copy = diary_restore_checks.verify_displaced_copy
local checked_record_complete = diary_restore_checks.checked_record_complete

--- THE SOLE WRITER OF `rollback_done` AND `revert_done`.
---
--- Forward-declared here because the fresh rollback below it writes completions
--- and the gate it must pass through is defined with the rest of the replay
--- validation further down. Every route that finishes a rollback — the fresh
--- automatic rollback of a failed accept, the fresh user revert, and each
--- recovery branch — appends its completion through this one function, and
--- there is no other appender of those two kinds in this file.
local record_completion


-- Every name below stays a local of this file under its original name so no call site
-- changes.
local diary_restore_factory = require("yana.safety.diary_restore")
local diary_restore = diary_restore_factory.new({
	uv = uv,
	diff = diff,
	checked_record_complete = checked_record_complete,
	chmod_temp = chmod_temp,
	verify_displaced_copy = verify_displaced_copy,
	revert_refusal_message = revert_refusal_message,
	rollback_purpose = rollback_purpose,
	hash_bytes = hash_bytes,
	read_bytes = read_bytes,
	fsync_dir = fsync_dir,
	journal_path = journal_path,
	append_jsonl = append_jsonl,
	write_displaced = write_displaced,
	record_completion = function(...)
		return record_completion(...)
	end,
	test_state = M._test,
})

local journaled_restore = diary_restore.journaled_restore


-- Moved verbatim behind `M.new(deps)`. Every name below stays a local of this file
-- under its original name so no call site changes.
--
-- `apply_delete` is forward-declared here: `diary_apply.lua` is
-- instantiated first (because `diary_apply_delete.lua` needs ITS
-- `refuse_if_substituted`) and captures `apply_delete` as a forwarding
-- closure over this local — the same "forward through the parent's
-- still-loading scope" pattern used for `record_completion` above, just
-- between two sibling modules instead of parent-to-child.
local apply_delete

local diary_apply_factory = require("yana.safety.diary_apply")
local diary_apply = diary_apply_factory.new({
	uv = uv,
	diff = diff,
	append_jsonl = append_jsonl,
	journal_path = journal_path,
	fsync_dir = fsync_dir,
	resolve_target = resolve_target,
	read_bytes = read_bytes,
	hash_bytes = hash_bytes,
	write_displaced = write_displaced,
	check_space = check_space,
	observe_state = observe_state,
	evidence_complete = evidence_complete,
	state_matches = state_matches,
	state_refusal = state_refusal,
	identity_of = identity_of,
	displaced_path_for = displaced_path_for,
	journaled_restore = journaled_restore,
	test_state = M._test,
	config = M._config,
	refusal_message = function(path)
		return M.refusal_message(path)
	end,
	apply_delete = function(...)
		return apply_delete(...)
	end,
})

local record_refusal = diary_apply.record_refusal
local refuse_if_substituted = diary_apply.refuse_if_substituted
local record_temp_identity = diary_apply.record_temp_identity
local apply_operation = diary_apply.apply_operation

local diary_apply_delete_factory = require("yana.safety.diary_apply_delete")
local diary_apply_delete = diary_apply_delete_factory.new({
	uv = uv,
	diff = diff,
	append_jsonl = append_jsonl,
	journal_path = journal_path,
	fsync_dir = fsync_dir,
	refuse_if_substituted = refuse_if_substituted,
	test_state = M._test,
})

apply_delete = diary_apply_delete.apply_delete


-- Journal a new intent row for one op and apply it unless record_only.
function M.intent(opts)
	opts = opts or {}
	local session = opts.session
	local path = opts.path
	local target = opts.target or ""
	local record_only = opts.record_only == true

	if opts.base_hash == nil then
		return false, "base_hash required — turn-start fingerprint must be supplied by caller"
	end

	-- Persist the validated LEXICAL workspace-relative path as the SOLE target
	-- authority. It is captured here, before any
	-- symlink resolution, so a `.git` name cannot be resolved away; every later
	-- process reading this journal row re-derives the write target from the
	-- trusted workspace root plus this value, never from an absolute path that
	-- could disagree.
	local raw_rel = opts.raw_rel or lexical_rel(session.workspace, path)

	local abs, perr = resolve_target(session.workspace, path, raw_rel)
	if not abs then
		return false, perr
	end

	-- "replace" (write target bytes) or "delete" (journaled unlink). Recorded on
	-- the intent row, so recovery in a later process knows which action it is
	-- completing — an unlink cannot be inferred from an empty target, because a
	-- legitimate replacement with empty content looks identical.
	local op_kind = opts.op_kind or "replace"
	if op_kind ~= "replace" and op_kind ~= "delete" then
		return false, "unknown operation kind: " .. tostring(op_kind)
	end
	if op_kind == "delete" and target ~= "" then
		return false, "a deletion carries no target bytes"
	end

	local op = {
		op_id = next_op_id(session),
		stream = opts.stream or session.stream,
		path = abs,
		raw_rel = raw_rel,
		target = target,
		op_kind = op_kind,
		base_hash = opts.base_hash,
		-- The before-state TAG, taken by the producer's classifying read and
		-- carried unchanged: "absent", "file" or "link". It is on the intent row
		-- so it reaches an applier in a later process, replaying after a crash
		-- with no caller to ask. There is no untagged route any more: an
		-- operation whose evidence is incomplete refuses here, before a row is
		-- written, rather than being compared by fingerprint alone.
		base_state = (opts.base_state == "absent" or opts.base_state == "file" or opts.base_state == "link")
				and opts.base_state
			or nil,
		base_mode = opts.base_mode,
		base_link_target = opts.base_link_target,
		target_mode = opts.target_mode,
		-- WHEN the turn-start fingerprint (`base_hash` above) was taken. Carried
		-- through to the journal's `intent` row (so a later replaying process
		-- still has it) and from there to the stale-file refusal record. Nil
		-- when the caller does not know — recorded as absent, not fabricated.
		base_hash_captured_ts = opts.base_hash_captured_ts,
	}

	if not M._test.fault.allow_untagged_base then
		local ok_ev, ev_err = evidence_complete(op)
		if not ok_ev then
			return false, ev_err
		end
	end

	local ok, err = record_intent(session, op)
	if not ok then
		return false, err
	end

	if record_only then
		return true
	end

	local ok2, err2, detail2 = apply_operation(session, op, {})
	return ok2, err2, detail2
end

-- Apply the most recent undone intent journaled for the given path.
function M.apply_pending(opts)
	opts = opts or {}
	local session = opts.session
	local path = diff.abs_path_literal(opts.path)
	local rows, _, err = load_journal(session)
	if not rows then
		return false, err
	end
	local done = {}
	for _, row in ipairs(rows) do
		if row.kind == "done" then
			done[row.op_id] = true
		end
	end
	for i = #rows, 1, -1 do
		local row = rows[i]
		if row.kind == "intent" and row.path == path and not done[row.op_id] then
			return apply_operation(session, row, opts.apply_opts or {})
		end
	end
	return false, "no pending intent for path"
end

-- Test hook: mark the session crashed after a given path, for replay tests.
function M.simulate_crash(opts)
	opts = opts or {}
	local session = opts.session
	session.crash_after = diff.abs_path(opts.after)
	session.crashed = true
	append_jsonl(journal_path(session), {
		kind = "crash",
		after = session.crash_after,
		ts = os.time(),
	})
	return true
end

-- Delete orphan temp files from crashed writes, verifying identity first.
function M.sweep_orphan_temps(session)
	local rows, _, err = load_journal(session)
	if not rows then
		return {}, err, {}
	end
	local done = {}
	local refused = {}
	local cleaned = {}
	local sweep_refused_ops = {}
	local pending = {}
	for _, row in ipairs(rows) do
		if row.kind == "done" then
			done[row.op_id] = true
		elseif row.kind == "refused" then
			refused[row.op_id] = true
		elseif row.kind == "temp_cleaned" and row.path then
			cleaned[row.path] = true
		elseif row.kind == "temp_sweep_refused" and row.op_id then
			sweep_refused_ops[row.op_id] = true
		elseif row.kind == "temp_sweep_refused_cleared" and row.op_id then
			sweep_refused_ops[row.op_id] = true
		elseif row.kind == "temp_created" and row.path then
			pending[#pending + 1] = row
		end
	end
	local swept = {}
	local sweep_refused = {}
	for _, row in ipairs(pending) do
		if done[row.op_id] or refused[row.op_id] or cleaned[row.path] or sweep_refused_ops[row.op_id] then
			goto continue
		end
		local tmp_path = row.path
		if vim.fn.filereadable(tmp_path) ~= 1 then
			goto continue
		end
		local reason
		if not row.temp_ino or not row.temp_dev then
			reason = "temp identity not recorded — refusing ambiguous sweep at journal path"
		else
			local st = uv.fs_lstat(tmp_path)
			if not st or st.ino ~= row.temp_ino or st.dev ~= row.temp_dev then
				reason = "temp identity mismatch — refusing to delete user file at journal path"
			end
		end
		if reason then
			local ok_ref, ref_err = append_jsonl(journal_path(session), {
				kind = "temp_sweep_refused",
				op_id = row.op_id,
				path = tmp_path,
				reason = reason,
				ts = os.time(),
			})
			if not ok_ref then
				return swept, ref_err, sweep_refused
			end
			sweep_refused[#sweep_refused + 1] = {
				op_id = row.op_id,
				path = tmp_path,
				reason = reason,
			}
			goto continue
		end
		local ok_log, log_err = append_jsonl(journal_path(session), {
			kind = "temp_cleanup",
			op_id = row.op_id,
			path = tmp_path,
			target_path = row.target_path,
			ts = os.time(),
		})
		if not ok_log then
			return swept, log_err, sweep_refused
		end
		if M._test.fault.fail_temp_delete then
			return swept, "failed to delete orphan temp: " .. tmp_path, sweep_refused
		end
		local del_rc = vim.fn.delete(tmp_path)
		if del_rc ~= 0 or vim.fn.filereadable(tmp_path) == 1 then
			return swept, "failed to delete orphan temp: " .. tmp_path, sweep_refused
		end
		swept[#swept + 1] = tmp_path
		append_jsonl(journal_path(session), {
			kind = "temp_cleaned",
			op_id = row.op_id,
			path = tmp_path,
			ts = os.time(),
		})
		::continue::
	end
	return swept, nil, sweep_refused
end

function M.clear_sweep_refused(session, op_id)
	if not op_id or op_id == "" then
		return false, "op_id required"
	end
	local ok_log, log_err = append_jsonl(journal_path(session), {
		kind = "temp_sweep_refused_cleared",
		op_id = op_id,
		ts = os.time(),
	})
	if not ok_log then
		return false, log_err
	end
	return true
end

-- `record_completion` fills the forward-declared local above (used earlier in this
-- file, in `journaled_restore`); `complete_rollback` becomes a local here, same as
-- every Group-A/B/C name.
local diary_rollback_factory = require("yana.safety.diary_rollback")
local diary_rollback = diary_rollback_factory.new({
	checked_record_complete = checked_record_complete,
	rollback_purpose = rollback_purpose,
	displaced_record_complete = displaced_record_complete,
	hash_bytes = hash_bytes,
	read_bytes = read_bytes,
	identity_of = identity_of,
	mode_perm = mode_perm,
	resolve_target = resolve_target,
	fsync_dir = fsync_dir,
	journal_path = journal_path,
	append_jsonl = append_jsonl,
	test_state = M._test,
	accepted_state_for_revert = accepted_state_for_revert,
	revert_refusal_message = revert_refusal_message,
	journaled_restore = journaled_restore,
})

record_completion = diary_rollback.record_completion
local complete_rollback = diary_rollback.complete_rollback
-- Every M.* facade below stays reachable under its original name so no call site
-- changes.
--
local diary_replay_factory = require("yana.safety.diary_replay")
local diary_replay = diary_replay_factory.new({
	uv = uv,
	diff = diff,
	control_plane = control_plane,
	load_journal = load_journal,
	read_bytes = read_bytes,
	hash_bytes = hash_bytes,
	append_jsonl = append_jsonl,
	journal_path = journal_path,
	apply_operation = apply_operation,
	complete_rollback = complete_rollback,
	displaced_path_for = displaced_path_for,
	test_state = M._test,
	config = M._config,
	sweep_orphan_temps = function(...)
		return M.sweep_orphan_temps(...)
	end,
})

function M.replay(opts)
	return diary_replay.replay(opts)
end

function M.apply_with_injection(opts)
	return diary_replay.apply_with_injection(opts)
end

function M.refusal_message(path)
	return diary_replay.refusal_message(path)
end

function M.empty_hash()
	return diary_replay.empty_hash()
end

function M.note(session, row)
	return diary_replay.note(session, row)
end

function M.journal_rows(session)
	return diary_replay.journal_rows(session)
end

function M.status_summary(session)
	return diary_replay.status_summary(session)
end

function M.list_displaced(session)
	return diary_replay.list_displaced(session)
end

function M.recover_displaced(session, op_id, out_path)
	return diary_replay.recover_displaced(session, op_id, out_path)
end

function M.second_pass_reanchor(opts)
	return diary_replay.second_pass_reanchor(opts)
end

function M.displaced_copy_path(session, op_id)
	return diary_replay.displaced_copy_path(session, op_id)
end


-- `M.revert_operation`'s facade stays reachable under its original name;
-- `revert_refused` is internal-only (this group's only caller of it) so it gets a
-- parent-local for consistency with the rest of this split, not because anything
-- outside this group calls it.
local diary_revert_factory = require("yana.safety.diary_revert")
local diary_revert = diary_revert_factory.new({
	load_journal = load_journal,
	op_seq_number = op_seq_number,
	resolve_target = resolve_target,
	append_jsonl = append_jsonl,
	journal_path = journal_path,
	fsync_dir = fsync_dir,
	observe_state = observe_state,
	accepted_state_for_revert = accepted_state_for_revert,
	revert_refusal_message = revert_refusal_message,
	complete_rollback = complete_rollback,
	journaled_restore = journaled_restore,
	record_completion = record_completion,
	test_state = M._test,
})

local revert_refused = diary_revert.revert_refused

function M.revert_operation(opts)
	return diary_revert.revert_operation(opts)
end


return M
