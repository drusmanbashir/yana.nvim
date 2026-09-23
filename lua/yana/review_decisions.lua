-- Per-hunk and file-level decisions for one open inline review.
local M = {}

-- One semantic owner for a native edit that destroys a pending hunk. It may
-- run on the live ledger or on the watcher's private chronological ledger.
-- External anchor/log/Turn effects are published only after the live mutation
-- or the prepared transaction has committed.
function M.prepare_destroyed_hunk(state, deps, block, idx, line_delta, pre_seq, reason)
  local ledger = state.hunk_ledger
  if not ledger or not ledger:owns(block) then return nil end
  local recorded = ledger.pre_edit_state and ledger:pre_edit_state(block) or nil
  local first = recorded and recorded.start_line or block.new_start_line
  local last = (recorded and recorded.end_line) or block.new_end_line or first
  ledger:decide(block, "reject", line_delta)
  if ledger.record_destroyed_hunk then
    ledger:record_destroyed_hunk(block, deps.buf_undo_seq(state.bufnr))
  end
  local seq = deps.buf_undo_seq(state.bufnr)
  local entry = { action = "reject", idx = idx, block = block, delta = line_delta,
    pre_seq = pre_seq, post_seq = seq, owner_kind = "buffer_edit", owner_seq = seq }
  state.decisions[#state.decisions + 1] = entry
  return { entry = entry, block = block, idx = idx, first = first, last = last,
    reason = reason, is_last = ledger:count() == 0 }
end

function M.publish_destroyed_hunk(effect, deps, state, facade, first, last)
  local block, idx = effect.block, effect.idx
  local change, bufnr = state.change, state.bufnr
  first, last = first or effect.first, last or effect.last
  deps.record_decision(state, "reject_hunk", {
    hunk = idx, model_index = block.model_index, model_join = block.model_join,
    row = effect.first, old_count = #(block.old_lines or {}),
    new_count = #(block.new_lines or {}), reason = effect.reason,
  })
  effect.entry.anchor = deps.park_decision_anchor(bufnr, first, last)
  if effect.is_last then deps.record_last_hunk_decided("reject", block) end
  facade._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "reject_hunk")
  facade._poll_leave_edge(state, "hunk_destroyed")
end

local function push_register_decision(state, change, count, payload)
  local row = {
    kind = "decision",
    rel = change.rel or change.path,
    workspace = change.review_workspace or (state and state.opts and state.opts.workspace) or vim.fn.getcwd(),
    turn_id = change.turn_id or change.turn_gen,
    count = count == nil and 1 or count,
  }
  for key, value in pairs(payload or {}) do
    row[key] = value
  end
  local ok, result = pcall(function()
    return require("yana.turn.turn_register"):push(row)
  end)
  if not ok then
    return false, tostring(result)
  end
  if result == false then
    return false, "turn register refused the decision row"
  end
  return true
end

--- `opts.history == false`: the caller's step (cA) carries history; no count=0 row.
function M.record_mode_decision(file, decision, opts)
  if type(file) ~= "table" or type(file.decide_mode) ~= "function" then
    return false, "review_decisions.record_mode_decision needs a File with decide_mode"
  end
  if type(decision) ~= "table" then
    return false, "review_decisions.record_mode_decision needs a decision table"
  end
  local change = file.change
  if type(change) ~= "table" or type(file.path) ~= "string" then
    return false, "review_decisions.record_mode_decision needs the exact File/change identity"
  end

  local previous_record = file.mode_verdict
  local ok, reason = file:decide_mode({
    proposal_key = decision.proposal_key,
    previous = decision.previous,
    next = decision.next,
    policy = decision.policy,
    asked = decision.asked,
  })
  if ok ~= true then
    return false, reason
  end

  if type(opts) == "table" and opts.history == false then
    return true
  end
  local pushed, push_err = push_register_decision(nil, change, 0, {
    file = file,
    file_path = file.path,
    change = change,
    change_id = file.change_id,
    mode = {
      proposal_key = decision.proposal_key,
      previous = decision.previous,
      next = decision.next,
      policy = decision.policy,
      asked = decision.asked,
      previous_record = previous_record,
    },
  })
  if not pushed then
    file.mode_verdict = previous_record
    return false, "review_decisions.record_mode_decision could not record history: " .. tostring(push_err)
  end
  return true
end

function M.record_operation_decision(file, verdict, state)
  if type(file) ~= "table" or type(file.decide_operation) ~= "function" then
    return false, "review_decisions.record_operation_decision needs a File with decide_operation"
  end
  local change = file.change
  if type(change) ~= "table" or type(file.path) ~= "string" then
    return false, "review_decisions.record_operation_decision needs the exact File/change identity"
  end
  local previous = file.operation_verdict or "pending"
  if previous == verdict then
    return true
  end
  local ok, reason = file:decide_operation(verdict)
  if ok ~= true then
    return false, reason
  end
  local transition = {
    file = file,
    file_path = file.path,
    change = change,
    change_id = file.change_id,
    previous = previous,
    next = verdict,
  }
  local pushed, push_err = push_register_decision(state, change, 0, { operation = transition })
  if not pushed then
    file:decide_operation(previous)
    return false, "review_decisions.record_operation_decision could not record history: " .. tostring(push_err)
  end
  return true
