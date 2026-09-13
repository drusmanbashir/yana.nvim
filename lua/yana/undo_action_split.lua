-- UndoActionSplit -- the reverse and forward of ONE `Ledger:split` call
-- (lua/yana/hunk_ledger_lifecycle.lua:153). Shared module shape:
-- `Factory.new(env)` -> `{reverse, forward}`.
--
-- WHY THIS CLASS EXISTS. Of every mutator on `Ledger`, `split` and `merge` are the ONLY
-- two a keypress can reach that push no register row of their own. The keypress is
-- ordinary TYPING: an on_lines batch the absorb seam REFUSES
-- (lua/yana/review_watch.lua:633) runs `try_split` (lua/yana/review_watch.lua:663),
-- which calls `Ledger:split` (lua/yana/review_hunk_split.lua:316).
--
-- PUSH ORDER (the push site is NOT in this file -- see the audit). The row
-- must be pushed AFTER `Ledger:split` returns, so the register reads, oldest
-- to newest: `buffer_edit`, `hunk_split`. `u` walks newest first and so undoes
-- the MEMBERSHIP before the TEXT that caused it; `<C-r>` mirrors that. A push
-- before the split inverts both directions.
--
-- THE FOUR LAWS (contract). 1: `true` = honoured, `false` = refused and the
-- row stands. 2: the register cursor is the router's -- nothing here walks
-- it. 3: navigation is the router's -- `resolve_target` is asked for, never
-- `jump_to_rel`, and no file is opened, parked or closed here. 4: only the
-- ledger of `row.rel`, reached through `resolve_target`, is ever touched.
--
-- ============================ THE ROW SHAPE ============================
--
-- }, ... } } -- one entry per child, read AFTER the split, so it is the tag
-- `Ledger:split` left on each -- `model_index` nil, `model_join` lost_at_split;
-- parallel to `children`.
--
-- WHICH KEY SURVIVES THE MUTATION: the block TABLES, by reference. `Ledger:split`
-- (hunk_ledger_lifecycle.lua) builds a NEW list out of the SAME table references it
-- already held plus the SAME `children` the caller passed; no table is copied or
-- replaced anywhere in the method, only fields are assigned. `model_index` does
-- NOT survive -- the ledger nil's it on every child -- so it is not the key.
--
-- IS `Ledger:merge` A TRUE INVERSE? It is NOT an inverse in two respects, and this
-- class repairs both: (a) it stamps `merged.model_index = nil` (:624) and
-- `merged.model_join = "lost_at_merge"` (:628) -- the class writes the row's `before`
-- tag back, undoing the primitive's own stamp inside the same atomic action. (b) it
-- needs `#members >= 2` (:603) while `split` accepts one child (:560).
local Factory = {}

