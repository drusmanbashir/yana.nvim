-- Timeline walk — implementation behind the pinned lua/yana/timeline/walk.lua.
-- walk.lua's two stubs delegate here (the integrator wires that); this file is
-- the only file the walk lane owns.
--
-- WHAT A WALK IS. Walking TO row R reverts, NEWEST FIRST, every actionable
-- entry strictly newer than R, one step at a time; R names the state the
-- operator lands in. A walk is NOT ATOMIC and is never reported as one: both
-- underlying revert primitives (`diary.revert_operation`,
-- `checkpoint.revert_turn`) loop and stop at their first conflict, so this
-- module stops at its own first failed step and reports the exact committed
-- prefix, the entry it stopped at, and the reason — never "reverted" for a walk
-- that half-happened.
--
-- NO SECOND AUTHORITY. This module holds integers, ids and records —
-- never bytes. A buffer step is `:undo {seq}` inside `nvim_buf_call`, after the
-- epoch and expected-hash evidence checks; Neovim's own tree restores the text.
-- A durable step goes through the EXISTING journaled revert path,
-- `diary.revert_operation`, and the buffer is brought back in step with disk by
-- the EXISTING `shadow/apply.reconcile_applied_buffer` — no restoration route
-- is added here.
local M = {}

local diary = require("yana.safety.diary")
local apply = require("yana.shadow.apply")
local hash = require("yana.safety.hash")
local uv = vim.uv or vim.loop

--- The display index this walk executes over — the pinned
--- lua/yana/timeline/init.lua interface (`entries`, `reachable`,
--- `review_open_for`). Required lazily so a headless probe can preload a stub
--- while the record lane's implementation is in flight.
local function index()
	return require("yana.timeline")
end

--- Integration seams the record lane owns the other side of.
--- `epoch_of` must answer with the SAME epoch value the record lane stamps
--- when it mints `buffer_epoch` for a row; the default reads the buffer-local
--- variable `yana_timeline_epoch`. A recreated buffer answers nil, and
--- nil REFUSES — "the seq exists" is not evidence (T06).
M._deps = {
	epoch_of = function(bufnr)
		return vim.b[bufnr].yana_timeline_epoch
	end,
}

--- Canonical buffer text for hashing: lines joined by "\n", plus the trailing
--- newline when the buffer carries one — the same shape apply.lua's final
--- verify uses. The record lane MUST compute `expected_hash` over this same
--- canonical form (use these helpers), or every honest walk refuses.
function M.buffer_text(bufnr)
	local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	if vim.bo[bufnr].endofline and vim.bo[bufnr].fixendofline then
		text = text .. "\n"
	end
	return text
end

function M.buffer_hash(bufnr)
	return (hash.hash_bytes(M.buffer_text(bufnr)))
end

local function join(workspace, rel)
	return (tostring(workspace):gsub("/$", "")) .. "/" .. tostring(rel)
end

--- Does this entry demand an action when walked over? Marker rows
--- (`review_opened`, hunk decisions, `review_closed`) moved no restorable
--- state and contribute no step. Rows the authority already reports as
--- `reverted` are already undone, and `refused` rows never happened; neither
--- is stepped again. `pending` rows STAY actionable so `execute` stops at
--- them rather than silently crossing an unresolved record (T08).
local function actionable(entry)
	if entry.state == "reverted" or entry.state == "refused" then
		return false
	end
	if entry.regime == "durable" then
		return entry.op_id ~= nil and entry.diary_dir ~= nil
	end
	if entry.regime == "buffer" then
		return entry.undo_seq ~= nil
	end
	return false
end

