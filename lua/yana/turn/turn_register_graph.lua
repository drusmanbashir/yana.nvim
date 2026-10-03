-- Size split of turn_register.lua: the review-event graph (plan
-- followup-addendum-turn.md "### M0: history mapping", S1 record schema;
-- F-ADDENDUM-UNDO, -EDIT-HISTORY, -UNDO-FLOOR). Per file, Endpoints form a tree
-- whose edges are Events; `cur` (file_id -> EpRef) is the history position, with
-- no global cursor. Events truncated off the register's reach or retired by a
-- reset stay here. Native projection, adoption, crossing and per-file redo
-- selection are M2.
local M = {}

local SCHEMA = 1

-- Graph = {events, clock, step, last_push_step, cur, endpoints, arrival, root_ep,
-- views}; `next_ep` mints endpoint ids, `of_row` maps a pushed row to its event.
function M.new()
	return { events = {}, clock = 0, step = 0, last_push_step = 0, cur = {}, endpoints = {},
		arrival = {}, root_ep = {}, views = {}, next_ep = 0, of_row = {} }
end

-- Graph records. EpRef = {ep_id, revision}: a revision's EndpointState is written
-- once; a re-seal makes a new revision (`Register:seal`).
local function ref(ep)
	return { ep_id = ep.ep_id, revision = ep.revision }
end

local EVENT_KIND = { buffer_edit = "buffer_edit", decision = "decision", accept_turn_step = "decision",
	file_touch = "operation", followup_cycle = "publication" }

