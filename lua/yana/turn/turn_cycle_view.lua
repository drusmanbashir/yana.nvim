-- Size split of turn_cycle.lua: what the cycle owner reads from the world (plan followup-addendum-turn.md
-- "### Reconciliation" steps 1-3, "### M0" B5/B7 and the S1 record schema; PANEL.md F-ADDENDUM-B0,
-- -DECISIONS, -HISTORY-RUNNING). One canonical file identity; the CycleInput captured at submit; a file's
-- current rows from their owners (live buffer, else its review's retained text); the stopped run's effective
-- private view; ledger facts through the ledger's own exports; the register path between two endpoints.
local diff = require("yana.diff")
local geometry = require("yana.hunk_extent_geometry")
local settle_snapshot = require("yana.turn.turn_settle_snapshot")
local uv = vim.uv or vim.loop

local V = {}
local SCHEMA = 1

local function loaded(bufnr)
	return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end
V.loaded = loaded

-- Bytes as rows of a file with `eol`: a final terminator is no row, "\r" belongs to a dos terminator, a BOM to
-- the encoding.
function V.rows_of(bytes, eol)
	if eol and eol.bomb and bytes:sub(1, 3) == "\239\187\191" then bytes = bytes:sub(4) end
	local lines = require("yana.review_line_space").buffer_lines(bytes)
	if eol and eol.fileformat == "dos" then
		for i, l in ipairs(lines) do lines[i] = (l:gsub("\r$", "")) end
	end
	return lines
end

-- One identity per file: the resolved absolute path (an unsaved new path keeps its absolute spelling).
function V.canonical_path(path)
	local abs = diff.abs_path(path)
	return uv.fs_realpath(abs) or abs
end

-- The key the register knows the file by: a member's rows carry its `rel`; any other file takes its path
-- relative to the workspace, the `rel` it would carry once promoted, else its canonical path.
local function register_key(entry, canonical, workspace)
	if entry.file and entry.file.change and entry.file.change.rel then return entry.file.change.rel end
	if type(workspace) == "string" then
		local ws = V.canonical_path(workspace)
		if canonical:sub(1, #ws + 1) == ws .. "/" then return canonical:sub(#ws + 2) end
	end
	return canonical
end

-- Ledger facts, through the ledger's exports -------------------------

-- Per member, in membership order: identity, lineage and split genealogy from the ledger's own endpoint export
-- (`capture_ledger_endpoint` frames: the frozen copy of each member's fields), rows from
-- `turn_settle_snapshot.hunks_of` (the one resolver of a recorded extent), ownership per row from
-- `Ledger:row_is_owned`. nil when the ledger is gone or closed.
function V.facts(ledger, lines)
	if ledger == nil or not ledger:is_open() then return nil end
	local ep = ledger:capture_ledger_endpoint()
	local hunks = settle_snapshot.hunks_of({ ledger = ledger }, lines)
	local out = {}
	for i, block in ipairs(ep.members) do
		local frame, h = ep.frames[block] or {}, hunks[i]
		local fields = frame.fields or {}
		out[i] = { block = block, lineage = frame.lineage_id, parent = fields.split_parent_lineage_id,
			initial = fields.initial_new_count, verdict = h.verdict, span = h.span, old = h.old_lines or {},
			owned = function(row) return ledger:row_is_owned(block, row) end }
	end
	return out
end

-- The owned runs of each pending member (`hunk_extent_geometry.runs_in`, prior text by its `allocate`): an
-- operator row inside a member's span stays the operator's on both sides. {a, b, old, origin, block}, a..b
-- half-open in `lines` rows. nil, reason when a pending member has no resolved row.
function V.pending_runs(facts)
	local out = {}
	for _, f in ipairs(facts or {}) do
		if f.verdict == "pending" then
			local s = f.span or {}
			if s.unplaced or s.first == nil then
				return nil, "pending hunk " .. tostring(f.lineage) .. " has no resolved row: " .. tostring(s.reason)
			end
			if s.last < s.first then
				out[#out + 1] = { a = s.first, b = s.first, old = f.old, origin = f.lineage, block = f.block }
			else
				local runs = geometry.runs_in({ first = s.first, last = s.last }, f.owned)
				if #runs == 0 then runs = { { first = s.first, last = s.last } } end
				for k, child in ipairs(geometry.allocate(runs, f.old)) do
					out[#out + 1] = { a = runs[k].first, b = runs[k].last + 1, old = child.old_lines, origin = f.lineage,
						block = f.block }
				end
			end
		end
	end
	return out
end

-- `C` over `lines`: each pending run replaced by its allocated prior text (turn_projection compose_from_buffer).
function V.comparison(lines, runs)
	local hunks = {}
	for i, r in ipairs(runs) do
		hunks[i] = { id = i, verdict = "pending", old_lines = r.old, span = { first = r.a, last = r.b - 1 } }
	end
	return require("yana.turn.turn_projection").compose_from_buffer({ lines = lines, endofline = false }, hunks)
end

-- An input contribution's verdict now, per surviving piece in input rows: the same member's verdict, else its
-- split children's (recorded genealogy), which partition the member's input rows in order when their initial
-- row counts add up to it; anything else is `unresolved` (kept pending). The second value lists the current
-- members those pieces account for, by identity.
function V.resolve_contributions(contributions, facts)
	local by_block, children = {}, {}
	for _, f in ipairs(facts or {}) do
		by_block[f.block] = f
		if f.parent ~= nil then
			children[f.parent] = children[f.parent] or {}
			table.insert(children[f.parent], f)
		end
	end
	local out, accounted = {}, {}
	for _, c in ipairs(contributions) do
		local f = by_block[c.block]
		local kids = children[c.lineage] or {}
		local total = 0
		for _, k in ipairs(kids) do total = total + (k.initial or 0) end
		if f then
			accounted[f.block] = true
			out[#out + 1] = { first = c.first, last = c.last, old = c.old, verdict_now = f.verdict }
		elseif #kids > 0 and c.whole and total == c.whole.last - c.whole.first + 1 then
			local first = c.whole.first
			for _, k in ipairs(kids) do
				accounted[k.block] = true
				local last = first + k.initial - 1
				if last >= c.first and first <= c.last then
					out[#out + 1] = { first = math.max(first, c.first), last = math.min(last, c.last), old = k.old,
						verdict_now = k.verdict }
				end
				first = last + 1
			end
		else
			out[#out + 1] = { first = c.first, last = c.last, old = c.old, unresolved = c.lineage }
		end
	end
	return out, accounted
end

-- Rejections the genealogy cannot place: current rejected members that are neither submit members nor
-- accounted for by a resolved contribution (a nested split's grandchild, a merge of input hunks).
function V.unplaced_rejections(facts, accounted, submit_members)
	local out = {}
	for _, f in ipairs(facts or {}) do
		if f.verdict == "rejected" and not accounted[f.block] and not submit_members[f.block] then
			out[#out + 1] = tostring(f.lineage)
		end
	end
	return out
end

-- A file's current rows, from their owners ---------------------------

-- The live buffer's rows (live = true), else the retained text of the file's review: the bytes captured when
-- its buffer unloaded, or its park snapshot (live = false). nil when no owner retains the view.
function V.current_rows(cur, eol)
	if cur and loaded(cur.bufnr) then return vim.api.nvim_buf_get_lines(cur.bufnr, 0, -1, false), true end
	local st = cur and cur.review_state
	local change = cur and cur.file and cur.file.change
	local parked = type(change) == "table" and change._parked_review or nil
	local text = (st and st.reload_unload_text) or (parked and parked.staged_text)
	if type(text) == "string" then return V.rows_of(text, eol), false end
	return nil
end

-- What the agent reads for an unopened member: its selected review view (retained text), else the proposal
-- the review was built from. Existence and mode come from the change; nil bytes are never an empty base.
function V.unattached(entry)
	local f = entry.file
	local change = f and f.change or {}
	local rows, _ = V.current_rows({ review_state = f and f.review_state, file = f }, nil)
	if change.kind == "delete" then return { existence = false, bytes = "" } end
	if rows then return { existence = true, bytes = table.concat(rows, "\n") .. (#rows > 0 and "\n" or ""),
		mode = change.after_mode or change.base_mode } end
	if type(change.after) == "string" then
		return { existence = true, bytes = change.after, mode = change.after_mode or change.base_mode }
	end
	return nil, "no selected view for unopened member " .. tostring(f and f.path)
end

-- CycleInput ----------------------------------------------------------

-- The capture entries: Turn members, plus other open named file buffers ({path, bufnr}) the agent reads as
-- input only, deduplicated by canonical path (a member wins; a buffer for it lends its bufnr). Buffer over disk:
-- a loaded buffer is what the agent reads.
function V.input_files(turn, buffers)
	local out, at = {}, {}
	for _, f in ipairs((turn and turn.files) or {}) do
		local key = V.canonical_path(f.path)
		local e = { path = key, ledger = f.ledger, file = f, member = true, review_state = f.review_state,
			bufnr = f.bufnr or (f.review_state and f.review_state.bufnr) }
		if at[key] == nil then
			at[key] = e
			out[#out + 1] = e
		end
	end
	for _, b in ipairs(buffers or {}) do
		local key = V.canonical_path(b.path)
		local e = at[key]
		if e == nil then
			e = { path = key, bufnr = b.bufnr, input_only = true }
			at[key] = e
			out[#out + 1] = e
		elseif not loaded(e.bufnr) then
			e.bufnr = b.bufnr
		end
	end
	return out
end

local function eol_of(bufnr)
	return { fileformat = vim.bo[bufnr].fileformat, endofline = vim.bo[bufnr].endofline, bomb = vim.bo[bufnr].bomb }
end

-- Contributions: the submit endpoint's pending owned runs in input rows, each with its member (identity),
-- lineage, allocated prior text (copied) and the member's whole input span (for split resolution).
local function contributions_of(facts)
	local runs = V.pending_runs(facts) or {}
	local whole = {}
	for _, f in ipairs(facts or {}) do
		local s = f.span or {}
		if s.first ~= nil and not s.unplaced then whole[f.block] = { first = s.first, last = s.last } end
	end
	local out = {}
	for _, r in ipairs(runs) do
		out[#out + 1] = { block = r.block, lineage = r.origin, first = r.a, last = r.b - 1, old = vim.deepcopy(r.old),
			whole = whole[r.block] }
	end
	return out
end

-- The endpoint state of a file with no loaded buffer: the ledger's own endpoint export (members, frames,
-- origins, prior rejections, split allocations, history) with the selected view's bytes, existence and mode.
function V.unattached_state(entry, rec)
	local ledger = entry.ledger
	if ledger ~= nil and not ledger:is_open() then return nil end
	local state = ledger and ledger:capture_ledger_endpoint() or { members = {} }
	local change = entry.file and entry.file.change or {}
	state.schema_version, state.bytes_ref, state.existence, state.mode = SCHEMA, rec.bytes_ref, rec.existence, rec.mode
	state.proposal_view = { before = change.before, after = change.after, after_mode = change.after_mode, kind = change.kind }
	state.attachment_state = { unattached = true }
	return state
end

-- Every check that can refuse runs before the submit extmarks are placed, so a refused capture leaves none.
local function capture_file(entry, ns, env)
	local rec = { file = entry.file, member = entry.member == true, input_only = entry.input_only == true }
	if not loaded(entry.bufnr) then
		local view, why = V.unattached(entry)
		if not view then return nil, why end
		rec.bytes_ref, rec.existence, rec.mode = view.bytes, view.existence, view.mode
		rec.lines = V.rows_of(view.bytes, nil)
		rec.native = { unattached = true }
		rec.state = V.unattached_state(entry, rec)
		if rec.state == nil then return nil, "the ledger of " .. tostring(entry.path) .. " is closed" end
	else
		local bufnr = entry.bufnr
		rec.bufnr, rec.lines, rec.eol = bufnr, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), eol_of(bufnr)
		rec.bytes_ref, rec.existence = diff.buffer_bytes_snapshot(bufnr), true
		rec.mode = entry.file and entry.file.change and (entry.file.change.after_mode or entry.file.change.base_mode)
		-- S1b's endpoint state for a review file; a plain buffer's endpoint holds its bytes.
		if entry.review_state then
			rec.state = require("yana.review_park_snapshot").capture_endpoint(entry.review_state, { file = entry.file })
		end
		rec.state = rec.state or { schema_version = SCHEMA, bytes_ref = rec.bytes_ref, existence = true, eol = rec.eol,
			mode = rec.mode, members = {} }
		-- NativePos: the native sequence from its owners -- the review's ledger history, else the caller's reader.
		local seq = rec.state.ledger_history and rec.state.ledger_history.seq
		if seq == nil and env.seq_of then seq = env.seq_of(bufnr) end
		if seq == nil then return nil, "no native sequence for " .. tostring(entry.path) end
		rec.native = { bufnr = bufnr, seq = seq, tick = vim.api.nvim_buf_get_changedtick(bufnr), bytes_ref = rec.bytes_ref }
	end
	local facts = V.facts(entry.ledger, rec.lines)
	if entry.ledger ~= nil and facts == nil then return nil, "the ledger of " .. tostring(entry.path) .. " is closed" end
	rec.contributions = contributions_of(facts)
	rec.submit_members = {}
	for _, f in ipairs(facts or {}) do rec.submit_members[f.block] = true end
	rec.decision_revision = settle_snapshot.decision_stamp(entry.file or entry)
	return rec
end

-- The submit extmarks: one per input row, Neovim's own tracking (consumed rows invalidate; undo restores).
local function mark_rows(rec, ns)
	if not rec.bufnr then return end
	rec.marks = {}
	for row = 1, #rec.lines do
		rec.marks[row] = vim.api.nvim_buf_set_extmark(rec.bufnr, ns, row - 1, 0, { invalidate = true })
	end
end

local QUALIFIERS = { "buf_inc", "hist_inc", "root_gen" }

-- The register owner's qualified native identity kept, the capture's validating fields added.
local function qualified(owned, captured)
	local out = {}
	for k, v in pairs(captured) do out[k] = v end
	for _, k in ipairs(QUALIFIERS) do
		if owned and owned[k] ~= nil then out[k] = owned[k] end
	end
	return out
end

-- The submit position of one file: its current register position (never re-rooted: another live Turn may hold
-- it), its unsealed revision filled with the captured state through the register's seal; a file with no position
-- is admitted with that state. Returns the EpRef and the splice watermark (recorded splices at submit).
local function position_of(register, key, rec, turn_id)
	local at = register:position()[key]
	if at == nil then
		return register:admit(key, { turn_id = turn_id, native = rec.native, state = rec.state }), 0
	end
	local ep, state = register:endpoint(at)
	local seq = ep and ep.native and ep.native.seq
	if seq ~= nil and rec.native.seq ~= nil and seq ~= rec.native.seq then
		return nil, string.format("the register stands at native %s but %s is at %s: flush before submit",
			tostring(seq), tostring(key), tostring(rec.native.seq))
	end
	rec.native = qualified(ep and ep.native, rec.native)
	-- Only this Turn's own endpoint is sealed: an unsealed revision is filled, and a sealed one whose bytes moved
	-- at the same native sequence (`:undojoin`) gets a new immutable revision. Another Turn's is pinned as it is.
	local moved = state ~= nil and state.bytes_ref ~= rec.state.bytes_ref
	if ep and ep.turn_id == turn_id and (state == nil or moved) then at = register:seal(at.ep_id, rec.state, rec.native) end
	local event = ep and register:event(ep.via)
	local part = event and event.parts[key]
	return at, part and part.splices and #part.splices or 0
end

local next_input = 0

-- CycleInput (S1 schema) at submit, step 1. env = {turn_id, workspace_id, workspace?, cycle_id, pass, register?,
-- seq_of?, files = V.input_files(...), private_view?, operation_snapshot?}. Per canonical path: the bytes the
-- agent reads (a member without a buffer: its selected review view), eol/existence/mode, the pending
-- contributions in input rows, the decision revision, the NativePos and the submit extmarks; the submit EpRef
-- (with its state sealed) pinned under `pin_holder`, and the splice watermark. nil, reason when evidence is
-- missing. Nothing writes it afterwards.
function V.capture_input(env)
	next_input = next_input + 1
	local input_id = string.format("input:%s:%s:%d", tostring(env.turn_id), tostring(env.cycle_id), next_input)
	local input = { schema_version = SCHEMA, workspace_id = env.workspace_id, turn_id = env.turn_id,
		input_id = input_id, cycle_id = env.cycle_id, run_generation = env.pass and env.pass.generation,
		view_id = input_id, positions = {}, splice_watermark = {}, decision_revision = {}, files = {},
		private_view = env.private_view, operation_snapshot = env.operation_snapshot,
		ns = vim.api.nvim_create_namespace("yana_cycle_" .. input_id) }
	for _, entry in ipairs(env.files or {}) do
		local path = V.canonical_path(entry.path)
		local rec, why = capture_file(entry, input.ns, env)
		if not rec then
			V.release_input(input, nil)
			return nil, why
		end
		mark_rows(rec, input.ns)
		rec.file_id, rec.key = path, register_key(entry, path, env.workspace)
		input.files[path] = rec
		input.decision_revision[path] = rec.decision_revision
		if env.register then
			local at, watermark = position_of(env.register, rec.key, rec, env.turn_id)
			if at == nil then
				V.release_input(input, nil)
				return nil, watermark
			end
			input.positions[path] = at
			input.splice_watermark[path] = { tick = rec.native.tick, splices = watermark }
		end
	end
	if env.register then
		local pins = {}
		for path, at in pairs(input.positions) do pins[input.files[path].key] = at end
		input.pin_holder = input_id
		env.register:pin(input.pin_holder, pins)
	end
	return input
end

-- Drop the submit extmarks, the input pin and the run's retention pins (`held`). Writes nothing into `input`.
function V.release_input(input, register, held)
	for _, rec in pairs(input.files) do
		if loaded(rec.bufnr) then pcall(vim.api.nvim_buf_clear_namespace, rec.bufnr, input.ns, 0, -1) end
	end
	if register and input.pin_holder then register:unpin(input.pin_holder) end
	for holder in pairs(held or {}) do
		if register then register:unpin(holder) end
		held[holder] = nil
	end
end

-- Where each input row stands now by its submit extmark, or nil when every mark is gone (reload).
function V.marked_rows(rec, ns)
	local rows, kept = {}, 0
	local untouched = vim.api.nvim_buf_get_changedtick(rec.bufnr) == rec.native.tick
	for row, id in ipairs(rec.marks or {}) do
		local at = untouched and { row - 1 } or vim.api.nvim_buf_get_extmark_by_id(rec.bufnr, ns, id, { details = true })
		if at[1] ~= nil and not (at[3] and at[3].invalid) then
			rows[row], kept = at[1] + 1, kept + 1
		else
			rows[row] = false
		end
	end
	if kept == 0 and #rows > 0 then return nil end
	return rows
end

----------------------------------------------------------------------
-- B5: the directed register path from submit to now
----------------------------------------------------------------------

local function chain(register, at)
	local out, ep = {}, at and register:endpoint(at)
	while ep do
		out[#out + 1] = ep
		ep = ep.parent and register:endpoint(ep.parent) or nil
	end
	return out
end

-- The edge into endpoint `ep` for file `key`: its event part, if the edge is one a byte map can cross.
local function edge(register, ep, key)
	local event = register:event(ep.via)
	local part = event and event.parts[key]
	if not (part and part.after.ep_id == ep.ep_id) then return nil, "endpoint " .. tostring(ep.ep_id) .. " has no edge" end
	if event.halted then return nil, "event " .. tostring(event.event_id) .. " halted" end
	if not (event.kind == "buffer_edit" or event.kind == "decision") then
		return nil, "a " .. tostring(event.kind) .. " event is on the path (publications map by lineage: S5)"
	end
	if not (ep.kind == "arrival" or ep.kind == "decision") then return nil, "a " .. ep.kind .. " endpoint is on the path" end
	return part
end

-- Does `ep` stand in the native history incarnation of `from`? Each qualifier present on either side must match.
local function same_incarnation(from, ep)
	local a, b = from and from.native or {}, ep.native or {}
	for _, k in ipairs(QUALIFIERS) do
		if (a[k] ~= nil or b[k] ~= nil) and a[k] ~= b[k] then return false end
	end
	return true
end

-- {kind, steps?, suffix?, reason?}: "same" (one EpRef), "revision" (a later revision: its suffix splices),
-- "forward" (only forward edit/decision edges: the live submit extmarks hold), "composed" (back to the deepest
-- common endpoint and down again: recorded splices, inverted going back) or "unknown" (reset, reload, a
-- publication or an edge with no recorded splices).
function V.history_path(register, key, from, to, watermark)
	if register == nil or from == nil or to == nil then return { kind = "unknown", reason = "no register position" } end
	if from.ep_id == to.ep_id then
		if from.revision == to.revision then return { kind = "same" } end
		local ep = register:endpoint(to)
		local part = ep and edge(register, ep, key)
		local list = part and part.splices
		if list == nil then return { kind = "revision" } end
		local suffix = {}
		for k = (watermark or 0) + 1, #list do suffix[#suffix + 1] = list[k] end
		return { kind = "revision", steps = { { splices = suffix, back = false } } }
	end
	local down, up = chain(register, to), chain(register, from)
	local on_up = {}
	for i, ep in ipairs(up) do on_up[ep.ep_id] = i end
	local meet
	for i, ep in ipairs(down) do
		if on_up[ep.ep_id] then meet = i; break end
	end
	if meet == nil then return { kind = "unknown", reason = "the submit and current positions share no endpoint" } end
	-- Both endpoints of every traversed edge, the common ancestor included, stand in the submit's incarnation.
	local nodes = { down[meet] }
	for i = 1, meet - 1 do nodes[#nodes + 1] = down[i] end
	for i = 1, on_up[down[meet].ep_id] - 1 do nodes[#nodes + 1] = up[i] end
	for _, ep in ipairs(nodes) do
		if not same_incarnation(up[1], ep) then return { kind = "unknown", reason = "the native history incarnation changed" } end
	end
	local steps, forward = {}, on_up[down[meet].ep_id] == 1
	for i = 1, on_up[down[meet].ep_id] - 1 do
		local part, why = edge(register, up[i], key)
		if not part then return { kind = "unknown", reason = why } end
		if part.splices == nil then return { kind = "unknown", reason = "an edge records no splices" } end
		steps[#steps + 1] = { splices = part.splices, back = true }
	end
	for i = meet - 1, 1, -1 do
		local part, why = edge(register, down[i], key)
		if not part then return { kind = "unknown", reason = why } end
		if part.splices == nil and not forward then return { kind = "unknown", reason = "an edge records no splices" } end
		steps[#steps + 1] = { splices = part.splices or {}, back = false }
	end
	return { kind = forward and "forward" or "composed", steps = steps }
end

-- B7 retention during a run: pin every endpoint that is current for an input file, one holder per EpRef seen
-- (a pin keeps the endpoint's ancestry), recorded in `held` (the run's own table).
function V.pin_current(register, input, held)
	local now = register:position()
	for _, rec in pairs(input.files) do
		local at = now[rec.key]
		local holder = at and string.format("%s:seen:%d:%d", input.input_id, at.ep_id, at.revision)
		if holder and not held[holder] then
			register:pin(holder, { [rec.key] = at })
			held[holder] = true
		end
	end
end

return V
