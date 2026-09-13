-- THE KEY STREAM, WRITTEN INTO YANA'S OWN LOG BY YANA'S OWN LOGGER.
--
-- WHY THIS MODULE EXISTS. Evidence about a keyed bug has to say which key a
-- logged line answers. The recorder used to infer that from ITS OWN clock in a
-- SEPARATE file (keys.tsv, one process away), against a log stamped only to the
-- second -- two clocks and a rounding, which on bug 7 named the wrong deciding
-- frame. A key line written through the SAME append path, in the SAME process,
-- into the SAME file makes ORDER IN THE FILE THE ORDER OF EVENTS, with no clock
-- comparison left to get wrong. keys.tsv stays as the independent cross-check.
--
-- WHAT IT MAY DO, AND NOTHING ELSE. It is attached only under
-- `setup({ profile = "debugger", debug_modules = { "keys" } })`, it registers
-- `vim.on_key` and it writes `yana.key` rows. It replaces no component, adds no
-- option, changes no timing the editor can observe, and every error inside the
-- callback is swallowed and counted (`M._test.errors`) rather than propagated:
-- a diagnostic must never be able to break the editor it is watching. The
-- further a debug build sits from the factory one, the less its evidence says
-- about the factory one.
--
-- ON `vim.on_key`, MEASURED ON THIS RIG, NOT ASSUMED. nvim 0.12 under kitty's
-- keyboard protocol, keys delivered by xdotool, the bug-2 gesture recorded with
-- EVERY callback logged (`XREC_KEYS_RECORD_ALL=1`, run root
-- /s/agent_rw/tmp/xrec/dbg-onkey-b2, 2026-09-09):
--
--   17 keys sent -> 18 callbacks. The 3x fan-out
--   `tests/headless/xrec/selftest/counter_init.lua:5-12` measured (10 keys ->
--   30 callbacks, on the counter editor) DOES NOT HAPPEN HERE.
--
--   WHAT DOES HAPPEN IS MAPPINGS. The review mapping `ca` arrived as ONE
--   callback with typed="ca", followed by TWO callbacks with typed="" carrying
--   the keys the mapping itself produced (key="z", twice).
--
--   THE RULE, from that data: LOG A CALLBACK IFF `typed` IS NON-EMPTY. It keeps
--   exactly one row per thing the user typed and drops a mapping's own
--   expansion, which is not a keypress and would double-count every mapped
--   gesture. 16 rows for 17 keys in that take is not a lost key: `c` and `a`
--   are ONE typed sequence to on_key, so a reader may never assume one row per
--   keys.tsv line.
--
--   AND READ `typed`, NOT `key`. For a key arriving through the kitty protocol
--   `key` is the raw terminal code -- `vim.fn.keytrans` renders it `<t_...>`
--   with a non-printable byte inside -- while `typed` is `u`. Both are logged
--   and every byte outside printable ASCII is escaped `<HH>`, because the raw
--   bytes made the log a binary file: `grep` silently reported no matches in a
--   log full of them until this escape went in.
--
-- COST, MEASURED (`M._test.bench`, this box, 5 runs of 1000 synthetic keys):
--   callback body, format and queue only, no write:  6.0-6.9 us per key
--   ONE flush of a full 63-row batch (one write, one fsync):
--     2.3-2.7 ms on the NVMe root, where ~/.local/state/nvim/yana.log lives
--     35-58 ms on /s (ext4 on sda), where the recorder's run roots live
--   one `yana.key` row is 183 bytes, so a full batch is about 12 KB.
--   A DURABLE SYNC PER KEYSTROKE WOULD PUT THAT FLUSH NUMBER ON EVERY KEY.
--
-- ONE ATTACH PER PROCESS, AND NO DETACH. `attach` is idempotent, and there is
-- no way to take an `on_key` callback back off once it is on. So a process that
-- ran `setup{ profile = "debugger" }` and is then given `setup{}` keeps writing
-- key rows -- its log's first line already said `debugger`, and a fresh editor
-- (which is what ships, and what tests/yana_debug_profile_gate.sh boots) never
-- loads this file at all. Detaching is not built because nothing needs it.
-- The callback body only formats and appends to a table; the durable write is
-- BATCHED. yana's factory append is one open + one write + one fsync + one
-- close per line (`lua/yana/log.lua`, `write_durable`), and the fsync is off the
-- loop but the caller still waits for it (`lua/yana/safety/flush.lua:1-13`), so
-- a durable sync per keystroke would put that wait on the editor's own loop.
-- Rows are held in memory and handed to the factory append in ONE write when
--   (a) the next non-key yana record is about to be written -- `log.before_append`
--       -- so file order stays event order,
--   (b) the buffer reaches MAX_PENDING rows, or
--   (c) VimLeavePre, so a session that ends mid-buffer loses nothing.
-- The log's existing 5MB rotation bounds the file; nothing here bounds it.

