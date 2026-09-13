-- Buffer ownership and external-reload composition.
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
  -- A hunk with no membership record: tell human rows by content.
  local new_lines = block.new_lines or {}
  if #live <= #new_lines then
    return old_lines, nil
  end
  local remaining = {}
  for _, line in ipairs(new_lines) do
    remaining[line] = (remaining[line] or 0) + 1
  end
  local function standalone_human_line(line)
    if vim.tbl_contains(new_lines, line) then
      return false
    end
    for _, nl in ipairs(new_lines) do
      if #nl > 0 and line:sub(1, #nl) == nl and #line > #nl then
        return false
      end
    end
    return true
  end
  local human_inserts = {}
  local agent_seen = 0
  for _, line in ipairs(live) do
    if remaining[line] and remaining[line] > 0 then
      remaining[line] = remaining[line] - 1
      agent_seen = agent_seen + 1
    elseif standalone_human_line(line) then
      human_inserts[#human_inserts + 1] = { after = agent_seen, text = line }
    else
      agent_seen = agent_seen + 1
    end
  end
  if #human_inserts == 0 then
    return old_lines, nil
  end
  local out = vim.deepcopy(old_lines)
  for _, h in ipairs(human_inserts) do
    local pos = math.min(h.after + 1, #out + 1)
    table.insert(out, pos, h.text)
  end
  return out, nil
end

local function resolve_disk_unchanged(change)
  -- Since E9 the file is still there for the whole review -- the deletion happens at
  -- accept -- so the honest question is the same one every other kind asks: are the
  -- bytes captured at open still the bytes on disk?
  if change.before == nil and change.kind ~= "delete" then
    -- The `disk_absent_at_open` branch this replaces refused ANY appearance at the
    -- path, and yana's own proposal-time touch is exactly that appearance -- unamended,
    -- this guard would rule every created-file review stale the moment the touch and
    -- the open raced, in either order.
    local creation_touch = require("yana.creation_touch")
    local ours, why = creation_touch.disk_is_ours(change.path)
    if ours then
      return true
    end
    if change._accept_composed_hash ~= nil and deps.base_fingerprint ~= nil then
      local disk = diff.read_file_bytes(change.path)
      if disk ~= nil and deps.base_fingerprint(disk) == change._accept_composed_hash then
        return true
      end
    end
    return false, why or "file appeared on disk since review opened"
  end
  if change.disk_at_open == nil then
    if change.kind == "delete" and vim.fn.filereadable(change.path) == 1 then
      -- Absent when the review opened, present now: someone else created it.
      return false, "file on disk changed since review opened"
    end
    return true
  end
  local ok, err = diff.disk_bytes_unchanged(change.path, change.disk_at_open)
  if not ok then
    return false, err
  end
  return true
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
    resolve_disk_unchanged = resolve_disk_unchanged,
    staged_snapshot_unchanged = staged_snapshot_unchanged,
    apply_review_blocks_to_reloaded_disk = apply_review_blocks_to_reloaded_disk,
    absorb_review_blocks_over_drift = absorb_review_blocks_over_drift,
  }
end

return M
