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

-- Colon-callable module convenience: `require("yana.turn_register"):push(action)`
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
function Register:push(action)
	assert(type(action) == "table", "turn register action must be a table")
	-- Flush this file's owed row FIRST, so it lands beneath the row that
	-- triggered it. Cleared before the recursive push so an owed row can
	-- never flush itself.
	local key = owed_key(action)
	self.owed = self.owed or {}
	local owed = self.owed[key]
	if owed ~= nil and owed ~= action then
		self.owed[key] = nil
		self:push(owed)
	end
	for i = self.cursor + 1, #self.actions do
		self.actions[i] = nil
	end
	self.actions[#self.actions + 1] = action
	self.cursor = #self.actions
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
		depth = self.cursor,
	})
	return action
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
