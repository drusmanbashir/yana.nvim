-- Transient text evidence for one queued watcher batch. The watcher owns it;
-- Neovim remains the text and undo authority.
local M = {}
local Timeline = {}
Timeline.__index = Timeline

local function split(text, opts)
  local source = text or ""
  if opts.bomb then
    assert(source:sub(1, 3) == "\239\187\191", "watch timeline: missing BOM")
    source = source:sub(4)
  end
  local eol = opts.fileformat == "dos" and "\r\n" or (opts.fileformat == "mac" and "\r" or "\n")
  if opts.endofline then
    assert(source:sub(-#eol) == eol, "watch timeline: missing final EOL")
    source = source:sub(1, -#eol - 1)
  end
  if eol ~= "\n" then source = source:gsub(eol, "\n") end
  return vim.split(source, "\n", { plain = true })
end

local function copy(lines)
  local out = {}
  for i, line in ipairs(lines) do out[i] = line end
  return out
end

-- on_bytes counts a newline after every row, so the end of the text is (#lines, 0): an empty row past the last,
-- which an edit at the end of the buffer (`o` on the last row, `dd` of it, an append) addresses. It is spliced
-- like any row and must come out last and empty; Neovim keeps one empty row in a buffer emptied of text.
local function splice_lines(source, s, inserted)
  assert(type(s.sr) == "number" and type(s.sc) == "number"
    and type(s.er) == "number" and type(s.ec) == "number")
  local lines = copy(source)
  lines[#lines + 1] = ""
  assert(lines[s.sr + 1] ~= nil and lines[s.er + 1] ~= nil)
  assert(s.sc <= #lines[s.sr + 1] and s.ec <= #lines[s.er + 1])
  assert(type(inserted) == "table" and #inserted > 0)
  local prefix = lines[s.sr + 1]:sub(1, s.sc)
  local suffix = lines[s.er + 1]:sub(s.ec + 1)
  local replacement = {}
  if #inserted == 1 then
    replacement[1] = prefix .. inserted[1] .. suffix
  else
    replacement[1] = prefix .. inserted[1]
    for i = 2, #inserted - 1 do replacement[i] = inserted[i] end
    replacement[#inserted] = inserted[#inserted] .. suffix
  end
  local out = {}
  for i = 1, s.sr do out[#out + 1] = lines[i] end
  vim.list_extend(out, replacement)
  for i = s.er + 2, #lines do out[#out + 1] = lines[i] end
  assert(out[#out] == "", "watch timeline: a splice removed the final newline")
  out[#out] = nil
  if #out == 0 then out[1] = "" end
  return out
end

-- The slice a splice wrote, read inside its own callback; nil while the buffer does not hold it yet. A slice that
-- ends at the end of the text ends with the final newline, past the last row the buffer API can address.
local function written(bufnr, s)
  local count = vim.api.nvim_buf_line_count(bufnr)
  if s.nr > count or (s.nr == count and s.nc ~= 0) then return nil end
  if s.sr == count then return { "" } end
  local function row(r) return vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1] end
  if s.sc > #row(s.sr) then return nil end
  if s.nr == count then
    local text = vim.api.nvim_buf_get_text(bufnr, s.sr, s.sc, count - 1, #row(count - 1), {})
    text[#text + 1] = ""
    return text
  end
  if s.nc > #row(s.nr) then return nil end
  return vim.api.nvim_buf_get_text(bufnr, s.sr, s.sc, s.nr, s.nc, {})
end

function M.new(before_text, opts)
  assert(type(before_text) == "string", "watch timeline needs pre-batch text")
  assert(type(opts) == "table", "watch timeline needs buffer format")
  local before = split(before_text, opts)
  return setmetatable({ before = before, shadow = copy(before), changes = {} }, Timeline)
end

-- Called inside `on_bytes`, after the edit while its pre-state still exists in
-- `shadow`. Reading the new slice is permitted under Neovim's callback textlock.
function Timeline:capture(change, bufnr)
  local s = change.splice
  local inserted = written(bufnr, s)
  if inserted == nil then
    -- A join (`J`, `3J`, visual `J`) reports each joined row's splice before it writes the joined line: the
    -- callback still sees the rows apart (measured on Neovim 0.12.4). What a join writes between the parts is
    -- spaces only; the flush still checks the whole shadow against the buffer (`matches_live`).
    assert(s.nr == s.sr, "watch timeline: a multi-row splice was reported before its text was written")
    inserted = { string.rep(" ", s.nc - s.sc) }
  end
  if #inserted == 0 then inserted = { "" } end
  local updated = splice_lines(self.shadow, s, inserted)
  change._timeline_inserted = copy(inserted)
  change._timeline_touched = { require("yana.hunk_anchor_splice").touched(s) }
  self.shadow = updated
  self.changes[#self.changes + 1] = change
  return true
end

-- Replays one captured splice on another buffer, so its marks move as the live buffer's did. The buffer API
-- cannot address the end of the text, so a splice reaching it (whole rows there, by the final-newline rule) is
-- replayed as the whole-row replacement Neovim reports with that same splice.
function M.replay_splice(bufnr, s, inserted)
  local count = vim.api.nvim_buf_line_count(bufnr)
  if s.er < count then
    vim.api.nvim_buf_set_text(bufnr, s.sr, s.sc, s.er, s.ec, inserted)
    return
  end
  assert(s.sc == 0 and s.ec == 0 and inserted[#inserted] == "",
    "watch timeline: a splice reaching the end of the text is not whole rows")
  vim.api.nvim_buf_set_lines(bufnr, s.sr, s.er, false, vim.list_slice(inserted, 1, #inserted - 1))
end

function Timeline:states()
  local lines = copy(self.before)
  local out = {}
  for i, change in ipairs(self.changes) do
    lines = splice_lines(lines, change.splice, change._timeline_inserted)
    out[i] = copy(lines)
  end
  return out
end

function Timeline:matches_live(bufnr)
  local live = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #live ~= #self.shadow then return false end
  for i, line in ipairs(live) do if line ~= self.shadow[i] then return false end end
  return true
end

-- The range the timeline observes for one member: its live authority mark, else -- for a decided member, which the
-- painter leaves without marks (review_paint repaints pending hunks only) -- its band as the ledger transports it.
-- Without this, an edit in a buffer whose hunks are all decided filed no register row (LEDGER N46).
function M.member_range(read_range, bufnr, block)
  local first, last = read_range(bufnr, block)
  if first == nil and block.verdict ~= "pending" and type(block.new_start_line) == "number" then
    -- In the staged mark's own convention (review_watch_timeline_prepare `mark_range`): a band of at least one
    -- row, or the empty band before `first` for a hunk with no rows.
    first = block.new_start_line
    last = #(block.new_lines or {}) == 0 and first - 1 or math.max(block.new_end_line or first, first)
  end
  return first, last
end

-- At the scheduled flush Neovim has finished moving marks for the final
-- on_bytes. Every earlier endpoint was observed as the next callback's PRE
-- mark; this closes only the last endpoint, without reversing a deletion.
function Timeline:seal_live_ranges(bufnr, read_range)
  -- Neovim increments changedtick after on_bytes returns. Capture it only at
  -- this settled endpoint, never inside the callback's pre-tick window.
  self.changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local last = self.changes[#self.changes]
  if not last or last._timeline_live_after then return end
  last._timeline_live_after = {}
  for _, block in ipairs(self.real_members or {}) do
    local prior = last._timeline_live_before and last._timeline_live_before[block]
    assert(prior, "watch timeline: final endpoint has no pre-edit mark")
    assert(prior.authority_id == block.authority_extmark_id
      and prior.incoming_id == block.incoming_extmark_id,
      "watch timeline: final authority mark rebound")
    local first, final = M.member_range(read_range, bufnr, block)
    assert(first ~= nil and final ~= nil,
      "watch timeline: final endpoint has no authority range")
    last._timeline_live_after[block] = { first = first, last = final,
      authority_id = block.authority_extmark_id,
      incoming_id = block.incoming_extmark_id }
  end
end

return M
