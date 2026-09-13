-- Stateless turn settlement.
local diff = require("yana.diff")
local M = {}

local function split_lines(text)
  local newline = text:find("\r\n", 1, true) and "\r\n" or "\n"
  local normalized = text:gsub("\r\n", "\n")
  local trailing = normalized:sub(-1) == "\n"
  local body = trailing and normalized:sub(1, -2) or normalized
  if body == "" then
    return {}, trailing, newline
  end
  local out = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  return out, trailing, newline
end

local function render(lines, trailing, newline)
  local text = table.concat(lines, newline)
  return trailing and text .. newline or text
end

local function copy_lines(lines)
  local out = {}
  for i, line in ipairs(lines or {}) do
    out[i] = line
  end
  return out
end

local function same_lines(lines, start, expected)
  for i, line in ipairs(expected) do
    if lines[start + i - 1] ~= line then
      return false
    end
  end
  return true
end

local function disk_changes(base, disk, base_trailing, disk_trailing)
  local indices = vim.diff(
    render(base, base_trailing, "\n"),
    render(disk, disk_trailing, "\n"),
    { algorithm = "histogram", result_type = "indices", ctxlen = 0 }
  ) or {}
  local changes = {}
  for _, item in ipairs(indices) do
    changes[#changes + 1] = {
      start = item[1],
      base_count = item[2],
      disk_count = item[4],
    }
  end
  return changes
end

local function range_touches_hunk(change, hunk)
  local hunk_start = hunk.start_line or 1
  local old_count = #(hunk.old_lines or {})
  if change.base_count == 0 then
    -- A pure insertion on either edge is outside. Only a boundary strictly
    -- inside the reviewed span is a conflict (RADV F13).
    return change.start > hunk_start and change.start < hunk_start + old_count
  end
  local hunk_count = math.max(1, old_count)
  local change_start = change.start
  local change_end = change_start + change.base_count - 1
  return change_start <= hunk_start + hunk_count - 1
    and hunk_start <= change_end
end

local function delta_before(changes, base_line)
  local delta = 0
  for _, change in ipairs(changes) do
    if change.start + change.base_count <= base_line then
      delta = delta + change.disk_count - change.base_count
    end
  end
  return delta
end

