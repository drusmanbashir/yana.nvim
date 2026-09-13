-- One `buffer_edit` register row: ONE Neovim undo sequence in one review
-- buffer, whatever the watcher made of it (absorbed into a hunk, free-standing,
-- or both in one coalesced flush). Neovim owns the bytes; HunkLedger's keyed
-- history owns the per-hunk proposal changes that sequence caused; this class
-- owns the atomic `reverse()` / `forward()` the router calls.
--
-- Laws: refuse BEFORE touching the buffer, never walk the register (the router
-- spends the row only on `ok`), never navigate (the outcome names where the
-- router should land).
--
-- ALL OR NOTHING. `changed` is the promise the router spends a register row on,
-- so `changed = false` means the call left NOTHING behind it: buffer bytes,
-- Neovim's undo sequence, the ledger's proposals/extents/observed sequence, the
-- model mirror, the watcher's suspension and pending changes, the paint and the
-- register cursor all equal what the call found. A move that cannot keep that
-- promise -- because its own rollback could not complete -- reports
-- `changed = true` with a reason naming each part still out of place, rather
-- than a `false` the router would act on.
local hunk_identity = require("yana.hunk_identity")

local M = {}
local BufferEditAction = {}
BufferEditAction.__index = BufferEditAction

--- Redo preflight. A retracted reject always names a hunk the undo RESTORED to
--- pending, so a live equivalent exists in the ledger now. On a slow resume the
--- rebuild swapped that hunk for a fresh table, leaving the entry's `block`
--- pointing at the dead one; re-pushing it unchanged would put a block the
--- ledger does not own into `state.decisions`. Re-point each entry to the live
--- member by stable identity BEFORE any bytes move. On the fast path the ledger
--- already owns the block, so this is a no-op. A zero or AMBIGUOUS match is a
--- refusal, not a guess: return the offending entry so the caller can refuse
--- the whole redo with `changed=false` rather than move bytes it cannot pair
--- with a live verdict.
local function rebind_retracted(self, target)
  local retracted = self.retracted_decisions or {}
  if #retracted == 0 then
    return true
  end
  -- There ARE rejects to re-push, so a live ledger to bind them against is
  -- required, not optional: without one there is no way to prove the re-pushed
  -- block is owned, and success here would be the very false green this refusal
  -- exists to stop.
  local L = target and target.hunk_ledger
  if not L or type(L.owns) ~= "function" or type(L.members) ~= "function" then
    return false, "cannot rebind a resumed reject: no live ledger to bind against"
  end
  local members = L:members() or {}
  -- Resolve EVERY entry before mutating any of them: a zero or ambiguous match
  -- on the last entry must leave the first untouched, so the refusal the caller
  -- turns into changed=false is truthful about the whole stack.
  local plan = {}
  for i, entry in ipairs(retracted) do
    if entry.block and L:owns(entry.block) then
      plan[i] = entry.block
    else
      -- THE shared resolver (`hunk_identity.resolve_unique`), the same call the
      -- ledger's frame restore makes, so the decision rebind and the ledger
      -- replay can never answer "which live hunk is this recorded hunk"
      -- differently.
      local match, matches = hunk_identity.resolve_unique(members, entry.block)
      if not match then
        return false, string.format(
          "cannot rebind a resumed reject to a live hunk (%d matches)", matches)
      end
      plan[i] = match
    end
  end
  for i, entry in ipairs(retracted) do
    entry.block = plan[i]
  end
  return true
end

--- Every refusal below carries a `byte_location` as well as `changed`: the
--- router's compensation direction is a function of WHERE THE BYTES ARE, and
--- `ok`/`changed` cannot express the three answers. Refusals taken BEFORE the
--- move are "pre_call" by construction -- nothing was called.
local function result(ok, changed, reason, extra)
  local out = { ok = ok, changed = changed, reason = reason }
  for key, value in pairs(extra or {}) do
    out[key] = value
  end
  return out
end

