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

-- FAULT INJECTION, default OFF, the same `_test.fault` shape
-- lua/yana/shadow/apply.lua uses. Armed only by the recorder's synthetic-bug
-- menu (oracle/adapters/yana-v2/rec/plant) so the "undo moved the bytes but
-- the hunk never came back" defect can be put on camera deliberately.
M._test = { fault = {} }

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
	return require("yana.single_file").buffer_abs_path(ws, rel)
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
--- THE TURN BOUNDARY, decided ONCE across every root (operator ruling #99,
--- 2026-08-23). Asking each root to derive its own current turn would leak: a
--- turn that touched only root A leaves root B's newest row belonging to the
--- PREVIOUS turn, and root B would then offer that row as if it were current
--- -- the cross-root shape of exactly the bug this gate closes.
--- `mint_order_key` is the same cross-root ordering `next_undo_across` already
--- uses for the rows themselves.
--- Returns nil when no root has a single register row.
local function current_turn_across(roots)
	local gate, gate_key
	for _, ws in ipairs(roots) do
		local t = timeline.current_turn(ws)
		if t then
			local key = mint_order_key(t)
			if gate == nil or key > gate_key then
				gate, gate_key = t, key
			end
		end
	end
	return gate
end

local function next_undo_across(roots)
	local gate = current_turn_across(roots)
	if gate == nil then
		-- No root has a single register row: the same "history is empty"
		-- answer this function has always given for that.
		return nil
	end
	local best, best_ws, best_key
	for _, ws in ipairs(roots) do
		local row, err = timeline.next_undo(ws, skip_set, gate)
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

local function buffer_range(bufnr)
	if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
		return nil
	end
	local n = vim.api.nvim_buf_line_count(bufnr)
	return { start_line = 1, end_line = n, source = "buffer_after_undo" }
end

--- Yana just moved this buffer's history itself (the plain `:undo`/`:redo`
--- below, reached when this dispatcher's own register has nothing left). Put
--- the head on the position that move produced, or the next press compares
--- against the position BEFORE it and refuses as drift -- forever. See
--- `record.absorb_own_history_move` for the operator measurements.
local function absorb_own_move(bufnr)
	local ok, rec = pcall(require, "yana.timeline.record")
	if ok and type(rec) == "table" and type(rec.absorb_own_history_move) == "function" then
		pcall(rec.absorb_own_history_move, bufnr)
	end
end

--- Post-review native redo can schedule `on_lines` while Yana's rewind
--- suppress/hold counters are still up, so the deferred reconcile is dropped
--- and a withdrawn review never restores. Try a direct restore once the redo
--- has landed (property seed 87008 step 35).
local function reconcile_withdrawn_after_native_redo(bufnr)
	local ok_inline, inline = pcall(require, "yana.inline_diff")
	if not ok_inline or type(inline._rewind_try_restore_after_redo) ~= "function" then
		return
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return
	end
	inline._rewind_try_restore_after_redo(vim.fn.fnamemodify(name, ":p"))
end

local function notify_drift(bufnr, head, cur, action)
	local rel = vim.api.nvim_buf_get_name(bufnr)
	local reason = "undo sequence drift: buffer is at seq "
		.. tostring(cur and cur.undo_seq)
		.. ", but Yana's register head is seq "
		.. tostring(head and head.undo_seq)
	notify.one_line("yana: " .. reason, vim.log.levels.WARN)
	lifecycle("undo.retrace_refused", {
		rel = rel,
		reason = reason,
		action = action,
		head_seq = head and head.undo_seq,
		current_seq = cur and cur.undo_seq,
	})
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

--- THE ONE SHAPE a review this module reopens (or brings forward from
--- parked) must be handed, or `finish_session` falls through to the "legacy
--- in-place accept path is removed" refusal — that fallback fires whenever
--- `state.opts.shadow_apply` is missing, and every real-tree write this
--- module's reopened reviews make must route through the journaled applier
--- like any other (`shadow_apply.accept_standalone`, the SAME primitive a
--- freshly-opened review from the panel uses).
--- `reintegrate()` always built this inline; `redo_hunk_decision`'s
--- park-and-bring-forward path (WIP commit 28636ea) built its OWN bare
--- `{ workspace = ... }` instead and never wired shadow_apply in, so a
--- redo that had to park the active review and bring a CLOSED file's review
--- forward closed it again straight into that refusal (measured:
--- "refused to accept bravo.py -- legacy direct-write path is removed",
--- immediately followed by retrace's own "redid hunk_accepted in bravo.py",
--- reporting success over a write that never happened). ONE constructor,
--- used everywhere this module opens or reopens a review, so no third call
--- site can drift from the other two again.
local function retrace_review_opts(ws)
	return {
		workspace = ws,
		shadow_apply = true,
		on_shadow_accept = function(c, composed, ...)
			return shadow_apply.accept_standalone(reintegration_panel(ws), c, composed, ...)
		end,
	}
end

