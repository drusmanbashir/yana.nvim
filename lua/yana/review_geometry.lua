-- Diff geometry, buffer focus, navigation, and undo helpers.
local Factory = {}

function Factory.new(deps)
  local M = deps.facade
  local diff = deps.diff
  local review_buffer_factory = deps.review_buffer_factory
  local notify_one_line = deps.notify_one_line
  local log = deps.log
  local function live_block_range(...)
    return deps.fn.live_block_range(...)
  end

  -- Line space and the diff -> buffer-coordinate conversion live in their own
  -- pure module; re-exported here so `inline.build_diff_blocks` and the facade
  -- fields every caller already uses keep working unchanged.
  local line_space = require("yana.review_line_space")
  local split_lines = line_space.split_lines
  local buffer_lines = line_space.buffer_lines
  M.build_diff_blocks = line_space.build_diff_blocks

  local function win_for_buf(bufnr)
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_get_buf(w) == bufnr then
          return w, tab
        end
      end
    end
    return nil, nil
  end

  -- Show the review buffer and put the cursor in it. Finding is local; PLACING a buffer
  -- no window shows belongs to review_tabs (`M._review_tabs_place`): it is the one
  -- function that opens review tabs, mirrors the sidebar into them and records
  -- ownership, and it never moves the cursor -- that is this function's job. Returns
  -- nil when nothing can show the buffer (e.g.
  local function focus_buf(path, bufnr)
    local win, tab = win_for_buf(bufnr)
    if not (win and vim.api.nvim_win_is_valid(win)) then
      local place = M._review_tabs_place
      local placed = type(place) == "function" and place(path, bufnr) or nil
      if type(placed) ~= "table" or placed.kind == "none" or not placed.win then
        return nil
      end
      win, tab = placed.win, placed.tab
    end
    if tab and vim.api.nvim_tabpage_is_valid(tab) then
      pcall(vim.api.nvim_set_current_tabpage, tab)
    end
    if not pcall(vim.api.nvim_set_current_win, win) then
      return nil
    end
    return bufnr, win_for_buf(bufnr)
  end

  -- what they said. Computed on refusal branches only, so the cost is off the
  -- hot path by construction.
  local function fingerprint(text)
    if type(text) ~= "string" then
      return nil
    end
    local ok, digest = pcall(function()
      return require("yana.safety.hash").hash_bytes(text)
    end)
    if not ok or type(digest) ~= "string" then
      return nil
    end
    return digest:sub(1, 16)
  end

  -- Full 64-hex content fingerprint, the shape the diary's CAS compares
  -- (`safety/diary.lua` rejects anything shorter). `fingerprint` above truncates
  -- to 16 for human-readable evidence and must not be used where the applier
  -- will compare the value.
  local function base_fingerprint(text)
    if type(text) ~= "string" then
      return nil
    end
    local ok, digest = pcall(function()
      return require("yana.safety.hash").hash_bytes(text)
    end)
    if not ok or type(digest) ~= "string" then
      return nil
    end
    return digest
  end

  -- Refusals return (nil, message, detail). `detail.reason` is the machine
  -- classification the log records — a system refusal is not a user decision,
  -- and reading the two as one is what made review churn unattributable.
  local function stale_refusal(msg, expected, actual)
    return nil, msg, {
      reason = "stale_file",
      expected_fp = fingerprint(expected),
      actual_fp = fingerprint(actual),
    }
  end

  -- WHO moved the file. `stale_file` says only that disk stopped matching the
  -- turn-start bytes; it cannot say whether a HUMAN saved during review or the
  -- AGENT overwrote its own edit inside the same turn, and those are opposite
  -- diagnoses -- a race with the operator versus the agent fighting itself. The
  -- corpus showed 18 refusals in one session with no way to split them.
  --
  -- The datum that separates them is already in hand at every drift refusal:
  -- when the agent self-wrote, the bytes on disk ARE this change's own
  -- after-content, so `actual_fp` equals fingerprint(change.after). Nothing else
  -- produces that collision by accident. It was recorded and never compared.
  --
  -- Guessing "external" here would dress an absence of evidence up as a finding. Nil
  -- origin means this refusal is not a drift refusal at all (no `actual_fp`), where a
  -- missing field is honest and an "unknown" would imply a comparison was attempted.
  local SELF_WRITE_REASON = "agent_self_write"

  local function attribute_drift(change, reason, actual_fp)
    if type(actual_fp) ~= "string" then
      return nil, reason
    end
    if type(change) ~= "table" or type(change.after) ~= "string" then
      return "unknown", reason
    end
    local after_fp = fingerprint(change.after)
    if type(after_fp) ~= "string" then
      return "unknown", reason
    end
    if after_fp == actual_fp then
      return "agent", SELF_WRITE_REASON
    end
    return "external", reason
  end

  --- Close the buffer's current undo block, so the NEXT buffer change starts a
  --- new one and plain `u` stops one step short of it.
  ---
  --- THE MECHANISM, and why it is this one. Neovim exposes no API for it: undo blocks
  --- are closed by `u_sync`, which the editor runs by itself every time the main loop
  --- goes idle waiting for the operator's next key. Setting 'undolevels' to its own
  --- value is Vim's OWN documented way to ask for that sync out of band (`:h
  --- undo-blocks`), and it is the only one.
  ---
  --- WHERE IT ACTUALLY MATTERS. through nvim_input and the real normal-mode loop):
  --- three `ca` presses on a three-hunk review already land in three separate undo
  --- blocks with nothing added here -- the idle between two keypresses closes them.
  ---
  --- A decision that rewrites no bytes therefore cannot cost the operator a `u` that
  --- appears to do nothing.
  local function break_undo_block(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
      return
    end
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("let &undolevels = &undolevels")
    end)
  end

  --- Where this buffer currently sits in ITS OWN undo tree. An INTEGER, and that is the
  --- whole point: Yana bookmarks positions in Neovim's history and never holds a copy
  --- of the bytes at one. Every byte restoration in this file's undo paths is `:undo
  --- {seq}` -- the editor moving its own buffer -- so there is no second copy of the
  --- text that could disagree with it.
  local function buf_undo_seq(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
      return nil
    end
    local seq
    pcall(vim.api.nvim_buf_call, bufnr, function()
      seq = (vim.fn.undotree() or {}).seq_cur
    end)
    return seq
  end

  local function replace_line_span(lines, start_line, end_line, replacement)
    local out = {}
    for i = 1, math.max(0, start_line - 1) do
      out[#out + 1] = lines[i]
    end
    for _, line in ipairs(replacement or {}) do
      out[#out + 1] = line
    end
    for i = math.max(start_line, end_line + 1), #lines do
      out[#out + 1] = lines[i]
    end
    return out
  end

  local function lines_after_pending_withheld(lines, blocks)
    local out = vim.deepcopy(lines or {})
    local ordered = vim.deepcopy(blocks or {})
    table.sort(ordered, function(a, b)
      return (a.new_start_line or math.huge) < (b.new_start_line or math.huge)
    end)
    local offset = 0
    for _, block in ipairs(ordered) do
      local start_line = (block.new_start_line or block.start_line or 1) + offset
      local end_line = start_line + math.max(#(block.new_lines or {}), 1) - 1
      if #(block.new_lines or {}) == 0 then
        end_line = start_line - 1
      end
      out = replace_line_span(out, start_line, end_line, block.old_lines or {})
      offset = offset + #(block.old_lines or {}) - #(block.new_lines or {})
    end
    return out
  end

  local function lines_after_sealed_accepts(before, decisions)
    local out = buffer_lines(before or "")
    local accepted = {}
    for _, decision in ipairs(decisions or {}) do
      if decision.action == "accept" and decision.block then
        accepted[#accepted + 1] = decision.block
      end
    end
    if #accepted == 0 then
      return nil
    end
    table.sort(accepted, function(a, b)
      return (a.start_line or math.huge) < (b.start_line or math.huge)
    end)
    local offset = 0
    for _, block in ipairs(accepted) do
      local start_line = (block.start_line or 1) + offset
      local end_line = (block.end_line or start_line) + offset
      out = replace_line_span(out, start_line, end_line, block.new_lines or {})
      offset = offset + #(block.new_lines or {}) - #(block.old_lines or {})
    end
    return out
  end

  function M._parked_dirty_explained_by_decisions(change, parked)
    if not (type(change) == "table" and type(parked) == "table" and type(parked.staged_text) == "string") then
      return false
    end
    local expected = lines_after_sealed_accepts(change.before or "", parked.sealed_decisions or {})
    if not expected then
      return false
    end
    local buffer_owned = lines_after_pending_withheld(buffer_lines(parked.staged_text), parked.blocks or {})
    if #buffer_owned ~= #expected then
      return false
    end
    for i, line in ipairs(buffer_owned) do
      if line ~= expected[i] then
        return false
      end
    end
    return true
  end

  local review_buffer = review_buffer_factory.new({
    buffer_lines = buffer_lines,
    buf_undo_seq = buf_undo_seq,
    break_undo_block = break_undo_block,
    stale_refusal = stale_refusal,
    base_fingerprint = base_fingerprint,
    parked_dirty_explained = function(change, parked)
      return M._parked_dirty_explained_by_decisions(change, parked)
    end,
  })
  local open_review_buffer = review_buffer.open


  --- `direction` (optional) is set ONLY by navigation (`]x`/`[x`). Two pending
  --- hunks can share a line (2:[18..19] and 3:[19..21] share 19); resolving that
  --- line to the first match makes `idx == #blocks` unreachable, so `]x` never
  --- parks and the cursor is pinned. Navigation therefore reads the LAST
  --- overlapping match travelling "next" and the FIRST travelling "prev" -- the
  --- block the direction is leaving. Accept/reject pass no direction and keep
  --- the first match unchanged: which hunk `ca`/`cr` decides must not move.
  local function current_block(blocks, bufnr, direction)
    -- No window showing the review buffer means no meaningful cursor: falling
    -- back to window 0 would resolve hunks against an unrelated buffer's cursor
    -- line. The hunk keymaps are buffer-local, so in real use this is non-nil.
    local win = win_for_buf(bufnr)
    if not win then
      return nil, nil
    end
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    local last, last_idx = nil, nil
    for idx, block in ipairs(blocks) do
      local start_line, end_line = live_block_range(bufnr, block)
      if start_line then
        local eff_end = math.max(end_line, start_line)
        if cursor_line >= start_line and cursor_line <= eff_end then
          if direction ~= "next" then
            return block, idx
          end
          last, last_idx = block, idx
        end
      end
    end
    return last, last_idx
  end

  local function nav_start_line(bufnr, block)
    -- Navigation reads the SAME authority accept/reject read (live_block_range).
    -- `block.new_start_line` is computed when the diff is built and never moves,
    -- so once the human types a line above a hunk the two disagree and `]x`
    -- lands that many lines short. The stored integer is a last resort for an
    -- invalidated mark, and taking it is STATED, not silent.
    local start_line, end_line = live_block_range(bufnr, block)
    if start_line then
      return start_line, math.max(end_line, start_line)
    end
    local fallback = block.new_start_line
    if not block.nav_fallback_stated then
      block.nav_fallback_stated = true
      local said = string.format(
        "yana: hunk extmark invalidated -- navigation fell back to the stored line %s",
        tostring(fallback)
      )
      -- On screen, like every other refusal in this file, AND in the log so the
      -- statement outlives the message area. Once per block: navigation runs on
      -- keypresses and cursor moves, and a per-event warning would be noise.
      notify_one_line(said, vim.log.levels.WARN)
      log.write("WARN", said)
    end
    return fallback, math.max(block.new_end_line or fallback, fallback)
  end

  local function nearest_block(blocks, bufnr, direction)
    local win = win_for_buf(bufnr) or 0
    local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
    if #blocks == 0 then
      return nil
    end

    local starts = {}
    for i, block in ipairs(blocks) do
      local start_line, eff_end = nav_start_line(bufnr, block)
      starts[i] = start_line
      if cursor_line >= start_line and cursor_line <= eff_end then
        local j = direction == "next" and (i % #blocks) + 1 or ((i - 2) % #blocks) + 1
        return blocks[j]
      end
    end

    local best_idx, best_dist = nil, nil
    for i, _ in ipairs(blocks) do
      local dist = direction == "next" and (starts[i] - cursor_line)
        or (cursor_line - starts[i])
      if direction == "next" and starts[i] > cursor_line then
        if best_dist == nil or dist < best_dist then
          best_dist, best_idx = dist, i
        end
      elseif direction == "prev" and starts[i] < cursor_line then
        if best_dist == nil or dist < best_dist then
          best_dist, best_idx = dist, i
        end
      end
    end
    if best_idx then
      return blocks[best_idx]
    end
    return direction == "next" and blocks[1] or blocks[#blocks]
  end

  local function land_on(path, bufnr, block)
    if path and not focus_buf(path, bufnr) then
      return false
    end
    if not block then
      return true
    end
    local win = win_for_buf(bufnr)
    if not win then
      return false
    end
    -- Clamp, and never throw. Cursor placement is cosmetic; it must never decide
    -- whether a review session survives.
    local total = vim.api.nvim_buf_line_count(bufnr)
    local line = math.max(1, math.min(nav_start_line(bufnr, block), total))
    pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd("normal! zz")
    end)
    return true
  end

  local function insert_new_lines(bufnr, blocks)
    local offset = 0
    for _, block in ipairs(blocks) do
      local start_line = block.start_line + offset
      local end_line = block.end_line + offset
      vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, block.new_lines)
      offset = offset + #block.new_lines - #block.old_lines
    end
  end

  return {
    split_lines = split_lines,
    buffer_lines = buffer_lines,
    win_for_buf = win_for_buf,
    focus_buf = focus_buf,
    fingerprint = fingerprint,
    base_fingerprint = base_fingerprint,
    stale_refusal = stale_refusal,
    attribute_drift = attribute_drift,
    break_undo_block = break_undo_block,
    buf_undo_seq = buf_undo_seq,
    replace_line_span = replace_line_span,
    lines_after_pending_withheld = lines_after_pending_withheld,
    lines_after_sealed_accepts = lines_after_sealed_accepts,
    review_buffer = review_buffer,
    open_review_buffer = open_review_buffer,
    current_block = current_block,
    nav_start_line = nav_start_line,
    nearest_block = nearest_block,
    land_on = land_on,
    insert_new_lines = insert_new_lines,
  }
end

return Factory
