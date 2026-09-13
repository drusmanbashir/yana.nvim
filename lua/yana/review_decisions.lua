-- Per-hunk and file-level decisions for one open inline review.
local creation_touch = require("yana.creation_touch")
local M = {}

local function push_register_decision(state, change, count)
  pcall(function()
    require("yana.turn_register"):push({
      kind = "decision",
      rel = change.rel or change.path,
      workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd(),
      turn_id = change.turn_id or change.turn_gen,
      count = count or 1,
    })
  end)
end

function M.new(deps)
  local state = deps.state
  local change = deps.change
  local bufnr = deps.bufnr
  local facade = deps.facade

  local function park_anchor(_, start_line, end_line)
    return deps.park_decision_anchor(bufnr, start_line, end_line)
  end

  -- Record the same reject decision the `cr` door records, while `line_delta` lets the
  -- ledger own the one physical shift that the deletion caused. The watcher supplies
  -- the pre-delete undo seq so `u` can take this decision back as one logical step.
  local function reject_destroyed_hunk(block, idx, line_delta, pre_seq, reason)
    if not state.hunk_ledger or not state.hunk_ledger:owns(block) then
      return false
    end
    -- Geometry comes from the ledger's RECORDED pre-edit frame, not from
    -- `block.new_start_line` as it stands here. By the time this runs, the
    -- watcher's shift pass has already moved the live fields by the size of the
    -- deletion, so an anchor parked on them is off by exactly that many lines
    -- and one undo restores the bytes against the wrong range. The recorded
    -- frame is captured before the shift and is keyed by the block itself, so
    -- it survives a move that invalidates any row anchor.
    local recorded = state.hunk_ledger.pre_edit_state and state.hunk_ledger:pre_edit_state(block) or nil
    local start_line = recorded and recorded.start_line or block.new_start_line
    local end_line = (recorded and recorded.end_line) or block.new_end_line or start_line
    state.hunk_ledger:decide(block, "reject", line_delta)
    -- Record the destruction in keyed history AFTER `decide`, because the frame
    -- pair this writes is BEFORE/AFTER and only the AFTER half is read off the
    -- live hunk. `remember` snapshots the block as it stands now, so recording
    -- first stored an after-frame that still said `pending`, and redo compared
    -- pending against pending and never restored the verdict -- the bytes went
    -- back but the hunk stayed in the pending set. The BEFORE half does not move
    -- with this call: `record_destroyed_hunk` takes it from
    -- `buffer_history.last_before[block]`, captured by the shift pass before the
    -- edit, and `decide` neither touches that frame nor drops the hunk from the
    -- ledger, so the pre-edit geometry and the `pending` verdict one undo
    -- restores are the same either way.
    --
    -- An absorbed edit records itself; a hunk deleted outright absorbs nothing,
    -- so without this call history holds no record of the destruction and the
    -- replay has nothing to restore.
    if state.hunk_ledger.record_destroyed_hunk then
      state.hunk_ledger:record_destroyed_hunk(block, deps.buf_undo_seq(bufnr))
    end
    deps.record_decision(state, "reject_hunk", {
      hunk = idx,
      model_index = block.model_index,
      model_join = block.model_join,
      row = start_line,
      old_count = #(block.old_lines or {}),
      new_count = #(block.new_lines or {}),
      reason = reason,
    })
    local anchor = park_anchor(block, start_line, end_line)
    local post_seq = deps.buf_undo_seq(bufnr)
    local entry = {
      action = "reject",
      idx = idx,
      block = block,
      delta = line_delta,
      pre_seq = pre_seq,
      post_seq = post_seq,
      anchor = anchor,
      -- This reject is a CONSEQUENCE owned by the editor command's own
      -- `buffer_edit` register row (undo_seq == owner_seq), not a decision the
      -- register walks on its own. `u` retracts it when it reverses that
      -- sequence and re-pushes it on redo (undo_action_buffer_edit.lua), so the
      -- one keystroke stays one reversible action. `owner_kind` marks it apart
      -- from a `cr` reject, whose entry is otherwise the same shape and which
      -- the register never owns.
      owner_kind = "buffer_edit",
      owner_seq = post_seq,
    }
    state.decisions[#state.decisions + 1] = entry
    -- No register row. The editor command that destroyed this hunk already
    -- pushes its own `buffer_edit` row (review_watch.lua), and that row is what
    -- `u` reverses. Pushing a decision row here as well would put TWO rows on
    -- the register for ONE keystroke, so one press would spend one row and
    -- leave the other half of the command standing. The `state.decisions` entry
    -- above still records what was decided, tagged to that buffer_edit so its
    -- reversal takes it back atomically -- review bookkeeping, not the register.
    if state.hunk_ledger:count() == 0 then
      deps.record_last_hunk_decided("reject", block)
    end
    facade._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "reject_hunk")
    -- Edge poll notifies the Turn (`on_decision`); `_poll_leave_edge` never
    -- returns true, so no try_finalize branch remains here.
    facade._poll_leave_edge(state, "hunk_destroyed")
    return true
  end

  local function anchor_range(id)
    if not id then
      return nil
    end
    local ext = vim.api.nvim_buf_get_extmark_by_id(bufnr, deps.anchor_ns, id, { details = true })
    if not ext or ext[1] == nil then
      return nil
    end
    local meta = ext[3] or {}
    return ext[1] + 1, (meta.end_row or ext[1]) + 1
  end

  local function drop_anchor(id)
    if id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, deps.anchor_ns, id)
    end
  end

  local function clear_extmarks(block)
    if facade._fault_keeps_paint(state.hunk_ledger:pending(), block) then
      return
    end
    if block.incoming_extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, deps.ns, block.incoming_extmark_id)
      block.incoming_extmark_id = nil
    end
    if block.delete_extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, deps.ns, block.delete_extmark_id)
      block.delete_extmark_id = nil
    end
    if block.authority_extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, deps.authority_ns, block.authority_extmark_id)
      block.authority_extmark_id = nil
    end
  end

  -- A bulk caller stepping this per hunk (`review_bulk.reject_all`'s prior-decisions
  -- path) must not let each hunk push its own register row -- that made `cx` write N
  -- rows for ONE press. The caller passes true and pushes ONE aggregate row itself once
  -- the loop is done.
  local function reject_block_at(idx, suppress_register)
    local block = state.hunk_ledger:pending()[idx]
    if not block then
      return
    end
    deps.break_undo_block(bufnr)
    local start_line, end_line, range_err = deps.live_block_range(bufnr, block)
    if not start_line then
      change.review_error = range_err or "hunk invalidated"
      deps.notify_one_line("yana: " .. change.review_error, vim.log.levels.WARN)
      return
    end
    local restored = deps.reject_restoration(bufnr, block, start_line, end_line)
    local replaced = (end_line >= start_line) and (end_line - start_line + 1) or 0
    local delta = #restored - replaced
    local pre_seq = deps.buf_undo_seq(bufnr)
    -- The decided hunk leaves `paint_membership` the instant the ledger knows, and the
    -- band it leaves behind is removed by the ONE coalesced repaint the dirty signal
    -- schedules -- this door neither deletes an extmark (`clear_extmarks`) nor repaints
    -- by hand. The byte restore and the decision-stack/timeline bookkeeping follow,
    -- inside watch_suspended, so no paint can ever run against a half-updated ledger.
    local decided = state.hunk_ledger and state.hunk_ledger:owns(block)
    if decided then
      -- The suspended on_lines callback owns this physical row delta. The
      -- decision changes membership only; applying the same delta here would
      -- move every later hunk twice.
      state.hunk_ledger:decide(block, "reject", 0)
    end
    -- This edit is the review's OWN bookkeeping for the hunk just decided, not a human
    -- touching the buffer. The on_lines watcher still moves ledger geometry once, but
    -- suspension keeps it out of interpretation. Left unsuspended, rejecting an all-new
    -- interior hunk (0 old lines) is a net removal that on_lines reports exactly like a
    -- human deleting the live gap between two OTHER pending hunks, and
    -- `try_merge`/`merge_gap_pair` (review_hunk_split.lua) wrongly fuse those two
    state.watch_suspended = true
    -- `redo_of` was never a name in this scope: it read as an undeclared
    -- global, always nil, so the replay branch it guarded was unreachable.
    -- Removed with the whole-tree undeclared-globals gate
    -- (tests/undeclared_globals_gate.sh).
    vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, restored)
    state.watch_suspended = false
    deps.break_undo_block(bufnr)
    facade._recompute_modified(bufnr, state.hunk_ledger:pending(), change.path)
    deps.record_decision(state, "reject_hunk", {
      hunk = idx,
      model_index = block.model_index,
      model_join = block.model_join,
      row = start_line,
      old_count = #(block.old_lines or {}),
      new_count = #(block.new_lines or {}),
    })
    local anchor = park_anchor(block, start_line, start_line + math.max(#restored, 1) - 1)
    state.decisions[#state.decisions + 1] = {
      action = "reject",
      idx = idx,
      block = block,
      delta = delta,
      pre_seq = pre_seq,
      post_seq = deps.buf_undo_seq(bufnr),
      anchor = anchor,
    }
    if not suppress_register then
      push_register_decision(state, change, 1)
    end
    if state.hunk_ledger:count() == 0 then
      deps.record_last_hunk_decided("reject", block)
    end
    local snap = deps.diff.buffer_bytes_snapshot(bufnr)
    if snap then
      state.staged_text = snap
      state.latest_undo_seq = deps.buf_undo_seq(bufnr)
      change.after = snap
    end
    facade._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "reject_hunk")
    deps.land_on(change.path, bufnr, deps.nearest_block(state.hunk_ledger:pending(), bufnr, "next"))
    if state._flush_paint then
      state._flush_paint("reject_hunk")
    end
    -- A1: the edge is polled HERE, at the door's tail, never inside `decide`.
    -- End review? (turn-scope zero) lives inside `_poll_leave_edge` via
    -- turn_bind.on_decision. Never returns true — no try_finalize branch.
    facade._poll_leave_edge(state, "reject_hunk")
  end

  local function accept_block_at(idx)
    local block = state.hunk_ledger:pending()[idx]
    if not block then
      return
    end
    deps.break_undo_block(bufnr)
    local at_seq = deps.buf_undo_seq(bufnr)
    local start_line, _, range_err = deps.live_block_range(bufnr, block)
    if not start_line then
      change.review_error = range_err or "hunk invalidated"
      deps.notify_one_line("yana: " .. change.review_error, vim.log.levels.WARN)
      return
    end
    -- Accept passes NO delta: the buffer already holds the agent's lines, so no later
    -- hunk moves (`remove_block`'s `use_new_lines` branch). `owns` is asked because a
    -- rebuild can orphan the block this door is holding (amendment log); an orphan
    -- simply carries no verdict. The band over the accepted hunk goes with the ONE
    -- coalesced repaint the dirty signal schedules -- this door deletes no extmark and
    -- repaints nothing by hand.
    if state.hunk_ledger and state.hunk_ledger:owns(block) then
      state.hunk_ledger:decide(block, "accept")
    end
    -- Nothing is written here, so nothing advances the undo seq behind the decision's
    -- back either, and the W13 `save_buffer` stamp this site existed to sequence around
    -- is gone with it.
    deps.record_decision(state, "accept_hunk", {
      hunk = idx,
      model_index = block.model_index,
      model_join = block.model_join,
      row = start_line,
      old_count = #(block.old_lines or {}),
      new_count = #(block.new_lines or {}),
    })
    local a_start, a_end = deps.live_block_range(bufnr, block)
    local anchor = park_anchor(block, a_start or start_line, a_end or start_line)
    state.decisions[#state.decisions + 1] = {
      action = "accept",
      idx = idx,
      block = block,
      delta = 0,
      pre_seq = at_seq,
      post_seq = at_seq,
      anchor = anchor,
    }
    push_register_decision(state, change, 1)
    if not creation_write then
      vim.bo[bufnr].modified = true
    end
    if state.hunk_ledger:count() == 0 then
      deps.record_last_hunk_decided("accept", block)
    end
    -- The final accept is terminal only after the leave offer and async claim
    -- path complete. Do not emit an intermediate settle event for it.
    if state.hunk_ledger:count() > 0 then
      facade._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "accept_hunk")
    end
    deps.land_on(change.path, bufnr, deps.nearest_block(state.hunk_ledger:pending(), bufnr, "next"))
    if state._flush_paint then
      state._flush_paint("accept_hunk")
    end
    -- Edge poll notifies the Turn; `_poll_leave_edge` never returns true.
    facade._poll_leave_edge(state, "accept_hunk")
  end

  local function reject_hunk()
    local block, idx = deps.current_block(state.hunk_ledger:pending(), bufnr)
    if block then
      reject_block_at(idx)
      return
    end
    -- ca/cr act on the hunk under the cursor only; a key that sometimes hits an
    -- off-screen sole pending hunk is what we refuse.
    deps.notify_one_line(
      "yana: cursor is not on a pending hunk — move onto one, then cr",
      vim.log.levels.WARN
    )
  end

  local function accept_hunk()
    local block, idx = deps.current_block(state.hunk_ledger:pending(), bufnr)
    if block then
      accept_block_at(idx)
      return
    end
    -- ca/cr act on the hunk under the cursor only; a key that sometimes hits an
    -- off-screen sole pending hunk is what we refuse.
    deps.notify_one_line(
      "yana: cursor is not on a pending hunk — move onto one, then ca",
      vim.log.levels.WARN
    )
  end

  local function accept_all()
    deps.record_decision(state, "accept_file", { hunks_remaining = state.hunk_ledger:count() })
    local pending_before = state.hunk_ledger:pending()
    local members = {}
    --
    -- Written HERE, in the loop that already walks the pending hunks, and
    -- BEFORE `decide_all`: each anchor is parked off the block's LIVE range,
    -- and the repaint the verdicts' dirty signal schedules takes the marks
    -- those ranges are read from with it.
    --
    -- `delta = 0` and `pre_seq == post_seq` for the reason the per-hunk accept
    -- door uses them: accepting moves no bytes (the buffer already holds the
    -- agent's lines), so no later hunk shifts and there is no undo-tree
    -- position to rewind to.
    local at_seq = deps.buf_undo_seq(bufnr)
    for i, block in ipairs(pending_before) do
      members[#members + 1] = {
        hunk = block.model_index or i,
        old_count = #(block.old_lines or {}),
        new_count = #(block.new_lines or {}),
      }
      local a_start, a_end = deps.live_block_range(bufnr, block)
      -- A hunk whose marks are already gone still gets an entry, anchored off its
      -- stored geometry: `pop_decision` falls back to `live_block_range` and then
      -- refuses BY NAME if the position is truly unknowable. Dropping the entry instead
      -- would silently desync `count` from the array and send the surplus pop into the
      -- undo-exhausted door -- the very fault this block exists to close. The per-hunk
      -- door may refuse the whole press on a dead range because it is deciding ONE
      a_start = a_start or block.new_start_line
      a_end = a_end or block.new_end_line or a_start
      state.decisions[#state.decisions + 1] = {
        action = "accept",
        idx = i,
        block = block,
        delta = 0,
        pre_seq = at_seq,
        post_seq = at_seq,
        anchor = a_start and park_anchor(block, a_start, a_end) or nil,
      }
    end
    push_register_decision(state, change, #members)
    local last_block = state.hunk_ledger:pending()[#state.hunk_ledger:pending()]
    state.hunk_ledger:decide_all("accept")
    deps.record_last_hunk_decided("accept", last_block)
    -- Only the HINT namespace is not the painter's, so only it is cleared here.
    vim.api.nvim_buf_clear_namespace(bufnr, deps.hint_ns, 0, -1)
    if state._flush_paint then
      state._flush_paint("accept_file")
    end
    -- A1/call 2: the file-level door polls the SAME edge as the per-hunk ones instead
    -- of calling `finish_session` behind their backs -- that asymmetry is why the leave
    -- offer only ever reached two of the doors.
    local edge = facade._poll_leave_edge(state, "accept_file")
    if edge == "stay" then
      return
    end
    -- No pending hunk to cross the boundary WITH: an agent-created empty file diffs to
    -- zero hunks and still has to be acceptable. (`edge == true` / try_finalize is gone
    -- — `_poll_leave_edge` never yields true.) Creation already wrote above;
    -- finish_session still closes the review.
    deps.finish_session(state, true)
    if state._redo_hold_active then
      local pool = deps.pool_for(state.opts or {})
      if pool.active == nil then
        pool.active = state
      end
    end
  end

  state._decide_destroyed_hunk = reject_destroyed_hunk

  -- Under the ruling a decision on a created file moves no bytes at all, so there is
  -- nothing to revert.
  --
  -- What the ruling DOES need here is the other direction. So the NEXT decision on any
  -- of those hunks may arrive with no file underneath it, and it must re-run the touch
  -- owner's FORWARD before it applies. It cannot be replayed from a register row:
  -- `turn_register:push` clears forward rows (lua/yana/turn_register.lua:55-58), so a
  -- row-based redo of the touch is unreachable BY CONSTRUCTION and must not be relied
  -- on.
  --
  -- Hooked on the ledger's three verdict-applying entries rather than on each door, so
  -- a decision arriving through any door -- per-hunk, file-level, the watcher's
  -- destroyed-hunk seam, or a redo replay -- re-touches first. FORWARD is idempotent,
  -- so the ordinary case (file still there) costs one `getftype`. Installed ONCE per
  -- ledger object.
  if creation_touch.is_creation(change)
    and state.hunk_ledger
    and not state.hunk_ledger._creation_retouch_hooked
  then
    local led = state.hunk_ledger
    led._creation_retouch_hooked = true
    local function retouch()
      local ok, err = creation_touch.touch(change.path)
      if not ok then
        -- Someone else owns that path now. The decision still lands in the
        -- ledger; what refuses is putting the file back under it.
        deps.notify_one_line(
          "yana: could not re-create " .. (change.rel or change.path) .. ": " .. tostring(err),
          vim.log.levels.WARN
        )
      end
    end
    local orig_decide = led.decide
    function led.decide(self, block, action, line_delta)
      retouch()
      return orig_decide(self, block, action, line_delta)
    end
    local orig_decide_all = led.decide_all
    function led.decide_all(self, action)
      retouch()
      return orig_decide_all(self, action)
    end
    local orig_redo = led.redo_decision
    function led.redo_decision(self, block, action)
      retouch()
      return orig_redo(self, block, action)
    end
  end

  return {
    park_anchor = park_anchor,
    anchor_range = anchor_range,
    drop_anchor = drop_anchor,
    clear_extmarks = clear_extmarks,
    reject_block_at = reject_block_at,
    accept_block_at = accept_block_at,
    reject_hunk = reject_hunk,
    accept_hunk = accept_hunk,
    accept_all = accept_all,
  }
end

return M
