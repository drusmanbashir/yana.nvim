-- Same journal format, same checkpoint-only gate on `write_bytes`, same
-- restore-through-`intent`/`apply_pending` path as before the split.
local M = {}

function M.new(deps)
	local diff = deps.diff
	local control_plane = deps.control_plane
	-- diary_fs base layer
	local op_seq_number = deps.op_seq_number
	local load_journal = deps.load_journal
	local append_jsonl = deps.append_jsonl
	local journal_path = deps.journal_path
	local fsync_dir = deps.fsync_dir
	local resolve_target = deps.resolve_target
	local hash_bytes = deps.hash_bytes
	-- diary_state layer
	local observe_state = deps.observe_state
	local mode_perm = deps.mode_perm
	-- Live reference (not a copy): a test that mutates
	-- `diary._test.force_diary_root` at runtime is still seen here.
	local test_state = deps.test_state
	-- Late-bound: `M.empty_hash`/`M.intent`/`M.apply_pending` are defined
	-- later in diary.lua (the public apply/readers groups), so these
	-- forward through the parent's `M` table rather than capturing a value
	-- before it exists.
	local empty_hash = deps.empty_hash
	local intent = deps.intent
	local apply_pending = deps.apply_pending

	-- Private to this session/write lifecycle; nothing outside this module
	-- reads or writes it.
	local CHECKPOINT_WRITE = false

	local function displaced_path_for(session, op_id)
		local seq = op_seq_number(op_id)
		return session.diary_dir .. "/displaced/" .. tostring(seq) .. ".bin"
	end

	local function session_from_rows(diary_dir, rows)
		local workspace, stream, op_seq, created_at = nil, nil, 0, os.time()
		for _, row in ipairs(rows) do
			if row.kind == "begin" then
				workspace = row.workspace
				stream = row.stream
				created_at = row.ts or created_at
			elseif row.kind == "intent" and row.op_id then
				op_seq = math.max(op_seq, op_seq_number(row.op_id))
			end
		end
		if not workspace then
			return nil, "diary has no begin row"
		end
		return {
			stream = stream or "default",
			workspace = workspace,
			diary_dir = diary_dir,
			op_seq = op_seq,
			crash_after = nil,
			created_at = created_at,
			touched_dirs = {},
		}
	end

	-- Rebuild a diary session by replaying an existing directory's journal.
	local function open(diary_dir)
		diary_dir = diff.abs_path(diary_dir)
		local rows, tail, err = load_journal({ diary_dir = diary_dir })
		if not rows then
			return nil, err
		end
		local session, serr = session_from_rows(diary_dir, rows)
		if not session then
			return nil, serr
		end
		if tail and tail ~= "" then
			session.truncated_journal_tail = tail
		end
		return session
	end

	-- Start a new diary session: create its dir and write a durable begin row.
	local function begin(opts)
		opts = opts or {}
		local workspace = diff.abs_path(opts.workspace or vim.fn.getcwd())
		local stream = opts.stream or "default"
		local diary_dir = opts.diary_dir or test_state.force_diary_root
		if not diary_dir then
			diary_dir = workspace
				.. "/.yana/diary/"
				.. stream
				.. "/"
				.. tostring(os.time())
				.. "-"
				.. tostring(math.random(1, 1e6))
		end
		diary_dir = diff.abs_path(diary_dir)
		local parent = vim.fn.fnamemodify(diary_dir, ":h")
		vim.fn.mkdir(diary_dir, "p")
		local session = {
			stream = stream,
			workspace = workspace,
			diary_dir = diary_dir,
			op_seq = 0,
			crash_after = nil,
			created_at = os.time(),
			touched_dirs = {},
		}
		local ok, err = append_jsonl(journal_path(session), {
			kind = "begin",
			stream = stream,
			workspace = workspace,
			ts = os.time(),
		})
		if not ok then
			return nil, err
		end
		ok, err = fsync_dir(parent)
		if not ok then
			return nil, err
		end
		ok, err = fsync_dir(diary_dir)
		if not ok then
			return nil, err
		end
		return session
	end

	-- Reject a modify payload that has a base but no shadow content (degenerate).
	local function validate_payload(opts)
		opts = opts or {}
		if opts.kind == "modify" and (opts.base or "") ~= "" and (opts.shadow or "") == "" then
			return false, "degenerate empty payload refused"
		end
		return true
	end

	-- Write raw bytes to path; checkpoint-only, refuses control-plane targets.
	local function write_bytes(opts)
		opts = opts or {}
		if not CHECKPOINT_WRITE then
			return false, "diary.write_bytes is internal to checkpoint only"
		end
		local path = opts.path
		-- Control-plane fail-safe on the checkpoint-restore write primitive. When
		-- the workspace and the persisted raw_rel are supplied, re-derive and re-guard the
		-- target through resolve_target — the same immutable matcher, symlink and
		-- mount-crossing checks the applier uses — so a forged checkpoint manifest naming
		-- `.git/config` cannot write the repository. When they are not supplied, fall back to
		-- a lexical full-path control-plane refusal so the primitive is never a silent hole.
		if opts.workspace and opts.raw_rel then
			local abs, perr = resolve_target(opts.workspace, path, opts.raw_rel)
			if not abs then
				return false, perr
			end
			path = abs
		else
			local lit = diff.abs_path_literal(path)
			if control_plane.is_control_plane(lit) then
				return false, "write_bytes refused — control-plane path: " .. lit
			end
		end
		local content = opts.content or ""
		local ok, err = diff.write_file(path, content)
		return ok, err
	end

	-- Arm the checkpoint-only gate so M.write_bytes is allowed to run.
	local function _checkpoint_write_begin()
		CHECKPOINT_WRITE = true
	end

	-- Disarm the checkpoint-only gate after a checkpoint write completes.
	local function _checkpoint_write_end()
		CHECKPOINT_WRITE = false
	end

	--- Restore workspace bytes through the journaled applier (checkpoint revert and
	--- other callers that must not bypass the journal).
	local function restore_workspace_bytes(opts)
		opts = opts or {}
		local session = opts.session
		if not session then
			return false, "no diary session"
		end
		local path = opts.path
		if not path then
			return false, "no path"
		end
		local state, serr = observe_state(path)
		if not state then
			return false, serr
		end
		local base_hash = opts.base_hash
		local base_state = opts.base_state
		local base_mode = opts.base_mode
		local base_link_target = opts.base_link_target
		-- When the caller hands no `base_hash`, this function derives one from a
		-- FRESH read taken right here — so "now" IS the true capture time, not a
		-- proxy. When the caller supplies its own `base_hash`, only that caller
		-- knows when it was taken, so its own `base_hash_captured_ts` (possibly
		-- nil) travels through unchanged rather than being overwritten with this
		-- function's own clock.
		local base_hash_captured_ts = opts.base_hash_captured_ts
		if base_hash == nil then
			base_hash_captured_ts = base_hash_captured_ts or os.time()
			if state.kind == "absent" then
				base_hash = empty_hash()
				base_state = base_state or "absent"
			elseif state.kind == "file" then
				base_hash = state.hash
				base_state = base_state or "file"
				base_mode = base_mode or mode_perm(state.mode)
			elseif state.kind == "link" then
				base_hash = hash_bytes(state.target or "")
				base_state = base_state or "link"
				base_mode = base_mode or mode_perm(state.mode)
				base_link_target = base_link_target or state.target
			else
				return false, "cannot derive base_hash for checkpoint restore at " .. tostring(path)
			end
		end
		local ok, err = intent({
			session = session,
			path = path,
			target = opts.content or "",
			op_kind = opts.op_kind or "replace",
			base_hash = base_hash,
			base_state = base_state,
			base_mode = base_mode,
			base_link_target = base_link_target,
			base_hash_captured_ts = base_hash_captured_ts,
			-- The mode to INSTALL, distinct from `base_mode` which is the mode the
			-- drift check expects to find. A checkpoint restore carries the pre-turn
			-- mode here so `chmod_temp` sets it on the temp before the rename; without
			-- it the replace path falls back to whatever the target wears now, and a
			-- revert put a 755 script back at the umask.
			target_mode = opts.target_mode,
			raw_rel = opts.raw_rel,
			record_only = true,
		})
		if not ok then
			return false, err
		end
		return apply_pending({ session = session, path = path })
	end


	return {
		open = open,
		begin = begin,
		validate_payload = validate_payload,
		write_bytes = write_bytes,
		_checkpoint_write_begin = _checkpoint_write_begin,
		_checkpoint_write_end = _checkpoint_write_end,
		restore_workspace_bytes = restore_workspace_bytes,
		displaced_path_for = displaced_path_for,
	}
end

return M
