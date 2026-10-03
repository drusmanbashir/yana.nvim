-- One follow-up publication as one register row (plan followup-addendum-turn.md "### Publication and history" and
-- "### Reuse and object rules" register-row contract; panel rules F-ADDENDUM-PUBLISH, -RECOMPUTE, -UNDO,
-- -REDO). `M.commit_publication` installs a turn_cycle PreparedPublication across its files in one step (no await)
-- and pushes ONE `followup_cycle` row whose participants carry each file's native before/after position and its
-- before/after EndpointState (review_park_snapshot.capture_endpoint). Per file it composes the doors `U` uses for a
-- retained version: Yana's own splice (review_watch.own_splice), `Ledger:load_snapshot`, the model mirror's
-- in-place restore. A failed file compensates every file already moved, through the ledger's guarded member
-- publication (`publish_prepared_members`, as review_watch_timeline_prepare's commit does) and a native undo.
-- `reverse`/`forward` (change 2) move every participant to its recorded endpoint: native moves, then S1b's endpoint
-- install and S4's version restore, all files or none.
local diff = require("yana.diff")

local M = {}
local FollowupCycleAction = {}
FollowupCycleAction.__index = FollowupCycleAction

-- Register row (UndoAction): `rel` names the row's first file; `participants` = {[file_id] = {native,
-- native_edge, state, structural}} makes the register record one multi-part publication event.
function M.new(fields)
	assert(type(fields) == "table" and type(fields.rel) == "string", "followup_cycle row needs a `rel`")
	assert(type(fields.participants) == "table", "followup_cycle row needs its participants")
	local row = {}
	for k, v in pairs(fields) do row[k] = v end
	row.kind = "followup_cycle"
	return setmetatable(row, FollowupCycleAction)
end

----------------------------------------------------------------------
-- reverse / forward (F-ADDENDUM-UNDO, -REDO; plan "### Publication and history", M0 B4)
----------------------------------------------------------------------

local function outcome(self, ok, changed, reason, where, paths)
	return { ok = ok, changed = changed, reason = reason, byte_location = where,
		affected_paths = paths or self.affected_paths }
end

-- An initiated native move of `bufnr` to `seq` (an undo-tree jump; text is never pasted), with the watcher's
-- interpretation muted; the ledger side is installed from the endpoint right after.
local function jump(bufnr, seq)
	require("yana.review_watch").own_splice(bufnr, function()
		vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent undo " .. seq) end)
	end)
	local now = M.seq_of(bufnr)
	if now ~= seq then error(string.format("native history landed on %s, not %s", tostring(now), tostring(seq)), 0) end
end

