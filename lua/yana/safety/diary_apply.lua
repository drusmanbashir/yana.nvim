-- Same names, same behaviour, same write order, moved verbatim.
--
-- `record_refusal`/`refuse_if_substituted`/`record_temp_identity`/ `apply_operation`
-- form one call graph too tightly coupled to cut a clean internal seam through
-- (record_refusal is the sole writer of a `refused` row, refuse_if_substituted is its
-- only caller besides apply_operation itself, and apply_operation calls all three).
-- ~720 lines together at base size, over the 700 ceiling by itself, so `apply_delete` —
-- one function with exactly one caller here (`apply_operation`) — moved out to its own
local M = {}

function M.new(deps)
	local uv = deps.uv
	local diff = deps.diff
	local append_jsonl = deps.append_jsonl
	local journal_path = deps.journal_path
	local fsync_dir = deps.fsync_dir
	local resolve_target = deps.resolve_target
	local read_bytes = deps.read_bytes
	local hash_bytes = deps.hash_bytes
	local write_displaced = deps.write_displaced
	local check_space = deps.check_space
	local observe_state = deps.observe_state
	local evidence_complete = deps.evidence_complete
	local state_matches = deps.state_matches
	local state_refusal = deps.state_refusal
	local identity_of = deps.identity_of
	local displaced_path_for = deps.displaced_path_for
	local journaled_restore = deps.journaled_restore
	-- Live reference (not a copy): a test that mutates
	-- `diary._test.fault.x` / `diary._config.x` at runtime is still seen
	-- here.
	local test_state = deps.test_state
	local config = deps.config
	local refusal_message = deps.refusal_message
	-- Late-bound the OTHER way: `apply_delete` lives in the sibling module
	-- `diary_apply_delete.lua`, instantiated by the parent AFTER this one
	-- (it needs this module's own `refuse_if_substituted`), so this
	-- forwards through the parent's forward-declared local rather than a
	-- value this module could hold directly at `M.new(deps)` time.
	local apply_delete = deps.apply_delete

	--- THE DECLARED VOCABULARY, and the only place a value is admitted to it.
	---
	--- The logging module's own refusal `reason_code` vocabulary table is the
	--- authority this mirrors. A category meaning "something else" is the one
	--- that grows to swallow every future refusal shape nobody named yet, so
	--- `record_refusal` below refuses to write a row for any code not listed
	--- here — the same discipline `tests/lib/log_assert.lua`'s
	--- `REQUIRED_QUALIFIERS` applies to a test's own usage errors.
	local REASON_CODES = {
		generic_pre_apply = true,
		evidence_error = true,
		delete_target_absent = true,
		observe_failed = true,
		stale_file = true,
	}

	--- THE SOLE WRITER of a `kind = "refused"` journal row, across all five
	--- categories. `fields.reason_code` is REQUIRED and must be declared above;
	--- an undeclared code is a programmer error in the CALLER, not a user-facing
	--- condition one more retry could fix, so this raises rather than silently
	--- widening the vocabulary one string literal at a time.
	---
	--- Returns the fields actually written (with `op_id`/`path` merged in), so a
	--- caller can hand the SAME table back as its structured third return value
	--- rather than keeping two copies that can drift apart.
	---
	--- Mutation seam (gate): `strip_refusal_evidence` reproduces the PRE-this-delta
	--- shape of every category except `stale_file` (which already carried its
	--- fingerprint pair) — `kind`, `op_id`, `path`, `reason` prose, `ts`, and
	--- nothing else. Every one of the five test rows this delta adds reds under
	--- it, because every one of them asserts a field this strips.
	local function record_refusal(session, op, fields)
		local code = fields and fields.reason_code
		if not REASON_CODES[code] then
			error("diary.lua: refusing to write a refusal row with an undeclared reason_code: " .. tostring(code), 0)
		end
		local out = fields
		if test_state.fault.strip_refusal_evidence then
			out = { reason = fields.reason, reason_code = fields.reason_code }
		end
		local row = { kind = "refused", op_id = op.op_id, path = op.path, ts = os.time() }
		for k, v in pairs(out) do
			row[k] = v
		end
		local ok, err = append_jsonl(journal_path(session), row)
		if not ok then
			return nil, err
		end
		out.op_id = op.op_id
		out.path = op.path
		return out
	end

	--- THE DRIFT CHECK, ONE SYSCALL BEFORE THE ACT.
	---
	--- A human save landing anywhere in that window was overwritten, and the displaced
	--- copy held the bytes from BEFORE the save, so the human's own text survived nowhere.
	--- This runs last, so the window is one rename or one unlink wide.
	---
	--- Identity and content both. `(dev, ino, type)` catches a pathname that now
	--- resolves to a different object — a checkout, a build step, a parent
	--- component replaced mid-review — which a content hash alone cannot see when
	--- the substitute happens to carry the same bytes. The content re-read catches
	--- the ordinary case this exists for: the human saved.
	---
	--- It is a mitigation, not a proof. lstat-then-act is still two syscalls; only
	--- a descriptor-relative applier (openat2 plus renameat2/unlinkat, neither
	--- exposed by Neovim's libuv — see the note at the top of this file) removes
	--- the gap. It shrinks the window from the whole check/copy/journal/write
	--- sequence to one instruction.
	local function refuse_if_substituted(session, op, path, state, reason_code)
		-- REQUIRED, NOT DEFAULTED. A category that silently falls back to "something
		-- else" is the one that grows to swallow every future refusal shape nobody
		-- named yet — every caller must classify itself.
		assert(type(reason_code) == "string" and reason_code ~= "", "refuse_if_substituted requires a reason_code")
		local repath, rerr = resolve_target(session.workspace, op.path, op.raw_rel)
		local reason
		local sub_kind
		if not repath or repath ~= path then
			reason = tostring(op.path)
				.. ": "
				.. tostring(rerr or "the target no longer resolves to the location that was checked")
			sub_kind = "resolve_mismatch"
		else
			local now = uv.fs_lstat(path)
			if state.kind == "absent" then
				if now ~= nil then
					reason = path
						.. ": this path did not exist when the change was checked and something has created it since"
						.. " — refusing; your file is untouched"
					sub_kind = "appeared"
				end
			elseif not now then
				reason = path .. ": this file was removed after its contents were checked — refusing; nothing was written"
				sub_kind = "removed"
			elseif now.type ~= "file" then
				reason = path
					.. ": this file was replaced by a "
					.. tostring(now.type)
					.. " after its contents were checked — refusing; it is left exactly as found"
				sub_kind = "type_changed"
			elseif now.dev ~= state.dev or now.ino ~= state.ino then
				reason = path
					.. ": this path resolves to a different object than the one whose contents were checked"
					.. " — refusing; it is left exactly as found"
				sub_kind = "identity_changed"
			else
				local content = read_bytes(path)
				if content == nil then
					reason = path .. ": this file became unreadable after its contents were checked — refusing"
					sub_kind = "unreadable"
				elseif hash_bytes(content) ~= state.hash then
					reason = refusal_message(path)
					sub_kind = "content_drift"
				end
			end
		end
		if not reason then
			return nil
		end
		local now_st = uv.fs_lstat(path)
		-- EVIDENCE ONLY, never a comparison input: detection above stays BY CONTENT (CORE).
		-- `st_ino`/`st_mtime` are here so a same-bytes-new-inode or a clock-skew story can be
		-- tested from the record instead of guessed at.
		local detail = record_refusal(session, op, {
			reason = reason,
			reason_code = reason_code,
			sub_kind = sub_kind,
			checked = "immediately before the write",
			st_ino = now_st and now_st.ino or nil,
			st_mtime = now_st and now_st.mtime and now_st.mtime.sec or nil,
		})
		return reason, detail
	end

	local function record_temp_identity(session, op, tmp_path)
		if test_state.fault.fail_temp_identity then
			return false, "fault: temp identity unavailable"
		end
		local st = uv.fs_lstat(tmp_path)
		if not st or not st.dev or not st.ino then
			return false, "temp identity unavailable"
		end
		local ok_log, log_err = append_jsonl(journal_path(session), {
			kind = "temp_created",
			op_id = op.op_id,
			path = tmp_path,
			target_path = op.path,
			temp_dev = st.dev,
			temp_ino = st.ino,
			ts = os.time(),
		})
		if not ok_log then
			return false, log_err
		end
		-- Handed back as well as journaled: the rename below installs THIS inode, so
		-- an automatic rollback of this accept knows the identity it would restore
		-- over without observing the path again.
		return true, { dev = st.dev, ino = st.ino }
	end

	local function apply_operation(session, op, opts)
		opts = opts or {}
		local path, perr = resolve_target(session.workspace, op.path, op.raw_rel)
		if not path then
			return false, perr
		end

		-- Mutation/negative-row seam (gate) ONLY: simulates a FUTURE call site
		-- passing an undeclared `reason_code` -- the shape a code review, not a
		-- user, is supposed to catch. `record_refusal` is the sole writer and must
		-- refuse (raise) rather than silently widen the vocabulary.
		if test_state.fault.inject_bad_reason_code then
			record_refusal(session, op, { reason = "test-injected", reason_code = "not_a_declared_code" })
		end

		-- EVIDENCE FIRST, AND COMPLETE. Re-checked here and not only at intent time because
		-- this also runs on a row replayed by a later process, which has no caller to ask and
		-- must not fall back to comparing content alone.
		if not test_state.fault.allow_untagged_base then
			local ok_ev, ev_err, ev_info = evidence_complete(op)
			if not ok_ev then
				ev_info = ev_info or {}
				local detail = record_refusal(session, op, {
					reason = ev_err,
					reason_code = "evidence_error",
					evidence_check = ev_info.evidence_check,
					evidence_rejected = ev_info.evidence_rejected,
				})
				return false, ev_err, detail
			end
		end

		-- Deleting what is already gone is not a no-op to be waved through: the
		-- human removed it during the review, so the turn's evidence is stale.
		-- Refuse by name rather than "succeed" at doing nothing. This is reached
		-- when the file was EMPTY at turn start, where the base-hash check below
		-- cannot tell absence from an empty file.
		if op.op_kind == "delete" and uv.fs_lstat(path) == nil then
			local msg = "refusing to delete " .. path .. ": it is already gone — the file was removed since the turn started"
			-- The child's own identity left no trace, but the parent directory's
			-- does survive absence: evidence only, never a comparison input.
			local parent_st = uv.fs_lstat(vim.fn.fnamemodify(path, ":h"))
			local detail = record_refusal(session, op, {
				reason = msg,
				reason_code = "delete_target_absent",
				expected_state = op.base_state,
				st_ino = parent_st and parent_st.ino or nil,
			})
			return false, msg, detail
		end

		local need
		if op.op_kind == "delete" then
			-- Space for the retained displaced copy, not for target bytes.
			local st = uv.fs_lstat(path)
			need = (st and st.size or 0) + config.min_free_bytes
		else
			need = #op.target * 2 + config.min_free_bytes
		end
		local ok, err = check_space(session, need)
		if not ok then
			return false, err
		end

		local state, oerr = observe_state(path)
		if not state then
			-- The parent directory's own stat, not the target's: an observation
			-- failure at THIS path is usually a permissions or mount fact the
			-- directory it lives in can corroborate, and the raw errno/oerr string
			-- travels in its own field rather than folded only into prose.
			local parent_dir = vim.fn.fnamemodify(path, ":h")
			local parent_st = uv.fs_lstat(parent_dir)
			local detail = record_refusal(session, op, {
				reason = oerr,
				reason_code = "observe_failed",
				oerr = oerr,
				parent_dev = parent_st and parent_st.dev or nil,
				parent_ino = parent_st and parent_st.ino or nil,
				parent_mode = parent_st and parent_st.mode or nil,
			})
			return false, oerr, detail
		end
		local real = state.bytes or ""
		local real_hash = state.kind == "file" and state.hash or hash_bytes("")
		if not state_matches(op, state) then
			local msg = state_refusal(op, path, state)
			-- EVIDENCE ONLY, never comparison inputs: `state_matches` above is the sole
			-- BY-CONTENT decision (CORE) and neither field below feeds it. `st_ino`/`st_mtime`
			-- let a same-bytes-new-inode or a clock-skew story be tested from the record instead
			-- of guessed at. `now_st` is a SEPARATE read from the one `observe_state` took above
			-- (which never captures mtime) — a benign extra lstat, not a second decision.
			local now_st = uv.fs_lstat(path)
			-- WHEN the turn-start fingerprint (`op.base_hash`) was captured. Threaded from the
			-- producer's classifying read (see M.intent / restore_workspace_bytes below); absent
			-- (nil) on any caller that has not been updated to supply it, which is recorded as
			-- absent, never guessed.
			--
			-- Mutation seam (gate), dedicated to this one field rather than the
			-- shared `strip_refusal_evidence`: `omit_base_hash_captured_ts`
			-- reproduces the pre-this-delta `stale_file` record exactly (it already
			-- carried `expected_fp`/`actual_fp`), minus only the capture-time triad
			-- this delta adds.
			local cap_ts, cap_ino, cap_mtime = op.base_hash_captured_ts,
				now_st and now_st.ino or nil,
				now_st and now_st.mtime and now_st.mtime.sec or nil
			if test_state.fault.omit_base_hash_captured_ts then
				cap_ts, cap_ino, cap_mtime = nil, nil, nil
			end
			record_refusal(session, op, {
				reason = msg,
				reason_code = "stale_file",
				expected_state = op.base_state,
				found_state = state.kind,
				expected_hash = op.base_hash,
				found_hash = real_hash,
				base_hash_captured_ts = cap_ts,
				st_ino = cap_ino,
				st_mtime = cap_mtime,
			})
			-- THIRD RETURN: the structured mismatch. Fingerprints are truncated to 16 hex
			-- characters here, the schema's width, and are hashes only: no content crosses this
			-- boundary.
			return false, msg, {
				reason = "stale_file",
				reason_code = "stale_file",
				path = op.path,
				op_id = op.op_id,
				expected_state = op.base_state,
				found_state = state.kind,
				expected_fp = type(op.base_hash) == "string" and op.base_hash:sub(1, 16) or nil,
				actual_fp = type(real_hash) == "string" and real_hash:sub(1, 16) or nil,
				base_hash_captured_ts = cap_ts,
				st_ino = cap_ino,
				st_mtime = cap_mtime,
			}
		end

		if opts.inject_after_hash then
			diff.write_file(path, opts.inject_after_hash)
		end

		local displaced_path = displaced_path_for(session, op.op_id)
		vim.fn.mkdir(session.diary_dir .. "/displaced", "p")
		local cp_ok, cp_err = write_displaced(displaced_path, real)
		if not cp_ok then
			return false, cp_err
		end
		ok, err = fsync_dir(session.diary_dir .. "/displaced")
		if not ok then
			return false, err
		end
		op.displaced_path = displaced_path
		op.displaced_hash = real_hash
		op.displaced_bytes = #real
		-- What this path WAS, carried so the rollback below can restore absence as
		-- absence. An empty displaced copy standing for "there was nothing here"
		-- reads identically to "there was an empty file here", and restoring it
		-- creates a file the human never had.
		op.displaced_state = state.kind
		op.displaced_mode = state.mode

		local ok_disp, err_disp = append_jsonl(journal_path(session), {
			kind = "displaced",
			op_id = op.op_id,
			path = op.path,
			displaced_path = displaced_path,
			displaced_hash = op.displaced_hash,
			displaced_state = op.displaced_state,
			displaced_mode = op.displaced_mode,
			bytes = op.displaced_bytes,
			ts = os.time(),
		})
		if not ok_disp then
			return false, err_disp
		end

		-- Everything above is shared: base revalidated, displaced copy retained and
		-- journaled. Only the action itself differs.
		if op.op_kind == "delete" then
			return apply_delete(session, op, path, displaced_path, state)
		end

		local target_mode = op.target_mode
		if not target_mode then
			local st = uv.fs_stat(path)
			if st and st.mode then
				target_mode = st.mode
			end
		end

		local dir = vim.fn.fnamemodify(path, ":h")
		session.touched_dirs[dir] = true

		-- ONE UNIQUE O_EXCL SIBLING TEMP, AND THE RENAME INSTALLS THAT INODE.
		--
		-- The staging name is an ordinary pathname a user may already own, and
		-- `diff.write_file` replaces whatever it finds there, so accepting `foo` silently
		-- destroyed a legitimate `foo.yana-diary-target` — bytes never displaced, never
		-- journaled, no refusal. CORE: the journaled applier is the sole real-tree writer,
		-- and every write it makes retains a displaced copy. `diff.write_file` already
		-- creates a unique O_EXCL temp in the target's directory and renames it onto the
		local tmp_path
		local installed
		-- Smuggled out of the `on_before_rename` closure below: `diff.write_file`
		-- surfaces only `ok, err` from a failing callback, so the structured detail
		-- travels on this upvalue rather than being lost at that boundary.
		local sub_detail
		local tmp_ok, tmp_err = diff.write_file(path, op.target, {
			target_mode = target_mode,
			on_temp_created = function(t)
				tmp_path = t
				local ok_id, id_or_err = record_temp_identity(session, op, t)
				if not ok_id then
					return false, id_or_err
				end
				installed = id_or_err
				return true
			end,
			on_before_rename = function()
				if test_state.fault.skip_rename then
					return false, "fault: rename skipped"
				end
				if opts.inject_before_rename then
					diff.write_file(path, opts.inject_before_rename)
				end
				local sub, detail = refuse_if_substituted(session, op, path, state, "generic_pre_apply")
				if sub then
					sub_detail = detail
					return false, sub
				end
				return true
			end,
		})
		if not tmp_ok then
			return false, tmp_err, sub_detail
		end
		append_jsonl(journal_path(session), {
			kind = "temp_cleaned",
			op_id = op.op_id,
			path = tmp_path,
			ts = os.time(),
		})

		if opts.inject_after_rename then
			diff.write_file(path, opts.inject_after_rename)
		end

		-- THE ROLLBACK OF A FAILED ACCEPT IS AN AUTOMATIC ONE, AND SAYS SO.
		--
		-- It is not a user revert and it must not be recovered as one: it ends at
		-- `rollback_done` with no `done` row ever written, because the accept it
		-- undoes never verified. `purpose` is what carries that to a later process,
		-- which has only the journal to go on.
		-- WHAT THE ACCEPT ITSELF INSTALLED, NOT A LATER LOOK AT THE PATH.
		--
		-- Both fields are already known and neither needs an observation: the rename put the
		-- temp's inode at the target, recorded above before it happened, and the applier
		-- wrote `op.target` into it, so its fingerprint is the hash of the payload. An
		-- automatic rollback that instead observes the path records whatever is there when it
		-- starts — a human's in-place save included, which keeps the inode — and the restore
		-- then destroys those bytes because the identity still matches and no recorded hash
		local function accept_checked()
			if test_state.fault.rollback_marker_no_hash then
				-- Mutation seam (gate): the pre-fix marker — a fresh observation of the
				-- path, identity only, no content.
				return identity_of(path)
			end
			return {
				kind = "file",
				dev = installed and installed.dev,
				ino = installed and installed.ino,
				hash = hash_bytes(op.target),
			}
		end

		local landed, lerr = read_bytes(path)
		if test_state.fault.fail_read_after_rename then
			-- The accepted bytes ARE on disk; the applier could not read them back to
			-- prove it. This is the frontier where an unrecovered rollback is read as
			-- a completed accept.
			landed, lerr = nil, "injected post-rename read failure"
		end
		if landed == nil then
			local rb_ok, rb_err = journaled_restore(
				session,
				op,
				displaced_path,
				path,
				"read failed after rename",
				{ purpose = "auto", checked = accept_checked() }
			)
			if not rb_ok then
				return false, rb_err or lerr
			end
			return false, lerr
		end
		if hash_bytes(landed) ~= hash_bytes(op.target) then
			local rb_ok, rb_err = journaled_restore(
				session,
				op,
				displaced_path,
				path,
				"post-rename verify failed",
				{ purpose = "auto", checked = accept_checked() }
			)
			if not rb_ok then
				return false, rb_err or "post-rename verify failed"
			end
			return false, "post-rename verify failed"
		end

		ok, err = fsync_dir(dir)
		if not ok then
			return false, err
		end

		if test_state.fault.done_before_fsync then
			ok, err = append_jsonl(journal_path(session), {
				kind = "done",
				op_id = op.op_id,
				path = op.path,
				ts = os.time(),
			})
			if not ok then
				return false, err
			end
		end

		if test_state.fault.crash_before_done then
			session.simulated_crash = op.op_id
			return true
		end

		if not test_state.fault.done_before_fsync then
			ok, err = append_jsonl(journal_path(session), {
				kind = "done",
				op_id = op.op_id,
				path = op.path,
				ts = os.time(),
			})
			if not ok then
				return false, err
			end
		end
		-- LOAD-BEARING, AND NOT FOR THE `done` ROW. The row is already durable from
		-- `append_jsonl`'s file fsync. Its twin on the delete path was removable only because
		-- that path fsyncs the diary directory at `unlink_start`, before its destructive act;
		-- this path has no such earlier flush.
		ok, err = fsync_dir(session.diary_dir)
		if not ok then
			return false, err
		end

		op.applied = true
		return true
	end

	return {
		record_refusal = record_refusal,
		refuse_if_substituted = refuse_if_substituted,
		record_temp_identity = record_temp_identity,
		apply_operation = apply_operation,
	}
end

return M
