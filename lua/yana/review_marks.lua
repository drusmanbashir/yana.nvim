-- Authority marks and modified-buffer accounting.
local M = {}

function M.new(deps)
  local M = deps.facade
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

--- Neovim owns the modified flag, so a decision no longer sets it by
--- comparing the buffer with the file on disk. Kept as a no-op for its four
--- callers outside this module until they are removed.
function M._recompute_modified(_bufnr, _blocks, _path)
end

  return {
    live_block_range = live_block_range,
    lines_equal = lines_equal,
  }
end

return M
