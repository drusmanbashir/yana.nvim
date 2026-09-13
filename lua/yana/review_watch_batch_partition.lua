-- Size split of review_watch_batch.lua: the split/merge partition of the pending hunks.
local M = {}

function M.new(env)
  local deps = env.deps
  local state = env.state
  local bufnr = env.bufnr
  local try_split = env.try_split
  local try_merge = env.try_merge

  local function repartition(changes)
    local just_changed = {}
    for _, change in ipairs(changes or {}) do
      for row = change.first + 1, change.last_new do
        just_changed[row] = true
      end
    end
    -- ONE classifier: never `just_changed → human`. During insert, blank or
    -- ERROR rows from the pending edit that sit inside a pending extent are
    -- held as owned so try_split keeps the parent (provisional paint).
    local inserting = tostring(vim.fn.mode(1)):find("[iR]") ~= nil
    local function row_in_pending_extent(row)
      for _, block in ipairs(state.hunk_ledger:pending()) do
        local start_line = block.new_start_line
        local end_line = block.new_end_line or start_line
        if type(start_line) == "number" and type(end_line) == "number"
          and row >= start_line and row <= end_line
        then
          return true
        end
        local live_start, live_end = deps.live_block_range(bufnr, block)
        if live_start and live_end and row >= live_start and row <= live_end then
          return true
        end
      end
      return false
    end
    local function classify(row)
      -- Created file: every row is owned; blanks never open a boundary.
      if type(state.change) == "table" and state.change.before == nil then
        return true
      end
      -- Ledger identity first (F-OWN-DEF): seeded anchors must survive split
      -- even when the parent-rule momentarily disagrees (first row of a multi-row insert).
      for _, block in ipairs(state.hunk_ledger:pending()) do
        if state.hunk_ledger:row_is_owned(block, row) then
          return true
        end
      end
      if inserting and just_changed[row] and row_in_pending_extent(row) then
        local line = (vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false) or {})[1] or ""
        if line:match("^%s*$") then
          return true
        end
        if type(state._row_is_yana_owned) == "function" and state._row_is_yana_owned(row) then
          return true
        end
      end
      if type(state._row_is_yana_owned) == "function" then
        return state._row_is_yana_owned(row) and true or false
      end
      return false
    end
    -- WHICH CHANGE OWNS A SPLIT. `try_split` is driven per BLOCK, not per
    -- change, so the record has to be attributed. The text that owns a split is
    -- the text sitting in the GAP the split opened -- the rows between one
    -- child's end and the next child's start.
    --
    -- THE EARLIEST such change owns it, not the latest. Neovim seals a native
    -- sequence part-way through a typed split: `o.<C-u><C-d>HUMAN = 1<Esc>`
    -- arrives as `markers=2x2,3x17` -- the FIRST sequence opens the gap ROW and
    -- that row alone is what partitions the hunk; the second only fills the row
    -- with characters. Measured: filed under the LAST writer, `u` press 1
    -- rejoins the hunk while the gap row is still on screen -- the ledger
    -- saying one hunk over a buffer showing two, which is the same desync read
    -- from the other end. Filed under the first, the membership comes back on
    -- the very press that deletes the row.
    local row_change, order_of = {}, {}
    for i, change in ipairs(changes or {}) do
      order_of[change] = i
      for row = change.first + 1, change.last_new do
        if row_change[row] == nil then
          row_change[row] = change
        end
      end
    end
    local function causal_change(rec)
      local found = nil
      for k = 1, #rec.children - 1 do
        local gap_from = rec.children[k].new_end_line
        local gap_to = rec.children[k + 1].new_start_line
        if type(gap_from) == "number" and type(gap_to) == "number" then
          for row = gap_from + 1, gap_to - 1 do
            local cand = row_change[row]
            if cand and (found == nil or order_of[cand] < order_of[found]) then
              found = cand
            end
          end
        end
      end
      -- No gap row was written by this batch (a split off a DELETION, say).
      -- nil is honest: review_watch files an unattributed record under the LAST
      -- native sequence rather than dropping it, and an unrecorded membership
      -- change is the defect itself.
      return found
    end
    -- SURFACED, not swallowed: these records are the only inverse of the
    -- membership this seam just destroyed, and the register push that consumes
    -- them lives one level up, where the native undo sequences are known.
    --
    -- ORDER IS MUTATION ORDER, and the list is ONE list: splits first because
    -- `try_split` runs first, then the merges, each in the order its
    -- `Ledger:split`/`Ledger:merge` call was made. `u` walks the list
    -- newest-first, so it unmerges before it unsplits before it rewinds the
    -- text -- the exact reverse of the order this batch made them.
    local records = {}
    -- F-OWN-HEAL hold: during insert, refuse to split on blank/ERROR pending
    -- rows — keep the parent. Created files never split (one contiguous hunk;
    -- blanks must not open boundaries). Split only after InsertLeave (or
    -- outside insert) at genuine human boundaries in existing files.
    local created_file = type(state.change) == "table" and state.change.before == nil
    if not inserting and not created_file then
      for _, block in ipairs(state.hunk_ledger:pending()) do
        if block.verdict == "pending" then
          local did, record = try_split(state, block, classify)
          if did and record then
            record.change = causal_change(record)
            records[#records + 1] = record
          end
        end
      end
    end
    for _, record in ipairs(try_merge(state, changes) or {}) do
      records[#records + 1] = record
    end
    return records
  end

  return { repartition = repartition }

end



return M
