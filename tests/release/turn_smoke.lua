local hunks_lib = dofile((debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/") .. "/tests/headless/lib/hunks.lua")
-- turn_smoke.lua — the fresh-install smoke that actually spawns a turn.
--
-- tests/release/smoke.lua (the pre-existing fresh-install check) calls
-- yana.setup() and opens/closes the panel, but never submits a prompt, so a
-- runtime module reachable only from inside a real turn is invisible to it
-- either way it can go missing: a direct, unconditional require() (like
-- lua/yana/agent/agent.lua's `require("yana.agent.vendor_stream")`, which runs on every
-- turn-launch) or a guarded pcall(require, ...) (like
-- lua/yana/inline_diff.lua's `pcall(require, "yana.timeline.retrace")`,
-- which degrades SILENTLY -- no error at all, undo just stops crossing
-- files -- exactly the operator's live-nvim symptom this lane was opened
-- to fix). Both holes shipped once with every ordinary gate green; this is
-- the test that would have caught either regardless of how the missing
-- module was loaded.
--
-- Driven through the ORDINARY product path, no shortcuts: yana.panel.ui.open() +
-- yana.panel.ui.submit(), mode = "inline" (the confined path, real bwrap overlay,
-- same mechanism tests/release/confined_turn_smoke.lua already proves
-- works from an exported tree), with tests/release/turn_smoke_agent as the
-- fixture -- see that file's header for why it differs from
-- tests/release/fake-cursor-agent. One turn: hunk appears, the real file is
-- proven unchanged while review is open, then accept and prove safe End applies
-- the fixture's exact edit to the buffer and disk.
--
-- ENVIRONMENT: needs YANA_TURN_SMOKE_SCRATCH, a writable directory OUTSIDE
-- /tmp (same requirement, same reason, as tests/headless_gate.sh and
-- tests/release/confined_turn_gate.sh: the overlay applies `--tmpfs /tmp`
-- while building the bwrap sandbox, so a scratch placed under /tmp binds in
-- empty and the confined turn cannot run).
--
-- EXIT CODES: 0 pass, 1 a check failed, 65 bwrap unavailable (INCONCLUSIVE,
-- same convention tests/release/confined_turn_smoke.lua uses).
local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(repo)

local failures = {}
local function check(cond, msg)
  if cond then
    print("PASS: " .. msg)
  else
    print("FAIL: " .. msg)
    failures[#failures + 1] = msg
  end
end
local function die(msg)
  print("FAIL: " .. msg)
  print(string.format("FAILED %d check(s)", #failures + 1))
  os.exit(1)
end

local jail = require("yana.shadow.jail")
if not jail.available() then
  print("TURN SMOKE INCONCLUSIVE: bwrap unavailable")
  os.exit(65)
end

local scratch = os.getenv("YANA_TURN_SMOKE_SCRATCH")
if not scratch or scratch == "" then
  die("YANA_TURN_SMOKE_SCRATCH required (writable directory outside /tmp)")
end
vim.fn.mkdir(scratch, "p")

local agent_fixture = repo .. "/tests/release/turn_smoke_agent"
if vim.fn.executable(agent_fixture) ~= 1 then
  die("tests/release/turn_smoke_agent is not executable: " .. agent_fixture)
end

local workspace = scratch .. "/ws"
vim.fn.delete(workspace, "rf")
vim.fn.mkdir(workspace, "p")
local target = workspace .. "/notes.txt"
local fh = assert(io.open(target, "wb"))
fh:write("alpha\nbeta\ngamma\n")
fh:close()

vim.env.YANA_TURN_SMOKE_TARGET = "notes.txt"
require("yana.shadow.preview")._test.force_state_root = scratch .. "/state"

require("yana").setup({
  mode = "inline",
  cmd = agent_fixture,
  write_roots = { workspace },
  sessions = { dir = scratch .. "/sessions-data", chats_dir = scratch .. "/chats" },
})

vim.fn.chdir(workspace)

local ui = require("yana.panel.ui")
local inline = require("yana.inline_diff")

local p = ui.open()
check(p ~= nil and p.prompt_buf ~= nil, "panel opens")
if not p then
  die("panel did not open")
end

ui.focus_prompt(p)
vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "edit notes.txt" })
ui.focus_prompt(p)
check(inline.active_state({ workspace = workspace }) == nil, "review state is clear before submit")
check(p.got_result == false, "panel has no prior result before submit")
if inline.active_state({ workspace = workspace }) ~= nil or p.got_result ~= false then
  die("turn smoke precondition failed")
end
local before_gen = p.turn_gen
ui.submit()

local launched_gen = nil
local advanced = vim.wait(5000, function()
  if p.turn_gen > before_gen then
    launched_gen = p.turn_gen
    return true
  end
  return false
end, 25)
check(advanced and launched_gen ~= nil, "turn generation advanced after submit")
if not launched_gen then
  die("turn generation did not advance after submit")
end
local turned = vim.wait(30000, function()
  return p.turn_gen == launched_gen
    and (p.job_spawn_gen == nil or p.job_spawn_gen == launched_gen)
    and p.got_result == true
end, 25)
check(turned, "submitted turn produced a result")

local state = nil
local got_hunk = vim.wait(30000, function()
  state = inline.active_state({ workspace = workspace })
  return state ~= nil
    and state.change ~= nil
    and state.change.turn_gen == launched_gen
    and state.hunk_ledger ~= nil
    and hunks_lib.hunks(state) ~= nil
    and hunks_lib.pending_count(state) > 0
end, 25)
check(got_hunk and state ~= nil and hunks_lib.hunks(state) and hunks_lib.pending_count(state) > 0,
  "a hunk appeared after the turn (overlay walk + inline_diff review, proves vendor_stream loaded)")

if not state then
  die("no review state — cannot continue to the undo half of this smoke")
end

local win = vim.fn.bufwinid(state.bufnr)
local review_bufnr = state.bufnr
check(win ~= -1, "the hunk's buffer is displayed in a window")
if win == -1 then
  die("hunk buffer not visible; cannot drive accept/undo")
end

vim.api.nvim_set_current_win(win)
local first_hunk = state.hunk_ledger:pending()[1]
local live_start, live_end
local ready = vim.wait(30000, function()
  live_start, live_end = inline.live_block_range(review_bufnr, first_hunk)
  return vim.api.nvim_get_current_buf() == review_bufnr
    and vim.fn.maparg("ca", "n", false, true).buffer == 1
    and type(live_start) == "number"
    and type(live_end) == "number"
    and live_start <= live_end
end, 25)
check(ready, "review buffer and live accept range are ready")
if not ready then
  die("review accept range did not become ready")
end
vim.api.nvim_win_set_cursor(win, { live_start, 0 })
local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
check(cursor_row >= live_start and cursor_row <= live_end, "cursor is inside the live accept range")
vim.cmd("redraw")

-- Accept the (only) hunk -- "ca", the exact key the product's own
-- notification names ("yana: review notes.txt — ca accept · cr reject").
local original = "alpha\nbeta\ngamma\n"
local expected = original .. "turn smoke edit\n"
local fh = assert(io.open(target, "rb"))
local before_accept_disk = fh:read("*a")
fh:close()
check(before_accept_disk == original, "notes.txt on disk stays original while the hunk is open")

local accept_sent = false
vim.schedule(function()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ca", true, false, true), "x", false)
  accept_sent = true
end)
local closed = vim.wait(15000, function()
  return accept_sent
    and inline.active_state({ workspace = workspace }) == nil
    and hunks_lib.pending_count(state) == 0
end, 25)
check(closed, "review closed after accepting the hunk")

-- When no pending hunks remain, ca triggers the safe End path. Wait for both
-- the review to close and the journaled applier to update the buffer and file.
local applied = vim.wait(15000, function()
  local read_fh = assert(io.open(target, "rb"))
  local disk_bytes = read_fh:read("*a")
  read_fh:close()
  local buffer_bytes = table.concat(vim.api.nvim_buf_get_lines(review_bufnr, 0, -1, false), "\n") .. "\n"
  return inline.active_state({ workspace = workspace }) == nil
    and disk_bytes == expected
    and buffer_bytes == expected
end, 25)
check(applied, "safe End applies exact fixture edit to review buffer and disk")

if #failures > 0 then
  print(string.format("FAILED %d check(s)", #failures))
  os.exit(1)
end
print("ALL PASS: yana turn smoke")
os.exit(0)