--- THE BASE A REINTEGRATED REVIEW MUST DIFF AGAINST (issue-log row 112).
--- Disk alone is not it. Ruling 87: accepting a hunk in an OPEN buffer writes
--- NOTHING, so a file whose review closed with one hunk accepted and one
--- rejected still holds its PRE-TURN bytes on disk -- and disk-vs-buffer then
--- paints the ACCEPTED hunk as pending again alongside the one this press
--- actually reversed. One `u` press hands back two decisions (row 112's
--- measured pending counts 4,3,2,**4** where 3 was owed).
--- Every decision this file's own timeline still reads as `done` is a decision
--- the operator has NOT walked back, so its hunk is composed back into the
--- base here and only the reverted hunk returns as pending.
--- NO SECOND BYTE AUTHORITY: nothing is stored. The hunk boundaries come from
--- `inline.build_diff_blocks` over the change's OWN turn-start pair, disk and
--- the buffer are read fresh by the caller, and the composition is refused
--- outright (returning disk unchanged, the old behaviour) whenever the pair no
--- longer describes the bytes on disk.
--- NAMED LIMIT: a decision recorded FROM a reintegrated review labels its hunk
--- by that mini-review's own ordinal, not the turn model's, so a still-standing
--- accept taken inside one is mapped by that ordinal. Every walk this lane
--- measures reverts such a row before it is read back; a later lane that wants
--- the mapping exact should carry `model_index` on the timeline row itself
--- (`inline_diff.lua` already has it at both record sites) instead of parsing
--- the operator-facing label.
local function settled_base(ws, rel, change, before, after, inline)
	if type(inline.build_diff_blocks) ~= "function" or type(change) ~= "table" then
		return before
	end
	-- The turn-start pair, captured ONCE -- this function's own overwrite of
	-- `change.before`/`change.after` below is what would otherwise make the
	-- model drift after the first reintegration.
	local model = change._retrace_model
	if model == nil then
		model = { before = change.before, after = change.after }
		change._retrace_model = model
	end
	if type(model.before) ~= "string" or model.before ~= before then
		-- Disk is not at the turn-start bytes (a save, a durable write, an
		-- outside edit): the model's hunk boundaries do not describe this text,
		-- so nothing is composed and the caller gets plain disk-vs-buffer.
		return before
	end
	local ok, entries = pcall(timeline.entries, ws, rel)
	if not ok or type(entries) ~= "table" then
		return before
	end
	-- LAST DECISION PER HUNK WINS. The journal is append-only and the head is a
	-- single pointer, so a hunk decided, walked back, and decided AGAIN carries
	-- two rows -- and once the newer one is itself walked back, the older one
	-- reads `done` again simply by sitting at the head. Reading every `done` row
	-- would then call that hunk settled and the press would reopen nothing at
	-- all (measured: r74_reviews_opened_does_not_grow, cycle 2's `u`). Only the
	-- NEWEST row for a hunk describes its current state; an older row for the
	-- same hunk was superseded when the operator decided it again.
	local last, any = {}, false
	for _, e in ipairs(entries) do
		if e.regime == "buffer" and (e.kind == "hunk_accepted" or e.kind == "hunk_rejected") then
			local n = tonumber(tostring(e.label or ""):match("hunk (%d+)"))
			if n then
				last[n] = e
			end
		end
	end
	local settled = {}
	for n, e in pairs(last) do
		if e.state == "done" and e.kind == "hunk_accepted" then
			settled[n] = true
			any = true
		end
	end
	if not any then
		return before
	end
	local blocks = inline.build_diff_blocks(model.before, model.after or after)
	if type(blocks) ~= "table" or #blocks == 0 then
		return before
	end
	local lines = vim.split(before, "\n", { plain = true })
	local out, cursor = {}, 1
	for i, b in ipairs(blocks) do
		local first = b.start_line
		local last = b.end_line
		if type(first) ~= "number" or type(last) ~= "number" or first < cursor then
			return before
		end
		for k = cursor, first - 1 do
			out[#out + 1] = lines[k]
		end
		if settled[i] then
			for _, l in ipairs(b.new_lines or {}) do
				out[#out + 1] = l
			end
		else
			for k = first, last do
				out[#out + 1] = lines[k]
			end
		end
		cursor = last + 1
	end
	for k = cursor, #lines do
		out[#out + 1] = lines[k]
	end
	return table.concat(out, "\n")
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
--- YANA'S OWN TRANSACTION, ACROSS SCHEDULED WORK (KI-1, 2026-08-24).
---
--- The walk below is not synchronous. It moves the buffer itself (`walk.execute`
--- reverses the bytes of the decision this press took back) and then does its
--- reintegration and review reopen from `vim.schedule` callbacks, and a close
--- inside the walk queues a queue advance that opens and stages the NEXT file
--- a tick later again. Every one of those edits is Yana's own.
---
--- `inline._rewind_suppress` cannot cover that: it holds the rewind
--- reconciler's guard for one frame and releases it on the next tick, so the
--- walk's scheduled edits landed AFTER the release and the reconciler read
--- them as the operator time travelling -- withdrawing a review the walk still
--- owned, mid-step. Measured under the parallel gate as the r75 redo-paint and
--- r113 reopen families; it passed on a quiet box, which is why it survived.
---
--- `inline._rewind_own_transaction` takes a TOKEN instead, released when the
--- walk's own scheduled work has actually finished -- no timer and no duration
--- anywhere in it. Deferred work started while the token is open joins it (see
--- `walk_schedule` and inline_diff's HOLDS block), so the chain is covered
--- however deep it goes.
---
--- NO SILENT DEGRADE. inline_diff is a sibling module of this one and always
--- present; an inline_diff that loads but does not expose the seam is a
--- WIRING ERROR, and the one thing it must not do is quietly run the walk
--- unguarded -- a tree in that state measures nothing while looking like it
--- passed (it cost this lane one whole verification run). It is asserted, by
--- name, on the first walk. The only tolerated fallback is inline_diff not
--- being loadable at all, which is not a state a walk can occur in anyway.
local function yana_own_transaction(fn)
	local inline = require("yana.inline_diff")
	if type(inline._rewind_own_transaction) ~= "function" then
		error("yana.timeline.retrace: yana.inline_diff has no _rewind_own_transaction -- "
			.. "the rewind guard is not wired and this walk would run unguarded", 0)
	end
	return inline._rewind_own_transaction(fn)
end

--- `vim.schedule` for a piece of the walk's own deferred work: inside a walk
--- it joins the walk's token, outside one it is exactly `vim.schedule`.
--- Asserted for the same reason as `yana_own_transaction`.
local function walk_schedule(fn)
	local inline = require("yana.inline_diff")
	if type(inline._rewind_schedule) ~= "function" then
		error("yana.timeline.retrace: yana.inline_diff has no _rewind_schedule -- "
			.. "the rewind guard is not wired and this walk's deferred work would escape it", 0)
	end
	return inline._rewind_schedule(fn)
end

local function reintegrate(ws, rel, before, after, reverted_ids)
	-- REC-PLANT seam (`skip_reintegrate`, default off, see M._test.fault at the
	-- top): the caller's byte and timeline revert has already happened; only the
	-- reopening of the review is skipped, which is exactly the reported shape.
	if M._test.fault.skip_reintegrate then
		return
	end
	if after == nil then
		return
	end
	-- NO `before == after` EARLY RETURN. It used to sit here, and it is the
	-- upstream half of issue-log row 113: `before` is DISK and `after` is the
	-- BUFFER, an accept in an open review moves no bytes (ruling 87), so the
	-- moment anything writes the accepted bytes -- a `:w`, ruling 76's
	-- register entry, a turn-end write -- disk EQUALS the buffer and this
	-- returned silently. The register said "undid accept hunk 2 in a.py", the
	-- change stayed accepted with zero painted bands, and the active review
	-- never left the other file (measured by lane row113-s3,
	-- /s/agent_rw/tmp/lpd-20260823/row113-s3/SUMMARY.md section 1).
	-- Whether a hunk is pending is a REGISTER question, and
	-- `inline.reopen_from_register` below is what asks it. Disk-vs-buffer is
	-- kept only as the fallback for a file the register knows nothing about.
	local inline_ok, inline = pcall(require, "yana.inline_diff")
	if not inline_ok or type(inline.review) ~= "function" then
		return
	end
	local abs = abs_path(ws, rel)
	local uv = vim.uv or vim.loop
	local opts = retrace_review_opts(ws)
	-- RULING 74 (AD:895): `u` after a review closes REOPENS THE ORIGINAL
	-- review, same identity -- it does not manufacture a new one. LOOK UP the
	-- change this workspace's pool already recorded for `rel` (the same set
	-- `undo_rest_of_turn`'s `turn_changes` draws from, `inline_diff.lua`)
	-- BEFORE minting anything. Found: reuse THAT table -- every decision
	-- record, ledger row and log line already names it by `change.id`, and
	-- `M.enqueue`/`park_and_open_state` never rebuild a change table either,
	-- so this is the same kind of identity-preserving reuse the rest of the
	-- tree already relies on. Not found (a genuinely cross-turn `u`: nothing
	-- has ever been recorded for this rel in this workspace's pool): mint a
	-- fresh one exactly as before, and say so -- there is no original
	-- identity to reopen.
	local change = type(inline._find_change_for_rel) == "function" and inline._find_change_for_rel(rel, opts) or nil
	if change then
		-- ROW 113: ONE reopen path. `inline.reopen_from_register` builds the
		-- pending set from this file's REGISTER and anchors it in the BUFFER --
		-- it needs no disk read, so it is correct whether or not the accepted
		-- bytes have already been written, and it sets the change's pair,
		-- status and markers itself. It also refuses by name (returning nil)
		-- rather than guessing when the buffer no longer matches what the
		-- register says was decided.
		local reopened = nil
		if type(inline.reopen_from_register) == "function" then
			local bufnr = vim.fn.bufnr(abs, false)
			if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
				reopened = inline.reopen_from_register(ws, rel, bufnr, nil, reverted_ids)
			end
		end
		if reopened then
			before, after = reopened.before, reopened.after
		else
			-- FALLBACK, unchanged: a file the register holds no hunk decisions
			-- for (ruling 72(b)'s never-opened accept, a cross-turn mint) is
			-- still reintegrated from disk-vs-buffer, with row 112's
			-- still-standing accepts composed back into the base.
			-- ROW 112: only the decision this press reversed comes back as
			-- pending (see `settled_base`).
			before = settled_base(ws, rel, change, before, after, inline)
			if before == after then
				return
			end
		end
		-- Only the two sides of THIS hunk decision, and the pending state,
		-- move. `base_hash`/`base_state`/`base_mode` describe the file at
		-- TURN START, not at this reintegration, and stay whatever they were;
		-- `id` is the whole point of reusing the table. The navigation order
		-- is refreshed below so the reused object occupies the same "just
		-- reopened" position the old fresh-object path occupied.
		change.before = before
		change.after = after
		change.status = "pending"
		change._retrace_reintegration = true
		-- ROW 112: this pair is NEWER than any parked snapshot the change is
		-- still carrying (`inline_diff.lua`'s `M.open` reads the flag once and
		-- clears it), so the reopened review shows what the walk just left,
		-- not what the file looked like before this press.
		change._retrace_fresh = true
		if type(inline._reopen_review_order) == "function" then
			inline._reopen_review_order(change, opts)
		end
	elseif before == after then
		-- Nothing recorded for this rel and disk already equals the buffer:
		-- there is no pair to mint a review from. (This is the ONLY case the
		-- deleted top-of-function early return still covers.)
		return
	else
		log.write(
			"INFO",
			"yana.timeline.retrace reintegrate: no prior change recorded for "
				.. rel
				.. " in this workspace's pool -- minting a fresh review (cross-turn undo)"
		)
		local stat = uv.fs_stat(abs)
		change = {
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
			-- Captured right here, from `before` read moments ago in this same
			-- function: "now" is the true capture time, not a proxy.
			base_hash_captured_ts = os.time(),
			base_state = stat and "file" or "absent",
			base_mode = stat and stat.mode or nil,
			status = "pending",
			_retrace_reintegration = true,
		}
	end
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
	-- `walk_schedule`, not `vim.schedule`: this reopen is the walk's own
	-- work and must run while the walk still holds the rewind guard.
	walk_schedule(function()
		local active = inline.active_state and inline.active_state(opts)
		local ok, result
		if active and inline._park_and_open_state then
			ok, result = pcall(inline._park_and_open_state, active, "next", {
				change = change,
				opts = opts,
				owner = nil,
				-- Rulings 74/77: the file being parked here is being stepped
				-- away from by an UNDO, not by navigation -- it keeps its
				-- pending hunks painted so the operator can see both sides of
				-- the walk (row 112).
				retrace_repaint = true,
			})
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
--- ONE REGISTER (ruling 75). A review that pops one of its own decisions on
--- `u` pushes it here, onto the same LIFO the cross-file walk uses, so
--- `<C-r>` replays steps in the reverse of the order they were undone no
--- matter which file each came from. Keyed by the root set the review's
--- workspace resolves to -- the same key `M.undo` pushes under.
function M.push_review_redo(entry)
	if type(entry) ~= "table" or type(entry.workspace) ~= "string" then
		return
	end
	local roots = resolve_roots(entry.workspace)
	local stack = redo_stack(roots_key(roots))
	stack[#stack + 1] = entry
end

--- The OPEN review for (workspace, rel), with its decision primitives
--- (`state._ops`, set by `inline_diff.M.open`). nil when no review is open on
--- that file -- a redo that needs one refuses by name rather than guessing.
local function open_review_ops(ws, rel)
	local ok, inline = pcall(require, "yana.inline_diff")
	if not ok or type(inline.active_state) ~= "function" then
		return nil
	end
	local state = inline.active_state({ workspace = ws })
	if type(state) ~= "table" or type(state.change) ~= "table" then
		return nil
	end
	local srel = state.change.rel or state.change.path
	if srel ~= rel or type(state._ops) ~= "table" then
		return nil
	end
	return state
end

--- Re-apply a hunk decision (`hunk_accepted` / `hunk_rejected`) to the open
--- review on `rel` through the review's own key path. Returns true, or false
--- plus a reason.
--- The step's target file's review is PARKED behind the active one (a
--- 4-file walk leaves the last-reverted file active; the redo stack's top
--- may name another). Bring that file's review forward exactly as the walk
--- does on the way back (`reintegrate`'s takeover: park the active review,
--- open the target's), then return its `state._ops`, or nil.
--- Measured: "cannot redo charlie.py -- no open review" x12 on every 4-file
--- scenario (adversarial ledger, codex-3 f01-f05).
local function bring_review_forward(entry)
	local ok_inline, inline = pcall(require, "yana.inline_diff")
	if not (ok_inline and type(inline._find_change_for_rel) == "function") then
		return nil
	end
	-- SAME OPTS `reintegrate()` uses (shadow_apply + on_shadow_accept), never
	-- a bare `{ workspace = ... }` -- a review brought forward with
	-- incomplete opts closes straight into finish_session's "legacy in-place
	-- accept path is removed" refusal the moment its last hunk is redone,
	-- which then reports success anyway (measured: "refused to accept
	-- bravo.py -- legacy direct-write path is removed" immediately followed
	-- by "redid hunk_accepted in bravo.py").
	local opts = retrace_review_opts(entry.workspace)
	local change = inline._find_change_for_rel(entry.rel, opts)
	if type(change) ~= "table" then
		return nil
	end
	local active = inline.active_state and inline.active_state(opts) or nil
	local ok_p, res
	if active ~= nil and active.change ~= change and type(inline._park_and_open_state) == "function" then
		-- Something else is the active review: PARK it (never discard it --
		-- the same primitive `]x`/`[x` navigation and `reintegrate()`'s own
		-- takeover use) and bring this file's review forward in its place.
		ok_p, res = pcall(inline._park_and_open_state, active, "next", {
			change = change,
			opts = opts,
			owner = nil,
			retrace_repaint = true,
		})
	end
	if not (ok_p and res == true) and type(inline.review) == "function" then
		-- Nothing is active (every review closed or parked), the target IS
		-- already the active review, or the park-and-open attempt itself
		-- failed -- `inline.review` is the same fallback `reintegrate()`
		-- falls back to, and it resumes a change's own `_parked_review` when
		-- it has one rather than starting over.
		ok_p, res = pcall(inline.review, change, opts)
	end
	if ok_p then
		return open_review_ops(entry.workspace, entry.rel)
	end
	return nil
end

--- PRUNE (Vim's own rule, row r75_new_action_prunes_redo): the buffer must
--- still sit where the undo left it; typing since makes the step
--- unreachable and the caller drops it. Asked of the register itself, not of
--- Neovim's seq (an earlier redo of a later step legitimately moves the
--- buffer): the step is reachable only while the buffer's head row still
--- sits BEFORE it. Typing since the undo appended a `human_edit` row and
--- moved the head onto it -- at or after this row -- so the step is gone,
--- exactly as in Vim's own tree.
local function redo_step_pruned(state, entry)
	local head = timeline.buffer_head(state.bufnr)
	local ok_e, entries = pcall(timeline.entries, entry.workspace, entry.rel)
	if head ~= nil and head.id ~= nil and ok_e and type(entries) == "table" then
		local head_i, entry_i
		for i, e in ipairs(entries) do
			if e.id == head.id then
				head_i = i
			end
			if e.id == entry.id then
				entry_i = i
			end
		end
		if head_i ~= nil and entry_i ~= nil and head_i >= entry_i then
			return true
		end
	end
	-- Typing inside an open review is captured lazily (at its next
	-- decision), so it may not be a row yet: the buffer having drifted off
	-- Yana's own head is the same fact, read live.
	local cur = timeline.observe_buffer(state.bufnr)
	if head ~= nil and cur ~= nil and type(head.undo_seq) == "number"
		and (head.buffer_epoch ~= cur.buffer_epoch or head.undo_seq ~= cur.undo_seq)
	then
		return true
	end
	return false
end

local function redo_hunk_decision(entry)
	local state = open_review_ops(entry.workspace, entry.rel) or bring_review_forward(entry)
	if state == nil then
		return false, "no open review on " .. tostring(entry.rel) .. " to put that decision back into"
	end
	local hunk = tonumber(entry.hunk)
	local idx = nil
	local ok_inline, inline = pcall(require, "yana.inline_diff")
	for i, b in ipairs(state.diff_blocks or {}) do
		local n = b.model_index
		if n == nil and ok_inline and type(inline._hunk_number_for_block) == "function" then
			n = inline._hunk_number_for_block(state.change, b)
		end
		if hunk ~= nil and n == hunk then
			idx = i
			break
		end
	end
	if idx == nil then
		return false, "hunk " .. tostring(hunk) .. " is not pending in " .. tostring(entry.rel)
	end
	if redo_step_pruned(state, entry) then
		return false, "pruned"
	end
	if entry.kind == "hunk_accepted" then
		state._ops.accept_block_at(idx, entry.id)
	else
		state._ops.reject_block_at(idx, entry.id)
	end
	return true
end

--- The file-level twin of `redo_hunk_decision` (ruling 75): `entry.kind` is
--- `file_accepted`/`file_rejected`, ONE row covering however many hunks the
--- original `ca`/`cb` decided, so there is no `entry.hunk` to look up and no
--- per-hunk index to find -- the whole file's own `accept_all`/`reject_all`
--- primitive is asked to redo, exactly the way `redo_hunk_decision` asks
--- `accept_block_at`/`reject_block_at`.
local function redo_file_decision(entry)
	local state = open_review_ops(entry.workspace, entry.rel) or bring_review_forward(entry)
	if state == nil then
		return false, "no open review on " .. tostring(entry.rel) .. " to put that decision back into"
	end
	if type(state._ops.accept_all) ~= "function" or type(state._ops.reject_all) ~= "function" then
		return false, "this review has no file-level redo primitive"
	end
	if redo_step_pruned(state, entry) then
		return false, "pruned"
	end
	if entry.kind == "file_accepted" then
		state._ops.accept_all(entry.id)
	else
		state._ops.reject_all(entry.id)
	end
	return true
end

local function undo_impl(workspace, opts)
	opts = opts or {}
	local roots = resolve_roots(workspace)
	local row, rerr, ws = next_undo_across(roots)
	if row == nil then
		if rerr then
			notify.one_line("yana: could not read the cross-file undo history — " .. tostring(rerr), vim.log.levels.WARN)
			lifecycle("undo.retrace_error", { workspace = roots[1], reason = rerr })
			return true
		end
		-- RULING #100 (operator, 2026-08-23). `u` is a key SHARED with Neovim.
		-- An empty cross-file register means yana has NOTHING LEFT TO DO for this
		-- press -- and a press yana does nothing for must look, to the operator,
		-- exactly as it would if yana's keymap were not installed: the buffer
		-- moves under plain Neovim undo and no line is printed. This used to
		-- notify at INFO ("yana: nothing left to undo -- the cross-file history is
		-- empty") on EVERY press from there on, which is once per keystroke for
		-- the rest of the session on a key the operator holds down. The fact is
		-- still recorded, in the one place a fact of this kind belongs.
		--
		-- `false` is unchanged and is what carries the meaning: every dispatcher
		-- below (`on_u_key`, and `inline_diff.lua`'s floor via `try_from_floor`)
		-- reads it as "fall through to plain undo".
		log.write("INFO", "yana.timeline.retrace undo: cross-file register empty for "
			.. tostring(roots[1]) .. " -- press handed to plain Neovim undo")
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
				reintegrated = opts.reintegrate == true,
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
	if row.kind == "human_edit" and type(row.undo_seq) == "number" then
		local cur = timeline.observe_buffer(bufnr)
		if cur and cur.buffer_epoch == row.buffer_epoch and type(cur.undo_seq) == "number" and cur.undo_seq < row.undo_seq then
			notify_drift(bufnr, { undo_seq = row.undo_seq }, cur, "resync")
			return true
		end
		if type(row.prior_buffer_undo_seq) == "number" and row.undo_seq < row.prior_buffer_undo_seq then
			notify_drift(bufnr, { undo_seq = row.prior_buffer_undo_seq }, { undo_seq = row.undo_seq }, "resync")
			return true
		end
	end

	local result = walk.execute(ws, row.rel, row.walk_target, { bufnr = bufnr })
	local committed = result.committed or {}
	local last = committed[#committed]
	if #committed == 0 or result.stopped_at ~= nil then
		refuse(row, result.reason)
		return true
	end

	local rkey = roots_key(roots)
	local function push_member(entry)
		return {
			workspace = ws,
			rel = row.rel,
			id = entry.id,
			kind = entry.kind,
			regime = entry.regime,
			bufnr = bufnr,
			-- The turn-start hunk number, from the row's own label, so a
			-- `hunk_accepted`/`hunk_rejected` step can be re-applied to the
			-- reopened review by hunk rather than by Neovim undo position
			-- (an accept has none -- ruling 87).
			hunk = tonumber(tostring(entry.label or ""):match("hunk (%d+)")),
			-- Carried for a DURABLE entry (`M.entries` already returns
			-- these on every row, never opener-specific) so `M.redo` can
			-- redo an ordinary opened file's composed write the SAME way
			-- `redo_never_opened_row` already redoes one that never had a
			-- buffer -- see that function's own generality and `M.redo`'s
			-- comment at its call site.
			diary_dir = entry.diary_dir,
			op_id = entry.op_id,
			-- True when this undo reintegrated an open review. Redo must then
			-- go through redo_hunk_decision / redo_file_decision. Engine-only
			-- undos (P113) leave this false and redo via native `:redo`.
			reintegrated = opts.reintegrate == true,
		}
	end
	-- RULING 75: a file-level `ca`/`cb` decision is now ALWAYS exactly one
	-- row (`file_accepted`/`file_rejected`), so `committed` never holds more
	-- than one actionable entry for it and no grouping is needed here --
	-- every entry this walk committed is pushed back individually, exactly
	-- like any other kind of row.
	for _, entry in ipairs(committed) do
		redo_stack(rkey)[#redo_stack(rkey) + 1] = push_member(entry)
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
		range = buffer_range(bufnr),
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
		-- WHAT THIS PRESS JUST UNDID, by row id, per hunk. The reopen needs it
		-- because a byte-neutral row (an accept -- ruling 87) leaves the
		-- buffer's undo position unchanged, so `timeline.entries`' head-derived
		-- state still reads that row as `done` for the rest of this press and
		-- the reopen would compose a review with nothing pending in it.
		local reverted_ids = nil
		for _, entry in ipairs(committed) do
			if entry.kind == "hunk_accepted" or entry.kind == "hunk_rejected" then
				local n = tonumber(tostring(entry.label or ""):match("hunk (%d+)"))
				if n then
					reverted_ids = reverted_ids or {}
					reverted_ids[n] = entry.id
				end
			elseif (entry.kind == "file_accepted" or entry.kind == "file_rejected") and type(entry.members) == "table" then
				-- RULING 75: a file-level row's byte-less half (accept moves no
				-- bytes) needs the SAME override every hunk-level accept needs --
				-- every hunk it covers, not just one.
				reverted_ids = reverted_ids or {}
				for _, m in ipairs(entry.members) do
					local n = tonumber(m.hunk)
					if n then
						reverted_ids[n] = entry.id
					end
				end
			end
		end
		if buf_now ~= nil then
			reintegrate(ws, row.rel, disk, buf_now, reverted_ids)
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
--- REINTEGRATED ROWS (2026-08-23, operator clips 12-41-06 / 12-43-32): a
--- `hunk_accepted`/`hunk_rejected` row `M.undo` reintegrated is put back
--- THROUGH the reopened review's own accept/reject path (`redo_hunk_decision`
--- -> `state._ops`, with `redo_of = row id` so the register reuses the row
--- instead of minting a second one). A review's own popped decision
--- (`regime = "review"`, pushed by `pop_decision`) replays via the closure it
--- carried. Both sit on ONE LIFO with the walk's rows, so order is reverse
--- undo order across files (ruling 75).
--- The turn a redo-memory entry's row belongs to, read from the row's own
--- durable stamp rather than from the in-memory entry: the memory predates
--- the stamp and carrying a copy on it would be a second, drift-prone
--- authority for the same fact.
local function entry_turn_id(entry)
	if entry == nil or entry.workspace == nil or entry.rel == nil or entry.id == nil then
		return nil
	end
	local ok, rows = pcall(timeline.entries, entry.workspace, entry.rel)
	if not ok or type(rows) ~= "table" then
		return nil
	end
	for _, e in ipairs(rows) do
		if e.id == entry.id then
			return e.turn_id
		end
	end
	return nil
end

local function redo_impl(workspace)
	local roots = resolve_roots(workspace)
	local stack = redo_stack(roots_key(roots))
	-- OPERATOR RULING #99, the `<C-r>` half: "`<C-r>` likewise never redoes
	-- into an older turn". The redo memory is per root-SET and is never
	-- cleared between turns, so a `u` taken in turn 1 leaves an entry that a
	-- `<C-r>` pressed in turn 2 would otherwise replay. The stack is LIFO and
	-- the turn boundary is monotonic, so an older-turn entry on top means
	-- every entry under it is older too: there is nothing for this press.
	-- The entries STAY on the stack (nothing is destroyed here, the same
	-- posture as the journal rows the undo gate refuses to walk).
	local top = stack[#stack]
	if top ~= nil then
		local gate = current_turn_across(roots)
		local top_turn = entry_turn_id(top)
		if gate == nil or gate.turn_id == nil or top_turn == nil or top_turn ~= gate.turn_id then
			notify.one_line("yana: nothing left to redo in the cross-file history", vim.log.levels.INFO)
			return false
		end
	end
	local entry = table.remove(stack)
	if entry == nil then
		-- RULING #100, the redo mirror of `M.undo`'s empty register above:
		-- `<C-r>` is Neovim's key too, and a press this module does nothing
		-- for must be indistinguishable from one it never saw. `false` still
		-- tells `on_redo_key` to fall through to plain `:redo`.
		log.write("INFO", "yana.timeline.retrace redo: cross-file redo stack empty -- press handed to plain Neovim redo")
		return false
	end
	-- RULING 75: a file-level `ca`/`cb` decision is now ALWAYS one row, so it
	-- reaches the ordinary `entry.kind == "file_accepted"/"file_rejected"`
	-- dispatch below like any other single entry -- no compound-entry replay
	-- is needed here any more.
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
	-- A decision THIS session's open review popped itself (`pop_decision`
	-- pushed it, ruling 75's one register). The review re-adopts its own
	-- decision object, bytes and bookkeeping together; "pruned" means the
	-- operator typed since the undo, so the step is unreachable (Vim's own
	-- rule) and is dropped, and the press falls through to plain redo.
	if entry.regime == "review" then
		local ok_r, reason = false, "no redo closure"
		if type(entry.redo) == "function" then
			ok_r, reason = entry.redo(entry)
		end
		if ok_r then
			local said = "yana: redid " .. (entry.kind or "the last undone step") .. " in " .. entry.rel
			log.write("WARN", said)
			notify.one_line(said, vim.log.levels.INFO)
			lifecycle("redo.retrace", { workspace = entry.workspace, rel = entry.rel, id = entry.id, row_kind = entry.kind })
			return true
		end
		if reason == "pruned" then
			log.write("INFO", "yana.timeline.retrace redo: dropped pruned step " .. tostring(entry.id) .. " in " .. entry.rel)
			return false
		end
		stack[#stack + 1] = entry
		local msg = "yana: cannot redo " .. entry.rel .. " -- " .. tostring(reason)
		log.write("WARN", msg)
		notify.one_line(msg, vim.log.levels.WARN)
		lifecycle("redo.retrace_refused", { workspace = entry.workspace, rel = entry.rel, id = entry.id, reason = reason })
		return true
	end
	local bufnr, berr = ensure_buffer(entry.workspace, entry.rel, nil)
	if not bufnr then
		local msg = "yana: cannot redo " .. entry.rel .. " -- " .. tostring(berr)
		log.write("WARN", msg)
		notify.one_line(msg, vim.log.levels.WARN)
		return true
	end
	-- A hunk decision the cross-file walk reverted and reintegrated as a
	-- pending hunk: put it back THROUGH THE REVIEW (its own accept/reject
	-- path -- bytes, decision row and paint together), never a bare
	-- `:redo`, which moves no bytes for an accept and records nothing for
	-- a reject. This is the path the "NAMED LIMIT (reintegration)" above
	-- left unbuilt -- measured as "redid hunk_accepted" announced with the
	-- hunk still pending (operator clip 2026-08-23 12-41-06).
	--
	-- Engine walk undos (P113) push with reintegrated=false: skip the review
	-- path and fall through to native `:redo` + mark_reverted below.
	if entry.reintegrated
		and (entry.kind == "hunk_accepted" or entry.kind == "hunk_rejected" or entry.kind == "file_accepted" or entry.kind == "file_rejected")
	then
		local redoer = (entry.kind == "file_accepted" or entry.kind == "file_rejected") and redo_file_decision or redo_hunk_decision
		local ok_h, reason = redoer(entry)
		-- UNREACHABLE, not just PRUNED: "no open review ... to put that
		-- decision back into" means `open_review_ops`/`bring_review_forward`
		-- found nothing to reintegrate this decision into at all -- no
		-- review is open or reopenable for this file, so there is no pending
		-- UI state left to desync. That is the SAME shape as "pruned": the
		-- operator has moved past this step by some other route (here: two
		-- more bare `u` presses that retrace's own row-walk had nothing left
		-- to claim, so `on_u_key` fell through to plain `:undo` -- see
		-- `M.undo`'s own fallthrough just above -- walked past the
		-- reintegrated review before it was ever shown). Treating ONLY
		-- "pruned" as droppable and everything else as a hard,
		-- stack-preserving refusal left this entry stuck on top of the redo
		-- stack forever: every `<C-r>` re-popped the SAME entry, failed the
		-- SAME way, and pushed it right back -- so a plain `:redo` that would
		-- have walked the buffer's own intact undo tree forward (recovering
		-- the operator's own typed line, two blocks past this one) was never
		-- reached. Drop it and return false -- callers (redo_key / on_redo_key)
		-- fall through to native `:redo` and MUST repaint (r75 paint rows).
		local unreachable = reason == "pruned"
			or (type(reason) == "string" and reason:match("^no open review") ~= nil)
		if not ok_h and unreachable then
			log.write("INFO", "yana.timeline.retrace redo: dropped unreachable step "
				.. tostring(entry.id) .. " in " .. entry.rel .. " (" .. tostring(reason) .. ")")
			return false
		end
		if not ok_h then
			stack[#stack + 1] = entry
			local msg = "yana: cannot redo " .. entry.rel .. " -- " .. tostring(reason)
			log.write("WARN", msg)
			notify.one_line(msg, vim.log.levels.WARN)
			lifecycle("redo.retrace_refused", { workspace = entry.workspace, rel = entry.rel, id = entry.id, reason = reason })
			return true
		end
		local said = "yana: redid " .. entry.kind .. " in " .. entry.rel
		log.write("WARN", said)
		notify.one_line(said, vim.log.levels.INFO)
		lifecycle("redo.retrace", { workspace = entry.workspace, rel = entry.rel, id = entry.id, row_kind = entry.kind })
		return true
	end
	local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
		vim.cmd("silent redo")
	end)
	if not ok then
		log.write("WARN", "yana.timeline.retrace redo: " .. tostring(err))
	end
	local ok_record, record = pcall(require, "yana.timeline.record")
	if ok_record and type(record.mark_reverted) == "function" then
		record.mark_reverted(entry.id, false)
	end
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

--- The cross-file `u` walk. One press, one transaction: see
--- `yana_own_transaction` above for why the token and not a suppression
--- window.
function M.undo(workspace, opts)
	return yana_own_transaction(function()
		return undo_impl(workspace, opts)
	end)
end

--- The cross-file `<C-r>` walk, under the same token as `M.undo`.
function M.redo(workspace)
	return yana_own_transaction(function()
		return redo_impl(workspace)
	end)
end

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
		if head ~= nil
			and cur ~= nil
			and type(head.undo_seq) == "number"
			and type(cur.undo_seq) == "number"
			and head.buffer_epoch == cur.buffer_epoch
			and cur.undo_seq < head.undo_seq
		then
			notify_drift(bufnr, head, cur, "undo")
			return
		end
		local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
			vim.cmd("silent undo")
		end)
		if not ok then
			log.write("WARN", "yana.timeline.retrace native undo: " .. tostring(err))
		end
		absorb_own_move(bufnr)
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
		absorb_own_move(bufnr)
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
		absorb_own_move(bufnr)
		reconcile_withdrawn_after_native_redo(bufnr)
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
		absorb_own_move(bufnr)
	end
	reconcile_withdrawn_after_native_redo(bufnr)
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

--- RULING #100's other half, asked for by `inline_diff.lua`'s floor when a
--- retrace-reopened review is closed by a press walking below it. Everything
--- on this module's redo stack for these roots names a decision INSIDE
--- reviews the walk itself reopened; the operator has just walked out below
--- the last of them, so there is nothing left for `<C-r>` to re-take and the
--- key goes back to meaning what it means everywhere else. Without this the
--- next `<C-r>` would replay a decision into a review that no longer exists,
--- which is the mirror of the defect the floor press itself was.
---
--- Roots-scoped, not global: another root's walk is a different history and
--- is untouched.
function M.forget_walk_redo()
	local roots = timeline.known_workspaces()
	if #roots == 0 then
		roots = { vim.fn.getcwd() }
	end
	redo_stacks[roots_key(roots)] = nil
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
