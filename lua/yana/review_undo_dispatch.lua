-- Size split of review_undo.lua (plan followup-addendum-turn.md "### M0" B4: the `undo_key`/`redo_key` dispatch
-- moves to its own module, an owner-preserving split of the 711-line review_undo.lua): the per-kind routing of
-- Yana's `u` and `<C-r>` over the turn register, with the router-owned landing after a file removal. Moved
-- unchanged; the one addition routes a `followup_cycle` publication row (undo_action_followup_cycle.lua) to its
-- own reverse/forward across its files and crosses it through the register graph (panel rules
-- F-ADDENDUM-UNDO, -REDO).
local Factory = {}

function Factory.new(env)
  local deps, M, state, change, bufnr = env.deps, env.facade, env.state, env.change, env.bufnr
  local log, notify_one_line, turn_register = env.log, env.notify_one_line, env.turn_register
  local buf_undo_seq, undo_refuse = env.buf_undo_seq, env.undo_refuse
  local rerender_after_history_move, resolve_target = env.rerender_after_history_move, env.resolve_target
  local pool_for_walk, spend_buffer_edit = env.pool_for_walk, env.spend_buffer_edit
  local undo_accept_turn_step, redo_accept_turn_step = env.undo_accept_turn_step, env.redo_accept_turn_step
  local native_redo, pop_decision = env.native_redo, env.pop_decision

    local keys = {}

    --- A follow-up publication row (one multi-part event): every participant's watcher is finalized first (an
    --- edit still being recorded there is newer and goes first), the graph must stand on the event in all its
    --- parts, and the row's own reverse/forward moves every file or none. Crossed through the S1a graph
    --- (`Register:mark`) only on success; a move that could not be put back is recorded on the row, spent
    --- unreplayed (the buffer-edit halt protocol) and the cycle halts as `recovery_required`.
    local function spend_publication(register, peeked, direction)
      local undoing = direction == "undo"
      local function on_top() return (undoing and register:peek_back() or register:peek_forward()) == peeked end
      if peeked.halted then
        undo_refuse("this follow-up publication stopped part-way -- " .. tostring(peeked.halted))
        return false
      end
      local live, cycle = require("yana.turn.turn_bind").get(), require("yana.turn.turn_cycle")
      local files = {}
      for _, f in ipairs(live and live.files or {}) do files[cycle.canonical_path(f.path)] = f end
      for _, p in pairs(peeked.participants or {}) do
        local st = files[p.path] and files[p.path].review_state
        if st and st ~= state and st.bufnr and vim.api.nvim_buf_is_valid(st.bufnr) then
          local ready, why = require("yana.review_watch").finalize(st.bufnr, st)
          if not ready then undo_refuse("could not finish pending edit: " .. tostring(why)); return false end
        end
      end
      if not on_top() then return (undoing and keys.undo or keys.redo)() end
      local event = register:event_of(peeked)
      local at, why = (undoing and register:head() or register:next_redo())
      if event == nil or at ~= event then
        undo_refuse("cannot " .. direction .. " this follow-up -- " .. tostring(why or "history is not at it"))
        return false
      end
      local out = (undoing and peeked.reverse or peeked.forward)(peeked, {
        file_of = function(path) return files[path] end })
      if out.ok == true then
        local marked, mark_why = register:mark(event, undoing and "undone" or "applied")
        if not marked then undo_refuse("follow-up " .. direction .. " left the history unmarked -- " .. tostring(mark_why)) end
        return marked
      end
      if out.changed == true then
        peeked.halted = tostring(out.reason)
        if on_top() then
          if undoing then register:walk_back() else register:walk_forward() end
        end
        pcall(function() live:cycles():set_state("recovery_required") end)
      end
      undo_refuse(tostring(out.reason))
      return false
    end

    --- The pair that must be exact inverses is the file's EXISTENCE ON DISK, so it
 --- lives in its own class beside the `cA` giant step.
    ---
    --- The class does the disk op, parks/revives ITS OWN review and announces.
    ---
    --- The old `walk_file_touch` returned `true` unconditionally AND was consumed
    --- before it ran, so a refused removal still moved the row.
    ---
    --- ROUTER-OWNED ON PURPOSE. Every hop is pcall'd and any missing plumbing is a
    --- quiet no-op -- the disk op already happened and was announced.
    local function land_after_removal(rel, next_rel)
      local pool = pool_for_walk()
      if not pool or require("yana.review_context").state_for_buf(pool) ~= nil then
        return
      end
      local facade = deps.facade
      -- `file_creation.reverse` has already parked this file -- correctly, BEFORE
      -- blanking its buffer, so `change._parked_review.staged_text` holds the
      -- pre-removal screen. Calling the full `_park_and_open_state` here parked it a
      -- SECOND time, over the now-blank buffer, and `<C-r>` restored that blank
      -- verbatim (`r_v2r24_redo_after_removal_retouches`: want 7 lines, got 1). The
      -- open half alone lands the walk and leaves the snapshot alone.
      local open_fn = facade and facade._open_target_item
      if type(open_fn) ~= "function" then
        return
      end
      local removed_change = nil
      for _, item in ipairs(pool.queue or {}) do
        local c = item.change
        if c and (c.rel or c.path) == rel then
          removed_change = c
          break
        end
      end
      -- The walk continues into the file it was reviewing BEFORE the creation:
      -- the parked change immediately before the removed one in review order. It
      -- is all-accepted -- ZERO pending -- BY DEFINITION, which is the only
      -- reason it had register rows to walk back at all. The ordinary target
      -- finder (`_ordered_target_for_state`) skips a settled file, emitting
      -- "settled -- skipping", and MUST keep doing so for `]x`/`[x` (A-7); so it
      -- can never return this one. Parked all-accepted files stay in `pool.queue`
      -- (review_queue.lua), so take the predecessor straight off it instead.
      -- THE REGISTER IS THE TRUTH ABOUT "PREVIOUS", NOT `_review_order`.
      -- `_review_order` is the order the turn ENQUEUED its files; the walk runs
      -- back over the order the operator DECIDED them, and the two part company
      -- the moment the operator reviews out of queue order. MEASURED: with the
      -- created file enqueued first, the queue reads `n.py:1 | p.py:2` while the
      -- file the walk owes next is p.py, so "the entry before order 1" is nothing
      -- at all and the walk landed nowhere
      -- (`r_v2r24_third_press_walks_to_previous_file`, got active=nil).
      -- So the landing is the file named by the row the NEXT press will spend;
      -- the review-order predecessor stays as the fallback for a register with
      -- nothing left behind this row (`u_walk_after_removal_lands_on_settled_file`
      -- pushes the `file_touch` row alone).
      local target_item = nil
      if next_rel and next_rel ~= rel then
        for _, item in ipairs(pool.queue or {}) do
          local c = item.change
          if c and (c.rel or c.path) == next_rel then
            target_item = item
            break
          end
        end
      end
      if not target_item then
        local removed_order = (removed_change and removed_change._review_order) or math.huge
        local target_order = nil
        for _, item in ipairs(pool.queue or {}) do
          local c = item.change
          local o = c and c._review_order
          if c and o and o < removed_order and (target_order == nil or o > target_order) then
            target_item, target_order = item, o
          end
        end
      end
      if not target_item then
        return
      end
      pcall(open_fn, pool, target_item, "first", "walk")
    end

    local decision = require("yana.undo_action_decision").new({})

    local file_creation = require("yana.undo_action_file_creation").new({
      facade = M,
      state = state,
      change = change,
      log = log,
      notify_one_line = notify_one_line,
      resolve_target = resolve_target,
      undo_refuse = undo_refuse,
    })

    --- `<C-r>` inside an open review.
    local function redo_key()
      local ready, reason = require("yana.review_watch").finalize(bufnr, state)
      if not ready then undo_refuse("could not finish pending edit: " .. tostring(reason)); return false end
      -- LIFO: `U`'s last act was the turn sweep, so redo owes its removals first.
      if M._redo_staged_restores(state) then
        return
      end
      local before = buf_undo_seq(bufnr)
      if state.reload_redo_guard and before == state.reload_restore_seq then
        undo_refuse("redo cannot reapply the transient buffer state used by reload")
        rerender_after_history_move("native_redo")
        return
      end
      if before ~= state.reload_restore_seq then
        state.reload_redo_guard = nil
        state.reload_restore_seq = nil
      end
      local workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
      local register = turn_register.for_workspace(workspace)
      local live_turn = change.turn_id or change.turn_gen
      local peeked = register:peek_forward()
      if peeked ~= nil and peeked.turn_id == live_turn and peeked.kind == "buffer_edit" then
        return spend_buffer_edit(register, peeked, "redo")
      end
      if peeked ~= nil and peeked.turn_id == live_turn and peeked.kind == "followup_cycle" then
        return spend_publication(register, peeked, "redo")
      end
      if peeked ~= nil and peeked.turn_id == live_turn and peeked.kind == "accept_turn_step" then
        -- The row is CONSUMED BY THE OUTCOME, never by the press. So: redo first,
        -- consume only on a FULL reapply (partial counts as refusal -- see
        -- `redo_accept_turn_step`).
        --
        -- The identity re-check is not belt-and-braces: the redo re-enters
        -- the review (paint, watchers, queue), and any register `push` from
        -- in there truncates the forward side, which would leave this
        -- `walk_forward` landing on a DIFFERENT row than the one just
        -- redone. Consume the row that was actually replayed, or nothing.
        --
        -- The claims this step needs are fetched from the daemon WITHOUT
        -- blocking the editor, so the outcome may only be known after the
        -- press returns. `"pending"` means exactly that: the same identity
        -- re-check then runs from the completion callback instead, and a
        -- late callback from an abandoned attempt is dropped by the
        -- per-attempt token in `review_undo_turn_step.lua` before it can
        -- reach here. Either way the row is consumed once, and only on a
        -- full reapply.
        local function consume_on_full_reapply(applied)
          if applied == true and register:peek_forward() == peeked then
            register:walk_forward()
          end
        end
        local outcome = redo_accept_turn_step(peeked, { on_complete = consume_on_full_reapply })
        if outcome ~= "pending" then
          consume_on_full_reapply(outcome)
        end
        return
      end
      if peeked ~= nil and peeked.turn_id == live_turn and peeked.kind == "file_touch" then
        -- CONSUME ONLY ON SUCCESS. A refused re-touch (the path is occupied)
        -- leaves the row exactly where it stands, so a later press can retry.
        -- The identity re-check mirrors `accept_turn_step` above: the action
        -- re-enters the review, and any `push` from in there truncates the
        -- forward side, which would land this `walk_forward` on a DIFFERENT
        -- row than the one just replayed.
        if file_creation.forward(peeked) == true and register:peek_forward() == peeked then
          register:walk_forward()
        end
        return
      end
      if peeked ~= nil and peeked.turn_id == live_turn then
        local target_state = resolve_target(peeked.rel)
        if target_state then
          local ok
          if peeked.kind == "decision" then
            ok = decision.forward(peeked, target_state)
          else
            undo_refuse("unknown undo action kind: " .. tostring(peeked.kind))
            return false
          end
          if ok == true and register:peek_forward() == peeked then register:walk_forward() end
          return ok
        end
      end

      -- A live Turn owns this buffer's history even at its newest edge.
      if require("yana.turn.turn_bind").get() then
        notify_one_line("Already at newest change", vim.log.levels.INFO)
        return false
      end
      -- Outside a live Turn the editor's own redo remains available.
      --
      -- The outcome is STRUCTURED and a refusal the user cannot see is a silent
      -- failure -- this press reported nothing at all where the undo side says
      -- why (`spend_buffer_edit`). Neovim prints its own message for a history
      -- that simply had nowhere to go, so that one no-op is left to it; every
      -- other refusal, including a move that could not be put back, is named.
      local outcome = native_redo()
      if type(outcome) == "table"
        and outcome.ok ~= true
        and outcome.code ~= "no_move"
      then
        undo_refuse("could not redo -- " .. tostring(outcome.reason))
      end
    end

    --- Take one decision back. Ask the turn-global register for the newest
    --- not-yet-walked action, turn-wide, not just this file's own `state.decisions`.
    --- Exhaustion is NOT bare `walk_back()==nil` (ADJUDICATED 28/correction 1-2): a row
    --- belonging to a FOREIGN turn is nothing for THIS turn too, since its payload died
    --- with the state object that pushed it.
    local function undo_key()
      local ready, reason = require("yana.review_watch").finalize(bufnr, state)
      if not ready then undo_refuse("could not finish pending edit: " .. tostring(reason)); return false end
      local workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
      local register = turn_register.for_workspace(workspace)
      local live_turn = change.turn_id or change.turn_gen
      local peeked = register:peek_back()
      -- Every buffer edit is a `buffer_edit` register row (F-UNDO-REGISTER), so
      -- the register alone decides which press owns the next native undo.
      local exhausted = peeked == nil or peeked.turn_id ~= live_turn
      if exhausted then
        if state.decisions[#state.decisions] == nil and require("yana.turn.turn_bind").get() then
          notify_one_line("Already at oldest change", vim.log.levels.INFO)
        end
        return pop_decision()
      end
      if peeked.kind == "accept_turn_step" then
        register:walk_back()
        return undo_accept_turn_step(peeked)
      end
      if peeked.kind == "file_touch" then
        -- CONSUME ONLY ON SUCCESS (contract law 1).
        if file_creation.reverse(peeked) ~= true then
          return false
        end
        register:walk_back()
        -- The action parked its own review and left NO active one, so without this
        -- there is no live `u` keymap and the walk dies on the very press the ruling
        -- says continues it. THIS IS THE ROUTER'S JOB, NOT THE ACTION'S: an action that
        -- navigates for itself reaches into another file's state, which is D-26.
        local next_row = register:peek_back()
        land_after_removal(peeked.rel,
          (next_row and next_row.turn_id == live_turn) and next_row.rel or nil)
        return true
      end
      if peeked.kind == "buffer_edit" then
        return spend_buffer_edit(register, peeked, "undo")
      end
      if peeked.kind == "followup_cycle" then
        return spend_publication(register, peeked, "undo")
      end
      local target_state, err = resolve_target(peeked.rel)
      if not target_state then
        undo_refuse("could not reach " .. tostring(peeked.rel) .. " to undo -- " .. tostring(err))
        return false
      end
      local ok
      if peeked.kind == "decision" then
        ok = decision.reverse(peeked, target_state)
      else
        undo_refuse("unknown undo action kind: " .. tostring(peeked.kind))
        return false
      end
      if ok == true and register:peek_back() == peeked then register:walk_back() end
      return ok
    end

  keys.undo, keys.redo = undo_key, redo_key
  return { undo_key = undo_key, redo_key = redo_key }
end

return Factory
