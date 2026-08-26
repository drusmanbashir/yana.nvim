-- turn_smoke.lua — the fresh-install smoke that actually spawns a turn.
--
-- tests/release/smoke.lua (the pre-existing fresh-install check) calls
-- yana.setup() and opens/closes the panel, but never submits a prompt, so a
-- runtime module reachable only from inside a real turn is invisible to it
-- either way it can go missing: a direct, unconditional require() (like
-- lua/yana/agent.lua's `require("yana.vendor_stream")`, which runs on every
-- turn-launch) or a guarded pcall(require, ...) (like
-- lua/yana/inline_diff.lua's `pcall(require, "yana.timeline.retrace")`,
-- which degrades SILENTLY -- no error at all, undo just stops crossing
-- files -- exactly the operator's live-nvim symptom this lane was opened
-- to fix). Both holes shipped once with every ordinary gate green; this is
-- the test that would have caught either regardless of how the missing
-- module was loaded.
--
-- Driven through the ORDINARY product path, no shortcuts: yana.ui.open() +
-- yana.ui.submit(), mode = "inline" (the confined path, real bwrap overlay,
-- same mechanism tests/release/confined_turn_smoke.lua already proves
-- works from an exported tree), with tests/release/turn_smoke_agent as the
-- fixture -- see that file's header for why it differs from
-- tests/release/fake-cursor-agent. One turn: hunk appears, accept it
-- (closes the review -> exactly where
-- lua/yana/inline_diff.lua reinstalls retrace-aware `u`/`<C-r>` for this
-- buffer, per the "POST-REVIEW RETRACE" comment there), then undo, then
-- assert nothing in :messages looks like a Lua/Vim error.
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
  sessions = { dir = scratch .. "/sessions-data", chats_dir = scratch .. "/chats" },
})

vim.fn.chdir(workspace)

local ui = require("yana.ui")
local inline = require("yana.inline_diff")

local p = ui.open()
check(p ~= nil and p.prompt_buf ~= nil, "panel opens")
if not p then
  die("panel did not open")
end

ui.focus_prompt(p)
vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "edit notes.txt" })
ui.focus_prompt(p)
ui.submit()

local turned = vim.wait(30000, function()
  return p.busy ~= true
end, 25)
check(turned, "turn finished (agent.run/vendor_stream did not hang or crash the process)")

local state = nil
local got_hunk = vim.wait(10000, function()
  state = inline.active_state({ workspace = workspace })
  return state ~= nil
end, 25)
check(got_hunk and state ~= nil and state.diff_blocks and #state.diff_blocks > 0,
  "a hunk appeared after the turn (overlay walk + inline_diff review, proves vendor_stream loaded)")

if not state then
  die("no review state — cannot continue to the undo half of this smoke")
end

local win = vim.fn.bufwinid(state.bufnr)
check(win ~= -1, "the hunk's buffer is displayed in a window")
if win == -1 then
  die("hunk buffer not visible; cannot drive accept/undo")
end

vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { state.hint_line or 1, 0 })
vim.cmd("redraw")

-- Accept the (only) hunk -- "ca", the exact key the product's own
-- notification names ("yana: review notes.txt — ca accept · cr reject").
-- Closing the review is what installs the retrace-aware u/<C-r> for this
-- buffer (lua/yana/inline_diff.lua's "POST-REVIEW RETRACE" block).
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ca", true, false, true), "x", false)
local closed = vim.wait(5000, function()
  return inline.active_state({ workspace = workspace }) == nil
end, 25)
check(closed, "review closed after accepting the hunk")

vim.cmd("messages clear")
local undo_ok, undo_err = pcall(function()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("u", true, false, true), "x", false)
end)
check(undo_ok, "undo keypress did not throw: " .. tostring(undo_err))
vim.cmd("redraw")

local msgs = vim.fn.execute("messages")
local looks_like_error = msgs:find("E%d%d%d", 1) ~= nil
  or msgs:find("stack traceback", 1, true) ~= nil
  or msgs:find("attempt to", 1, true) ~= nil
check(not looks_like_error, "no Lua/Vim error appears in :messages after undo (got: " .. msgs .. ")")

-- The stronger, behavioural half of this check (measured 2026-08-21: a tree
-- with lua/yana/timeline/retrace.lua removed passes the "no error" check
-- above with EXIT 0 -- the pcall swallows it exactly as designed -- and
-- undo silently degrades to Neovim's own "N changes; before #N ..." status
-- line instead of retrace's notify.one_line("yana: undid " .. ..., see
-- lua/yana/timeline/retrace.lua:608). Retrace present is the only way this
-- specific text appears, so its absence here means retrace's post-review
-- key was never reinstalled -- the module is missing, unreachable, or
-- broken, and the earlier "no Lua error" check alone would have missed it.
check(msgs:find("yana: undid ", 1, true) ~= nil,
  "undo went through yana's retrace-aware handler, not Neovim's native fallback (msgs: " .. msgs .. ")")

if #failures > 0 then
  print(string.format("FAILED %d check(s)", #failures))
  os.exit(1)
end
print("ALL PASS: yana turn smoke")
os.exit(0)
