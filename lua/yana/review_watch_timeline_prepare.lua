-- One transient chronological interpretation of a queued native edit batch.
-- The ordinary watcher remains the sole publisher of ledger and register state.
local batch_factory = require("yana.review_watch_batch")
local ownership_factory = require("yana.review_watch_ownership")
local frame = require("yana.hunk_ledger_buffer_frame")
local splice = require("yana.hunk_anchor_splice")
local identity = require("yana.hunk_identity")

local M = {}

local function copy_array(source)
  local out = {}
  for i, value in ipairs(source or {}) do out[i] = value end
  return out
end

local function clone_state(state, ledger, scratch, timeline)
  local staged = {}
  for key, value in pairs(state) do staged[key] = value end
  staged.bufnr = scratch
  staged.hunk_ledger = ledger
  staged.model_hunks = vim.deepcopy(timeline.model_before)
  staged.decisions = copy_array(state.decisions)
  staged._ownership_dirty_rows = {}
  staged._timeline_stage = true
  staged._timeline_split_parents = {}
  staged._flush_paint = nil
  staged.change = {}
  for key, value in pairs(state.change or {}) do staged.change[key] = value end
  staged.change._retrace_absorbed = vim.deepcopy((state.change or {})._retrace_absorbed or {})
  return staged
end

