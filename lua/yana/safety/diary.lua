-- Accept diary — sole writer of the real tree for shadow acceptance.
-- openat2 unavailable in Neovim runtime: lstat walk enforces RESOLVE_BENEATH|NO_SYMLINKS.
--
-- Amendment 1 (dir-fsync batching): this API applies one file per intent/apply_pending call,
-- so each operation fsyncs touched dirs and writes its own done row immediately after its
-- rename. The safety invariant holds per-op (a done row is never durable before that op's
-- swap). True multi-file batching (all renames → one dir-fsync per folder → done rows) is
-- deferred to Stage 7 when the compose/apply path can batch renames.
--
-- Amendment 2 (off-loop flushes, 2026-08-19): every fsync below goes through
-- `safety/flush.fsync`, which performs it on the libuv threadpool and awaits it
-- with `vim.wait(..., fast_only=true)`. Not one flush is batched, deferred,
-- removed or reordered — same descriptors, same count, same positions, and no
-- statement here runs before the flush ahead of it has answered. Only the
-- operator's editor stops being held for the disk. `the review and apply contract`,
-- "Durability posture".
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

local function write_all_fd(fd, content)
	local written = 0
	while written < #content do
		if M._test.fault.force_short_write then
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
	if M._test.fault.fail_dir_fsync then
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
--- The `fs_fsync` below is the WHOLE durability of a row. An append changes the
--- file's CONTENTS and its inode (size, mtime); it does not touch the directory
--- entry that names the file, and `fsync` — not `fdatasync` — flushes both the
--- data and that inode. `journal.jsonl` is named in the diary directory exactly
--- once, by `M.begin`, which fsyncs the diary directory and its parent before it
--- returns a session; nothing else creates it and there is no rotation. So by
--- the time a row reaches here, the file's directory entry is already durable.
--- Against a PROCESS crash the row survived the moment `fs_write` returned;
--- against POWER LOSS it survives because of the fsync here. Neither needs the
--- diary directory fsynced afterwards.
---
--- THAT ARGUMENT IS ABOUT THE ROW, AND ONLY ABOUT THE ROW. It does not license
--- deleting a `fsync_dir(session.diary_dir)` that follows an append, because two
--- things create NEW ENTRIES inside the diary directory after `M.begin` has
--- returned: `apply_operation` creates `displaced/`, and `checkpoint.begin_turn`
--- creates `checkpoint/<turn>/files`. `fsync_dir(diary_dir .. "/displaced")`
--- covers the entries INSIDE `displaced/`, never the entry FOR it. Until those
--- creations fsync the diary directory where they happen, some later
--- `fsync_dir(session.diary_dir)` is the only barrier that makes the displaced
--- copy — the human's sole recovery path — REACHABLE after power loss, and
--- removing it silently converts that guarantee into a filesystem heuristic.
--- Before deleting one, trace what has been created in the diary directory
--- since the last fsync of it. See the two removals in `apply_delete`.
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
-- Applier fail-safe, the last line and independent of the
-- producer/consumer. `raw_rel`, when supplied, is the SOLE target authority
-- caller-supplied path: it is validated and classified lexically, and the
-- operation's own `path` may not disagree with it. Every mutation site — intent,
-- apply_operation, rollback/revert/replay restore — resolves through here, so a
-- forged or replayed journal cannot push agent bytes into a repository even if
-- walls 1-3 were bypassed.
--
-- TODO: resolve the write from a trusted root
-- descriptor via openat2 RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS|RESOLVE_NO_XDEV.
-- openat2 is unavailable in the Neovim runtime (file header, line 2), so this is
-- its lstat-walk emulation: lexical raw_rel authority + control-plane refusal +
-- symlink-component refusal + the st_dev cross-device check below (NO_XDEV). The
-- one residual a pure-Lua walk cannot close is a component swapped BETWEEN the
-- walk and the write (a true TOCTOU); only the fd-anchored applier closes it,
-- and it is covered by an expected-RED row named as such.
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
	local cap = M._test.force_cap_bytes or M._config.max_bytes
	local used = diary_usage(session.diary_dir)
	if used + (extra or 0) > cap then
		return false, "diary size cap exceeded"
	end
	return true
end

local function check_space(session, need)
	if M._test.force_no_space then
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

--- The observable before-state of one real path, TAGGED.
---
--- change-model: "Each operation records the lower-layer before-state
--- fingerprint, OR ABSENCE, for that touched path." Absence is a state, not a
--- hash of nothing, and neither of them is what an unreadable file is. The old
--- representation collapsed all three onto the empty fingerprint: a present
--- file whose bytes could not be read compared equal to nothing-there, so an
--- accepted deletion passed its check, retained an EMPTY displaced copy, and
--- then unlinked the real file. Every byte of it was destroyed and nothing
--- anywhere held a copy.
---
--- Returns `{ kind = "absent" }`, `{ kind = "link", mode, target }`,
--- `{ kind = "file", bytes, hash, mode, dev, ino }`, or nil plus a named refusal.
local function observe_state(path)
	local st = uv.fs_lstat(path)
	if not st then
		return { kind = "absent" }
	end
	if st.type == "link" then
		local target = uv.fs_readlink(path)
		if not target then
			return nil,
				path
					.. ": this symlink exists but its target could not be read — refusing; nothing was changed"
		end
		return {
			kind = "link",
			mode = st.mode,
			target = target,
		}
	end
	if st.type ~= "file" then
		return nil,
			path
				.. ": this path is a "
				.. tostring(st.type)
				.. ", not a regular file — the applier writes and displaces regular files only, so it refuses"
				.. " rather than act through it; nothing was changed and both versions are intact"
	end
	local content, rerr = read_bytes(path)
	if content == nil then
		return nil,
			path
				.. ": this file exists but could not be read ("
				.. tostring(rerr or "unreadable")
				.. "), so its bytes cannot be retained as a displaced copy — refusing; nothing was changed."
				.. " Make it readable and re-run, or reject this file"
	end
	return {
		kind = "file",
		bytes = content,
		hash = hash_bytes(content),
		mode = st.mode,
		dev = st.dev,
		ino = st.ino,
	}
end

local function mode_perm(mode)
	return mode and (mode % 4096) or nil
end

--- Is this a mode a restore could actually set?
---
--- `uv.fs_chmod` takes a number. A string, a float or a negative is not a mode
--- the applier can apply, and accepting one meant the refusal arrived from
--- inside `chmod_temp` — after the rollback row was durable and after the temp
--- had been written, which is exactly the "wrote a row for something it could
--- not do" the marker discipline forbids.
local function valid_mode(mode)
	return type(mode) == "number" and mode == math.floor(mode) and mode >= 0 and mode <= 0xFFFF
end

--- The identity of one real path, from a single lstat.
---
--- Deliberately weaker than `observe_state`: it never reads the file. An
--- automatic rollback runs after a rename whose result could not be READ at
--- all, and refusing to record what it is about to restore over — because those
--- bytes are unreadable — would leave the failed accept standing for ever.
--- Identity is what a marker must carry; content is recorded beside it only
--- where it is known.
local function identity_of(path)
	local st = uv.fs_lstat(path)
	if not st then
		return { kind = "absent" }
	end
	return { kind = st.type, dev = st.dev, ino = st.ino, mode = st.mode }
end

--- Is this operation's accept-time evidence a COMPLETE TAGGED RECORD?
---
--- Every field the comparison needs is required, and a missing one refuses
--- rather than being compared around. The untagged route this replaces compared
--- by fingerprint alone with absence reading as the empty content, so a path
--- that was ABSENT when the change was prepared and has since been created as an
--- empty file compared EQUAL and was overwritten — the producer gap turned into
--- a licence to destroy a file nothing had read. The evidence is taken by the
--- producer's own classifying read; if it did not reach the applier intact, the
--- honest answer is that drift cannot be judged, which is a refusal.
local function evidence_complete(op)
	local tag = op.base_state
	if tag ~= "absent" and tag ~= "file" and tag ~= "link" then
		return false,
			tostring(op.path)
				.. ": this change carries no recorded before-state (found "
				.. tostring(tag)
				.. "), so whether the real file is the one the change was prepared against cannot be judged"
				.. " — refusing; nothing was changed. Re-run the turn to produce evidence for it"
	end
	if type(op.base_hash) ~= "string" or #op.base_hash ~= 64 or not op.base_hash:match("^%x+$") then
		return false,
			tostring(op.path)
				.. ": this change carries no usable before-fingerprint — refusing; nothing was changed"
	end
	if (tag == "file" or tag == "link") and op.base_mode == nil then
		return false,
			tostring(op.path)
				.. ": this change records a "
				.. tag
				.. " before-state but no mode for it, so a mode-only human change cannot be seen"
				.. " — refusing; nothing was changed"
	end
	if tag == "link" and (type(op.base_link_target) ~= "string" or op.base_link_target == "") then
		return false,
			tostring(op.path)
				.. ": this change records a symlink before-state but no target for it — refusing; nothing was changed"
	end
	return true
end