local M = {}

local uv = vim.uv or vim.loop

-- HOW MANY ROWS MAY WAIT. One fsync per this many keys instead of one per key,
-- and at most this many rows are in memory at once. Small enough that a crash
-- (which skips VimLeavePre) loses at most a fraction of a second of typing.
local MAX_PENDING = 64

local pending = {}
local logger = nil
local attached = false

M._test = M._test or {}
-- Errors swallowed inside the callback, and rows written. A row can assert that
-- the stream is complete without reading the file.
M._test.errors = 0
M._test.written = 0
-- Diagnosis only: record EVERY on_key callback, including the ones the dedupe
-- rule drops, with both arguments. This is how the 3x fan-out above was measured
-- and it is never on in a recording.
M._test.record_all = false

-- A LOG IS A TEXT FILE. `keytrans` on a kitty-protocol key returns `<t_...>`
-- with a raw byte in it; one of those makes grep treat the whole log as binary
-- and report no matches at all, in a file full of them. Escaped here and
-- nowhere else, so what is escaped is exactly what this module writes.
local function printable(s)
  return (tostring(s):gsub("[^\32-\126]", function(c)
    return string.format("<%02X>", string.byte(c))
  end))
end

local function flush()
  if #pending == 0 or logger == nil then
    return
  end
  local batch = pending
  pending = {}
  M._test.written = M._test.written + #batch
  logger.append_lines(batch)
end

M._test.flush = flush

--- One key, as the editor saw it, in the same file as everything else it said.
---
--- `key` is what the mapping engine produced and `typed` what the user actually
--- typed (empty when the key came from a mapping, a macro or feedkeys). `mode`,
--- `buf`, `cursor` and `tick` are read INSIDE the callback, so the row says what
--- the editor's state was AT that key rather than after the next one.
local function on_key(key, typed)
  local ok, err = pcall(function()
    local keep = typed ~= nil and typed ~= ""
    if not (keep or M._test.record_all) then
      return
    end
    local row, encode_err = logger.lifecycle_record("yana.key", {
      key = printable(vim.fn.keytrans(key or "")),
      typed = printable(vim.fn.keytrans(typed or "")),
      mode = vim.api.nvim_get_mode().mode,
      buf = vim.api.nvim_get_current_buf(),
      cursor = vim.api.nvim_win_get_cursor(0),
      tick = vim.api.nvim_buf_get_changedtick(0),
      dropped = (not keep) and true or nil,
    })
    if not row then
      error(tostring(encode_err), 0)
    end
    pending[#pending + 1] = row
    if #pending >= MAX_PENDING then
      flush()
    end
  end)
  if not ok then
    -- SWALLOWED, AND COUNTED. An error raised out of an on_key callback reaches
    -- the editor the operator is using; a diagnostic that can do that is worse
    -- than no diagnostic. The count is the evidence that it happened.
    M._test.errors = M._test.errors + 1
    local _ = err
  end
end

--- Attach the key stream to the factory logger. Called once, by the composition
--- root in `yana.init`, and only under `profile = "debugger"`.
function M.attach(log)
  if attached then
    return
  end
  attached = true
  logger = log
  -- BEFORE THE NEXT NON-KEY RECORD REACHES DISK. This is what keeps file order
  -- equal to event order while the rows are batched.
  log.before_append(flush)
  vim.on_key(on_key)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("YanaDebugKeys", { clear = true }),
    callback = flush,
    desc = "yana debug_keys: write the last batch of key rows",
  })
end

--- Nanoseconds spent in the callback body for `n` synthetic keys, and in ONE
--- durable flush of a full buffer. Measurement only -- it is what the numbers in
--- this file's header were taken with.
---
--- The body is timed in chunks of MAX_PENDING-1 so the auto-flush never fires
--- inside the timed region: the first version of this measured 432 us/key, which
--- was fifteen fsyncs hiding inside a thousand formats.
function M._test.bench(log, n)
  logger = log
  local body_ns, done = 0, 0
  while done < n do
    local chunk = math.min(MAX_PENDING - 1, n - done)
    pending = {}
    local t0 = uv.hrtime()
    for _ = 1, chunk do
      on_key("x", "x")
    end
    body_ns = body_ns + (uv.hrtime() - t0)
    done = done + chunk
  end
  pending = {}
  for _ = 1, MAX_PENDING - 1 do
    on_key("x", "x")
  end
  local rows = #pending
  local t1 = uv.hrtime()
  flush()
  local flush_ns = uv.hrtime() - t1
  return { body_ns = body_ns, keys = n, flush_ns = flush_ns, flush_rows = rows }
end

return M
