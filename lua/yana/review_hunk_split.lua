-- Hunk split/merge geometry, hung off review_watch's refusal seam.
--
-- Extracted out of review_watch.lua to keep that file under the 500-line
-- ceiling; the seam itself (calling these two functions only from the
-- watcher's REFUSAL branch) still lives there.
local extent = require("yana.hunk_extent")
local splice = require("yana.hunk_anchor_splice")
local ownership = require("yana.review_watch_ownership")
local anchor_bounds = require("yana.hunk_ledger_settle").anchor_bounds

local M = {}

-- THE BATCH FRAME. One watcher batch can carry SEVERAL on_lines changes, and
-- each one's `first`/`last_orig`/`last_new` are rows in the buffer as it stood
-- just before THAT change -- already moved by every earlier change in the same
-- batch. `state.staged_text` is the snapshot from before the WHOLE batch. So
-- reading the removed text out of `staged_text` with a later change's own rows
-- reads the wrong lines: `:g/.../d` deleting three rows top-down made the
-- second and third deletions read one and two rows too high, the destroyed-hunk
-- test then failed to match the hunk's own line, and the deletion fell through
-- to the gap-merge branch instead (r_atomic_group_reverses_with_same_boundaries).
--
-- `M.mark_batch` stamps each change with the list it belongs to and its place
-- in it, at the ONE seam that sees the whole batch (review_watch_batch's
-- `interpret`), and `M.unshift_row` walks that list backwards to carry a row
-- from a change's own frame back into the pre-batch frame `staged_text`
-- describes. A single-change batch (and any change never stamped) maps to
-- itself, so every existing single-deletion path is unchanged.
function M.mark_batch(changes)
  for index, change in ipairs(changes or {}) do
    if type(change) == "table" then
      change._batch_changes = changes
      change._batch_index = index
    end
  end
end

-- NO PREIMAGE. Not every row in a later change's frame came from before the
-- batch: a row an earlier change wrote or joined has no line in `staged_text`,
-- and the row number that happens to land there belongs to an unrelated
-- pre-batch line. The one transform's inverse (`hunk_anchor_splice.preimage`)
-- says so with this sentinel instead of guessing a number: a unique table,
-- never a row and never nil, so a caller that forgets it cannot index with it.
M.NO_PREIMAGE = splice.NO_PREIMAGE

function M.unshift_row(change, row)
  local batch = type(change) == "table" and change._batch_changes or nil
  local index = type(change) == "table" and change._batch_index or nil
  if type(batch) ~= "table" or type(index) ~= "number" or type(row) ~= "number" then
    return row
  end
  for j = index - 1, 1, -1 do
    if type(batch[j]) == "table" and type(batch[j].first) == "number" then
      row = splice.preimage(splice.of(batch[j]), row)
      if row == M.NO_PREIMAGE then
        return row
      end
    end
  end
  return row
end

-- THE MODEL MIRROR IS PART OF A SPLIT'S RECORD, so it is part of its inverse: a
-- mutation of `state.model_hunks` that no snapshot covers is one no `u` can take
-- back. These two functions are the one place that reads and writes that array
-- as a whole; `undo_action_split` calls `M.restore_model_snapshot` rather than
-- keeping a second copy of the rule. A SHALLOW ARRAY COPY IS LOSSLESS: no writer
-- mutates an existing entry table, each ASSIGNS a freshly-built one into a slot,
-- so holding the old entry by reference holds its old content too.
function M.snapshot_model(model)
  if type(model) ~= "table" then
    return nil
  end
  local out = { n = #model }
  for i = 1, out.n do
    out[i] = model[i]
  end
  return out
end

--- Restore an array snapshot IN PLACE -- the same table, never a replacement,
--- because `state.model_hunks` is held by reference in several places.
--- Slots above the snapshot's length are cleared, so an inverse gives the array
--- back its exact length as well as its exact contents.
function M.restore_model_snapshot(model, snap)
  if type(model) ~= "table" or type(snap) ~= "table" then
    return false
  end
  local high = #model
  if snap.n > high then
    high = snap.n
  end
  for i = 1, high do
    model[i] = snap[i]
  end
  return true
end

-- THE CHILDREN A SPLIT WOULD MAKE, and nothing else. A pure calculation over the
-- parent and the spans `hunk_extent`'s resolve tier already allocated: it reads no
-- state, touches no ledger and decides nothing about whether the split happens --
-- every refusal stays above it in `try_split`, and `hunk_extent_geometry.allocate`
-- remains the one owner of the base-range allocation this only copies out.
--
-- The ARRAY SEMANTICS are part of the answer and are kept exactly: each child
-- holds the span's own `old_lines` and `lines` tables BY REFERENCE, as the loop
-- inside `try_split` always did, so a caller that compared identity still sees
-- what it saw.
local function build_split_children(block, spans)
  local pure_insert_parent = #(block.old_lines or {}) == 0
  local children = {}
  for _, span in ipairs(spans) do
    -- The child is born with both or with neither.
    local child = {
      old_lines = span.old_lines,
      new_lines = span.lines,
      new_start_line = span.first,
      new_end_line = span.last,
    }
    if pure_insert_parent then
      -- A pure-insert parent has no base range to cut, so every child keeps
      -- the parent's own (empty) old span, byte-for-byte the behaviour this
      -- branch has always had.
      child.start_line = block.start_line
      child.end_line = block.end_line
    else
      -- DELETED-BELOW in base coordinates, computed by `hunk_extent
      -- .allocate`: the topmost child carries the whole deletion, every
      -- lower child is an empty base range parked just after it.
      child.start_line = span.old_start_line
      child.end_line = span.old_end_line
    end
    children[#children + 1] = child
  end
  return children
end

function M.new(deps)
  local function split_text_lines(text)
    if text == nil or text == "" then
      return {}
    end
    local lines = vim.split(text, "\n", { plain = true })
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines)
    end
    return lines
  end

  -- A SPLIT ADDS NOTHING TO THE MODEL MIRROR. The mirror is the agent's account
  -- of what it proposed; the runs a split cuts are the HUMAN's, so children get
  -- no slot and no index -- the contract `Ledger:split` already stamps and the
  -- one `review_open_bind`'s resume reads. Handing child 1 the parent's slot
  -- made the two owners disagree, and a reused slot is not a name: a dead
  -- parent's frame resolved to that child through it.
  --
  -- The retrace cache is what a split still owes the change: keyed by
  -- model_index, holding the parent's now-meaningless content.
  local function invalidate_retrace_cache(state, mi)
    if type(mi) ~= "number" then
      return
    end
    local change = state.change
    local absorbed = type(change) == "table" and change._retrace_absorbed
    if type(absorbed) == "table" then
      absorbed[mi] = nil
    end
  end

  -- SPLIT. A pending hunk whose live ownership partition now holds more than
  -- one run is split into one child per run. NEW SIDE: only PENDING hunks
  -- split; a decided hunk is frozen (the caller only ever offers pending
  -- blocks here).
  --
  -- `hunk_extent`'s RESOLVE tier answers with the spans it can justify and never
  -- declines; every decision to keep one hunk instead is an ordinary `if` right
  -- here, over that answer -- 0 or 1 run resolves to exactly one span, which the
  -- `#spans < 2` refusal below reads.
  local function try_split(state, block, classify)
    local bufnr = state.bufnr
    classify = classify or state._row_is_yana_owned
    local ext = extent.new(bufnr, block, classify, { live_range_fn = deps.live_block_range })
    -- `resolve` is TOTAL, so it would happily hand back the block's STORED bounds when
    -- the authority extmark is gone -- and a stored bound is precisely what the filmed
    -- defect painted. A split is a membership change; it is allowed only off LIVE
    -- truth. "collapsed" is live truth about a DEAD range and is refused for the same
    -- reason.
    if ext:provenance() ~= "live" then
      return false
    end
    local spans = ext:resolve()
    -- REFUSAL 2. One span is the member keeping its own extent -- not a split.
    if #spans < 2 then
      return false
    end
    -- NO CONTENT EXCEPTION. One committed hunk is ONE contiguous interval with one
    -- stable id and one verdict, so
    -- what the rows between two runs contain decides nothing here: ownership is
    -- the classifier's answer and it has already been given by the time the spans
    -- arrive.
    local children = build_split_children(block, spans)
    -- The old seam could drop an agent row because it allocated content by re-diff and
    -- the re-diff's cut points were not the ownership runs. The children above ARE the
    -- runs, so the cover is a tautology -- stated, not tested for.
    assert(#children == spans.runs, "hunk split: one child per ownership run")
    -- REFUSAL 9.
    if #children < 2 then
      return false
    end
    -- ============ THE SPLIT'S OWN INVERSE, read across the mutation ============
    -- Everything `Ledger:split` + the retrace invalidation are about to destroy
    -- is read HERE, before either runs, and the post-state is read after. The record
    -- is handed up to `repartition` -> `review_watch` and rides the causing
    -- change's own `BufferEditAction`, exactly as a merge record does; without it
    -- NO SEQUENCE OWNS THE SPLIT and `u` moves bytes while membership stands.
    local before_tag = { model_index = block.model_index, model_join = block.model_join }
    local model = state.model_hunks
    local model_before = M.snapshot_model(model)
    local review_change = state.change
    -- Keyed by the PARENT's model_index, which the invalidation below clears
    -- and which is nil'd on the block itself by `Ledger:split`.
    local retrace_key = block.model_index
    local retrace_before = nil
    if type(review_change) == "table" and type(review_change._retrace_absorbed) == "table" and retrace_key ~= nil then
      retrace_before = review_change._retrace_absorbed[retrace_key]
    end
    state.hunk_ledger:split(block, children)
    if state._timeline_stage then
      state._timeline_split_parents[block.lineage_id] = {
        parent = block, children = children, before = before_tag,
        decisions = #state.decisions,
      }
      for _, child in ipairs(children) do
        assert(type(state._timeline_mark_new) == "function",
          "watch timeline: staged child has no native mark owner")
        state._timeline_mark_new(child)
        -- The prepared child has no real extmark yet. This sentinel preserves
        -- the tracked-range branch while the injected reader supplies its
        -- private native range; it is removed before publication.
        child.authority_extmark_id = -1
      end
    end
    invalidate_retrace_cache(state, retrace_key)
    local after_tags = {}
    for i, child in ipairs(children) do
      after_tags[i] = { model_index = child.model_index, model_join = child.model_join }
    end
    return true, {
      kind = "hunk_split",
      parent = block,
      children = children,
      before = before_tag,
      after = after_tags,
      model = model,
      model_before = model_before,
      model_after = M.snapshot_model(model),
      review_change = review_change,
      retrace_key = retrace_key,
      retrace_before = retrace_before,
    }
  end

  -- The rows a change removed, read from the buffer snapshot staged just before
  -- the whole batch (`state.staged_text`). The change's own rows are in ITS
  -- frame, which for the second and later changes of a batch has already moved,
  -- so every row is carried back through `M.unshift_row` first.
  --
  -- Second return value: TRUE when at least one removed row had no pre-batch
  -- existence (`M.NO_PREIMAGE`). Such a row is not a base line, so it is left
  -- out of the answer -- but its absence also means the answer is no longer a
  -- faithful account of what the change removed, and callers that reason about
  -- WHICH line was removed must not treat it as one.
  local function collect_deletion(state, change)
    if change.last_orig <= change.first then
      return {}, false
    end
    local before_lines = split_text_lines(state.staged_text or "")
    local out = {}
    local incomplete = false
    for row = change.first + 1, change.last_orig do
      local staged_row = M.unshift_row(change, row)
      if staged_row == M.NO_PREIMAGE then
        incomplete = true
      elseif before_lines[staged_row] ~= nil then
        out[#out + 1] = before_lines[staged_row]
      end
    end
    return out, incomplete
  end

  local function old_spans_adjacent(a, b)
    local a_end = a.end_line or ((a.start_line or 1) - 1)
    local b_start = b.start_line or 0
    return b_start <= a_end + 1
  end

  -- THE MERGE PREDICATE, and the single source of truth for it.
  --
  -- `try_merge` decides on this function and nothing else, and review_watch's
  -- `absorb_human_edits` consults the SAME function as a VETO on `interior`. Two copies
  -- of the rule would drift into a change that is vetoed here and refused there —
  -- silently dropping the edit out of both branches.
  --
  -- Qualifies when a change REMOVES rows and its collapsed post-edit row lies
  -- in the live gap between two buffer-order-adjacent PENDING hunks. Returns
  -- `a, b, a_start, b_end` for the first such pair, else nil.
  local function merge_gap_pair(state, change)
    local bufnr = state.bufnr
    -- That row is not a base row sitting in the gap; it is the human's own new line,
    -- mid-edit. Only a change that actually shrinks the row count (last_new <
    -- last_orig) can be collapsing real rows into the gap between two hunks -- require
    -- that here, matching the doc comment above ("Qualifies when a change REMOVES
    -- rows").
    if not change or change.last_new >= change.last_orig then
      return nil
    end
    if not state.hunk_ledger then
      return nil
    end
    local removed, removed_incomplete
    local pending = state.hunk_ledger:pending()
    for i = 1, #pending - 1 do
      local a, b = pending[i], pending[i + 1]
      local a_start, a_end = deps.live_block_range(bufnr, a)
      local b_start, b_end = deps.live_block_range(bufnr, b)
      if a_start and b_start then
        local _, a_owned_end = anchor_bounds(a)
        local b_owned_start = anchor_bounds(b)
        -- Neovim's mark can collapse onto the deleted row even when a human
        -- gap survives. The settled owner rows are the actual membership
        -- boundary: only adjacent owners have been joined by the deletion.
        local owner_gap_survives = a_owned_end and b_owned_start
          and b_owned_start > a_owned_end + 1
        -- COORDINATES. `change.first`/`last_orig` are on_lines' PRE-edit rows;
        -- `a_end`/`b_start` come from extmarks and are POST-edit, already shifted by
        -- this very deletion. Compare in the post-edit frame: the deletion collapses to
        -- row `change.first + 1`, which must sit after a's last row and no later than
        -- b's first row.
        local collapsed = change.first + 1
        if not owner_gap_survives and collapsed > a_end and collapsed <= b_start then
          -- SHARPENER. Extmarks alone cannot tell these two apart: deleting the gap
          -- ABOVE b and deleting b's OWN first row both collapse to row `b_start`,
          -- because b's authority mark slides up onto the deleted row either way. Read
          -- the removed text out of the pre-edit snapshot instead.
          if removed == nil then
            removed, removed_incomplete = collect_deletion(state, change)
          end
          -- The sharpener below decides on WHICH line was removed. When part of
          -- what this change removed was born inside the batch, `staged_text`
          -- cannot answer that, and inferring from the lines that DO have a
          -- preimage would attribute an intra-batch row to an unrelated pending
          -- line. Merging two hunks is a membership change; it is not made on
          -- evidence we do not have.
              if removed_incomplete then
            return nil
          end
          if removed[1] == nil or removed[1] ~= (b.new_lines or {})[1] then
            -- Two hunks in different top-level classes/functions share no such parent
            -- even after the base line between them is deleted, and must stay two hunks
            -- (r_merge_refused_across_syntax_boundary[cross]); two hunks inside the
            -- same function body do share it and still merge ([control]).
            if ownership.same_class_scope(bufnr, a_end, b_start, state) then
              return a, b, a_start, b_end
            end
          end
        end
      end
    end
    return nil
  end

  -- MERGE. Guarded on base-adjacency. Pending+pending only, and only when a
  -- refused change qualifies under `merge_gap_pair` above. Adjacent old spans
  -- concatenate plainly; when they are not adjacent the intervening base slice
  -- the change removed is folded into the merged old_lines (reject then
  -- restores it).
  -- Returns an ORDERED list of structural records, one per `Ledger:merge` call,
  -- in the order the calls actually mutated the ledger. The loop below can fuse
  -- several pairs in one batch, and each fusion is its own undoable membership
  -- change: one record each, never one for the batch (`u` walking newest-first
  -- then unmerges them in the exact reverse of the order they were made).
  --
  -- Each record carries the CHANGE that qualified it, so the caller can hand the
  -- record to the native undo sequence that change belongs to -- the flush can
  -- carry several sequences, and a membership row filed under the wrong one is
  -- reversed by the wrong press.
  local function try_merge(state, changes)
    local records = {}
    local again = true
    while again do
      again = false
      for _, qualifying in ipairs(changes or {}) do
        local a, b, a_start, b_end = merge_gap_pair(state, qualifying)
        if a then
          local old_lines = {}
          vim.list_extend(old_lines, a.old_lines or {})
          if not old_spans_adjacent(a, b) then
            -- Parenthesised: collect_deletion has a second return value, and
            -- list_extend's third parameter is a start index.
            vim.list_extend(old_lines, (collect_deletion(state, qualifying)))
          end
          vim.list_extend(old_lines, b.old_lines or {})
          -- Any gap content between a and b that survived the boundary-line deletion
          -- (e.g. Without this, review_paint.lua's paint_spans can only content-match a
          -- and b's own lines and leaves the interior span bare (the ledger owns
          -- membership and paint is a consumer -- the span here IS the membership paint
          -- reads).
          local new_lines = vim.api.nvim_buf_get_lines(state.bufnr, a_start - 1, b_end, false)
          local start_line = math.min(a.start_line or math.huge, b.start_line or math.huge)
          local merged = {
            old_lines = old_lines,
            new_lines = new_lines,
            start_line = start_line,
            end_line = start_line + #old_lines - 1,
            new_start_line = a_start,
            new_end_line = b_end,
          }
          -- `Ledger:merge` hands back the inverse of the membership it just
          -- consumed (hunk_ledger_lifecycle.lua:294-309). Dropping it here is
          -- what left `u` rewinding the TEXT while the ledger kept a merged
          -- block the buffer no longer justified. `after` is the merged block's
          -- own model tag read AFTER the call, because the primitive blanks
          -- `model_index` and stamps `model_join = "lost_at_merge"` -- redo has
          -- to put those back too, or a re-merge wears a stale tag.
          local record = state.hunk_ledger:merge({ a, b }, merged)
          if type(record) == "table" then
            records[#records + 1] = {
              record = record,
              members = record.members,
              before = record.before,
              merged = merged,
              after = { model_index = merged.model_index, model_join = merged.model_join },
              change = qualifying,
            }
          end
          again = true
          break
        end
      end
    end
    return records
  end

  -- Within one still-unpublished Insert pass, a gap that never survives the
  -- completed pass may close. Reuse only the exact parent and children born
  -- in this private pass; a merge of already-committed siblings stays fresh.
  local function rejoin_owned_siblings(state)
    if not state._timeline_stage then return {} end
    local pending = state.hunk_ledger:pending()
    local records = {}
    for i = 1, #pending - 1 do
      local a, b = pending[i], pending[i + 1]
      local id = a.split_parent_lineage_id
      local split = id and state._timeline_split_parents[id]
      if split and id == b.split_parent_lineage_id
        and split.children[1] == a and split.children[2] == b
        and #state.decisions == split.decisions
        and a.verdict == "pending" and b.verdict == "pending" then
        local a_first = anchor_bounds(a)
        local _, b_last = anchor_bounds(b)
        if a_first and b_last and b_last >= a_first then
          local lines = vim.api.nvim_buf_get_lines(state.bufnr, a_first - 1, b_last, false)
          local owners, complete = {}, true
          for row = a_first, b_last do
            local source = lines[row - a_first + 1]
            local anchored = false
            for _, child in ipairs({ a, b }) do
              for _, owner in ipairs(child.owned_rows or {}) do
                if owner.row == row and not owner.provisional and owner.source == source then
                  anchored = true
                end
              end
            end
            if not anchored and not state._row_is_yana_owned(row, true) then
              complete = false
              break
            end
            owners[#owners + 1] = { row = row, source = source, provisional = false }
          end
          if complete then
            local merged = split.parent
            merged.new_lines = lines
            merged.new_start_line, merged.new_end_line = a_first, b_last
            merged.owned_rows = owners
            local record = state.hunk_ledger:merge({ a, b }, merged)
            merged.model_index = split.before.model_index
            merged.model_join = split.before.model_join
            state._timeline_mark_new(merged)
            merged.authority_extmark_id = -1
            state._timeline_split_parents[id] = nil
            records[#records + 1] = { record = record, members = record.members,
              before = record.before, merged = merged,
              after = { model_index = merged.model_index, model_join = merged.model_join } }
            break
          end
        end
      end
    end
    return records
  end

  return {
    try_split = try_split,
    try_merge = try_merge,
    merge_gap_pair = merge_gap_pair,
    rejoin_owned_siblings = rejoin_owned_siblings,
  }
end

return M