--- Does the state just observed match the evidence this operation carries?
---
--- `base_state` is the tag, and `evidence_complete` above has already refused
--- anything without one, so the comparison here is exact in every field: absent
--- matches only absent, and type, mode, symlink target and content must all
--- agree.
local function state_matches(op, state)
	-- Mutation seam (gate): the pre-fix content-only fallback for an operation
	-- carrying no tag. It is what made absence and an empty file compare equal.
	if M._test.fault.allow_untagged_base and op.base_state == nil then
		return (state.kind == "absent" and hash_bytes("") or state.hash) == op.base_hash
	end
	if op.base_state ~= state.kind then
		return false
	end
	if state.kind == "absent" then
		return true
	end
	if state.kind == "link" then
		if state.target ~= op.base_link_target then
			return false
		end
		return mode_perm(state.mode) == mode_perm(op.base_mode)
	end
	if mode_perm(state.mode) ~= mode_perm(op.base_mode) then
		return false
	end
	return state.hash == op.base_hash
end

--- Why the observed state is not the recorded one, named for the human.
local function state_refusal(op, path, state)
	if op.base_state == "absent" and state.kind == "file" then
		return path
			.. ": this file did not exist when the change was prepared and something has created it since"
			.. " — refusing to overwrite it; the agent's version is kept in the turn and yours is untouched"
	end
	if op.base_state == "file" and state.kind == "absent" then
		return path
			.. ": this file existed when the change was prepared and has been removed since"
			.. " — refusing to recreate it; re-diff to decide against the current tree"
	end
	if op.base_state == "link" and state.kind == "link" and op.base_link_target and state.target ~= op.base_link_target then
		return path
			.. ": this symlink's target ("
			.. tostring(state.target)
			.. ") differs from the agent's starting copy ("
			.. tostring(op.base_link_target)
			.. ") — refusing; both versions are kept"
	end
	if op.base_state == "file" and state.kind == "file" and op.base_mode and mode_perm(state.mode) ~= mode_perm(op.base_mode) then
		return path
			.. ": this file's mode differs from the agent's starting copy — refusing; both versions are kept"
	end
	if op.base_state == "link" and state.kind == "link" and op.base_mode and mode_perm(state.mode) ~= mode_perm(op.base_mode) then
		return path
			.. ": this symlink's mode differs from the agent's starting copy — refusing; both versions are kept"
	end
	return M.refusal_message(path)
end

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

function M.open(diary_dir)
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

function M.begin(opts)
	opts = opts or {}
	local workspace = diff.abs_path(opts.workspace or vim.fn.getcwd())
	local stream = opts.stream or "default"
	local diary_dir = opts.diary_dir or M._test.force_diary_root
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

function M.validate_payload(opts)
	opts = opts or {}
	if opts.kind == "modify" and (opts.base or "") ~= "" and (opts.shadow or "") == "" then
		return false, "degenerate empty payload refused"
	end
	return true
end

function M.write_bytes(opts)
	opts = opts or {}
	if not CHECKPOINT_WRITE then
		return false, "diary.write_bytes is internal to checkpoint only"
	end
	local path = opts.path
	-- Control-plane fail-safe on the checkpoint-restore write primitive (finding
	-- 3). When the workspace and the persisted raw_rel are supplied, re-derive
	-- and re-guard the target through resolve_target — the same immutable matcher,
	-- symlink and mount-crossing checks the applier uses — so a forged checkpoint
	-- manifest naming `.git/config` cannot write the repository. When they are
	-- not supplied, fall back to a lexical full-path control-plane refusal so the
	-- primitive is never a silent hole.
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

function M._checkpoint_write_begin()
	CHECKPOINT_WRITE = true
end

function M._checkpoint_write_end()
	CHECKPOINT_WRITE = false
end

