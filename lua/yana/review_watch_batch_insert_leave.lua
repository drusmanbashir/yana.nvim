-- Size split of review_watch_batch.lua: InsertLeave membership (the grow walk, judge, complete call).
local M = {}

function M.new(env)
  local deps = env.deps
  local state = env.state
  local bufnr = env.bufnr
  local interior_line_is_yana_owned = env.interior_line_is_yana_owned
  local line_at = env.line_at
  local anchor_bounds = env.anchor_bounds
  local complete = env.complete

  -- F-OWN-HEAL on InsertLeave: re-judge ONLY the insert-touched rows against the
  -- settled parse, then complete the edit from that answer. Absorb walks
  -- outward from the hunk's members one touched row at a time and stops at the
  -- first row that does not resolve owned (F-OWN-SHIFT). Growth never takes a
  -- row another pending hunk owns or one an earlier hunk grew into this pass,
  -- and crosses an unowned row only toward a split sibling (same
  -- split_parent_lineage_id), so two pending extents never overlap.
  -- `undo_seq` / `before_seq` PARTITION the absorb (review_watch.lua): each
  -- native sequence's rows are recorded under that sequence's sealed number so
  -- `u` peels one line's text and its ownership in lockstep.
  local function absorb_on_insert_leave(dirty_rows, undo_seq, before_seq)
    if type(dirty_rows) ~= "table" or next(dirty_rows) == nil then
      return false
    end
    if not state.hunk_ledger or not state.hunk_ledger:is_open() then
      return false
    end
    local is_owned = interior_line_is_yana_owned
    if type(undo_seq) ~= "number" then
      undo_seq = deps.buf_undo_seq(bufnr)
    end
    local pending = state.hunk_ledger:pending()

    local function ledger_owner_other(block, row)
      for _, other in ipairs(pending) do
        if other ~= block and other.verdict == "pending"
          and state.hunk_ledger:row_is_owned(other, row)
        then
          return other
        end
      end
      return nil
    end

    -- Pending block immediately beyond `row` in the growth direction, if any.
    local function neighbor_beyond(block, row, growing_down)
      for _, other in ipairs(pending) do
        if other ~= block and other.verdict == "pending" then
          local os = other.new_start_line
          local oe = other.new_end_line or os
          local ls, le = deps.live_block_range(bufnr, other)
          if ls then
            os, oe = ls, le
          end
          if type(os) == "number" and type(oe) == "number" then
            if growing_down and os >= row and os <= row + 1 then
              return other
            end
            if not growing_down and oe <= row and oe >= row - 1 then
              return other
            end
          end
        end
      end
      return nil
    end

    local claimed = {}
    local function may_grow_to(block, row, growing_down)
      if not dirty_rows[row] or claimed[row] or ledger_owner_other(block, row) then
        return false
      end
      if state.hunk_ledger:row_is_owned(block, row) or is_owned(row) then
        return true
      end
      local neighbor = neighbor_beyond(block, row, growing_down)
      return neighbor ~= nil and neighbor.split_parent_lineage_id ~= nil
        and neighbor.split_parent_lineage_id == block.split_parent_lineage_id
    end

    -- One touched row's settled membership. A row whose settled anchor still
    -- holds the anchor's own text is the proposal's row unchanged (ledger
    -- identity, F-OWN-DEF 1); blankness never revokes it (F-OWN-GAP). Every
    -- other touched row is re-judged without its own provisional identity.
    local function judge(block, row)
      local line = line_at(row) or ""
      for _, owner in ipairs(block.owned_rows or {}) do
        if owner.row == row and not owner.provisional and owner.source == line then
          return { row = row, owned = true, source = line }
        end
      end
      return { row = row, owned = is_owned(row, true) and true or false, source = line }
    end

    local absorbed_any = false
    for index, block in ipairs(pending) do
      local lo, hi = anchor_bounds(block)
      if lo == nil then
        lo, hi = block.new_start_line, block.new_end_line or block.new_start_line
      end
      if type(lo) == "number" and type(hi) == "number" then
        local grew = true
        while grew do
          grew = false
          if may_grow_to(block, hi + 1, true) then
            hi, grew = hi + 1, true
            claimed[hi] = true
          end
          if may_grow_to(block, lo - 1, false) then
            lo, grew = lo - 1, true
            claimed[lo] = true
          end
        end
        local decisions = {}
        for row in pairs(dirty_rows) do
          if type(row) == "number" and row >= lo and row <= hi and not ledger_owner_other(block, row) then
            decisions[#decisions + 1] = judge(block, row)
          end
        end
        if complete(block, index, decisions, {}, undo_seq, before_seq) then
          absorbed_any = true
        end
      end
    end
    -- try_split runs AFTER paint recreates authority (see
    -- on_insert_leave_ownership): a completed edit deletes the mark, and
    -- try_split refuses non-live provenance.
    return absorbed_any
  end

  return { absorb_on_insert_leave = absorb_on_insert_leave }

end



return M
