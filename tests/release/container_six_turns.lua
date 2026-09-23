-- container_six_turns.lua — two real Yana submits for one mode inside Docker.
--
-- Env:
--   YANA_SIX_TURNS_MODE   agentic | inline | ask  (required)
--   YANA_SIX_TURNS_SCRATCH  writable root OUTSIDE /tmp (required for overlay)
--
-- Asserts: two completed turns, mode-correct on-disk bytes, no leftover review
-- for ask, and prints one SIX-TURNS PASS line the host greps.
local mode = os.getenv("YANA_SIX_TURNS_MODE")
local scratch = os.getenv("YANA_SIX_TURNS_SCRATCH")
if mode ~= "agentic" and mode ~= "inline" and mode ~= "ask" then
  print("FAIL: YANA_SIX_TURNS_MODE must be agentic|inline|ask")
  os.exit(1)
end
if not scratch or scratch == "" or scratch:sub(1, 5) == "/tmp/" or scratch == "/tmp" then
  print("FAIL: YANA_SIX_TURNS_SCRATCH required outside /tmp")
  os.exit(1)
end
if os.getenv("YANA_UI_ROOT") and os.getenv("YANA_UI_ROOT") ~= "" then
  print("FAIL: YANA_UI_ROOT must not be set inside the public Docker proof")
  os.exit(1)
end
if os.getenv("YANA_REPO_DIR") and os.getenv("YANA_REPO_DIR") ~= "" then
  print("FAIL: YANA_REPO_DIR must not be set inside the public Docker proof")
  os.exit(1)
end

local repo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
vim.opt.runtimepath:prepend(repo)

