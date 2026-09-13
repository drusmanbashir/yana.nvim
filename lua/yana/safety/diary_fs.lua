--
-- Base layer: every op/session-level function in diary.lua calls through here for
-- journal append/read, fsync, path resolution and the diary's size/space checks.
-- Nothing in this file knows about `op` or `session` semantics beyond the plain fields
-- (`session.diary_dir`, `session.stream`, `session.op_seq`, `session.workspace`)
-- already used by the moved code.
local M = {}

function M.new(deps)
	local uv = deps.uv
	local flush = deps.flush
	local diff = deps.diff
	local hash = deps.hash
	local manifest = deps.manifest
	local control_plane = deps.control_plane
	-- Live references (not copies): a test that mutates
	-- `diary._test.fault.x` or `diary._config.max_bytes` at runtime is still
	-- seen here, because these are the SAME tables the parent holds.
	local test_state = deps.test_state
	local config = deps.config

	local function write_all_fd(fd, content)
		local written = 0
		while written < #content do
			if test_state.fault.force_short_write then
				local n = math.min(1, #content - written)
				local ok, werr = uv.fs_write(fd, content:sub(written + 1, written + n), -1)
				if not ok then
					return false, werr
				end
				return false, "forced short write"
			end
			local n, werr = uv.fs_write(fd, content:sub(written + 1), -1)
			if not n then
				return false, werr
			end
			if n == 0 then
				return false, "zero-length write"
			end
			written = written + n
		end
		return true
	end

	local function hash_bytes(s)
		-- Parenthesised: a bare `return f(s)` is a tail call and forwards however
		-- many values f returns, so this alias would silently inherit any future
		-- second return from the hash authority.
		return (hash.hash_bytes(s))
	end

	local function read_bytes(path)
		return diff.read_file_bytes(path)
	end

	local function journal_path(session)
		return session.diary_dir .. "/journal.jsonl"
	end

	local function fsync_path(path)
		local fd, err = uv.fs_open(path, "r", 438)
		if not fd then
			return false, err
		end
		local ok, ferr = flush.fsync(fd)
		uv.fs_close(fd)
		if not ok then
			return false, ferr
		end
		return true
	end

	local function fsync_dir(dir)
		if test_state.fault.fail_dir_fsync then
			return false, "injected directory fsync failure"
		end
		if not uv.fs_open then
			return false, "directory fsync unavailable"
		end
		local fd, err = uv.fs_open(dir, "r", 0)
		if not fd then
			return false, err
		end
		local ok, ferr = flush.fsync(fd)
		uv.fs_close(fd)
		if not ok then
			return false, ferr
		end
		return true
	end

	--- APPEND ONE JOURNAL ROW AND MAKE IT DURABLE.
	---
	--- The `fs_fsync` below is the WHOLE durability of a row. An append changes the file's
	--- CONTENTS and its inode (size, mtime); it does not touch the directory entry that
	--- names the file, and `fsync` — not `fdatasync` — flushes both the data and that
	--- inode. `journal.jsonl` is named in the diary directory exactly once, by `M.begin`,
	--- which fsyncs the diary directory and its parent before it returns a session;
	--- nothing else creates it and there is no rotation.
	---
	--- THAT ARGUMENT IS ABOUT THE ROW, AND ONLY ABOUT THE ROW. It does not license
	--- deleting a `fsync_dir(session.diary_dir)` that follows an append, because two
	--- things create NEW ENTRIES inside the diary directory after `M.begin` has returned:
	--- `apply_operation` creates `displaced/`, and `checkpoint.begin_turn` creates
	--- `checkpoint/<turn>/files`. `fsync_dir(diary_dir ..
	local function append_jsonl(path, row)
		local line = vim.json.encode(row) .. "\n"
		local fd, err = uv.fs_open(path, "a", 438)
		if not fd then
			return false, err
		end
		local ok, werr = write_all_fd(fd, line)
		if not ok then
			uv.fs_close(fd)
			return false, werr
		end
		ok, err = flush.fsync(fd)
		uv.fs_close(fd)
		if not ok then
			return false, err
		end
		return true
	end

	local function read_jsonl(path)
		if vim.fn.filereadable(path) ~= 1 then
			return {}, nil
		end
		local raw, err = read_bytes(path)
		if raw == nil then
			return nil, err or "journal unreadable"
		end
		if raw == "" then
			return {}, nil
		end
		local rows = {}
		local truncated = nil
		local from = 1
		while from <= #raw do
			local nl = raw:find("\n", from, true)
			if nl then
				local line = raw:sub(from, nl - 1)
				if line ~= "" then
					local ok, row = pcall(vim.json.decode, line)
					if not ok or type(row) ~= "table" then
						return nil, "malformed journal row"
					end
					rows[#rows + 1] = row
				end
				from = nl + 1
			else
				truncated = raw:sub(from)
				break
			end
		end
		return rows, truncated
	end

	--- The LEXICAL workspace-relative path — derived WITHOUT following symlinks, so
	--- a `.git` symlink keeps its own name. `abs_path_literal` makes the path
	--- absolute and normalises `.`/`..` but never resolves a symlink component,
	--- which is exactly the evidence the control-plane classifier needs. Returns
	--- nil when the lexical path is not under the workspace.
	local function lexical_rel(workspace, path)
		local ws = diff.abs_path_literal(workspace)
		local p = diff.abs_path_literal(path)
		if p == ws then
			return ""
		end
		if not vim.startswith(p, ws .. "/") then
			return nil
		end
		return p:sub(#ws + 2)
	end

	-- Path safety: no escape above workspace; reject symlink components (N7: hash is
	-- authority); refuse control-plane paths by name; refuse mount crossings.
	--
	-- Applier fail-safe, the last line and independent of the producer/consumer.
	-- `raw_rel`, when supplied, is the SOLE target authority caller-supplied path: it is
	-- validated and classified lexically, and the operation's own `path` may not disagree
	-- with it. Every mutation site — intent, apply_operation, rollback/revert/replay
	-- restore — resolves through here, so a forged or replayed journal cannot push agent
	-- bytes into a repository even if walls 1-3 were bypassed.
	--
	-- TODO: resolve the write from a trusted root descriptor via openat2
	-- RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS|RESOLVE_NO_XDEV. openat2 is unavailable in the
	-- Neovim runtime (file header, line 2), so this is its lstat-walk emulation: lexical
	-- raw_rel authority + control-plane refusal + symlink-component refusal + the st_dev
	-- cross-device check below (NO_XDEV). The one residual a pure-Lua walk cannot close is
	-- a component swapped BETWEEN the walk and the write (a true TOCTOU); only the
	local function resolve_target(workspace, path, raw_rel)
		-- (1) Classify the LEXICAL path BEFORE any symlink resolution. `diff.abs_path`
		-- below follows symlinks (Mac /var vs /private/var), which would turn a
		-- `.git -> admin` alias into an innocent `admin/…` and lose the name the
		-- classifier depends on; the lexical form keeps `.git` named.
		local lex = lexical_rel(workspace, path)
		if raw_rel ~= nil and raw_rel ~= "" then
			local ok_rr, rr_err = manifest.validate_rel(raw_rel)
			if not ok_rr then
				return nil, "raw_rel invalid: " .. tostring(rr_err)
			end
			if control_plane.is_control_plane(raw_rel) then
				return nil, control_plane.refusal(raw_rel)
			end
			-- The persisted authority and the acted-on path must agree. A forged row
			-- with an innocent raw_rel beside a `.git/config` path is refused here.
			if lex ~= nil and lex ~= raw_rel then
				return nil, "raw_rel disagrees with the operation path — refusing (" .. raw_rel .. " vs " .. lex .. ")"
			end
		end
		if lex ~= nil and control_plane.is_control_plane(lex) then
			return nil, control_plane.refusal(lex)
		end

		-- (2) Resolved-path escape check.
		workspace = diff.abs_path(workspace)
		path = diff.abs_path(path)
		if path ~= workspace and not vim.startswith(path, workspace .. "/") then
			return nil, "path escapes workspace"
		end
		local rel = path:sub(#workspace + 2)
		if rel == "" then
			return path, ""
		end
		-- A control-plane segment surfaced only by resolution (a symlink whose
		-- resolved target lands inside a `.git/`) is refused too.
		if control_plane.is_control_plane(rel) then
			return nil, control_plane.refusal(rel)
		end
		-- Bare-repository root: only after proving the workspace is bare,
		-- refuse writes to its top-level git-internal entries (HEAD/objects/refs/…),
		-- which carry no `.git` segment. The proof gate keeps ordinary projects with
		-- a top-level `HEAD`/`refs`/`objects` fully writable.
		if control_plane.is_bare_entry(rel) and control_plane.workspace_is_bare(workspace) then
			return nil, "refused — write into a bare repository root (control-plane): " .. rel
		end

		-- (3) Component walk: reject `..`, reject symlink components, and EMULATE
		-- openat2 RESOLVE_NO_XDEV — a bind mount (e.g. `safe-admin/` bind-mounted
		-- onto `.git/`) is lexically innocent and not a symlink, so the only tell is
		-- that crossing it changes st_dev. Refuse any existing component whose device
		-- differs from the workspace root's, bind mounts included.
		local root_st = uv.fs_lstat(workspace)
		local root_dev = root_st and root_st.dev
		local cur = workspace
		for part in vim.gsplit(rel, "/", { plain = true, trimempty = true }) do
			if part == ".." then
				return nil, "path escapes workspace"
			end
			cur = cur .. "/" .. part
			local st = uv.fs_lstat(cur)
			if st and st.type == "link" then
				return nil, "symlink in path"
			end
			if st and root_dev and st.dev ~= root_dev then
				return nil, "mount crossing in path (control-plane bind-mount guard): " .. cur
			end
		end
		return path, rel
	end

	local function diary_usage(dir)
		local total = 0
		local entries = vim.fn.glob(dir .. "/*", false, true) or {}
		for _, name in ipairs(entries) do
			if vim.fn.isdirectory(name) == 1 then
				total = total + diary_usage(name)
			else
				local st = uv.fs_stat(name)
				if st then
					total = total + st.size
				end
			end
		end
		return total
	end

	local function check_cap(session, extra)
		local cap = test_state.force_cap_bytes or config.max_bytes
		local used = diary_usage(session.diary_dir)
		if used + (extra or 0) > cap then
			return false, "diary size cap exceeded"
		end
		return true
	end

	local function check_space(session, need)
		if test_state.force_no_space then
			return false, "insufficient disk space for diary accept"
		end
		local st = uv.fs_statvfs and uv.fs_statvfs(session.workspace)
		if st and st.bavail and st.bsize and (st.bavail * st.bsize) < need then
			return false, "insufficient disk space for diary accept"
		end
		return true
	end

	--- Retain the displaced copy from the bytes the operation actually checked.
	---
	--- Deliberately NOT a re-read of the target. The displaced copy is the human's
	--- recovery path, so it has to be the same bytes the base-fingerprint check
	--- passed on; re-reading the file here would let a save that landed in between
	--- become "the version this turn displaced", and the bytes the check licensed
	--- the write against would exist nowhere.
	local function write_displaced(dst, content)
		local dir = vim.fn.fnamemodify(dst, ":h")
		vim.fn.mkdir(dir, "p")
		local fd, oerr = uv.fs_open(dst, "w", 438)
		if not fd then
			return false, oerr
		end
		local ok, werr = write_all_fd(fd, content)
		if not ok then
			uv.fs_close(fd)
			return false, werr
		end
		local ferr
		ok, ferr = flush.fsync(fd)
		uv.fs_close(fd)
		if not ok then
			return false, ferr
		end
		return true
	end

	local function load_journal(session)
		local rows, tail = read_jsonl(journal_path(session))
		if not rows then
			return nil, nil, tail
		end
		return rows, tail, nil
	end

	local function next_op_id(session)
		session.op_seq = (session.op_seq or 0) + 1
		return string.format("%s:%d", session.stream, session.op_seq)
	end

	local function op_seq_number(op_id)
		return tonumber(op_id:match(":(%d+)$") or "") or 0
	end

	return {
		write_all_fd = write_all_fd,
		hash_bytes = hash_bytes,
		read_bytes = read_bytes,
		journal_path = journal_path,
		fsync_path = fsync_path,
		fsync_dir = fsync_dir,
		append_jsonl = append_jsonl,
		read_jsonl = read_jsonl,
		lexical_rel = lexical_rel,
		resolve_target = resolve_target,
		diary_usage = diary_usage,
		check_cap = check_cap,
		check_space = check_space,
		write_displaced = write_displaced,
		load_journal = load_journal,
		next_op_id = next_op_id,
		op_seq_number = op_seq_number,
	}
end

return M
