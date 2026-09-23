-- Turn-owned cross-file undo register. State is memory-only and dies with the
-- Turn that owns this register.
--
-- Nothing here clears the stack on turn end; the boundary is the stamp, not a wipe.
local M = {}

local Register = {}
Register.__index = Register

function M.new()
	return setmetatable({ actions = {}, cursor = 0, owed = {} }, Register)
end

-- The identity an OWED row is held under: one file, one turn. Two turns may
-- own a row for the same `rel` without either flushing the other's.
local function owed_key(action)
	return tostring(action.rel) .. "\0" .. tostring(action.turn_id)
end

-- Per-workspace singletons, so `push`ing from one call site and walking from another
-- reach the SAME stack without either holding a reference to it.
local registers = {}

function M.for_workspace(workspace)
	local key = workspace or "?"
	local reg = registers[key]
	if not reg then
		reg = M.new()
		registers[key] = reg
	end
	return reg
end

-- Colon-callable module convenience: `require("yana.turn.turn_register"):push(action)`
-- routes to the action's OWN workspace's register. `self` is the module
-- table itself (colon syntax), unused beyond that -- the action names its
-- own workspace, which is the only identity this needs.
function M.push(_self, action)
	assert(type(action) == "table" and type(action.rel) == "string",
		"turn register push needs a table with a `rel` field")
	return M.for_workspace(action.workspace):push(action)
end

-- Colon-callable mirror of `M.push` for a row that is OWED rather than
-- pushed. See `Register:owe`.
function M.owe(_self, action)
	assert(type(action) == "table" and type(action.rel) == "string",
		"turn register owe needs a table with a `rel` field")
	return M.for_workspace(action.workspace):owe(action)
end

-- OWE one action: a row that must sit DIRECTLY BENEATH its own file's first
-- row of the turn, and nowhere else. It does not enter the stack here.
--
-- The `file_touch` row is created at PROPOSAL time, and a proposal happens for EVERY
-- file the turn names before ANY decision is taken anywhere. Pushed there, it lands at
-- the BOTTOM of a register that is per-WORKSPACE and turn-global -- underneath every
-- other file's decisions, not underneath its own file's hunk rows. The newest-first
-- walk then reached the touch row only after the WHOLE turn was exhausted, so the
-- removal press never came, and the press that should have removed the file walked a
--
-- Owing it instead makes the row's position true to its own comment: the
-- first row this file pushes flushes it first, so every one of that file's
-- rows sits ABOVE it and the walk reaches it exactly when the file's own
-- rows run out. A file that pushes NO row all turn never flushes it -- there
-- is nothing to walk back for that file, and the turn-end reverse
-- is what removes it there.
function Register:owe(action)
	assert(type(action) == "table", "turn register action must be a table")
	self.owed = self.owed or {}
	self.owed[owed_key(action)] = action
	return action
end