-- The one writer of an endpoint's native identity and its arrival slot. An old
-- slot is cleared only while it still names this endpoint; `journal` (a batch
-- checkpoint) records what a new slot overwrote so a rollback can restore it.
local function set_native(g, ep, native, journal)
	local old = ep.native
	local slots = g.arrival[ep.file_id]
	local hist = old and old.seq and slots and slots[old.hist_inc or 0]
	if ep.kind == "arrival" and hist and hist[old.seq] == ep.ep_id then hist[old.seq] = nil end
	ep.native = native
	if ep.kind ~= "arrival" or not (native and native.seq) then return end
	g.arrival[ep.file_id] = slots or {}
	local h = native.hist_inc or 0
	g.arrival[ep.file_id][h] = g.arrival[ep.file_id][h] or {}
	hist = g.arrival[ep.file_id][h]
	if journal then journal[#journal + 1] = { ep.file_id, h, native.seq, hist[native.seq] } end
	hist[native.seq] = ep.ep_id
end

local function new_endpoint(g, owner, file_id, kind, fields, journal)
	g.next_ep = g.next_ep + 1
	local ep = { schema_version = SCHEMA, workspace_id = owner.workspace, turn_id = owner.turn_id,
		ep_id = g.next_ep, file_id = file_id, parent = fields.parent, via = fields.via, kind = kind,
		revision = 1, states = { fields.state }, reachable = true, pins = {} }
	g.endpoints[ep.ep_id] = ep
	set_native(g, ep, fields.native, journal)
	return ep
end

local function floor_id(turn_id)
	return "floor:" .. tostring(turn_id)
end

-- The Turn a file's current position belongs to, and whether it has one.
local function owner_of(g, file_id)
	local at = g.cur[file_id]
	local ep = at and g.endpoints[at.ep_id]
	return ep and ep.turn_id, ep ~= nil
end

-- A file's position for `owner.turn_id`: its current endpoint when that Turn
-- holds it, else a fresh root pinned as the Turn's floor (F-ADDENDUM-UNDO-FLOOR),
-- made current and root.
local function admitted(g, file_id, owner, native, state)
	local turn, held = owner_of(g, file_id)
	if held and turn == owner.turn_id then return g.cur[file_id] end
	local root = new_endpoint(g, owner, file_id, "root", { native = native, state = state })
	local id = floor_id(owner.turn_id)
	g.views[id] = g.views[id] or { view_id = id, positions = {} }
	g.views[id].positions[file_id] = ref(root)
	root.pins[id] = root.revision
	g.root_ep[file_id] = root.ep_id
	g.cur[file_id] = ref(root)
	return g.cur[file_id]
end

-- A part's native edge, derived from its endpoints when no owner supplied one.
local function derive_edge(g, part)
	local before, after = g.endpoints[part.before.ep_id], g.endpoints[part.after.ep_id]
	local native = after and after.kind == "arrival" and after.native
	if not (native and native.seq) then return nil end
	return { hist_inc = native.hist_inc, from_seq = before and before.native and before.native.seq,
		to_seq = native.seq, derived = true }
end

-- One event per pushed row: one part for the row's file (`file_id`, else `rel`),
-- or one per `row.participants` entry ({[file_id] = {native, native_edge, splices,
-- structural, entry, state}}) for a multi-part publication.
function M.add_event(g, row, journal)
	g.clock, g.step = g.clock + 1, g.step + 1
	g.last_push_step = g.step
	local kind = EVENT_KIND[row.kind] or (row.participants and "publication") or "decision"
	local event = { schema_version = SCHEMA, workspace_id = row.workspace, turn_id = row.turn_id,
		event_id = g.clock, clock = g.clock, kind = kind, op = row.kind, cycle_id = row.cycle_id,
		run_generation = row.run_generation, parts = {} }
	local specs = row.participants or { [row.file_id or row.rel] = {} }
	local files = {}
	for file_id in pairs(specs) do files[#files + 1] = file_id end
	table.sort(files, function(a, b) return tostring(a) < tostring(b) end)
	for _, file_id in ipairs(files) do
		local spec = specs[file_id]
		local before = admitted(g, file_id, row)
		local from = g.endpoints[before.ep_id].native
		local native = spec.native
		if native == nil and kind == "decision" then
			native = from
		elseif native == nil and row.undo_seq ~= nil then
			native = { seq = row.undo_seq }
		end
		local ep_kind = (native and native.unattached) and "version"
			or (kind == "decision" and "decision") or "arrival"
		local after = new_endpoint(g, row, file_id, ep_kind,
			{ native = native, parent = before, via = event.event_id, state = spec.state }, journal)
		local part = { before = before, after = ref(after), row = row, entry = spec.entry,
			splices = spec.splices, structural = spec.structural }
		part.native_edge = spec.native_edge or derive_edge(g, part)
		event.parts[file_id] = part
		g.cur[file_id] = part.after
	end
	g.events[event.event_id] = event
	g.of_row[row] = event
	return event
end

local function drop_endpoint(g, id)
	if g.endpoints[id] then set_native(g, g.endpoints[id], nil) end
	g.endpoints[id] = nil
end

local function drop_event(g, id)
	local event = g.events[id]
	g.events[id] = nil
	for _, part in pairs(event and event.parts or {}) do
		if g.of_row[part.row] == event then g.of_row[part.row] = nil end
	end
end

-- Rollback token for a committed batch (its `arrival` is the batch's journal).
-- Recording only mints records, moves `cur`/`root_ep`/view positions and fills
-- arrival slots, so a rollback drops what was minted and restores the rest.
function M.checkpoint(g)
	local mark = { clock = g.clock, step = g.step, last_push_step = g.last_push_step,
		next_ep = g.next_ep, cur = {}, root_ep = {}, views = {}, arrival = {} }
	for k, v in pairs(g.cur) do mark.cur[k] = v end
	for k, v in pairs(g.root_ep) do mark.root_ep[k] = v end
	for id, view in pairs(g.views) do
		mark.views[id] = {}
		for k, v in pairs(view.positions) do mark.views[id][k] = v end
	end
	return mark
end

function M.rollback_to(g, mark)
	for id = mark.next_ep + 1, g.next_ep do drop_endpoint(g, id) end
	for id = mark.clock + 1, g.clock do drop_event(g, id) end
	for i = #mark.arrival, 1, -1 do
		local slot = mark.arrival[i]
		g.arrival[slot[1]][slot[2]][slot[3]] = slot[4]
	end
	for id, view in pairs(g.views) do
		if mark.views[id] then view.positions = mark.views[id] else g.views[id] = nil end
	end
	g.clock, g.step, g.last_push_step, g.next_ep = mark.clock, mark.step, mark.last_push_step, mark.next_ep
	g.cur, g.root_ep = mark.cur, mark.root_ep
end

-- Cross one event in all its parts (B3): back lands on `before` and records the
-- endpoint it left from; forward lands on `left_from`, else `after`. A row the
-- router spends unreplayed (`halted`) records the Halt and crosses nothing: where
-- its bytes landed is unproven.
function M.cross(g, event, outcome, halted)
	g.step = g.step + 1
	if halted ~= nil or event.halted then
		event.halted = event.halted or { event_id = event.event_id, direction = outcome, step = g.step,
			reason = tostring(halted) }
		return
	end
	for file_id, part in pairs(event.parts) do
		local here = g.cur[file_id]
		if outcome == "undone" then
			part.left_from = (here and here.ep_id == part.after.ep_id) and here or nil
			g.cur[file_id] = part.before
		else
			g.cur[file_id] = part.left_from or part.after
		end
	end
	event.undone_at = outcome == "undone" and g.step or nil
end

-- Whether `event` crosses in every part: not halted, each file sits on the part's
-- `side` endpoint, and both its endpoints are still reachable (B7).
local function crossable(g, event, side)
	if event.halted then return false, "event halted: " .. event.halted.reason end
	for file_id, part in pairs(event.parts) do
		local here = g.cur[file_id]
		if not here or here.ep_id ~= part[side].ep_id then
			return false, "history is not at this event in " .. tostring(file_id)
		end
		for _, at in ipairs({ part.before, part.after }) do
			local ep = g.endpoints[at.ep_id]
			if not ep or ep.reachable == false then
				return false, "history no longer reaches " .. tostring(file_id)
			end
		end
	end
	return true
end

local function edge_event(self, row, side, none)
	local event = row and self.graph.of_row[row]
	if not event then return nil, none end
	local ok, why = crossable(self.graph, event, side)
	if not ok then return nil, why end
	return event
end

-- Why a reset of `turn_id` with explicit `roots` would move another Turn's
-- current position, or nil.
function M.reset_conflict(g, turn_id, roots)
	for file_id in pairs(roots or {}) do
		local turn, held = owner_of(g, file_id)
		if held and turn ~= turn_id then
			return "reset root for " .. tostring(file_id) .. " would move turn " .. tostring(turn) .. "'s position"
		end
	end
end

-- Graph-aware reset (plan "### M0" Reset): the turn's events leave Yana's reach
-- but stay as records (`retired_at`; pinned ones survive `drop_unreachable`).
-- Each file of the turn's floor, plus each file in `roots` (the native position
-- the reset load left), gets a reset root endpoint mapped to the floor (`parent`
-- = the floor endpoint, `via` nil); it becomes the file's current, root and floor
-- position. A file another Turn now holds keeps its position and root.
function M.retire(g, turn_id, roots)
	g.step = g.step + 1
	for _, event in pairs(g.events) do
		if event.turn_id == turn_id and event.retired_at == nil then event.retired_at = g.step end
	end
	local id = floor_id(turn_id)
	local floor = g.views[id] or { view_id = id, positions = {} }
	local files = {}
	for file_id in pairs(floor.positions) do files[#files + 1] = file_id end
	for file_id in pairs(roots or {}) do
		if not floor.positions[file_id] then files[#files + 1] = file_id end
	end
	for _, file_id in ipairs(files) do
		local turn, held = owner_of(g, file_id)
		if not held or turn == turn_id then
			g.views[id] = floor
			local mapped = floor.positions[file_id]
			local prior = mapped and g.endpoints[mapped.ep_id]
			local reset = new_endpoint(g, { workspace = prior and prior.workspace_id, turn_id = turn_id },
				file_id, "reset", { native = roots and roots[file_id], parent = mapped })
			reset.pins[id] = reset.revision
			floor.positions[file_id] = ref(reset)
			g.root_ep[file_id] = reset.ep_id
			g.cur[file_id] = floor.positions[file_id]
		end
	end
end

-- Register methods over the graph. `env.move_cursor` is the register's one cursor mover.
function M.install(Register, env)
	-- The newest event Yana `u` would undo, applied in all its parts, or nil and why.
	function Register:head()
		return edge_event(self, self:peek_back(), "after", "nothing to undo")
	end

	-- The oldest undone event Yana `<C-r>` would redo (M1: the truncating branch).
	function Register:next_redo()
		return edge_event(self, self:peek_forward(), "before", "nothing to redo")
	end

	-- Record that `event` was reversed ("undone") or reapplied ("applied") in ALL its
	-- parts, or nothing: it must be `head()` / `next_redo()`.
	function Register:mark(event, outcome)
		assert(outcome == "undone" or outcome == "applied", "turn register mark: undone or applied")
		local want, why
		if outcome == "undone" then want, why = self:head() else want, why = self:next_redo() end
		if want == nil or want ~= event then
			return false, why or ("not the next event to " .. (outcome == "undone" and "undo" or "redo"))
		end
		env.move_cursor(self, outcome)
		return true
	end

	-- Graph reads: the event a row made, an EpRef's endpoint with that revision's
	-- state (nil until sealed), and a copy of the history position (file -> EpRef).
	function Register:event_of(row)
		return self.graph.of_row[row]
	end

	-- The event an endpoint's `via` names (turn/turn_cycle_view.lua walks edges by it).
	function Register:event(event_id)
		return event_id ~= nil and self.graph.events[event_id] or nil
	end

	function Register:endpoint(at)
		local ep = at and self.graph.endpoints[at.ep_id]
		return ep, ep and ep.states[at.revision]
	end

	function Register:position()
		local out = {}
		for file_id, at in pairs(self.graph.cur) do out[file_id] = at end
		return out
	end

	-- Seal a captured EndpointState: the first seal fills the endpoint's revision, a
	-- later one (`:undojoin`, re-install) makes a new revision. A re-sealed current
	-- endpoint moves its file's position to the new revision. A `native` installs
	-- the endpoint's native identity, its arrival slot and its derived edges.
	function Register:seal(ep_id, state, native)
		local g = self.graph
		local ep = assert(g.endpoints[ep_id], "turn register seal: unknown endpoint " .. tostring(ep_id))
		assert(state ~= nil, "turn register seal needs an EndpointState")
		if ep.states[ep.revision] ~= nil then
			ep.revision = ep.revision + 1
			local here = g.cur[ep.file_id]
			if here and here.ep_id == ep_id then g.cur[ep.file_id] = ref(ep) end
		end
		ep.states[ep.revision] = state
		if native ~= nil then
			set_native(g, ep, native)
			for _, event in pairs(g.events) do
				local part = event.parts[ep.file_id]
				if part and (part.native_edge == nil or part.native_edge.derived)
					and (part.after.ep_id == ep_id or part.before.ep_id == ep_id) then
					part.native_edge = derive_edge(g, part)
				end
			end
		end
		return ref(ep)
	end

	-- Admit a file's initial endpoint and this Turn's floor without an event or
	-- any retirement: a root carrying the owners' `native`/`state`, made current,
	-- root and floor. Idempotent: a file the Turn already holds returns its
	-- current EpRef unchanged. The EpRef is what `seal` and `pin` take.
	function Register:admit(file_id, opts)
		assert(file_id ~= nil and type(opts) == "table" and opts.turn_id ~= nil,
			"turn register admit needs a file_id and {turn_id, native, state}")
		return admitted(self.graph, file_id, { turn_id = opts.turn_id, workspace = self.workspace },
			opts.native, opts.state)
	end

	-- Name a position vector (default: the current one) under `holder` -- submit
	-- `input:<cycle>`, unpublished result, recovery -- and pin its endpoints at their
	-- revisions until `unpin(holder)`. Pinned records are never collected (B7).
	function Register:pin(holder, positions)
		self:unpin(holder)
		local view = { view_id = holder, positions = {} }
		for file_id, at in pairs(positions or self.graph.cur) do
			local ep = assert(self.graph.endpoints[at.ep_id], "turn register pin: unknown endpoint")
			ep.pins[holder] = at.revision
			view.positions[file_id] = at
		end
		self.graph.views[holder] = view
		return view
	end

	function Register:unpin(holder)
		self.graph.views[holder] = nil
		for _, ep in pairs(self.graph.endpoints) do ep.pins[holder] = nil end
	end

	-- The native observer (M2) flags what Neovim's history no longer reaches.
	function Register:set_reachable(ep_id, reachable)
		local ep = assert(self.graph.endpoints[ep_id], "turn register: unknown endpoint " .. tostring(ep_id))
		ep.reachable = reachable == true
	end

	-- An ended Turn (End completed or Abort; turn.lua) is never walked again: its unpinned endpoints become
	-- unreachable and the drop below removes what nothing else holds. Pinned records stay (B7).
	function Register:release_turn(turn_id)
		if turn_id == nil then return end
		for id, ep in pairs(self.graph.endpoints) do
			if ep.turn_id == turn_id and next(ep.pins) == nil then self:set_reachable(id, false) end
		end
		self:drop_unreachable()
	end

	-- Drop records natively unreachable and unpinned (B7) and endpoint revisions no
	-- record names. Current endpoints and every event in the `u`/`<C-r>` reach stay.
	-- A pin (each view is one) keeps its endpoint's ancestry -- incoming events,
	-- parents and their revisions up to the root -- so a pinned input can still be
	-- translated after native pruning; `unpin` releases that closure.
	function Register:drop_unreachable()
		local g = self.graph
		local keep, revs, kept, seen = {}, {}, {}, {}
		local function hold(at)
			if at then keep[at.ep_id] = true; revs[at.ep_id .. ":" .. at.revision] = true end
		end
		local function hold_event(event)
			if kept[event] then return end
			kept[event] = true
			for _, part in pairs(event.parts) do hold(part.before); hold(part.after); hold(part.left_from) end
		end
		local function hold_path(at)
			while at and not seen[at.ep_id .. ":" .. at.revision] do
				seen[at.ep_id .. ":" .. at.revision] = true
				hold(at)
				local ep = g.endpoints[at.ep_id]
				if ep and ep.via and g.events[ep.via] then hold_event(g.events[ep.via]) end
				at = ep and ep.parent
			end
		end
		for _, at in pairs(g.cur) do hold(at) end
		for _, view in pairs(g.views) do
			for _, at in pairs(view.positions) do hold_path(at) end
		end
		for id, ep in pairs(g.endpoints) do
			for _, rev in pairs(ep.pins) do hold_path({ ep_id = id, revision = rev }) end
			if ep.reachable ~= false then keep[id] = true end
		end
		for _, row in ipairs(self.actions) do
			if g.of_row[row] then hold_event(g.of_row[row]) end
		end
		for id, event in pairs(g.events) do
			if not kept[event] then
				local whole = true
				for _, part in pairs(event.parts) do
					whole = whole and keep[part.before.ep_id] == true and keep[part.after.ep_id] == true
				end
				if whole then hold_event(event) else drop_event(g, id) end
			end
		end
		for id, ep in pairs(g.endpoints) do
			if not keep[id] then
				drop_endpoint(g, id)
			else
				for rev in pairs(ep.states) do
					if rev ~= ep.revision and not revs[id .. ":" .. rev] then ep.states[rev] = nil end
				end
			end
		end
	end
end

return M