-- Each participant's live review and the side it leaves (`from`) and lands on (`to`): {native, state, version}.
-- Refuses before anything moves unless every file sits exactly on `from` (native seq and bytes).
local function preflight(self, env, undoing)
	local parts = {}
	for key, p in pairs(self.participants) do
		local b = self.before and self.before[key]
		local from, to = b, p
		if undoing then from, to = p, b end
		local name = tostring(p.path or key)
		if p.joined then
			-- A file the publication added: its membership and attached or queued review leave on undo and return on redo,
			-- through this action's native endpoint and the panel's join/leave doors, with the other participants.
			local file = env.file_of and env.file_of(p.path) or nil
			local doors = self.doors
			if not (doors and doors.join and doors.leave and p.change) then
				return nil, name .. ": the publication recorded no join door for it"
			end
			if undoing and not file then return nil, name .. ": it is no longer a member of the review" end
			local state = file and file.review_state
			if undoing and p.native.bufnr and not (state and state.bufnr == p.native.bufnr
				and vim.api.nvim_buf_is_loaded(state.bufnr)) then
				return nil, name .. ": its attached review is missing"
			end
			if undoing and state and (state.closed or not state.bufnr
				or M.seq_of(state.bufnr) ~= p.native.seq
				or diff.buffer_bytes_snapshot(state.bufnr) ~= p.native.bytes_ref) then
				return nil, name .. ": its history is not at this follow-up"
			end
			if not undoing and file then return nil, name .. ": it is already a member of the review" end
			parts[#parts + 1] = { key = key, name = name, joined = true, path = p.path, change = p.change, record = p,
				file = file, state = state, doors = doors, leaving = undoing }
		elseif not (from and to and from.native and to.native and type(to.native.seq) == "number" and to.state) then
			return nil, name .. ": the publication recorded no endpoint to restore"
		else
			local file = env.file_of and env.file_of(p.path) or nil
			local state = file and file.review_state
			local bufnr = state and state.bufnr
			if not (state and state.hunk_ledger and state.hunk_ledger:is_open() and not state.closed
				and bufnr and vim.api.nvim_buf_is_loaded(bufnr)) then
				return nil, name .. ": its review is not open"
			end
			if bufnr ~= from.native.bufnr then return nil, name .. ": its review buffer changed" end
			if state.watch_timeline then return nil, name .. ": an edit session is still open" end
			if M.seq_of(bufnr) ~= from.native.seq or diff.buffer_bytes_snapshot(bufnr) ~= from.native.bytes_ref then
				return nil, name .. ": its history is not at this follow-up"
			end
			parts[#parts + 1] = { key = key, name = name, file = file, state = state, bufnr = bufnr, from = from, to = to,
				pair = state._anchor_pair or {} }
		end
	end
	table.sort(parts, function(x, y) return tostring(x.key) < tostring(y.key) end)
	return parts
end

-- S1b's endpoint door: ledger history, members, frames, decision stacks, model (with the review's anchor pair).
local function install(part, side)
	return require("yana.review_park_snapshot").install_endpoint(part.state, side.state, { seq = side.native.seq,
		current_seq = function() return M.seq_of(part.bufnr) end, park_anchor = part.pair.park,
		drop_anchor = part.pair.drop, file = part.file })
end

-- A joined file's native history returns to its captured pre-staging endpoint
-- before the panel withdraws its membership. This also serves failed commit rollback.
local function restore_joined_native(state, before, expected_attached)
	if expected_attached and not (before and state and state.bufnr
		and vim.api.nvim_buf_is_loaded(state.bufnr)) then
		error("joined file's attached history is unavailable for restoration", 0)
	end
	if not (before and state and state.bufnr and vim.api.nvim_buf_is_loaded(state.bufnr)) then return end
	jump(state.bufnr, before.seq)
	if diff.buffer_bytes_snapshot(state.bufnr) ~= before.bytes_ref then
		error("joined file did not return to its pre-publication bytes", 0)
	end
	vim.bo[state.bufnr].modified = before.modified
end

-- A joined file's membership: `leave` withdraws its Turn membership, queued review and panel record; `join`
-- re-admits the same change through the first-run door (an attached or queued review with no decisions).
local function membership(part, leave)
	if leave then
		if part.file and part.file.review_state ~= part.state then
			error("joined review changed before withdrawal", 0)
		end
		restore_joined_native(part.state, part.record.before_native, part.record.native.bufnr ~= nil)
		if part.doors.leave(part.path, part.change) ~= true then error("its membership could not be withdrawn", 0) end
		return
	end
	local got = part.doors.join(part.path, { change = part.change })
	if not (got and got.file) then error("it did not rejoin the review", 0) end
	local state = got.file.review_state
	part.file = got.file
	part.state = state -- Compensation must restore this exact rejoined attachment.
	if state and state.bufnr then
		part.record.native = { bufnr = state.bufnr, seq = M.seq_of(state.bufnr),
			bytes_ref = diff.buffer_bytes_snapshot(state.bufnr) }
	end
end

-- One file onto `to`: S4's File version door, the native move, then the endpoint install.
local function apply_part(part)
	if part.joined then
		part.moved = true
		return membership(part, part.leaving)
	end
	if part.file and part.to.version then part.token = assert(part.file:restore_version(part.to.version)) end
	part.moved = true
	jump(part.bufnr, part.to.native.seq)
	local out = install(part, part.to)
	if out.ok ~= true then error(out.reason or out.code, 0) end
	part.state.latest_undo_seq = part.to.native.seq
