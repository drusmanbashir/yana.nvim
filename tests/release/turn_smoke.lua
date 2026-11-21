local hunks_lib = dofile((debug.getinfo(1, "S").source:sub(2)):match("^(.*)/tests/") .. "/tests/headless/lib/hunks.lua")
-- Drive one installed-tree MCP turn through the panel and verify review,
-- acceptance, native undo after End, and a save of the undone buffer.
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

local scratch = os.getenv("YANA_TURN_SMOKE_SCRATCH")
if not scratch or scratch == "" then
  die("YANA_TURN_SMOKE_SCRATCH required")
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
local expected = "alpha\nbeta\ngamma\n"
local fh = assert(io.open(target, "wb"))
fh:write(expected)
fh:close()
local function disk_bytes()
  local file = assert(io.open(target, "rb"))
  local bytes = file:read("*a")
  file:close()
  return bytes
end

vim.env.YANA_TURN_SMOKE_TARGET = "notes.txt"
require("yana.shadow.preview")._test.force_state_root = scratch .. "/state"

require("yana").setup({
  mode = "inline",
  backends = { default = "claude", claude = { cmd = agent_fixture } },
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
  "a hunk appeared after the turn (MCP proposal + inline review)")

if not state then
  print("TURN SMOKE panel state: " .. vim.inspect({
    busy = p.busy, job = p.job, awaiting_exit = p.awaiting_exit,
    turn_gen = p.turn_gen, job_spawn_gen = p.job_spawn_gen,
    got_result = p.got_result, session_error = p.yanad_session_err,
  }))
  if p.conv_buf and vim.api.nvim_buf_is_valid(p.conv_buf) then
    print("TURN SMOKE conversation:\n" .. table.concat(vim.api.nvim_buf_get_lines(p.conv_buf, 0, -1, false), "\n"))
  end
  print("TURN SMOKE messages:\n" .. vim.fn.execute("messages"))
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
check(disk_bytes() == expected, "pending review has not saved its proposal")

-- Accept the (only) hunk -- "ca", the exact key the product's own
-- notification names ("yana: review notes.txt — ca accept · cr reject").
-- The final hunk invokes End; subsequent undo is Neovim's own buffer undo.
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

-- The review buffer already shows the hunk before accept (the closed check
-- above is what proves accept ran); this proves undo has bytes to restore,
-- so the buffer check after undo cannot pass on an unchanged buffer.
local accepted_bytes = table.concat(vim.api.nvim_buf_get_lines(review_bufnr, 0, -1, false), "\n") .. "\n"
check(accepted_bytes ~= expected, "review buffer holds the turn's change before undo")
check(disk_bytes() == accepted_bytes, "accepting the last hunk saved the accepted bytes")

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

local buffer_bytes = table.concat(vim.api.nvim_buf_get_lines(review_bufnr, 0, -1, false), "\n") .. "\n"
check(buffer_bytes == expected, "undo restored review buffer bytes exactly")
check(disk_bytes() == accepted_bytes, "native undo leaves the accepted disk bytes until a save")
local write_ok, write_err = pcall(vim.api.nvim_buf_call, review_bufnr, function()
  vim.cmd("write")
end)
check(write_ok, "saving the undone buffer did not throw: " .. tostring(write_err))
check(disk_bytes() == expected, "explicit save restored the original disk bytes")

if #failures > 0 then
  print(string.format("FAILED %d check(s)", #failures))
  os.exit(1)
end
print("ALL PASS: yana turn smoke")
os.exit(0)