--- What a walk WOULD do, without doing it. SIDE-EFFECT FREE: the surface calls
--- this before any confirmation is shown, so nothing here opens a diary,
--- touches a buffer, or writes a record — it reads the index and returns.
--- Returns nil, reason when no walk can even be described (unknown row, or the
--- surface is disabled because a review is open).
--- `blocked` is the ENTRY THAT MUST GO FIRST when per-path LIFO blocks the
--- target (its id is also on `blocked_by`); `unresolved` is the first step
--- whose derived state is not `done`, which `execute` will refuse to cross.
function M.plan(workspace, rel, target_id)
	if not workspace or not rel or not target_id then
		return nil, "plan requires workspace, rel and target_id"
	end
	local tl = index()
	if tl.review_open_for(workspace, rel) then
		return nil,
			tostring(rel)
				.. ": the timeline is disabled while this file's review is open — the review's own keys are the surface until it closes"
	end
	local entries = tl.entries(workspace, rel) or {}
	local previous_buffer
	for _, e in ipairs(entries) do
		if e.regime == "buffer" then
			e._undo_to = previous_buffer
			previous_buffer = e
		end
	end
	local ti
	for i, e in ipairs(entries) do
		if e.id == target_id then
			ti = i
			break
		end
	end
	if not ti then
		return nil, "no timeline entry " .. tostring(target_id) .. " for " .. tostring(rel)
	end

	local plan = {
		steps = {},
		buffer_count = 0,
		durable_count = 0,
		blocked = nil,
		blocked_by = nil,
		target = entries[ti],
		unresolved = nil,
	}
	for i = #entries, ti + 1, -1 do
		local e = entries[i]
		if actionable(e) then
			plan.steps[#plan.steps + 1] = e
			if e.regime == "durable" then
				plan.durable_count = plan.durable_count + 1
			else
				plan.buffer_count = plan.buffer_count + 1
			end
			if e.state ~= "done" and not plan.unresolved then
				plan.unresolved = e
			end
		end
	end

	local ok, blocked_by, blocked_reason = tl.reachable(workspace, rel, target_id)
	if not ok then
		if blocked_by then
			for _, e in ipairs(entries) do
				if e.id == blocked_by then
					plan.blocked = e
					break
				end
			end
			plan.blocked = plan.blocked or { id = blocked_by }
			plan.blocked_by = blocked_by
		else
			plan.blocked_reason = blocked_reason or "the target row is not currently reachable"
		end
	end
	return plan
end

--- One buffer step: `:undo {seq}` inside `nvim_buf_call`, after the evidence
--- checks. Epoch first — a recreated buffer's plausible-looking sequence
--- belongs to a different tree (T06). A row without an expected hash refuses
--- BEFORE the undo: "the seq exists" is not evidence. After the undo the
--- content is hashed against the row's record; on mismatch the buffer is
--- returned to the seq it was at (through the same tree — no bytes held) and
--- the step reports the mismatch (T07).
local function step_buffer(entry, bufnr, rel)
	if not bufnr or bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
		return false,
			tostring(rel)
				.. ": no loaded buffer, so its undo tree cannot answer — refusing; row "
				.. tostring(entry.id)
				.. " stays listed as unreachable"
	end
	local destination = entry._undo_to
	if not destination then
		return false,
			"row " .. tostring(entry.id) .. " has no older buffer row to restore through; refusing"
	end
	if destination.buffer_epoch == nil or destination.expected_hash == nil then
		return false,
			"row "
				.. tostring(destination.id)
				.. " carries incomplete buffer evidence (epoch or expected hash missing) — refusing; a bare sequence number is not evidence"
	end
	local epoch = M._deps.epoch_of(bufnr)
	if epoch ~= destination.buffer_epoch then
		return false,
			tostring(rel)
				.. ": undo-tree epoch mismatch — the buffer's tree is "
				.. tostring(epoch)
				.. ", row "
				.. tostring(destination.id)
				.. " was recorded against "
				.. tostring(destination.buffer_epoch)
				.. " — refusing; a recreated buffer's sequence numbers are not evidence"
	end

	local err
	local okc, callerr = pcall(vim.api.nvim_buf_call, bufnr, function()
		local ut = vim.fn.undotree()
		if type(destination.undo_seq) ~= "number" or destination.undo_seq < 0 or destination.undo_seq > ut.seq_last then
			err = tostring(rel)
				.. ": seq "
				.. tostring(destination.undo_seq)
				.. " is not in this buffer's undo tree (last is "
				.. tostring(ut.seq_last)
				.. ") — refusing; the row stays listed as unreachable"
			return
		end
		local pre_seq = ut.seq_cur
		local oku, uerr = pcall(vim.cmd, string.format("silent undo %d", destination.undo_seq))
		if not oku then
			err = tostring(rel) .. ": `:undo " .. tostring(destination.undo_seq) .. "` failed: " .. tostring(uerr)
			return
		end
		local got = M.buffer_hash(bufnr)
		if got ~= destination.expected_hash then
			-- Return through the same tree; nothing here supplies bytes.
			pcall(vim.cmd, string.format("silent undo %d", pre_seq))
			err = tostring(rel)
				.. ": the content at seq "
				.. tostring(destination.undo_seq)
				.. " is not what row "
				.. tostring(entry.id)
				.. " recorded — history has moved outside the timeline; refusing, and the buffer was returned to seq "
				.. tostring(pre_seq)
			return
		end
	end)
	if not okc then
		return false, tostring(rel) .. ": buffer step failed: " .. tostring(callerr)
	end
	if err then
		return false, err
	end
	local ok_record, record = pcall(require, "yana.timeline.record")
	if ok_record and type(record.sync_buffer_head) == "function" then
		record.sync_buffer_head(bufnr, destination)
	end
	local ok_capture, capture = pcall(require, "yana.timeline.edit_capture")
	if ok_capture and type(capture.sync) == "function" then
		capture.sync(bufnr)
	end
	return true
end

--- One durable step: the EXISTING journaled revert path, nothing else. The
--- diary named by the row is opened (once per walk), `revert_operation` is
--- asked for exactly that op, and the count it answers is asserted — a step is
--- only called committed when the journal says exactly one revert happened.
--- Afterwards the buffer is brought back in step with what the applier
--- restored, through the EXISTING reconcile. A reconcile refusal does not
--- un-happen the disk revert: the step reports committed plus a halt reason,
--- and the walk stops with the buffer left `modified` and the changed-on-disk
--- prompt armed — which is the safe, truthful state.
local function step_durable(entry, sessions, workspace, rel)
	local dir = entry.diary_dir
	local session = sessions[dir]
	if not session then
		local s, err = diary.open(dir)
		if not s then
			return false,
				"row " .. tostring(entry.id) .. ": its diary (" .. tostring(dir) .. ") could not be opened: " .. tostring(err)
		end
		sessions[dir] = s
		session = s
	end
	local ok, err, reverted_n = diary.revert_operation({ session = session, op_id = entry.op_id })
	if not ok then
		local path = join(workspace, rel)
		local stat = uv.fs_stat(path)
		if stat then
			local rok, rerr = apply.reconcile_applied_buffer({ kind = "replace", path = path, stat = stat })
			if not rok then
				err = tostring(err) .. "; buffer reconcile also refused: " .. tostring(rerr)
			end
		end
		return false, err
	end
	if reverted_n ~= 1 then
		return false,
			"row "
				.. tostring(entry.id)
				.. ": the diary reports "
				.. tostring(reverted_n)
				.. " reverted operations where exactly one ("
				.. tostring(entry.op_id)
				.. ") was asked — refusing to call this step committed"
	end
	-- DISK ONLY. A durable row and the buffer are SEPARATE planes in this
	-- timeline -- that separation is the whole reason durable and buffer rows
	-- are distinct kinds -- so reverting the durable write reverts the file and
	-- nothing else. The buffer is moved only by walking back the BUFFER rows
	-- below this one; forcing it here would fuse the two planes and make a
	-- durable step un-isolable, which is exactly what the design keeps apart.
	-- The operator sees where they are from the timeline cursor: the durable
	-- row now reads `reverted`, the accepts below it still stand, and the buffer
	-- reflects those accepts. A transient buffer-newer-than-disk during a walk
	-- is truthful, not a desync -- the two are at different timeline positions
	-- and the operator is the one moving between them. (Earlier this called
	-- reconcile_applied_buffer; the break-test that owns T01 established the
	-- plane separation and this follows it.)
	return true
end

--- Execute a walk. NEWEST-TO-OLDEST, one step at a time, STOP ON FIRST
--- FAILURE. Always returns a result table; `committed` is the exact prefix
--- that happened, in the order it happened, and is truthful even when the walk
--- never starts (empty, with `reason` set). The plan is recomputed here — a
--- plan shown at confirm time is a description, not a licence, and the index,
--- the diary and the buffer are all re-checked at execution time.
--- opts: { bufnr = n } optionally names the buffer for `rel` (otherwise it is
--- resolved from the workspace path).
function M.execute(workspace, rel, target_id, opts)
	opts = opts or {}
	local result = { committed = {}, stopped_at = nil, reason = nil }

	local plan, perr = M.plan(workspace, rel, target_id)
	if not plan then
		result.reason = perr
		return result
	end
	if plan.blocked then
		result.reason = "row "
			.. tostring(target_id)
			.. " cannot be walked to yet: row "
			.. tostring(plan.blocked.id)
			.. " must go first (per-path LIFO for this file)"
		return result
	end
	if plan.blocked_reason then
		result.reason = plan.blocked_reason
		return result
	end

	local sessions = {}
	local bufnr = opts.bufnr
	for _, entry in ipairs(plan.steps) do
		local ok, err, halted
		if entry.state ~= "done" then
			ok, err = false,
				"row "
					.. tostring(entry.id)
					.. " ("
					.. tostring(entry.label or entry.kind)
					.. ") is "
					.. tostring(entry.state)
					.. " — the walk does not cross an unresolved row; the diary, not this surface, must resolve it first"
		elseif entry.regime == "buffer" then
			if bufnr == nil then
				bufnr = vim.fn.bufnr(join(workspace, rel), false)
			end
			ok, err = step_buffer(entry, bufnr, rel)
		else
			ok, err, halted = step_durable(entry, sessions, workspace, rel)
		end
		if ok then
			result.committed[#result.committed + 1] = entry
			if halted then
				-- The disk revert stands; only the presentation could not follow.
				result.halted_after = entry
				result.reason = halted
				return result
			end
		else
			result.stopped_at = entry
			result.reason = err
			return result
		end
	end
	return result
end

return M