end

function M.new(deps)
  local state = deps.state
  local change = deps.change
  local bufnr = deps.bufnr
  local facade = deps.facade

  local function current_file()
    local pool = type(deps.pool_for) == "function" and deps.pool_for(state.opts or {}) or nil
    local turn = pool and require("yana.turn.turn_bind").get(pool) or nil
    local path = deps.diff.abs_path(change.path)
    return turn and turn:file(path) or nil
  end

  local function operation_transition(next_verdict)
    local file = current_file()
    if file == nil or file.operation == nil then
      return nil
    end
    local members = file.ledger and type(file.ledger.members) == "function" and file.ledger:members() or {}
    if #members > 0 or file.operation_verdict == next_verdict then
      return nil
    end
    return {
      file = file,
      file_path = file.path,
      change = file.change,
      change_id = file.change_id,
      previous = file.operation_verdict or "pending",
      next = next_verdict,
    }
  end

  local function apply_operation(transition, forward)
    if transition == nil then
      return true
    end
    local file = transition.file
    local expected = forward and transition.previous or transition.next
    local verdict = forward and transition.next or transition.previous
    if not rawequal(file.change, transition.change)
      or file.path ~= transition.file_path
      or file.change_id ~= transition.change_id
      or file.operation_verdict ~= expected
    then
      return false, "operation decision no longer names the same File state"
    end
    return file:decide_operation(verdict)
  end

  local function park_anchor(_, start_line, end_line)
    return deps.park_decision_anchor(bufnr, start_line, end_line)
  end

  local function reject_destroyed_hunk(block, idx, line_delta, pre_seq, reason)
    local effect = M.prepare_destroyed_hunk(state, deps, block, idx, line_delta, pre_seq, reason)
    if not effect then return false end
    M.publish_destroyed_hunk(effect, deps, state, facade)
    return true
  end
  state._publish_destroyed_effect = function(effect, first, last)
    return M.publish_destroyed_hunk(effect, deps, state, facade, first, last)
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
    if state.hunk_ledger and state.hunk_ledger.frozen_for_end then
      return false, "turn is frozen for End"
    end
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
    if state.hunk_ledger and state.hunk_ledger.frozen_for_end then
      return false, "turn is frozen for End"
    end
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
    -- Accept changes membership only; the buffer already holds the proposed lines.
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
    vim.bo[bufnr].modified = true
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
      return reject_block_at(idx)
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
      return accept_block_at(idx)
    end
    -- ca/cr act on the hunk under the cursor only; a key that sometimes hits an
    -- off-screen sole pending hunk is what we refuse.
    deps.notify_one_line(
      "yana: cursor is not on a pending hunk — move onto one, then ca",
      vim.log.levels.WARN
    )
  end

  local function accept_all()
    if state.hunk_ledger and state.hunk_ledger.frozen_for_end then
      return false, "turn is frozen for End"
    end
    deps.record_decision(state, "accept_file", { hunks_remaining = state.hunk_ledger:count() })
    local pending_before = state.hunk_ledger:pending()
    local members = {}
    --
    -- Park anchors before decide_all removes the live pending ranges.
    local at_seq = deps.buf_undo_seq(bufnr)
    for i, block in ipairs(pending_before) do
      members[#members + 1] = {
        hunk = block.model_index or i,
        old_count = #(block.old_lines or {}),
        new_count = #(block.new_lines or {}),
      }
      local a_start, a_end = deps.live_block_range(bufnr, block)
      -- Dead live marks fall back to stored geometry; the history count stays exact.
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
    local operation = operation_transition("accepted")
    local operation_ok, operation_err = apply_operation(operation, true)
    if not operation_ok then
      deps.notify_one_line("yana: could not record operation decision: " .. tostring(operation_err), vim.log.levels.WARN)
      return false
    end
    local pushed, push_err = push_register_decision(state, change, #members, { operation = operation })
    if not pushed then
      apply_operation(operation, false)
      deps.notify_one_line("yana: could not record decision history: " .. tostring(push_err), vim.log.levels.WARN)
      return false
    end
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

  local function after_pending_edit(fn)
    return function(...)
      local ready, reason = require("yana.review_watch").finalize(bufnr, state)
      if not ready then
        deps.notify_one_line("yana: could not finish pending edit: " .. tostring(reason),
          vim.log.levels.WARN)
        return false
      end
      return fn(...)
    end
  end

  return {
    park_anchor = park_anchor,
    anchor_range = anchor_range,
    drop_anchor = drop_anchor,
    clear_extmarks = clear_extmarks,
    reject_block_at = after_pending_edit(reject_block_at),
    accept_block_at = after_pending_edit(accept_block_at),
    reject_hunk = after_pending_edit(reject_hunk),
    accept_hunk = after_pending_edit(accept_hunk),
    accept_all = after_pending_edit(accept_all),
  }
end

return M
