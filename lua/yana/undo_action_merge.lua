-- UndoActionMerge -- the reverse and forward of ONE `Ledger:merge` call
-- (lua/yana/hunk_ledger_lifecycle.lua:203). Shared module shape:
-- `Factory.new(env)` -> `{reverse, forward}`.
--
-- One class with a direction flag would have to guess which of a row's two block lists
-- is the "before" side. Two kinds, two classes.
--
-- The keypress is the same seam as split's: an on_lines batch the absorb seam
-- REFUSES (lua/yana/review_watch.lua:633) runs `try_merge`
-- (lua/yana/review_watch.lua:666), which calls `Ledger:merge`
-- (lua/yana/review_hunk_split.lua:462) for each qualifying gap deletion. That
-- batch pushes a `buffer_edit` row (lua/yana/review_watch.lua) for the
-- text it removed; nothing records the MEMBERSHIP change.
--
-- PUSH ORDER (the push site is NOT in this file). `try_merge` LOOPS
-- (review_hunk_split.lua:427-467) and can fuse several pairs in one batch, so it is ONE
-- ROW PER `Ledger:merge` CALL, pushed after each call returns, and pushed after
-- `try_split`'s rows because the watcher runs splits first (review_watch.lua:662-666).
-- `u` walking newest-first then unmerges before it unsplits before it rewinds the text
-- -- the exact reverse of the order the batch made them.
--
-- ============================ THE ROW SHAPE ============================
--
-- { kind = "hunk_merge", rel, workspace, turn_id, -- register plumbing members = { <the
-- member block TABLES, ascending buffer order, exactly as handed to Ledger:merge> },
-- merged = <the merged block TABLE>, before = { { model_index = ..., model_join = ...
-- }, ... }, -- one per member, read BEFORE the merge; parallel to -- `members`.
--
-- WHICH KEY SURVIVES THE MUTATION: the block TABLES, by reference -- the same proof as
-- `undo_action_split.lua`'s, on the mirror method. `Ledger:merge` (:630-645) builds a
-- NEW list out of the SAME tables it already held plus the SAME `merged` table the
-- caller passed; it copies no table and replaces none. `Ledger:owns` (:130) ->
-- `index_of` (:44) is a `==` scan, so a table reference is exactly the key it answers
-- on.
--
-- WHAT DOES NOT SURVIVE: `merged.model_index`, nil'd at :624, and
-- `merged.model_join`, overwritten to "lost_at_merge" at :628. A member's own
-- `model_index` survives the merge (the members are only removed from the
-- list, never rewritten) -- but it does NOT survive the REVERSE, because
-- `Ledger:split` blanks every child's (:571, :576). That is why `before`
-- exists.
--
-- IS `Ledger:split` A TRUE INVERSE OF `Ledger:merge`? * it leaves
-- `old_lines`/`new_lines` alone and re-seeds no `owned_rows` (:586's `seed_row_owners`
-- early-returns on a block that already has them, :266), so a member returns with its
-- own content and anchors. * it is NOT an inverse on the two model fields (:571, :576)
-- -- this class writes the row's `before` tags back, undoing the primitive's own stamp
-- inside the same atomic action.
local Factory = {}

function Factory.new(env)
  local resolve_target = env.resolve_target
  local undo_refuse = env.undo_refuse
  local notify_one_line = env.notify_one_line
  local log = env.log

  --- Undoing the primitive's OWN stamp, not a second writer of a foreign
  --- fact: `Ledger:split`/`Ledger:merge` blank these two fields
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
      undo_refuse("could not reach " .. tostring(row.rel) .. " to reverse a hunk merge -- " .. tostring(err))
      return nil
    end
    if not target.hunk_ledger:is_open() then
      undo_refuse("that file's hunk ledger is closed, so its merge cannot be moved")
      return nil
    end
    return target.hunk_ledger, target
  end

  --- A row this class cannot act on is a REFUSAL, never a guess and never a
  --- raise: `Ledger:merge`/`split` raise on a bad argument, and an action
  --- class must not throw into the router.
  local function well_formed(row)
    return type(row.merged) == "table"
      and type(row.members) == "table"
      and #row.members >= 2
      and type(row.after) == "table"
      and type(row.before) == "table"
      and #row.before == #row.members
  end

  local function repaint(ledger, target, site)
    ledger:request_paint()
    if target._flush_paint then
      target._flush_paint(site)
    end
  end

  --- `u`. Take the merged block out and put its members back.
  local function reverse(row)
    if not well_formed(row) then
      undo_refuse("that hunk merge cannot be taken back -- its history row is incomplete")
      return false
    end
    local ledger, target = ledger_for(row)
    if not ledger then
      return false
    end
    -- Each is a condition `Ledger:split` would raise on, asked here so the press
    -- reports instead of erroring. The already-taken-back check comes FIRST so its own
    -- message is the one the operator gets: once the merge is reversed, the merged
    -- block is off the ledger too, and the guard below would otherwise answer a
    -- question nobody asked.
    for _, member in ipairs(row.members) do
      if ledger:owns(member) then
        undo_refuse("that hunk merge is already taken back")
        return false
      end
    end
    if not ledger:owns(row.merged) then
      undo_refuse("the ledger no longer holds that merged hunk, so it cannot be split apart again")
      return false
    end
    if row.merged.verdict ~= "pending" then
      -- `Ledger:split` raises on a non-pending block (hunk_ledger.lua:557),
      -- and splitting a decided hunk would scatter one verdict over several.
      undo_refuse("that merged hunk is already " .. tostring(row.merged.verdict) .. ", so the merge cannot be taken back")
      return false
    end
    ledger:split(row.merged, row.members)
    for i, member in ipairs(row.members) do
      wear_tag(member, row.before[i])
    end
    -- ROLLBACK. Membership is already mutated by the line above; the paint is
    -- a LATER step and can throw (a dead extmark, a closed window). A throw here would leave the ledger split, the row
    -- unconsumed by the router (it consumes only on `true`), and the next press
    -- replaying a split that has already happened -- the ledger and the
    -- register desynced by exactly the failure this class exists to prevent.
    -- So the tail runs under pcall and the primitive is put back on failure.
    local ok, err = pcall(function()
      repaint(ledger, target, "hunk_merge_reverse")
    end)
    if not ok then
      -- THE COMPENSATION IS CHECKED. If putting the merge back fails too, the
      -- ledger is split while the caller believes nothing moved -- a state no
      -- forward edit produced. That is not an ordinary refusal the caller can
      -- retry, so it is reported as a SECOND value the caller must halt on.
      local put_back = pcall(function()
        ledger:merge(row.members, row.merged)
        wear_tag(row.merged, row.after)
      end)
      undo_refuse("that hunk merge could not be taken back -- " .. tostring(err))
      if not put_back then
        return false, "a reversed hunk merge could not be re-merged after its paint failed -- " .. tostring(err)
      end
      return false
    end
    if log then
      log.lifecycle_info("review.undo.hunk_merge", {
        rel = row.rel,
        turn_id = row.turn_id,
        direction = "reverse",
        members = #row.members,
      })
    end
    notify_one_line("yana: split a merged hunk back into " .. #row.members .. " again", vim.log.levels.INFO)
    return true
  end

  --- `<C-r>`. Re-merge: take the members out and put the merged block back.
  local function forward(row)
    if not well_formed(row) then
      return false
    end
    local ledger, target = ledger_for(row)
    if not ledger then
      return false
    end
    if ledger:owns(row.merged) then
      undo_refuse("that hunk merge is already reapplied")
      return false
    end
    for _, member in ipairs(row.members) do
      if not ledger:owns(member) then
        undo_refuse("the ledger no longer holds that merge's parts, so it cannot be rejoined")
        return false
      end
      if member.verdict ~= "pending" then
        -- `Ledger:merge` raises on a non-pending member (hunk_ledger.lua:615)
        -- and would fold a decided hunk's verdict away.
        undo_refuse("decide-then-undo one of those hunks first -- it is already " .. tostring(member.verdict))
        return false
      end
    end
    ledger:merge(row.members, row.merged)
    wear_tag(row.merged, row.after)
    -- Same rollback as `reverse`, on the mirror primitive.
    local ok, err = pcall(function()
      repaint(ledger, target, "hunk_merge_forward")
    end)
    if not ok then
      -- Mirror of `reverse`'s: an unchecked compensation here would leave the
      -- ledger merged behind a `false` that promises it is not.
      local put_back = pcall(function()
        ledger:split(row.merged, row.members)
        for i, member in ipairs(row.members) do
          wear_tag(member, row.before[i])
        end
      end)
      undo_refuse("that hunk merge could not be reapplied -- " .. tostring(err))
      if not put_back then
        return false, "a re-merged hunk could not be split apart again after its paint failed -- " .. tostring(err)
      end
      return false
    end
    if log then
      log.lifecycle_info("review.undo.hunk_merge", {
        rel = row.rel,
        turn_id = row.turn_id,
        direction = "forward",
        members = #row.members,
      })
    end
    notify_one_line("yana: rejoined those " .. #row.members .. " hunks into one again", vim.log.levels.INFO)
    return true
  end

  return {
    reverse = reverse,
    forward = forward,
  }
end

return Factory