local failures = {}
local function check(cond, msg)
  if cond then
    print("PASS: " .. msg)
  else
    failures[#failures + 1] = msg
    print("FAIL: " .. msg)
  end
end
local function die(msg)
  print("FAIL: " .. msg)
  print(string.format("FAILED %d check(s)", #failures + 1))
  os.exit(1)
end

local jail = require("yana.shadow.jail")
if (mode == "inline" or mode == "ask") and not jail.available() then
  print("SIX-TURNS INCONCLUSIVE: bwrap unavailable for overlay mode " .. mode)
  os.exit(65)
end

vim.fn.mkdir(scratch, "p")
local workspace = scratch .. "/ws"
local state_root = scratch .. "/state"
vim.fn.delete(workspace, "rf")
vim.fn.mkdir(workspace, "p")
local target = workspace .. "/notes.txt"
do
  local fh = assert(io.open(target, "wb"))
  fh:write("seed\n")
  fh:close()
end
local seed = "seed\n"

local agent = repo .. "/tests/release/six_turns_agent"
if vim.fn.executable(agent) ~= 1 then
  die("six_turns_agent not executable: " .. agent)
end

require("yana.shadow.preview")._test.force_state_root = state_root
vim.env.YANA_SIX_TURNS_TARGET = "notes.txt"

local setup_opts = {
  mode = mode,
  cmd = agent,
  write_roots = { workspace },
  sessions = { dir = scratch .. "/sessions", chats_dir = scratch .. "/chats" },
}
if mode == "agentic" then
  setup_opts.enable_agentic = true
  setup_opts.modes = { "agentic" }
end
require("yana").setup(setup_opts)
vim.fn.chdir(workspace)

local ui = require("yana.panel.ui")
local inline = require("yana.inline_diff")

-- Headless abort confirmations (same shape as tests/headless/lib/r_abort_adversarial_common.lua).
do
  local orig = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    local prompt = (opts and opts.prompt) or ""
    if type(prompt) == "string" and (prompt:find("Abort", 1, true) or prompt:find("Close tabs", 1, true)) then
      for _, item in ipairs(items or {}) do
        if tostring(item):sub(1, 3) == "Yes" or tostring(item):find("Yes", 1, true) then
          return on_choice(item)
        end
      end
    end
    return orig(items, opts, on_choice)
  end
end

local p = ui.open()
check(p ~= nil and p.prompt_buf ~= nil, "panel opens for mode " .. mode)
if not p then
  die("panel did not open")
end

-- Record the state root so the host can prove modes did not share it.
do
  local marker = assert(io.open(scratch .. "/state_root.txt", "w"))
  marker:write(state_root .. "\n")
  marker:close()
end

local function read_target()
  local fh = io.open(target, "rb")
  if not fh then
    return nil
  end
  local bytes = fh:read("*a")
  fh:close()
  return bytes
end

-- Clear review + shadow claim so the next submit is not queued behind
-- "review still open" (lua/yana/panel/ui_submit.lua).
local function clear_confined_turn()
  if mode == "agentic" then
    return true
  end
  if mode == "inline" then
    local st = inline.active_state({ workspace = workspace })
    if st ~= nil then
      -- Product reject path (same notification turn_smoke drives with "ca").
      local win = vim.fn.bufwinid(st.bufnr)
      if win ~= -1 then
        vim.api.nvim_set_current_win(win)
        local first = st.hunk_ledger and st.hunk_ledger:pending()[1]
        if first then
          local live_start = select(1, inline.live_block_range(st.bufnr, first))
          if type(live_start) == "number" then
            vim.api.nvim_win_set_cursor(win, { live_start, 0 })
          end
        end
        vim.schedule(function()
          vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("cr", true, false, true), "x", false)
        end)
      else
        pcall(inline.abort_active, { workspace = workspace })
      end
    end
  end
  pcall(inline.discard_pool, { workspace = workspace })
  local ready = vim.wait(30000, function()
    return p.shadow_turn == nil
      and inline.active_state({ workspace = workspace }) == nil
      and not p.busy
      and p.job == nil
      and not p.awaiting_exit
  end, 25)
  check(ready, "confined turn cleared (no shadow claim / review)")
  return ready
end

local function wait_turn(before_gen)
  local launched = nil
  local advanced = vim.wait(8000, function()
    if p.turn_gen > before_gen then
      launched = p.turn_gen
      return true
    end
    return false
  end, 25)
  check(advanced and launched ~= nil, "turn generation advanced (before=" .. tostring(before_gen) .. ")")
  if not launched then
    return nil
  end
  -- Same completion signal as tests/release/turn_smoke.lua: got_result.
  local got = vim.wait(45000, function()
    return p.turn_gen == launched
      and (p.job_spawn_gen == nil or p.job_spawn_gen == launched)
      and p.got_result == true
  end, 25)
  check(got, "turn " .. tostring(launched) .. " produced a result")
  if not got then
    return nil
  end
  if mode == "inline" then
    -- Review binds after got_result; wait for the open review before clearing.
    local reviewed = vim.wait(30000, function()
      local st = inline.active_state({ workspace = workspace })
      return st ~= nil and st.change ~= nil and st.change.turn_gen == launched
    end, 25)
    check(reviewed, "inline: review opened for turn " .. tostring(launched))
  elseif mode == "ask" then
    local settled = vim.wait(30000, function()
      return p.shadow_turn == nil
    end, 25)
    check(settled, "ask: shadow claim released for turn " .. tostring(launched))
  end
  return launched
end

local completed = {}
for n = 1, 2 do
  vim.env.YANA_SIX_TURNS_N = tostring(n)
  if n > 1 and not clear_confined_turn() then
    die("could not clear previous confined turn before submit " .. n)
  end
  local before = p.turn_gen
  ui.focus_prompt(p)
  vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "six-turns prompt " .. n })
  ui.submit()
  local gen = wait_turn(before)
  if gen then
    completed[#completed + 1] = gen
  end
end
-- Leave ask/inline with no open review for the final disk assertions.
clear_confined_turn()

check(#completed == 2, "exactly two completed turns (got " .. tostring(#completed) .. ")")
check(completed[1] ~= nil and completed[2] ~= nil and completed[1] ~= completed[2],
  "the two completed turns have distinct generations")
-- Each user submit launches its own turn: the first cold submit is generation 1
-- without needing a second submit to re-fire it, and the second is generation 2.
check(completed[1] == 1 and completed[2] == 2,
  "submit 1 launched generation 1 and submit 2 launched generation 2 (got "
    .. tostring(completed[1]) .. "," .. tostring(completed[2]) .. ")")

local disk = read_target()
if mode == "agentic" then
  check(disk == "seed\nsix-turn-1\nsix-turn-2\n", "agentic: both edits landed on real disk")
elseif mode == "inline" or mode == "ask" then
  check(disk == seed, mode .. ": real workspace unchanged after two confined turns")
  if mode == "ask" then
    check(inline.active_state({ workspace = workspace }) == nil, "ask: no review left open")
  end
end

-- Marker the host greps; includes mode and completed gens. PASS only when every
-- check passed: a PASS line next to FAILED checks is a false green.
print(string.format(
  "SIX-TURNS %s mode=%s turns=%d gens=%s,%s state_root=%s",
  #failures == 0 and "PASS" or "FAIL",
  mode,
  #completed,
  tostring(completed[1]),
  tostring(completed[2]),
  state_root
))

if #failures > 0 then
  print(string.format("FAILED %d check(s)", #failures))
  os.exit(1)
end
os.exit(0)