local function sorted_hunks(ledger)
  local entries = {}
  for order, hunk in ipairs(ledger:members()) do
    entries[#entries + 1] = { hunk = hunk, order = order }
  end
  table.sort(entries, function(a, b)
    local a_start = a.hunk.start_line or 0
    local b_start = b.hunk.start_line or 0
    return a_start == b_start and a.order < b.order or a_start < b_start
  end)
  local hunks = {}
  for i, entry in ipairs(entries) do
    hunks[i] = entry.hunk
  end
  return hunks
end

local function replacement_for(hunk)
  return hunk.verdict == "accepted" and (hunk.new_lines or {}) or (hunk.old_lines or {})
end

local function find_lines(lines, start, expected)
  if #expected == 0 then
    return start
  end
  for at = start, #lines - #expected + 1 do
    if same_lines(lines, at, expected) then
      return at
    end
  end
  return nil
end

local function compose_disk(base_text, disk_text, ledger)
  local base, base_trailing = split_lines(base_text or "")
  local disk, disk_trailing, disk_newline = split_lines(disk_text or "")
  local changes = disk_changes(base, disk, base_trailing, disk_trailing)
  local hunks = sorted_hunks(ledger)

  for _, change in ipairs(changes) do
    for _, hunk in ipairs(hunks) do
      if range_touches_hunk(change, hunk) then
        return nil, "conflict"
      end
    end
  end

  local out = copy_lines(disk)
  local applied_delta = 0
  for _, hunk in ipairs(hunks) do
    local old_lines = hunk.old_lines or {}
    local replacement = replacement_for(hunk)
    local at = (hunk.start_line or 1)
      + delta_before(changes, hunk.start_line or 1) + applied_delta
    at = math.max(1, at)
    if #old_lines > 0 then
      if at + #old_lines - 1 > #out or not same_lines(out, at, old_lines) then
        return nil, "conflict"
      end
      for _ = 1, #old_lines do
        table.remove(out, at)
      end
    end
    for i = #replacement, 1, -1 do
      table.insert(out, at, replacement[i])
    end
    applied_delta = applied_delta + #replacement - #old_lines
  end
  return render(out, disk_text ~= "" and disk_trailing or base_trailing, disk_newline)
end

local function compose_buffer(buffer_lines, base_text, ledger)
  local hunks = sorted_hunks(ledger)
  local out = copy_lines(buffer_lines)
  local applied_delta = 0
  local last_start, last_at, last_replacement_count
  for _, hunk in ipairs(hunks) do
    local old_lines = hunk.old_lines or {}
    local proposed = hunk.new_lines or {}
    local replacement = replacement_for(hunk)
    local at
    if last_start == hunk.start_line then
      at = last_at + last_replacement_count
    else
      at = (hunk.start_line or 1) + applied_delta
    end
    -- The buffer shows ONE of two overlays for this hunk: the PROPOSED lines (painted
    -- at review open and never moved since -- accept moves no bytes, and a reject door
    -- that leaves byte work to the Settler, e.g. the reference-turn `cx` abort, leaves
    -- them standing too), or the OLD lines (a reject door that already restored them
    -- itself, reject_restoration's per-hunk put-back). Diff-derived hunks never share a
    -- first line between old and proposed, so both sides cannot match at the same spot;
    local overlay
    local at_proposed = #proposed > 0 and find_lines(out, at, proposed) or nil
    local at_old = #old_lines > 0 and find_lines(out, at, old_lines) or nil
    if at_proposed and (not at_old or at_proposed <= at_old) then
      overlay, at = proposed, at_proposed
    elseif at_old then
      overlay, at = old_lines, at_old
    elseif #proposed == 0 or #old_lines == 0 then
      overlay = #proposed == 0 and proposed or old_lines
      at = math.min(math.max(at, 1), #out + 1)
    else
      return nil, "buffer_conflict"
    end
    if #overlay > 0 then
      if at + #overlay - 1 > #out then
        return nil, "buffer_conflict"
      end
      for _ = 1, #overlay do
        table.remove(out, at)
      end
    end
    for i = #replacement, 1, -1 do
      table.insert(out, at, replacement[i])
    end
    applied_delta = applied_delta + #replacement - #overlay
    last_start, last_at, last_replacement_count = hunk.start_line, at, #replacement
  end
  return out
end

local function read_disk(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local text = file:read("*a")
  file:close()
  return text
end

local function valid_buffer(bufnr)
  return type(bufnr) == "number" and bufnr > 0
    and vim.api.nvim_buf_is_valid(bufnr)
end

local function creation_accepted(f)
  if type(f.v1_accepted_any) == "function" then
    return f.v1_accepted_any() == true
  end
  local led = f.ledger
  return led ~= nil and type(led.count) == "function" and (led:count("accepted") or 0) > 0
end

--
-- That is the touch owner's REVERSE, only-if-still-empty like every other reverse site.
local creation_touch = require("yana.creation_touch")

--- Rejecting every hunk must leave the path ABSENT.
local function unsettle_untouched_creation(f)
  local change = f.change
  local path = (type(change) == "table" and change.path) or f.path
  local ok, err = creation_touch.remove(path)
  if not ok then
    return false, err
  end
  if type(change) == "table" and change.status == "pending" then
    change.status = "rejected"
  end
  return true
end

-- Deleting on a per-hunk undo press would merge hunk-undo and file-removal into ONE
-- press -- the exact merge the ruling refuses -- and would reverse a touch that was
-- never part of that press's step. The file is removed by ONE press and one press only:
-- the last one, which walks the `file_touch` register row (lua/yana/review_undo.lua).

-- Every UNDECIDED (still coloured) hunk is NOT stored: the file's bytes at those spans
-- revert to the pre-turn text, IN THE BUFFER AND ON DISK ALIKE. Usually nothing of ours
-- is, so a file never saved mid-turn returns to its seed by doing nothing. The
-- discriminator it lacks is WHOSE BYTES sit in the span.
local function revert_undecided_on_disk(f, base_text, settled_text)
  local path = f.path
  local disk_text = path and read_disk(path) or nil
  if disk_text == nil or disk_text == base_text then return true end
  local base = split_lines(base_text or "")
  local out, disk_trailing, disk_newline = split_lines(disk_text)
  local delta, changed, cursor = 0, false, 1
  for _, hunk in ipairs(sorted_hunks(f.ledger)) do
    local old_lines = hunk.old_lines or {}
    local proposed = hunk.new_lines or {}
    local start_line = hunk.start_line or 1
    local undecided = hunk.verdict == nil or hunk.verdict == "pending"
    local at = math.max(cursor, start_line + delta)
    local at_proposed = #proposed > 0 and find_lines(out, at, proposed) or nil
    local at_old = #old_lines > 0 and find_lines(out, at, old_lines) or nil
    if at_proposed and (not at_old or at_proposed <= at_old) then
      if undecided then
        for _ = 1, #proposed do table.remove(out, at_proposed) end
        for i = #old_lines, 1, -1 do table.insert(out, at_proposed, old_lines[i]) end
        changed = true
        delta, cursor = at_proposed - start_line, at_proposed + #old_lines
      else
        -- Decided and already on disk by the human's own hand: 87(a) leaves it.
        delta = at_proposed - start_line + #proposed - #old_lines
        cursor = at_proposed + #proposed
      end
    elseif at_old then
      delta, cursor = at_old - start_line, at_old + #old_lines
    elseif #proposed == 0 and undecided and #old_lines > 0 then
      -- A pure DELETION saved mid-turn leaves no bytes of its own to
      -- recognise, and a stranger deleting the same lines looks identical. The
      -- one witness is the seam -- the base lines either side of the gap,
      -- still adjacent on disk. Put the pre-turn lines back only with it.
      local before_ok = start_line <= 1 or (at > 1 and out[at - 1] == base[start_line - 1])
      local after_ok = out[at] == base[start_line + #old_lines]
      if not (before_ok and after_ok) then
        return false, "disk conflict: third-party bytes where an undecided hunk was deleted"
      end
      for i = #old_lines, 1, -1 do table.insert(out, at, old_lines[i]) end
      changed = true
      delta, cursor = at - start_line, at + #old_lines
    elseif undecided and #old_lines > 0 and #proposed > 0 then
      -- A replacement hunk showing neither side: somebody else owns it now.
      return false, "disk conflict: third-party bytes inside an undecided hunk"
    end
    -- A pure INSERTION whose proposal is absent never reached disk: nothing owed.
  end
  if not changed then return true end
  local final_text = render(out, disk_trailing, disk_newline)
  if settled_text == final_text and valid_buffer(f.bufnr) then
    -- The settled buffer owns exactly these bytes, so let Vim do the write:
    -- the inode is kept and Neovim's own record of the file is re-stamped, so
    -- the operator's next `:w` gets no W12 prompt over a change that was ours.
    -- A CRLF or no-final-newline file never compares equal and takes the
    -- write_file path below, where the buffer rightly stays `modified`.
    local saved, save_err = diff.save_buffer(f.bufnr)
    if not saved then return false, "disk revert save: " .. tostring(save_err) end
    return true
  end
  local written, write_err = diff.write_file(path, final_text)
  if not written then return false, "disk revert write: " .. tostring(write_err) end
  return true
end

--
-- A created file reaches this function as an ordinary file with a base of `""` (it has
-- been on disk, empty, since the turn proposed it), so 87(a)/87(b) decide it the same
-- way they decide everything else. The only creation-specific clause left is the
-- zero-accepted reverse below.
function M.settle(f)
  local change = f.change
  if creation_touch.is_creation(change) then
    -- Anything else settles below as an ordinary file whose base is `""`.
    if not creation_accepted(f) then
      return unsettle_untouched_creation(f)
    end
  end

  local base_text = f.base_text or ""
  local bufnr = f.bufnr

  if valid_buffer(bufnr) then
    if not vim.bo[bufnr].modifiable then
      return false, "nomodifiable"
    end
    local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local final_buffer, compose_err = compose_buffer(buffer_lines, base_text, f.ledger)
    if not final_buffer then
      return false, compose_err
    end
    -- Skip the write when nothing changed so the turn's own settlement never costs the
    -- buffer's own undo tree a step it did not ask for.
    if not vim.deep_equal(buffer_lines, final_buffer) then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final_buffer)
    end
    -- The byte comparison errs only toward `modified` (a CRLF or no-trailing-newline
    -- file compares unequal), never toward
    --
    -- A refusal is reported only after the buffer has settled: the guard protects the
    -- FILE, and withholding the buffer's settlement too would punish the operator twice
    -- for a stranger's edit.
    local ok_disk, disk_err = revert_undecided_on_disk(f, base_text,
      table.concat(final_buffer, "\n") .. "\n")
    local settled_disk = read_disk(f.path)
    vim.bo[bufnr].modified = settled_disk == nil
      or table.concat(final_buffer, "\n") .. "\n" ~= settled_disk
    if not ok_disk then
      return false, disk_err
    end
    return true
  end

  local disk_text = read_disk(f.path)
  if disk_text == nil then
    if base_text ~= "" then
      return false, "deleted"
    end
    disk_text = ""
  end

  local final_text, compose_err = compose_disk(base_text, disk_text, f.ledger)
  if not final_text then
    return false, compose_err
  end

  local written, write_err = diff.write_file(f.path, final_text)
  if not written then
    return false, "write: " .. tostring(write_err)
  end
  return true
end

function M.reverse_turn_creations(files)
  local refused = {}
  for _, f in ipairs(files or {}) do
    local change = f.change
    if creation_touch.is_creation(change) then
      local path = (type(change) == "table" and change.path) or f.path
      local ok, err = creation_touch.remove(path)
      if not ok then
        refused[#refused + 1] = { path = path, err = tostring(err) }
      end
    end
  end
  return refused
end

return M
