-- Split out of review_undo.lua to meet the 500-line ceiling.
-- Decision replay helpers: index_in, shift_from, orphan_slot, redo_local, pop_decision.
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
  local undo_refuse = deps.undo_refuse
  local rerender_after_history_move = deps.rerender_after_history_move
  local log = deps.log

    --- `deps.pool_for` is not threaded down this factory chain; the live singleton
    --- closure is reachable off the facade's own test seam, which aliases the exact
    --- function `inline_diff.lua` built `review_context` with -- not a fresh, empty
    --- instance. nil when the facade wiring is absent (a bare unit-test double), which
    --- the caller treats as "no Turn to tell".
    local function turn_pool()
      local pf = deps.facade and deps.facade._test and deps.facade._test.pool_for
      if type(pf) ~= "function" then
        return nil
      end
      local ok, pool = pcall(pf, state.opts or {})
      if ok then
        return pool
      end
      return nil
    end

    --- `owns=false` alone cannot tell apart two different bugs: the hunk missing from
    --- the ledger entirely, vs. the ledger holding a DIFFERENT table for the same hunk.
    local function resolved_by_for(ledger, block, owns)
      if owns then
        return "identity"
      end
      if not ledger then
        return "absent"
      end
      local model_index = block and block.model_index
      for _, member in ipairs(ledger.hunks or {}) do
        if model_index ~= nil and member.model_index == model_index then
          return "copy"
        end
      end
      local old_lines = block and block.old_lines or {}
      local new_lines = block and block.new_lines or {}
      for _, member in ipairs(ledger.hunks or {}) do
        if lines_equal(member.old_lines or {}, old_lines) and lines_equal(member.new_lines or {}, new_lines) then
          return "copy"
        end
      end
      return "absent"
    end

    --- Where a hunk sits in a pending list RIGHT NOW.
    local function index_in(blocks, block)
      for i, b in ipairs(blocks or {}) do
        if b == block then
          return i
        end
      end
      return nil
    end

    --- Where an ORPHAN sits: a decision recorded before a rebuild, whose hunk the
    --- ledger swapped out for a fresh table and therefore does not own (amendment log,
    --- "a rebuild orphans the decision stack"). It is in no pending list, so its
    --- position is the one the pre-ledger mirror splice used -- `min(top.idx, #pending
    --- + 1)` -- computed the same way in both directions so an undo and its redo shift
    --- the same hunks by the same amount. Derived per call from a local vector; nothing
    local function orphan_slot(blocks, idx)
      return math.min(idx or (#blocks + 1), #blocks + 1)
    end
    --- The redo half of one popped decision, called when the top of the
    --- cross-file redo register is a decision this review popped. Refuses when
    --- the buffer has moved since (row r75_new_action_prunes_redo).
    local function redo_local(entry)
      local stack = state.undone_decisions or {}
      local top = stack[#stack]
      if top == nil then
        return false, "this review has no undone decision to put back"
      end
      local before = buf_undo_seq(bufnr)
      if before == nil or top.pre_seq ~= before then
        return false, "pruned"
      end
      if before ~= state.reload_restore_seq then
        state.reload_redo_guard = nil
        state.reload_restore_seq = nil
      end
      -- Accepting a hunk moves no buffer bytes, so taking it back created no
      -- Neovim redo step; consuming one here would replay an unrelated edit.
      -- The suspended on_lines callback still reports this physical byte move
      -- to HunkLedger. Replay changes the verdict only; applying top.delta here
      -- as well would move every later hunk twice.
      state.watch_suspended = true
      local after = before
      if top.action ~= "accept" then
        local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("silent redo")
        end)
        if not ok then
          log.write("WARN", "yana.inline_diff redo: " .. tostring(err))
          state.watch_suspended = false
          state.watch_changes = {}
          rerender_after_history_move("native_redo")
          return false, tostring(err)
        end
        after = buf_undo_seq(bufnr)
      end
      if after ~= top.post_seq then
        pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("silent undo " .. tonumber(before))
        end)
        state.watch_suspended = false
        state.watch_changes = {}
        return false, "redo no longer matches the decision it would put back"
      end
      local redo_start, redo_end = live_block_range(bufnr, top.block)
      if not redo_start then
        -- Orphan undo left geometry on the (off-ledger) block and cleared its
        -- extmarks; a reject's Neovim redo above may also have deleted the
        -- rows any re-anchored mark sat on. Fall back to the stored span so
        -- redo can still park and shift (amendment log, rebuild orphans).
        redo_start = top.block.new_start_line
        if redo_start == nil then
          pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd("silent undo " .. tonumber(before))
          end)
          state.watch_suspended = false
          state.watch_changes = {}
          return false, "redo cannot recover that decision's hunk position"
        end
        if top.action == "reject" then
          local n = #(top.block.old_lines or {})
          redo_end = (n > 0) and (redo_start + n - 1) or (redo_start - 1)
        else
          local n = #(top.block.new_lines or {})
          redo_end = top.block.new_end_line
            or ((n > 0) and (redo_start + n - 1) or (redo_start - 1))
        end
      end
      table.remove(stack)
      -- A decided hunk holds no authority mark, so re-applying a decision must
      -- clear them or the block stays actionable while resolved.
      clear_extmarks(top.block)
      top.anchor = park_anchor(top.block, redo_start, redo_end)
      -- Position from the block REFERENCE, read before the redo takes it back out of
      -- the pending list.
      local L = state.hunk_ledger
      local owns = L ~= nil and L:owns(top.block)
      if log then
        log.lifecycle_info("review.decision.replay", {
          rel = change.rel or change.path,
          turn_id = change.turn_id or change.turn_gen,
          park_seq = change._park_seq,
          direction = "redo",
          owns = owns,
          ledger_total = L and (L:count("pending") + L:count("accepted") + L:count("rejected")) or 0,
          pending_before = L and L:count() or 0,
          hunk = top.block and top.block.model_index or nil,
          resolved_by = resolved_by_for(L, top.block, owns),
        })
      end
      if owns then
        L:redo_decision(top.block, top.action)
      else
        -- ORPHAN: not on the ledger, so re-deciding it is a no-op. The
        -- watcher still shifts every owned hunk after the physical edit row.
      end
      state.decisions[#state.decisions + 1] = top
      record_decision(state, "redo_decision", {
        hunk = top.idx,
        model_index = top.block.model_index,
        model_join = top.block.model_join,
        redone = top.action,
      })
      local snap = diff.buffer_bytes_snapshot(bufnr)
      if snap then
        state.staged_text = snap
        state.latest_undo_seq = buf_undo_seq(bufnr)
      end
      rerender_after_history_move("native_redo")
      vim.schedule(function()
        state.watch_suspended = false
        state.watch_changes = {}
      end)
      return true
    end
    --- Take one decision back. True when popped, false when refused (and said
    --- so), nil when there was none.
    local function pop_decision()
      local top = state.decisions[#state.decisions]
      if top == nil then
        local pool = turn_pool()
        if pool then
          pcall(require("yana.turn_bind").on_undo_exhausted, pool)
        end
        return nil
      end
      if top.action == "reject" and top.pre_seq ~= nil then
        -- Yana's own `:undo {seq}`, not the operator time travelling; without the
        -- guard the rewind reconciler reads it as crossing the insert boundary.
        -- Suspension does NOT stop the ledger moving spans: `record_buffer_change`
        -- runs before the `watch_suspended` gate. It mutes interpretation and
        -- paint; this replay must not apply the same physical delta again.
        state.watch_suspended = true
        local ok = pcall(M._rewind_suppress, function()
          vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent undo " .. tonumber(top.pre_seq))
          end)
        end)
        if not ok then
          -- A reload past 'undoreload' clears the tree and the bookmark with it.
          state.watch_suspended = false
          state.watch_changes = {}
          undo_refuse("undo history no longer matches this review")
          return false
        end
      end
      local start_line, end_line = anchor_range(top.anchor)
      if start_line ~= nil then
        -- A reject's `:undo` just above widens the anchor's end-of-hunk mark by
        -- one row, so re-deciding a resurrected hunk ate an extra live line. The
        -- hunk's own content length is authoritative; re-derive the end from it.
        local n = #(top.block.new_lines or {})
        end_line = (n > 0) and (start_line + n - 1) or (start_line - 1)
      end
      if start_line == nil then
        start_line, end_line = live_block_range(bufnr, top.block)
      end
      if start_line == nil then
        state.watch_suspended = false
        state.watch_changes = {}
        undo_refuse("that hunk's position is no longer knowable, so the decision cannot be taken back")
        return false
      end
      -- Attribution. If the region still holds exactly what the agent proposed,
      -- re-adopting is free; otherwise the human has been in there and the reject
      -- separator decides whether the authors can be told apart. Refuses by name.
      local live = {}
      if end_line >= start_line then
        live = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
      end
      if not lines_equal(live, top.block.new_lines or {}) then
        local restored, merge_err = reject_restoration(bufnr, top.block, start_line, end_line)
        if not restored then
          record_decision(state, "undo_decision_refused", {
            hunk = top.idx,
            model_index = top.block.model_index,
            reason = "undo_would_discard_human_edit",
            detail = merge_err,
          })
          state.watch_suspended = false
          state.watch_changes = {}
          undo_refuse("refused to take back that decision -- " .. tostring(merge_err) .. "; it stands")
          return false
        end
      end
      -- Re-adopt, and keep the popped decision: redo must move the buffer and the
      -- review together or refuse, never re-apply bytes without the decision.
      state.undone_decisions = state.undone_decisions or {}
      state.undone_decisions[#state.undone_decisions + 1] = top
      table.remove(state.decisions)
      drop_anchor(top.anchor)
      -- An ORPHAN (a block a rebuild swapped off the ledger) is not owned, so
      -- `set_span` would refuse it -- it keeps the direct write it always had, being a
      -- table no ledger and no painter can see.
      if state.hunk_ledger and state.hunk_ledger:owns(top.block) then
        state.hunk_ledger:set_span(top.block, start_line, math.max(end_line, start_line - 1))
      else
        top.block.new_start_line = start_line
        top.block.new_end_line = math.max(end_line, start_line - 1)
      end
      -- The block's authority mark died with the repaint that followed its
      -- decision; forget the dead id so `live_block_range` reads no reissued one.
      top.block.authority_extmark_id = nil
      top.block.incoming_extmark_id = nil
      top.block.delete_extmark_id = nil
      -- Only MEMBERSHIP and the verdict go through the ledger; every buffer-side field
      -- above is shared state the renderer and the geometry helpers write directly.
      local L = state.hunk_ledger
      local owns = L ~= nil and L:owns(top.block)
      if log then
        log.lifecycle_info("review.decision.replay", {
          rel = change.rel or change.path,
          turn_id = change.turn_id or change.turn_gen,
          park_seq = change._park_seq,
          direction = "undo",
          owns = owns,
          ledger_total = L and (L:count("pending") + L:count("accepted") + L:count("rejected")) or 0,
          pending_before = L and L:count() or 0,
          hunk = top.block and top.block.model_index or nil,
          resolved_by = resolved_by_for(L, top.block, owns),
        })
      end
      if owns then
        -- Only revert a verdict that is actually decided. Undoing back across
        -- turns can leave a global turn_register decision row pointing at a
        -- block a turn-scoped reset already returned to pending; the ledger
        -- guard (hunk_ledger.lua: "undo_decision on a pending hunk") then
        -- crashes the whole undo. An owned-and-already-pending block is a no-op
        -- here -- its geometry was restored above -- exactly as the sibling
        -- callers treat it (review_undo_turn_step.lua: `owns(block) and
        -- block.verdict ~= "pending"`). Not the orphan `else`: this block IS
        -- owned, it just holds no decision to take back.
        if top.block.verdict ~= "pending" then
          L:undo_decision(top.block)
          -- Back in the frame the reject was decided in (`:undo pre_seq`).
          if top.pre_seq ~= nil then L:wear_decided(top.block) end
        end
      else
        -- Re-anchor: the orphaned table is off the ledger and unpainted, so
        -- redo cannot recover a live extmark. Park a decision anchor on the
        -- geometry just restored; redo_local also falls back to these fields
        -- when live_block_range still misses (reject's Neovim redo deletes
        -- the anchored rows).
        top.anchor = park_anchor(top.block, start_line, end_line)
      end
      record_decision(state, "undo_decision", {
        hunk = top.idx,
        model_index = top.block.model_index,
        model_join = top.block.model_join,
        undone = top.action,
        row = start_line,
        to_undo_seq = top.pre_seq,
      })
      local snap = diff.buffer_bytes_snapshot(bufnr)
      if snap then
        state.staged_text = snap
        state.latest_undo_seq = buf_undo_seq(bufnr)
      end
      -- This site asks for the ONE coalesced repaint instead of calling the painter
      -- itself.
      state.hunk_ledger:request_paint()
      if state._flush_paint then
        state._flush_paint("undo_decision")
      end
      M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "undo_decision")
      vim.schedule(function()
        state.watch_suspended = false
        state.watch_changes = {}
      end)
      return true
    end

  return {
    redo_local = redo_local,
    pop_decision = pop_decision,
    index_in = index_in,
    orphan_slot = orphan_slot,
  }
end

return Factory