function M.prepare(env, groups, timeline)
  local real = env.state
  local live_ledger = real.hunk_ledger
  assert(timeline and timeline.members_before and timeline:matches_live(real.bufnr),
    "watch timeline differs from live buffer")
  -- The live callback is allowed to transport old members while the Insert
  -- session is open. Replaying those exact captured splices on a private copy
  -- gives the pre-publication state those same live members must still have.
  local transport = vim.deepcopy(timeline.ledger_before)
  transport.dirty_callback = nil
  for _, change in ipairs(timeline.changes) do
    transport:record_buffer_change(change)
  end
  local expected_transport = {}
  for i, original in ipairs(timeline.real_members) do
    expected_transport[original] = frame.snapshot(transport:members()[i]).fields
  end
  -- A private parser buffer is needed because the sole ownership classifier
  -- and the existing batch both read a bufnr. Suppress user autocmds for its
  -- entire lifetime; the normal buffer is never switched or edited here.
  local prior_eventignore = vim.o.eventignore
  vim.o.eventignore = "all"
  local made, scratch = pcall(vim.api.nvim_create_buf, false, true)
  if not made or type(scratch) ~= "number" or scratch < 1 then
    vim.o.eventignore = prior_eventignore
    error("watch timeline: scratch parser buffer creation failed: " .. tostring(scratch), 0)
  end
  local ok, result = pcall(function()
    local prepared_groups = {}
    for i, group in ipairs(groups) do
      local changes = {}
      for j, change in ipairs(group.changes) do
        local copy_change = {}
        for key, value in pairs(change) do
          if key ~= "_ledger_before" and key ~= "_batch_changes" then copy_change[key] = value end
        end
        changes[j] = copy_change
      end
      prepared_groups[i] = { marker = group.marker, seq = group.seq, changes = changes }
    end
    vim.bo[scratch].filetype = vim.bo[real.bufnr].filetype
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, timeline.before)
    local mark_ns = vim.api.nvim_create_namespace("yana_timeline_prepare")
    local function mark_new(block, first, last)
      assert(type(first) == "number" and type(last) == "number",
        "watch timeline: no exact endpoint range for staged mark")
      local start_row = math.max(first - 1, 0)
      local end_row = math.max(last - 1, start_row)
      block._timeline_mark_id = vim.api.nvim_buf_set_extmark(scratch, mark_ns,
        start_row, 0, { end_row = end_row, end_col = 0,
          right_gravity = false, end_right_gravity = true })
      block._timeline_provenance = "derived_from_live"
    end
    local function mark_range(block)
      local id = block._timeline_mark_id
      assert(id, "watch timeline: staged block has no native mark")
      local ext = vim.api.nvim_buf_get_extmark_by_id(scratch, mark_ns, id, { details = true })
      assert(ext and ext[1] ~= nil, "watch timeline: staged native mark vanished")
      local first = ext[1] + 1
      local last = ((ext[3] or {}).end_row or ext[1]) + 1
      if #(block.new_lines or {}) == 0 then last = first - 1 end
      return first, last
    end
    local function raw_mark_range(id)
      local ext = vim.api.nvim_buf_get_extmark_by_id(scratch, mark_ns, id, { details = true })
      assert(ext and ext[1] ~= nil, "watch timeline: prepared decision anchor vanished")
      return ext[1] + 1, ((ext[3] or {}).end_row or ext[1]) + 1
    end
    local real_to_stage, stage_to_real = {}, {}
    local hunks = timeline.members_before
    for i, original in ipairs(timeline.real_members) do
      local staged = hunks[i]
      real_to_stage[original] = staged
      stage_to_real[staged] = original
      local range = timeline.live_before[i]
      assert(range and range.first, "watch timeline: missing live parent range")
      mark_new(staged, range.first, range.last)
      staged._timeline_provenance = "captured_live"
    end
    local seqs = {}
    for _, group in ipairs(prepared_groups) do seqs[group.seq] = true end
    local ids = identity.stage_ids()
    local history = timeline.history_before:stage_copy(seqs, real_to_stage, timeline.seq_before)
    local ledger = timeline.ledger_before
    ledger.buffer_history = history
    ledger.identity_stage = ids
    ledger.dirty_callback = nil
    ledger._timeline_stage = true
    ledger.anchor_collisions = nil
    local state = clone_state(real, ledger, scratch, timeline)
    state._timeline_mark_new = function(block)
      mark_new(block, block.new_start_line, block.new_end_line)
    end
    state._timeline_anchor_new = function(effect)
      local count = vim.api.nvim_buf_line_count(scratch)
      local first = math.min(math.max(effect.first, 1), count)
      local last = math.min(math.max(effect.last, first), count)
      mark_new(effect, first, last)
    end
    local current_seq = timeline.seq_before
    local deps = {}
    for key, value in pairs(env.deps) do deps[key] = value end
    deps.buf_undo_seq = function() return current_seq end
    deps.live_block_range = function(_, block)
      return mark_range(block)
    end
    local owner = ownership_factory.new(scratch, state)
    state._row_is_yana_owned = owner.interior_line_is_yana_owned
    local batch = batch_factory.new({ deps = deps, state = state, bufnr = scratch,
      edge_line_is_yana_owned = owner.edge_line_is_yana_owned,
      interior_line_is_yana_owned = owner.interior_line_is_yana_owned })
    local effects, actions = {}, {}
    state._decide_destroyed_hunk = function(block, index, delta, pre_seq, reason)
      local effect = require("yana.review_decisions").prepare_destroyed_hunk(
        state, deps, block, index, delta, pre_seq, reason)
      if not effect then return false end
      state._timeline_anchor_new(effect)
      effects[#effects + 1] = effect
      return true
    end
    local states = timeline:states()
    local change_index = 0
    for _, group in ipairs(prepared_groups) do
      local dirty = {}
      for _, change in ipairs(group.changes) do
        change_index = change_index + 1
        local s = change.splice
        vim.api.nvim_buf_set_text(scratch, s.sr, s.sc, s.er, s.ec,
          change._timeline_inserted)
        dirty = splice.rows(s, dirty)
        local lo, hi = splice.touched(s)
        for row = lo or 1, hi or 0 do dirty[row] = true end
        ledger:record_buffer_change(change)
        for _, block in ipairs(ledger:members()) do
          local original = stage_to_real[block]
          local observed = original and change._timeline_live_after
            and change._timeline_live_after[original]
          if observed then
            local first, last = mark_range(block)
            assert(first == observed.first and last == observed.last,
              "watch timeline: native scratch mark differs from captured live endpoint")
          end
        end
      end
      current_seq = group.seq
      ledger:begin_buffer_group(group.marker, group.seq)
      local before_frames = history.last_before
      local before_seq = history.last_before_seq
      local prior_index = change_index - #group.changes
      state.staged_text = table.concat(prior_index == 0 and timeline.before
        or states[prior_index], "\n")
      local structural = {}
      local absorbed, remaining = batch.interpret(group.changes)
      if not absorbed then
        state.free_standing_edit = true
        structural = batch.repartition(remaining or group.changes) or {}
      end
      vim.list_extend(structural, require("yana.review_hunk_collision").merge(
        state, ledger:take_anchor_collisions()))
      batch.settle(group.changes)
      batch.absorb_on_insert_leave(dirty, group.seq, history.last_before_seq)
      for _, block in ipairs(ledger:members()) do
        assert(block._timeline_mark_id, "watch timeline: prepared member lacks native mark")
        block.authority_extmark_id = -1
      end
      vim.list_extend(structural, batch.repartition({}) or {})
      local action = require("yana.undo_action_buffer_edit").new({
        rel = state.change.rel or state.change.path,
        workspace = state.change.review_workspace or (state.opts or {}).workspace or vim.fn.getcwd(),
        turn_id = state.change.turn_id or state.change.turn_gen,
        undo_seq = group.seq,
      })
      local attach = require("yana.review_watch_register").new(deps).attach_structural
      for _, entry in ipairs(structural) do attach(state, action, entry) end
      actions[#actions + 1] = { action = action, structural = structural }
      ledger:finish_buffer_changes(group.seq, env.reachable)
      history:seal_exact_endpoint(group.seq, before_seq, before_frames, ledger:pending())
      state.staged_text = table.concat(states[change_index], "\n")
    end
    for _, effect in ipairs(effects) do
      effect.final_first, effect.final_last = raw_mark_range(effect._timeline_mark_id)
    end
    return { ledger = ledger, state = state, history = history, ids = ids,
      actions = actions, effects = effects, real_to_stage = real_to_stage,
      stage_to_real = stage_to_real, seqs = seqs,
      expected_transport = expected_transport, scratch = scratch }
  end)
  local deleted, delete_err = pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  vim.o.eventignore = prior_eventignore
  if not ok then
    error(tostring(result) .. (not deleted and ("; scratch cleanup: " .. tostring(delete_err)) or ""), 0)
  end
  if not deleted then error(delete_err, 0) end
  result.scratch = nil
  return result
end

local function copy_fields(block, original)
  local out = {}
  for key, value in pairs(block) do
    if (type(key) ~= "string" or key:sub(1, 10) ~= "_timeline_")
      and key ~= "authority_extmark_id"
      and key ~= "incoming_extmark_id" and key ~= "incoming_extmark_ids"
      and key ~= "delete_extmark_id" then
      out[key] = value
    end
  end
  if original then
    for _, key in ipairs({ "authority_extmark_id", "incoming_extmark_id",
      "incoming_extmark_ids", "delete_extmark_id" }) do
      out[key] = original[key]
    end
  end
  return out
end

local function shallow_fields(block)
  local out = {}
  for key, value in pairs(block) do out[key] = value end
  return out
end

function M.commit(env, prepared, timeline)
  local state, ledger = env.state, env.state.hunk_ledger
  assert(timeline:matches_live(state.bufnr), "watch timeline: buffer changed before publish")
  assert(timeline.generation == state._watch_generation,
    "watch timeline: attachment generation changed before publish")
  assert(timeline.changedtick == vim.api.nvim_buf_get_changedtick(state.bufnr),
    "watch timeline: unrecorded buffer change before publish")
  local final_snapshot = require("yana.diff").buffer_bytes_snapshot(state.bufnr)
  local final_seq = env.deps.buf_undo_seq(state.bufnr)
  assert(final_snapshot ~= nil and type(final_seq) == "number",
    "watch timeline: final native endpoint unreadable")
  assert(#prepared.actions > 0
    and final_seq == prepared.actions[#prepared.actions].action.undo_seq,
    "watch timeline: native sequence changed before publish")
  local live_members = ledger:members()
  assert(#live_members == #timeline.real_members,
    "watch timeline: ledger membership changed during Insert session")
  for i, block in ipairs(live_members) do
    assert(block == timeline.real_members[i],
      "watch timeline: ledger identity changed during Insert session")
    assert(vim.deep_equal(frame.snapshot(block).fields, prepared.expected_transport[block]),
      "watch timeline: live ledger differs from captured edit transport")
  end
  local remap = {}
  for staged, original in pairs(prepared.stage_to_real) do remap[staged] = original end
  local function target(block)
    assert(type(block) == "table", "watch timeline: unresolved prepared block")
    if not remap[block] then remap[block] = block end
    return remap[block]
  end
  local members, fields = {}, {}
  for _, block in ipairs(prepared.ledger:members()) do members[#members + 1] = target(block) end
  local actions = {}
  for _, entry in ipairs(prepared.actions) do
    local action = entry.action
    for _, row in ipairs(action.hunk_merges or {}) do
      if row.kind == "hunk_split" then
        row.parent = target(row.parent)
        for i, child in ipairs(row.children) do row.children[i] = target(child) end
        row.model = state.model_hunks
        row.review_change = state.change
      elseif row.kind == "hunk_merge" then
        row.merged = target(row.merged)
        for i, member in ipairs(row.members) do row.members[i] = target(member) end
      else
        error("watch timeline: unresolved structural kind " .. tostring(row.kind))
      end
    end
    actions[#actions + 1] = action
  end
  local decisions = {}
  for i, decision in ipairs(prepared.state.decisions or {}) do
    if i > #(state.decisions or {}) then
      decision.block = target(decision.block)
    end
    decisions[i] = decision
  end
  for _, effect in ipairs(prepared.effects or {}) do effect.block = target(effect.block) end
  for seq in pairs(prepared.seqs) do
    local record = prepared.history.records[seq]
    if record then
      for block in pairs(record.before or {}) do target(block) end
      for block in pairs(record.after or {}) do target(block) end
      for block in pairs(record.before_members or {}) do target(block) end
    end
  end
  for staged, real in pairs(remap) do
    fields[real] = copy_fields(staged, prepared.stage_to_real[staged] and real or nil)
  end
  local history = ledger.buffer_history
  local history_result = history:stage_result(prepared.history, remap, prepared.seqs)
  local workspace = state.change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
  local register = require("yana.turn.turn_register").for_workspace(workspace)
  local start = timeline.register_before
  assert(start and register.actions == start.actions and register.cursor == start.cursor
    and register.owed == start.owed,
    "watch timeline: register changed during Insert session")
  local register_plan = register:prepare_push_many(actions)
  local action_map = {}
  for seq, action in pairs(state._buffer_edit_actions or {}) do action_map[seq] = action end
  for _, action in ipairs(actions) do
    assert(action_map[action.undo_seq] == nil,
      "watch timeline: duplicate native buffer action")
    action_map[action.undo_seq] = action
  end
  local old_members, old_fields = live_members, {}
  for block in pairs(fields) do old_fields[block] = shallow_fields(block) end
  local old_history = history:publication_snapshot()
  local old_actions = state._buffer_edit_actions
  local old_decisions = state.decisions
  local model_owner = require("yana.review_hunk_split")
  local old_model = model_owner.snapshot_model(state.model_hunks)
  local new_model = model_owner.snapshot_model(prepared.state.model_hunks)
  local old_retrace = state.change and state.change._retrace_absorbed
  local old_dirty = state._ownership_dirty_rows
  local committed_register = false
  local ok, err = pcall(function()
    local ids_ok, ids_err = prepared.ids:commit()
    assert(ids_ok, ids_err)
    ledger:publish_prepared_members(members, fields)
    history:publish_stage_result(history_result)
    model_owner.restore_model_snapshot(state.model_hunks, new_model)
    if state.change then
      state.change._retrace_absorbed = prepared.state.change._retrace_absorbed
    end
    state.decisions = decisions
    state._buffer_edit_actions = action_map
    local reg_ok, reg_err = register:commit_prepared(register_plan)
    assert(reg_ok, reg_err)
    committed_register = true
    state._ownership_dirty_rows = {}
  end)
  if not ok then
    if committed_register then register:rollback_prepared(register_plan) end
    ledger:publish_prepared_members(old_members, old_fields)
    history:restore_publication(old_history)
    model_owner.restore_model_snapshot(state.model_hunks, old_model)
    if state.change then state.change._retrace_absorbed = old_retrace end
    state.decisions, state._buffer_edit_actions = old_decisions, old_actions
    state._ownership_dirty_rows = old_dirty
    prepared.ids:rollback()
    error(err, 0)
  end
  state.staged_text = final_snapshot
  state.latest_undo_seq = final_seq
  state.watch_timeline = nil
  local function post(label, fn)
    local passed, post_err = pcall(fn)
    if not passed then
      pcall(require("yana.log").write, "WARN",
        "watch timeline: committed but " .. label .. " failed: " .. tostring(post_err))
    end
  end
  post("register log", function() register:log_prepared(register_plan) end)
  for _, effect in ipairs(prepared.effects or {}) do
    post("destroyed decision publication", function()
      local publish = state._publish_destroyed_effect
      assert(type(publish) == "function", "decision publisher missing")
      publish(effect, effect.final_first, effect.final_last)
    end)
  end
  post("modified state", function()
    env.deps.recompute_modified(state.bufnr, ledger:pending(), state.change and state.change.path)
  end)
  post("paint", function()
    ledger:request_paint()
    if state._flush_paint then state._flush_paint("buffer_watch_timeline") end
  end)
  post("undo trace", function()
    require("yana.review_undo_trace").capture("timeline_committed", state,
      { groups = #actions, seq = final_seq })
  end)
  return true
end

return M
