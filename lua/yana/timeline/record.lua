-- Timeline record — the storage behind the pinned timeline interface
-- (lua/yana/timeline/init.lua). Built to the timeline design contract (v2).
--
-- WHAT LIVES HERE. An append-only journal per (workspace, file) under
-- `<workspace>/.yana/timeline/`, holding integers, ids and records —
-- NEVER bytes. Restoration authority stays with Neovim's undo tree (buffer
-- rows) and the diary's journaled applier (durable rows); this module stores
-- how to ask each authority, preserving the single-authority rule.
--
-- Four durability and identity corrections are enforced structurally:
--
--   * STATE IS DERIVED, NEVER STORED. A row carries no state field on disk.
--     Durable rows resolve through `diary.status_summary`, the diary's OWN
--     reading of its markers — the record that survives a crash. The ledger
--     cannot be the authority: it is in-memory with bounded rings that DROP
--     entries at capacity (lua/yana/ledger.lua LIMITS) and let callers
--     continue.
--   * `op_id` IS NOT GLOBALLY UNIQUE. It is `stream:sequence` and every new
--     diary starts at zero, so a durable row REQUIRES `diary_dir` too, and
--     resolution happens strictly inside that diary.
--   * `undo_seq` IS BUFFER-LOCAL while the timeline is per-file and outlives
--     the buffer. A buffer row REQUIRES a buffer epoch and an expected content
--     hash; reachable() refuses on mismatch. "The seq exists" is not evidence.
--   * reachable() ENFORCES PER-PATH LIFO: a durable row is reachable only if
--     no LATER durable row for the same path is still un-reverted (or
--     unresolved). The blocking row's id is returned.
--
-- TWO-PHASE ORDERING (timeline.md, "Ordering, and what a crash leaves"):
-- `intent` appends `pending` BEFORE the diary intent; a failure here returns
-- (nil, err) and the CALLER MUST HALT the action — the same rule every durable
-- record in this product follows. The diary does not carry a foreign
-- correlation field, so the durable caller passes the op id it is about to
-- mint: `session.stream .. ":" .. (session.op_seq + 1)`, computed immediately
-- before its `diary.intent` call on the same session. A crash between the two
-- phases leaves a row the diary has no marker for, which derives `pending` —
-- truthfully distinguishable from "action happened" (break-test T08).
--
-- RETURN EXTENSION. reachable() returns (ok, blocked_by, reason): the third
-- value is refusal text, always set when ok is false. The pinned two-value
-- contract is untouched; the break-tests require every refusal to carry its
-- reason ("a test that cannot distinguish 'refused correctly' from 'did
-- nothing' is not a test").
local M = {}

local diff = require("yana.diff")
local hash = require("yana.safety.hash")
local flush = require("yana.safety.flush")
local diary = require("yana.safety.diary")
local uv = vim.uv or vim.loop

--- Lazily required: this module must stay usable from a bare context (a
--- headless probe preloading a stub, per walk_impl.lua's own precedent) even
--- if `yana.log` is not on the load path there.
local function log_warn(msg)
	local ok, log = pcall(require, "yana.log")
	if ok and log and log.write then
		log.write("WARN", "yana.timeline: " .. msg)
	end
end

local KINDS = {
	review_opened = true,
	hunk_accepted = true,
	hunk_rejected = true,
	human_edit = true,
	review_closed = true,
	applied = true,
}

local EPOCH_VAR = "yana_timeline_epoch"
local HEAD_EPOCH_VAR = "yana_timeline_head_epoch"
local HEAD_SEQ_VAR = "yana_timeline_head_seq"
local HEAD_HASH_VAR = "yana_timeline_head_hash"
local HEAD_ID_VAR = "yana_timeline_head_id"

-- ---------------------------------------------------------------------------
-- Journal storage. Same durability posture as the diary: append + fsync via
-- `safety/flush` (off the loop), and a directory fsync when a journal file is
-- first created so its NAME is durable too.
-- ---------------------------------------------------------------------------

local function timeline_dir(ws)
	return ws .. "/.yana/timeline"
end

--- The cross-file ORDER pointer (FIX-UNDO lane, operator ruling 2026-08-21).
--- ORDER ONLY: `{seq, rel, id, kind}`, one line per timeline row, workspace-
--- monotonic. Never bytes, never a second copy of anything a per-path journal
--- already owns -- the per-path `.jsonl` files stay exactly as they are and
--- stay the authority for content and state. This file exists because the
--- per-path journals alone answer "what happened to THIS file, in order" but
--- not "what happened LAST, anywhere in this workspace" without reading every
--- one of them; the pointer makes that O(1) instead of O(files).
local function order_file(ws)
	return timeline_dir(ws) .. "/_order.jsonl"
end

--- Injective filename for a workspace-relative path: every byte outside
--- [A-Za-z0-9._-] is %XX-encoded. Very long names fall back to a hashed form;
--- rows carry `rel` and readers filter on it, so even a filename collision
--- cannot mix histories.
local function enc(rel)
	local s = rel:gsub("[^%w%._%-]", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	if #s > 180 then
		s = s:sub(1, 64) .. "-" .. hash.hash_bytes(rel):sub(1, 32)
	end
	return s
end

local function journal_file(ws, rel)
	return timeline_dir(ws) .. "/" .. enc(rel) .. ".jsonl"
end

local function fsync_dir(dir)
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

local function write_all_fd(fd, content)
	local written = 0
	while written < #content do
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

-- Journal files whose directory entries are known durable, so steady-state
-- appends cost one file fsync, not three.
local durable_names = {}

local function append_row(ws, rel, row)
	local dir = timeline_dir(ws)
	local path = journal_file(ws, rel)
	local existed = uv.fs_stat(path) ~= nil
	if not existed and vim.fn.isdirectory(dir) ~= 1 then
		local mk_ok, mk_err = pcall(vim.fn.mkdir, dir, "p")
		if not mk_ok or vim.fn.isdirectory(dir) ~= 1 then
			return false, "cannot create " .. dir .. (mk_err and (": " .. tostring(mk_err)) or "")
		end
	end
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
	if not existed or not durable_names[path] then
		-- The row is durable; make the file's NAME durable before reporting
		-- success, exactly as diary.begin does for its journal.
		local ok2, e2 = fsync_dir(dir)
		if not ok2 then
			return false, e2
		end
		local parent = vim.fn.fnamemodify(dir, ":h")
		local ok3, e3 = fsync_dir(parent)
		if not ok3 then
			return false, e3
		end
		durable_names[path] = true
	end
	return true
end

-- Async twin of append_row. The row bytes are appended before this function
-- returns, preserving journal order; only the durability waits run through
-- libuv callbacks. This is used by review-open recording so a slow fsync does
-- not hold Neovim's input/paint loop before the first interaction. Every
-- flush remains present and ordered: file, timeline directory, then parent.
local function append_row_async(ws, rel, row, callback)
	local dir = timeline_dir(ws)
	local parent = vim.fn.fnamemodify(dir, ":h")
	local path = journal_file(ws, rel)
	local existed = uv.fs_stat(path) ~= nil
	if not existed and vim.fn.isdirectory(dir) ~= 1 then
		local mk_ok, mk_err = pcall(vim.fn.mkdir, dir, "p")
		if not mk_ok or vim.fn.isdirectory(dir) ~= 1 then
			return false, "cannot create " .. dir .. (mk_err and (": " .. tostring(mk_err)) or "")
		end
	end

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

	local need_name_flush = not existed or not durable_names[path]
	local dir_fd, parent_fd
	if need_name_flush then
		dir_fd, err = uv.fs_open(dir, "r", 0)
		if not dir_fd then
			uv.fs_close(fd)
			return false, err
		end
		parent_fd, err = uv.fs_open(parent, "r", 0)
		if not parent_fd then
			uv.fs_close(dir_fd)
			uv.fs_close(fd)
			return false, err
		end
	end

	local finished = false
	local function finish(success, finish_err)
		if finished then
			return
		end
		finished = true
		callback(success, finish_err)
	end
	local function queue_fsync(target_fd, cb)
		local called, req = pcall(uv.fs_fsync, target_fd, cb)
		if not called or not req then
			return false, called and "could not queue fsync" or tostring(req)
		end
		return true
	end

	local queued, qerr = queue_fsync(fd, function(file_err)
		uv.fs_close(fd)
		if file_err then
			if dir_fd then uv.fs_close(dir_fd) end
			if parent_fd then uv.fs_close(parent_fd) end
			finish(false, file_err)
			return
		end
		if not need_name_flush then
			finish(true)
			return
		end
		local dir_queued, dir_qerr = queue_fsync(dir_fd, function(dir_err)
			uv.fs_close(dir_fd)
			if dir_err then
				uv.fs_close(parent_fd)
				finish(false, dir_err)
				return
			end
			local parent_queued, parent_qerr = queue_fsync(parent_fd, function(parent_err)
				uv.fs_close(parent_fd)
				if parent_err then
					finish(false, parent_err)
					return
				end
				durable_names[path] = true
				finish(true)
			end)
			if not parent_queued then
				uv.fs_close(parent_fd)
				finish(false, parent_qerr)
			end
		end)
		if not dir_queued then
			uv.fs_close(dir_fd)
			uv.fs_close(parent_fd)
			finish(false, dir_qerr)
		end
	end)
	if not queued then
		uv.fs_close(fd)
		if dir_fd then uv.fs_close(dir_fd) end
		if parent_fd then uv.fs_close(parent_fd) end
		return false, qerr
	end
	return true
end

--- Parse a jsonl journal. A torn TAIL (no trailing newline — a crash mid
--- append) is tolerated and ignored, as the diary tolerates it. A malformed
--- COMPLETE line stops parsing there: the rows before it are returned with an
--- error naming the file, and nothing past the damage is invented.
local function read_rows(path)
	if vim.fn.filereadable(path) ~= 1 then
		return {}
	end
	local raw, rerr = diff.read_file_bytes(path)
	if raw == nil then
		return nil, rerr or (path .. " unreadable")
	end
	local rows = {}
	local from = 1
	while from <= #raw do
		local nl = raw:find("\n", from, true)
		if not nl then
			break -- torn tail, tolerated
		end
		local line = raw:sub(from, nl - 1)
		if line ~= "" then
			local ok, row = pcall(vim.json.decode, line)
			if not ok or type(row) ~= "table" then
				return rows, "malformed timeline row in " .. path .. " at byte " .. from
			end
			rows[#rows + 1] = row
		end
		from = nl + 1
	end
	return rows
end

-- ---------------------------------------------------------------------------
-- The cross-file order pointer: a workspace-monotonic counter, durable
-- across restarts by recovering its high-water mark from the pointer file
-- itself (the same "read what's already on disk" recovery the diary and the
-- per-path journals both use elsewhere), and one append function.
-- ---------------------------------------------------------------------------

local global_seq_cache = {}

-- Every workspace root that has recorded at least one row THIS SESSION --
-- populated automatically as a side effect of `next_global_seq`, which
-- every `prepare_row` call already runs exactly once. This is what lets
-- the post-review `u` dispatcher (`retrace.lua`) retrace across every root
-- a panel/turn actually touched without needing its own copy of that list
-- from `ui.lua`'s pass/turn bookkeeping -- "every root with a row" and
-- "every root this session touched" are the same set by construction.
local known_workspaces = {}

--- PUBLIC: every workspace this process has recorded a timeline row for,
--- in no particular order. FIX-UNDO lane, 2026-08-21.
function M.known_workspaces()
	local out = {}
	for ws in pairs(known_workspaces) do
		out[#out + 1] = ws
	end
	return out
end

local function last_recorded_global_seq(ws)
	local rows = read_rows(order_file(ws))
	local last = 0
	if rows then
		for _, r in ipairs(rows) do
			if type(r.seq) == "number" and r.seq > last then
				last = r.seq
			end
		end
	end
	return last
end

--- The next workspace-monotonic seq. Gaps are harmless (a failed append
--- still consumed one), and the counter is cached in-memory per workspace
--- after its first read so a long session does not re-read the whole
--- pointer file on every intent.
local function next_global_seq(ws)
	known_workspaces[ws] = true
	local cached = global_seq_cache[ws]
	if cached == nil then
		cached = last_recorded_global_seq(ws)
	end
	cached = cached + 1
	global_seq_cache[ws] = cached
	return cached
end

--- Append one order-pointer row, durably: fsync the file, and (only the
--- first time this pointer file is created) fsync the directory so its NAME
--- is durable too -- the same shape `append_row` uses for a per-path
--- journal, kept independent of it on purpose: the pointer is a SEPARATE,
--- strictly secondary artefact, and its own durability failure must never be
--- read as "the decision did not happen" when the per-path row (the real
--- authority) already landed.
local function append_order_row(ws, row)
	local dir = timeline_dir(ws)
	local path = order_file(ws)
	local existed = uv.fs_stat(path) ~= nil
	if not existed and vim.fn.isdirectory(dir) ~= 1 then
		local mk_ok, mk_err = pcall(vim.fn.mkdir, dir, "p")
		if not mk_ok or vim.fn.isdirectory(dir) ~= 1 then
			return false, "cannot create " .. dir .. (mk_err and (": " .. tostring(mk_err)) or "")
		end
	end
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
	if not existed then
		local ok2, e2 = fsync_dir(dir)
		if not ok2 then
			return false, e2
		end
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Correlation ids and buffer observation helpers.
-- ---------------------------------------------------------------------------

local mint_seq = 0
local function mint_id()
	mint_seq = mint_seq + 1
	-- pid + hrtime + counter: unique across restarts of the editor, which the
	-- per-file journal outlives.
	return string.format("tl-%x-%x-%d", uv.os_getpid(), uv.hrtime(), mint_seq)
end

--- The epoch of a buffer's undo tree: minted once per buffer LIFETIME and kept
--- in a b: variable, which `:bwipeout` and buffer recreation destroy. A
--- recreated buffer therefore presents no (or a different) epoch and every row
--- recorded against the old tree refuses, which is break-test T06.
function M.buffer_epoch(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local ok, v = pcall(vim.api.nvim_buf_get_var, bufnr, EPOCH_VAR)
	if ok and type(v) == "string" and v ~= "" then
		return v
	end
	local epoch = string.format("ep-%x-%x", uv.os_getpid(), uv.hrtime())
	vim.api.nvim_buf_set_var(bufnr, EPOCH_VAR, epoch)
	return epoch
end

local function current_epoch(bufnr)
	local ok, v = pcall(vim.api.nvim_buf_get_var, bufnr, EPOCH_VAR)
	if ok and type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

local function buf_undotree(bufnr)
	return vim.api.nvim_buf_call(bufnr, function()
		return vim.fn.undotree()
	end)
end

--- Content hash of a live buffer. The convention (lines joined with "\n", no
--- synthetic trailing newline) only has to agree with ITSELF: the same
--- function computes `expected_hash` at record time and the comparison hash in
--- reachable(). It is never compared with on-disk bytes.
-- The canonical form MUST be byte-identical to the one walk_impl verifies
-- against, or every honest walk refuses on a hash mismatch that is really a
-- canonicalisation mismatch. This lane's original form (strict indexing, no
-- trailing newline) differed from walk's (loose indexing + a trailing newline
-- under endofline/fixendofline), which is exactly the failure the record lane's
-- own note predicted and the integration re-run then measured across four
-- break-tests. Delegating to walk_impl removes the possibility of the two
-- drifting apart -- there is now ONE definition.
local function buf_content_hash(bufnr)
	local ok, walk = pcall(require, "yana.timeline.walk_impl")
	if ok and type(walk) == "table" and type(walk.buffer_hash) == "function" then
		return walk.buffer_hash(bufnr)
	end
	-- Fallback matches walk_impl.buffer_text byte for byte, so it is safe even
	-- if the module is unavailable.
	local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	if vim.bo[bufnr].endofline and vim.bo[bufnr].fixendofline then
		text = text .. "\n"
	end
	return (hash.hash_bytes(text))
end

--- Everything a capture site needs for a buffer row, observed in one call:
--- { buffer_epoch, undo_seq, expected_hash }.
function M.observe_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_loaded(bufnr) then
		return nil, "buffer " .. tostring(bufnr) .. " is not loaded"
	end
	local tree = buf_undotree(bufnr)
	return {
		buffer_epoch = M.buffer_epoch(bufnr),
		undo_seq = tree.seq_cur,
		expected_hash = buf_content_hash(bufnr),
	}
end

--- Record the last buffer state the timeline itself witnessed. This is not a
--- byte authority: it is only an epoch, undo sequence and hash used to refuse
--- an out-of-band `g-`/`:undo` before a walk can silently cross it.
function M.sync_buffer_head(bufnr, obs)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and type(obs) == "table") then
		return false
	end
	if type(obs.buffer_epoch) ~= "string" or type(obs.undo_seq) ~= "number" or type(obs.expected_hash) ~= "string" then
		return false
	end
	vim.api.nvim_buf_set_var(bufnr, HEAD_EPOCH_VAR, obs.buffer_epoch)
	vim.api.nvim_buf_set_var(bufnr, HEAD_SEQ_VAR, obs.undo_seq)
	vim.api.nvim_buf_set_var(bufnr, HEAD_HASH_VAR, obs.expected_hash)
	if type(obs.id) == "string" and obs.id ~= "" then
		vim.api.nvim_buf_set_var(bufnr, HEAD_ID_VAR, obs.id)
	end
	return true
end

local function buffer_head(bufnr)
	local function get(name)
		local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
		return ok and value or nil
	end
	return {
		buffer_epoch = get(HEAD_EPOCH_VAR),
		undo_seq = get(HEAD_SEQ_VAR),
		expected_hash = get(HEAD_HASH_VAR),
		id = get(HEAD_ID_VAR),
	}
end

--- PUBLIC (FIX-UNDO lane, 2026-08-21): read-only view of the same head this
--- module's own `reachable()` buffer branch and `walk_impl.lua` compare
--- against -- "where did YANA's own bookkeeping last leave this buffer's
--- undo tree". This is the exact-condition primitive the post-review `u`/
--- `<C-r>` dispatcher (`lua/yana/timeline/retrace.lua`) needs: a buffer
--- whose CURRENT position still equals this head has had nothing (no
--- typing, no plain `:undo`) move it since Yana's last action, so `u`
--- retraces; any other position means the operator's own history is the
--- newest thing there, so `u` stays Neovim's. Never bytes -- an epoch, a
--- seq and a hash, precisely what `M.sync_buffer_head` already writes.
function M.buffer_head(bufnr)
	return buffer_head(bufnr)
end

local function find_buffer(abs)
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) then
			local name = vim.api.nvim_buf_get_name(b)
			if name ~= "" and diff.abs_path(name) == abs then
				return b
			end
		end
	end
	return nil
end

--- Depth-first exact search for a sequence number in an undo tree, alternate
--- branches included. Seq 0 is the root and always present.
local function seq_in_tree(tree, seq)
	if seq == 0 then
		return true
	end
	local function scan(entries)
		for _, e in ipairs(entries or {}) do
			if e.seq == seq then
				return true
			end
			if e.alt and scan(e.alt) then
				return true
			end
		end
		return false
	end
	return scan(tree.entries)
end

-- ---------------------------------------------------------------------------
-- State derivation.
-- ---------------------------------------------------------------------------

--- Durable state, resolved inside ONE diary via the diary's own marker
--- interpretation (`status_summary` reads the same journal recovery reads).
--- `summaries` caches one journal load per diary per entries() call.
local function durable_state(row, summaries)
	local key = row.diary_dir
	local summary = summaries[key]
	if not summary then
		summary = diary.status_summary({ diary_dir = key })
		summaries[key] = summary
	end
	if summary.error then
		-- No diary evidence readable: the action cannot be shown to have
		-- happened, so the row stays pending — never guessed done.
		return "pending", "diary unreadable: " .. tostring(summary.error)
	end
	local st = summary.states[row.op_id]
	if not st then
		return "pending", "no diary intent for " .. row.op_id .. " — crashed or halted before the action"
	end
	if st.state == "done" then
		return "done"
	elseif st.state == "reverted" then
		return "reverted"
	elseif st.state == "refused" or st.state == "conflict" then
		return "refused", st.state == "conflict" and "diary marked conflict" or nil
	end
	-- intent / displaced: recorded, not completed.
	return "pending", "diary state " .. tostring(st.state)
end

--- Buffer state. The event was witnessed when recorded, so the resting state
--- is `done`; when the live buffer with the MATCHING epoch currently sits
--- before the row's seq, Neovim's own tree says the row is walked back over,
--- which derives `reverted`. Without a matching live buffer the event stays
--- `done` — whether it can be WALKED is reachable()'s question, not a state.
local function buffer_state(ws, row)
	local abs = diff.abs_path(ws .. "/" .. row.rel)
	local buf = find_buffer(abs)
	if not buf then
		return "done"
	end
	if current_epoch(buf) ~= row.buffer_epoch then
		return "done", "buffer epoch differs; row belongs to an earlier tree"
	end
	local tree = buf_undotree(buf)
	if type(tree.seq_cur) == "number" and type(row.undo_seq) == "number" and tree.seq_cur < row.undo_seq then
		return "reverted", "buffer sits before this row (seq_cur " .. tree.seq_cur .. ")"
	end
	return "done"
end

-- ---------------------------------------------------------------------------
-- The pinned surface.
-- ---------------------------------------------------------------------------

--- Append an entry in the `pending` state; return its correlation id.
--- A failure returns (nil, err) and the caller MUST HALT the action.
--- `entry.workspace` routes storage (defaults to cwd); the id is minted here.
local function prepare_row(entry)
	if type(entry) ~= "table" then
		return nil, "timeline intent requires an entry table"
	end
	if entry.id ~= nil then
		return nil, "the correlation id is minted at intent; do not supply one"
	end
	local ws = diff.abs_path(entry.workspace or vim.fn.getcwd())
	local rel = entry.rel
	if type(rel) ~= "string" or rel == "" then
		return nil, "entry.rel (workspace-relative path) is required"
	end
	if rel:sub(1, 1) == "/" then
		return nil, "entry.rel must be workspace-relative, not absolute"
	end
	if not KINDS[entry.kind] then
		return nil, "unknown timeline kind: " .. tostring(entry.kind)
	end
	if type(entry.label) ~= "string" or entry.label == "" then
		return nil, "entry.label is required — it is what the operator reads"
	end
	local regime = entry.regime
	if regime ~= "buffer" and regime ~= "durable" then
		return nil, "entry.regime must be 'buffer' or 'durable', set where the event is recorded"
	end
	local row = {
		v = 1,
		id = mint_id(),
		kind = entry.kind,
		label = entry.label,
		regime = regime,
		rel = rel,
		ts = os.time(),
		-- FIX-UNDO lane, 2026-08-21: workspace-monotonic, stamped on EVERY row
		-- at this single choke point (both `M.intent` and `M.intent_async`
		-- share `prepare_row`), so a per-file journal alone still carries
		-- enough to rebuild the cross-file order pointer if that pointer file
		-- were ever lost. ORDER ONLY: ordering by this integer never decides
		-- WHETHER a row is reachable -- `reachable()`'s per-path LIFO rule is
		-- untouched and still the one authority for that.
		global_seq = next_global_seq(ws),
	}
	if regime == "durable" then
		if entry.buffer_epoch ~= nil or entry.undo_seq ~= nil or entry.expected_hash ~= nil then
			return nil, "a durable row must not carry buffer fields"
		end
		if type(entry.diary_dir) ~= "string" or entry.diary_dir == "" then
			return nil, "a durable row must carry diary_dir — op_id is 'stream:sequence' and is not globally unique"
		end
		if type(entry.op_id) ~= "string" or not entry.op_id:match("^.+:%d+$") then
			return nil, "a durable row must carry op_id ('stream:sequence' within its diary)"
		end
		row.diary_dir = diff.abs_path(entry.diary_dir)
		row.op_id = entry.op_id
	else
		if entry.diary_dir ~= nil or entry.op_id ~= nil then
			return nil, "a buffer row must not carry diary fields"
		end
		if type(entry.buffer_epoch) ~= "string" or entry.buffer_epoch == "" then
			return nil, "a buffer row must carry buffer_epoch — undo_seq is buffer-local and a recreated buffer can present a valid-looking seq from a different tree"
		end
		if type(entry.undo_seq) ~= "number" or entry.undo_seq < 0 or entry.undo_seq % 1 ~= 0 then
			return nil, "a buffer row must carry an integer undo_seq"
		end
		if type(entry.expected_hash) ~= "string" or #entry.expected_hash ~= 64 or not entry.expected_hash:match("^%x+$") then
			return nil, "a buffer row must carry expected_hash (64-hex content hash); 'the seq exists' is not evidence"
		end
		row.buffer_epoch = entry.buffer_epoch
		row.undo_seq = entry.undo_seq
		row.expected_hash = entry.expected_hash
	end
	return row, ws, rel
end

function M.intent(entry)
	local row, ws, rel_or_err = prepare_row(entry)
	if not row then
		return nil, ws
	end
	local rel = rel_or_err
	local ok, err = append_row(ws, rel, row)
	if not ok then
		return nil, "timeline intent not durable — the action must halt: " .. tostring(err)
	end
	-- SECONDARY and NON-FATAL on purpose: the per-path row above is already
	-- durable and is the real authority. A pointer-append failure costs the
	-- cross-file ORDER INDEX one entry (recoverable in principle by rescanning
	-- every per-path journal for this row's global_seq), never the decision
	-- itself -- halting the caller here would turn a secondary index's fsync
	-- failure into a refused accept/reject, which is a worse outcome than a
	-- stale pointer.
	local pok, perr = append_order_row(ws, { seq = row.global_seq, rel = rel, id = row.id, kind = row.kind })
	if not pok then
		log_warn("timeline order pointer not durable for " .. tostring(rel) .. ": " .. tostring(perr))
	end
	if row.regime == "buffer" then
		local bufnr = find_buffer(diff.abs_path(ws .. "/" .. rel))
		if bufnr then
			M.sync_buffer_head(bufnr, row)
		end
	end
	return row.id
end

--- Append an entry immediately, then complete the same durability sequence in
--- libuv callbacks. Returns the id once the append and flush requests exist;
--- callback receives the final durability verdict on Neovim's main loop.
--- This is only for an event already made true, never for a durable action
--- whose execution depends on the intent being durable first.
function M.intent_async(entry, callback)
	local row, ws, rel_or_err = prepare_row(entry)
	if not row then
		return nil, ws
	end
	local rel = rel_or_err
	local ok, err = append_row_async(ws, rel, row, function(durable, async_err)
		vim.schedule(function()
			if callback then
				callback(durable, async_err, row.id)
			end
		end)
	end)
	if not ok then
		return nil, "timeline intent not queued for durability: " .. tostring(err)
	end
	-- Same secondary, non-fatal pointer append as `M.intent`. Done
	-- synchronously even on this async path: the pointer file is tiny (one
	-- JSON line) and this keeps the ordering guarantee simple -- the order
	-- pointer for THIS row is on disk before the caller's `intent_async`
	-- returns, never racing a later row's pointer append.
	local pok, perr = append_order_row(ws, { seq = row.global_seq, rel = rel, id = row.id, kind = row.kind })
	if not pok then
		log_warn("timeline order pointer not durable for " .. tostring(rel) .. ": " .. tostring(perr))
	end
	-- The row is already appended at this point. Advance the in-memory cursor
	-- now, in append order, not from the later fsync callback: a later hunk
	-- event may update the head while this flush is still in flight, and the
	-- older callback must never move that head backwards.
	if row.regime == "buffer" then
		local bufnr = find_buffer(diff.abs_path(ws .. "/" .. rel))
		if bufnr then
			M.sync_buffer_head(bufnr, row)
		end
	end
	return row.id
end

--- Entries for one file, oldest first (journal append order), each with a
--- state DERIVED at call time. Second return: an error string when the journal
--- was damaged mid-file (the rows before the damage are still returned).
function M.entries(workspace, rel)
	local ws = diff.abs_path(workspace or vim.fn.getcwd())
	local rows, err = read_rows(journal_file(ws, rel))
	local out = {}
	if not rows then
		return out, err
	end
	local summaries = {}
	for _, row in ipairs(rows) do
		if row.rel == rel then
			local e = {
				id = row.id,
				kind = row.kind,
				label = row.label,
				regime = row.regime,
				rel = row.rel,
				ts = row.ts,
				buffer_epoch = row.buffer_epoch,
				undo_seq = row.undo_seq,
				expected_hash = row.expected_hash,
				diary_dir = row.diary_dir,
				op_id = row.op_id,
			}
			if row.regime == "durable" then
				e.state, e.state_detail = durable_state(row, summaries)
			else
				e.state, e.state_detail = buffer_state(ws, row)
			end
			out[#out + 1] = e
		end
	end
	local bufnr = find_buffer(diff.abs_path(ws .. "/" .. rel))
	if bufnr then
		local head = buffer_head(bufnr)
		local head_i
		for i, e in ipairs(out) do
			if e.id == head.id then
				head_i = i
				break
			end
		end
		if head_i then
			for i = head_i + 1, #out do
				if out[i].regime == "buffer" then
					out[i].state = "reverted"
					out[i].state_detail = "timeline head is at older row " .. tostring(head.id)
				end
			end
		end
	end
	return out, err
end

--- The single most recent NOT-YET-REVERTED row across every file this
--- workspace's timeline has, newest `global_seq` first. This is what
--- cross-file `u` (FIX-UNDO lane, ruling 2026-08-21) retraces against once a
--- file's own review has closed: global chronological order is a linear
--- extension of every per-path order, so the row this returns is
--- automatically its OWN path's newest un-reverted row too, and
--- `reachable()`'s per-path LIFO guarantee is never violated by walking
--- straight to it. A row whose file's review is still OPEN is skipped: that
--- surface belongs to the review's own `u`/`U`/`<C-r>` until it closes
--- (`review_open_for`, unchanged).
---
-- Only these kinds are operator-facing ACTIONS a retrace can undo.
-- `review_opened`/`review_closed` are markers -- they carry a real undo_seq
-- (so `walk`'s own machinery can target them as a LANDING state) but
-- reverting "review opened" is not a thing the operator did.
local UNDOABLE_KIND = {
	hunk_accepted = true,
	hunk_rejected = true,
	human_edit = true,
	applied = true,
}

--- Returns nil when there is nothing left to undo anywhere in the workspace
--- -- an empty pointer file, every row already reverted, or every remaining
--- row's file still mid-review. Callers MUST say so rather than doing
--- nothing silently (the retrace's own "empty history" contract).
---
--- `walk_target` is the id `walk.plan`/`walk.execute` must be called WITH:
--- walking "to" a row means landing on it, i.e. reverting everything NEWER
--- than it (`walk_impl.lua`'s own contract) -- so to revert `id` itself the
--- caller must target `id`'s own PREDECESSOR in that path's row list, which
--- this resolves once here rather than asking every caller to re-derive it.
--- nil when `id` is the first row for its path (the product always records a
--- `review_opened` marker there in practice, so this should not arise live).
---
--- `exclude` (optional set, id -> true) skips rows the caller has already
--- reported as refused THIS session -- operator ruling row 72 (a): a
--- refusal must not strand every OLDER row behind it, so the caller (the
--- retrace dispatcher) remembers what it already reported and asks for the
--- next candidate down, one press at a time. The refused row itself is
--- UNTOUCHED here: excluding it from this scan does not revert it, mark it,
--- or remove it from its own file's ordinary review -- it stays exactly
--- pending, reachable the normal way.
--- @return table|nil {rel, id, kind, global_seq, walk_target}, string|nil err
function M.next_undo(workspace, exclude)
	local ws = diff.abs_path(workspace or vim.fn.getcwd())
	local order_rows, oerr = read_rows(order_file(ws))
	if order_rows == nil then
		return nil, oerr
	end
	table.sort(order_rows, function(a, b)
		return (a.seq or 0) > (b.seq or 0)
	end)
	local entries_cache = {}
	for _, prow in ipairs(order_rows) do
		local rel = prow.rel
		if
			type(rel) == "string"
			and type(prow.id) == "string"
			and UNDOABLE_KIND[prow.kind]
			and not (exclude and exclude[prow.id])
		then
			if M.review_open_for(ws, rel) then
				goto continue_next_undo
			end
			local list = entries_cache[rel]
			if list == nil then
				list = M.entries(ws, rel)
				entries_cache[rel] = list
			end
			for i, e in ipairs(list) do
				if e.id == prow.id then
					if e.state == "done" then
						local prev = list[i - 1]
						return {
							rel = rel,
							id = e.id,
							kind = e.kind,
							global_seq = prow.seq,
							walk_target = prev and prev.id or nil,
							-- Carried for the ONE case `walk_target == nil` cannot
							-- express: a durable row with no buffer-recorded
							-- predecessor at all (ruling row 72(b) -- a file
							-- accepted without ever being opened, so no
							-- `review_opened` anchor was ever recorded for it).
							-- `walk.plan`/`walk.execute`'s target-lands-on
							-- abstraction has no id to name for "nothing came
							-- before this"; the caller needs these three fields
							-- to revert the op directly instead.
							regime = e.regime,
							diary_dir = e.diary_dir,
							op_id = e.op_id,
						}
					end
					break
				end
			end
		end
		::continue_next_undo::
	end
	return nil
end

--- Can this entry be walked to right now?
--- Returns (ok, blocked_by, reason): `blocked_by` is the id of the row that
--- must go first (per-path LIFO), `reason` is refusal text, set whenever ok is
--- false. This function only OBSERVES — it never moves buffer, tree or disk.
function M.reachable(workspace, rel, id)
	local ws = diff.abs_path(workspace or vim.fn.getcwd())
	if M.review_open_for(ws, rel) then
		return false, nil, "a review is open for " .. rel .. ": the timeline surface is disabled; use u/U/<C-r> or :YanaAbortReview"
	end
	local list, lerr = M.entries(ws, rel)
	if lerr then
		return false, nil, "timeline journal damaged — refusing to judge reachability: " .. lerr
	end
	local target, target_i
	for i, e in ipairs(list) do
		if e.id == id then
			target, target_i = e, i
			break
		end
	end
	if not target then
		return false, nil, "no timeline row " .. tostring(id) .. " for " .. tostring(rel)
	end

	if target.regime == "durable" then
		if target.state == "reverted" then
			return false, nil, "row " .. id .. " is already reverted"
		end
		if target.state == "refused" then
			return false, nil, "row " .. id .. " was refused; nothing was applied, so there is nothing to walk back"
		end
		if target.state == "pending" then
			return false, nil,
				"row " .. id .. " is unresolved (" .. (target.state_detail or "pending") .. "); the walk refuses to cross an unresolved row"
		end
		-- PER-PATH LIFO: the NEWEST later durable row that is still un-reverted
		-- (or unresolved) must go first; return its id.
		for i = #list, target_i + 1, -1 do
			local e = list[i]
			if e.regime == "durable" and (e.state == "done" or e.state == "pending") then
				local why = e.state == "pending" and "unresolved" or "still un-reverted"
				return false, e.id,
					"blocked by later durable row " .. e.id .. " (" .. tostring(e.label) .. ", " .. why
						.. "): durable revert is per-path LIFO — newest first"
			end
		end
		return true
	end

	-- Buffer row: the undo tree is the authority, and the row's epoch + hash
	-- decide whether the live tree is the one the row was recorded against.
	local abs = diff.abs_path(ws .. "/" .. rel)
	local buf = find_buffer(abs)
	if not buf then
		return false, nil, "no loaded buffer for " .. rel .. ": undo_seq is buffer-local and cannot be resolved without its buffer"
	end
	local epoch = current_epoch(buf)
	if epoch ~= target.buffer_epoch then
		return false, nil, string.format(
			"buffer epoch mismatch for row %s: recorded against %s, buffer now has %s — a recreated buffer can present a valid-looking seq from a different tree; refusing",
			id,
			tostring(target.buffer_epoch),
			tostring(epoch)
		)
	end
	local tree = buf_undotree(buf)
	local head = buffer_head(buf)
	if head.buffer_epoch ~= nil then
		local now_hash = buf_content_hash(buf)
		if
			head.buffer_epoch ~= epoch
			or head.undo_seq ~= tree.seq_cur
			or head.expected_hash ~= now_hash
		then
			return false, nil, string.format(
				"buffer history moved outside the timeline: expected epoch %s seq %s hash %s…, found epoch %s seq %s hash %s…; refusing",
				tostring(head.buffer_epoch),
				tostring(head.undo_seq),
				tostring(head.expected_hash):sub(1, 16),
				tostring(epoch),
				tostring(tree.seq_cur),
				tostring(now_hash):sub(1, 16)
			)
		end
	end
	if not seq_in_tree(tree, target.undo_seq) then
		return false, nil, string.format(
			"undo seq %d is no longer in this buffer's tree (history reloaded or trimmed); row %s stays listed but cannot be walked",
			target.undo_seq,
			id
		)
	end
	if tree.seq_cur == target.undo_seq then
		local now = buf_content_hash(buf)
		if now ~= target.expected_hash then
			return false, nil, string.format(
				"content hash mismatch at seq %d: expected %s…, buffer holds %s… — history moved by a path the timeline never saw; refusing",
				target.undo_seq,
				target.expected_hash:sub(1, 16),
				now:sub(1, 16)
			)
		end
	end
	return true
end

--- True while a review is OPEN for this file in this workspace. The inline
--- engine's active state is the authority; lazily required so this storage
--- module never drags the review UI into a headless reader.
function M.review_open_for(workspace, rel)
	local ok, inline = pcall(require, "yana.inline_diff")
	if not ok then
		return false
	end
	local ws = diff.abs_path(workspace or vim.fn.getcwd())
	local change = inline.active_change({ workspace = ws })
	if not change then
		return false
	end
	-- RETRACE REINTEGRATION EXEMPTION (FIX-UNDO lane, 2026-08-21).
	-- `lua/yana/timeline/retrace.lua` reopens a review to make a reversed
	-- hunk decidable again, and marks the change it builds
	-- `_retrace_reintegration = true`. That review must never freeze the
	-- OPERATOR'S OWN continued `u` presses into this same file's older,
	-- still-un-reverted history -- ruling row 72(a)'s "a refusal must not
	-- strand a hunk" reasoning extends here: reintegration exists to make a
	-- hunk decidable, not to jam retrace behind its own bookkeeping.
	-- Measured: P115's real-keypress sequence walks FIVE consecutive rows
	-- of the same file (A.txt) across five separate presses; without this
	-- exemption the second of those presses reads as "A.txt is mid-review"
	-- (because the first press's reintegration just opened one) and every
	-- older row for A.txt goes unreachable until that mini-review is
	-- decided. A GENUINE agent-turn review (no marker) still blocks below,
	-- exactly as before.
	if change._retrace_reintegration then
		return false
	end
	if change.path and rel and diff.abs_path(change.path) == diff.abs_path(ws .. "/" .. rel) then
		return true
	end
	if change.rel and change.rel == rel then
		return true
	end
	return false
end

--- Test/introspection only (FIX-UNDO lane): forget every workspace this
--- process has recorded a row for, and the cached global-seq high-water
--- marks with it. Real sessions never call this -- `known_workspaces`
--- growing for the process's whole lifetime is deliberate (retrace.lua's
--- `on_u_key`/`try_from_floor` read it to reach every root a session has
--- ever touched). A test harness that runs many INDEPENDENT scenarios back
--- to back in one Neovim process (the review-state-property row's model) is not one such
--- session, though, and without a reset a later scenario's very first `u`
--- press can retrace into an earlier scenario's leftover, already-torn-down
--- workspace -- measured 2026-08-21: the review-state-property row's seed 87002 shrunk to a bare `u`
--- reds only when run after an earlier witness in the same process, and
--- passes clean in isolation with the identical trace (see the FIX-UNDO
--- lane report). Call this between independent scenarios, never mid-trace.
function M._test_reset()
	known_workspaces = {}
	global_seq_cache = {}
end

return M
