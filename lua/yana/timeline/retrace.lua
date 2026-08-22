-- Cross-file retrace — the dispatcher behind "post-review `u`/`<C-r>`"
-- (FIX-UNDO lane, operator ruling 2026-08-21, verbatim intent: "undo hunk ->
-- hunk comes back -> keep undoing and RETRACING MY STEPS LIKE A TRUE UNDO...
-- across files"), and the orchestrator's design correction on top of it.
--
-- WHAT THIS OWNS, and what it does not. `lua/yana/timeline/record.lua`
-- stamps a workspace-monotonic `global_seq` on every row and keeps a small
-- ORDER-ONLY pointer file; `M.next_undo` there finds the single newest
-- not-yet-reverted row across every file. This module is what ACTS on that
-- answer: switch to the right buffer, drive the EXISTING
-- `lua/yana/timeline/walk.lua` (`plan`/`execute` -- a buffer step through
-- `:undo {seq}`, a durable step through `diary.revert_operation`, neither
-- rewritten here), and say what happened. It holds no bytes and no inverse of
-- its own; `timeline/init.lua`'s "no second authority" boundary is
-- unchanged.
--
-- WHERE THIS DOES NOT APPLY. While a file's OWN review is open, `u`/`U`/
-- `<C-r>` are its buffer-local keys (`inline_diff.lua`, `undo_key`/
-- `undo_turn`/`redo_key`, UNTOUCHED by this lane) and this module is never
-- reached for it -- `record.next_undo` already skips any row whose file is
-- mid-review, and `reachable()` refuses it independently if asked directly.
-- This is deliberately the SAME boundary `timeline/init.lua` already states:
-- "a raw `:undo` into an open review bypasses the decision unwind... the
-- ENTIRE surface is disabled then."
--
-- THE BLOCKED-CHAIN HAZARD, and the operator's own final ruling on it
-- (issue log row 72), which supersedes an earlier
-- FORCE-key design both independent design reviews had proposed: THERE IS
-- NO FORCE KEY. Operator's words: "a refusal if forgotten will mean I can't
-- go back and accept it in future" -- so a refused entry is never bypassed,
-- it is left exactly as it stands (still pending, still reachable through
-- that file's own review the ordinary way) and NAMED. A refusal on ONE
-- entry must not freeze every OLDER entry behind it: this module remembers
-- (in-memory, per root-set, `skip_set` below) which ids it has already
-- reported refused, so the NEXT `u` press tries the entry before it instead
-- of reporting the same refusal forever -- but each press still tries
-- exactly ONE entry and stops; nothing here cascades through several
-- entries in one press (that would itself be "advancing past it silently"
-- in every way that matters to the operator watching the messages go by).
local M = {}

local timeline = require("yana.timeline")
local walk = require("yana.timeline.walk")
local diff = require("yana.diff")
local notify = require("yana.notify")
local log = require("yana.log")
local diary = require("yana.safety.diary")
local shadow_apply = require("yana.shadow.apply")
local hash = require("yana.safety.hash")

-- Non-authoritative. Purely "which buffer-regime step did THIS dispatcher
-- last take back, so `<C-r>` knows what to replay forward" -- an id and a
-- kind, never bytes, same category as every other index this module reads.
-- Cleared per Neovim session; nothing here claims to survive a restart.
local redo_stacks = {}

local function redo_stack(ws)
	local s = redo_stacks[ws]
	if not s then
		s = {}
		redo_stacks[ws] = s
	end
	return s
end

-- Ids `M.undo` has already reported refused this session (ruling row 72a).
-- id -> true. Ids are minted process-wide unique (record.lua's `mint_id`),
-- so one flat set works across every root a retrace call spans -- no
-- per-root bookkeeping needed. Never cleared by a successful undo/redo
-- elsewhere: the refused entry's own route back is reopening its file's
-- review, not this index forgetting it was ever offered.
local skip_set = {}

local function abs_path(ws, rel)
	return (diff.abs_path(ws):gsub("/$", "")) .. "/" .. rel
end

--- `workspace` is one root or a list of roots (a panel/turn can have more
--- than one open at once, e.g. a repo and a sibling non-repo folder). Always
--- normalised to a list of absolute paths, so every caller below merges
--- across roots the same way.
local function resolve_roots(workspace)
	local list = workspace
	if type(list) == "string" then
		list = { list }
	elseif list == nil then
		list = { vim.fn.getcwd() }
	end
	local out, seen = {}, {}
	for _, w in ipairs(list) do
		local abs = diff.abs_path(w)
		if not seen[abs] then
			seen[abs] = true
			out[#out + 1] = abs
		end
	end
	return out
end

--- One key naming this exact set of roots, for the redo memory: two calls
--- with the same roots (in any order) share one ordered stack, because a
--- retrace across two roots is one action history, not two.
local function roots_key(roots)
	local sorted = { unpack(roots) }
	table.sort(sorted)
	return table.concat(sorted, "\30")
end

--- The minted id embeds `hrtime` (`tl-<pid_hex>-<hrtime_hex>-<seq>`,
--- record.lua's `mint_id`) -- nanosecond resolution and, within one editor
--- process, comparable across DIFFERENT workspace roots even though each
--- root's own `global_seq` counter is not. A cross-root panel is one editor
--- driving several roots, so this is the correct tie-break: finer than the
--- second-resolution `ts` every row also carries, which this falls back to
--- only if two ids ever came from different processes (never true for a
--- single retrace call, kept as a defensive fallback rather than a crash).
local function mint_order_key(row)
	local hrtime_hex = row.id and row.id:match("^tl%-%x+%-(%x+)%-%d+$")
	if hrtime_hex then
		local n = tonumber(hrtime_hex, 16)
		if n then
			return n
		end
	end
	return (row.ts or 0) * 1e9
end

--- The single newest not-yet-reverted row across EVERY given root. Within one
--- root `global_seq` already decides this order (record.next_undo's own
--- scan); across roots their counters are independent, so this compares by
--- MINT ORDER instead (see `mint_order_key`) -- never `global_seq` against
--- `global_seq` from a different root.
local function next_undo_across(roots)
	local best, best_ws, best_key
	for _, ws in ipairs(roots) do
		local row, err = timeline.next_undo(ws, skip_set)
		if row == nil and err then
			return nil, ws .. ": " .. tostring(err)
		end
		if row then
			local key = mint_order_key(row)
			if best == nil or key > best_key then
				best, best_ws, best_key = row, ws, key
			end
		end
	end
	if not best then
		return nil
	end
	return best, nil, best_ws
end

--- LOAD `rel`'s buffer if it is not already loaded -- a buffer-regime step
--- needs one to walk through (`walk_impl.step_buffer` operates via
--- `nvim_buf_call`, which works on an unlisted, invisible buffer exactly as
--- well as a displayed one). Operator ruling row 72(c): a file that is
--- loaded but not currently shown is acted on WITHOUT being shown -- do not
--- pop a window, do not steal the current one, do not open a split. If the
--- buffer already happens to be visible somewhere, Neovim repaints that
--- window on its own; nothing here needs to make it visible.
--- Returns the bufnr, or nil, err.
local function ensure_buffer(ws, rel)
	local path = abs_path(ws, rel)
	local bufnr = vim.fn.bufnr(path, false)
	if bufnr == -1 or bufnr == 0 then
		bufnr = vim.fn.bufadd(path)
		vim.fn.bufload(bufnr)
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, "could not load a buffer for " .. rel
	end
	return bufnr
end

local function lifecycle(kind, fields)
	local ok = pcall(log.lifecycle_later, kind, fields)
	if not ok then
		pcall(log.write, "WARN", kind .. ": " .. vim.inspect(fields))
	end
end

--- OPERATOR RULING ROW 72(b), 2026-08-21: revert a durable row DIRECTLY
--- via `diary.revert_operation`, for a path with NO buffer-recorded
--- predecessor to land on -- a file accepted without ever being opened in
--- Neovim (`accept_everything`'s queued-drain branch, `inline_diff.lua`),
--- so no `review_opened` anchor was ever recorded for it and
--- `walk.plan`/`walk.execute`'s target-lands-on abstraction has no id to
--- name for "nothing came before this". Mirrors `walk_impl.lua`'s own
--- `step_durable`, minus the multi-step plan/steps scaffolding -- there is
--- exactly one step here, and that scaffolding is exactly what needs the
--- target id this case has none to offer. Never used where
--- `walk.execute` already applies.
local function revert_never_opened_row(ws, row)
	if row.diary_dir == nil or row.op_id == nil then
		return false, "no journaled op id was ever recorded for this row"
	end
	local session, serr = diary.open(row.diary_dir)
	if not session then
		return false, "its diary (" .. tostring(row.diary_dir) .. ") could not be opened: " .. tostring(serr)
	end
	local ok, err, reverted_n = diary.revert_operation({ session = session, op_id = row.op_id })
	if not ok then
		return false, err
	end
	if reverted_n ~= 1 then
		return false,
			"the diary reports " .. tostring(reverted_n) .. " reverted operation(s) where exactly one (" .. row.op_id .. ") was asked"
	end
	-- The buffer plane is separate, same rule `walk_impl.lua` states: if a
	-- buffer for this path happens to exist anyway (the operator opened it
	-- independently, outside any review), reconcile it against what the
	-- applier just wrote -- best effort, never a reason to un-happen the
	-- disk revert that already committed.
	local abs = abs_path(ws, row.rel)
	local bufnr = vim.fn.bufnr(abs, false)
	if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
		local uv = vim.uv or vim.loop
		local stat = uv.fs_stat(abs)
		if stat then
			pcall(shadow_apply.reconcile_applied_buffer, { kind = "replace", path = abs, stat = stat })
		end
	end
	return true
end

--- The redo half of `revert_never_opened_row`: the diary keeps the
--- ORIGINAL write's content in its own "intent" row forever (never pruned
--- by a revert -- only the revert's own start/rollback/done markers get
--- appended), so redo re-reads it from there and writes it back through
--- the SAME journaled applier, rather than needing a second copy of
--- anything. This is what makes ruling 52's create-then-redo promise reach
--- a file that was never opened too: no buffer, no `change.after` in
--- memory anywhere -- the diary's own record is the only copy, and it was
--- always going to have to be.
local function redo_never_opened_row(entry)
	if entry.diary_dir == nil or entry.op_id == nil then
		return false, "no journaled op id was recorded for this row"
	end
	local session, serr = diary.open(entry.diary_dir)
	if not session then
		return false, "its diary (" .. tostring(entry.diary_dir) .. ") could not be opened: " .. tostring(serr)
	end
	local rows, jerr = diary.journal_rows(session)
	if not rows then
		return false, "its journal could not be read: " .. tostring(jerr)
	end
	local target, target_mode
	for _, r in ipairs(rows) do
		if r.kind == "intent" and r.op_id == entry.op_id then
			target = r.target
			target_mode = r.base_mode
			break
		end
	end
	if target == nil then
		return false, "the original write's content is no longer in the journal"
	end
	local ok, err = diary.restore_workspace_bytes({
		session = session,
		path = abs_path(entry.workspace, entry.rel),
		content = target,
		target_mode = target_mode,
	})
	if not ok then
		return false, err
	end
	return true
end

--- Record a refusal: named durably, added to `skip_set` so the row this
--- session never offers it again as "next", and the row it names is left
--- completely untouched -- still pending, still reachable by reopening its
--- own file's review, per ruling row 72(a).
local function refuse(row, reason, blocked_by)
	skip_set[row.id] = true
	local msg = "yana: could not undo " .. row.rel .. " -- " .. tostring(reason)
		.. "; that hunk stays pending -- reopen " .. row.rel .. " to decide it directly, or press u again to continue with the rest"
	log.write("WARN", msg)
	notify.one_line(msg, vim.log.levels.WARN)
	lifecycle("undo.retrace_refused", {
		workspace = row.workspace,
		rel = row.rel,
		id = row.id,
		global_seq = row.global_seq,
		blocked_by = blocked_by,
		reason = reason,
	})
end

----------------------------------------------------------------------
-- REINTEGRATION (FIX-UNDO lane, this session): retrace above this point
-- reverses the BYTES and the TIMELINE STATE, but on its own leaves nothing
-- for the operator to SEE or DECIDE -- the hunk is pending on disk and in
-- the log, but painted nowhere. This is the seam that closes that gap.
----------------------------------------------------------------------

-- One synthetic "panel" per workspace, reused across every reintegrated
-- accept in that root purely so `shadow_apply.accept_standalone`'s own
-- diary memo (`panel._standalone_diary`) is not rebuilt on every press --
-- the same minimal `{id, session_id, cwd}` shape the review-state property test
-- and ui.lua's no-shadow-pass fallback already use. A reintegrated hunk
-- belongs to no live turn/lifecycle pass by the time retrace reaches it,
-- so there is no richer panel to reuse.
local reintegration_panels = {}
local function reintegration_panel(ws)
	local p = reintegration_panels[ws]
	if not p then
		p = { id = "retrace-reintegrate:" .. ws, session_id = "retrace-reintegrate:" .. ws, cwd = ws }
		reintegration_panels[ws] = p
	end
	return p
end

--- THE SEAM: `inline_diff.review(change, opts)` -- the SAME public
--- open-or-enqueue entry every other caller (the panel picker, the queue
--- drain) already uses to hand a change to the review machinery. Feeding it
--- a change built from CURRENT DISK bytes vs CURRENT BUFFER bytes runs
--- `open_review_buffer` / `M.build_diff_blocks` / the extmark painting
--- exactly the path a fresh agent turn already takes -- this module grows
--- no second paint/bookkeeping path and holds no bytes of its own (the
--- before/after pair is re-read fresh on every call, never stored).
---
--- WHY DISK-VS-BUFFER, always, regardless of accept or reject: accepting a
--- hunk moves no buffer bytes (`accept_block_at`'s own comment -- the
--- agent's text has sat in the buffer since the review opened), so the
--- buffer's own undo tree cannot answer what the hunk's ORIGINAL text was.
--- The composed WRITE is what changed disk, though, and reversing THAT
--- durable row (`step_durable`, unchanged) restores disk to the true
--- pre-turn bytes while leaving the buffer exactly as the review closed
--- it -- so disk (original) vs buffer (still proposed) IS the hunk, with no
--- separate byte store needed. Rejecting a hunk is the mirror: disk was
--- never written for it, so it already holds the original, and reversing
--- the buffer-regime reject row puts the proposed text back into the
--- buffer only -- disk (original) vs buffer (now proposed) is again
--- exactly the hunk. Both cases fall out of the SAME two reads.
---
--- `change` is marked `_retrace_reintegration = true`, which
--- `record.review_open_for` reads to keep this file's OWN older history
--- reachable by later presses (see that function's comment) -- a
--- reintegrated review exists to make a hunk decidable, never to freeze
--- the operator's own walk behind it.
---
--- NAMED LIMITS, not silently accepted -- stated so a later lane can close
--- them instead of rediscovering them: (1) if this SAME path is
--- reintegrated again while the first reintegration is still undecided,
--- `inline.review` queues the second one behind the first (the ordinary
--- "parking is navigation" rule any two pending reviews follow) rather than
--- merging into one -- the operator sees them one after another, not
--- combined. (2) a LATER walk into the same buffer (a further `u` press
--- reaching an even older row of the same file) can move bytes this open
--- review is still displaying; nothing here re-syncs its painting
--- mid-flight -- `rerender_after_history_move`'s repaint-on-move pattern
--- would close this, not attempted here. Neither limit loses bytes or data:
--- every row this lane touches still reverts correctly regardless of
--- whether its paint stays fresh.
local function reintegrate(ws, rel, before, after)
	if before == after then
		return
	end
	if after == nil then
		return
	end
	local inline_ok, inline = pcall(require, "yana.inline_diff")
	if not inline_ok or type(inline.review) ~= "function" then
		return
	end
	local abs = abs_path(ws, rel)
	local uv = vim.uv or vim.loop
	local stat = uv.fs_stat(abs)
	local change = {
		id = "retrace-reintegrate-" .. tostring(uv.hrtime()),
		path = abs,
		rel = rel,
		kind = "modify",
		before = before,
		after = after,
		-- The empty hash for an absent path (shadow/ops.lua's own
		-- convention) -- `before == nil` here means retrace's revert left
		-- nothing on disk (a never-opened create, reversed), so the
		-- reintegrated mini-review is itself a create.
		base_hash = hash.hash_bytes(before or ""),
		base_state = stat and "file" or "absent",
		base_mode = stat and stat.mode or nil,
		status = "pending",
		_retrace_reintegration = true,
	}
	local opts = {
		workspace = ws,
		shadow_apply = true,
		on_shadow_accept = function(c, composed)
			return shadow_apply.accept_standalone(reintegration_panel(ws), c, composed)
		end,
	}
	-- ROW 80: `change` above is never `inline.M.enqueue`d -- the takeover
	-- below hands it straight to `_park_and_open_state` (or, when nothing is
	-- active, to `inline.review`, which itself skips enqueue when the pool is
	-- otherwise empty) -- so the ordinary paths that mint `_review_order`
	-- (`M.enqueue` inserting into the queue, `park_and_open_state` recording
	-- the item being left behind) can both end up never running for THIS
	-- change. Without it, `]x`/`[x` read `_review_order == nil` as "no
	-- siblings" and refuse in both directions even with a pending sibling
	-- file. `M._ensure_review_order` calls the exact same `remember_batch_item`
	-- those two paths call (see its own comment) -- no second ordering
	-- scheme -- and is idempotent, so calling it here ahead of the takeover
	-- is always safe regardless of which branch below ends up handling it.
	if type(inline._ensure_review_order) == "function" then
		inline._ensure_review_order(change, opts)
	end
	-- TAKE OVER, do not merely queue. `inline.review` alone would append
	-- behind whatever is currently active -- correct for two ordinary
	-- reviews, wrong for "undo": the operator just pressed `u` and the
	-- hunk it reversed must be what they see NEXT, not parked behind a
	-- turn's queue that happened to auto-advance somewhere else in the
	-- meantime. Measured 2026-08-21 against the operator's own worked
	-- example (`tests/gui/repro/rows/r_undo_cross_file_retrace.lua`): B's
	-- review closed, the queue auto-advanced to the turn's own untouched
	-- C, and `u` reintegrating B's hunk via plain `inline.review` queued it
	-- behind C -- `active_path()` stayed "c.py", not "b.py", so undo
	-- reversed the byte and the timeline row but the operator's own next
	-- press landed nowhere near what they had just undone. If something
	-- else is genuinely active, PARK it (ruling 7's own primitive,
	-- `inline._park_and_open_state`, the same one `]x`/`[x` navigation
	-- already uses to switch files without deciding the one left behind)
	-- and open the reintegrated hunk immediately in its place; the parked
	-- review is not lost -- it re-enters the queue exactly where park
	-- already puts it, reachable the ordinary way once this hunk is
	-- decided. A currently-active REINTEGRATION (an earlier `u` press's
	-- own hunk, still undecided) is parked the same way -- each `u` press
	-- shows what THAT press just reversed.
	-- DEFERRED ONE TICK, deliberately. The decision (and file) whose close
	-- JUST reversed almost always leaves its OWN `schedule_queue_advance`
	-- (inline_diff.lua's `finish_session`) sitting in Neovim's scheduler,
	-- queued the moment that file's review closed but not yet run -- the
	-- turn's own queue auto-advancing to whatever comes next is a
	-- `vim.schedule` callback, not a synchronous effect of the accept/reject
	-- keypress that triggered it. Deciding "is something active" and acting
	-- on it BEFORE that stale callback runs races it: this call can open
	-- (or park-and-open) the reintegrated hunk first, only for the turn's
	-- OWN advance to run a moment later, see the pool unchanged from ITS
	-- own stale point of view, and open its own next file on top -- the
	-- reintegrated review is silently replaced by something the operator
	-- never asked for. Measured 2026-08-21 against the operator's own
	-- worked-example fixture: the very first `u` press reintegrated b.py
	-- correctly, and the queue's own already-pending advance to c.py (from
	-- the accept BEFORE undo even began) clobbered it milliseconds later.
	-- Scheduling this callback AFTER that one (same FIFO queue) means it
	-- always observes the pool in its true settled state.
	vim.schedule(function()
		local active = inline.active_state and inline.active_state(opts)
		local ok, result
		if active and inline._park_and_open_state then
			ok, result = pcall(inline._park_and_open_state, active, "next", { change = change, opts = opts, owner = nil })
			if not (ok and result == true) then
				-- Either the pcall threw, or `park_and_open_state` returned
				-- false (not an exception -- the takeover itself failed to
				-- open, and it already tried to restore what it parked).
				-- Fall back to the ordinary queue rather than leaving the
				-- hunk unreachable.
				ok, result = pcall(inline.review, change, opts)
			end
		else
			ok, result = pcall(inline.review, change, opts)
		end
		if not ok then
			log.write("WARN", "yana.timeline.retrace reintegrate: could not reopen review for " .. rel .. ": " .. tostring(result))
		end
	end)
end

--- The never-opened-durable mirror of `reintegrate`'s disk-vs-buffer read:
--- there is no buffer at all here, so "after" (the proposed text) comes
--- from the diary's own intent row for this op -- the SAME row
--- `redo_never_opened_row` already reads, kept as its own small read here
--- rather than reused, so a failure to find it is silent (best-effort
--- reintegration) instead of changing `redo_never_opened_row`'s own
--- refusal text.
local function never_opened_proposed_text(diary_dir, op_id)
	if diary_dir == nil or op_id == nil then
		return nil
	end
	local session = diary.open(diary_dir)
	if not session then
		return nil
	end
	local rows = diary.journal_rows(session)
	if not rows then
		return nil
	end
	for _, r in ipairs(rows) do
		if r.kind == "intent" and r.op_id == op_id then
			return r.target
		end
	end
	return nil
end

--- `u`, once no in-review decision is left to pop for the file under the
--- cursor (i.e. the file's own review has already closed, or the cursor is
--- not in a review buffer at all). Returns true when it consumed the press
--- (successfully, or by a named refusal that leaves the hunk pending),
--- false when the workspace's whole cross-file history is empty -- callers
--- fall through to plain buffer undo in that case, exactly as they always
--- did.
--- @param workspace string|string[] one root, or every root this panel/turn
---   has open -- a cross-root retrace merges their histories (see
---   `next_undo_across`) rather than only ever seeing the first one.
--- @param opts table|nil `opts.reintegrate = true` hands a successfully
---   reversed hunk-decision or applied-write row back to the review
---   machinery (see `reintegrate` above) so it is paintable and decidable
---   again. Default false/omitted: bytes and timeline state move exactly as
---   before this session, no painting attempted -- this is what
---   `retrace.undo`'s existing direct callers (`:YanaUndo`, P113, P114, and
---   any future pure-engine caller) keep getting, unchanged. The keypress
---   dispatchers below (`on_u_key`, `try_from_floor`) are the only callers
---   that pass `reintegrate = true` -- painting is an OPERATOR-FACING
---   concern, not an engine one, and the engine's own regression coverage
---   (P113/P114/P115's `row_state`/byte assertions) depends on calling the
---   engine without it.
function M.undo(workspace, opts)
	opts = opts or {}
	local roots = resolve_roots(workspace)
	local row, rerr, ws = next_undo_across(roots)
	if row == nil then
		if rerr then
			notify.one_line("yana: could not read the cross-file undo history — " .. tostring(rerr), vim.log.levels.WARN)
			lifecycle("undo.retrace_error", { workspace = roots[1], reason = rerr })
			return true
		end
		notify.one_line("yana: nothing left to undo — the cross-file history is empty", vim.log.levels.INFO)
		return false
	end
	row.workspace = ws
	if row.walk_target == nil then
		if row.regime == "durable" then
			-- Ruling row 72(b): a file accepted without ever being opened.
			local ok, err = revert_never_opened_row(ws, row)
			if not ok then
				refuse(row, err)
				return true
			end
			local rkey = roots_key(roots)
			redo_stack(rkey)[#redo_stack(rkey) + 1] = {
				workspace = ws,
				rel = row.rel,
				id = row.id,
				kind = row.kind,
				regime = "durable",
				diary_dir = row.diary_dir,
				op_id = row.op_id,
				never_opened = true,
			}
			local said = "yana: undid " .. row.rel .. " -- accepted without ever being opened, reverted by disk write"
			log.write("WARN", said)
			notify.one_line(said, vim.log.levels.INFO)
			lifecycle("undo.retrace", {
				workspace = ws,
				rel = row.rel,
				id = row.id,
				row_kind = row.kind,
				global_seq = row.global_seq,
				regime = "durable",
				steps = 1,
				never_opened = true,
			})
			if opts.reintegrate then
				local disk = diff.read_file_bytes(abs_path(ws, row.rel))
				local proposed = never_opened_proposed_text(row.diary_dir, row.op_id)
				if proposed ~= nil then
					reintegrate(ws, row.rel, disk, proposed)
				end
			end
			return true
		end
		-- `id` is the first row recorded for its path (no `review_opened`
		-- anchor precedes it) -- the product always records one at review
		-- open for a BUFFER row, so this should not arise for one; refused
		-- by name rather than guessed at, and left pending exactly like
		-- any other refusal.
		refuse(row, "this is the first recorded row for this file; there is no earlier state to land on")
		return true
	end

	local ok, blocked_by, reason = timeline.reachable(ws, row.rel, row.walk_target)
	if not ok then
		refuse(row, reason, blocked_by)
		return true
	end

	local bufnr, berr = ensure_buffer(ws, row.rel)
	if not bufnr then
		refuse(row, berr)
		return true
	end

	local result = walk.execute(ws, row.rel, row.walk_target, { bufnr = bufnr })
	local committed = result.committed or {}
	local last = committed[#committed]
	if #committed == 0 or result.stopped_at ~= nil then
		refuse(row, result.reason)
		return true
	end

	local rkey = roots_key(roots)
	for _, entry in ipairs(committed) do
		redo_stack(rkey)[#redo_stack(rkey) + 1] = {
			workspace = ws,
			rel = row.rel,
			id = entry.id,
			kind = entry.kind,
			regime = entry.regime,
			bufnr = bufnr,
			-- Carried for a DURABLE entry (`M.entries` already returns
			-- these on every row, never opener-specific) so `M.redo` can
			-- redo an ordinary opened file's composed write the SAME way
			-- `redo_never_opened_row` already redoes one that never had a
			-- buffer -- see that function's own generality and `M.redo`'s
			-- comment at its call site.
			diary_dir = entry.diary_dir,
			op_id = entry.op_id,
		}
	end

	local said = "yana: undid " .. (last.label or last.kind or "the last decision") .. " in " .. row.rel
	log.write("WARN", said)
	notify.one_line(said, vim.log.levels.INFO)
	lifecycle("undo.retrace", {
		workspace = ws,
		rel = row.rel,
		id = last.id,
		row_kind = last.kind,
		global_seq = row.global_seq,
		regime = last.regime,
		steps = #committed,
	})
	-- REINTEGRATION. Gated on the LAST committed entry's kind: a plain
	-- `human_edit` reversal is the operator's own typing coming back, not a
	-- hunk decision, and painting it as a pending agent hunk would be
	-- exactly backwards -- there is no proposal to accept or reject. Every
	-- other UNDOABLE_KIND (`hunk_accepted`, `hunk_rejected`, `applied`) is a
	-- decision, and disk-vs-buffer now names it (see `reintegrate`'s own
	-- comment for why that pair is correct regardless of which decision it
	-- was).
	if opts.reintegrate and last.kind ~= "human_edit" then
		local disk = diff.read_file_bytes(abs_path(ws, row.rel))
		local buf_now = diff.buffer_bytes_snapshot(bufnr)
		if buf_now ~= nil then
			reintegrate(ws, row.rel, disk, buf_now)
		end
	end
	return true
end

--- `<C-r>`, the mirror of `M.undo`. Buffer-regime steps replay through
--- Neovim's own `:redo` on the buffer the undo came from (the editor's own
--- operation, exactly like the in-review `redo_key` already treats redo
--- elsewhere in this product) — the same tree `M.undo` walked backward
--- through, forward again. NAMED LIMIT: a DURABLE step (a write that had
--- already reached disk before this lane) has no redo primitive yet —
--- `diary.lua` never gained a "reapply the reverted write" counterpart, and
--- this refuses BY NAME rather than pretending. Returns false only when
--- there is truly nothing in this dispatcher's own redo memory to try —
--- callers fall through to plain buffer redo.
--- NAMED LIMIT (reintegration, this session): if `M.undo` reintegrated the
--- row this call is about to redo, that mini-review is left exactly as it
--- is -- undecided, still showing the now-stale hunk -- rather than closed
--- or refreshed. Out of scope for this lane's own job (the operator's
--- ruling under repair is "undo -- the hunk comes back", not redo); a later
--- lane can teach this call to discard or refresh that review the way
--- `reintegrate`'s own NAMED LIMITS comment already anticipates.
function M.redo(workspace)
	local roots = resolve_roots(workspace)
	local stack = redo_stack(roots_key(roots))
	local entry = table.remove(stack)
	if entry == nil then
		notify.one_line("yana: nothing left to redo in the cross-file history", vim.log.levels.INFO)
		return false
	end
	if entry.regime == "durable" then
		if entry.never_opened or (entry.diary_dir ~= nil and entry.op_id ~= nil) then
			-- Ruling row 72(b)/ruling 52's own mechanism, generalised this
			-- session: `redo_never_opened_row` never actually depended on
			-- "never opened" -- it reads the diary's own intent row for
			-- `op_id` and writes `target` back, which is exactly as true
			-- for an ordinary file's composed accept as for one that was
			-- queued-and-accepted sight unseen. `M.entries` already
			-- carries `diary_dir`/`op_id` on every durable row, opener or
			-- not (this lane's own `M.undo` above now copies them onto
			-- every regular redo_stack entry too), so the ONLY thing that
			-- made this look never-opened-specific was that nothing
			-- carried the fields through for the regular path until now.
			local ok, err = redo_never_opened_row(entry)
			if not ok then
				stack[#stack + 1] = entry
				local msg = "yana: cannot redo " .. entry.rel .. " -- " .. tostring(err)
				log.write("WARN", msg)
				notify.one_line(msg, vim.log.levels.WARN)
				lifecycle("redo.retrace_refused", { workspace = entry.workspace, rel = entry.rel, id = entry.id, reason = err })
				return true
			end
			-- A REGULAR file (unlike the never-opened case) usually still
			-- has a live buffer; bring it back in step with what redo just
			-- wrote, same best-effort reconcile `revert_never_opened_row`
			-- already does for the opposite direction -- never a reason to
			-- un-happen the disk write that already committed.
			local abs = abs_path(entry.workspace, entry.rel)
			local bufnr2 = vim.fn.bufnr(abs, false)
			if bufnr2 > 0 and vim.api.nvim_buf_is_loaded(bufnr2) then
				local uv = vim.uv or vim.loop
				local stat = uv.fs_stat(abs)
				if stat then
					pcall(shadow_apply.reconcile_applied_buffer, { kind = "replace", path = abs, stat = stat })
				end
			end
			local said = entry.never_opened
					and ("yana: redid " .. entry.rel .. " -- restored, byte-identical, without ever opening it")
				or ("yana: redid " .. entry.rel .. " -- the composed write reached disk again")
			log.write("WARN", said)
			notify.one_line(said, vim.log.levels.INFO)
			lifecycle("redo.retrace", { workspace = entry.workspace, rel = entry.rel, id = entry.id, row_kind = entry.kind })
			return true
		end
		-- Put it back so a later, real redo primitive can still find it, and
		-- refuse rather than silently drop the operator's redo press. NAMED
		-- GAP, narrower now: a durable row this lane cannot name an
		-- `op_id` for at all (recorded before diary_dir/op_id were
		-- threaded through, or from a path outside this lane's own
		-- capture) still has no redo primitive.
		stack[#stack + 1] = entry
		local msg = "yana: cannot redo " .. entry.rel .. " -- redoing a write that already reached disk is not built yet; the file stays at its turn-start bytes"
		log.write("WARN", msg)
		notify.one_line(msg, vim.log.levels.WARN)
		lifecycle("redo.retrace_refused", { workspace = entry.workspace, rel = entry.rel, id = entry.id, reason = "durable redo not implemented" })
		return true
	end
	local bufnr, berr = ensure_buffer(entry.workspace, entry.rel, nil)
	if not bufnr then
		local msg = "yana: cannot redo " .. entry.rel .. " -- " .. tostring(berr)
		log.write("WARN", msg)
		notify.one_line(msg, vim.log.levels.WARN)
		return true
	end
	local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
		vim.cmd("silent redo")
	end)
	if not ok then
		log.write("WARN", "yana.timeline.retrace redo: " .. tostring(err))
	end
	local ok_record, record = pcall(require, "yana.timeline.record")
	if ok_record and type(record.sync_buffer_head) == "function" then
		local ok_entries, entries = pcall(timeline.entries, entry.workspace, entry.rel)
		if ok_entries then
			for _, e in ipairs(entries) do
				if e.id == entry.id then
					record.sync_buffer_head(bufnr, e)
					break
				end
			end
		end
	end
	local said = "yana: redid " .. (entry.kind or "the last undone step") .. " in " .. entry.rel
	log.write("WARN", said)
	notify.one_line(said, vim.log.levels.INFO)
	lifecycle("redo.retrace", { workspace = entry.workspace, rel = entry.rel, id = entry.id, row_kind = entry.kind })
	return true
end

----------------------------------------------------------------------
-- THE SEAM: a bare `u`/`<C-r>` in a buffer whose review has CLOSED.
--
-- THE EXACT CONDITION (operator's own requirement -- stated precisely,
-- not shipped ambiguous): a press in buffer B dispatches to cross-file
-- retrace IF AND ONLY IF
--
--   (1) `record.buffer_head(B)` has a numeric `undo_seq` at all -- i.e.
--       Yana has recorded at least one timeline row against B this
--       session (a buffer it never reviewed never qualifies), AND
--   (2) B's LIVE position -- `record.observe_buffer(B)`, the same
--       `{buffer_epoch, undo_seq}` pair `reachable()`'s buffer branch
--       already compares -- is EXACTLY EQUAL to that head: same epoch
--       (a recreated buffer never matches), same `undo_seq`.
--
-- `buffer_head` is updated at every `timeline.intent` call AND at the end
-- of every buffer-regime `walk_impl.step_buffer` / this module's own
-- `M.redo` -- so it always names "where YANA's own bookkeeping last put
-- this buffer's undo tree", never a stale snapshot. If the condition does
-- not hold -- the operator typed something since, or already ran a plain
-- `:undo`/`:redo` that moved the tree elsewhere -- this is the editor's
-- own history now, and plain Neovim undo/redo runs, UNCHANGED, exactly as
-- if Yana were not installed. This is the SAME two-owner rule
-- `inline_diff.lua`'s in-review `undo_key` already states ("the newest
-- thing in the tree is the human's own edit... hands straight to
-- Neovim's undo"), reapplied here to the CLOSED-review case with the
-- already-durable `buffer_head` standing in for that function's local
-- `state.decisions` stack.
--
-- WHERE THIS ENGAGES, and where it does not. `inline_diff.lua`'s `M.open`
-- installs its OWN buffer-local `u`/`U`/`<C-r>` for the DURATION of an
-- open review; Neovim resolves a buffer-local mapping over anything set
-- here, so while that review is open THIS module is never reached for
-- that buffer -- `undo_key`/`undo_turn`/`redo_key` are byte-identical to
-- before this lane, untouched. The moment that review closes,
-- `M.cleanup` deletes those maps and installs `on_u_key`/`on_redo_key`
-- (below) in their place, buffer-local to exactly that buffer -- never a
-- global `u` remap, never a buffer Yana has not itself reviewed.
----------------------------------------------------------------------

--- `u` once a review has closed. See the seam comment above for the exact
--- condition; this is only its implementation.
function M.on_u_key(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local head = timeline.buffer_head(bufnr)
	local cur = timeline.observe_buffer(bufnr)
	local eligible = head ~= nil
		and cur ~= nil
		and type(head.undo_seq) == "number"
		and head.buffer_epoch == cur.buffer_epoch
		and head.undo_seq == cur.undo_seq
	if not eligible then
		local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
			vim.cmd("silent undo")
		end)
		if not ok then
			log.write("WARN", "yana.timeline.retrace native undo: " .. tostring(err))
		end
		return
	end
	local roots = timeline.known_workspaces()
	if #roots == 0 then
		roots = { vim.fn.getcwd() }
	end
	-- `M.undo` returning `false` means the cross-file TIMELINE has nothing
	-- left for any root it knows about -- not that undo history itself is
	-- exhausted. Neovim's own tree usually still has more (the staging
	-- edit that opened the review, and anything before it): once the
	-- product's own bookkeeping stops, plain undo is exactly what should
	-- pick up from there, unchanged (the post-close stepping row's contract: `u`
	-- steps one hunk per press and then reaches the pre-turn file, same
	-- as if this module had never wrapped it).
	local consumed = M.undo(roots, { reintegrate = true })
	if not consumed then
		local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
			vim.cmd("silent undo")
		end)
		if not ok then
			log.write("WARN", "yana.timeline.retrace native undo (fallthrough): " .. tostring(err))
		end
	end
end

--- `<C-r>` once a review has closed. Mirror of `on_u_key`.
function M.on_redo_key(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local head = timeline.buffer_head(bufnr)
	local cur = timeline.observe_buffer(bufnr)
	local eligible = head ~= nil
		and cur ~= nil
		and type(head.undo_seq) == "number"
		and head.buffer_epoch == cur.buffer_epoch
		and head.undo_seq == cur.undo_seq
	if not eligible then
		local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
			vim.cmd("silent redo")
		end)
		if not ok then
			log.write("WARN", "yana.timeline.retrace native redo: " .. tostring(err))
		end
		return
	end
	local roots = timeline.known_workspaces()
	if #roots == 0 then
		roots = { vim.fn.getcwd() }
	end
	local consumed = M.redo(roots)
	if not consumed then
		local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
			vim.cmd("silent redo")
		end)
		if not ok then
			log.write("WARN", "yana.timeline.retrace native redo (fallthrough): " .. tostring(err))
		end
	end
end

--- ROW 74 (issue log, orchestrator ruling 2026-08-21): `u` pressed inside a
--- review that has JUST opened (the queue auto-advanced here, e.g. right
--- after the file this press SHOULD have reached closed) has nothing of
--- its OWN to pop -- and `inline_diff.lua`'s own in-review floor guard
--- read that as "nothing to undo at all", refusing immediately rather
--- than asking whether some OTHER file still has an un-reverted decision
--- from the SAME session. It does not: the dispatcher must answer from
--- the order index, never from the active file. Called from
--- `inline_diff.lua`'s `undo_key`, ONLY at its own floor (this review's
--- own decision stack is empty and the buffer has not moved since the
--- review opened) -- the decision-popping branch above that check is
--- completely untouched. Returns true when the cross-file history
--- reached SOMETHING (a real reversal, or a named refusal about that
--- other file) -- in either case the floor's own generic refusal must
--- not also fire. Returns false only when the cross-file history is
--- genuinely empty too, so the ORIGINAL floor message still applies.
function M.try_from_floor()
	local roots = timeline.known_workspaces()
	if #roots == 0 then
		roots = { vim.fn.getcwd() }
	end
	return M.undo(roots, { reintegrate = true })
end

--- Install `on_u_key`/`on_redo_key` as buffer-local `u`/`<C-r>` on `bufnr`.
--- Called from `inline_diff.lua`'s `M.cleanup`, exactly where that
--- review's OWN buffer-local `u`/`U`/`<C-r>` were just deleted -- see the
--- seam comment above.
function M.install_post_review_keys(bufnr)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		return
	end
	vim.keymap.set("n", "u", function()
		M.on_u_key(bufnr)
	end, { buffer = bufnr, desc = "yana: undo (retraces across files once this review is closed)" })
	vim.keymap.set("n", "<C-r>", function()
		M.on_redo_key(bufnr)
	end, { buffer = bufnr, desc = "yana: redo (retraces across files once this review is closed)" })
end

--- Test/introspection only.
function M._test_reset()
	redo_stacks = {}
	skip_set = {}
	reintegration_panels = {}
end

return M
