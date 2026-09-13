-- LINE SPACE: the one place that decides what counts as a LINE, and the
-- diff-to-buffer-coordinate conversion built on that decision.
--
-- Everything here is a pure function of its arguments -- no facade, no deps, no buffers
-- -- and it is the only code in the tree allowed to turn a pair of file texts into hunk
-- COORDINATES. Keeping it beside window focus and navigation helpers was what let the
-- diff side and the paint side drift into two different ideas of a trailing newline.
local M = {}

local function split_lines(text)
  if text == nil or text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

-- Buffer lines for a snapshot string. A trailing "\n" splits into a final ""
-- element, which as a buffer line is a real blank line: harmless while resolve
-- wrote an exact string through io.open, but now that resolve saves the buffer
-- itself that phantom line lands on disk as an extra newline. Drop it here and
-- let 'endofline'/'fixendofline' decide the final newline at write time.
local function buffer_lines(text)
  local lines = split_lines(text)
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

-- A final "\n" is a line TERMINATOR, not a line. `buffer_lines` above already
-- says so for the paint side; this says it for the diff side, and both must
-- agree or the coordinates handed to the ledger are in a different space from
-- the buffer they index. Terminate a non-empty text that does not end in one.
--
-- "" stays "": a text with NO lines and a text with ONE BLANK line are different files,
-- and `before == nil` (a create) arrives here as "". Adding a newline there would give
-- a created file a phantom line 1 for its first hunk to start on -- the create path
-- deliberately strips a created file's trailing newline (review_model.lua:16-22), so it
-- is exactly the caller that would be shifted.
local function terminate(text)
  if text ~= "" and text:sub(-1) ~= "\n" then
    return text .. "\n"
  end
  return text
end

-- Diffs before/after into hunk blocks with old/new lines and positions.
function M.build_diff_blocks(before, after)
  local old_str = before or ""
  local new_str = after or ""
  if old_str == new_str then
    return {}
  end

  -- COORDINATES, NOT CHARACTERS. The same artefact reports a last-line DELETE as a
  -- two-line replace. The buffer these coordinates index has no such distinction, so
  -- put both sides in the buffer's own space before diffing rather than unpicking the
  -- replace afterwards from the characters it happens to contain.
  old_str, new_str = terminate(old_str), terminate(new_str)

  local old_lines = split_lines(old_str)
  local new_lines = split_lines(new_str)
  -- ctxlen is how many UNCHANGED lines must separate two changes before vim.diff calls
  -- them SEPARATE hunks, so it decides hunk boundaries and must never come from a
  -- display option. `vim.o.scrolloff` was passed here (inherited from avante); at
  -- scrolloff >= 5 two changes a few lines apart arrived as ONE hunk spanning both,
  -- swallowing the untouched lines between them, so the operator could not decide them
  -- separately. 0 also matches settlement (turn_settle.lua:46) and every other vim.diff
  local patch = vim.diff(old_str, new_str, {
    algorithm = "histogram",
    result_type = "indices",
    ctxlen = 0,
  })

  local blocks = {}
  for _, hunk in ipairs(patch) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    local start_line, end_line
    if count_a == 0 then
      -- Pure insert: nvim_buf_set_lines uses [start_line-1, end_line) with end_line < start_line.
      -- vim.diff: start_a = line AFTER which to insert (0 = BOF).
      start_line = start_a + 1
      end_line = start_a
    else
      start_line = start_a
      end_line = start_a + count_a - 1
    end
    local block = {
      old_lines = count_a > 0 and vim.list_slice(old_lines, start_a, start_a + count_a - 1) or {},
      new_lines = count_b > 0 and vim.list_slice(new_lines, start_b, start_b + count_b - 1) or {},
      start_line = start_line,
      end_line = end_line,
    }
    table.insert(blocks, block)
  end

  local base = 0
  for _, block in ipairs(blocks) do
    block.new_start_line = block.start_line + base
    block.new_end_line = block.new_start_line + #block.new_lines - 1
    base = base + #block.new_lines - #block.old_lines
  end
  return blocks
end

M.split_lines = split_lines
M.buffer_lines = buffer_lines

return M
