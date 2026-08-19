-- One-line notifications.
--
-- A `vim.notify` whose message wraps past a single screen line raises a
-- hit-enter prompt, and a hit-enter prompt blocks the main loop: every
-- scheduled callback (queue pumps, claim repaints, oracle steps) stops until
-- a human presses a key. Several of this plugin's notifications embed
-- arbitrary-length strings -- file paths, `review_error` text, agent output --
-- so the overflow is data-dependent and only shows up on the long inputs.
--
-- Trimming is by DISPLAY WIDTH, not byte or character count: CJK and emoji
-- occupy two cells, so a character-budgeted cut still wraps on them.
local M = {}

-- Collapse any string to a single line. Shared with the conversation panel,
-- which interpolates the same error text into nvim_buf_set_lines -- and that
-- API REJECTS a newline-bearing item outright ("'replacement string' item
-- contains newlines"), so an unflattened error there is not cosmetic: it
-- throws inside the repaint, which is swallowed by the observer's pcall, and
-- claim lines silently stop updating from then on.
function M.flatten(msg)
  msg = tostring(msg)
  msg = msg:gsub("^%s+", ""):gsub("%s+$", "")
  msg = msg:gsub("%s*\r?\n%s*", " · ")
  return msg
end

-- First line of an error for on-screen notify. Full text stays on change.review_error;
-- including "stack traceback:" in a flattened notify still trips oracle's ERROR scan.
function M.error_headline(msg)
  msg = tostring(msg):match("^([^\r\n]+)") or tostring(msg)
  return msg:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Flatten, then trim to `room` display cells (default: one screen line).
function M.one_line_text(msg, room)
  msg = M.flatten(msg)
  room = room or math.max(8, vim.o.columns - 1)
  if vim.fn.strdisplaywidth(msg) > room then
    local cut = msg
    while cut ~= "" and vim.fn.strdisplaywidth(cut .. "…") > room do
      cut = vim.fn.strcharpart(cut, 0, vim.fn.strchars(cut) - 1)
    end
    msg = cut .. "…"
  end
  return msg
end

function M.one_line(msg, level)
  msg = tostring(msg)
  -- Flatten FIRST. Width trimming alone does not deliver one line: a message
  -- carrying an embedded newline -- which every interpolated `tostring(err)`
  -- from a failed vim.cmd or API call can -- is echoed as multiple lines and
  -- raises the hit-enter prompt no matter how short it is. strdisplaywidth
  -- also scores "\n" as two cells rather than a break, so the budget below is
  -- computed on the wrong string until this runs.
  local full = msg
  -- Trim first so a message that merely ENDS in a newline does not pick up a
  -- dangling " · " trailer.
  msg = msg:gsub("^%s+", ""):gsub("%s+$", "")
  msg = msg:gsub("%s*\r?\n%s*", " · ")
  -- `math.max(8, ...)` is a floor for pathological 'columns'; Vim's own
  -- minimum is 12, so in practice room >= 11.
  local room = math.max(8, vim.o.columns - 1)
  if vim.fn.strdisplaywidth(msg) > room then
    local cut = msg
    -- Strictly shrinking, with an empty-string guard: terminates even if a
    -- single character is itself wider than the budget.
    while cut ~= "" and vim.fn.strdisplaywidth(cut .. "…") > room do
      cut = vim.fn.strcharpart(cut, 0, vim.fn.strchars(cut) - 1)
    end
    msg = cut .. "…"
  end
  -- Persist every WARN/ERROR at full text, whether or not the screen line
  -- was truncated. Truncation used to be the only write trigger (`full ~= msg`),
  -- so a wide terminal left yana.log unchanged for the same failure a
  -- narrow one recorded. Lazy require: log.lua does not depend on this module.
  if level and level >= vim.log.levels.WARN then
    pcall(function()
      require("yana.log").write(level >= vim.log.levels.ERROR and "ERROR" or "WARN", full)
    end)
  end
  -- Per-level count into the live turn's ledger (in-memory, no I/O). Lets the
  -- flow report say how many times the turn spoke to the user, and at which
  -- level, without re-reading the log.
  pcall(function()
    require("yana.ledger").note_notify(level)
  end)
  vim.notify(msg, level)
end

--- `one_line` from a context that may be a libuv callback. `vim.notify` (and
--- the width probe it needs) are main-loop APIs; calling them from inside a
--- fast event is a crash, not a cosmetic issue. Every notification a
--- diagnostic path emits goes through here.
function M.safe(msg, level)
  if vim.in_fast_event() then
    vim.schedule(function()
      M.one_line(msg, level)
    end)
    return
  end
  M.one_line(msg, level)
end

return M
