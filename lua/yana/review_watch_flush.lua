-- Size split of review_watch.lua: the batch flush and the InsertLeave partition one attachment runs.
local M = {}

--- `env` carries exactly what the two functions closed over inside `attach`;
--- `owns()` answers for THIS attachment's generation.
function M.new(env)
  local deps = env.deps
  local state = env.state
  local owns = env.owns
  local batch = env.batch
  local push_buffer_edit = env.push_buffer_edit
  local attach_structural = env.attach_structural
  local reachable_seqs = env.reachable_seqs
  local clear_queue = env.clear_queue
  local diff = env.diff
  local absorb_human_edits = batch.interpret
  local function process_pending_watch()
    -- FIRST LINE, before anything is read off the state: a scheduled flush
    -- belonging to a retired attachment interprets nothing.
    if not owns() then
      clear_queue(state)
      return
    end
    if not state.watch_pending then
      return
    end
    state.watch_pending = false
    local changes = state.watch_changes or {}
    state.watch_changes = {}
    if state.watch_detached or state.closed or state.reload_restaging then
      return
    end
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    if not state.hunk_ledger or not state.hunk_ledger:is_open() then return end
    -- ONE SCHEDULED FLUSH IS NOT ONE NATIVE SEQUENCE. `vim.schedule` fires
    -- once per event-loop turn, so a synchronous mapping that closes one undo
    -- sequence and opens another before yielding delivers BOTH sequences'
    -- changes to a single flush. Interpreting them together pushed one action
    -- and finished one record for two sequences -- measured on the real
    -- watcher as `SEQ_BATCH base=1 first=2 second=3 record_first=false
    -- record_second_before=1 rows=1` -- which breaks the group law
    -- (2026-09-06): a group's boundaries are the NATIVE sequence's, never the
    -- timer's. So the queue is partitioned by the sequence each callback
    -- stamped on its change, and capture selection, interpretation, the
    -- register push and `finish` all run once PER SEQUENCE, in arrival order.
    local groups, order = {}, {}
    for _, change in ipairs(changes) do
      local key = change.undo_marker
      if key == nil then key = false end
      local group = groups[key]
      if not group then
        group = { marker = change.undo_marker, changes = {} }
        groups[key] = group
        order[#order + 1] = group
      end
      group.changes[#group.changes + 1] = change
    end
    -- MARKERS SEPARATE THE GROUPS; THE LABELS COME FROM HERE, because a marker
    -- means one of two things and the flush is the first place that can tell
    -- them apart:
    --
    --   ALREADY SEALED when the callback ran (`nvim_buf_set_lines` after an
    --   undo break, an `:s` command): the marker is the sequence the change
    --   CREATED, and it is therefore above the sequence this ledger last
    --   finished on.
    --
    --   STILL IN FLIGHT (insert mode: every keystroke reports the pre-insert
    --   sequence): the marker is the sequence the change DEPARTED FROM, and
    --   sits at or below the last finished one.
    --
    -- A group still in flight ends on the state its successor departed from
    -- -- the successor's marker -- or, with no successor, on the buffer's
    -- sequence now, read after every queued change has landed. Labelling a
    -- sealed marker that way instead gave two groups ONE label and collapsed
    -- them right back into one record and one register row.
    local flush_seq = deps.buf_undo_seq(state.bufnr)
    local previous = state.hunk_ledger:observed_buffer_seq()
    for i, group in ipairs(order) do
      local label
      if type(group.marker) == "number"
        and (type(previous) ~= "number" or group.marker > previous)
      then
        label = group.marker
      else
        local successor = order[i + 1]
        label = successor and successor.marker or nil
        if type(previous) == "number" and type(label) == "number" and label <= previous then
          label = nil
        end
      end
      if type(label) ~= "number" then
        label = flush_seq
      end
      group.seq = label
      previous = label
    end
    -- Read ONCE, after every queued change has landed: the reachable set is a
    -- property of the buffer as it stands now, and every group is pruned
    -- against the same reading.
    local reachable = reachable_seqs(state.bufnr)
    -- INTERPRETATION STAYS WHOLE; THE RECORD AND THE REGISTER ARE PARTITIONED.
    -- A hunk split is decided by reading a batch of changes against each
    -- other, and Neovim seals a native sequence part-way through one: a typed
    -- interior split arrives as `markers=2x2,3x17` -- two sequences, one
    -- split. Interpreting the two changes of the first sequence on their own
    -- refuses them, sets `free_standing_edit` and repartitions a fragment, and
    -- the split is lost (measured: `r_v2_r18_retype`, `r_hunksplit_merge_back_
    -- after_typed_split`, `r_paint_bof_module_ownership[created]` and
    -- `r_paint_multi_file_undo_band` all went red on it). So `interpret` still
    -- sees the whole queue, under the FIRST group -- the state before the
    -- whole flush, which is the pre-edit geometry a destroyed-hunk decision
    -- has always been given -- while `History:finish` and the register push
    -- run once per native sequence below, which is where the
    -- one-sequence/one-action boundary actually lives.
    state.hunk_ledger:begin_buffer_group(order[1].marker, order[1].seq)
    -- Interpretation is NOT partitioned (see above); the membership changes it
    -- makes are filed under their own change's native sequence below.
    local structural_records = {}
    do
      local absorbed, remaining_changes = absorb_human_edits(changes)
      if not absorbed then
        remaining_changes = remaining_changes or changes
        state.free_standing_edit = true
        -- SEAM: repartition hangs off the REFUSAL branch, never the absorb
        -- branch above. `absorb_human_edits` claims an interior insert only
        -- when `interior_owned` holds; the edit that actually splits a
        -- hunk fails that test and lands here, unclaimed.
        structural_records = batch.repartition(remaining_changes) or {}
      end
    end
    -- Two hunks' anchors on one row merge, claimed change or not (F-SPLIT-MERGE).
    vim.list_extend(structural_records, require("yana.review_hunk_collision").merge(state, state.hunk_ledger:take_anchor_collisions()))
    -- Rows move without changing owner: every pending hunk's band follows its
    -- members, recorded under this group, before any group closes.
    batch.settle(changes)
    local function group_key(group)
      local key = group.marker
      if key == nil then key = false end
      return key
    end
    for i, group in ipairs(order) do
      state.hunk_ledger:begin_buffer_group(group.marker, group.seq)
      -- EVERY native editor undo sequence gets its buffer action, including
      -- one whose consequence was a hunk destroyed outright. The
      -- destroyed-hunk decision records what it decided, but it is not a
      -- substitute for this row: one editor command a user undoes with one
      -- press has to resolve to one reversible action, and `u` resolves
      -- `BufferEditAction` by `kind == "buffer_edit"`. Skipping the push here
      -- is what left a full deletion with a `decision` row and no buffer
      -- action to reverse.
      local buffer_action = push_buffer_edit(state, group.seq)
      -- A record rides the sequence of the change that qualified it (the same
      -- key the groups were built on); a record whose change was never grouped
      -- rides the LAST group rather than being dropped -- an unrecorded
      -- membership change is the defect itself.
      for _, entry in ipairs(structural_records) do
        if not entry._filed then
          local key = entry.change and entry.change.undo_marker
          if key == nil then key = false end
          if key == group_key(group) or i == #order then
            entry._filed = true
            attach_structural(state, buffer_action, entry)
          end
        end
      end
      -- ONE call closes ONE sequence's group. The ledger's records describe
      -- NATIVE undo states and Neovim discards those as `undolevels` fills,
      -- so the record this group writes and the death of the records the
      -- buffer can no longer reach are the same event and are applied
      -- together. This is the one place that has both the buffer and the
      -- ledger: reading `undotree()` is THIS side's job (`reachable_seqs`),
      -- and the ledger receives the answer as a value so it never learns what
      -- a buffer is.
      local _, pruned_ok = state.hunk_ledger:finish_buffer_changes(group.seq, reachable)
      if pruned_ok == false then
        -- RETENTION IS CORRECT and the silence was not: an unreadable
        -- `undotree()` keeps every record (the only safe answer) but the
        -- caller discarded the report, so a buffer whose reachability can
        -- never be read again retained without a trace anyone could find.
        require("yana.log").write("WARN", string.format(
          "review_watch: buffer history retained unpruned, undotree() unreadable (bufnr=%s seq=%s)",
          tostring(state.bufnr), tostring(group.seq)))
      end
    end
    deps.recompute_modified(state.bufnr, state.hunk_ledger:pending(), state.change and state.change.path)
    -- This site asks for the ONE coalesced repaint instead of calling the painter
    -- itself.
    state.hunk_ledger:request_paint()
    if state._flush_paint then
      state._flush_paint("buffer_watch")
    end
    local snapshot = diff.buffer_bytes_snapshot(state.bufnr)
    if snapshot then
      state.staged_text = snapshot
      state.latest_undo_seq = deps.buf_undo_seq(state.bufnr)
    end
  end

  -- F-OWN-TRIGGER / F-OWN-HEAL: InsertLeave re-resolves ONLY the insert-touched
  -- rows and absorbs owned ones into the parent via complete_buffer_edit.
  local function on_insert_leave_ownership()
    if not owns() then
      return
    end
    if state.watch_detached or state.closed or state.watch_suspended then
      return
    end
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    if not state.hunk_ledger or not state.hunk_ledger:is_open() then
      return
    end
    -- DRAIN THE PENDING FLUSH FIRST, now that insert has ended and the native
    -- sequence has SEALED. A flush deferred until here labels the in-flight
    -- group with the sealed sequence (buf_undo_seq now) and pushes its text
    -- BufferEditAction under that same sequence -- the one the absorb below
    -- rides. Without this drain the flush runs later, off its own schedule,
    -- and can leave the text action under a provisional pre-seal sequence that
    -- `<C-r>` never reaches.
    if state.watch_pending then
      process_pending_watch()
    end
    local dirty = state._ownership_dirty_rows
    if type(dirty) ~= "table" or next(dirty) == nil then
      return
    end
    -- PARTITION BY NATIVE SEQUENCE. Each dirty row carries the marker its edit
    -- departed from; rows sharing a marker share a native sequence. An
    -- in-flight group's SEALED sequence is its successor's marker, or -- for
    -- the last group -- the buffer's sequence now. This mirrors
    -- process_pending_watch's own labelling, so each absorbed row is recorded
    -- under, and rides the SAME BufferEditAction as, its own text. Recording
    -- every row under the last sequence let one `u` peel two sequences'
    -- ownership at once; per-sequence recording peels exactly one line's text
    -- and its ownership together, in lockstep (UNDO.md acceptance example).
    local cur_seq = deps.buf_undo_seq(state.bufnr)
    local by_marker = {}
    for row, m in pairs(dirty) do
      if type(row) == "number" then
        local set = by_marker[m]
        if not set then
          set = {}
          by_marker[m] = set
        end
        set[row] = true
      end
    end
    local numeric = {}
    for m, _ in pairs(by_marker) do
      if type(m) == "number" then
        numeric[#numeric + 1] = m
      end
    end
    table.sort(numeric)
    local seq_for = {}
    for i, m in ipairs(numeric) do
      seq_for[m] = numeric[i + 1] or cur_seq
    end
    -- Absorb in chronological order (ascending sealed sequence); the `false`
    -- marker (unreadable seq) rides the current sequence, last.
    local groups = {}
    for _, m in ipairs(numeric) do
      groups[#groups + 1] = m
    end
    if by_marker[false] then
      groups[#groups + 1] = false
    end
    local last_seq = nil
    for _, m in ipairs(groups) do
      local seq = (m ~= false) and seq_for[m] or cur_seq
      -- The frame's before_seq is the sequence this burst DEPARTED FROM -- its
      -- own marker -- because that is the sequence native undo lands on when
      -- `u` reverses `seq`, and `transition_for` pairs the redo of `seq` with
      -- `before_seq == current_seq`. Dating it from the ledger's stale observed
      -- seq (the default) leaves redo unable to restore the ownership.
      local before_seq = (m ~= false) and m or nil
      batch.absorb_on_insert_leave(by_marker[m], seq, before_seq)
      -- The absorbed frame is keyed under `seq`; a BufferEditAction under the
      -- same seq is the register row `u`/`<C-r>` walk to reverse/replay it.
      -- Dedupes with the flush's own text action for this sequence, so the
      -- ownership peel rides the text (F-OWN-HEAL: same native undo).
      if type(seq) == "number" then
        push_buffer_edit(state, seq)
      end
      last_seq = seq
    end
    state._ownership_dirty_rows = {}
    -- Paint first so authority marks match the absorbed spans; try_split
    -- requires live provenance (F-OWN-HEAL: absorb, then split at human
    -- boundaries in existing files).
    state.hunk_ledger:request_paint()
    if state._flush_paint then
      state._flush_paint("ownership_insert_leave")
    end
    local created_file = type(state.change) == "table" and state.change.before == nil
    if not created_file then
      local structural = batch.repartition({}) or {}
      local seq = last_seq or cur_seq
      local action = nil
      if type(seq) == "number" then
        action = push_buffer_edit(state, seq)
      end
      if type(action) == "table" then
        for _, entry in ipairs(structural) do
          attach_structural(state, action, entry)
        end
      end
      if #structural > 0 then
        state.hunk_ledger:request_paint()
        if state._flush_paint then
          state._flush_paint("ownership_insert_leave_split")
        end
      end
    end
    local snapshot = diff.buffer_bytes_snapshot(state.bufnr)
    if snapshot then
      state.staged_text = snapshot
      state.latest_undo_seq = deps.buf_undo_seq(state.bufnr)
    end
  end

  return {

    process_pending_watch = process_pending_watch,

    on_insert_leave_ownership = on_insert_leave_ownership,

  }

end



return M
