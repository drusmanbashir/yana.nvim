-- Reading the world for one Turn file: line ownership and the frozen
-- projection INPUT. The file on disk is not read here, beyond whether a
-- creation's path exists
-- (disk and buffer-write audit). Split out of `turn_settle.lua`, which had grown past
-- 500 lines carrying two jobs -- deciding what is true, and acting on it. This
-- half only decides what is true. It calculates no action, no target bytes and
-- no mode, opens no write door and touches no buffer; `turn_settle` owns all of
-- that and is this module's only caller.
local creation_touch = require("yana.paths.creation_touch")
local diff = require("yana.diff")

local M = {}

-- `turn_settle` is required LAZILY, inside the one function that needs it:
-- it requires this module at load time, so a top-level require here would be a
-- cycle. `current_mode_verdict` stays its published API rather than moving,
-- because callers outside this pair name it there.

function M.valid_buffer(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

--- THE ONE PLACE A MODE IS NORMALISED. `uv.fs_lstat` reports the full `st_mode`
--- (file type plus permissions) while a change carries permission bits alone
--- (`cli/turn.lua:166-171` bounds them to 0..4095), and an unmasked value
--- once reached `base_mode`. The projection COMPARES mode
--- values and must never parse or format one (rule 7c), so the snapshot adapter
--- owes it values that are comparable. Masking here, once, is that debt paid;
--- the diary applies the same mask before it chmods
--- (`safety/diary_restore_checks.lua:48`).
function M.mode_perm(mode)
  if type(mode) ~= "number" then
    return nil
  end
  return mode % 4096
end

--- LINE OWNERSHIP, RESOLVED ONCE, FROM THE RECORDED EXTENT ALONE. Bytes may
--- VALIDATE the one anchored location; they never SELECT one (no text search).
---
--- An EMPTY extent (`last < first`) is either a reject door's restoration or a
--- pending pure deletion. Every restore door writes `set_lines(start-1, end,
--- restored)` and the transport (`hunk_anchor_splice.band`) leaves the band
--- empty directly BELOW the restored rows, so a rejected hunk's original side
--- must stand at exactly `first-#old .. first-1`. Anything else -- the human
--- deleted or edited those rows, or F-OWN-GAP rows sit among them -- is a named
--- refusal, never a guess.
function M.span_of(block, buffer_lines)
  local first = block.new_start_line
  if first == nil then
    return { first = nil, last = nil }
  end
  local new_lines, old_lines = block.new_lines or {}, block.old_lines or {}
  local last = block.new_end_line or (first + #new_lines - 1)
  if last >= first then
    return { first = first, last = last }
  end
  if block.verdict == "rejected" then
    local top = first - #old_lines
    local standing = top >= 1 and buffer_lines ~= nil
    for index = 1, standing and #old_lines or 0 do
      standing = standing and buffer_lines[top + index - 1] == old_lines[index]
    end
    if standing then
      return { first = first, last = first - 1, restored = true }
    end
    return { unplaced = true, reason = "rejected hunk's original side is not standing at its anchored rows" }
  end
  if #new_lines == 0 then
    return { first = first, last = first - 1 }
  end
  return { unplaced = true, reason = "empty live extent over proposed lines; its original side cannot be placed without a text search" }
end

function M.hunks_of(f, buffer_lines)
  local ledger = f.ledger
  local members = ledger ~= nil and type(ledger.members) == "function" and ledger:members() or {}
  local out = {}
  for index, block in ipairs(members) do
    out[index] = {
      id = block.id or index,
      verdict = block.verdict,
      -- The ORIGINAL-side start, for the bufferless route.
      old_start = block.start_line,
      old_lines = block.old_lines or {},
      new_lines = block.new_lines or {},
      span = M.span_of(block, buffer_lines),
    }
  end
  return out
end

--- Was this path CREATED by the turn? That is the question `original.exists`
--- answers, and it is about identity, not about what is on disk now.
---
--- `creation_touch.is_creation` reads `change.before == nil`, which is the
--- creation marker until Yana's own End write records the bytes it wrote
--- (`turn_file` `record_projection` sets `change.before`); the operator's `:w`
--- never touches it. R6 requires a created file to remain identified as
--- turn-created after saves, so the immutable record answers first: the File's ORIGINAL operation (turn_file fixes it
--- once; `operation` is the selected version's, F-ADDENDUM-CARRY) and then the
--- change's own kind, which no save rewrites.
function M.creation(f, change)
  local original = f.original_operation
  if original == nil then original = f.operation end
  return original == "create"
    or change.kind == "create"
    or creation_touch.is_creation(change)
end

--- The register this file's review rows go to and the Turn id they carry, resolved as the decision and
--- watcher doors push them (`review_decisions`, `review_watch_register`). The Turn's completion releases it.
function M.register_key(f)
  local change = type(f) == "table" and type(f.change) == "table" and f.change or {}
  local opts = type(f) == "table" and ((f.review_state or {}).opts or f.review_opts) or {}
  return change.review_workspace or opts.workspace or vim.fn.getcwd(), change.turn_id or change.turn_gen
end

--- The projection INPUT for one file. Everything the calculation needs, read
--- once, with no calculation of its own: original and proposal sides, the
--- resolved hunks, the two verdicts and the buffer when one is loaded. The
--- proposal side, verdicts, carried acceptance and hunk base are the File's
--- SELECTED VERSION (`File:version`); the original side never is.
function M.snapshot_of(f, purpose)
  local change = type(f.change) == "table" and f.change or {}
  local proposed = type(f.proposal) == "table" and f.proposal or change
  local is_creation = M.creation(f, change)

  local buffer
  -- A delete's review buffer shows the proposal (absence), not the file's content:
  -- composing a kept delete from it adds a trailing blank record (kept.py gains
  -- "\n", an empty file becomes "\n"). A delete projects from original + verdicts.
  if proposed.kind ~= "delete" then
    if purpose == "exit" and type(f.frozen_buffer) == "table" then
      buffer = f.frozen_buffer
    elseif M.valid_buffer(f.bufnr) then
      buffer = {
        lines = vim.api.nvim_buf_get_lines(f.bufnr, 0, -1, false),
        changedtick = vim.api.nvim_buf_get_changedtick(f.bufnr),
        fileformat = vim.bo[f.bufnr].fileformat,
        endofline = vim.bo[f.bufnr].endofline,
        bomb = vim.bo[f.bufnr].bomb,
      }
    end
  end

  return {
    purpose = purpose,
    original = {
      -- A creation had no original side; everything else did.
      exists = not is_creation,
      -- The IMMUTABLE original bytes when the File retains them. `change.before`
      -- is rebased applier evidence and is only the fallback for an entry that
      -- carries no original record.
      bytes = f.base_text or change.before or "",
      mode = M.mode_perm(change.base_mode),
      -- A creation's path EXISTENCE now (one lstat, never content), and whether it
      -- is still exactly the file its review buffer last wrote (stat identity):
      -- only the operator's own save may be removed when a creation ends absent
      -- (CORE "Saving is Neovim's", LEDGER N51).
      present = is_creation and (vim.uv or vim.loop).fs_lstat(change.path or f.path) ~= nil or nil,
      saved = is_creation and require("yana.turn.turn_save_record").matches(change.path or f.path) or nil,
    },
    proposal = {
      exists = proposed.kind ~= "delete",
      bytes = proposed.after,
      mode = M.mode_perm(proposed.after_mode),
    },
    hunks = M.hunks_of(f, buffer and buffer.lines or nil),
    operation_verdict = f.operation_verdict,
    -- Accepted work and the effective accepted mode an earlier cycle's version
    -- owes End, and the text a later version's hunks index (F-ADDENDUM-CARRY).
    carried = f.carried == true,
    accepted_mode = M.mode_perm(f.accepted_mode),
    base = f.version_base,
    versioned = f.version_installed == true,
    -- Rule 7a: the permission record lives on the File as `mode_verdict` and
    -- authorises a mode only for the proposal it records. Absent, or recorded
    -- for a since-revised proposal, the projection defaults to keep, which is
    -- the only safe default.
    mode_verdict = f.mode_verdict ~= nil
      and (require("yana.turn.turn_settle").current_mode_verdict(f) or {}).verdict or nil,
    buffer = buffer,
  }
end

--- The buffer lines `bytes` become in `bufnr`, by its 'fileformat'.
function M.lines_of_bytes(bufnr, bytes)
  local lines = vim.split(bytes, "\n", { plain = true })
  if bytes:sub(-1) == "\n" then
    table.remove(lines)
  end
  if vim.bo[bufnr].fileformat == "dos" then
    for index, line in ipairs(lines) do
      lines[index] = line:gsub("\r$", "")
    end
  end
  if #lines == 0 then
    lines = { "" }
  end
  return lines
end

--- A KEPT FILE'S FINAL BUFFER IS WHAT DISK ENDS AS. With nothing accepted, a
--- file whose final buffer Neovim calls 'modified' is still saved through the
--- buffer, so whatever the operator's `:w` put on disk during the review --
--- pending agent lines included -- never outlives End (CORE "Saving is
--- Neovim's", LEDGER N51). Never a disk read. A kept deletion projects from the
--- original, not from its buffer, so its buffer owes the terminal text when it
--- does not hold it. Absence (`plan.bytes == nil`) owes nothing.
function M.buffer_owes_save(f, plan)
  if plan.bytes == nil or not (M.valid_buffer(f.bufnr) and vim.api.nvim_buf_is_loaded(f.bufnr)) then
    return false
  end
  if vim.bo[f.bufnr].modified then
    return true
  end
  return plan.buffer_lines == nil
    and not vim.deep_equal(vim.api.nvim_buf_get_lines(f.bufnr, 0, -1, false), M.lines_of_bytes(f.bufnr, plan.bytes))
end

-- ---------------------------------------------------------- SETTLEMENT EVIDENCE
-- Whether a recorded settlement still describes this file: the stamp of what
-- its proposal, decisions and buffer WERE, and the comparison against what
-- they are now. The file on disk is not part of it.
-- Moved here from `turn_settle.lua` at 529 lines because it answers the same
-- question this module exists for -- what is true -- and never acts on it.

function M.bytes_stamp(bytes)
  if bytes == nil then return { exists = false } end
  return { exists = true, size = #bytes, hash = vim.fn.sha256(bytes) }
end

-- A successful path may be skipped when a later path refuses and End turn is
-- retried, but only while every input of that settlement is still the same. A
-- bare boolean would silently ignore an intervening buffer edit, verdict
-- reversal or retarget.
function M.settlement_state(f)
  local change = f.change or {}
  local hunks = {}
  for i, hunk in ipairs(f.ledger and f.ledger:members() or {}) do
    hunks[i] = {
      verdict = hunk.verdict,
      start_line = hunk.start_line,
      new_start_line = hunk.new_start_line,
      new_end_line = hunk.new_end_line,
      old_lines = vim.deepcopy(hunk.old_lines or {}),
      new_lines = vim.deepcopy(hunk.new_lines or {}),
    }
  end
  local buffer
  if M.valid_buffer(f.bufnr) then
    local bytes, snapshot_err = diff.buffer_bytes_snapshot(f.bufnr)
    if bytes == nil then error(snapshot_err or "buffer snapshot failed") end
    buffer = M.bytes_stamp(bytes)
  else
    buffer = { loaded = false }
  end
  return {
    change_object = change,
    change = {
      path = change.path,
      rel = change.rel,
      root = change.root,
      kind = change.kind,
      status = change.status,
      base_hash = change.base_hash,
      base_mode = change.base_mode,
      after_mode = change.after_mode,
    },
    hunks = hunks,
    buffer = buffer,
  }
end

--- THE RETRY CHECK. A file already settled in an earlier End attempt is
--- REVALIDATED here, never trusted: every input and output of that settlement
--- must still be exactly what it was.
function M.settled_current(f)
  if type(f) ~= "table" or type(f.settlement_stamp) ~= "table" then
    return false
  end
  if f.settlement_stamp.change_object ~= f.change then
    return false
  end
  local ok, current = pcall(M.settlement_state, f)
  return ok and vim.deep_equal(f.settlement_stamp, current)
end

--- THE DECISION INPUTS OF A PROJECTION, as one comparable value.
---
--- A terminal projection is computed BEFORE the settler waits for file.claim,
--- and the operator keeps reviewing while it waits. A `ca` in that window
--- changes a verdict without touching a byte of the buffer, so neither the
--- staged-buffer pin nor a changedtick can see it: the End would write a
--- projection that no longer matches the decisions it claims to carry, and the
--- late decision is lost in silence.
---
--- Every input a review decision can move is in here and nothing else is:
--- each member's identity and verdict IN ORDER (so a reordering or a dropped
--- member shows), the retained membership count, the textless operation
--- verdict, and the mode verdict. Deliberately NOT the buffer bytes or the
--- changedtick -- this question is about decisions, and those answer a
--- different one.
function M.decision_stamp(f)
  if type(f) ~= "table" then return "" end
  local ledger = f.ledger
  local members = ledger ~= nil and type(ledger.members) == "function" and ledger:members() or {}
  local parts = { "n=" .. tostring(#members) }
  for index, block in ipairs(members) do
    parts[#parts + 1] = table.concat({
      tostring(index),
      tostring(block.id or index),
      tostring(block.verdict),
    }, "/")
  end
  parts[#parts + 1] = "op=" .. tostring(f.operation_verdict)
  parts[#parts + 1] = "mode="
    .. tostring((require("yana.turn.turn_settle").current_mode_verdict(f) or {}).verdict)
  return table.concat(parts, "|")
end

return M
