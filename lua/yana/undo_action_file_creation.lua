
-- Hand-test tracing (tools/handtest). Inert unless YANA_HANDTEST_TRACE is set.
local function _ht_trace(msg)
  local p = os.getenv("YANA_HANDTEST_TRACE")
  if not p then return end
  local f = io.open(p, "a")
  if f then f:write(msg .. "\n"); f:close() end
end

-- (`u`) and forwards (`<C-r>`). The atom here is the file's EXISTENCE on disk,
-- never a hunk verdict: the ledger is untouched by the removal press and the
-- hunks come back pending, so nothing in this module may read or write a
-- ledger's verdicts.
--
-- Same module idiom as `review_undo_turn_step.lua` (the `cA` giant step): a
-- factory over the review-local `env`, returning the pair the router
-- dispatches. `reverse` is `u`, `forward` is `<C-r>`.
--
-- The FOUR LAWS this class is written to: 1. `true` = honoured, the router may consume
-- the row. `false` = refused, the row stands exactly where it is.
--
-- Disk is the only thing the removal changes and the operator cannot see disk, so the
-- press ANNOUNCES; and a press that leaves the proposal still painted reads as a
-- swallowed press, so the file's review DETACHES and its buffer goes blank.
local Factory = {}

--- `env` is the router's review-local bundle: `facade` (the inline-diff module table,
--- for `_park_and_open_state` / `_pool_for`), `state` and `change` (the review the
--- press fired in), `log`, `notify_one_line`, and `resolve_target` (the ONE navigation
--- primitive, used only to revive this row's own file). Every dep is reached
--- defensively and every call is pcall'd: a bare unit-test double wires none of this,
--- and the same degrade-quietly contract `review_undo_turn_step.lua` holds for
function Factory.new(env)
  local facade = env.facade
  local state = env.state
  local change = env.change
  local log = env.log
  local notify_one_line = env.notify_one_line
  local resolve_target = env.resolve_target
  local creation_touch = require("yana.creation_touch")

  --- Say it BOTH ways, as `undo_turn` (review_undo.lua) already does:
  --- `notify.one_line` trims by DISPLAY WIDTH, so an announcement carrying a
  --- path can reach the operator already cut. The log line is the untrimmed
  --- record of the same sentence.
  local function say(msg, level)
    if log and type(log.write) == "function" then
      pcall(log.write, "WARN", msg)
    end
    if type(notify_one_line) == "function" then
      pcall(notify_one_line, msg, level)
    end
  end

  local function rel_of(row)
    return row.rel or row.path or "?"
  end

  local function state_rel(st)
    local c = st and st.change
    return c and (c.rel or c.path) or nil
  end

  --- THIS row's own review state, reached WITHOUT MOVING THE SCREEN. These are
  --- `resolve_target`'s first two branches (review_undo.lua:236) and deliberately not
  --- its third: the file under the press, and the file the pool already has ACTIVE. The
  --- third branch is `jump_to_rel`, which parks whatever is on screen to open the
  --- target -- and parking another file to reach a review we are about to park
  --- ourselves is navigation, which law 3 reserves for the router.
  local function own_state(rel)
    if state_rel(state) == rel then
      return state
    end
    local pool_for = facade and facade._pool_for
    if type(pool_for) ~= "function" then
      return nil
    end
    local ok, pool = pcall(pool_for, (state and state.opts) or {})
    if not ok or type(pool) ~= "table" then
      return nil
    end
    if state_rel(pool.active) == rel then
      return pool.active
    end
    return nil
  end

  --- The DETACH: park this file's own review, then blank its own buffer.
  ---
  --- ORDER IS LOAD-BEARING. The park snapshots the live buffer into
  --- `change._parked_review.staged_text` (review_navigate.lua), and that
  --- snapshot is what the revive below repaints from; blanking first would
  --- snapshot the blank and leave `<C-r>` nothing to restore.
  ---
  --- `target_item` is NIL ON PURPOSE (law 3, the D-26 defect). With no target the
  --- primitive does the full park -- teardown, `_parked_review` seal,
  --- `queue_insert_original` so the file rejoins its queue slot in `_review_order`
  --- position, which is also how the revive finds it again -- and then returns false
  --- without opening anything. That false is not a failure and is ignored: it reports
  --- "no file was opened", which is the whole point.
  local function detach(target)
    if not target then
      return
    end
    local park = facade and facade._park_and_open_state
    if type(park) == "function" then
      pcall(park, target, "walk", nil, nil, true)
    end
    local bufnr = target.bufnr
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
      return
    end
    -- Suspend/restore exactly as `native_undo` does around its own move.
    target.watch_suspended = true
    pcall(function()
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
      vim.bo[bufnr].modified = false
    end)
    -- The park above snapshotted the PRE-REMOVAL screen; the blank just written is not
    -- it.
    local parked = target.change and target.change._parked_review
    if type(parked) == "table" then
      parked.buffer_emptied = true
    end
    _ht_trace(("DETACH rel=%s parked=%s"):format(
      tostring(target.change and (target.change.rel or target.change.path)),
      tostring(type(parked) == "table")))
    vim.schedule(function()
      target.watch_suspended = false
      target.watch_changes = {}
    end)
  end

  --- The REVIVE: bring this row's own review back and let its surviving pending hunks
  --- repaint. `resolve_target` is the ONE navigation primitive (review_undo.lua:236 ->
  --- `jump_to_rel` -> `_park_and_open_state`), and the file it reopens is THIS ROW'S
  --- OWN -- the only file law 3 permits this class to touch.
  local function revive(rel)
    if type(resolve_target) ~= "function" then
      return
    end
    local ok, target = pcall(resolve_target, rel)
    if not ok or type(target) ~= "table" then
      return
    end
    -- Defensive: `jump_to_rel` already refuses a reopen that "landed
    -- elsewhere", but a repaint aimed at the wrong file would be law 4.
    if state_rel(target) ~= rel or not target.hunk_ledger then
      return
    end
    pcall(function()
      target.hunk_ledger:request_paint()
    end)
    if type(target._flush_paint) == "function" then
      pcall(target._flush_paint, "file_touch_redo")
    end
  end

  --- A refusal returns false with the row unconsumed and NOTHING else run -- no detach,
  --- no removal announcement -- because on a refusal the file is still there and its
  --- review is still the truth on screen.
  local function reverse(row)
    local rel = rel_of(row)
    local ok, err = creation_touch.remove(row.path or row.rel)
    if not ok then
      change.review_error = tostring(err)
      say("yana: kept " .. rel .. " -- refusing to remove it: " .. tostring(err), vim.log.levels.WARN)
      return false
    end
    detach(own_state(rel))
    say("yana: removed " .. rel .. " from disk -- <C-r> brings it back", vim.log.levels.INFO)
    return true
  end

  --- An occupied path refuses in the same shape the reverse does, and the row stays on
  --- the redo side.
  local function forward(row)
    local rel = rel_of(row)
    local ok, err = creation_touch.touch(row.path or row.rel)
    if not ok then
      change.review_error = tostring(err)
      say("yana: could not re-create " .. rel .. " -- " .. tostring(err), vim.log.levels.WARN)
      return false
    end
    revive(rel)
    say("yana: restored " .. rel .. " on disk -- its hunks are pending again", vim.log.levels.INFO)
    return true
  end

  return {
    reverse = reverse,
    forward = forward,
  }
end

return Factory
