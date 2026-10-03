-- Buffer ownership and external-reload composition.
local line_space = require("yana.review_line_space")

local M = {}

function M.new(deps)
  local diff = deps.diff
  local buffer_lines = deps.buffer_lines

local function reject_restoration(bufnr, block, start_line, end_line)
  local old_lines = block.old_lines or {}
  if end_line < start_line then
    return old_lines, nil
  end
  local live = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  -- F-OWN-GAP: reject acts on member rows only. A row in the band the hunk does
  -- not own is the operator's and survives, in order, after the old lines that
  -- stand for the members above it.
  local members = {}
  for _, owner in ipairs(block.owned_rows or {}) do
    members[owner.row] = true
  end
  if next(members) ~= nil then
    local out, seen, kept = vim.deepcopy(old_lines), 0, 0
    for offset, line in ipairs(live) do
      if members[start_line + offset - 1] then
        seen = seen + 1
      else
        table.insert(out, math.min(seen, #old_lines) + kept + 1, line)
        kept = kept + 1
      end
    end
    return out, nil
  end
  -- A hunk with no membership record cannot tell the operator's rows from the
  -- agent's without comparing texts, so it falls back to its base: the old lines
  -- come back whole and anything typed inside stays in the undo history
  --
  return old_lines, nil
end

-- Sensor: has the review buffer diverged from what this engine last staged?
--
-- It is NOT a blanket accept guard, and wiring it as one is wrong. Refusing there would
-- destroy a legitimate workflow to prevent a loss that does not happen.
--
-- It is used only where accept does NOT compose from the buffer and would therefore
-- discard buffer text the human typed: * a delete accept, which unlinks the file and
-- never reads the buffer; * accept_everything's QUEUED files.
local function staged_snapshot_unchanged(state)
  if not state.staged_text then
    return true
  end
  local now = diff.buffer_bytes_snapshot(state.bufnr)
  if now == nil then
    return false
  end
  return now == state.staged_text
end

local function ranges_overlap(a_start, a_count, b_start, b_count)
  local a_end = a_count > 0 and (a_start + a_count - 1) or a_start
  local b_end = b_count > 0 and (b_start + b_count - 1) or b_start
  return a_start <= b_end and b_start <= a_end
end

local function disk_change_touches_review_hunk(disk_hunks, blocks)
  for _, hunk in ipairs(disk_hunks) do
    local start_a, count_a = hunk[1], hunk[2]
    local disk_start = count_a > 0 and start_a or (start_a + 1)
    local disk_count = count_a > 0 and count_a or 1
    for _, block in ipairs(blocks) do
      local block_start = block.start_line
      local block_count = math.max(1, block.end_line - block.start_line + 1)
      if ranges_overlap(disk_start, disk_count, block_start, block_count) then
        return true
      end
    end
  end
  return false
end

local function line_delta_before(disk_hunks, base_line)
  local delta = 0
  for _, hunk in ipairs(disk_hunks) do
    local start_a, count_a, _, count_b = unpack(hunk)
    local old_end = count_a > 0 and (start_a + count_a - 1) or start_a
    if old_end < base_line then
      delta = delta + count_b - count_a
    end
  end
  return delta
end

local function sorted_by_start(blocks)
  local out = {}
  for i, b in ipairs(blocks) do
    out[i] = b
  end
  table.sort(out, function(a, b)
    return (a.start_line or 0) < (b.start_line or 0)
  end)
  return out
end

-- Splice `blocks` (each replacing its `old_lines` span with `new_lines`, in BASE line
-- coordinates) onto `disk_text`, relocating every block past `disk_hunks` (the
-- base->disk diff). Third return: the row each block's rows now start at.
local function splice_blocks_onto_disk(disk_text, disk_hunks, blocks)
  local lines, relocated_at = buffer_lines(disk_text), {}
  local applied_delta = 0
  for _, block in ipairs(sorted_by_start(blocks)) do
    local relocated = math.max(1, block.start_line + line_delta_before(disk_hunks, block.start_line) + applied_delta)
    relocated_at[block] = relocated
    local old_count = #block.old_lines
    local replacement = vim.deepcopy(block.new_lines)
    if old_count > 0 and relocated + old_count - 1 > #lines then
      return nil, "conflict: reviewed hunk could not be relocated after reload"
    end
    for _ = 1, old_count do
      table.remove(lines, relocated)
    end
    for i = #replacement, 1, -1 do
      table.insert(lines, relocated, replacement[i])
    end
    applied_delta = applied_delta + #replacement - old_count
  end
  return lines, nil, relocated_at
end

-- Accept never rewrites a buffer byte (the buffer holds `new_lines` from the moment the
-- review opened; accept only drops the hunk from the pending list), so those bytes
-- exist nowhere but this buffer -- not on disk, not in `blocks`. Composing from disk +
-- only the still-PENDING `blocks` therefore silently reverted every accepted hunk back
-- to its base text.
local function apply_review_blocks_to_reloaded_disk(base, disk_now, blocks, accepted_blocks)
  local base_text = base or ""
  local disk_text = disk_now or ""
  local disk_hunks = vim.diff(base_text, disk_text, {
    algorithm = "histogram",
    result_type = "indices",
    ctxlen = 0,
  }) or {}

  accepted_blocks = accepted_blocks or {}
  local combined = {}
  for _, b in ipairs(accepted_blocks) do
    combined[#combined + 1] = b
  end
  for _, b in ipairs(blocks) do
    combined[#combined + 1] = b
  end

  if disk_change_touches_review_hunk(disk_hunks, combined) then
    return nil, "conflict: file changed on disk inside a reviewed hunk"
  end

  local settled_lines, settled_err = splice_blocks_onto_disk(disk_text, disk_hunks, accepted_blocks)
  if not settled_lines then
    return nil, settled_err
  end
  local composed_lines, composed_err, relocated = splice_blocks_onto_disk(disk_text, disk_hunks, combined)
  if not composed_lines then
    return nil, composed_err
  end

  local trailing = disk_text:sub(-1) == "\n" and "\n" or ""
  local settled_text = table.concat(settled_lines, "\n") .. trailing
  local composed_text = table.concat(composed_lines, "\n") .. trailing
  return composed_text, nil, settled_text, relocated
end

--
-- `apply_review_blocks_to_reloaded_disk` above is ALL-OR-NOTHING: one disk hunk
-- touching one reviewed hunk refuses the whole file. That is right for the watcher,
-- which has a live review it can tear down and requeue. It is wrong for `cA`, where the
-- refusal it produced was per-FILE: a queued file the operator had touched anywhere at
-- all was skipped whole, even when the edit was nowhere near a hunk.
--
-- Returns composed bytes (the operator's file with the absorbed hunks applied),
-- the absorbed list and the conflicted list. Composition is over `now`, never
-- over `base`, so an edit outside every hunk is KEPT rather than reverted.
local function absorb_review_blocks_over_drift(base, now, blocks)
  local base_text = base or ""
  local now_text = now or ""
  local drift = vim.diff(base_text, now_text, {
    algorithm = "histogram",
    result_type = "indices",
    ctxlen = 0,
  }) or {}

  local absorbed, conflicted = {}, {}
  for _, block in ipairs(blocks or {}) do
    if disk_change_touches_review_hunk(drift, { block }) then
      conflicted[#conflicted + 1] = block
    else
      absorbed[#absorbed + 1] = block
    end
  end

  local lines = buffer_lines(now_text)
  local applied_delta = 0
  -- `blocks` arrive in buffer order (build_diff_blocks emits them ascending), so
  -- `applied_delta` accumulates only over hunks already written. A conflicted
  -- hunk contributes nothing to it, which is exactly right: it is not applied.
  for _, block in ipairs(absorbed) do
    local relocated = block.start_line + line_delta_before(drift, block.start_line) + applied_delta
    relocated = math.max(1, relocated)
    local old_count = #(block.old_lines or {})
    local replacement = vim.deepcopy(block.new_lines or {})
    if old_count > 0 and relocated + old_count - 1 > #lines then
      return nil, nil, nil, "conflict: reviewed hunk could not be relocated over the operator's edit"
    end
    for _ = 1, old_count do
      table.remove(lines, relocated)
    end
    for i = #replacement, 1, -1 do
      table.insert(lines, relocated, replacement[i])
    end
    applied_delta = applied_delta + #replacement - old_count
  end

  return table.concat(lines, "\n") .. (now_text:sub(-1) == "\n" and "\n" or ""), absorbed, conflicted, nil
end

  return {
    reject_restoration = reject_restoration,
    staged_snapshot_unchanged = staged_snapshot_unchanged,
    apply_review_blocks_to_reloaded_disk = apply_review_blocks_to_reloaded_disk,
    absorb_review_blocks_over_drift = absorb_review_blocks_over_drift,
    place_on_b1 = M.place_on_b1,
  }
end

-- Buffer drift stage 1 (spec BUILD buffer drift; INTERFACE.md section 3; PLACEMENT.md).
-- `blocks` are the agent's edits in B0 rows (the buffer at submit). The submit laid one
-- extmark on every B0 line; this reads where each one sits in B1 (the buffer now) and
-- re-expresses every block in B1 rows. Nothing here compares texts to find a line: a
-- line is where its mark is, and a B1 line with no surviving mark is one the operator
-- typed. The one text comparison left drops an edit whose place already holds the
-- agent's lines. Returns nil and a reason whenever the marks cannot say where an edit
-- goes; the caller then reviews against B0 instead.
function M.place_on_b1(blocks, snap, b1_lines)
  if type(snap) ~= "table" then
    return nil, "no buffer snapshot"
  end
  if snap.lost then
    return nil, "buffer snapshot lost (" .. tostring(snap.lost) .. ")"
  end
  if snap.no_extmarks then
    return nil, "buffer was too large to mark at submit"
  end
  local bufnr = snap.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil, "buffer snapshot lost (buffer gone)"
  end
  b1_lines = b1_lines or {}
  local n = #b1_lines
  local count = vim.api.nvim_buf_line_count(bufnr)
  if count ~= n and not (n == 0 and count == 1) then
    return nil, "the buffer changed after B1 was read"
  end

  -- Where each B0 line (1-based) sits in B1, or nil once its line was deleted.
  local b0_count = #line_space.buffer_lines(snap.b0 or "")
  local marks = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, snap.ns, 0, -1, { details = true })) do
    marks[m[1]] = m
  end
  local at, owners = {}, {}
  for line = 1, b0_count do
    local id = snap.ids and snap.ids[line - 1]
    local m = id and marks[id]
    if not m then
      return nil, "missing extmark for B0 line " .. line
    end
    if not m[4].invalid then
      local row = m[2] + 1
      if row > n then
        return nil, "the buffer changed after B1 was read"
      end
      at[line] = row
      owners[row] = owners[row] or {}
      table.insert(owners[row], line)
    end
  end

  -- The B1 row of the first surviving B0 line at or after `line`; past the end, the
  -- end of the buffer.
  local function next_surviving(line)
    for l = line, b0_count do
      if at[l] then
        return at[l]
      end
    end
    return n + 1
  end

  local placed, reach = {}, 0
  for _, block in ipairs(blocks or {}) do
    local s0, e0 = block.start_line, block.end_line
    local s, e
    if e0 < s0 then
      -- Pure insertion after B0 line e0: before the next surviving line, so typed
      -- lines at that spot stay first.
      s = next_surviving(e0 + 1)
      e = s - 1
    else
      local prev
      for line = s0, e0 do
        local row = at[line]
        if row then
          if prev and row <= prev then
            return nil, "target lines out of order"
          end
          s, prev = s or row, row
        end
      end
      e = prev
      if not s then
        -- Every target line is gone. The top and bottom of the buffer count as
        -- surviving neighbours.
        local before = s0 == 1 and 0 or at[s0 - 1]
        local after = e0 >= b0_count and (n + 1) or at[e0 + 1]
        if before and after then
          if after <= before then
            return nil, "target lines out of order"
          end
          -- The typed lines between the neighbours are the place; none makes it
          -- a pure addition before `after`.
          s, e = before + 1, after - 1
        else
          s = next_surviving(e0 + 1)
          e = s - 1
        end
      end
      for row = s, e do
        for _, line in ipairs(owners[row] or {}) do
          if line < s0 or line > e0 then
            return nil, "a surviving non-target line inside a place"
          end
        end
      end
    end
    local old_lines = e >= s and vim.list_slice(b1_lines, s, e) or {}
    if not vim.deep_equal(old_lines, block.new_lines or {}) then
      if s <= reach then
        return nil, "two places overlapping"
      end
      reach = math.max(reach, e)
      local copy = vim.deepcopy(block)
      copy.start_line, copy.end_line, copy.old_lines = s, e, old_lines
      placed[#placed + 1] = copy
    end
  end

  -- New-file rows recomputed exactly as review_line_space.build_diff_blocks does.
  local base = 0
  for _, block in ipairs(placed) do
    block.new_start_line = block.start_line + base
    block.new_end_line = block.new_start_line + #(block.new_lines or {}) - 1
    base = base + #(block.new_lines or {}) - #block.old_lines
  end
  return placed
end

-- Buffer drift stage 3 (INTERFACE.md section 3). For each parent a "restore"
-- decision names: its B0 lines whose submit extmarks are flagged deleted, each run
-- put back at its old spot (right before the next surviving B0 line after it), as
-- insertion blocks shaped like build_diff_blocks output in B1 rows. A surviving
-- line is never restored. A B0 line an agent edit replaces stays with that edit:
-- the caller lists the placed edits in `decision.edits` (their `b0_span`). Each
-- block's `b0_span` names the B0 lines it restores; with no agent hunk behind it, their
-- count is its render-check reference (`model_span_new_count`). Any other decision: none.
function M.restore_blocks(decision, snap, b1_lines)
  if type(decision) ~= "table" or decision.kind ~= "restore" then
    return {}
  end
  local b0 = line_space.buffer_lines(snap.b0 or "")
  local marks = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(snap.bufnr, snap.ns, 0, -1, { details = true })) do
    marks[m[1]] = m
  end
  local function mark(line)
    return marks[snap.ids[line - 1]]
  end
  local carried = {}
  for _, edit in ipairs(decision.edits or {}) do
    local span = edit.b0_span
    for line = span and span.start_line or 1, span and span.end_line or 0 do
      carried[line] = true
    end
  end
  local wanted = {}
  for _, parent in ipairs(decision.parents or {}) do
    for line = parent.start_row + 1, parent.end_row + 1 do
      local m = mark(line)
      if m and m[4].invalid and not carried[line] then
        wanted[line] = true
      end
    end
  end
  local out, line, base = {}, 1, 0
  while line <= #b0 do
    if wanted[line] then
      local first = line
      while wanted[line + 1] do
        line = line + 1
      end
      local at = #(b1_lines or {}) + 1
      for after = line + 1, #b0 do
        local m = mark(after)
        if m and not m[4].invalid then
          at = m[2] + 1
          break
        end
      end
      local lines = vim.list_slice(b0, first, line)
      out[#out + 1] = { start_line = at, end_line = at - 1, old_lines = {}, new_lines = lines,
        new_start_line = at + base, new_end_line = at + base + #lines - 1,
        b0_span = { start_line = first, end_line = line },
        model_span_new_count = line - first + 1, model_join = "restored_parent" }
      base = base + #lines
    end
    line = line + 1
  end
  return out
end

-- Per file record: where each B0 row (0-based) sits in B1 (0-based, nil once deleted) and
-- how many B0 rows were deleted, read from the submit extmarks once per buffer change.
local b0_rows_by_snap = setmetatable({}, { __mode = "k" })

local function b0_rows_in_b1(snap, bufnr)
  local tick = vim.b[bufnr].changedtick
  local cached = b0_rows_by_snap[snap]
  if cached and cached.tick == tick then
    return cached
  end
  local mark_row = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, snap.ns, 0, -1, { details = true })) do
    if not m[4].invalid then
      mark_row[m[1]] = m[2]
    end
  end
  local count = #line_space.buffer_lines(snap.b0 or "")
  local at, deleted = {}, 0
  for row = 0, count - 1 do
    local id = snap.ids and snap.ids[row]
    at[row] = id and mark_row[id]
    if at[row] == nil then
      deleted = deleted + 1
    end
  end
  cached = { tick = tick, at = at, count = count, deleted = deleted }
  b0_rows_by_snap[snap] = cached
  return cached
end

-- Buffer drift stage 3 (spec BUILD buffer drift; INTERFACE.md sections 2 and 5). `block` is
-- the agent edit in B0 rows, as place_on_b1 takes it (the placed copy has lost its B0 rows);
-- call it only for a file whose edits place_on_b1 placed. Decides whether the parents the
-- edit sat in must be offered back. Rows come from the extmarks and the syntax tree only.
function M.parent_decision(block, snap, b1_bufnr, lang)
  local keep = { kind = "keep" }
  local marks = b0_rows_in_b1(snap, b1_bufnr)
  if marks.deleted == 0 then
    return keep -- no deleted B0 line in the file: no conflict, no parse
  end
  local at, count = marks.at, marks.count
  -- The target rows; a pure insertion after line end_line is aimed at the line after it.
  local first, last = block.start_line - 1, block.end_line - 1
  if block.end_line < block.start_line then
    first = math.min(block.end_line, count - 1)
    last = first
  end
  local own = require("yana.review_watch_ownership")
  local parents = own.parents_of_text(snap.b0, lang, first, last) or {}
  -- A parent with a deleted line inside may have lost its header; one without is intact.
  local deleted, any = {}, false
  for k, p in ipairs(parents) do
    deleted[k] = at[p.header_row] == nil
    any = any or deleted[k]
  end
  if not any then
    return keep -- every header survives: no B1 parse
  end

  -- Each parent whose header was deleted, on its own. None of its lines survive: the whole
  -- parent was deleted and nothing of it can have moved, so it comes back with no B1 parse.
  -- Some survive: ask B1 at the first of them (never at the edit's landing spot, which may
  -- lie in a neighbour) for its innermost parent. Top level, or a parent whose header
  -- carries the mark of an outer parent of the edit: it comes back. Another line's parent
  -- or a typed header: the code was moved or merged, keep. A syntax error: unsure.
  local restore = {}
  for k, p in ipairs(parents) do
    if deleted[k] then
      local survivor
      for r = p.start_row, p.end_row do
        if at[r] then
          survivor = at[r]
          break
        end
      end
      local back = survivor == nil
      if not back then
        local q, why = own.innermost_parent(b1_bufnr, survivor)
        if q == nil then
          return { kind = "unsure", reason = why }
        end
        back = q == false
        for j = k + 1, #parents do
          back = back or (not deleted[j] and at[parents[j].header_row] == q.header_row)
        end
      end
      if back then
        restore[#restore + 1] = p
      end
    end
  end
  if #restore == 0 then
    return keep
  end
  return { kind = "restore", parents = restore }
end

return M
