-- yana: rung-1 render reconciliation — state plane vs decoration plane.
--
-- A rendering defect is the class where every internal source says the right
-- thing and the user sees the wrong thing. Rung 1 is the first seam of the
-- truth ladder: what the review engine BELIEVES it drew, against the extmarks
-- Neovim actually holds, against the change model the hunks came from.
--
-- Five checks come from the brainstorm's §4.2 (orphaned bookkeeping, leaked
-- decoration, drift, unresolvable highlight group, lost window mapping). The
-- sixth is the N8 addition and the reason this exists at all:
--
--   MODEL EXTENT — for every hunk, the number of buffer rows actually covered
--   by new-line highlight extmarks must equal the hunk's new-line count IN THE
--   CHANGE MODEL. Comparing applied decoration against block bookkeeping alone
--   passes when the intended range is itself short by a row, which is exactly
--   the shape of the reference defect (N new lines, N−1 highlighted).
--
-- The model arrives from the caller and this module never builds one. What it
-- does guarantee is that it never INVENTS one: a block the caller could not
-- join to a model hunk is recorded as `model_unavailable`, carrying the
-- caller's `model_join` reason and `model_source`, and is never scored against
-- the block's own numbers. The independence of the model is the caller's
-- contract (see inline_diff.payload_model); the refusal to substitute for it
-- is this module's.
--
-- Row coverage is computed the way the compositor resolves it, not the way the
-- call site meant it: an extmark spanning (start_row,0) → (end_row,end_col)
-- covers rows start_row … end_row−1 in full, and covers end_row only when
-- end_col > 0. An `hl_eol` mark whose end_col is 0 therefore leaves its last
-- row unpainted — the fencepost this check exists to name.
--
-- Contract: this module is an OBSERVER. `evaluate` is pure (no API calls, no
-- side effects, no I/O); `collect` performs read-only API calls; neither ever
-- repairs, refuses, or changes control flow. The caller decides what to do
-- with a violation, and the only permitted action is to record it.
local M = {}

-- Violation kinds. Stable strings: gate fixtures assert on them.
M.KIND = {
  orphaned = "orphaned_bookkeeping",
  leaked = "leaked_decoration",
  drift = "drift",
  unresolvable = "unresolvable_hl",
  lost_winhl = "lost_window_mapping",
  model_extent = "model_extent",
  model_unavailable = "model_unavailable",
}

-- How far an extmark may sit from the row its block claims before it is drift
-- rather than ordinary gravity. Extmarks are position authority in this engine,
-- so movement is legal; unbounded movement is not.
M.DRIFT_ROWS = 100

--- Rows a highlight extmark actually paints, given how Neovim resolves an
--- extmark range. Pure arithmetic on the details table.
function M.covered_rows(mark)
  if type(mark) ~= "table" then
    return 0
  end
  local sr = mark.row or 0
  local er = mark.end_row
  local ec = mark.end_col or 0
  if er == nil then
    -- No end position: the mark decorates its own row only if it carries an
    -- end column past the start.
    return (ec > (mark.col or 0)) and 1 or 0
  end
  if er < sr then
    return 0
  end
  local rows = er - sr
  if ec > 0 then
    rows = rows + 1
  end
  return rows
end

local function attrs_empty(attrs)
  if type(attrs) ~= "table" then
    return true
  end
  return next(attrs) == nil
end

local function same_ground(attrs, normal)
  if type(attrs) ~= "table" or type(normal) ~= "table" then
    return false
  end
  -- Only a group with NO distinguishing attribute of its own and the same
  -- background as Normal is invisible. A group that sets fg, bold, underline
  -- or anything else still renders.
  local keys = 0
  for _ in pairs(attrs) do
    keys = keys + 1
  end
  if keys == 0 then
    return true
  end
  if attrs.bg ~= nil and normal.bg ~= nil and attrs.bg == normal.bg then
    return attrs.fg == nil or attrs.fg == normal.fg
  end
  return false
end

----------------------------------------------------------------------
-- the pure core
----------------------------------------------------------------------

