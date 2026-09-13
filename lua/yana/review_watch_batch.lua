-- Interprets one coalesced watcher batch against one file ledger.
local hunk_split_factory = require("yana.review_hunk_split")
local extent = require("yana.hunk_extent")
local partition_factory = require("yana.review_watch_batch_partition")
local insert_leave_factory = require("yana.review_watch_batch_insert_leave")
local M = {}

-- Pure policy: one relation, one answer. Merge/destruction are already marked
-- by their owning seams; this decides geometric hunk relevance only.
local function relation_is_yana(placement, relation)
  return relation.interior or placement == "spans" or placement == "bottom_edge"
end

function M.new(env)
  local deps = env.deps
  local state = env.state
  local bufnr = env.bufnr
  local edge_line_is_yana_owned = env.edge_line_is_yana_owned
  local interior_line_is_yana_owned = env.interior_line_is_yana_owned
  local hunk_split = hunk_split_factory.new(deps)
  local try_split = hunk_split.try_split
  local try_merge = hunk_split.try_merge
  local merge_gap_pair = hunk_split.merge_gap_pair
  local splice = require("yana.hunk_anchor_splice")
  local anchor_bounds = require("yana.hunk_ledger_settle").anchor_bounds

  local function line_at(row)
    return (vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false) or {})[1]
  end

  local function live_rows(first, last)
    return vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  end

  -- What a completed edit changes outside the ledger: the authority mark no
  -- longer names the band (paint recreates it), the model mirror follows, and
  -- the retrace keeps the hunk's live text.
  local function after_complete(block, index)
    if block.authority_extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, deps.authority_ns, block.authority_extmark_id)
      block.authority_extmark_id = nil
    end
    local model_hunk = state.model_hunks and block.model_index and state.model_hunks[block.model_index]
    if model_hunk then
      model_hunk.new_count = #(block.new_lines or {})
      model_hunk.new_end_line = block.new_end_line
    end
    local change = state.change
    if type(change) == "table" then
      change._retrace_absorbed = change._retrace_absorbed or {}
      change._retrace_absorbed[block.model_index or index] = vim.deepcopy(block.new_lines or {})
    end
  end

  -- THE completed-edit call (hunk_ledger_settle.lua). The flush and InsertLeave
  -- both finish an edit through here and nowhere else.
  local function complete(block, index, decisions, changes, undo_seq, before_seq)
    local changed = state.hunk_ledger:complete_buffer_edit(block, {
      changes = changes,
      decisions = decisions,
      lines = live_rows,
      undo_seq = undo_seq or deps.buf_undo_seq(bufnr),
      before_seq = before_seq,
    })
    if changed then
      after_complete(block, index)
    end
    return changed
  end

  -- The rows a claimed change wrote (`splice.touched`), carried to the batch's
  -- final frame through every later change by the one transform, as PROVISIONAL
  -- owned decisions (F-OWN-PROVISION): InsertLeave settles them. A row the hunk
  -- already owns keeps the anchor it has; a claim only ever adds members.
  local function claim_decisions(block, changes, claims)
    local decisions, seen = {}, {}
    for _, ci in ipairs(claims) do
      local lo, hi = splice.touched(splice.of(changes[ci]))
      for row = lo or 1, hi or 0 do
        local final = row
        for j = ci + 1, #changes do
          final = final and splice.point(splice.of(changes[j]), final)
        end
        if final and not seen[final] and not state.hunk_ledger:row_is_owned(block, final) then
          seen[final] = true
          decisions[#decisions + 1] = { row = final, owned = true, provisional = true, source = line_at(final) }
        end
      end
    end
    return decisions
  end

  -- Every pending hunk after one interpreted batch: rows move without any row
  -- changing owner, and the band follows its members (F-OWN-SHIFT).
  local function settle(changes)
    if not state.hunk_ledger or not state.hunk_ledger:is_open() then
      return
    end
    for index, block in ipairs(state.hunk_ledger:pending()) do
      complete(block, index, nil, changes)
    end
  end

    local function absorb_human_edits(changes)
	  local native_action_owns_batch = false
      -- Stamp every change with its place in THIS batch before anything reads
      -- rows out of `state.staged_text`. A later change's rows are in a frame
      -- the earlier changes already moved; `hunk_split_factory.unshift_row`
      -- carries them back, and without the stamp it cannot.
      hunk_split_factory.mark_batch(changes)
      -- MERGE VETO. A change that will merge two pending hunks must not first be
      -- swallowed by one of them: absorbing returns true and the watcher never reaches
      -- the refusal seam where try_merge lives. The predicate is try_merge's OWN
      -- (review_hunk_split.merge_gap_pair), so the two branches cannot drift.
      local hunk_related = {}
      local merge_gap = {}
      for change_index, change in ipairs(changes) do
        if merge_gap_pair(state, change) ~= nil then
          merge_gap[change_index] = true
          hunk_related[change] = true
        end
      end
      -- Capture this before the ordinary line-shift pass; the destruction edit's shift
      -- must be owned by Ledger:decide below, exactly once, or the later hunks move
      -- twice.
      local destroyed = {}
      local destruction_changes = {}
      for _, block in ipairs(state.hunk_ledger:pending()) do
        local live_start, live_end, range_err, collapsed = deps.live_block_range(bufnr, block)
        local start_line = block.new_start_line
        local end_line = block.new_end_line or start_line
        local before_lines = vim.split(state.staged_text or "", "\n", { plain = true })
        if before_lines[#before_lines] == "" then
          table.remove(before_lines)
        end
        local removed_lines = {}
        local overlapping = {}
        if start_line and end_line then
          for change_index, change in ipairs(changes) do
            local before = change._ledger_before and change._ledger_before[block]
            local overlap_block_start = (before and before.start_line) or start_line
            local overlap_block_end = (before and before.end_line) or end_line
            local first_line = change.first + 1
            local last_orig = change.last_orig
            local overlap_start = math.max(first_line, overlap_block_start)
            local overlap_end = math.min(last_orig, overlap_block_end)
            if change.last_new < change.last_orig and overlap_start <= overlap_end then
              for row = overlap_start, overlap_end do
                -- `before_lines` is the PRE-BATCH snapshot; `row` is in this
                -- change's own (already shifted) frame. Carry it back, or the
                -- second deletion of a `:g//d` reads the line above the one it
                -- removed, the hunk's own text never matches, and a destroy is
                -- misread as a gap deletion.
                local staged_row = hunk_split_factory.unshift_row(change, row)
                if staged_row == hunk_split_factory.NO_PREIMAGE then
                  -- This row was BORN inside the batch (an earlier change
                  -- inserted or replaced it), so `before_lines` holds no line
                  -- for it and the row number lands on an unrelated pending
                  -- line. Keep the slot -- the offset-by-offset test below
                  -- compares position for position -- but fill it with a value
                  -- that is not a line, so this deletion can never be counted
                  -- as having removed one of the hunk's own rows.
                  removed_lines[#removed_lines + 1] = hunk_split_factory.NO_PREIMAGE
                else
                  removed_lines[#removed_lines + 1] = before_lines[staged_row]
                end
              end
              overlapping[change_index] = true
            end
          end
        end
        local live_matches = false
        if live_start and live_end and live_end >= live_start then
          local live = vim.api.nvim_buf_get_lines(bufnr, live_start - 1, live_end, false)
          live_matches = deps.lines_equal(live, block.new_lines or {})
        end
        local fully_removed = #(block.new_lines or {}) > 0
          and #removed_lines >= #(block.new_lines or {})
          and not live_matches
        if fully_removed then
          for offset, line in ipairs(block.new_lines or {}) do
            if removed_lines[offset] ~= line then
              fully_removed = false
              break
            end
          end
        end
        local destruction_error = range_err
          or (collapsed and "hunk invalidated: extmark range collapsed")
          or (fully_removed and "hunk invalidated: lines deleted")
        -- A range error alone is not proof that this batch destroyed the
        -- hunk. An outside gap/EOF deletion can collapse an extmark's edge
        -- while leaving the live hunk intact; only a deletion overlapping
        -- the hunk's stored span may claim the change as destruction.
        if destruction_error and next(overlapping) ~= nil then
          range_err = destruction_error
          local info = { error = range_err, changes = {} }
          destroyed[block] = info
          for change_index in pairs(overlapping) do
            info.changes[change_index] = true
            destruction_changes[change_index] = true
            hunk_related[changes[change_index]] = true
          end
        end
      end

      local claimed = {}
      for index, block in ipairs(state.hunk_ledger:pending()) do
        local tracked_live = block.authority_extmark_id ~= nil
        -- One extent per PENDING hunk per flush, discarded with this loop
        -- (hunk_extent.lua's own scope rule).
        local block_extent = extent.new(bufnr, block, state._row_is_yana_owned, {
          live_range_fn = deps.live_block_range,
        })
        local start_line, end_line, range_err, collapsed = deps.live_block_range(bufnr, block)
        range_err = range_err or (collapsed and "hunk invalidated: extmark range collapsed")
        local destroyed_info = destroyed[block]
        if destroyed_info then
          range_err = destroyed_info.error
          start_line = nil
          end_line = nil
        end
        local extends_block = false
        local extra_lines = 0
        local refused_edge = false
        local leading_shift = 0
        -- The band this batch has ALREADY given the hunk that its transported
        -- band does not carry: rows a claimed leading insert put above its
        -- start and rows a claimed trailing insert added below its end.
        local frame_lead = 0
        local frame_growth = 0
        local claims = {}
        for change_index, change in ipairs(changes) do
          -- LEADING BAND RETRACTION. `leading_shift` counts rows THIS batch has
          -- already put ABOVE the hunk's stored start, so those rows occupy
          -- `[start_line, start_line + leading_shift - 1]` and the hunk's own
          -- first row now sits at `effective_start`. A later change in the SAME
          -- batch can delete those rows again -- insert `X` above the hunk, then
          -- delete `X` -- and then the band is gone but the count is not.
          -- Leaving it standing pushes `effective_start` past the hunk's own
          -- first row, so every later change reads as being ABOVE the hunk: a
          -- plain replacement of the hunk's own line is classified `below`,
          -- never claimed, and the hunk goes on to absorb an EMPTY live range,
          -- silently dropping the user's edit out of the proposal. The
          -- retraction below is the exact inverse of the accounting the leading
          -- claim further down applied when those rows arrived.
          local band_rows = 0
          if start_line
            and leading_shift > 0
            and change.last_new < change.last_orig
            and change.first + 1 >= start_line
            and change.last_orig <= start_line + leading_shift - 1
          then
            band_rows = change.last_orig - change.last_new
          end
          if band_rows > 0 then
            leading_shift = math.max(0, leading_shift - band_rows)
            frame_lead = math.max(0, frame_lead - band_rows)
            if not tracked_live then
              -- An untracked block's leading claim moved `end_line` by the same
              -- rows it moved `start_line` by; the retraction returns both.
              extra_lines = extra_lines - band_rows
            end
            -- This batch's own bookkeeping has fully accounted for the change.
            -- Leaving it unclaimed would send it to the refusal seam as an
            -- unowned human edit, which it is not.
            claimed[change_index] = true
          elseif start_line then
            local effective_start = start_line + leading_shift
            local effective_end = end_line + extra_lines
            -- Classify ONCE, in the frame this change was typed into: the
            -- ledger's geometry as captured just before it (already shifted by
            -- every earlier change at or above the hunk, never by this one)
            -- plus the growth earlier claimed changes in this batch produced.
            -- The live extmark is the wrong frame here: it has already moved
            -- with THIS change, so a whole-line deletion directly above the
            -- hunk reads as interior there. Absorption and register
            -- attribution consume this same answer.
            local before = change._ledger_before and change._ledger_before[block]
            local place, rel = block_extent:placement({
              first = change.first,
              last_orig = change.last_orig,
              last_new = change.last_new,
              start_line = before and (before.start_line - frame_lead) or effective_start,
              end_line = before and (before.end_line + frame_growth) or effective_end,
            })
            -- An unowned leading edge is outside the hunk. Interior/spanning
            -- edits can reach the split path; the trailing edge remains
            -- Yana-connected because the pending hunk can claim that EOF
            -- insertion. Merge and destruction are marked at their seams.
            if relation_is_yana(place, rel) then
              hunk_related[change] = true
            end
            -- The BOOLEANS, not the single label: a hunk with no new_lines has
            -- end_line == start_line - 1, so one pure insert is BOTH leading
            -- and trailing there and both branches below must still run.
            local pure_insert = rel.pure_insert
            local leading_insert = rel.leading_insert
            -- A row inserted above the hunk is judged by the classifier alone
            -- (F-OWN-ONE, F-OWN-SHIFT): no content match with the first
            -- proposal row and no borrowed anchor claims it, so a pasted copy
            -- of that row is a new candidate (F-OWN-DEF).
            local leading_owned = leading_insert
              and edge_line_is_yana_owned(effective_start, effective_start + 1)
            if leading_insert then
              refused_edge = refused_edge or not leading_owned
              leading_shift = leading_shift + math.max(0, change.last_new - change.first)
              effective_start = start_line + leading_shift
            end
            -- Interior bound MUST use the live authority range (see hunk_extent.lua's
            -- `M.relation`). A trailing pure insert is decided by the edge rule below
            -- and is never interior.
            --
            -- `merge_gap` stays HERE, not in the extent: it is the MERGE VETO
            -- (caller policy), not geometry.
            local trailing_insert = rel.trailing_insert
            local interior = rel.interior and not merge_gap[change_index]
            local interior_line_insert = interior
              and pure_insert
              and change.last_new > change.first
            -- A human does not materialise a finished line; they open a blank one and
            -- type into it. An in-place change to a row this hunk does not own as an
            -- AGENT row is that same human line, still under adjudication, so it faces
            -- the parent test too. It is legal only as the ancestor test's OWN
            -- no-parser fallback (`interior_line_is_yana_owned`'s tail), never as a
            -- shortcut that skips the ancestor test here: doing so let a fresh
            local interior_owned = interior and interior_line_is_yana_owned(change.first + 1)
            local trailing_owned = trailing_insert
              and edge_line_is_yana_owned(effective_end + 1, effective_end)
            if trailing_insert then
              refused_edge = refused_edge or not trailing_owned
            end
            local owned_leading = leading_insert and leading_owned
            local owned_trailing = trailing_insert and trailing_owned
            -- In-place text is absorbed only on a row the hunk already owns; on any
            -- other interior row it faces the same parent test.
            if interior_owned then
              -- No frame growth: the band grew with this change's own transport.
              extends_block = true
              claimed[change_index] = true
              claims[#claims + 1] = change_index
              if not tracked_live then
                extra_lines = extra_lines + (change.last_new - change.last_orig)
              end
            elseif owned_trailing or owned_leading then
              extends_block = true
              claimed[change_index] = true
              claims[#claims + 1] = change_index
              if owned_leading then
                frame_lead = frame_lead + math.max(0, change.last_new - change.first)
              else
                frame_growth = frame_growth + math.max(0, change.last_new - change.last_orig)
              end
              if owned_trailing or not tracked_live then
                extra_lines = extra_lines + math.max(0, change.last_new - change.last_orig)
              end
            end
          end
        end

        -- Classification decided which changes are this hunk's; the edit is
        -- completed from that answer and the band follows the members. A
        -- change this hunk did not claim moved it through the position remap
        -- and the settle pass (review_watch.lua) completes it.
        if start_line and extends_block then
          complete(block, index, claim_decisions(block, changes, claims), changes)
        end
        if refused_edge and block.authority_extmark_id then
          pcall(vim.api.nvim_buf_del_extmark, bufnr, deps.authority_ns, block.authority_extmark_id)
          block.authority_extmark_id = nil
        end
        if range_err then
          if destroyed_info then
            for change_index in pairs(destroyed_info.changes) do
              claimed[change_index] = true
            end
          end
          if state._decide_destroyed_hunk then
            native_action_owns_batch = state._decide_destroyed_hunk(
              block,
              index,
              0,
              state.latest_undo_seq or deps.buf_undo_seq(bufnr),
              range_err
            ) == true or native_action_owns_batch
          end
        end
      end
      local unclaimed = {}
      for index = 1, #changes do
        if not claimed[index] then
          unclaimed[#unclaimed + 1] = changes[index]
        end
      end
      if #unclaimed == 0 then
        return true, nil, nil, native_action_owns_batch
      end
      local register_hunk_edit = false
      for _, change in ipairs(unclaimed) do
        if hunk_related[change] then
          register_hunk_edit = true
          break
        end
      end
      return false, unclaimed, register_hunk_edit, native_action_owns_batch
    end

  -- The split/merge partition lives in review_watch_batch_partition.lua and
  -- the InsertLeave membership in review_watch_batch_insert_leave.lua.
  local repartition = partition_factory.new({
    deps = deps,
    state = state,
    bufnr = bufnr,
    try_split = try_split,
    try_merge = try_merge,
  }).repartition
  local absorb_on_insert_leave = insert_leave_factory.new({
    deps = deps,
    state = state,
    bufnr = bufnr,
    interior_line_is_yana_owned = interior_line_is_yana_owned,
    line_at = line_at,
    anchor_bounds = anchor_bounds,
    complete = complete,
  }).absorb_on_insert_leave

  return {
    interpret = absorb_human_edits,
    repartition = repartition,
    absorb_on_insert_leave = absorb_on_insert_leave,
    settle = settle,
  }
end

return M
