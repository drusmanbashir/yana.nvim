-- Open-review local undo and redo controls.
local turn_register = require("yana.turn.turn_register")

-- Hand-test tracing (tools/handtest). Inert unless YANA_HANDTEST_TRACE is set.
local function _ht_trace(msg)
  local p = os.getenv("YANA_HANDTEST_TRACE")
  if not p then return end
  local f = io.open(p, "a")
  if f then f:write(msg .. "\n"); f:close() end
end

local Factory = {}

function Factory.new(deps)
  local M = deps.facade
  local state = deps.state
  local change = deps.change
  local bufnr = deps.bufnr
  local notify_one_line = deps.notify_one_line
  local diff = deps.diff
  local buf_undo_seq = deps.buf_undo_seq
  local log = deps.log
  local live_block_range = deps.live_block_range
  local clear_extmarks = deps.clear_extmarks
  local park_anchor = deps.park_anchor
  local record_decision = deps.record_decision
  local anchor_range = deps.anchor_range
  local lines_equal = deps.lines_equal
  local reject_restoration = deps.reject_restoration
  local drop_anchor = deps.drop_anchor

    --- Where a hunk sits in a pending list RIGHT NOW.
  local review_undo_replay_factory = require("yana.review_undo_replay")

    local function undo_refuse(why)
      change.review_error = why
      notify_one_line("yana: " .. why .. " -- decide with ca/cr/cf/cx/cA", vim.log.levels.WARN)
    end

    --- Repaint after Neovim's own history moved the buffer: undo and redo move
    --- the text plane without telling the review, so a hunk whose lines are gone
    --- loses its highlight. Repaint only -- a tree move is not a decision.
    local function rerender_after_history_move(site)
      local snap = diff.buffer_bytes_snapshot(bufnr)
      if snap then
        state.staged_text = snap
        state.latest_undo_seq = buf_undo_seq(bufnr)
      end
      -- A native undo/redo does NOT re-derive the ledger. The rebuild that
      -- stood here asked for reason "native_history", which REBUILD_REASONS
      -- (hunk_ledger.lua:23) has never held, so `Ledger:rebuild` raised on
      -- every press and the `pcall` swallowed it -- dead from the day it was
      -- written. Its replacement is the live-buffer extent re-derivation.
      for _, block in ipairs(state.hunk_ledger:pending()) do
        block.authority_extmark_id = nil
        block.authority_lost = nil
      end
      state.watch_pending = false
      state.watch_changes = {}
      -- This site asks for the ONE coalesced repaint instead of calling the painter
      -- itself.
      state.hunk_ledger:request_paint()
      if state._flush_paint then
        state._flush_paint(site)
      end
      M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, site)
    end

    -- UndoActionNative: the kind-less pair `BufferEditAction` drives through
    -- `state._native_undo`/`_native_redo`; bare `<C-r>` with nothing to redo
    -- also lands on `native_redo`.
    local native_action = require("yana.undo_action_native").new({
      facade = M,
      state = state,
      bufnr = bufnr,
      log = log,
      rerender_after_history_move = rerender_after_history_move,
    })
    local native_undo = native_action.reverse
    local native_redo = native_action.forward

  local replay = review_undo_replay_factory.new(vim.tbl_extend("force", deps, {
    undo_refuse = undo_refuse,
    rerender_after_history_move = rerender_after_history_move,
  }))
  local redo_local = replay.redo_local
  local pop_decision = replay.pop_decision

    --- Every field is reached off the facade's own PRODUCT field `M._pool_for`
    --- (inline_diff.lua) -- the SAME live singleton closure `turn_pool()`
    --- (review_undo_replay.lua) already uses for the pool. A bare unit-test double (no
    --- facade wiring) still degrades to that refusal rather than erroring.
    local function pool_for_walk()
      local pf = deps.facade and deps.facade._pool_for
      if type(pf) ~= "function" then
        return nil
      end
      local ok, pool = pcall(pf, state.opts or {})
      if ok then
        return pool
      end
      return nil
    end

    local function jump_to_rel(rel)
      local park_fn = deps.facade and deps.facade._park_and_open_state
      local pool = pool_for_walk()
      if type(park_fn) ~= "function" or not pool then
        return nil, "walk plumbing unavailable"
      end
      local target_item = nil
      for _, item in ipairs(pool.queue or {}) do
        local c = item.change
        if c and (c.rel or c.path) == rel then
          target_item = item
          break
        end
      end
      if not target_item then
        return nil, "not a member of this turn"
      end
      -- "none": open the file the row names, land NOTHING. See F-UNDO-CURSOR.
      local ok, jump_err = pcall(park_fn, state, "walk", target_item, "none", true)
      if not ok then
        -- The error was swallowed here for the whole life of this branch, so "could not
        -- reach that file" was the only thing anyone ever saw and the cause never
        -- reached a log.
        _ht_trace("JUMP threw rel=" .. tostring(rel) .. " err=" .. tostring(jump_err))
        pcall(log.write, "WARN", "yana: jump to " .. tostring(rel) .. " threw: " .. tostring(jump_err))
        return nil, "could not reach that file"
      end
      local finder = deps.facade and deps.facade._state_for_rel
      local target_state = type(finder) == "function" and finder(pool, rel) or nil
      _ht_trace("JUMP ok rel=" .. tostring(rel) .. " attached=" .. tostring(target_state and target_state.change and (target_state.change.rel or target_state.change.path)))
      if not target_state or target_state.closed or not target_state.change
        or target_state.change._parked_state == target_state
        or (target_state.change.rel or target_state.change.path) ~= rel
      then
        return nil, "reopen landed elsewhere"
      end
      return target_state
    end

    --- Resolve `rel` (a register row's target file) to the review state
    --- that can act on it RIGHT NOW: the file under the press (no jump at
    --- all), the file the pool has ACTIVE (already reachable, nothing to
    --- park), and otherwise the cross-file JUMP.
    ---
    --- The jump is NOT a last resort.
    ---
    local function resolve_target(rel)
      if rel == (change.rel or change.path) then
        return state
      end
      local pool = pool_for_walk()
      local attached = pool and type(deps.facade._state_for_rel) == "function"
        and deps.facade._state_for_rel(pool, rel)
      if attached and not attached.closed and attached.change._parked_state ~= attached then
        return attached
      end
      return jump_to_rel(rel)
    end

    --- One buffer-edit row, either direction, and the ONLY site that spends one.
    ---
    --- CONSUME ONLY ON SUCCESS has a third case the law's two words hide. A move
    --- can report `ok = false, changed = true`: it stopped part-way and could not
    --- put the state back. Leaving that row on the register wedges the review --
    --- every later press peeks the same row and replays it against a buffer that
    --- has already moved, `BufferEditAction`'s own `cur ~= self.undo_seq` guard
    --- refuses, and the rows underneath become unreachable.
    ---
    --- So the halt is RECORDED ON THE ROW and the row is spent unreplayed
    --- (Ordering: a sequence that stops part-way records that it
    --- stopped, and every later predicate reads that record before any predicate
    --- derived from the state being resolved). The press still refuses -- a
    --- consumed row is not a success -- it just leaves nothing behind that no
    --- press can ever spend.
    -- THE STRUCTURAL RECORDS OF ONE BUFFER EDIT. A typed gap deletion is ONE
    -- native undo sequence that did TWO things: it removed text AND it fused two
    -- pending hunks (`Ledger:merge`, via the watcher's refusal seam). The
    -- operator's group law (2026-09-06) says a forward group reverses as ONE
    -- unit on the SAME boundaries it applied forward -- so this is ONE press,
    -- not two, and the membership inverse rides on the buffer row rather than
    -- standing beside it as a row of its own. A second row would also make the
    -- cross-file walk cost one extra press per merge, which is the same defect
    -- read from the keyboard.
    --
    -- ORDER. Forward was: text, then merge. Both presses move membership FIRST
    -- (`spend_buffer_edit`), and every block that takes off the ledger rides the
    -- text move with it (`Ledger:carry_through`), so no block changes frame.
    local hunk_merge = require("yana.undo_action_merge").new({
      resolve_target = resolve_target,
      undo_refuse = undo_refuse,
      notify_one_line = notify_one_line,
      log = log,
    })

    --- Reverse (or re-apply) every structural record a buffer row carries, in
    --- the given order, and put back the ones that DID land if one of them
    --- refuses: a half-applied group is the desync this whole record exists to
    --- prevent.
    --- Three outcomes, never two. `true` -- every record landed. `false, nil` --
    --- one refused and every record that HAD landed was put back, so nothing
    --- moved and the press is a clean refusal. `false, <reason>` -- a
    --- COMPENSATION itself refused, so the group is half-applied: the world is in
    --- a state no forward edit produced, and the caller must HALT the row rather
    --- than report an ordinary refusal it could retry.
    -- The SPLIT half of the same contract. A split destroys more than ledger
    -- membership (`state.model_hunks` and `change._retrace_absorbed` too), so
    -- it gets its own class and its own lossless row rather than being squeezed
    -- into the merge row's two block lists.
    local hunk_split = require("yana.undo_action_split").new({
      resolve_target = resolve_target,
      undo_refuse = undo_refuse,
      notify_one_line = notify_one_line,
      log = log,
    })

    --- ONE dispatch point for both structural kinds. A row without a `kind` is
    --- a merge row written before splits had an inverse.
    local function action_for(row)
      if type(row) == "table" and row.kind == "hunk_split" then
        return hunk_split
      end
      return hunk_merge
    end

    local function move_structural(rows, undoing)
      local done = {}
      for idx, row in ipairs(rows) do
        local act = action_for(row)
        local ok, own_halt = (undoing and act.reverse or act.forward)(row)
        if ok ~= true then
          -- The record's OWN rollback failed: it is half-applied before any
          -- compensation of ours runs, so this is already a halt.
          if own_halt then
            return false, own_halt
          end
          local stranded = 0
          for i = #done, 1, -1 do
            local back = action_for(done[i])
            if (undoing and back.forward or back.reverse)(done[i]) ~= true then
              stranded = stranded + 1
            end
          end
          if stranded > 0 then
            return false, string.format(
              "hunk membership record %d of %d refused and %d already-moved record(s) could not be put back",
              idx, #rows, stranded)
          end
          return false, nil
        end
        done[#done + 1] = row
      end
      return true, nil
    end

    --- The records this row carries, newest-first for `u` and oldest-first for
    --- `<C-r>`.
    local function structural_rows(peeked, undoing)
      local src = type(peeked.hunk_merges) == "table" and peeked.hunk_merges or {}
      local out = {}
      for i = 1, #src do
        out[i] = undoing and src[#src - i + 1] or src[i]
      end
      return out
    end

    --- THE OUTCOME VALIDATOR. Three questions, three answers, and they are not
    --- restatements of each other:
    ---   `ok`      -- did the operation succeed
    ---   `changed` -- is anything in the world still out of place
    ---   `where`   -- WHERE THE BYTES ENDED UP: "pre_call" | "moved" | "unknown"
    --- Only the third can choose a compensation DIRECTION, and only when it is
    --- one of those three words. An action can hand back a combination that
    --- cannot be true at once, so every combination is normalised HERE rather
    --- than acted on as written:
    ---   * an unrecognised location becomes "unknown" -- an unknown word is not
    ---     a side, and inventing one is exactly what corrupted membership;
    ---   * a location PROVING the bytes moved forces the partial-move halt
    ---     protocol even under `changed = false`: bytes on the far side are a
    ---     changed world whatever the flag claims;
    ---   * `ok = true` over bytes that did not verifiably move is NOT a success
    ---     -- spending the register row on it would leave the cursor one step
    ---     ahead of the buffer with no row left to correct it.
    --- A missing location is read from the pair: a success moved the bytes by
    --- definition; a truthful `changed = false` promises nothing moved, bytes
    --- included; a `changed = true` naming no side is the case nobody may guess
    --- about.
    local function read_outcome(outcome)
      local ok = outcome.ok == true
      local changed = outcome.changed == true
      local where = outcome.byte_location
      local contradiction
      if where ~= "pre_call" and where ~= "moved" and where ~= "unknown" then
        if where ~= nil then
          contradiction = string.format("the move named an unusable byte location (%s)", tostring(where))
          where = "unknown"
        elseif ok and changed then
          where = "moved"
        elseif changed then
          where = "unknown"
        else
          where = "pre_call"
        end
      end
      if where == "moved" and not changed then
        contradiction = "the move reports no change over bytes it places on the far side"
        changed = true
      end
      if ok and (where ~= "moved" or not changed) then
        contradiction = string.format(
          "the move reports success over bytes it places at %s (changed=%s)", where, tostring(outcome.changed))
        ok = false
      end
      return ok, changed, where, contradiction
    end

    local function spend_buffer_edit(register, peeked, direction)
      local undoing = direction == "undo"
      local function still_on_top()
        return (undoing and register:peek_back() or register:peek_forward()) == peeked
      end
      local function walk()
        if undoing then register:walk_back() else register:walk_forward() end
      end
      -- The record is read BEFORE the row is replayed, never after.
      if peeked.halted then
        if still_on_top() then walk() end
        undo_refuse("this buffer edit stopped part-way and cannot be replayed -- " .. tostring(peeked.halted))
        return false
      end
      -- THE HALT, shared by every component of this transaction: the world moved
      -- and could not be put back. Recording it on the row and spending the row
      -- unreplayed is the same protocol the native half uses below.
      local function halt(reason)
        peeked.halted = tostring(reason)
        if still_on_top() then walk() end
        undo_refuse("buffer edit stopped part-way -- " .. peeked.halted)
        return false
      end
      local move_env = { resolve_target = resolve_target, buf_undo_seq = buf_undo_seq }
      -- MEMBERSHIP FIRST, TEXT SECOND, IN BOTH DIRECTIONS. The ledger frames the
      -- native move replays name the hunks this transition BEGAN with going
      -- back and the ones it ENDED with going forward, so the structural
      -- records must already be on that side when the ledger resolves them: a
      -- split child a redo re-creates cannot be named while the split is still
      -- reversed (the split-undo bounce, redo leg). A refusal here spends
      -- nothing and moves nothing -- the press reports and the row stays.
      local moved, stranded = move_structural(structural_rows(peeked, undoing), undoing)
      if not moved then
        if stranded then return halt(stranded) end
        undo_refuse("could not " .. direction .. " buffer edit -- its hunk membership could not be "
          .. (undoing and "taken back" or "reapplied"))
        return false
      end
      local raw = (undoing and peeked.reverse or peeked.forward)(peeked, move_env)
      local ok, changed, where, contradiction = read_outcome(raw)
      local reason = raw.reason
      if contradiction then
        reason = contradiction .. " -- " .. tostring(raw.reason)
      end
      -- WHICH WAY TO COMPENSATE IS A QUESTION ABOUT THE BYTES, in BOTH
      -- directions. `ok = false` is returned both when the text never moved and
      -- when it moved and then could not report where it landed, and those two
      -- need OPPOSITE membership handling. Reading `ok` alone on `u` re-merged
      -- membership FORWARD over bytes that had gone BACKWARD; reading it alone
      -- on `<C-r>` left membership on the UNDO side over bytes that had gone
      -- FORWARD. Both break the atomic-group law (the group reverses and
      -- re-applies as ONE unit on the SAME boundaries).
      if not ok then
        if where == "unknown" then
          -- NO GUESS AND NO CLAIM. Either direction could be the corrupting
          -- one, so membership is moved neither way, and the halt says the
          -- world is UNPROVEN rather than pretending it is consistent.
          return halt("native " .. direction .. " left the bytes in an unknown place, so hunk membership was "
            .. "compensated in NEITHER direction and is not proven to agree with the buffer -- " .. tostring(reason))
        end
        -- ONE COMPENSATION FOR BOTH DIRECTIONS, because membership is already on
        -- the far side of the press. "pre_call" -- the bytes are where the call
        -- found them -- is the case that has to walk membership back to meet
        -- them; "moved" leaves it where the bytes now are.
        if where == "pre_call" then
          local back, stuck = move_structural(structural_rows(peeked, not undoing), not undoing)
          if not back then
            return halt(stuck
              or ("hunk membership could not be put back after the text refused -- " .. tostring(reason)))
          end
        end
      end
      if ok and still_on_top() then
        -- ONE TRANSACTION: membership landed before the text, so by here both
        -- halves of the group are on the same side. The cursor is not moved:
        -- after undo/redo it is wherever neovim left it (F-UNDO-CURSOR).
        walk()
        return true
      end
      if not ok and changed == true then
        peeked.halted = tostring(reason or "state moved and could not be put back")
        if still_on_top() then walk() end
        undo_refuse("buffer edit stopped part-way -- " .. peeked.halted)
        return false
      end
      undo_refuse("could not " .. direction .. " buffer edit -- " .. tostring(reason))
      return ok
    end

    --- The KEYS stay here: only `redo_key`/`undo_key` below touch the register, and
    --- `turn_step.redo` reports back whether the step was reapplied in FULL so the
    --- caller can tell a whole reapplication from a partial one.
    local turn_step = require("yana.undo_action_turn_step").new({
      deps = deps,
      facade = M,
      state = state,
      log = log,
      notify_one_line = notify_one_line,
      record_decision = record_decision,
      undo_refuse = undo_refuse,
      resolve_target = resolve_target,
    })
    local undo_accept_turn_step = turn_step.reverse
    local redo_accept_turn_step = turn_step.forward

    --- Yana's `u` and `<C-r>`: the per-kind dispatch over the turn register, its own module
    --- (review_undo_dispatch.lua, the owner-preserving split of this file).
    local dispatch = require("yana.review_undo_dispatch").new({
      deps = deps, facade = M, state = state, change = change, bufnr = bufnr, log = log,
      notify_one_line = notify_one_line, turn_register = turn_register, buf_undo_seq = buf_undo_seq,
      undo_refuse = undo_refuse, rerender_after_history_move = rerender_after_history_move,
      resolve_target = resolve_target, pool_for_walk = pool_for_walk, spend_buffer_edit = spend_buffer_edit,
      undo_accept_turn_step = undo_accept_turn_step, redo_accept_turn_step = redo_accept_turn_step,
      native_redo = native_redo, pop_decision = pop_decision,
    })
    local undo_key, redo_key = dispatch.undo_key, dispatch.redo_key

    --- `U` -- the turn-wide history operation, NOT an undo action
 ---. It replays nothing:
    --- it loads the retained turn-start overlay and DISCARDS every row of the
    --- turn, walked and redo-side alike. Its own module because it shares no
    --- code with the per-row dispatch above and this file is at its ceiling.
    local undo_turn = require("yana.review_undo_turn_all").new({
      facade = M,
      state = state,
      change = change,
      deps = deps,
      log = log,
      notify_one_line = notify_one_line,
      record_decision = record_decision,
      undo_refuse = undo_refuse,
      turn_register = turn_register,
    }).undo_turn

    state._pop_decision = pop_decision
    -- This review's decision-anchor pair, for an endpoint install another file's press drives (a publication's
    -- reverse/forward, undo_action_followup_cycle.lua).
    state._anchor_pair = { park = park_anchor, drop = drop_anchor }
    state._redo_local = redo_local
    state._native_undo = native_undo
    state._native_redo = native_redo

  return {
    -- UNIT SEAM. `spend_buffer_edit` is the one site that spends a buffer_edit
    -- row and the only place the text move, the register walk and the membership
    -- records meet; it is unreachable from outside without a keypress otherwise.
    _test = {
      spend_buffer_edit = spend_buffer_edit,
      move_structural = move_structural,
    },
    undo_refuse = undo_refuse,
    rerender_after_history_move = rerender_after_history_move,
    native_undo = native_undo,
    redo_local = redo_local,
    redo_key = redo_key,
    pop_decision = pop_decision,
    undo_key = undo_key,
    undo_turn = undo_turn,
  }
end

return Factory