function M.new(fields)
  assert(type(fields) == "table", "buffer edit action needs fields")
  assert(type(fields.rel) == "string", "buffer edit action needs rel")
  assert(type(fields.undo_seq) == "number", "buffer edit action needs undo_seq")
  return setmetatable({
    kind = "buffer_edit",
    rel = fields.rel,
    workspace = fields.workspace,
    turn_id = fields.turn_id,
    undo_seq = fields.undo_seq,
  }, BufferEditAction)
end

--- The destroyed-hunk reject decisions THIS sequence owns, and nobody else's.
--- Retracting on undo and re-pushing on redo is what keeps one editor command
--- one reversible action: the register walks the `buffer_edit` row, and the
--- reject the command caused rides with it instead of sitting in
--- `state.decisions` for the next decision-undo to pop by mistake.
---
--- Kept on the ACTION (`self.retracted_decisions`), never in the shared
--- `state.undone_decisions`: `redo_local` consumes that stack by recency and
--- would replay a buffer-owned effect through the wrong path. Matched by
--- `owner_seq`, not `post_seq` alone, because a `cr` reject entry is the same
--- shape and must be left untouched. Every reject the one sequence owns moves,
--- in register order, so a delete that destroyed several hunks stays atomic.
---
--- `apply`/`rollback` run inside the native settle transaction
--- (`undo_action_native.lua`): apply after the ledger has followed the bytes,
--- rollback if the repaint then raises. Both snapshot and restore BOTH stacks
--- so a rollback is exact.
local function decision_hooks(self, target, direction)
  if type(target) ~= "table" or type(target.decisions) ~= "table" then
    return nil
  end
  local decisions = target.decisions
  self.retracted_decisions = self.retracted_decisions or {}
  local retracted = self.retracted_decisions
  local saved_decisions, saved_retracted
  local function snapshot(list)
    local copy = {}
    for i, e in ipairs(list) do
      copy[i] = e
    end
    return copy
  end
  local function overwrite(list, from)
    for i = #list, 1, -1 do
      list[i] = nil
    end
    for i, e in ipairs(from) do
      list[i] = e
    end
  end
  local function apply()
    saved_decisions = snapshot(decisions)
    saved_retracted = snapshot(retracted)
    if direction == "undo" then
      local kept = {}
      for _, e in ipairs(decisions) do
        if e.owner_kind == "buffer_edit" and e.owner_seq == self.undo_seq then
          retracted[#retracted + 1] = e
        else
          kept[#kept + 1] = e
        end
      end
      overwrite(decisions, kept)
    else
      -- Blocks were rebound in the redo preflight (execute), so a re-pushed
      -- entry names a hunk the live ledger owns.
      for _, e in ipairs(retracted) do
        decisions[#decisions + 1] = e
      end
      overwrite(retracted, {})
    end
  end
  local function rollback()
    overwrite(decisions, saved_decisions or {})
    overwrite(retracted, saved_retracted or {})
  end
  return { apply = apply, rollback = rollback }
end

--- Every hunk block this row's structural records (`hunk_merges`, both kinds)
--- name: a split's parent and children, a merge's members and result.
local function structural_blocks(self)
  local out = {}
  local function add(block)
    if type(block) == "table" then out[#out + 1] = block end
  end
  for _, rec in ipairs(self.hunk_merges or {}) do
    add(rec.parent)
    add(rec.merged)
    for _, block in ipairs(rec.children or {}) do add(block) end
    for _, block in ipairs(rec.members or {}) do add(block) end
  end
  return out
end

--- `env.resolve_target(rel)` -> the review state owning the row's buffer;
--- `env.buf_undo_seq(bufnr)` -> Neovim's current undo sequence there.
local function execute(self, env, direction)
  local target, target_err = env.resolve_target(self.rel)
  if not target then
    return result(false, false, "could not reach " .. tostring(self.rel) .. ": " .. tostring(target_err),
      { byte_location = "pre_call" })
  end
  -- An EXPLICIT branch. `direction == "undo" and target._native_undo or
  -- target._native_redo` reads like a choice but is not one: Lua's `and` yields
  -- nil when `_native_undo` is nil, and the `or` then hands back the REDO
  -- executor. A press asking to undo would move the bytes the other way.
  local move
  if direction == "undo" then
    move = target._native_undo
  else
    move = target._native_redo
  end
  if type(move) ~= "function" then
    return result(false, false, "native " .. direction .. " action is unavailable",
      { byte_location = "pre_call" })
  end
  local cur = env.buf_undo_seq(target.bufnr)
  if direction == "undo" and cur ~= self.undo_seq then
    return result(false, false, "native history is not at this buffer edit",
      { byte_location = "pre_call" })
  end
  local suppress = direction == "undo"
    and cur ~= nil
    and target.undo_open_seq ~= nil
    and cur >= target.undo_open_seq
  -- Redo has no pre-guard to give it: it is the move that RE-CREATES this
  -- sequence, so its identity can only be checked on landing. `:redo` follows
  -- the newest branch of Neovim's undo tree, which after an undo/type/undo is
  -- the operator's own branch and not this row's.
  local expect_seq = direction == "redo" and self.undo_seq or nil
  if direction == "redo" then
    -- BEFORE the move: refuse without touching bytes if a resumed reject cannot
    -- be paired with exactly one live hunk (all-or-nothing, contract law).
    local ok, reason = rebind_retracted(self, target)
    if not ok then
      return result(false, false, reason, { byte_location = "pre_call" })
    end
  end
  local hooks = decision_hooks(self, target, direction)
  -- The router moved this row's structural records BEFORE this text move, so
  -- every block they took off the ledger rides it (`Ledger:carry_through`).
  local ledger = target.hunk_ledger
  local function run() return move(suppress, expect_seq, hooks) end
  local called, outcome
  if type(ledger) == "table" and type(ledger.carry_through) == "function" then
    called, outcome = ledger:carry_through(structural_blocks(self), run)
  else
    called, outcome = pcall(run)
  end
  if not called then
    -- The executor raised OUTSIDE its own transaction, so `changed = false`
    -- cannot be taken on trust here: ask Neovim whether the bytes moved. A
    -- wrong `false` leaves the row unspent over a buffer that did move, which
    -- is the one failure the router cannot recover from.
    local now = env.buf_undo_seq(target.bufnr)
    local where
    if now == nil or cur == nil then
      where = "unknown"
    elseif now == cur then
      where = "pre_call"
    else
      where = "moved"
    end
    return result(false, where ~= "pre_call", tostring(outcome), { byte_location = where })
  end
  if type(outcome) ~= "table" or outcome.ok ~= true then
    -- The executor's own answer is passed through UNTRANSLATED. A missing
    -- location is read from `changed`: a truthful `changed = false` promises
    -- nothing moved, bytes included ("pre_call"); a `changed = true` with no
    -- location named is exactly the case nobody may guess about ("unknown").
    local where = type(outcome) == "table" and outcome.byte_location or nil
    local changed = type(outcome) == "table" and outcome.changed == true
    if where == nil then
      where = changed and "unknown" or "pre_call"
    end
    return result(false, changed,
      (type(outcome) == "table" and outcome.reason) or "native history move failed",
      { byte_location = where })
  end
  -- The hunk the move actually WROTE, named by the executor. `pending()[1]` is
  -- the file's first pending hunk, which is a different hunk whenever the edit
  -- was not in it; it stays as the fallback for an edit the ledger absorbed into
  -- no hunk at all, where there is no touched block to name.
  local touched = outcome.touched_blocks or {}
  return result(true, true, nil, {
    byte_location = "moved",
    target_state = target,
    target_block = touched[1]
      or (target.hunk_ledger and target.hunk_ledger:pending()[1])
      or nil,
  })
end

function BufferEditAction:reverse(env)
  return execute(self, env, "undo")
end

function BufferEditAction:forward(env)
  return execute(self, env, "redo")
end

return M