--- Reconcile one review's state against its gathered decoration facts.
--- `input` is whatever `collect` produced (or a fixture's hand-built table).
--- Returns a result record; never throws for a malformed input, because a
--- check that can crash the render path is worse than the defect it looks for.
function M.evaluate(input)
  input = input or {}
  local result = {
    ok = true,
    site = input.site,
    change_id = input.change_id,
    rel = input.rel,
    bufnr = input.bufnr,
    line_count = input.line_count,
    violations = {},
    hunks = {},
    groups = input.groups or {},
    windows = input.windows or {},
    counts = { blocks = 0, marks = 0, hint_marks = input.hint_mark_count or 0, violations = 0 },
    model_source = input.model_source or (input.model and "change_payload" or "unavailable"),
  }

  local function violate(kind, fields)
    local v = fields or {}
    v.kind = kind
    result.violations[#result.violations + 1] = v
    result.ok = false
  end

  local marks = input.marks or {}
  local by_id = {}
  for _, m in ipairs(marks) do
    by_id[m.id] = m
  end
  result.counts.marks = #marks

  local claimed = {}
  local blocks = input.blocks or {}
  result.counts.blocks = #blocks

  for _, block in ipairs(blocks) do
    local incoming = block.incoming_extmark_id and by_id[block.incoming_extmark_id] or nil
    local deleted = block.delete_extmark_id and by_id[block.delete_extmark_id] or nil
    if block.incoming_extmark_id then
      claimed[block.incoming_extmark_id] = true
    end
    -- A hunk with a human row inside it paints as SEVERAL incoming marks with
    -- a gap where the human's text is (inline_diff set_incoming_paint), so the
    -- single-id field names only the first. Claim every one of them, or the
    -- rest read as orphan marks nobody owns — which is a false alarm about the
    -- exact rendering the gap was introduced to make honest.
    for _, extra in ipairs(block.incoming_extmark_ids or {}) do
      claimed[extra] = true
    end
    if block.delete_extmark_id then
      claimed[block.delete_extmark_id] = true
    end

    local model = nil
    if input.model and block.model_index then
      model = input.model[block.model_index]
    end
    -- N16: a context-merged block is scored against the model SPAN the join
    -- derived for it (first spanned run's first new line .. last spanned run's
    -- last new line), not against run `mi` alone — otherwise a healthy merged
    -- render reads as an extent defect. Both numbers come from the model.
    local model_new = model and model.new_count or nil
    if block.model_span_new_count then
      model_new = block.model_span_new_count
    end
    local applied = incoming and M.covered_rows(incoming) or 0
    local hunk = {
      index = block.index,
      model_index = block.model_index,
      model_join = block.model_join,
      model_source = input.model_source,
      old_count = block.old_count,
      new_count = block.new_count,
      model_old_count = model and model.old_count or nil,
      model_new_count = model_new,
      model_span_last = block.model_span_last,
      new_start_line = block.new_start_line,
      new_end_line = block.new_end_line,
      intended_rows = block.new_count or 0,
      applied_rows = applied,
      start_row = incoming and incoming.row or nil,
      end_row = incoming and incoming.end_row or nil,
      end_col = incoming and incoming.end_col or nil,
      hl_groups = {},
      incoming_present = incoming ~= nil,
      delete_present = deleted ~= nil,
      verdict = "ok",
    }
    if incoming and incoming.hl_group then
      hunk.hl_groups[#hunk.hl_groups + 1] = incoming.hl_group
    end
    if deleted then
      hunk.deleted_virt_lines = deleted.virt_lines_count
    end

    -- 1. orphaned bookkeeping: the block names an extmark Neovim does not have.
    if block.incoming_extmark_id and not incoming then
      hunk.verdict = M.KIND.orphaned
      violate(M.KIND.orphaned, {
        hunk = block.index,
        extmark = "incoming",
        extmark_id = block.incoming_extmark_id,
      })
    end
    if block.delete_extmark_id and not deleted then
      hunk.verdict = hunk.verdict == "ok" and M.KIND.orphaned or hunk.verdict
      violate(M.KIND.orphaned, {
        hunk = block.index,
        extmark = "deleted",
        extmark_id = block.delete_extmark_id,
      })
    end

    -- 3. drift: the mark sits far from the row the block claims.
    if incoming and block.new_start_line then
      local mark_line = (incoming.row or 0) + 1
      local delta = math.abs(mark_line - block.new_start_line)
      hunk.drift = delta
      if delta > M.DRIFT_ROWS then
        hunk.verdict = M.KIND.drift
        violate(M.KIND.drift, {
          hunk = block.index,
          expected = block.new_start_line,
          got = mark_line,
          bound = M.DRIFT_ROWS,
        })
      end
    end

    -- 6. MODEL EXTENT: rows actually painted vs the change model's new-line
    -- count. This is the check that sees the reference defect; every other
    -- check on this hunk can pass while this one fails.
    if block.model_join == "no_new_lines" or (block.new_count or 0) == 0 then
      -- A pure deletion paints no rows and has no run to join to. The
      -- comparison is not unavailable, it is trivially satisfied — and it is
      -- still a comparison: decoration on a hunk with no new lines is a defect.
      hunk.model_new_count = 0
      if applied ~= 0 then
        hunk.verdict = M.KIND.model_extent
        violate(M.KIND.model_extent, {
          hunk = block.index,
          rel = input.rel,
          expected = 0,
          got = applied,
          intended = hunk.intended_rows,
          detail = "rows painted on a hunk with no new lines",
        })
      end
    elseif model_new == nil then
      -- The model could not speak for THIS hunk. Recorded, never guessed: a
      -- fabricated expectation here would be exactly the twin-comparison this
      -- check was rebuilt to stop being. `detail` names which of the join's
      -- refusals fired, so a run of these is diagnosable rather than mysterious.
      hunk.verdict = hunk.verdict == "ok" and M.KIND.model_unavailable or hunk.verdict
      violate(M.KIND.model_unavailable, {
        hunk = block.index,
        model_index = block.model_index,
        model_source = input.model_source,
        detail = block.model_join or "no model hunk for this block",
      })
    elseif applied ~= model_new then
      hunk.verdict = M.KIND.model_extent
      violate(M.KIND.model_extent, {
        hunk = block.index,
        rel = input.rel,
        expected = model_new,
        got = applied,
        intended = hunk.intended_rows,
        new_start_line = block.new_start_line,
        start_row = hunk.start_row,
        end_row = hunk.end_row,
        end_col = hunk.end_col,
      })
    end

    -- N16: `verdict` says HOW the hunk was reconciled, and a context-merged
    -- block is a weaker certification than a 1:1 run join even when its extent
    -- is right: the span matches, but rows cannot be attributed to individual
    -- payload runs. Name that state rather than let it wear the plain "ok" of a
    -- block the model spoke for line by line. Not a violation — `result.ok`
    -- stays true and nothing WARNs.
    if hunk.verdict == "ok" and block.model_span_new_count then
      hunk.verdict = "model_span"
    end

    result.hunks[#result.hunks + 1] = hunk
  end

  -- 2. leaked decoration: a mark in our namespace no block claims.
  for _, m in ipairs(marks) do
    if not claimed[m.id] then
      violate(M.KIND.leaked, { extmark_id = m.id, row = m.row, hl_group = m.hl_group })
    end
  end

  -- 4. cleared or invisible highlight groups. Walked in NAME ORDER, not hash
  -- order: the violation list is part of the record's signature, and a
  -- signature that reorders between two identical states would defeat the
  -- de-duplication that keeps one defect to one log record.
  local group_names = {}
  for name in pairs(result.groups) do
    group_names[#group_names + 1] = name
  end
  table.sort(group_names)
  for _, name in ipairs(group_names) do
    local info = result.groups[name]
    if info.required then
      if attrs_empty(info.attrs) then
        violate(M.KIND.unresolvable, { group = name, detail = "resolves to an empty attribute set" })
        info.ok = false
      elseif same_ground(info.attrs, input.normal) then
        violate(M.KIND.unresolvable, { group = name, detail = "indistinguishable from Normal" })
        info.ok = false
      else
        info.ok = true
      end
    end
  end

  -- 5. lost window mapping: a window showing the review buffer whose winhl no
  -- longer carries the Yana mappings.
  for _, w in ipairs(result.windows) do
    if not w.mapped then
      violate(M.KIND.lost_winhl, { win = w.win, winhl = w.winhl })
    end
  end

  result.counts.violations = #result.violations
  result.signature = M.signature(result)
  return result
end

--- A stable string identifying WHAT is wrong (not when). Capture sites use it
--- to write one record per distinct defect instead of one per re-render: a
--- review re-renders on every resolved hunk, and an unchanged defect repeated
--- forty times is noise that buries the first occurrence.
function M.signature(result)
  local parts = {}
  for _, v in ipairs(result.violations or {}) do
    parts[#parts + 1] = table.concat({
      v.kind,
      tostring(v.hunk or v.group or v.win or v.extmark_id or "-"),
      tostring(v.expected or "-"),
      tostring(v.got or "-"),
    }, ":")
  end
  -- Sorted, so the same defect set always produces the same string no matter
  -- what order the checks happened to emit it in.
  table.sort(parts)
  table.insert(parts, 1, result.ok and "ok" or "bad")
  table.insert(parts, 1, tostring(result.change_id or "?"))
  return table.concat(parts, "|")
end

--- One-line human summary of a result, for the WARN record.
function M.summarize(result)
  if result.ok then
    return string.format(
      "render check ok: %s (%d hunks, %d marks)",
      result.rel or tostring(result.change_id),
      result.counts.blocks,
      result.counts.marks
    )
  end
  local seen, kinds = {}, {}
  for _, v in ipairs(result.violations) do
    if not seen[v.kind] then
      seen[v.kind] = true
      kinds[#kinds + 1] = v.kind
    end
  end
  local worst = nil
  for _, v in ipairs(result.violations) do
    if v.kind == M.KIND.model_extent then
      worst = string.format(" hunk %s expected %s highlighted row(s), applied %s", tostring(v.hunk), tostring(v.expected), tostring(v.got))
      break
    end
  end
  return string.format(
    "render check FAILED: %s at %s — %d violation(s) [%s]%s; :YanaRenderCheck for detail, :YanaDump for state",
    result.rel or tostring(result.change_id),
    result.site or "render",
    result.counts.violations,
    table.concat(kinds, ","),
    worst or ""
  )
end

----------------------------------------------------------------------
-- gathering (read-only API calls)
----------------------------------------------------------------------

local function mark_list(bufnr, ns)
  local ok, raw = pcall(vim.api.nvim_buf_get_extmarks, bufnr, ns, 0, -1, { details = true })
  if not ok or type(raw) ~= "table" then
    return {}
  end
  local out = {}
  for _, entry in ipairs(raw) do
    local id, row, col, details = entry[1], entry[2], entry[3], entry[4] or {}
    out[#out + 1] = {
      id = id,
      row = row,
      col = col,
      end_row = details.end_row,
      end_col = details.end_col,
      hl_group = details.hl_group,
      hl_eol = details.hl_eol,
      priority = details.priority,
      virt_lines_count = details.virt_lines and #details.virt_lines or nil,
      virt_text = details.virt_text and true or nil,
      invalid = details.invalid,
    }
  end
  return out
end

M.mark_list = mark_list

--- Read the decoration facts for one review. `desc` names everything this
--- module is not allowed to know on its own:
---   bufnr, ns, hint_ns, blocks, model, ext_hl, palette, change_id, rel, site
function M.collect(desc)
  desc = desc or {}
  local bufnr = desc.bufnr
  local input = {
    site = desc.site,
    change_id = desc.change_id,
    rel = desc.rel,
    bufnr = bufnr,
    model = desc.model,
    model_source = desc.model_source,
    blocks = {},
    marks = {},
    groups = {},
    windows = {},
  }
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    input.buffer_valid = false
    return input
  end
  input.buffer_valid = true
  input.line_count = vim.api.nvim_buf_line_count(bufnr)

  for i, block in ipairs(desc.blocks or {}) do
    input.blocks[#input.blocks + 1] = {
      index = i,
      model_index = block.model_index,
      new_start_line = block.new_start_line,
      new_end_line = block.new_end_line,
      old_count = #(block.old_lines or {}),
      new_count = #(block.new_lines or {}),
      -- Why this block does or does not have a model hunk. Set once by
      -- inline_diff.stamp_model_index; carried here so a `model_unavailable`
      -- record says which refusal fired instead of just "no model".
      model_join = block.model_join,
      -- N16: at ctxlen > 0 one block can span several payload runs. The join
      -- derives the span's new-line count from the model (see
      -- inline_diff.stamp_model_index) and hands it over here; this module
      -- still never computes a model of its own.
      model_span_last = block.model_span_last,
      model_span_new_count = block.model_span_new_count,
      incoming_extmark_id = block.incoming_extmark_id,
      delete_extmark_id = block.delete_extmark_id,
    }
  end

  input.marks = mark_list(bufnr, desc.ns)
  if desc.hint_ns then
    input.hint_mark_count = #mark_list(bufnr, desc.hint_ns)
  end

  -- Highlight resolution. The extmarks name the EXT_HL groups, which are
  -- deliberately undefined globally: they are mapped per window through winhl
  -- onto the palette groups. So the group that must RESOLVE is the palette
  -- one, and the mapping is checked separately below.
  local function resolve(name, required)
    local ok, attrs = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    input.groups[name] = {
      required = required and true or false,
      defined = ok and type(attrs) == "table" and next(attrs) ~= nil or false,
      attrs = ok and attrs or nil,
    }
  end
  for _, name in pairs(desc.palette or {}) do
    resolve(name, true)
  end
  for _, name in pairs(desc.ext_hl or {}) do
    resolve(name, false)
  end
  local ok_normal, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
  input.normal = ok_normal and normal or nil

  -- Per-window mapping. A window created by another plugin that sets its own
  -- winhl afterwards wins, and nothing fires when it does.
  local wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      wins[#wins + 1] = win
    end
  end
  for _, win in ipairs(wins) do
    local ok_hl, winhl = pcall(function()
      return vim.wo[win].winhl
    end)
    winhl = ok_hl and winhl or ""
    local mapped = true
    for role, ext in pairs(desc.ext_hl or {}) do
      local target = (desc.palette or {})[role]
      if target and not winhl:find(ext .. ":" .. target, 1, true) then
        mapped = false
      end
    end
    input.windows[#input.windows + 1] = { win = win, winhl = winhl, mapped = mapped }
  end
  input.window_count = #wins

  return input
end

--- collect + evaluate. The one call a capture site makes.
function M.run(desc)
  return M.evaluate(M.collect(desc))
end

return M