-- Add one action at the current head. A new action after walk_back starts a
-- new branch, so stale redo actions cannot be replayed.
local function push_into(target, action, emitted)
	assert(type(action) == "table", "turn register action must be a table")
	-- Flush this file's owed row FIRST, so it lands beneath the row that
	-- triggered it. Cleared before the recursive push so an owed row can
	-- never flush itself.
	local key = owed_key(action)
	target.owed = target.owed or {}
	local owed = target.owed[key]
	if owed ~= nil and owed ~= action then
		target.owed[key] = nil
		push_into(target, owed, emitted)
	end
	for i = target.cursor + 1, #target.actions do
		target.actions[i] = nil
	end
	target.actions[#target.actions + 1] = action
	target.cursor = #target.actions
	emitted[#emitted + 1] = { action = action, depth = target.cursor }
	return action
end

local function log_pushes(emitted)
	for _, item in ipairs(emitted) do
		local action = item.action
	-- Every door reaches the stack through here -- `cf`, the panel, `cA`, the watcher's
	-- human-edit push -- so one record covers them all, and a door that pushes N rows
	-- where the rule says one is visible without a keypress.
	--
	-- `depth` is the fact a count alone cannot give: three presses to undo one
	-- action means either three rows or a count of one, and those two look
	-- identical from the row itself.
	require("yana.log").lifecycle("register.push", {
		rel = action.rel,
		turn_id = action.turn_id,
		kind = action.kind,
		count = action.count,
		undo_seq = action.undo_seq,
		workspace = action.workspace,
		depth = item.depth,
	})
	end
end

function Register:push(action)
	local emitted = {}
	push_into(self, action, emitted)
	log_pushes(emitted)
	return action
end

-- Prepare an ordered native batch without mutating the live cursor, owed rows,
-- or branch. The same `push_into` owns both paths' insertion rule.
function Register:prepare_push_many(actions)
	local target = { actions = {}, cursor = self.cursor, owed = {} }
	for i, action in ipairs(self.actions) do target.actions[i] = action end
	for key, action in pairs(self.owed or {}) do target.owed[key] = action end
	local emitted = {}
	for _, action in ipairs(actions or {}) do push_into(target, action, emitted) end
	return { before_actions = self.actions, before_cursor = self.cursor,
		before_owed = self.owed, actions = target.actions, cursor = target.cursor,
		owed = target.owed, emitted = emitted }
end

function Register:commit_prepared(plan)
	if self.actions ~= plan.before_actions or self.cursor ~= plan.before_cursor
		or self.owed ~= plan.before_owed then
		return false, "register changed during native batch preparation"
	end
	self.actions, self.cursor, self.owed = plan.actions, plan.cursor, plan.owed
	return true
end

function Register:rollback_prepared(plan)
	if self.actions == plan.actions and self.cursor == plan.cursor and self.owed == plan.owed then
		self.actions, self.cursor, self.owed = plan.before_actions, plan.before_cursor, plan.before_owed
	end
end

function Register:log_prepared(plan)
	log_pushes(plan.emitted or {})
end

-- Non-mutating look at the newest not-yet-walked action, or nil. Callers
-- decide (by `turn_id`, `rel`, `kind`) whether to act on it before spending
-- the real `walk_back()` -- a refused/foreign-turn action must stand exactly
-- where it is, not get consumed on a look.
function Register:peek_back()
	if self.cursor == 0 then
		return nil
	end
	return self.actions[self.cursor]
end

-- Return each action once, newest first, then leave the cursor at the oldest
-- edge. The action object is returned unchanged for the owning Turn to apply.
function Register:walk_back()
	if self.cursor == 0 then
		return nil
	end
	local action = self.actions[self.cursor]
	self.cursor = self.cursor - 1
	return action
end

-- Non-mutating look at the newest not-yet-redone action, or nil. Mirrors
-- `peek_back` for the forward direction -- `<C-r>`'s walk needs to resolve
-- WHICH file (and whether it is a foreign-turn/exhausted row) a press would
-- land on before spending the real `walk_forward()`, same reason `undo_key`
-- needs `peek_back` rather than consuming `walk_back()` speculatively.
function Register:peek_forward()
	if self.cursor == #self.actions then
		return nil
	end
	return self.actions[self.cursor + 1]
end

-- Redo in the inverse order of walk_back, stopping at the newest action.
function Register:walk_forward()
	if self.cursor == #self.actions then
		return nil
	end
	self.cursor = self.cursor + 1
	return self.actions[self.cursor]
end

-- Callers never mutate it.
function Register:entries()
	return self.actions
end

function Register:clear()
	self.actions = {}
	self.cursor = 0
	self.owed = {}
end

-- `U` hard-resets one live Turn. Remove both walked and redo-side rows for
-- that Turn while preserving older/future Turn rows and the cursor relation.
function Register:discard_turn(turn_id)
	local kept = {}
	local cursor = 0
	for i, action in ipairs(self.actions) do
		if action.turn_id ~= turn_id then
			kept[#kept + 1] = action
			if i <= self.cursor then
				cursor = cursor + 1
			end
		end
	end
	self.actions = kept
	self.cursor = cursor
	for key, action in pairs(self.owed or {}) do
		if action.turn_id == turn_id then
			self.owed[key] = nil
		end
	end
end

return M