--- Restore workspace bytes through the journaled applier (checkpoint revert and
--- other callers that must not bypass the journal).
function M.restore_workspace_bytes(opts)
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
	if base_hash == nil then
		if state.kind == "absent" then
			base_hash = M.empty_hash()
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
	local ok, err = M.intent({
		session = session,
		path = path,
		target = opts.content or "",
		op_kind = opts.op_kind or "replace",
		base_hash = base_hash,
		base_state = base_state,
		base_mode = base_mode,
		base_link_target = base_link_target,
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
	return M.apply_pending({ session = session, path = path })
end

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
--- `rollback_start` carries "auto" and `revert_start` carries "revert". A
--- record that says neither is not a record with a default: it is a record that
--- cannot say whether the accept it undoes was ever meant to stand. The old
--- code manufactured the answer at BOTH ends — `opts.purpose or "revert"` where
--- the marker was written and `marker.purpose or "revert"` where it was read —
--- so an automatic rollback whose purpose went missing came back as a user
--- revert and was finished with `revert_done`.
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
	if M._test.fault.gate_purpose_defaulted then
		return "revert"
	end
	return nil
end

--- THE SOLE WRITER OF `rollback_done` AND `revert_done`.
---
--- Forward-declared here because the fresh rollback below it writes completions
--- and the gate it must pass through is defined with the rest of the replay
--- validation further down. Every route that finishes a rollback — the fresh
--- automatic rollback of a failed accept, the fresh user revert, and each
--- recovery branch — appends its completion through this one function, and
--- there is no other appender of those two kinds in this file.
local record_completion

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
--- The record, not the copy. A rollback that cannot say WHAT it is restoring —
--- absence or a file, with which fingerprint, at which mode — is not a rollback,
--- it is a write of unexplained bytes over the human's current file. Each field
--- is required because the restore uses it: the tag decides unlink versus
--- rename, the fingerprint is the only proof the retained bytes are the ones
--- this operation displaced, and the mode is what a restored file is set to.
--- Only the states this applier can actually restore are accepted, and `link`
--- is refused BY NAME rather than by falling off the end of the list. It is a
--- state the producer records and the restore below cannot perform: every
--- non-`absent` branch installs a REGULAR FILE, so accepting a link record
--- meant writing a file holding the symlink's own retained bytes over the
--- human's symlink — a mutation, licensed by a rollback row, of a state nobody
--- implemented. It becomes restorable when link restoration ships, not before.
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
--- Fails closed in every direction: an incomplete journal record, a displaced
--- object that is not a regular file, one that cannot be read, and one whose
--- bytes do not hash to the recorded fingerprint. The old check asked only
--- whether lstat returned something and compared the hash only when one had
--- been recorded, so a truncated copy with no recorded hash, or a displaced
--- path replaced by a directory or a symlink, was installed over the accepted
--- file and only then reported "rollback verify failed".
local function verify_displaced_copy(displaced_path, op)
	-- Mutation seam (gate): the pre-fix laxness — existence only, hash compared
	-- only when one happens to be recorded.
	local lax = M._test.fault.accept_incomplete_displaced
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
	if not M._test.fault.skip_displaced_hash_check then
		if op.displaced_hash and actual ~= op.displaced_hash then
			return false, nil, "displaced copy is corrupted or stale — refusing rollback by name"
		end
	end
	return true, content, op.displaced_hash or actual
end

--- Is a rollback marker's record of the object it checked COMPLETE?
---
--- Every field, and for an automatic rollback no less than for a user revert.
--- Identity alone licenses a restore over an IN-PLACE human save: a shell
--- redirect, an editor that writes through the same inode, any writer that
--- opens and truncates, all keep `(dev, ino)` while replacing every byte. The
--- marker's own fingerprint is the only thing that separates "the object this
--- applier installed, untouched" from "that same inode, since rewritten by the
--- human". A marker that cannot say which bytes it checked is not evidence, and
--- the rollback refuses by name rather than compare around the gap.
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
	if M._test.fault.rollback_marker_no_hash then
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

--- THE RESTORE'S OWN OUTPUT, RECORDED BEFORE ITS RENAME.
---
--- A completed rollback is not "the pre-accept bytes are at the path"; it is
--- "the object THIS applier wrote is at the path". Recovery that classifies by
--- content alone calls a different inode carrying those bytes a finished
--- rollback — a checkout, a backup restore or a second tool can put them there —
--- and writes `rollback_done` over a file it never read. Git draws the same
--- line: it commits the specific tempfile it created, by renaming THAT inode,
--- not any destination that happens to hold equal content.
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
	if M._test.fault.restore_temp_unrecorded then
		return true, nil
	end
	local st = uv.fs_lstat(tmp_path)
	if M._test.fault.fail_restore_temp_identity then
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
--- Not a fresh derivation of what "still accepted" means. The marker that
--- licensed this rollback says which object it checked — `(dev, ino, type)`,
--- plus the fingerprint where one was known — and this compares the path
--- against THAT. A content-only comparison cannot see a different inode
--- carrying the same bytes, and after a `revert_start` that is not a
--- hypothetical: a checkout, a build step or a second tool can leave a file
--- with identical content at the path, and restoring over it destroys work this
--- applier never read.
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
	if M._test.inject and M._test.inject.human_save_before_restore then
		diff.write_file(path, M._test.inject.human_save_before_restore)
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
	if M._test.fault.revert_identity_blind then
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
--- Ordering, not decoration. A directory fsync blocks for as long as the
--- filesystem needs, and it used to sit BETWEEN the revalidation and the
--- rename: a human save landing while it blocked was checked before it existed
--- and overwritten a moment later. Durability first, the check last, the rename
--- immediately after it. The injection below is that save, at exactly the
--- instant the window is open.
local function fsync_dir_before_restore(dir, path)
	local ok, err = fsync_dir(dir)
	if not ok then
		return false, err
	end
	if M._test.inject and M._test.inject.human_save_during_restore_fsync then
		diff.write_file(path, M._test.inject.human_save_during_restore_fsync)
	end
	return true
end

--- Restore what one operation displaced, through the journal.
---
--- `opts.purpose` is the half of the marker state machine that recovery cannot
--- infer from the rows: a USER REVERT of a completed accept, or the AUTOMATIC
--- rollback of an accept whose post-rename verification failed. They finish
--- differently — a revert ends at `revert_done`, an automatic rollback ends at
--- `rollback_done` with the accept undone and no `done` row ever written — and a
--- crash in either is resolved from this field. Without it, recovery fell
--- through to the ordinary accept three-way, which is how an accept that FAILED
--- verification got applied a second time.
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
	-- This used to read `opts.purpose or "revert"`, which meant a caller that
	-- named no purpose did not get a refusal, it got a `rollback_start` claiming
	-- the accept it undoes had been a user's own revert. Every caller happening
	-- to pass one is a property of today's call sites, not of the marker; the
	-- marker is the only thing a later process has, so it is the marker that must
	-- be refused when it cannot say this.
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
	if M._test.fault.crash_after_rollback_start then
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

			-- THE RETAINED COPY IS DURABLE BEFORE THE UNLINK, AND SO IS ITS
			-- DIRECTORY ENTRY. `write_displaced` fsyncs the file it wrote; an
			-- fsync of a file says nothing about the directory that names it, so
			-- a crash here left a durable journal row saying a copy had been
			-- retained, a deleted target, and no copy — the object's bytes
			-- surviving nowhere. Copy, then its directory, then the row that
			-- claims both, then the check, then the removal.
			local function retain_found()
				local keep_ok, keep_err = write_displaced(kept, found)
				if not keep_ok then
					return false, keep_err
				end
				local sync_ok, sync_err
				if M._test.fault.fail_retained_dir_fsync then
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
			local retain_late = M._test.fault.retain_after_unlink
			if not retain_late then
				local keep_ok, keep_err = retain_found()
				if not keep_ok then
					return false, keep_err
				end
				-- Crash point: the retained copy and its row are durable and the
				-- object is still there. Nothing is lost either way.
				if M._test.fault.crash_after_rollback_found then
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
				if M._test.fault.crash_after_rollback_found then
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

	-- One unique O_EXCL sibling temp, and the rename installs THAT inode. The
	-- deterministic `<path>.yana-diary-rollback` this used to write through
	-- was a real, user-addressable pathname: a rollback of `foo` destroyed a
	-- legitimate `foo.yana-diary-rollback` whose bytes were never displaced
	-- and never journaled. `diff.write_file` owns that temp-and-rename sequence
	-- already; the hooks below keep the mode check and the pre-rename directory
	-- fsync this path had.
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
			if M._test.fault.restore_fsync_after_revalidate then
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
	if M._test.fault.crash_before_rollback_done then
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

--- THE DRIFT CHECK, ONE SYSCALL BEFORE THE ACT.
---
--- CORE: "The human's change is detected per touched path, by content
--- fingerprint, READ IMMEDIATELY BEFORE THE WRITE." The base check above is not
--- that: between it and the rename the applier copies the displaced version,
--- fsyncs it, appends journal rows, writes and fsyncs the new content, and
--- fsyncs directories. A human save landing anywhere in that window was
--- overwritten, and the displaced copy held the bytes from BEFORE the save, so
--- the human's own text survived nowhere. This runs last, so the window is one
--- rename or one unlink wide.
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
local function refuse_if_substituted(session, op, path, state)
	local repath, rerr = resolve_target(session.workspace, op.path, op.raw_rel)
	local reason
	if not repath or repath ~= path then
		reason = tostring(op.path)
			.. ": "
			.. tostring(rerr or "the target no longer resolves to the location that was checked")
	else
		local now = uv.fs_lstat(path)
		if state.kind == "absent" then
			if now ~= nil then
				reason = path
					.. ": this path did not exist when the change was checked and something has created it since"
					.. " — refusing; your file is untouched"
			end
		elseif not now then
			reason = path .. ": this file was removed after its contents were checked — refusing; nothing was written"
		elseif now.type ~= "file" then
			reason = path
				.. ": this file was replaced by a "
				.. tostring(now.type)
				.. " after its contents were checked — refusing; it is left exactly as found"
		elseif now.dev ~= state.dev or now.ino ~= state.ino then
			reason = path
				.. ": this path resolves to a different object than the one whose contents were checked"
				.. " — refusing; it is left exactly as found"
		else
			local content = read_bytes(path)
			if content == nil then
				reason = path .. ": this file became unreadable after its contents were checked — refusing"
			elseif hash_bytes(content) ~= state.hash then
				reason = M.refusal_message(path)
			end
		end
	end
	if not reason then
		return nil
	end
	append_jsonl(journal_path(session), {
		kind = "refused",
		op_id = op.op_id,
		path = op.path,
		reason = reason,
		checked = "immediately before the write",
		ts = os.time(),
	})
	return reason
end

local function record_temp_identity(session, op, tmp_path)
	if M._test.fault.fail_temp_identity then
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

	if M._test.fault.skip_unlink then
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
	if not M._test.fault.skip_unlink_start_marker then
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
		-- LOAD-BEARING, AND NOT FOR THE ROW ABOVE. The marker itself is already
		-- durable from `append_jsonl`'s file fsync. This flush is here for the
		-- ENTRY `apply_operation` created a moment ago: `displaced/` is a new
		-- name inside the diary directory, and `fsync_dir(diary_dir/displaced)`
		-- covers what is inside it, never the entry FOR it. Without this, a power
		-- loss after the unlink below can leave the target gone and the displaced
		-- copy unreachable — the one case CORE forbids, both versions retained.
		-- It is deliberately BEFORE the destructive act. Do not delete it because
		-- the two flushes further down this function were deleted.
		local ok_sync, sync_err = fsync_dir(session.diary_dir)
		if not ok_sync then
			return false, sync_err
		end
	end

	-- Crash point: the marker is durable and nothing has happened yet. Replay
	-- must find the original object untouched and redo the deletion.
	if M._test.fault.crash_before_unlink then
		session.simulated_crash = op.op_id
		return true
	end

	-- NOTHING BETWEEN THIS CHECK AND THE UNLINK.
	local sub = refuse_if_substituted(session, op, path, state)
	if sub then
		return false, sub
	end

	local un_ok, un_err = uv.fs_unlink(path)
	if not un_ok then
		return false, tostring(un_err)
	end

	-- Crash point: the object is gone and `unlink_done` is not durable yet. This
	-- is the frontier the pre-unlink marker above exists for, and the recreation
	-- injected here is the case that used to be deleted a second time.
	if M._test.fault.crash_after_unlink then
		if M._test.inject and M._test.inject.recreate_after_unlink_from then
			-- Renamed in from an object that already existed while the original
			-- did, so its identity provably differs from the freed one. Writing a
			-- fresh file here can be handed the just-released inode number, which
			-- would make the probe describe inode reuse rather than recreation.
			uv.fs_rename(M._test.inject.recreate_after_unlink_from, path)
		elseif M._test.inject and M._test.inject.recreate_after_unlink then
			diff.write_file(path, M._test.inject.recreate_after_unlink)
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
	-- `displaced/` entry created by `apply_operation` reachable — was already
	-- paid by the `unlink_start` site above, which fsyncs the diary directory
	-- BEFORE the unlink, where the barrier belongs. Between that fsync and this
	-- point the only things that happened were an append to the existing journal
	-- and an unlink of a path in the WORKSPACE — no name in the diary directory
	-- was created, so this call had nothing left to flush.
	--
	-- DO NOT DELETE THE NEIGHBOURS BY ANALOGY. The `unlink_start` fsync above,
	-- `fsync_dir(dir)` below (the unlink is a directory operation and that is
	-- what makes the removal itself durable), `fsync_dir(diary_dir/displaced)`
	-- after the displaced copy, the two in `M.begin`, and the one after the
	-- `done` row of a REPLACE are all load-bearing for a reason this comment does
	-- not cover.

	if M._test.inject and M._test.inject.recreate_after_unlink then
		diff.write_file(path, M._test.inject.recreate_after_unlink)
	end

	if M._test.fault.crash_before_delete_conflict then
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
	if M._test.fault.crash_before_done then
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

local function apply_operation(session, op, opts)
	opts = opts or {}
	local path, perr = resolve_target(session.workspace, op.path, op.raw_rel)
	if not path then
		return false, perr
	end

	-- EVIDENCE FIRST, AND COMPLETE. Re-checked here and not only at intent time
	-- because this also runs on a row replayed by a later process, which has no
	-- caller to ask and must not fall back to comparing content alone.
	if not M._test.fault.allow_untagged_base then
		local ok_ev, ev_err = evidence_complete(op)
		if not ok_ev then
			append_jsonl(journal_path(session), {
				kind = "refused",
				op_id = op.op_id,
				path = op.path,
				reason = ev_err,
				ts = os.time(),
			})
			return false, ev_err
		end
	end

	-- Deleting what is already gone is not a no-op to be waved through: the
	-- human removed it during the review, so the turn's evidence is stale.
	-- Refuse by name rather than "succeed" at doing nothing. This is reached
	-- when the file was EMPTY at turn start, where the base-hash check below
	-- cannot tell absence from an empty file.
	if op.op_kind == "delete" and uv.fs_lstat(path) == nil then
		local msg = "refusing to delete " .. path .. ": it is already gone — the file was removed since the turn started"
		append_jsonl(journal_path(session), {
			kind = "refused",
			op_id = op.op_id,
			path = op.path,
			reason = msg,
			ts = os.time(),
		})
		return false, msg
	end

	local need
	if op.op_kind == "delete" then
		-- Space for the retained displaced copy, not for target bytes.
		local st = uv.fs_lstat(path)
		need = (st and st.size or 0) + M._config.min_free_bytes
	else
		need = #op.target * 2 + M._config.min_free_bytes
	end
	local ok, err = check_space(session, need)
	if not ok then
		return false, err
	end

	local state, oerr = observe_state(path)
	if not state then
		append_jsonl(journal_path(session), {
			kind = "refused",
			op_id = op.op_id,
			path = op.path,
			reason = oerr,
			ts = os.time(),
		})
		return false, oerr
	end
	local real = state.bytes or ""
	local real_hash = state.kind == "file" and state.hash or hash_bytes("")
	if not state_matches(op, state) then
		local msg = state_refusal(op, path, state)
		append_jsonl(journal_path(session), {
			kind = "refused",
			op_id = op.op_id,
			path = op.path,
			reason = msg,
			expected_state = op.base_state,
			found_state = state.kind,
			expected_hash = op.base_hash,
			found_hash = real_hash,
			ts = os.time(),
		})
		-- THIRD RETURN: the structured mismatch. The journal already held the
		-- reason class and both fingerprints, but the only thing that escaped
		-- this function was a prose string, so the recording site several
		-- layers up could say no more than "shadow_accept_failed" — with no
		-- expected/actual pair, which is precisely what the logging schema
		-- requires of a drift refusal. Fingerprints are truncated to 16 hex
		-- characters here, the schema's width, and are hashes only: no content
		-- crosses this boundary.
		return false, msg, {
			reason = "stale_file",
			expected_state = op.base_state,
			found_state = state.kind,
			expected_fp = type(op.base_hash) == "string" and op.base_hash:sub(1, 16) or nil,
			actual_fp = type(real_hash) == "string" and real_hash:sub(1, 16) or nil,
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
	-- This used to stage through `<path>.yana-diary-target` and rename that
	-- name over the target. The staging name is an ordinary pathname a user may
	-- already own, and `diff.write_file` replaces whatever it finds there, so
	-- accepting `foo` silently destroyed a legitimate `foo.yana-diary-target`
	-- — bytes never displaced, never journaled, no refusal. CORE: the journaled
	-- applier is the sole real-tree writer, and every write it makes retains a
	-- displaced copy. `diff.write_file` already creates a unique O_EXCL temp in
	-- the target's directory and renames it onto the destination, so writing the
	-- target directly is both shorter and the correction: no deterministic,
	-- user-addressable staging name exists at any point.
	local tmp_path
	local installed
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
			if M._test.fault.skip_rename then
				return false, "fault: rename skipped"
			end
			if opts.inject_before_rename then
				diff.write_file(path, opts.inject_before_rename)
			end
			local sub = refuse_if_substituted(session, op, path, state)
			if sub then
				return false, sub
			end
			return true
		end,
	})
	if not tmp_ok then
		return false, tmp_err
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
	-- Both fields are already known and neither needs an observation: the rename
	-- put the temp's inode at the target, recorded above before it happened, and
	-- the applier wrote `op.target` into it, so its fingerprint is the hash of the
	-- payload. An automatic rollback that instead observes the path records
	-- whatever is there when it starts — a human's in-place save included, which
	-- keeps the inode — and the restore then destroys those bytes because the
	-- identity still matches and no recorded hash contradicts it.
	local function accept_checked()
		if M._test.fault.rollback_marker_no_hash then
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
	if M._test.fault.fail_read_after_rename then
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

	if M._test.fault.done_before_fsync then
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

	if M._test.fault.crash_before_done then
		session.simulated_crash = op.op_id
		return true
	end

	if not M._test.fault.done_before_fsync then
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
	-- `append_jsonl`'s file fsync. This is the ONLY flush of the diary directory
	-- anywhere on the replace path after `apply_operation` created `displaced/`
	-- and `checkpoint.begin_turn` created `checkpoint/<turn>/files`, so it is the
	-- only thing that makes the displaced copy — the human's sole recovery path
	-- — reachable after power loss rather than trusting a filesystem heuristic.
	-- Its twin on the delete path was removable only because that path fsyncs the
	-- diary directory at `unlink_start`, before its destructive act; this path has
	-- no such earlier flush. Placement is the standing weakness: this barrier
	-- lands AFTER the rename, so a power loss between the target-directory fsync
	-- above and this one still leaves an accepted swap with an unreachable
	-- displaced copy. Fixing that means fsyncing the diary directory where those
	-- entries are CREATED, not deleting this.
	ok, err = fsync_dir(session.diary_dir)
	if not ok then
		return false, err
	end

	op.applied = true
	return true
end

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

	ok, err = apply_operation(session, op, {})
	return ok, err
end

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

--- Is the pre-accept state this operation displaced the state at the path now?
---
--- Kept because it is precisely the test that is NOT sufficient for a file: it
--- names bytes and cannot name an object. The mutation seam in
--- `complete_rollback` restores it as the classifier.
local function displaced_state_present(disp, state)
	if disp.displaced_state == "absent" then
		return state.kind == "absent"
	end
	if disp.displaced_state == "file" then
		return state.kind == "file" and state.hash == disp.displaced_hash
	end
	return false
end

--- Is what is at the path THIS ROLLBACK'S OWN RESTORED OUTPUT?
---
--- Absence has no identity — an unlink either happened or it did not, and there
--- is no second absence a substitution could supply — so a restored absence is
--- classified by absence alone. A restored FILE does have an identity, and it is
--- the one the restore-temp marker recorded before its rename. Identity,
--- fingerprint, type and mode must all agree with THAT record: a different
--- object carrying the displaced bytes is not this applier's output, whatever it
--- contains, and calling it one writes `rollback_done` over a file the applier
--- never read.
--- Is the restore-temp record COMPLETE, and is it THIS operation's?
---
--- The same demand `checked_record_complete` makes of the rollback marker, made
--- of the marker on the other side of the action. A record consumed field by
--- field is believed field by field: whatever it happens to carry is compared
--- and whatever it omits is silently skipped, so an absent type or mode
--- narrowed the test instead of failing it, and nothing at all tied the record
--- to the operation replay was recovering. Validated whole and up front, an
--- incomplete record is not weaker evidence, it is no evidence: the record
--- names the object this applier installed, and one that cannot say its state,
--- its identity, its bytes, its mode and which target it was written for cannot
--- name anything.
local function restore_record_complete(restored, op)
	if type(restored) ~= "table" then
		return false
	end
	-- Mutation seam (gate): the pre-fix reader, which took the record apart
	-- rather than validating it, and asked nothing of the fields it did not use.
	if M._test.fault.restore_record_partial then
		return true
	end
	if restored.restored_state ~= "file" then
		return false
	end
	if type(restored.temp_dev) ~= "number" or type(restored.temp_ino) ~= "number" then
		return false
	end
	if
		type(restored.restored_hash) ~= "string"
		or #restored.restored_hash ~= 64
		or not restored.restored_hash:match("^%x+$")
	then
		return false
	end
	if type(restored.restored_mode) ~= "number" then
		return false
	end
	-- A complete record of SOME OTHER restore is not this one's output. Recovery
	-- indexes these rows by operation, so a mismatch here is a journal that does
	-- not mean what the index assumed, not a lookup that can be trusted anyway.
	if restored.op_id ~= op.op_id or restored.target_path ~= op.path then
		return false
	end
	return true
end

--- THE ONE GATE EVERY ROLLBACK ROW PASSES THROUGH.
---
--- Not a check per branch. Validation written branch by branch is validation
--- one branch can be reached without: `rollback_done` was honoured — and
--- `revert_done` appended behind it — before a single field of the marker had
--- been looked at, and a settled `revert_done` was counted without reading the
--- marker at all. Each of those routes was individually defensible and the set
--- of them was not, because "every route is guarded" was never a property of
--- the code, only a claim about it. One gate in front of the whole state
--- machine makes it a property: a branch that is not gated is a branch that
--- cannot be reached.
---
--- What the gate demands, of a completion no less than of a classification:
---
---   * a marker at all — an absent one licenses nothing;
---   * a purpose from the enum, EXACTLY. `rollback_start` carries "auto" and
---     `revert_start` carries "revert"; a record that says neither is not a
---     record with a default, it is a record that cannot say whether the accept
---     it undoes was ever meant to stand. Defaulting it to "revert" turned a
---     silent marker into a licence to write `revert_done`;
---   * the marker and the operation agreeing on `op_id` and target — recovery
---     indexes these rows by operation, so a mismatch is a journal that does not
---     mean what the index assumed;
---   * the complete checked record, by the same rule as everywhere else;
---   * whenever a completion is claimed at all, the COMPLETE displaced record
---     for this operation, agreeing with it on `op_id` and target. A completion
---     resting on no record of what was displaced is a completion recovery
---     cannot check, not one with nothing to check;
---   * and, when that validated record says `file`, the restore-temp record that
---     names the object the applier installed. A claimed completion with no such
---     record is a completion nobody can tie to an object. Which of the two is
---     demanded is read off the validated displaced state, never off its absence.
---
--- Any failure is conflict, and conflict appends nothing: the journal comes out
--- byte-identical to the one recovery found.
---
--- It is the gate at BOTH ends of the state machine. `record_completion` below
--- is the sole appender of `rollback_done` and `revert_done` and calls this
--- first, so a completion row is not merely honoured through one gate, it is
--- written through the same one.
local function rollback_record_complete(marker, op, path, disp, restored, completion_claimed)
	if type(marker) ~= "table" then
		return false,
			path
				.. ": no rollback marker licenses this operation, so recovery cannot say what was checked or why"
				.. " — refusing; nothing was changed"
	end
	if not rollback_purpose(marker.purpose) then
		return false,
			path
				.. ": the marker licensing this rollback records no purpose it could be recovered under (found "
				.. tostring(marker.purpose)
				.. "), so recovery cannot tell a user revert from the rollback of a failed accept — refusing;"
				.. " nothing was changed"
	end
	if marker.op_id ~= op.op_id or marker.path ~= op.path then
		return false,
			path
				.. ": the marker licensing this rollback was written for a different operation ("
				.. tostring(marker.op_id)
				.. " at "
				.. tostring(marker.path)
				.. ") — refusing; nothing was changed"
	end
	local ok_rec, rec_err = checked_record_complete({
		kind = marker.checked_type,
		dev = marker.checked_dev,
		ino = marker.checked_ino,
		hash = marker.checked_hash,
	}, path)
	if not ok_rec then
		return false, rec_err
	end
	-- Mutation seam (gate): the pre-fix demand, made conditional on the very
	-- record it was meant to check. `disp and disp.displaced_state == "file"`
	-- asked for the restore-temp record only when a displaced record happened to
	-- be present and happened to say `file`, so a journal whose `displaced` row
	-- was missing answered neither question and fell straight through.
	local lax_disp = M._test.fault.completion_disp_unchecked
	local restore_required = completion_claimed and disp ~= nil and disp.displaced_state == "file"
	if completion_claimed and not lax_disp then
		-- THE DISPLACED RECORD, WHOLE, BEFORE ANYTHING IS DECIDED FROM IT.
		--
		-- An absent record is not a completion with nothing to check, it is a
		-- completion nobody can check: recovery cannot say what this operation
		-- displaced, so it cannot say whether an object was installed, so it
		-- cannot say whether the restore-temp record it also lacks was required.
		-- Silence deciding its own sufficiency is exactly how the resumed
		-- `rollback_done` route reached a `revert_done` with neither row on disk.
		-- Absent is conflict, never fall-through.
		if type(disp) ~= "table" then
			return false,
				path
					.. ": this rollback claims a completion and the diary records nothing it displaced, so recovery"
					.. " cannot say what the completion is supposed to have restored — refusing; nothing was changed"
		end
		local ok_disp, disp_err = displaced_record_complete(disp)
		if not ok_disp then
			return false, disp_err
		end
		-- Recovery indexes these rows by operation. A complete record of some
		-- OTHER operation's displacement decides this completion against the wrong
		-- object, which is a journal that does not mean what the index assumed.
		if disp.op_id ~= op.op_id or disp.path ~= op.path then
			return false,
				path
					.. ": the displaced record this completion rests on was written for a different operation ("
					.. tostring(disp.op_id)
					.. " at "
					.. tostring(disp.path)
					.. ") — refusing; nothing was changed"
		end
		-- Decided from the VALIDATED state, so "no restore-temp record required"
		-- is something the journal said and not something its silence allowed.
		restore_required = disp.displaced_state == "file"
	end
	if restore_required and not restore_record_complete(restored, op) then
		return false,
			path
				.. ": this rollback claims a completed file restore and the record of the object it installed is"
				.. " missing or incomplete, so recovery cannot recognise its own output — refusing; nothing was"
				.. " changed"
	end
	return true
end

--- APPEND A COMPLETION ROW. THE ONLY PLACE EITHER KIND IS APPENDED.
---
--- The gate above was in front of every route recovery could take and in front
--- of none of the routes that WRITE. A fresh automatic rollback appended
--- `rollback_done` from inside the restore, a fresh user revert appended
--- `revert_done` straight after it, and each recovery branch appended its own —
--- five appenders, one gate, and "every completion is validated" was again a
--- claim about the code rather than a property of it.
---
--- So the appender and the gate are one function. A completion row exists only
--- because this returned true, and this returns true only for a marker that
--- names its operation, its purpose from the enum, the object it checked, and —
--- for a file restore — the object the applier installed. A completion is always
--- claimed here: something is about to assert one on disk.
---
--- The refusal is the caller's to report. On a fresh rollback it aborts the
--- rollback; on recovery it becomes the conflict. Either way nothing is
--- appended: a journal that cannot license a completion comes out unchanged.
function record_completion(session, kind, op, path, ctx)
	-- Mutation seam (gate): the pre-fix writers, each branch appending its own
	-- completion row with nothing in front of it.
	if not M._test.fault.completion_writer_bypassed then
		local ok_gate, gate_err =
			rollback_record_complete(ctx.marker, op, path, ctx.disp, ctx.restored, true)
		if not ok_gate then
			return false, gate_err
		end
	end
	local ok, err = append_jsonl(journal_path(session), {
		kind = kind,
		op_id = op.op_id,
		path = op.path,
		ts = os.time(),
	})
	if not ok then
		return false, err
	end
	return fsync_dir(session.diary_dir)
end

local function restore_output_present(disp, restored, st, state)
	if disp.displaced_state == "absent" then
		return st.kind == "absent"
	end
	if disp.displaced_state ~= "file" or st.kind ~= "file" or state == nil then
		return false
	end
	-- Classification only. The record itself was validated whole by
	-- `rollback_record_complete` at replay entry, before this or any other branch
	-- was reached; repeating it here is the branch-by-branch structure the gate
	-- replaced.
	if type(restored) ~= "table" then
		return false
	end
	if st.dev ~= restored.temp_dev or st.ino ~= restored.temp_ino then
		return false
	end
	if state.hash ~= restored.restored_hash then
		return false
	end
	if state.hash ~= disp.displaced_hash then
		return false
	end
	return mode_perm(st.mode) == mode_perm(restored.restored_mode)
end

--- Finish, or refuse, a rollback that a crash caught mid-flight.
---
--- ONE state machine for both purposes, because a crash leaves the same rows
--- either way and only the marker says which it was. A user revert ends at
--- `revert_done`; an automatic rollback of a failed accept ends at
--- `rollback_done`, with the accept undone and no `done` row. Neither is ever
--- routed through the ordinary accept three-way — that reads the restored
--- pre-accept bytes as "equals old, redo" and applies the very accept whose
--- verification failed, a second time.
---
--- Four outcomes, decided from the markers plus the state on disk, and never
--- more than one action:
---
---  * already restored — the pre-accept state is at the path, so what is missing
---    is bookkeeping and the file is not touched again;
---  * still the checked object — the restore never landed, so it is performed
---    now, through the journaled restore with its own displaced-copy
---    verification and its own drift check one syscall before the rename;
---  * conflict — the path holds neither, so someone else owns those bytes and
---    this recovery leaves them exactly as found;
---  * pending — recovery was asked to report, not to act.
---
--- "Still the checked object" is decided against the MARKER's recorded identity,
--- not against a fresh idea of what the accepted result looked like. A different
--- inode carrying the same bytes is a conflict: content cannot tell those apart
--- and `(dev, ino)` can.
local function complete_rollback(session, op, disp, marker, opts)
	opts = opts or {}
	local path, perr = resolve_target(session.workspace, op.path, op.raw_rel)
	if not path then
		return "failure", perr
	end

	-- THE GATE, ONCE, IN FRONT OF EVERY BRANCH BELOW.
	--
	-- Settled `revert_done`, `rollback_done`, already-restored, redo and pending
	-- are all reached from here and none of them is reached before this returns.
	-- A completion is CLAIMED when a row on disk already asserts one — the
	-- `rollback_done` this is finishing the bookkeeping for, or the `revert_done`
	-- a settled operation is being counted on — and also when a `restore_temp`
	-- record exists for a file restore, because that record is the claim that an
	-- object was installed and the already-restored test below decides purely by
	-- believing it. The redo route has no such record and demands none: nothing
	-- was installed there, which is exactly why it is redone.
	local completion_claimed = opts.rollback_done
		or opts.settled
		or (disp ~= nil and disp.displaced_state == "file" and opts.restored ~= nil)
	-- Mutation seam (gate): the pre-fix replay entry, which classified first and
	-- asked what the marker recorded only if it got as far as the restore.
	if not M._test.fault.replay_entry_unvalidated then
		local ok_gate, gate_err =
			rollback_record_complete(marker, op, path, disp, opts.restored, completion_claimed and true or false)
		if not ok_gate then
			return "conflict", gate_err
		end
	end

	-- Never defaulted. The gate above refused any marker that could not say this,
	-- and this reads it through the SAME admitting function rather than taking
	-- the field raw — one enum, one place, both ends.
	local purpose = rollback_purpose(marker and marker.purpose)

	-- The evidence this operation's completions are written against, assembled
	-- once. Every `record_completion` below passes it unchanged.
	local completion_ctx = { marker = marker, disp = disp, restored = opts.restored }

	if opts.settled then
		-- Already finished, and the evidence that says so has just been validated
		-- whole. Counting it appends nothing and touches no file.
		return "reverted"
	end

	if opts.rollback_done then
		-- The restore landed and was verified before `rollback_done` was written.
		-- Only bookkeeping is missing, so this touches no file at all.
		if purpose ~= "revert" then
			return "rolled_back"
		end
		local ok, err = record_completion(session, "revert_done", op, path, completion_ctx)
		if not ok then
			return "failure", err
		end
		return "reverted"
	end

	-- The marker's own record, carried forward into the classification and the
	-- restore below. Rebuilt from nothing the gate did not already prove.
	local checked = {
		kind = marker and marker.checked_type,
		dev = marker and marker.checked_dev,
		ino = marker and marker.checked_ino,
		hash = marker and marker.checked_hash,
	}

	if not disp or not disp.displaced_path then
		return "failure", "no displaced copy recorded for " .. tostring(op.op_id)
	end

	-- Observed without insisting the object be readable: an automatic rollback
	-- exists precisely because the applier could not read what it had just
	-- written, and refusing to recover that would strand it for ever.
	local st = identity_of(path)
	local state = nil
	if st.kind == "absent" then
		state = { kind = "absent" }
	elseif st.kind == "file" then
		local content = read_bytes(path)
		if content ~= nil then
			state = { kind = "file", hash = hash_bytes(content), mode = st.mode, dev = st.dev, ino = st.ino }
		end
	end

	local already
	if M._test.fault.restored_by_bytes then
		-- Mutation seam (gate): the pre-fix classifier — the displaced state and
		-- its fingerprint, with no idea which object carries them.
		already = state ~= nil and displaced_state_present(disp, state)
	else
		already = restore_output_present(disp, opts.restored, st, state)
	end
	if already then
		local ok, err = record_completion(session, "rollback_done", op, path, completion_ctx)
		if not ok then
			return "failure", err
		end
		if purpose ~= "revert" then
			return "rolled_back"
		end
		ok, err = record_completion(session, "revert_done", op, path, completion_ctx)
		if not ok then
			return "failure", err
		end
		return "reverted"
	end

	local licensed = false
	if M._test.fault.revert_identity_blind then
		-- Mutation seam (gate): the pre-fix test, which asked only whether the
		-- bytes at the path were the accepted result's. A different inode holding
		-- those bytes answered yes.
		licensed = state ~= nil and accepted_state_for_revert(op, state)
	elseif marker and marker.checked_type then
		licensed = st.kind == marker.checked_type
			and (
				st.kind == "absent"
				or (
					marker.checked_dev ~= nil
					and marker.checked_ino ~= nil
					and st.dev == marker.checked_dev
					and st.ino == marker.checked_ino
				)
			)
			-- MANDATORY EQUALITY, NOT AN OPTIONAL ONE. Entry validation above has
			-- already refused any file marker without a fingerprint, so there is no
			-- hashless marker left here to accommodate; a nil that still arrived
			-- would name bytes nobody checked, and treating it as agreement is
			-- precisely how an in-place human save passed for the checked object.
			-- A restored absence compares nil to nil and needs no special case.
			and (
				(state ~= nil and state.hash == marker.checked_hash)
				-- Mutation seam (gate): the pre-fix classifier, the other half of the
				-- pre-fix marker — the fingerprint was optional to record, and a
				-- marker that lacked one compared equal to whatever it found.
				or (M._test.fault.rollback_marker_no_hash and marker.checked_hash == nil)
			)
	end
	if not licensed then
		local seen = state or { kind = st.kind }
		if purpose == "revert" then
			return "conflict", revert_refusal_message(op, path, seen)
		end
		return "conflict",
			path
				.. ": the rollback of this failed accept cannot be completed — the path no longer holds the object it"
				.. " was licensed against, so it is left exactly as found and the retained copy stays in the diary"
	end

	if not opts.apply_pending then
		return "pending"
	end

	local restore_op = {
		op_id = op.op_id,
		path = op.path,
		displaced_state = disp.displaced_state,
		displaced_hash = disp.displaced_hash,
		displaced_mode = disp.displaced_mode,
	}
	local ok, rerr, restored = journaled_restore(session, restore_op, disp.displaced_path, path, "rollback recovery after crash", {
		accepted_op = purpose == "revert" and op or nil,
		purpose = purpose,
		-- THE MARKER'S RECORD, AND ONLY IT. They agree — `licensed` above is
		-- exactly that agreement — and carrying the marker's own fields forward
		-- keeps the licence and the last-instant check anchored to one recorded
		-- object rather than to two separate looks at the path. Nothing is filled
		-- in from this observation: a field the marker lacks is a field nobody
		-- checked, and replay inventing it from what it finds now would make the
		-- rollback license itself against the state it is meant to refuse. This is
		-- the very record validated at entry, carried forward rather than rebuilt,
		-- so the licence and the last-instant check cannot read different fields.
		checked = checked,
	})
	if not ok then
		return "failure", rerr
	end
	if purpose ~= "revert" then
		return "rolled_back"
	end
	-- The restore that just ran installed a NEW object and recorded it; the
	-- completion is written against THAT record, not against the one this replay
	-- entered with — which, on the redo route, is the record of nothing.
	ok, rerr = record_completion(session, "revert_done", op, path, {
		marker = marker,
		disp = disp,
		restored = restored,
	})
	if not ok then
		return "failure", rerr
	end
	return "reverted"
end

function M.replay(opts)
	opts = opts or {}
	local session = opts.session
	if opts.aged and (os.time() - (session.created_at or os.time())) >= M._config.aged_frontier_sec then
		if not opts.confirm_aged then
			return { done = 0, total = 0, needs_confirmation = true, aged = true }
		end
	end

	local rows, truncated, err = load_journal(session)
	if not rows then
		return { done = 0, total = 0, conflicts = {}, failures = { { error = err } } }
	end

	local swept = {}
	local sweep_refused = {}
	if opts.apply_pending then
		local err
		swept, err, sweep_refused = M.sweep_orphan_temps(session)
		if err then
			return {
				done = 0,
				total = 0,
				conflicts = {},
				failures = { { error = err } },
				swept = swept,
				sweep_refused = sweep_refused,
			}
		end
	end

	local intents = {}
	local done = {}
	local conflicted = {}
	local unlink_start = {}
	local unlink_done = {}
	local revert_start = {}
	local revert_done = {}
	local rollback_start = {}
	local rollback_done = {}
	local restore_temp = {}
	local displaced_rows = {}
	for _, row in ipairs(rows) do
		if row.kind == "intent" then
			intents[#intents + 1] = row
		elseif row.kind == "done" then
			done[row.op_id] = true
		elseif row.kind == "conflict" and row.op_id then
			conflicted[row.op_id] = true
		elseif row.kind == "unlink_start" and row.op_id then
			unlink_start[row.op_id] = row
		elseif row.kind == "unlink_done" and row.op_id then
			unlink_done[row.op_id] = true
		elseif row.kind == "displaced" and row.op_id then
			displaced_rows[row.op_id] = row
		elseif row.kind == "revert_start" and row.op_id then
			revert_start[row.op_id] = row
		elseif row.kind == "revert_done" and row.op_id then
			revert_done[row.op_id] = true
			done[row.op_id] = nil
		elseif row.kind == "rollback_start" and row.op_id then
			-- Last row wins: a retried rollback appends a fresh marker, and the
			-- identity recovery must compare against is the one the most recent
			-- attempt checked.
			rollback_start[row.op_id] = row
		elseif row.kind == "restore_temp" and row.op_id then
			-- Last row wins for the same reason: a retried restore creates its own
			-- fresh temp, and the output recovery may recognise is that one.
			restore_temp[row.op_id] = row
		elseif row.kind == "rollback_done" and row.op_id then
			rollback_done[row.op_id] = true
		end
	end

	local applied = 0
	local reverted = 0
	local rolled_back = 0
	local conflicts = {}
	local failures = {}
	local reverts = {}
	local rollbacks = {}
	for _, op in ipairs(intents) do
		-- Mutation seam (gate): the pre-fix blindness, where an automatic
		-- rollback left no marker replay would look at, so a crash on either
		-- side of its restore fell through to the accept three-way below.
		local marker = rollback_start[op.op_id]
		if M._test.fault.replay_ignores_rollback_rows then
			marker = nil
		end
		marker = marker or revert_start[op.op_id]
		local purpose = marker and marker.purpose
		local in_flight = not M._test.fault.replay_ignores_revert_rows
			and not revert_done[op.op_id]
			and (rollback_done[op.op_id] or marker)
		if revert_done[op.op_id] and M._test.fault.gate_bypass_settled then
			-- Mutation seam (gate): the pre-fix settled branch, which counted a
			-- `revert_done` row as a finished revert without reading the marker or
			-- the restore record that row rests on.
			reverted = reverted + 1
		elseif revert_done[op.op_id] then
			-- A SETTLED REVERT IS A COMPLETION CLAIM LIKE ANY OTHER.
			--
			-- It was the last row that escaped the state machine: `revert_done`
			-- present meant "reverted, count it and move on", so a marker stripped
			-- of its fingerprint or a restore record damaged after the fact was
			-- never looked at again and the revert stayed reported as finished.
			-- Routed through the same gate, the claim is re-validated against the
			-- evidence it rests on; nothing is appended either way.
			local verdict, verr = complete_rollback(session, op, displaced_rows[op.op_id], marker, {
				settled = true,
				restored = restore_temp[op.op_id],
			})
			if verdict == "reverted" then
				-- Reverted accepts are not pending applies.
				reverted = reverted + 1
			elseif verdict == "conflict" then
				conflicts[#conflicts + 1] = op
			else
				failures[#failures + 1] = {
					op_id = op.op_id,
					path = op.path,
					error = verr or "settled revert could not be validated",
				}
			end
		elseif in_flight then
			-- A ROLLBACK CAUGHT MID-FLIGHT. Its markers are a state machine, not
			-- decoration: `revert_start` says a user revert was licensed,
			-- `rollback_start` says which object a restore is about to be
			-- performed over and WHY, `rollback_done` says the restore landed and
			-- was verified, and `revert_done` says a revert is finished. Without
			-- this, a crash anywhere between them left the original `done` row
			-- standing or handed the operation to the accept three-way, which
			-- re-applied an accept that had already failed verification.
			local verdict, verr = complete_rollback(session, op, displaced_rows[op.op_id], marker, {
				rollback_done = rollback_done[op.op_id] and true or false,
				restored = restore_temp[op.op_id],
				apply_pending = opts.apply_pending,
			})
			if verdict == "reverted" then
				reverted = reverted + 1
				revert_done[op.op_id] = true
				done[op.op_id] = nil
				reverts[#reverts + 1] = op
			elseif verdict == "rolled_back" then
				-- The accept was undone on purpose. It is not applied, it is not
				-- pending, and it is never retried here: its verification failed.
				rolled_back = rolled_back + 1
				done[op.op_id] = nil
				rollbacks[#rollbacks + 1] = op
			elseif verdict == "conflict" then
				conflicts[#conflicts + 1] = op
			elseif verdict == "pending" then
				-- Nothing to do without --apply: the rollback is recorded, not finished.
				if purpose == "revert" then
					reverts[#reverts + 1] = op
				else
					rollbacks[#rollbacks + 1] = op
				end
			else
				failures[#failures + 1] = {
					op_id = op.op_id,
					path = op.path,
					error = verr or "rollback recovery failed",
				}
			end
		elseif done[op.op_id] then
			applied = applied + 1
		elseif conflicted[op.op_id] then
			conflicts[#conflicts + 1] = op
		elseif unlink_done[op.op_id] and uv.fs_lstat(op.path) ~= nil then
			conflicts[#conflicts + 1] = op
		else
			local real, rerr = read_bytes(op.path)
			if real == nil then
				-- EXISTENCE IS DECIDED BY LSTAT, NOT BY READABILITY. `filereadable`
				-- reports 0 for a present file whose bytes cannot be read, so this
				-- used to call an unreadable file "empty" and could then mark an
				-- empty-target operation done without ever touching it.
				if uv.fs_lstat(op.path) ~= nil then
					failures[#failures + 1] = {
						op_id = op.op_id,
						path = op.path,
						error = rerr or "file unreadable",
					}
				else
					real = ""
				end
			end
			if real ~= nil then
				local h = hash_bytes(real)

				-- Three-way recovery: real equals new -> done; equals old ->
				-- redo; otherwise conflict.
				--
				-- For an unlink the "new" state is ABSENCE, and it has to be
				-- decided with lstat rather than by hashing. read_bytes yields
				-- "" for a missing file, so a bytes-only test cannot separate
				-- the three outcomes this recovery exists to tell apart:
				-- already unlinked, never unlinked (still there with its
				-- turn-start bytes), and someone recreated it since.
				local verdict
				if op.op_kind == "delete" then
					local marker = unlink_start[op.op_id]
					local now = uv.fs_lstat(op.path)
					if unlink_done[op.op_id] then
						if now == nil then
							verdict = "new"
						else
							verdict = "conflict"
						end
					elseif now == nil then
						verdict = "new"
					elseif marker then
						-- The applier was licensed to unlink and no completion row
						-- exists, so whether it acted is unknowable from the journal.
						-- Redo ONLY while the very object the check passed on is
						-- still at the path; a different object carrying the same
						-- bytes is a recreation, and deleting it would destroy work
						-- this turn never read. Identity says what content cannot.
						if
							now.type == "file"
							and marker.checked_type == "file"
							and marker.checked_dev ~= nil
							and marker.checked_ino ~= nil
							and now.dev == marker.checked_dev
							and now.ino == marker.checked_ino
							and h == op.base_hash
						then
							verdict = "old"
						else
							verdict = "conflict"
						end
					elseif h == op.base_hash then
						verdict = "old"
					else
						verdict = "conflict"
					end
				elseif h == hash_bytes(op.target) then
					verdict = "new"
				elseif h == op.base_hash then
					verdict = "old"
				else
					verdict = "conflict"
				end

				if verdict == "new" then
					local ok_mark, err_mark = append_jsonl(journal_path(session), {
						kind = "done",
						op_id = op.op_id,
						path = op.path,
						ts = os.time(),
					})
					if ok_mark then
						done[op.op_id] = true
						applied = applied + 1
					else
						failures[#failures + 1] = {
							op_id = op.op_id,
							path = op.path,
							error = err_mark,
						}
					end
				elseif verdict == "old" then
					if opts.apply_pending then
						local ok, aerr = apply_operation(session, op, {})
						if ok then
							done[op.op_id] = true
							applied = applied + 1
						else
							failures[#failures + 1] = {
								op_id = op.op_id,
								path = op.path,
								error = aerr or "apply failed",
							}
						end
					end
				else
					conflicts[#conflicts + 1] = op
				end
			end
		end
	end

	local frontiers = {}
	for _, op in ipairs(intents) do
		local sid = op.stream or session.stream
		frontiers[sid] = frontiers[sid] or { done = 0, total = 0 }
		frontiers[sid].total = frontiers[sid].total + 1
		if done[op.op_id] then
			frontiers[sid].done = frontiers[sid].done + 1
		end
	end

	return {
		done = applied,
		reverted = reverted,
		rolled_back = rolled_back,
		total = #intents,
		frontiers = frontiers,
		conflicts = conflicts,
		reverts = reverts,
		rollbacks = rollbacks,
		failures = failures,
		truncated_tail = truncated,
		swept = swept,
		sweep_refused = sweep_refused,
	}
end

function M.apply_with_injection(opts)
	opts = opts or {}
	local session = opts.session
	local path = diff.abs_path(opts.path)
	local rows, _, err = load_journal(session)
	if not rows then
		return false, err
	end
	local op
	for i = #rows, 1, -1 do
		local row = rows[i]
		if row.kind == "intent" and row.path == path then
			op = row
			break
		end
	end
	if not op then
		return false, "no intent for path"
	end
	return apply_operation(session, op, {
		inject_after_rename = opts.inject_after_hash,
	})
end

function M.refusal_message(path)
	return path
		.. ": this file differs from the agent's starting copy — your mid-turn edit or a stale start copy; both versions kept; re-diff offered"
end

function M.empty_hash()
	return (hash_bytes(""))
end

function M.journal_rows(session)
	local rows, tail, err = load_journal(session)
	if not rows then
		return nil, err
	end
	return rows, tail
end

function M.status_summary(session)
	local rows, _, err = load_journal(session)
	if not rows then
		return {
			rows = {},
			states = {},
			done = 0,
			pending = 0,
			refused = 0,
			total = 0,
			error = err,
		}
	end
	local states = {}
	local done_ids = {}
	local done, pending, refused, total = 0, 0, 0, 0
	for _, row in ipairs(rows) do
		if row.kind == "intent" then
			total = total + 1
			states[row.op_id] = { rel = vim.fn.fnamemodify(row.path, ":."), state = "intent" }
		elseif row.kind == "displaced" and states[row.op_id] then
			states[row.op_id].state = "displaced"
		elseif row.kind == "done" and states[row.op_id] then
			states[row.op_id].state = "done"
			if not done_ids[row.op_id] then
				done_ids[row.op_id] = true
				done = done + 1
			end
		elseif row.kind == "refused" and states[row.op_id] then
			states[row.op_id].state = "refused"
			if not done_ids[row.op_id] then
				done_ids[row.op_id] = true
				refused = refused + 1
			end
		elseif row.kind == "conflict" and states[row.op_id] then
			states[row.op_id].state = "conflict"
			if not done_ids[row.op_id] then
				done_ids[row.op_id] = true
				refused = refused + 1
			end
		elseif row.kind == "revert_done" and states[row.op_id] then
			states[row.op_id].state = "reverted"
		end
	end
	for _, info in pairs(states) do
		if info.state == "intent" or info.state == "displaced" then
			pending = pending + 1
		end
	end
	return {
		rows = rows,
		states = states,
		done = done,
		pending = pending,
		refused = refused,
		total = total,
	}
end

function M.list_displaced(session)
	local rows, _, err = load_journal(session)
	local out = {}
	if not rows then
		return out
	end
	for _, row in ipairs(rows) do
		if row.kind == "displaced" then
			out[#out + 1] = row
		end
	end
	return out
end

function M.recover_displaced(session, op_id, out_path)
	-- Recovery output paths lie outside the workspace. Recovery
	-- output paths ... get their own explicit output-path refusal rule"), so the
	-- workspace-relative matcher does not apply — but a control-plane path is
	-- still never a write target, INCLUDING another repository's `.git/` that has
	-- nothing to do with this workspace. Classify the LEXICAL output path
	-- (unresolved, so a `.git` symlink keeps its name).
	local out_lit = diff.abs_path_literal(out_path)
	if control_plane.is_control_plane(out_lit) then
		return false, "recover --out refused — control-plane path: " .. out_lit
	end
	local resolved = diff.abs_path(out_path)
	if control_plane.is_control_plane(resolved) then
		return false, "recover --out refused — resolves into a control-plane path: " .. resolved
	end
	-- Distinguish the three outcomes explicitly: recovery
	-- must write strictly OUTSIDE the workspace. `resolve_target` now returns nil
	-- both for an escape (which we WANT here) and for a refusal (control-plane /
	-- symlink / mount), so its truthiness can no longer stand in for "inside".
	-- Test insideness directly against the resolved workspace prefix.
	local ws = diff.abs_path(session.workspace)
	if resolved == ws or vim.startswith(resolved, ws .. "/") then
		return false, "recover --out must not write inside workspace: " .. out_path
	end
	local rows, _, err = load_journal(session)
	if not rows then
		return false, err
	end
	for _, row in ipairs(rows) do
		if row.kind == "displaced" and row.op_id == op_id then
			local content, rerr = read_bytes(row.displaced_path)
			if content == nil then
				return false, rerr or "displaced file missing"
			end
			local ok, werr = diff.write_file(resolved, content)
			return ok, werr
		end
	end
	return false, "no displaced row for op_id " .. tostring(op_id)
end

function M.second_pass_reanchor(opts)
	opts = opts or {}
	local path = diff.abs_path(opts.path)
	local content, err = read_bytes(path)
	if content == nil then
		return nil, err
	end
	return {
		path = path,
		anchor_hash = hash_bytes(content),
		content = content,
	}
end

function M.displaced_copy_path(session, op_id)
	return displaced_path_for(session, op_id)
end

local function revert_refused(session, op, reason)
	return append_jsonl(journal_path(session), {
		kind = "revert_refused",
		op_id = op.op_id,
		path = op.path,
		reason = reason,
		ts = os.time(),
	})
end

function M.revert_operation(opts)
	opts = opts or {}
	local session = opts.session
	if not session then
		return false, "no diary session"
	end
	local filter = opts.op_id

	local rows, _, err = load_journal(session)
	if not rows then
		return false, err
	end

	local intents = {}
	local displaced = {}
	local done = {}
	local reverted = {}
	local revert_started = {}
	local rollback_started = {}
	local rollback_done = {}
	local restore_temp = {}
	for _, row in ipairs(rows) do
		if row.kind == "intent" then
			intents[row.op_id] = row
		elseif row.kind == "displaced" then
			displaced[row.op_id] = row
		elseif row.kind == "done" then
			done[row.op_id] = true
		elseif row.kind == "revert_done" then
			reverted[row.op_id] = true
		elseif row.kind == "revert_start" then
			revert_started[row.op_id] = row
		elseif row.kind == "rollback_start" then
			rollback_started[row.op_id] = row
		elseif row.kind == "restore_temp" then
			restore_temp[row.op_id] = row
		elseif row.kind == "rollback_done" then
			rollback_done[row.op_id] = true
		end
	end

	local targets = {}
	for op_id, _ in pairs(done) do
		if not reverted[op_id] and intents[op_id] then
			if not filter or filter == op_id then
				targets[#targets + 1] = intents[op_id]
			end
		end
	end
	table.sort(targets, function(a, b)
		return op_seq_number(a.op_id) > op_seq_number(b.op_id)
	end)

	if #targets == 0 then
		return false, filter and ("no completed operation to revert for " .. filter) or "no completed operations to revert"
	end

	local reverted_n = 0
	for _, op in ipairs(targets) do
		local path, perr = resolve_target(session.workspace, op.path, op.raw_rel)
		if not path then
			return false, perr
		end

		local disp = displaced[op.op_id]
		if not disp or not disp.displaced_path then
			return false, "no displaced copy recorded for " .. tostring(op.op_id)
		end

		-- A revert already in flight is resumed through the SAME state machine
		-- replay uses, so a retry and a `replay --apply` cannot disagree about
		-- what a half-finished revert means. Retrying used to skip straight to
		-- the restore, whose drift check then found the already-restored bytes
		-- instead of the accepted result and refused for good.
		if revert_started[op.op_id] or rollback_started[op.op_id] or rollback_done[op.op_id] then
			local verdict, verr = complete_rollback(
				session,
				op,
				disp,
				rollback_started[op.op_id] or revert_started[op.op_id],
				{
					rollback_done = rollback_done[op.op_id] and true or false,
					restored = restore_temp[op.op_id],
					apply_pending = true,
				}
			)
			if verdict ~= "reverted" then
				local msg = verr or (path .. ": this revert cannot be completed automatically; both versions are kept")
				revert_refused(session, op, msg)
				return false, msg
			end
			reverted_n = reverted_n + 1
			goto continue_revert
		end

		local state, oerr = observe_state(path)
		if not state then
			revert_refused(session, op, oerr)
			return false, oerr
		end
		if not accepted_state_for_revert(op, state) then
			local msg = revert_refusal_message(op, path, state)
			revert_refused(session, op, msg)
			return false, msg
		end

		-- THE MARKER RECORDS WHAT WAS CHECKED, IDENTITY INCLUDED.
		--
		-- `state` above is the object this revert was licensed against. Recording
		-- only that it "held the accepted bytes" left the revert unable to tell,
		-- later, whether the file it is about to overwrite is that same object: a
		-- different inode carrying the same bytes read as "still accepted" and was
		-- restored over. Bytes cannot separate those; `(dev, ino, type)` can.
		-- Kept, not just written: this is the record the `revert_done` at the end
		-- of this route is gated on.
		local marker = {
			kind = "revert_start",
			op_id = op.op_id,
			path = op.path,
			displaced_path = disp.displaced_path,
			purpose = "revert",
			checked_type = state.kind,
			checked_dev = state.dev,
			checked_ino = state.ino,
			checked_hash = state.hash,
			ts = os.time(),
		}
		-- Mutation seam (gate): the pre-fix `revert_start`, which recorded that
		-- the path held the accepted BYTES and never which object held them. The
		-- restore below carries `state` directly, so this marker is read by
		-- exactly one thing — the gate in front of this route's `revert_done`.
		if M._test.fault.revert_marker_identity_blind then
			marker.checked_dev = nil
			marker.checked_ino = nil
		end
		local ok_log, log_err = append_jsonl(journal_path(session), marker)
		if not ok_log then
			return false, log_err
		end
		local ok_sync, sync_err = fsync_dir(session.diary_dir)
		if not ok_sync then
			return false, sync_err
		end

		-- Crash point: the revert is licensed and journaled, and nothing has been
		-- restored yet. Replay must find the accepted result still on disk and
		-- finish the revert rather than leave it half done for ever.
		if M._test.fault.crash_before_rollback then
			session.simulated_crash = op.op_id
			return true, nil, reverted_n
		end

		local restore_op = {
			op_id = op.op_id,
			path = op.path,
			displaced_state = disp.displaced_state,
			displaced_hash = disp.displaced_hash,
			displaced_mode = disp.displaced_mode,
		}
		local ok, rerr, restored = journaled_restore(session, restore_op, disp.displaced_path, path, "revert after accept", {
			accepted_op = op,
			purpose = "revert",
			-- The very observation that licensed the revert, carried into the
			-- marker and into the check one syscall before the rename.
			checked = state,
		})
		if not ok then
			return false, rerr
		end
		if M._test.fault.crash_before_revert_done then
			session.simulated_crash = op.op_id
			return true, nil, reverted_n
		end
		-- Through the one gate, exactly as the recovery routes are. This append
		-- used to be the shortest route to a completion row in the file: a direct
		-- append behind a restore that had just succeeded, resting on the success
		-- rather than on the evidence.
		ok, rerr = record_completion(session, "revert_done", op, path, {
			marker = marker,
			disp = disp,
			restored = restored,
		})
		if not ok then
			return false, rerr
		end
		reverted_n = reverted_n + 1
		::continue_revert::
	end

	return true, nil, reverted_n
end

return M
