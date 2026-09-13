-- Authority marks, span composition, and modified-buffer accounting.
local M = {}

function M.new(deps)
  local M = deps.facade
  local diff = deps.diff
  local NS = deps.ns
  local AUTH_NS = deps.authority_ns
  local late = deps.late
  local live_block_range

local function lines_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

live_block_range = function(bufnr, block)
  -- The AUTHORITY mark decides this range, never the paint mark. See the
  -- AUTH_NS comment at the top of the file: the paint mark's end deliberately
  -- sits at column 0 of the row AFTER the hunk, which is precisely where a
  -- human types when appending below the hunk, so reading it here would let
  -- reject/compose swallow the human's line.
  local row, end_row, collapsed = nil, nil, false
  local auth_id = block.authority_extmark_id
  if auth_id then
    local ext = vim.api.nvim_buf_get_extmark_by_id(bufnr, AUTH_NS, auth_id, { details = true })
    if not ext or ext[1] == nil then
      return nil, nil, "hunk extmark invalidated"
    end
    local meta = ext[3]
    row = ext[1]
    -- Authority geometry is INCLUSIVE-by-encoding: end at (last_new_row, 0),
    -- so the 1-based last line is end_row + 1.
    end_row = ((meta and meta.end_row) or row) + 1
    collapsed = (meta and (meta.end_row or row) <= row)
      and (block.initial_new_count or #block.new_lines) > 1
  else
    -- No authority mark: fall back to the paint mark's anchor row only, and
    -- derive the end from the block's own new-line count rather than from the
    -- paint mark's end. This path is reached only if highlight_blocks did not
    -- run for this block; it must not resurrect the unsafe reading.
    local id = block.incoming_extmark_id
    if not id then
      return nil, nil, "hunk extmark missing"
    end
    local ext = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, id, { details = true })
    if not ext or ext[1] == nil then
      return nil, nil, "hunk extmark invalidated"
    end
    row = ext[1]
    end_row = row + math.max(#block.new_lines, 1)
  end
  local start_line = row + 1
  local end_line = end_row
  if #block.new_lines == 0 then
    end_line = start_line - 1
  end
  if end_line < start_line - 1 then
    return nil, nil, "hunk invalidated: extmark range collapsed"
  end
  if #block.new_lines > 0 then
    if end_line < start_line then
      return nil, nil, "hunk invalidated: lines deleted"
    end
    local live = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    if #live == 0 then
      return nil, nil, "hunk invalidated: lines deleted"
    end
  end
  return start_line, end_line, nil, collapsed
end
late.live_block_range = live_block_range

--- A save therefore writes the buffer with every PENDING hunk put back the way disk has
--- it -- an added line does not reach disk, a line the hunk proposes to delete stays
--- there. A DECIDED hunk already crossed owners and is absent from the
--- `hunk_ledger:pending()` list this is handed, so it is not touched here.

--- The bytes a list of buffer lines becomes on disk, by exactly the rules
--- `diff.buffer_bytes_snapshot` applies (`diff.lua:562-583`): 'fileformat'
--- picks the EOL byte, 'endofline' decides the final one, 'bomb' prefixes the
--- BOM. A naive `table.concat(lines, "\n") .. "\n"` corrupts dos and noeol
--- files; `finish_session`'s `match_eol` exists because that bug class already
--- shipped once.
---
--- A buffer holding no real line is written as an EMPTY file, not as one newline.
--- Defined on `M` rather than as a file-local: `M.open` is one function away from
--- LuaJIT's 60-upvalue ceiling, and two more file-locals referenced from the
--- BufWriteCmd closure inside it push it over.
function M._encode_buffer_lines(bufnr, lines)
  if #lines == 0 then
    return ""
  end
  local eol_byte
  local ff = vim.bo[bufnr].fileformat
  if ff == "dos" then
    eol_byte = "\r\n"
  elseif ff == "mac" then
    eol_byte = "\r"
  else
    eol_byte = "\n"
  end
  local body = table.concat(lines, eol_byte)
  if vim.bo[bufnr].endofline then
    body = body .. eol_byte
  end
  if vim.bo[bufnr].bomb then
    body = "\239\187\191" .. body
  end
  return body
end

--- The buffer's lines with every pending hunk's live range replaced by the
--- lines disk holds there (`block.old_lines`).
---
--- Position comes from `live_block_range` -- the AUTH_NS mark -- and never
--- from the paint mark, whose end deliberately sits on the row AFTER the hunk
--- (that reading is what made rejecting a hunk delete the human's line, N8a).
---
--- Every range is read against the UNMUTATED buffer, then the result is built as a NEW
--- list in ascending order. (The reject sweep runs last-hunk-first for the opposite
--- reason: it mutates the buffer in place.)
---
--- A pure deletion's live range is empty -- `(start_line, start_line - 1)`,
--- see `live_block_range` above -- so `old_lines` is inserted BEFORE
--- `start_line` and nothing is consumed.
---
--- Neither is a refused save: CORE requires that a human save is never blocked.
---
--- A verbatim buffer line is kept iff its own line number falls in the range. `range ==
--- nil` means "the whole buffer", byte-identical to this function's pre-ranged
--- behaviour.
---
--- Returns: composed lines, hunks actually withheld, first skip reason or nil,
--- number skipped.
function M._compose_buffer_owned_lines(bufnr, blocks, range)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    -- Vim's forced blank line is not a line of the file.
    lines = {}
  end
  local q1, q2
  if range then
    q1, q2 = range[1], range[2]
  end
  local ranges, skipped, first_reason = {}, 0, nil
  for _, block in ipairs(blocks or {}) do
    local start_line, end_line, range_err = live_block_range(bufnr, block)
    if start_line then
      -- Hunk-ownership: the same conservative restoration used by reject
      -- keeps unabsorbed interior human lines in the buffer-owned save.
      local restored = deps.reject_restoration(bufnr, block, start_line, end_line)
      ranges[#ranges + 1] = {
        s = math.max(1, math.min(start_line, #lines + 1)),
        e = math.min(end_line, #lines),
        old = restored or block.old_lines or {},
      }
    else
      skipped = skipped + 1
      first_reason = first_reason or (range_err or "hunk invalidated")
    end
  end
  table.sort(ranges, function(a, b)
    if a.s ~= b.s then
      return a.s < b.s
    end
    return a.e < b.e
  end)
  local kept, reach = {}, 0
  for _, r in ipairs(ranges) do
    if r.s <= reach then
      skipped = skipped + 1
      first_reason = first_reason or "two pending hunks claim the same lines"
    else
      kept[#kept + 1] = r
      reach = math.max(reach, r.e)
    end
  end
  local function want_line(i)
    return not q1 or (i >= q1 and i <= q2)
  end
  local function want_hunk(r)
    if not q1 then
      return true
    end
    local eff_e = math.max(r.s, r.e)
    return r.s <= q2 and eff_e >= q1
  end
  local out, cursor = {}, 1
  for _, r in ipairs(kept) do
    for i = cursor, r.s - 1 do
      if want_line(i) then
        out[#out + 1] = lines[i]
      end
    end
    if want_hunk(r) then
      for _, line in ipairs(r.old) do
        out[#out + 1] = line
      end
    end
    cursor = math.max(cursor, r.e + 1)
  end
  for i = cursor, #lines do
    if want_line(i) then
      out[#out + 1] = lines[i]
    end
  end
  return out, #kept, first_reason, skipped
end

---
--- True iff buffer-owned text differs from the bytes on disk. Human text outside every
--- pending hunk passes through the substitution unchanged and is exactly what can make
--- this true.
---
--- `blocks` is the caller's current PENDING set (nil/empty means "none
--- pending here", e.g. after the buffer has been fully reset to turn-start
--- bytes) -- a block already decided (no live extmark) is harmlessly skipped
--- by `_compose_buffer_owned_lines` rather than substituted.
---
--- `path` with no readable disk bytes (new/unwritten file) yields
--- `modified = true`, matching Vim's own reading of a buffer with nothing on
--- disk yet.
function M._recompute_modified(bufnr, blocks, path)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local composed = M._compose_buffer_owned_lines(bufnr, blocks or {})
  local composed_bytes = M._encode_buffer_lines(bufnr, composed)
  local on_disk = path and diff.read_file_bytes(path) or nil
  vim.bo[bufnr].modified = not (on_disk ~= nil and composed_bytes == on_disk)
end

  return {
    live_block_range = live_block_range,
    lines_equal = lines_equal,
  }
end

return M