function Factory.new(env)
  local resolve_target = env.resolve_target
  local undo_refuse = env.undo_refuse
  local notify_one_line = env.notify_one_line
  local log = env.log

  --- Undoing the primitive's OWN stamp, not a second writer of a foreign
  --- fact: `Ledger:merge`/`Ledger:split` blank these two fields
  --- unconditionally, and a reversal is not a reversal while they stay blank.
  local function wear_tag(block, tag)
    block.model_index = tag.model_index
    block.model_join = tag.model_join
  end

  --- The ledger this row is allowed to touch, or a refusal. Law 4: `row.rel`
  --- names the ONE file; law 3: the jump, if any, is `resolve_target`'s.
  local function ledger_for(row)
    local target, err = resolve_target(row.rel)
    if not target or not target.hunk_ledger then
      undo_refuse("could not reach " .. tostring(row.rel) .. " to reverse a hunk split -- " .. tostring(err))
      return nil
    end
    if not target.hunk_ledger:is_open() then
      undo_refuse("that file's hunk ledger is closed, so its split cannot be moved")
      return nil
    end
    return target.hunk_ledger, target
  end

  --- A row this class cannot act on is a REFUSAL, never a guess and never a
  --- raise: `Ledger:split`/`merge` raise on a bad argument, and an action
  --- class must not throw into the router.
  local function well_formed(row)
    return type(row.parent) == "table"
      and type(row.children) == "table"
      and #row.children >= 2
      and type(row.before) == "table"
      and type(row.after) == "table"
      and #row.after == #row.children
  end

  local function repaint(ledger, target, site)
    ledger:request_paint()
    if target._flush_paint then
      target._flush_paint(site)
    end
  end

  --- THE HALF OF A SPLIT THAT IS NOT MEMBERSHIP. `try_split` clears the
  --- parent's `change._retrace_absorbed` entry and hands up the model mirror
  --- either side of the mutation. `Ledger:merge` puts back NEITHER, so a
  --- membership-only reversal leaves the change carrying a retrace entry for a
  --- hunk the ledger no longer holds. The snapshot rule itself lives once, in
  --- `review_hunk_split.restore_model_snapshot`; this is only its caller.
  ---
  --- Both tables are held BY REFERENCE on the row, which is the identity law's
  --- first clause -- the same owned table, never an index and never bytes.
  local function wear_model(row, undoing)
    require("yana.review_hunk_split").restore_model_snapshot(
      row.model, undoing and row.model_before or row.model_after)
    local change = row.review_change
    if type(change) == "table" and type(change._retrace_absorbed) == "table" and row.retrace_key ~= nil then
      -- Forward re-clears it: that is exactly what the forward split did.
      change._retrace_absorbed[row.retrace_key] = undoing and row.retrace_before or nil
    end
  end

  --- `u`. Put the parent back and take the children out.
  local function reverse(row)
    if not well_formed(row) then
      undo_refuse("that split cannot be taken back -- its history row is incomplete")
      return false
    end
    local ledger, target = ledger_for(row)
    if not ledger then
      return false
    end
    -- Each of these is a condition `Ledger:merge` would raise on, asked here so the
    -- press reports instead of erroring.
    if ledger:owns(row.parent) then
      undo_refuse("that hunk split is already taken back")
      return false
    end
    for _, child in ipairs(row.children) do
      if not ledger:owns(child) then
        undo_refuse("the ledger no longer holds that split's halves, so it cannot be rejoined")
        return false
      end
      if child.verdict ~= "pending" then
        -- Re-fusing a decided half into a pending parent would drop a verdict
        -- the operator gave. Their own `u` reaches the decision row first.
        undo_refuse("decide-then-undo one of that split's halves first -- it is already " .. tostring(child.verdict))
        return false
      end
    end
    ledger:merge(row.children, row.parent)
    wear_tag(row.parent, row.before)
    wear_model(row, true)
    -- ROLLBACK. Membership and the model mirror are already mutated; the paint
    -- is a LATER step and can throw (a dead extmark, a closed window). A throw here would leave the ledger merged, the row
    -- unconsumed by the router (it consumes only on `true`), and the next press
    -- replaying a reversal that has already happened -- ledger and register
    -- desynced by exactly the failure this class exists to prevent.
    local ok, err = pcall(function()
      repaint(ledger, target, "hunk_split_reverse")
    end)
    if not ok then
      -- THE COMPENSATION IS CHECKED. A clean refusal is `false` alone; a FAILED
      -- COMPENSATION is a second, NAMED value the caller must halt on, because
      -- the world is then in a state no forward edit produced. The two are not
      -- collapsed into one boolean.
      local put_back = pcall(function()
        ledger:split(row.parent, row.children)
        for i, child in ipairs(row.children) do
          wear_tag(child, row.after[i])
        end
        wear_model(row, false)
      end)
      undo_refuse("that hunk split could not be taken back -- " .. tostring(err))
      if not put_back then
        return false, "a rejoined hunk split could not be re-split after its paint failed -- " .. tostring(err)
      end
      return false
    end
    if log then
      log.lifecycle_info("review.undo.hunk_split", {
        rel = row.rel,
        turn_id = row.turn_id,
        direction = "reverse",
        children = #row.children,
        model_index = row.before.model_index,
      })
    end
    notify_one_line("yana: rejoined a hunk that a typed edit had split in two", vim.log.levels.INFO)
    return true
  end

  --- `<C-r>`. Re-split: take the parent out and put the same children back.
  local function forward(row)
    if not well_formed(row) then
      return false
    end
    local ledger, target = ledger_for(row)
    if not ledger then
      return false
    end
    -- The already-reapplied check comes FIRST so its own message is the one
    -- the operator gets: once the split is back on, the parent is off the
    -- ledger too, and the parent guard below would otherwise answer a
    -- question nobody asked.
    for _, child in ipairs(row.children) do
      if ledger:owns(child) then
        undo_refuse("that split is already reapplied")
        return false
      end
    end
    if not ledger:owns(row.parent) then
      undo_refuse("the ledger no longer holds that hunk, so the split cannot be reapplied")
      return false
    end
    if row.parent.verdict ~= "pending" then
      -- `Ledger:split` raises on a non-pending block (hunk_ledger.lua:557).
      undo_refuse("that hunk is already " .. tostring(row.parent.verdict) .. ", so it cannot be split again")
      return false
    end
    ledger:split(row.parent, row.children)
    for i, child in ipairs(row.children) do
      wear_tag(child, row.after[i])
    end
    wear_model(row, false)
    -- Same rollback as `reverse`, on the mirror primitive.
    local ok, err = pcall(function()
      repaint(ledger, target, "hunk_split_forward")
    end)
    if not ok then
      local put_back = pcall(function()
        ledger:merge(row.children, row.parent)
        wear_tag(row.parent, row.before)
        wear_model(row, true)
      end)
      undo_refuse("that hunk split could not be reapplied -- " .. tostring(err))
      if not put_back then
        return false, "a re-split hunk could not be rejoined after its paint failed -- " .. tostring(err)
      end
      return false
    end
    if log then
      log.lifecycle_info("review.undo.hunk_split", {
        rel = row.rel,
        turn_id = row.turn_id,
        direction = "forward",
        children = #row.children,
        model_index = row.before.model_index,
      })
    end
    notify_one_line("yana: split that hunk back into " .. #row.children .. " halves", vim.log.levels.INFO)
    return true
  end

  return {
    reverse = reverse,
    forward = forward,
  }
end

return Factory
