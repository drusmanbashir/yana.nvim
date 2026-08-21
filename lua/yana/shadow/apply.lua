-- Accept-from-shadow pass: diary + checkpoint are the only real-tree writers.
local M = {}

local diary = require("yana.safety.diary")
local checkpoint = require("yana.safety.checkpoint")
local preview = require("yana.shadow.preview")
local diff = require("yana.diff")
local log = require("yana.log")
local hash = require("yana.safety.hash")

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

----------------------------------------------------------------------
-- FILE CLAIMS (PLAN-R1-capture.md §5)
----------------------------------------------------------------------
--
-- A broad root cannot be claimed whole -- that would lock every repository
-- beneath it -- so the turn claim keeps governing "may a second turn on THIS
-- repository start", and a second, finer claim governs "may this file's hunk
-- be reviewed and accepted". It is taken at FINALIZE, once per `(repository,
-- relative path)` the walk actually found touched; it is never taken at
-- launch, it never blocks a write, and it never blocks a human save. Only the
-- accept is refused, and it is refused BY NAME.
--
-- LIVENESS IS ONE QUESTION WITH ONE ANSWER. The holder record is the SAME
-- `pid boot_id start_ticks` record `shadow/jail.lua`'s `mark_review_open`
-- writes for an open review -- written here by that same function, so there is
-- one writer -- and it is judged by the same three verdicts, in the same order
-- and with the same fail-closed default, as `bin/yana-overlay`'s
-- `holder_is_live` (bin/yana-overlay:1413): the boot id makes the record
-- meaningless after a reboot, the process start time makes it survive pid
-- reuse, and anything that cannot be established is `unknown` and refuses.
-- "Dead" therefore means one thing everywhere.

local uv_mod = vim.uv or vim.loop

--- The claim record for one `(repository, relative path)`.
---
--- Keyed by the repository's FILESYSTEM IDENTITY, exactly as the turn claim is
--- (`claim_identity.workspace_slug`), so two editors reaching the same
--- repository by two different path spellings collide as they should; and by a
--- digest of the relative path, because a path is not a filename.
function M.file_claim_dir(root, rel)
	if type(root) ~= "string" or root == "" or type(rel) ~= "string" or rel == "" then
		return nil
	end
	local claim_identity = require("yana.claim_identity")
	return table.concat({
		preview.state_root(),
		"file-claims",
		claim_identity.workspace_slug(root),
		vim.fn.sha256(rel):sub(1, 32),
	}, "/")
end

local function read_first_line(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local line = f:read("l")
	f:close()
	if type(line) ~= "string" then
		return nil
	end
	return (line:gsub("%s+$", ""))
end

local function proc_start_ticks(pid)
	local line = read_first_line("/proc/" .. tostring(pid) .. "/stat")
	if not line then
		return nil
	end
	-- The comm field can contain spaces and parentheses, so everything up to
	-- the LAST ')' is skipped first -- the same parse `shadow/jail.lua` does.
	local after = line:match("%)%s+(.*)$")
	if not after then
		return nil
	end
	local fields = {}
	for w in after:gmatch("%S+") do
		fields[#fields + 1] = w
	end
	return fields[20]
end

--- alive / dead / unknown for one holder record. Never a boolean: a host where
--- `/proc` or the boot id cannot be read is `unknown`, and `unknown` refuses.
function M.holder_liveness(record_path)
	local raw = read_first_line(record_path)
	if not raw or raw == "" then
		return "unknown", "the holder record carries no identity"
	end
	local pid, boot, ticks = raw:match("^(%d+)%s+(%S+)%s+(%S+)")
	if not pid or not boot or not ticks then
		return "unknown", "the holder record is not a usable identity"
	end
	if vim.fn.filereadable("/proc/" .. pid .. "/stat") ~= 1 then
		return "dead", "the editor that opened this review is no longer running (pid " .. pid .. ")"
	end
	local boot_now = read_first_line("/proc/sys/kernel/random/boot_id")
	local ticks_now = proc_start_ticks(pid)
	if not boot_now or boot_now == "" or not ticks_now or ticks_now == "" then
		return "unknown", "the holder's identity could not be re-read"
	end
	if boot_now ~= boot or ticks_now ~= ticks then
		return "dead", "the editor that opened this review is gone (pid " .. pid .. " was reused)"
	end
	return "alive", "pid " .. pid
end

local function claim_owner(dir)
	local f = io.open(dir .. "/owner", "r")
	if not f then
		return nil
	end
	local raw = f:read("*a") or ""
	f:close()
	local ok, obj = pcall(vim.json.decode, raw)
	if ok and type(obj) == "table" then
		return obj
	end
	return nil
end

--- Who holds this claim, in the operator's words. Named, never anonymous: a
--- refusal that cannot say whose review is in the way is not actionable.
local function holder_description(dir)
	local owner = claim_owner(dir)
	local verdict, detail = M.holder_liveness(dir .. "/review-open")
	local who
	if owner and owner.turn_id and owner.workspace then
		who = string.format("turn %s in %s", tostring(owner.turn_id), tostring(owner.workspace))
	elseif owner and owner.turn_id then
		who = "turn " .. tostring(owner.turn_id)
	else
		who = "an unidentified turn"
	end
	return who .. ", " .. tostring(detail), owner, verdict
end

local function remove_claim(dir)
	pcall(vim.fn.delete, dir, "rf")
end

--- Take the claim for one touched path, reclaiming a DEAD holder's.
---
--- The directory creation is the atomic step (`mkdir(2)` fails EEXIST), so two
--- editors racing for the same file cannot both win; the holder record is
--- written immediately after, by the same function that writes an open
--- review's identity, so the claim's existence and whose it is become one
--- fact.
---
--- Returns `true, dir` when this turn holds it; `false, dir, description` when
--- somebody else does.
function M.take_file_claim(root, rel, owner)
	local dir = M.file_claim_dir(root, rel)
	if not dir then
		return false, nil, "the change carries no repository/path to claim"
	end
	local jail = require("yana.shadow.jail")
	vim.fn.mkdir(vim.fn.fnamemodify(dir, ":h"), "p")
	for attempt = 1, 2 do
		-- `mkdir(2)` ONCE, not `mkdir -p`: the failure on an existing directory is
		-- what makes acquisition atomic between two editors.
		local ok = uv_mod.fs_mkdir(dir, 493)
		if ok then
			jail.mark_review_open(dir)
			-- Written with `io.open`, NOT `diff.write_file`. `diff.write_file` is
			-- a tier-1 real-workspace write wrapper (tests/suite/round5_scan.lua's
			-- `WORKSPACE_WRITERS`), and this file may not call one: everything
			-- here lands under the state root, never on a reviewed path, and the
			-- claim record is exactly the kind of thing `shadow/jail.lua` already
			-- writes with `io.open`.
			local f = io.open(dir .. "/owner", "w")
			if f then
				f:write(vim.json.encode(owner or {}))
				f:close()
			end
			return true, dir
		end
		local description, existing, verdict = holder_description(dir)
		if
			existing
			and owner
			and tostring(existing.turn_id) == tostring(owner.turn_id)
			and tostring(existing.workspace) == tostring(owner.workspace)
		then
			-- Our own claim, from an earlier finalize of the same turn.
			return true, dir
		end
		if verdict == "dead" and attempt == 1 then
			-- The same reclaim the turn claim allows, on the same evidence: the
			-- holder is provably gone, so the record is cleared and the claim is
			-- taken. `unknown` never reaches here -- it refuses.
			remove_claim(dir)
		else
			return false, dir, description
		end
	end
	return false, dir, "the file claim could not be taken"
end

--- Give one claim back. Path-keyed, exactly like turn-claim release, so a
--- failure can never wedge a turn.
function M.release_file_claim(dir)
	if type(dir) ~= "string" or dir == "" then
		return false
	end
	remove_claim(dir)
	return true
end

--- Every file claim a turn took, given back. Called from `preview.release`, so
--- every path that finishes or abandons a review releases them -- and never
--- from agent exit alone, which the module forbids while a review is open.
function M.release_file_claims(holder)
	if type(holder) ~= "table" then
		return true
	end
	local claims = holder.file_claims
	if type(claims) ~= "table" then
		return true
	end
	for _, dir in ipairs(claims) do
		M.release_file_claim(dir)
	end
	holder.file_claims = {}
	return true
end

--- Take one claim per touched path at FINALIZE, and mark every change with the
--- answer. A change whose claim is held by another live turn is NOT dropped
--- and NOT hidden: it is reviewed as usual, and only its accept is refused --
--- so the operator sees the conflict named on the hunk it belongs to.
local function take_file_claims(pass, changes)
	local turn = pass.shadow_turn or {}
	local owner = {
		turn_id = tostring(pass.turn_id or turn.turn_id or "?"),
		workspace = turn.workspace,
		stream = turn.stream,
	}
	turn.file_claims = turn.file_claims or {}
	pass.file_claims = turn.file_claims
	for _, change in ipairs(changes or {}) do
		local root = (type(change.root) == "string" and change.root ~= "") and change.root or turn.workspace
		if root and change.rel then
			local held, dir, description = M.take_file_claim(root, change.rel, owner)
			if held then
				change.file_claim = dir
				change.file_claim_conflict = nil
				turn.file_claims[#turn.file_claims + 1] = dir
			else
				change.file_claim = nil
				change.file_claim_conflict = {
					dir = dir,
					root = root,
					rel = change.rel,
					holder = description,
				}
			end
		end
	end
end

--- The accept-time half of the file claim, paired with the `base_hash` guard
--- at the same step and named in the same voice.
---
--- Re-asked at the moment of the accept rather than trusted from finalize: the
--- holder may have settled since the review opened, and the honest answer then
--- is "take it and proceed", not "refuse because it was busy a minute ago".
function M.file_claim_refusal(pass, change)
	local conflict = change and change.file_claim_conflict
	if type(conflict) ~= "table" then
		return nil
	end
	local turn = (pass and pass.shadow_turn) or {}
	local owner = {
		turn_id = tostring((pass and pass.turn_id) or turn.turn_id or "?"),
		workspace = turn.workspace,
		stream = turn.stream,
	}
	local held, dir, description = M.take_file_claim(conflict.root, conflict.rel, owner)
	if held then
		change.file_claim = dir
		change.file_claim_conflict = nil
		turn.file_claims = turn.file_claims or {}
		turn.file_claims[#turn.file_claims + 1] = dir
		if pass then
			pass.file_claims = turn.file_claims
		end
		return nil
	end
	return string.format(
		"refusing to accept %s: %s is under review in another turn (holder: %s) — finish or reject that review "
			.. "first, or force-release it",
		tostring(change.path),
		conflict.root .. "/" .. conflict.rel,
		tostring(description or conflict.holder)
	)
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
	-- ONE JOURNAL PER ROOT, and the root is read off the change, never guessed.
	-- `safety/diary.lua` refuses a target outside its session's workspace
	-- ("path escapes workspace") and `safety/checkpoint.lua` refuses to capture
	-- one, which is exactly the boundary that makes a journal trustworthy. A
	-- declared write root is a workspace in its own right, so it gets its own
	-- journal rooted at itself rather than a widened check on the workspace's.
	-- A turn with no declared root produces one journal with the same paths in
	-- the same order it always did.
	local primary = shadow_turn.workspace
	local paths = {}
	local paths_by_root = {}
	for _, change in ipairs(changes or {}) do
		if change.path then
			paths[#paths + 1] = change.path
			local root = (type(change.root) == "string" and change.root ~= "") and change.root or primary
			local list = paths_by_root[root]
			if not list then
				list = {}
				paths_by_root[root] = list
			end
			list[#list + 1] = change.path
		end
	end
	local pass = {
		shadow_turn = shadow_turn,
		diary_begin = {
			workspace = primary,
			stream = shadow_turn.stream,
		},
		turn_id = tostring(shadow_turn.turn_id),
		paths = paths,
		paths_by_root = paths_by_root,
		checkpoint_started = false,
	}
	-- THE FILE CLAIMS, taken here and nowhere earlier: this is the moment the
	-- walk's touched set is known and the review opens (PLAN-R1-capture.md §5).
	-- Best effort per path and never fatal -- a store that cannot be reached
	-- must not stop a review from opening, and the accept-time check re-asks.
	pcall(take_file_claims, pass, changes)
	return pass, nil
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

--- The workspace of the root a change belongs to, or the pass's primary.
local function change_root(pass, change)
	local primary = pass.diary_begin and pass.diary_begin.workspace or nil
	local root = change and change.root
	if type(root) ~= "string" or root == "" then
		return primary
	end
	return root
end

--- The journal for ONE root, opened on demand.
---
--- The primary root goes through `ensure_session` untouched, so a single-root
--- pass -- and every pass built by hand, which carries `diary_session` and no
--- `diary_begin` at all -- behaves exactly as before. A declared write root
--- opens its own journal, rooted at itself, the first time an accept on that
--- root reaches this point; a turn whose extra-root changes are all rejected
--- never creates one.
local function session_for_root(pass, root)
	local primary = pass.diary_begin and pass.diary_begin.workspace or nil
	if not root or root == "" or primary == nil or root == primary then
		return ensure_session(pass)
	end
	pass.diary_sessions = pass.diary_sessions or {}
	if pass.diary_sessions[root] then
		return pass.diary_sessions[root]
	end
	local session, berr = diary.begin({
		workspace = root,
		stream = pass.diary_begin.stream,
	})
	if not session then
		local err = berr or ("opening the durable journal for " .. root .. " failed")
		pass.diary_begin_halted = err
		return nil, err
	end
	pass.diary_begin_halted = nil
	pass.diary_sessions[root] = session
	return session
end

--- Every journal this pass has actually opened, primary first. Read-only:
--- asking what the pass has written must never be the thing that makes it write.
local function opened_sessions(pass)
	local out = {}
	if pass and pass.diary_session then
		out[#out + 1] = pass.diary_session
	end
	for _, session in pairs((pass and pass.diary_sessions) or {}) do
		out[#out + 1] = session
	end
	return out
end

local function ensure_checkpoint(pass, root)
	root = root or (pass.diary_begin and pass.diary_begin.workspace) or nil
	local primary = pass.diary_begin and pass.diary_begin.workspace or nil
	local is_primary = (primary == nil) or (root == primary)
	if is_primary then
		if pass.checkpoint_started then
			return true
		end
	else
		pass.checkpoints_started = pass.checkpoints_started or {}
		if pass.checkpoints_started[root] then
			return true
		end
	end
	local session, serr = session_for_root(pass, root)
	if not session then
		return false, serr
	end
	-- Only THIS root's paths. checkpoint.begin_turn resolves every path inside
	-- its session's workspace and refuses one that is not, so handing it the
	-- whole turn's paths would fail the moment a turn spans two roots.
	local paths = pass.paths
	if root and pass.paths_by_root and pass.paths_by_root[root] then
		paths = pass.paths_by_root[root]
	end
	local cp, err = checkpoint.begin_turn({
		session = session,
		turn_id = pass.turn_id,
		paths = paths,
	})
	if not cp then
		return false, err
	end
	if is_primary then
		pass.checkpoint_started = true
	else
		pass.checkpoints_started[root] = true
	end
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

	-- THE UNSAVED-EDITS GUARD. `modified` alone does not tell us whether the
	-- human typed something OUTSIDE this turn: inline-mode review composes
	-- accepted/rejected hunks and the human's own refinements directly IN the
	-- review buffer, so a buffer that is `modified` going into accept is the
	-- NORMAL case there, not a red flag -- and by construction its bytes are
	-- exactly `applied.target_hash`, the fingerprint of what this call is
	-- about to install (the same `composed` string the applier already wrote
	-- to disk). What actually distinguishes a genuine independent edit is
	-- disagreeing with BOTH fingerprints this turn knows about:
	--
	--   * `applied.base_hash` (== `change.base_hash`, the drift guard in
	--     accept_composed already refuses to accept without it) -- the
	--     buffer is exactly the pre-turn file, untouched.
	--   * `applied.target_hash` -- the buffer already IS the turn's own
	--     result, whether because inline review put it there or because a
	--     caller passed a buffer already carrying it.
	--
	-- Matching either means replacing it with the applier's bytes discards
	-- nothing (the second case does not even change anything visible).
	-- Matching NEITHER means the human changed this buffer independently of
	-- this turn, and `nvim_buf_set_lines` below would silently overwrite
	-- their work the instant it ran. Refuse instead: disk already carries the
	-- accepted change (the diary is the sole real-tree writer and already
	-- wrote it), but the buffer -- and the human's bytes in it -- are left
	-- exactly as they were, still `modified`, so nothing of theirs is lost.
	-- The changed-on-disk prompt this leaves armed is now a TRUE one:
	-- something outside this turn (the human) really did diverge, which is
	-- exactly the case that prompt exists for.
	--
	-- Neither fingerprint present at all (not "both absent because they
	-- happen to be nil", but a CALLER that never carries this turn's
	-- context, e.g. `timeline/walk_impl.lua`'s post-revert reconcile) is a
	-- caller that has not opted into this guard, not a caller with something
	-- to hide -- it gets the pre-guard behaviour, unconditional reconcile,
	-- unchanged. Row 70 owns the ACCEPT path (`accept_composed`,
	-- `accept_standalone`), which always supplies `base_hash`; a walk step
	-- reconciling the buffer to a disk state it refused to change (the revert-reconcile row) is a
	-- different contract this guard must not reach into.
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
	-- Re-stamp the buffer's view of the file mtime without reloading or raising
	-- changed-on-disk prompts. `edit!` did this implicitly; here the bytes
	-- already match disk and only the timestamp cache is stale.
	--
	-- KNOWN RESIDUAL (documented, not fixed here -- see SYNC-70 in
	-- tests/tests.md): 'autoread' defaults ON in Neovim, so this unmodified
	-- buffer takes `:checktime`'s SILENT-RELOAD branch regardless of whether
	-- the FileChangedShell autocmd fired -- it re-reads the file and replaces
	-- the buffer wholesale. Bytes come out identical (we just wrote them
	-- ourselves), but the replace registers as a second, redundant undo state
	-- on top of the one this function just made. Holding `autoread` off for
	-- this call removes that redundant state, but `lua/yana/timeline`'s
	-- per-path walk (the timeline walk row) counts undo-tree slots between durable rows and is
	-- calibrated against the padded numbering that redundant state produces
	-- -- suppressing it silently shifted that walk by one row in testing.
	-- Fixing this belongs beside that counting logic, not here, so the
	-- padding stays for now.
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

	-- THE FILE CLAIM, paired with the drift guard above at the SAME accept step:
	-- the fingerprint answers "is the file the one this review was prepared
	-- against", and this answers "is anybody else already reviewing it".
	-- Removing this one line is the mutation
	-- tests/suite/p108_second_editor_clobber.lua drives.
	local claim_refusal = M.file_claim_refusal(pass, change)
	if claim_refusal then
		return false, claim_refusal
	end

	-- THE ACTION WAITING FOR ITS DURABLE STATE. The journal is opened here, on
	-- the accept, rather than when the review opened. It is opened BEFORE the
	-- checkpoint, because the checkpoint writes inside the diary directory the
	-- `begin` row names; a failure here returns without touching anything, so
	-- the change stays offered and the accept stays retryable.
	local root = change_root(pass, change)
	local session, serr = session_for_root(pass, root)
	if not session then
		return false, serr
	end
	local ok, err = ensure_checkpoint(pass, root)
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

--- The panel-local journal a standalone accept or scope revert writes through.
---
--- Primary-root changes keep `panel._standalone_diary`, opened at the review
--- workspace exactly as before. A change from a declared write root cannot be
--- journalled there -- the diary refuses a target outside its own workspace --
--- so it gets its own panel-local journal rooted at that root, kept beside the
--- first one and reused for every later change from the same root.
local function standalone_session(panel, change, label)
	local primary_root = change and change.root_is_primary ~= false
	if primary_root then
		if not panel._standalone_diary then
			local ws = change.review_workspace or panel.cwd or vim.fn.getcwd()
			local session, err = diary.begin({
				workspace = ws,
				stream = panel.session_id or ("panel-" .. tostring(panel.id or label)),
			})
			if not session then
				return nil, err
			end
			panel._standalone_diary = session
		end
		return panel._standalone_diary
	end
	panel._standalone_diary_roots = panel._standalone_diary_roots or {}
	local root = change.root
	if panel._standalone_diary_roots[root] then
		return panel._standalone_diary_roots[root]
	end
	local session, err = diary.begin({
		workspace = root,
		stream = panel.session_id or ("panel-" .. tostring(panel.id or label)),
	})
	if not session then
		return nil, err
	end
	panel._standalone_diary_roots[root] = session
	return session
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

	-- The same accept-step pairing as `accept_composed`, on the preview-mode
	-- route that has no apply pass.
	local standalone_claim_refusal = M.file_claim_refusal(nil, change)
	if standalone_claim_refusal then
		return false, standalone_claim_refusal
	end
	-- A change from a declared write root journals at THAT root: the diary's
	-- own "path escapes workspace" refusal is a boundary worth keeping, so the
	-- root becomes the journal's workspace rather than the check being widened.
	-- A primary-root change keeps the panel journal it has always used.
	local session, serr = standalone_session(panel, change, "inline")
	if not session then
		return false, serr
	end
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
		base_hash = change.base_hash,
		target_hash = hash.hash_bytes(is_delete and "" or (composed or "")),
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
	local session, serr = standalone_session(panel, change, "scope")
	if not session then
		return false, serr
	end
	return diary.restore_workspace_bytes({
		session = session,
		path = change.path,
		content = change.before,
		base_hash = change.base_hash,
		base_state = change.base_state,
		base_mode = change.base_mode,
		base_link_target = change.base_link_target,
	})
end

--- The turn whose PRIVATE evidence directory a staged removal belongs in --
--- the one `preview.discard` deletes when the turn finishes. Ruling 52 puts
--- the staged bytes there and NOT in the timeline:
--- `lua/yana/timeline/init.lua` states it holds no byte snapshot because that
--- "would create a second authority", and a staged copy is exactly such a
--- snapshot.
local function staging_turn(panel)
	local turn = (panel and panel.shadow_turn)
		or (panel and panel.shadow_pass and panel.shadow_pass.shadow_turn)
	if type(turn) ~= "table" or type(turn.private_dir) ~= "string" or turn.private_dir == "" then
		return nil, "this turn has no private evidence directory to stage a removal into"
	end
	return turn
end

--- Copy the file's CURRENT bytes into the turn's private dir, journal WHERE
--- they went, then remove the file through the journaled applier. The removal
--- is an ordinary `delete` op on the diary, so the sole-real-tree-writer
--- contract is untouched; the note is the only thing that says where redo can
--- find the bytes again.
local function stage_and_remove(panel, session, change)
	local turn, derr = staging_turn(panel)
	if not turn then
		return false, "cannot undo " .. tostring(change.rel or change.path) .. ": " .. derr
	end
	local content = diff.read_file_bytes(change.path)
	if content == nil then
		return false,
			"cannot undo " .. tostring(change.rel or change.path) .. ": its bytes are not readable, so removing it would not be recoverable"
	end
	local uv = vim.uv or vim.loop
	local st = uv.fs_stat(change.path)
	-- The COPY is `preview`'s, not this module's: the applier holds no direct
	-- writer of its own (the universal-negative inventory row), and preview.lua is the
	-- module that owns the turn's private directory.
	local staged_path, werr = preview.stage_undo_removal(turn, diff.abs_path(change.path), content)
	if not staged_path then
		return false,
			"cannot undo " .. tostring(change.rel or change.path) .. ": staging its bytes failed (" .. tostring(werr) .. ")"
	end
	local nok, nerr = diary.note(session, {
		kind = "undo.stage",
		path = diff.abs_path(change.path),
		staged_path = staged_path,
		bytes = #content,
		mode = st and (st.mode % 4096) or nil,
	})
	if not nok then
		pcall(vim.fn.delete, staged_path)
		return false,
			"cannot undo " .. tostring(change.rel or change.path) .. ": the staging could not be journaled (" .. tostring(nerr) .. ")"
	end
	local ok, err = diary.restore_workspace_bytes({
		session = session,
		path = change.path,
		content = "",
		op_kind = "delete",
	})
	if not ok then
		return false, err
	end
	change._undo_staged = {
		staged_path = staged_path,
		bytes = #content,
		mode = st and (st.mode % 4096) or nil,
	}
	log.lifecycle_later("undo.stage_removed", {
		turn_id = change.turn_id or change.turn_gen,
		generation = change.turn_gen,
		path = change.rel or change.path,
		staged = staged_path,
		bytes = #content,
	})
	return true, nil, { rel = change.rel or change.path, staged_path = staged_path, bytes = #content, removed = true }
end

--- Put ONE path back to the bytes the turn started from, through the
--- journaled applier. Ruling 48 (issue log row 48): `U` undoes every edit of
--- the whole turn, and a file the operator already ACCEPTED is already on
--- disk -- so undoing it is a real-tree WRITE with no accept behind it. That
--- is permitted by the ruling, but it is still a write, so it goes through the
--- diary like every other one: intent row, displaced copy, verification, and
--- something for crash recovery to work from. The sole-real-tree-writer
--- contract is not bent for it.
---
--- `base_hash` is deliberately NOT passed. The accept moved the file, so the
--- pre-turn fingerprint is exactly what disk must NOT be expected to hold;
--- `diary.restore_workspace_bytes` observes the CURRENT state instead and
--- displaces it, which is what makes this undo reversible in its turn.
function M.revert_to_turn_start(panel, change)
	if not panel or not change or not change.path then
		return false, "revert needs a panel and a path"
	end
	local session, serr
	local pass = panel.shadow_pass
	if pass then
		session, serr = session_for_root(pass, change_root(pass, change))
	else
		session, serr = standalone_session(panel, change, "undo_turn")
	end
	if not session then
		return false, serr
	end
	if change.before == nil then
		-- An agent-CREATED file has no turn-start bytes, only turn-start
		-- ABSENCE. Ruling 52 (issue log row 52): `U` branches on what the file
		-- WAS at turn start rather than refusing, so putting absence back is a
		-- journaled STAGE-AND-REMOVE -- the bytes are copied into the turn's
		-- private evidence directory first, so stepping forward again through
		-- redo can put them back.
		return stage_and_remove(panel, session, change)
	end
	return diary.restore_workspace_bytes({
		session = session,
		path = change.path,
		content = change.before,
		target_mode = change.base_mode,
	})
end

--- Redo's half of ruling 52: put a staged-and-removed file back, byte for
--- byte, through the same journaled applier the removal used.
---
--- RETENTION IS THE TURN'S PRIVATE DIR AND NOTHING LONGER. `preview.discard`
--- deletes it when the turn finishes, so once the turn's evidence is pruned
--- the staged bytes are GONE. That case is detected and REFUSED BY NAME here;
--- it is never a silent no-op, because "redo did nothing" and "redo restored
--- your file" look identical to an operator who is not staring at the disk.
function M.restore_staged_removal(panel, change)
	if not panel or not change or not change.path then
		return false, "restore needs a panel and a path"
	end
	local staged = change._undo_staged
	if type(staged) ~= "table" or type(staged.staged_path) ~= "string" then
		return false, "nothing was staged for " .. tostring(change.rel or change.path)
	end
	if vim.fn.filereadable(staged.staged_path) ~= 1 then
		return false,
			"the staged copy of "
				.. tostring(change.rel or change.path)
				.. " is gone (this turn's evidence has been pruned) — redo-scoped recovery only, so its bytes cannot be restored"
	end
	local content = diff.read_file_bytes(staged.staged_path)
	if content == nil then
		return false, "could not read the staged copy of " .. tostring(change.rel or change.path)
	end
	local session, serr
	local pass = panel.shadow_pass
	if pass then
		session, serr = session_for_root(pass, change_root(pass, change))
	else
		session, serr = standalone_session(panel, change, "undo_turn")
	end
	if not session then
		return false, serr
	end
	local ok, err = diary.restore_workspace_bytes({
		session = session,
		path = change.path,
		content = content,
		target_mode = staged.mode,
	})
	if not ok then
		return false, err
	end
	log.lifecycle_later("undo.restore", {
		turn_id = change.turn_id or change.turn_gen,
		generation = change.turn_gen,
		path = change.rel or change.path,
		staged = staged.staged_path,
		bytes = #content,
	})
	change._undo_staged = nil
	return true, nil, { rel = change.rel or change.path, staged_path = staged.staged_path, bytes = #content }
end

function M.revert_pass(pass)
	-- A pass with no journal has nothing captured and nothing to put back.
	if not pass or not pass.diary_session then
		return true
	end
	-- Every root that opened a journal is reverted, not just the workspace's: a
	-- turn that wrote into two roots and is reverted must put both back. Each
	-- root's checkpoint is its own durable artefact under its own diary
	-- directory, and the same "the artefact decides" rule applies to each.
	for _, session in pairs(pass.diary_sessions or {}) do
		if vim.fn.filereadable(checkpoint.manifest_path(session, pass.turn_id)) == 1 then
			local ok, err = checkpoint.revert_turn({ session = session, turn_id = pass.turn_id })
			if not ok then
				return ok, err
			end
		end
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
	local sessions = opened_sessions(pass)
	if #sessions == 0 then
		-- No accept has happened on this pass, so no journal exists. Reading it
		-- must not open one: introspection is not an action.
		return {}
	end
	local rows = {}
	for _, session in ipairs(sessions) do
		local path = session.diary_dir .. "/journal.jsonl"
		if vim.fn.filereadable(path) == 1 then
			for _, line in ipairs(vim.fn.readfile(path)) do
				if line ~= "" then
					rows[#rows + 1] = vim.json.decode(line)
				end
			end
		end
	end
	return rows
end

function M.read_real_bytes(path)
	return diff.read_file_bytes(path)
end

return M
