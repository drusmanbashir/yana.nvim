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

local function splice_lines(lines, s, inserted)
  assert(type(s.sr) == "number" and type(s.sc) == "number"
    and type(s.er) == "number" and type(s.ec) == "number")
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
  return out
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
  local inserted = vim.api.nvim_buf_get_text(bufnr, s.sr, s.sc, s.nr, s.nc, {})
  if #inserted == 0 then inserted = { "" } end
  local updated = splice_lines(self.shadow, s, inserted)
  change._timeline_inserted = copy(inserted)
  change._timeline_touched = { require("yana.hunk_anchor_splice").touched(s) }
  self.shadow = updated
  self.changes[#self.changes + 1] = change
  return true
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
    local first, final = read_range(bufnr, block)
    assert(first ~= nil and final ~= nil,
      "watch timeline: final endpoint has no authority range")
    last._timeline_live_after[block] = { first = first, last = final,
      authority_id = block.authority_extmark_id,
      incoming_id = block.incoming_extmark_id }
  end
end

return M