end

-- The inverse of a (partial) `apply_part`; true when the file is verifiably back on `from`.
local function back(part)
	if part.joined then return not part.moved or (pcall(membership, part, not part.leaving)) end
	local ok = true
	if part.moved then
		ok = pcall(jump, part.bufnr, part.from.native.seq) and install(part, part.from).ok == true
		part.state.latest_undo_seq = part.from.native.seq
	end
	if part.token then ok = part.file:restore_version(part.token) ~= nil and ok end
	return ok and diff.buffer_bytes_snapshot(part.bufnr) == part.from.native.bytes_ref
end

local paint

-- All participants or none: a failed file compensates every file moved so far to its start; a compensation that
-- cannot land halts (changed = true, the paths named) for the router's halt protocol and `recovery_required`.
local function move(self, env, undoing)
	local parts, why = preflight(self, env or {}, undoing)
	if not parts then
		pcall(require("yana.turn.turn_cycle_log").door_refused, "undo_across")
		return outcome(self, false, false, why, "pre_call")
	end
	local done = {}
	for _, part in ipairs(parts) do
		done[#done + 1] = part
		local ok, err = pcall(apply_part, part)
		if not ok then
			local stuck = {}
			for i = #done, 1, -1 do
				local okb, good = pcall(back, done[i])
				if not (okb and good) then stuck[#stuck + 1] = done[i].name end
				paint(done[i].state)
			end
			local reason = part.name .. ": " .. tostring(err)
			if #stuck > 0 then
				return outcome(self, false, true, reason .. "; could not put back " .. table.concat(stuck, ", "),
					"unknown", stuck)
			end
			return outcome(self, false, false, reason, "pre_call")
		end
	end
	for _, part in ipairs(parts) do paint(part.state) end
	return outcome(self, true, true, nil, "moved")
end

-- env = {file_of(path) -> the Turn's File}: the router hands the owners; the row never walks or navigates.
function FollowupCycleAction:reverse(env) return move(self, env, true) end
function FollowupCycleAction:forward(env) return move(self, env, false) end

----------------------------------------------------------------------
-- commit
----------------------------------------------------------------------

-- The buffer's current native sequence (`changenr()`, no undotree read); the cycle input's `seq_of` too.
function M.seq_of(bufnr)
	return vim.api.nvim_buf_call(bufnr, function() return vim.fn.changenr() end)
end

-- Native position of `bufnr` now (NativePos subset).
local function native_of(bufnr)
	return { bufnr = bufnr, seq = M.seq_of(bufnr), tick = vim.api.nvim_buf_get_changedtick(bufnr),
		bytes_ref = diff.buffer_bytes_snapshot(bufnr) }
end

-- The joined file's pre-staging endpoint belongs to this action, not to its
-- mutable panel change. An unloaded file starts at the native floor.
local function before_join(path, change)
	local bufnr = vim.fn.bufnr(path, false)
	local loaded = bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr)
	return { seq = loaded and M.seq_of(bufnr) or 0,
		bytes_ref = loaded and diff.buffer_bytes_snapshot(bufnr) or change.before or "",
		modified = loaded and vim.bo[bufnr].modified or false }
end

-- Close the open undo group so the publication is its own native sequence (the `undolevels` idiom
-- review_geometry's break_undo_block uses; that helper lives inside the inline-review facade).
local function seal_group(bufnr)
	vim.api.nvim_buf_call(bufnr, function() vim.cmd("let &undolevels = &undolevels") end)
end

-- Replace current rows [a, b) with `lines` (a == b: insert before row a). Region writes keep every extmark
-- outside the region where it is.
local function replace_rows(bufnr, a, b, lines)
	local n = vim.api.nvim_buf_line_count(bufnr)
	local function len(row) return #(vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or "") end
	if b > a and #lines > 0 then
		vim.api.nvim_buf_set_text(bufnr, a - 1, 0, b - 2, len(b - 1), lines)
	elseif b > a then
		if b <= n then
			vim.api.nvim_buf_set_text(bufnr, a - 1, 0, b - 1, 0, {})
		elseif a > 1 then
			vim.api.nvim_buf_set_text(bufnr, a - 2, len(a - 1), n - 1, len(n), {})
		else
			vim.api.nvim_buf_set_text(bufnr, 0, 0, n - 1, len(n), { "" })
		end
	elseif #lines > 0 then
		if a <= n then
			local text = vim.list_extend(vim.list_slice(lines), { "" })
			vim.api.nvim_buf_set_text(bufnr, a - 1, 0, a - 1, 0, text)
		else
			vim.api.nvim_buf_set_text(bufnr, n - 1, len(n), n - 1, len(n), vim.list_extend({ "" }, lines))
		end
	end
end

local function rows_of(s, lines)
	if s.first then return s.first, s.last - s.first + 1, vim.list_slice(lines or {}, s.first, s.last) end
	return s.anchor, 0, {}
end

-- The text of one prepared file: tracked files move by their typed segments (current rows -> result rows,
-- bottom up); a FALLBACK file's base is not the buffer, so its rows are replaced whole.
local function write_text(bufnr, f)
	if f.mode == "tracked" and f.lineage and f.lineage.segments then
		local segs = f.lineage.segments
		for i = #segs, 1, -1 do
			local a, n = rows_of(segs[i].src)
			local _, _, want = rows_of(segs[i].dst, f.lines)
			local have = vim.api.nvim_buf_get_lines(bufnr, a - 1, a - 1 + n, false)
			if not vim.deep_equal(have, want) then replace_rows(bufnr, a, a + n, want) end
		end
	else
		replace_rows(bufnr, 1, vim.api.nvim_buf_line_count(bufnr) + 1, f.lines)
	end
	if not vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), f.lines) then
		error("publication text did not land as prepared for " .. f.path, 0)
	end
end

-- First-run hunk blocks for the ledger: stamped with a fresh identity and a model index each (the model mirror is
-- rebuilt from the same blocks; new hunk ids belong to the new result, history keeps the old ones).
local function blocks_and_model(f)
	local identity, blocks, model = require("yana.hunk_identity"), {}, { n = #f.blocks }
	for i, b in ipairs(f.blocks) do
		local block = vim.tbl_extend("force", {}, b, { verdict = "pending", model_index = i, model_join = "publication" })
		identity.stamp(block)
		blocks[i] = block
		model[i] = { index = i, old_count = #(b.old_lines or {}), new_count = #(b.new_lines or {}),
			new_start_line = b.new_start_line, new_end_line = b.new_end_line }
	end
	return blocks, model
end

-- Everything one file's install changes, to put back on failure.
local function start_of(state)
	local L = state.hunk_ledger
	local fields = {}
	for _, block in ipairs(L:members()) do fields[block] = vim.tbl_extend("force", {}, block) end
	return { members = L:members(), fields = fields, decisions = state.decisions,
		sealed = state.sealed_decisions, undone = state.undone_decisions, staged_text = state.staged_text,
		latest_undo_seq = state.latest_undo_seq,
		model = require("yana.review_hunk_split").snapshot_model(state.model_hunks) }
end

-- `C`, the text the blocks' prior side indexes (blocks taken back over the result rows): the version's `base`,
-- which End composes from when it runs without a buffer.
local function base_bytes(f)
	local rows = f.lines
	for i = #f.blocks, 1, -1 do
		local b, out = f.blocks[i], {}
		vim.list_extend(out, rows, 1, b.new_start_line - 1)
		vim.list_extend(out, b.old_lines or {})
		vim.list_extend(out, rows, b.new_start_line + #(b.new_lines or {}), #rows)
		rows = out
	end
	return #rows > 0 and table.concat(rows, "\n") .. "\n" or ""
end

-- S4's File version door first (turn_file.lua `install_version`, before the members land): the result's
-- proposal, its base, and this cycle's write door; then the text, membership and model.
local function install_file(state, f, rec, file, next)
	if file then
		rec.version = assert(file:install_version(vim.tbl_extend("force", next, { base = base_bytes(f) })))
	end
	local bufnr = state.bufnr
	seal_group(bufnr)
	require("yana.review_watch").own_splice(bufnr, function() write_text(bufnr, f) end)
	seal_group(bufnr)
	rec.wrote = true
	local blocks, model = blocks_and_model(f)
	state.hunk_ledger:load_snapshot(blocks)
	require("yana.review_hunk_split").restore_model_snapshot(state.model_hunks, model)
	state.decisions, state.sealed_decisions, state.undone_decisions = {}, {}, {}
	state.staged_text = diff.buffer_bytes_snapshot(bufnr)
	rec.after = native_of(bufnr)
	-- The ledger's history stands on the publication's own sequence (Yana's splice was not observed), so the
	-- next edit's record departs from it and `u` of that edit lands back here (S1 `ledger_history.seq`).
	state.hunk_ledger:observe_buffer_seq(rec.after.seq)
	state.latest_undo_seq = rec.after.seq
end

local function compensate(state, rec, file)
	local start, bufnr = rec.start, state.bufnr
	if rec.version then assert(file:restore_version(rec.version)) end
	if rec.wrote then
		require("yana.review_watch").own_splice(bufnr, function()
			vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent undo " .. rec.before.seq) end)
		end)
	end
	state.hunk_ledger:publish_prepared_members(start.members, start.fields)
	state.hunk_ledger:observe_buffer_seq(rec.before.seq)
	require("yana.review_hunk_split").restore_model_snapshot(state.model_hunks, start.model)
	state.decisions, state.sealed_decisions, state.undone_decisions = start.decisions, start.sealed, start.undone
	state.staged_text, state.latest_undo_seq = start.staged_text, start.latest_undo_seq
	return diff.buffer_bytes_snapshot(bufnr) == rec.before.bytes_ref
end

-- One endpoint state, captured with the owning File so operation, verdict and mode decision are kept; the
-- proposal fields come from the File's selected version (S4), which `state.change` may lag.
local function capture_with_file(state, file)
	local ep = require("yana.review_park_snapshot").capture_endpoint(state, { file = file })
	local v = ep and file and file:version()
	if v and v.proposal then
		ep.proposal_view.kind, ep.proposal_view.after = v.proposal.kind, v.proposal.after
		ep.proposal_view.after_mode, ep.operation_view.mode = v.proposal.after_mode, v.proposal.after_mode
	end
	return ep
end

-- The review state of a file that just joined: its live review's endpoint when its buffer is open, else the
-- unattached endpoint (turn_cycle_view: the ledger's export with the selected view's bytes and existence).
local function joined_state(j)
	local st = j.file.review_state
	if st and st.bufnr and vim.api.nvim_buf_is_loaded(st.bufnr) then
		j.native, j.state = native_of(st.bufnr), assert(capture_with_file(st, j.file))
		return
	end
	local V = require("yana.turn.turn_cycle_view")
	local entry = { file = j.file, ledger = j.file.ledger }
	local view = assert(V.unattached(entry))
	j.native = { unattached = true }
	j.state = assert(V.unattached_state(entry, { bytes_ref = view.bytes, existence = view.existence, mode = view.mode }))
end

function paint(state)
	pcall(function()
		state.hunk_ledger:request_paint()
		if state._flush_paint then state._flush_paint("followup_publication") end
	end)
end

-- Why `f` can no longer be installed on `state` as prepared, or nil: the owners' evidence in prepared_against
-- (attachment, watcher generation, buffer, bytes, decisions, operation/mode verdicts of the File `file`).
local function stale(state, f, file)
	local at = f.prepared_against or {}
	if not (state and state.hunk_ledger and state.hunk_ledger:is_open() and not state.closed) then
		return "its review is no longer open"
	end
	if at.attachment ~= state or at.watch_generation ~= state._watch_generation then return "its review was replaced" end
	if state.bufnr ~= at.bufnr or not vim.api.nvim_buf_is_loaded(state.bufnr) then return "its buffer changed" end
	if state.watch_timeline then return "an edit session is still open" end
	if require("yana.turn.turn_settle_snapshot").decision_stamp(file or {}) ~= at.stamp
		or (file and (file.operation_verdict ~= at.operation_verdict or file.mode_verdict ~= at.mode_verdict)) then
		return "a decision was made after the result was prepared"
	end
	-- Neovim's write of a modified buffer moves changedtick and nothing else (CORE
	-- "Saving is Neovim's", N51): an unmodified buffer at the prepared undo position
	-- with the prepared bytes was not edited.
	local tick_moved = vim.api.nvim_buf_get_changedtick(state.bufnr) ~= at.tick
		and (vim.bo[state.bufnr].modified or at.seq == nil or M.seq_of(state.bufnr) ~= at.seq)
	if tick_moved or diff.buffer_bytes_snapshot(state.bufnr) ~= at.bytes_ref then
		return "it was edited after the result was prepared"
	end
	return nil
end

-- What the publication still waits for (plan "### Publication and history": a ready result waits until the
-- affected review buffers have left Insert and their native groups and flushes are complete), or nil when ready.
-- `states[path]` = the Turn's live review states. Returns {bufnr} for an Insert session, else {flush = true}.
function M.blocking(states)
	local mode, cur = vim.api.nvim_get_mode().mode:sub(1, 1), vim.api.nvim_get_current_buf()
	for _, state in pairs(states) do
		if state.bufnr == cur and (mode == "i" or mode == "R") then return { bufnr = cur } end
		if state.watch_pending or state.watch_timeline then return { flush = true } end
	end
	return nil
end

-- Install `prepared` (turn_cycle PreparedPublication) on the live review states and push ONE row on
-- `env.register`. env = {register, workspace, turn_id, states, files, results, review_opts(file), join(path, f),
-- was_reviewed(path), leave(path, change, forget_uncommitted_history)}; states (review states), files (Turn Files)
-- and results (turn_cycle result files) are keyed
-- by canonical path. A `first_run` file joins through `join` (-> {file}) inside the action and its state is
-- captured before the row is pushed; `leave` withdraws its membership and attached or queued review.
-- Returns the row (true when every file was left unchanged), or nil and {code = "stale"|"halted", reason,
-- affected_paths}. "stale": nothing moved (prepare again); "halted": a failed
-- install could not be compensated (`recovery_required`).
function M.commit_publication(prepared, env)
	local plan, fresh, files = {}, {}, env.files or {}
	for _, path in ipairs(prepared.order) do
		local f = prepared.files[path]
		if f.mode == "tracked" or f.mode == "fallback" then
			local state = env.states[path]
			local why = stale(state, f, files[path])
			if why then return nil, { code = "stale", reason = path .. ": " .. why } end
			plan[#plan + 1] = { path = path, f = f, state = state }
		elseif f.mode == "first_run" then
			fresh[#fresh + 1] = { path = path, f = f }
		end
	end
	local done, joined, failure = {}, {}, nil
	for _, item in ipairs(plan) do
		local file = files[item.path]
		local rec = { path = item.path, start = start_of(item.state), before = native_of(item.state.bufnr) }
		rec.before_state = capture_with_file(item.state, file)
		done[#done + 1] = rec
		local ok, err = pcall(install_file, item.state, item.f, rec, file, { review_opts = env.review_opts(file),
			change = env.results and env.results[item.path] and env.results[item.path].change })
		if not ok then
			failure = item.path .. ": " .. tostring(err)
			break
		end
		rec.after_state = capture_with_file(item.state, file)
	end
	-- A newly changed file joins the review inside this same action (F-ADDENDUM-RECOMPUTE), after the installs,
	-- and its review state is captured before the row exists: attached (buffer open) or unattached (queued).
	for _, item in ipairs(failure and {} or fresh) do
		local before = before_join(item.path, item.f.change)
		local had_history = env.was_reviewed and env.was_reviewed(item.path) == true
		local ok, got = pcall(env.join, item.path, item.f)
		local j = ok and got and got.file and { path = item.path, f = item.f, file = got.file,
			joined_state = got.file.review_state, before_native = before, had_history = had_history }
		if j then
			joined[#joined + 1] = j
			ok, got = pcall(joined_state, j)
		end
		if not (j and ok) then
			failure = item.path .. ": " .. tostring(ok and "it did not join the review" or got)
			break
		end
	end
	if failure then
		local stuck = {}
		for i = #joined, 1, -1 do
			local j = joined[i]
			local ok, left = pcall(function()
				if j.file.review_state ~= j.joined_state then error("joined review changed before rollback", 0) end
				restore_joined_native(j.joined_state, j.before_native,
					j.joined_state ~= nil and j.joined_state.bufnr ~= nil)
				return env.leave(j.path, j.f.change, not j.had_history)
			end)
			if not (ok and left) then stuck[#stuck + 1] = j.path end
		end
		for i = #done, 1, -1 do
			local ok, back = pcall(compensate, plan[i].state, done[i], files[done[i].path])
			if not (ok and back) then stuck[#stuck + 1] = done[i].path end
			paint(plan[i].state)
		end
		if #stuck > 0 then
			return nil, { code = "halted", reason = failure, affected_paths = stuck }
		end
		return nil, { code = "stale", reason = failure }
	end
	-- Members the cycle left unchanged take the cycle's write door only (no version change).
	for _, path in ipairs(prepared.order) do
		if files[path] and prepared.files[path].mode == "unchanged" then
			files[path]:install_version({ review_opts = env.review_opts(files[path]) })
		end
	end
	local participants, affected, before_states, rels = {}, {}, {}, {}
	for i, rec in ipairs(done) do
		local f, file = plan[i].f, files[rec.path]
		local key = f.key or f.file_id
		participants[key] = { path = rec.path, native = rec.after, exists = f.exists ~= false,
			native_edge = { from_seq = rec.before.seq, to_seq = rec.after.seq }, state = rec.after_state,
			structural = f.lineage and f.lineage.segments, version = file and file:version() }
		before_states[key] = { path = rec.path, native = rec.before, state = rec.before_state, version = rec.version,
			exists = true }
		affected[#affected + 1], rels[#rels + 1] = rec.path, file and file.change and file.change.rel or rec.path
		paint(plan[i].state)
	end
	for _, j in ipairs(joined) do
		local key, before = j.f.change.rel or j.f.key, j.f.change.before
		participants[key] = { path = j.path, change = j.f.change, native = j.native,
			before_native = j.before_native, joined = true, exists = j.state.existence ~= false, state = j.state,
			version = j.file:version() }
		before_states[key] = { native = { unattached = true }, exists = before ~= nil, member = false,
			state = { schema_version = 1, members = {}, existence = before ~= nil, bytes_ref = before,
				attachment_state = { unattached = true, member = false } } }
		affected[#affected + 1], rels[#rels + 1] = j.path, key
	end
	if #affected == 0 then return true end
	local row = M.new({ rel = rels[1], workspace = env.workspace, turn_id = env.turn_id, cycle_id = prepared.cycle_id,
		run_generation = prepared.run_generation, input_id = prepared.input_id, result_id = prepared.result_id,
		idem_key = prepared.idem_key, participants = participants, before = before_states, affected_paths = affected,
		commit = "committed", doors = #joined > 0 and { join = env.join, leave = env.leave } or nil })
	env.register:push(row)
	return row
end

return M
