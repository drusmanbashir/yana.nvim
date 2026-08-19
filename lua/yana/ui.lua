-- yana: the sidebar chat UI (conversation + prompt windows) and streaming
-- render of cursor-agent responses.
--
-- Multiple panels can be open at once, each with its own session, mode, model
-- and in-flight job, so several conversations can run in parallel. Panels
-- stack vertically inside the sidebar column. Commands act on the "current"
-- panel: the one your cursor is in, else the most recently used one.
local config = require("yana.config")
local agent = require("yana.agent")
local context = require("yana.context")
local diff = require("yana.diff")
local control_plane = require("yana.safety.control_plane")
local selection_scope = require("yana.selection_scope")
local sessions = require("yana.sessions")
local clipboard = require("yana.clipboard")
local log = require("yana.log")
local shadow_ops = require("yana.shadow.ops")
-- The per-turn flight recorder. Every call in this file is an in-memory table
-- write; nothing here reaches disk, and nothing here can change control flow.
local ledger = require("yana.ledger")
-- Every notification in this file goes through the one-line budget: several
-- embed arbitrary-length strings (paths, review_error text, agent output), and
-- a wrapped message raises a hit-enter prompt that blocks the main loop --
-- freezing queue pumps and claim repaints until a human presses a key.
local notify = require("yana.notify")
local notify_one_line = notify.one_line

local M = {}

local uv = vim.uv or vim.loop

----------------------------------------------------------------------
-- panel registry
----------------------------------------------------------------------

local panels = {}       -- list of panel state tables, in creation order
local last_panel = nil  -- most recently focused/used panel
-- Tracked (not sampled) panel focus for the <C-c> stop hook: set only when a
-- panel's own conv_buf/prompt_buf is entered, cleared only when a NORMAL
-- (buftype "") non-panel buffer is entered. Transient/plugin buffers (e.g. a
-- noice message window, buftype "nofile") do neither, so a notification
-- popping up and stealing the current window cannot silently revoke the
-- panel's claim on <C-c> — see setup_panel_autocmds and the global
-- YanaFocusTrack augroup below.
local last_focused_panel = nil
local _panel_seq = 0
local cancel_inflight   -- defined after submit_panel; used by scope rejection cap
local submit_panel      -- defined below; forward-declared so on_done can drain the queue
local maybe_drain_queue -- defined below; review-close drain after release_shadow_turn
local finalize_shadow_turn -- confirmed-exit overlay consume; also used by on_done spawn-fail

local function buf_valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function panel_alive(p)
  return p and buf_valid(p.conv_buf) and buf_valid(p.prompt_buf)
end

local function panel_open(p)
  return p ~= nil and win_valid(p.conv_win) and win_valid(p.prompt_win)
end

local function new_panel_state()
  _panel_seq = _panel_seq + 1
  return {
    id = _panel_seq,
    conv_buf = nil,
    conv_win = nil,
    prompt_buf = nil,
    prompt_win = nil,
    session_id = nil,
    title = nil,           -- short session title (from the first prompt)
    mode = nil,
    model = nil,           -- selected model id for this panel (nil => auto)
    job = nil,
    turn_gen = 0,          -- bumped on every submit/cancel; stale on_event/on_done no-op
    job_spawn_gen = nil,   -- turn_gen at which p.job was spawned; the correlation token
                           -- for on_exit_confirmed/escalation timers, so a late old
                           -- exit can never clear bookkeeping for a newer job (I2).
    pending_redirect = nil, -- steer text waiting for the old process to die (I4,
                           -- last-wins: a second steer while waiting replaces this).
    awaiting_exit = false, -- cancelled, exit not yet observed (spawn barrier, I1).
    busy = false,
    queue = {},            -- prompts submitted while busy; sent in order once the
                           -- in-flight turn finishes. Only ever emptied by draining
                           -- or by explicit user action in the queue picker — a
                           -- cancel (stop/new_chat/scope-cap) returns queued items
                           -- to the prompt buffer instead of dropping them.
    cancelled = false,     -- true when we jobstop()'d; on_done must not treat as error
    got_result = false,
    turn_errored = false,  -- did the turn that just finished render an agent error?
                           -- (agent-level `is_error`/`error` event, or a failed
                           -- process exit) — gates queue.pause_on_error.
    rendered_any = false,  -- did this turn render any text/tool output?
    stream_text = "",
    assistant_start = 0,   -- 0-based line where the streaming answer begins
    pending_selection = nil,
    active_turn_scope = nil,
    turn_scopes = {}, -- turn_gen -> scope table or false (explicitly unscoped)
    changes = {},          -- file changes made by the agent this session
    review_epoch = 0,      -- bumped on new_chat; owners stamped at batch time must
                           -- match or flush must not enqueue (H4).
    review_batch = {},     -- inline mode: owning changes for this turn, insertion
                           -- order, flushed into the review queue at turn end.
                           -- cursor-agent self-applies to disk and keeps going, so
                           -- afterFullFileContent is a PER-EDIT snapshot: the moment
                           -- it touches one file twice, every earlier change's
                           -- `after` is permanently unmatchable and the CAS in
                           -- open_review_buffer refuses it forever. Reviews
                           -- therefore open only once the agent can no longer
                           -- write. See flush_review_batch.
    review_batch_by_path = {}, -- abs path -> owning change in review_batch
    turns = 0,
    last_question = nil,   -- composed prompt last sent (post /command + @mentions)
    cwd = nil,             -- cwd of the last submitted turn
    spinner = { timer = nil, idx = 1 },
    closing = false,       -- guard for the WinClosed sibling-close autocmd
    augroup = nil,
    scope_rejections = {}, -- per-turn out-of-zone rejections by path
    review_rejections = {}, -- per-turn inline-review rejections by path
    turn_modes = {},       -- turn_gen -> resolved mode used for that submit
    turn_questions = {},   -- turn_gen -> composed prompt sent for that submit
    ask_advice_resend = nil, -- ask-no-edit turn: prompt <M-r>a should resend
  }
end

-- Drop panels whose buffers were wiped out from under us.
-- Everything a dead panel has to hand back, in one place. Two separate
-- retention paths used to survive a panel's death:
--   * the inline_diff observer closure, which holds the panel table, its
--     conv_buf handle and its whole `changes` list
--   * p.augroup, which carries a pattern-GLOBAL BufEnter tracker and a
--     pattern-global WinClosed handler -- those keep firing on every
--     buffer-enter and window-close for the rest of the session, holding the
--     same dead panel through their own closures
-- Releasing only the first left the retention half alive. This is the single
-- destruction site, and the invariant "whoever unsubscribes also nils the
-- field" is enforced here rather than by comment.
local function destroy_panel(p)
  if not p then
    return
  end
  if p.unsubscribe_review then
    pcall(p.unsubscribe_review)
    p.unsubscribe_review = nil
  end
  if p.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, p.augroup)
    p.augroup = nil
  end
end

local function prune_panels()
  for i = #panels, 1, -1 do
    if not panel_alive(panels[i]) then
      -- The panel's real destruction. close_panel keeps the panel alive on
      -- purpose (it only closes windows), so unsubscribing there froze claims
      -- across a toggle -- which is why release happens here and nowhere else.
      destroy_panel(panels[i])
      table.remove(panels, i)
    end
  end
  if last_panel and not panel_alive(last_panel) then
    last_panel = nil
  end
  -- Mirror the last_panel staleness check above: a destroyed panel must not
  -- be able to resurrect via a stale <C-c> target.
  if last_focused_panel and not panel_alive(last_focused_panel) then
    last_focused_panel = nil
  end
end

local function panel_for_buf(buf)
  for _, p in ipairs(panels) do
    if p.conv_buf == buf or p.prompt_buf == buf then
      return p
    end
  end
  return nil
end

-- Global (not per-panel) half of the <C-c> focus tracking: entering any
-- NORMAL buffer (buftype "") that isn't a panel's own buffer means the user
-- has genuinely moved away from yana, so <C-c> should stop claiming
-- them. Deliberately does NOT fire for transient/plugin buffers (buftype ~=
-- "" — e.g. a noice message window, popups, quickfix): those must neither
-- grant nor revoke panel focus, which is the whole point of tracking focus
-- instead of sampling the current buffer at keypress time.
--
-- Both WinEnter AND BufEnter, not WinEnter alone: opening a brand-new window
-- onto a real file (":vsplit foo.py", or a plugin's nvim_open_win(buf, ...))
-- creates the window first — firing WinEnter with whatever buffer the split
-- inherited — and only THEN swaps in the target buffer, which fires BufEnter
-- with no second WinEnter. WinEnter-only would miss that swap entirely and
-- leave a stale panel focus pointed at a window the user has since filled
-- with an unrelated file. buftype is re-checked on the buffer actually
-- entered either way, so a transient buffer still never triggers this.
--
-- buftype "terminal" is included alongside "" ("normal" file buffers): a
-- :terminal buffer is somewhere the user has genuinely moved to (unlike a
-- transient popup), and it owns its own <C-c> — see install_stop_on_key
-- below. Without this, a panel's focus claim survived the user switching
-- into a terminal buffer, and only the mode() == "t" bail there covered
-- terminal-insert/job mode; terminal-NORMAL mode (mode() == "nt") slipped
-- through both checks and let <C-c> in a terminal's normal mode stop the
-- panel's turn.
vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  group = vim.api.nvim_create_augroup("YanaFocusTrack", { clear = true }),
  callback = function(ev)
    log.guard("yana.ui YanaFocusTrack", function()
      local bt = vim.bo[ev.buf].buftype
      if (bt == "" or bt == "terminal") and not panel_for_buf(ev.buf) then
        last_focused_panel = nil
      end
    end)
  end,
})

local function find_panel_by_session(session_id)
  if not session_id then
    return nil
  end
  for _, p in ipairs(panels) do
    if p.session_id == session_id and panel_alive(p) then
      return p
    end
  end
  return nil
end

-- The panel commands act on: the one under the cursor, else the most
-- recently used, else any open one, else the newest alive one.
local function current_panel()
  prune_panels()
  local p = panel_for_buf(vim.api.nvim_get_current_buf())
  if p then
    return p
  end
  if last_panel then
    return last_panel
  end
  for _, q in ipairs(panels) do
    if panel_open(q) then
      return q
    end
  end
  return panels[#panels]
end

local function panel_index(p)
  for i, q in ipairs(panels) do
    if q == p then
      return i
    end
  end
  return 0
end

----------------------------------------------------------------------
-- low-level buffer helpers
----------------------------------------------------------------------

local function set_lines(p, start, finish, lines)
  if not buf_valid(p.conv_buf) then
    return
  end
  -- nvim_buf_set_lines rejects any entry containing "\\n". Flatten so a
  -- multi-line tool summary / stream glitch cannot abort the turn with a
  -- transient red vim.schedule error.
  local flat = {}
  for _, l in ipairs(lines) do
    if type(l) == "string" and l:find("\n", 1, true) then
      vim.list_extend(flat, vim.split(l, "\n", { plain = true }))
    else
      flat[#flat + 1] = l
    end
  end
  vim.bo[p.conv_buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.conv_buf, start, finish, false, flat)
  vim.bo[p.conv_buf].modifiable = false
end

local function scroll_to_bottom(p)
  if win_valid(p.conv_win) and buf_valid(p.conv_buf) then
    local count = vim.api.nvim_buf_line_count(p.conv_buf)
    pcall(vim.api.nvim_win_set_cursor, p.conv_win, { count, 0 })
  end
end

-- The turn ledger for a panel's current (or named) turn. One hash lookup;
-- creates the record if a callback arrives for a turn nothing opened.
--
-- `p.render_gen` is the OWNING generation of the output being rendered right
-- now, set for the duration of one event/apply-pass callback (see
-- `with_render_gen`). Without it every render helper resolved `p.turn_gen` —
-- the newest turn — so a stopped turn's late disk-bearing edit had its event
-- recorded in ledger G (on_event resolves the ledger with the explicit gen)
-- while its visible panel output landed in ledger G+1, citing an event seq
-- that generation never produced. That is exactly the late-event race the
-- (panel, gen) key exists to disambiguate, so the render side has to resolve
-- the same key the event side did.
local function turn_ledger(p, gen)
  return ledger.ensure(p and p.id or 0, gen or (p and (p.render_gen or p.turn_gen)) or 0)
end

-- Run `fn` with the panel's render generation pinned to `gen`, restoring the
-- previous value (normally nil) afterwards. Restoration happens even when
-- `fn` throws: a pinned generation that leaked past a failed callback would
-- misattribute every later append, and this is a logging concern that must
-- never change what the caller sees, so the error is re-raised unchanged.
local function with_render_gen(p, gen, fn, ...)
  local prev = p.render_gen
  p.render_gen = gen
  local ok, err = pcall(fn, ...)
  p.render_gen = prev
  if not ok then
    error(err, 0)
  end
end

-- Append lines to the end of the conversation buffer.
--
-- `kind` names WHY this append happened ("user", "note", "tool_note",
-- "tool_change", "error", "usage", …). Provenance, record 3 of 3: each append
-- is recorded against the stream-event seq in flight when it ran, so a
-- sentence that appears twice in the panel resolves to one of exactly three
-- causes — several appends citing ONE event seq is render duplication,
-- several distinct seqs under one spawn is vendor churn, and several spawn
-- records is a Yana respawn.
local function append(p, lines, kind)
  if not buf_valid(p.conv_buf) then
    return
  end
  local count = vim.api.nvim_buf_line_count(p.conv_buf)
  -- A fresh scratch buffer has a single empty line; overwrite it.
  if count == 1 and vim.api.nvim_buf_get_lines(p.conv_buf, 0, 1, false)[1] == "" then
    set_lines(p, 0, 1, lines)
  else
    set_lines(p, count, count, lines)
  end
  ledger.note_append(turn_ledger(p), kind or "append", lines)
  scroll_to_bottom(p)
end

----------------------------------------------------------------------
-- mode lock
----------------------------------------------------------------------

-- A chat's mode is fixed at its first turn and cannot be changed afterwards.
--
-- This is not a policy choice, it is a workaround for cursor-agent. Mode is a
-- per-message field upstream (`agent.v1.AgentMode`), and an explicit `--mode`
-- always wins -- but OMITTING it inherits the previous message's mode rather
-- than defaulting to agent. The CLI only accepts `--mode plan|ask`; there is no
-- `--mode agent` to emit (verified: `--mode agent` is a hard CLI error, and
-- `--force` is an approval policy, not a mode). So once any turn in a session
-- has run with `--mode ask`, every later `--resume` turn inherits ask forever,
-- and the two lived failure shapes are: the agent refuses outright, or -- worse
-- -- it edits the file anyway and then reports that the edit was blocked.
--
-- Locking the mode per chat makes that unreachable: an ask chat stays ask, an
-- agent chat never inherits ask. To change mode, start a new chat (which starts
-- a new upstream session, and a fresh session's mode chain starts clean).
-- Lock once an upstream session identity exists (init received or restored on
-- resume). turns alone is not authority — a spawn failure can increment turns
-- without ever creating an upstream mode chain.
local function mode_locked(p)
  return p ~= nil and p.session_id ~= nil and p.session_id ~= ""
end

-- Refuse mode changes while the first request is in flight (no session id yet)
-- or once locked. Returns blocked, reason ("locked" | "in_flight").
local function mode_change_blocked(p)
  if not p then
    return true, "locked"
  end
  if mode_locked(p) then
    return true, "locked"
  end
  if p.busy or p.job ~= nil or p.awaiting_exit then
    return true, "in_flight"
  end
  return false, nil
end

----------------------------------------------------------------------
-- STAGE 0 MID-CHAT SWITCH: quiescent renewal (the mode contract §3)
--
-- The operator's requirement is to change mode part-way through a chat and
-- keep talking. That cannot be a flag flip: cursor's upstream session carries a
-- FIXED mode chain, which is why mode_locked() exists and why the old product
-- simply refused. A mid-chat switch is therefore SESSION RENEWAL WITH CONTEXT
-- CARRY -- end the upstream session, start a new one in the new mode, hand it a
-- brief. From the operator's side the chat continues.
--
-- Stage 0 is deliberately the limited version. It is allowed ONLY at a boundary
-- where there is nothing to arbitrate, because the two defects that would make
-- arbitration wrong (dead-claim classification and path-alias identity)
-- only matter when something live must be weighed against something pending. At
-- a quiescent boundary there is nothing live and nothing pending, so there is
-- nothing to get wrong. Every precondition below is MEASURED, never assumed.
----------------------------------------------------------------------

--- Why this chat cannot renew right now, or nil if it can. Returns a message
--- naming the failing condition AND the action that clears it: a refusal the
--- operator cannot act on is only marginally better than a hang.
local function renewal_blocked_reason(p)
  if not p then
    return "no panel"
  end
  -- 1. no turn in flight
  if p.busy or p.job ~= nil or p.awaiting_exit then
    return "a turn is still running — wait for it to finish, or :YanaStop"
  end
  -- 2. no open review and no pending changes for this workspace
  local pending = require("yana.diff").pending(p.changes or {})
  if #pending > 0 then
    return string.format(
      "%d change(s) are still awaiting your decision — accept or reject them first (ca / :YanaReject)",
      #pending
    )
  end
  if require("yana.inline_diff").active_state({}) ~= nil then
    return "a review is open — finish or reject it first"
  end
  -- 3/4. the claim carries no review-open marker, and the previous turn
  -- released it. Read from DISK rather than from our own memory of it: the
  -- marker outliving the process is exactly the case this must not miss.
  local turn = p.shadow_turn
  local claim_dir = turn and turn.claim_dir or nil
  if claim_dir == nil and p.cwd then
    local okp, preview = pcall(require, "yana.shadow.preview")
    if okp then
      local okc, dir = pcall(preview.claim_dir, p.cwd)
      claim_dir = okc and dir or nil
    end
  end
  if claim_dir then
    local okj, jail = pcall(require, "yana.shadow.jail")
    if okj then
      if jail.review_open(claim_dir) then
        return "this workspace still has an open review recorded on disk — finish or reject it first"
      end
      if jail.claim_held(claim_dir) then
        return "the previous turn has not released its workspace claim yet — wait a moment, or release it if the holder is gone"
      end
    end
  end
  -- 5. no unresolved diary bundle awaiting apply or replay.
  --
  -- NOT IMPLEMENTED, AND THEREFORE ENFORCED THE ONLY HONEST WAY IT CAN BE.
  -- The spec requires all five preconditions to be MEASURED, never assumed.
  -- `diary` exposes no "is anything unresolved for this workspace" query today
  -- (it has open/apply_pending/list_displaced/recover_displaced, none of which
  -- answers it), and a check written against a function that does not exist is
  -- a check that can never fail -- the precise defect this project has spent
  -- the day removing from its own tests.
  --
  -- So this precondition is satisfied STRUCTURALLY rather than by query: the
  -- checks above already refuse while any change is pending, while a review is
  -- open, and while the claim is held or carries a review-open marker. A diary
  -- bundle awaiting apply cannot exist without at least one of those being
  -- true, because a bundle is opened for a turn and resolved at accept/reject.
  --
  -- That argument is a DERIVATION, not a measurement, and it is written here so
  -- it can be attacked rather than assumed. When diary grows a real query, this
  -- becomes a direct check and the derivation goes away. Until then, the
  -- weakest link in Stage 0 is named and it is this one.
  return nil
end

--- The brief handed to the renewed session, and shown to the operator at the
--- same moment. Explicitly NOT the raw transcript: a brief the operator can
--- read in five lines beats a replay nobody checks, and a handoff they cannot
--- see is a handoff they cannot correct.
local function renewal_brief(p, from_mode, to_mode)
  local lines = {
    "Continuing an existing conversation in a new mode.",
    string.format("Workspace: %s", tostring(p.cwd or vim.fn.getcwd())),
    string.format("Mode: %s (was %s)", tostring(to_mode), tostring(from_mode)),
  }
  if p.last_question and p.last_question ~= "" then
    local q = tostring(p.last_question):gsub("%s+", " ")
    if #q > 300 then
      q = q:sub(1, 300) .. "…"
    end
    lines[#lines + 1] = "Previous instruction: " .. q
  end
  local accepted, rejected, refused = {}, {}, {}
  for _, c in ipairs(p.changes or {}) do
    local name = c.rel or c.path
    if name then
      if c.status == "accepted" then
        accepted[#accepted + 1] = name
      elseif c.status == "rejected" then
        rejected[#rejected + 1] = name
      end
      if c.review_error and c.review_error ~= "" then
        refused[#refused + 1] = name .. " (" .. tostring(c.review_error) .. ")"
      end
    end
  end
  if #accepted > 0 then
    lines[#lines + 1] = "Accepted last turn: " .. table.concat(accepted, ", ")
  end
  if #rejected > 0 then
    lines[#lines + 1] = "Rejected last turn: " .. table.concat(rejected, ", ")
  end
  -- A refusal is part of the story: a control-plane refusal in particular is
  -- something the next session must not be told happened cleanly.
  if #refused > 0 then
    lines[#lines + 1] = "Refused: " .. table.concat(refused, ", ")
  end
  return table.concat(lines, "\n")
end

local function mode_change_refused_notify(p, reason)
  local nk = (config.options.keymaps or {}).new_chat
  local new_hint = (nk and nk ~= "") and (" with " .. nk) or " (:YanaNew)"
  if reason == "in_flight" then
    notify_one_line(
      "yana: wait for the current turn to finish before changing mode",
      vim.log.levels.WARN
    )
    return
  end
  notify_one_line(
    "yana: mode is locked for this chat — start a new chat"
      .. new_hint
      .. " to change mode",
    vim.log.levels.WARN
  )
end

----------------------------------------------------------------------
-- winbar / spinner
----------------------------------------------------------------------

-- Invariant capture: the number the user is SHOWN against the number the
-- review engine holds. They differ legitimately for most of a turn — a change
-- is pending long before its review is enqueued — so only the stuck shape is a
-- violation: the panel claims pending work, the engine has none queued, none
-- active and none batched, and nothing is in flight that could still produce
-- one. That is a counter the user cannot clear by any action, which is exactly
-- the observed failure.
local function reconcile_pending(p, panel_pending)
  local ok, inline = pcall(require, "yana.inline_diff")
  if not ok then
    return
  end
  local pool_pending = inline.pending_count()
  local batched = inline.batched_count()
  local idle = not p.busy and p.job == nil and not p.awaiting_exit and p.shadow_turn == nil
  local stuck = panel_pending > 0 and pool_pending == 0 and batched == 0 and idle
  local L = turn_ledger(p)
  ledger.record_pending(L, {
    panel = panel_pending,
    pool = pool_pending,
    batched = batched,
    idle = idle,
    stuck = stuck,
  })
  if stuck then
    local sig = string.format("%d/%d", panel_pending, pool_pending)
    if L.pending_desync_sig ~= sig then
      L.pending_desync_sig = sig
      log.write(
        "WARN",
        string.format(
          "yana.ui: pending counter desync — panel shows %d pending, review engine holds 0 (queued 0, active 0, batched 0) with no turn in flight; :YanaDump for state",
          panel_pending
        )
      )
    end
  end
end

local function winbar_text(p)
  local o = config.options
  local left
  if p.applying then
    -- THE GATED ACTION. CORE's Async principle licenses an accept to hold the
    -- operator's loop while its durable evidence is written, and names exactly
    -- one remedy: "Gate the ACTION briefly when its bundle is not yet published
    -- (spinner on accept)". This is that spinner. It sits ABOVE the `busy`
    -- branch because an accept issued mid-turn must say what the editor is
    -- doing NOW -- the fsyncs the operator is waiting on -- not that a turn is
    -- also in flight.
    local frame = o.ui.spinner[p.spinner.idx] or ""
    left = frame .. " applying…"
  elseif p.busy then
    local frame = o.ui.spinner[p.spinner.idx] or ""
    left = frame .. " thinking…"
  elseif p.awaiting_exit then
    left = p.pending_redirect and "⏳ redirecting…" or "⏳ stopping…"
  else
    left = " yana"
  end
  if #panels > 1 then
    left = left .. " [" .. panel_index(p) .. "]"
  end
  local sess
  if p.title and p.title ~= "" then
    sess = p.title
    if #sess > 24 then
      sess = sess:sub(1, 23) .. "…"
    end
    -- ESCAPE THE PERCENTS. p.title is the raw first line of the user's prompt,
    -- and 'winbar' is a statusline-syntax option: a bare "%" raises E539 and
    -- "%{" raises E540. So a first prompt like "cut tokens by 50%" made every
    -- update_winbar throw -- including the one in on_done, which sits BEFORE
    -- persist_session and maybe_drain_queue, so queued prompts stopped
    -- draining and the session stopped persisting for the rest of the
    -- session. A lifecycle stall reachable by typing an ordinary sentence.
    sess = "  · " .. sess:gsub("%%", "%%%%")
  else
    sess = p.session_id and "  · session" or "  · new"
  end
  local pending = #diff.pending(p.changes)
  reconcile_pending(p, pending)
  local pend = pending > 0 and (" · " .. pending .. " pending") or ""
  local qn = #p.queue
  local queued = qn > 0 and (" · " .. qn .. " queued") or ""
  local shell_fail = ""
  if not p.busy and not p.awaiting_exit and (p.shell_steps_failed or 0) > 0 then
    shell_fail = string.format(
      " · %d command failed (exit %s)",
      p.shell_steps_failed,
      tostring(p.first_failed_shell_exit or "?")
    )
  end
  local shadow = ""
  if not config.overlay_mode() then
    shadow = " · shadow:preview"
  elseif config.review_mode_active() then
    shadow = " · shadow:apply"
  else
    -- `ask`: confined like `inline`, but nothing is proposed so no review is
    -- owed. Saying so beats saying nothing, which reads as "no overlay".
    shadow = " · shadow:confined"
  end
  return string.format("%%#Title#%s%%* · %s%s · model: %s%s%s%s%s%s",
    left,
    config.panel_mode(p.mode),
    mode_locked(p) and " (locked)" or "",
    p.model or "auto",
    pend,
    queued,
    shell_fail,
    shadow,
    sess)
end

local function update_winbar(p)
  if win_valid(p.conv_win) then
    -- Cosmetic chrome must never be able to abort its caller. update_winbar
    -- is called from on_done ahead of persist_session and maybe_drain_queue,
    -- so a throw here used to cost the session its queue drain and its
    -- persistence. Escaping (above) removes the known trigger; this removes
    -- the whole class of consequence.
    pcall(function()
      vim.wo[p.conv_win].winbar = winbar_text(p)
    end)
  end
end

local function stop_spinner(p)
  if p.spinner.timer then
    p.spinner.timer:stop()
    if not p.spinner.timer:is_closing() then
      p.spinner.timer:close()
    end
    p.spinner.timer = nil
  end
end

local function start_spinner(p)
  stop_spinner(p)
  p.spinner.idx = 1
  local timer = uv.new_timer()
  p.spinner.timer = timer
  timer:start(0, 100, vim.schedule_wrap(function()
    log.guard("yana.ui spinner timer", function()
      if not p.busy and not p.applying then
        stop_spinner(p)
        return
      end
      local frames = config.options.ui.spinner
      p.spinner.idx = (p.spinner.idx % #frames) + 1
      update_winbar(p)
    end)
  end))
end

-- ANNOUNCING THE GATED ACCEPT.
--
-- The accept path opens the durable journal, writes an intent row, captures a
-- checkpoint and renames the target through fsync: measured at 427-1243 ms of
-- blocked loop for one path and 1676-4003 ms in aggregate for a bulk accept
-- over five, about 90% of it fsync. CORE licenses that wait on the ACTION and
-- names a spinner as the remedy; until now `start_spinner` was called only
-- from the submit path, so the operator got an unannounced freeze at the exact
-- moment they pressed accept -- indistinguishable from a hang.
--
-- WHAT THIS CAN AND CANNOT DO, stated here rather than implied. The frame is
-- painted BEFORE the first fsync, and `redraw` forces that paint out to the
-- terminal, because setting 'winbar' only marks the window dirty and Neovim
-- would otherwise repaint after the stall -- i.e. after the thing the notice
-- exists to announce. It CANNOT animate: the spinner's cadence is a uv timer
-- delivered through `vim.schedule_wrap`, and a blocked loop is precisely a loop
-- that delivers nothing. What the operator gets is a static "⠋ applying…" that
-- appears before the editor goes quiet and disappears when it comes back. That
-- is the honest ceiling of any in-process indication while the durable work is
-- synchronous, and it is still the difference between a hang and a wait.
--
-- ONE OPERATION, ONE INDICATION. The clear is scheduled, not called: a bulk
-- accept drives this funnel once per path with the loop blocked throughout, so
-- the re-entry guard suppresses every later start and the single scheduled
-- clear runs when the loop is free again -- after the last path, not between
-- paths. The same property is what clears it on EVERY exit: the clear is queued
-- before the durable work is entered, so a refusal, a `return false` or a THROW
-- out of the applier all leave it queued. A THROW IS A HALT (CORE), and a
-- spinner that outlives its operation is a lie about state.
local function begin_accept_indication(p)
  if not p or p.applying then
    return
  end
  p.applying = true
  -- Reuse the submit path's timer rather than adding a second one. When the
  -- panel is already busy its timer is running and owns the frame; restarting
  -- it here would reset a live turn's animation for nothing.
  if not p.busy then
    start_spinner(p)
  end
  update_winbar(p)
  pcall(vim.cmd, "redraw")
  vim.schedule(function()
    log.guard("yana.ui accept indication clear", function()
      p.applying = nil
      -- Only the accept's own spinner stops here. A turn still in flight owns
      -- the timer and must keep it.
      if not p.busy then
        stop_spinner(p)
      end
      update_winbar(p)
    end)
  end)
end

----------------------------------------------------------------------
-- rendering turns
----------------------------------------------------------------------

local function render_user(p, question, label)
  local lines = { "## You", "" }
  for _, l in ipairs(vim.split(question, "\n", { plain = true })) do
    table.insert(lines, l)
  end
  if label then
    table.insert(lines, "")
    table.insert(lines, "_context: `" .. label .. "`_")
  end
  table.insert(lines, "")
  append(p, lines, "user")
end

local function start_assistant_block(p)
  p.stream_text = ""
  p.stream_seq_first = nil
  p.stream_seq_last = nil
  p.stream_gen = nil
  p.rendered_any = false
  append(p, { "## Cursor · " .. config.panel_mode(p.mode), "" }, "assistant_header")
  p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
end

-- Streaming REWRITES the assistant region rather than appending, and it runs
-- once per delta, so it is counted rather than ringed: one ring entry per
-- delta would evict every structural append long before the turn ends. The
-- committed segment gets the ring entry instead (commit_stream below), which
-- is the granularity repetition is judged at.
local function render_stream(p)
  local lines = vim.split(p.stream_text, "\n", { plain = true })
  set_lines(p, p.assistant_start, -1, lines)
  ledger.bump(turn_ledger(p), "stream_renders")
  scroll_to_bottom(p)
end

local function append_stream(p, delta)
  if delta == nil or delta == "" then
    return
  end
  p.rendered_any = true
  -- Provenance for the segment being BUILT. The segment's ring entry is only
  -- written when the segment is committed (below), and by then the current
  -- event is the tool call that froze it or the result that ended it — so
  -- reading `event_seq_current` there attributed a repeated assistant sentence
  -- to the following tool-call sequence. Carry the originating seq range (and
  -- the generation that owns it) on the pending segment instead.
  local L = turn_ledger(p)
  local seq = ledger.current_event(L)
  if seq ~= nil then
    if p.stream_seq_first == nil then
      p.stream_seq_first = seq
      p.stream_gen = L.gen
    end
    p.stream_seq_last = seq
  end
  p.stream_text = p.stream_text .. delta
  render_stream(p)
end

-- "Freeze" the current streamed text so following content (tool output) is
-- appended after it, and subsequent deltas start a fresh segment.
local function commit_stream(p)
  if p.stream_text ~= "" then
    ledger.note_append_at(
      turn_ledger(p, p.stream_gen),
      "stream",
      vim.split(p.stream_text, "\n", { plain = true }),
      p.stream_seq_first,
      p.stream_seq_last
    )
  end
  p.stream_text = ""
  p.stream_seq_first = nil
  p.stream_seq_last = nil
  p.stream_gen = nil
  p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
end

local function render_note(p, text)
  append(p, { "_" .. text .. "_", "" }, "note")
end

local function render_tool_note(p, name, payload)
  commit_stream(p)
  p.rendered_any = true
  append(p, { "_⚙ " .. diff.tool_summary(name, payload) .. "_", "" }, "tool_note")
  p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
end

local function change_footer_text(change, _k)
  if change.status == "pending" then
    local maps = config.options.diff_keymaps or {}
    return string.format(
      "_Review in **file buffer**: `%s` reject hunk · `%s` accept hunk · `%s` accept all · `%s` accept all changes · `%s` abort file_",
      maps.ours or "co",
      maps.theirs or "ct",
      maps.all_theirs or "ca",
      maps.all_changes or "cA",
      maps.both or "cb"
    )
  end
  if change.status == "accepted" then
    return "_accepted — agent edit kept_"
  end
  if change.status == "kept_unreviewed" then
    return "_kept unreviewed — agent edit kept, no consent recorded_"
  end
  return "_rejected — file restored to pre-edit content_"
end

local function conv_base_line(p)
  local n = vim.api.nvim_buf_line_count(p.conv_buf)
  if n == 1 and vim.api.nvim_buf_get_lines(p.conv_buf, 0, 1, false)[1] == "" then
    return 0
  end
  return n
end

local function change_header_text(change, counts)
  local badge = change.undeclared and " · undeclared" or ""
  return "**"
    .. diff.status_icon(change)
    .. " "
    .. diff.kind_verb(change)
    .. " `"
    .. notify.flatten(change.rel)
    .. "`** "
    .. counts
    .. badge
end

local function stamp_undeclared_badge(p, change)
  if change.undeclared ~= nil then
    return
  end
  change.undeclared = require("yana.turn_lifecycle").is_undeclared_tracked(p.turn_pass, change.rel)
end

-- The change's block is addressed by ABSOLUTE line numbers stamped when it was
-- rendered (conv_header_line/conv_footer_line). Anything that shortens or
-- replaces the conversation after that — `new_chat`, a session resume — leaves
-- those numbers pointing past the end of the buffer, and nvim_buf_set_lines
-- THROWS on an out-of-range index. That throw propagates out of the panel's
-- on_accept handler and used to strand the review engine's teardown entirely
-- (see notify_owner in inline_diff.lua). Clamp instead: a stale stamp means
-- the block this change belonged to is gone, so there is nothing to refresh
-- and silently doing nothing is correct. Writing at a clamped-but-wrong line
-- would corrupt an unrelated line of the new conversation, so out-of-range is
-- a no-op, never a best-effort write.
local function refresh_change_block(p, change)
  if not buf_valid(p.conv_buf) or not change.conv_header_line then
    return
  end
  local total = vim.api.nvim_buf_line_count(p.conv_buf)
  if change.conv_header_line < 1 or change.conv_header_line > total then
    return
  end
  local k = config.options.keymaps
  local counts = string.format("(+%s −%s)", change.added or "?", change.removed or "?")
  local header = change_header_text(change, counts)
  vim.bo[p.conv_buf].modifiable = true
  -- pcall + unconditional restore, matching refresh_review_claim: a throw
  -- between these lines left the conversation buffer permanently editable and
  -- skipped the rest of on_accept (claim sweep, winbar).
  pcall(function()
    vim.api.nvim_buf_set_lines(p.conv_buf, change.conv_header_line - 1, change.conv_header_line, false, { header })
    if change.conv_footer_line and change.conv_footer_line >= 1 and change.conv_footer_line <= total then
      vim.api.nvim_buf_set_lines(
        p.conv_buf,
        change.conv_footer_line - 1,
        change.conv_footer_line,
        false,
        { change_footer_text(change, k) }
      )
    end
  end)
  vim.bo[p.conv_buf].modifiable = false
end

local function reload_after_scope_revert(change)
  local path = change.path
  if not path or path == "" then
    return true
  end
  local bufnr = vim.fn.bufnr(path)
  if bufnr <= 0 or not vim.api.nvim_buf_is_loaded(bufnr) then
    return true
  end
  if not vim.bo[bufnr].modified then
    return diff.reload_file(path)
  end
  local buf_text = diff.buffer_text_normalized(bufnr)
  if diff.text_equal_snapshot(buf_text, change.before or "") then
    return diff.reload_file(path, { force = true })
  end
  return false, "buffer has divergent edits; not reloaded"
end

local function scope_rejection_cap_note(p, change, reason)
  local scope = change.scope
  local zone = scope
    and string.format("L%d–L%d (%s)", scope.zone_l1, scope.zone_l2, scope.node_kind or "zone")
    or "selection zone"
  local wanted = reason or "edit outside selection scope"
  append(p, {
    "",
    "**⏹ stopped — repeated out-of-zone edits**",
    "",
    "> Enforced zone: " .. zone,
    "> Agent wanted: " .. wanted,
    "",
    "_Widen or clear the visual selection and re-ask, or set `selection_scope.enforce = \"warn\"` in yana config to keep out-of-zone hunks reviewable._",
    "",
  })
end

local function bump_scope_rejection(p, change, reason)
  local path = vim.fs.normalize(diff.abs_path(change.path))
  p.scope_rejections[path] = (p.scope_rejections[path] or 0) + 1
  local cap = config.options.selection_scope.rejection_cap
  if p.scope_rejections[path] >= cap and p.busy then
    cancel_inflight(p)
    scope_rejection_cap_note(p, change, reason)
  end
end

local function review_rejection_cap_note(p, change)
  append(p, {
    "",
    "**⏹ stopped — repeated re-edits after rejection**",
    "",
    "> File: " .. (change.rel or change.path or "?"),
    "",
    "_The agent kept re-applying hunks you rejected in `"
      .. (change.rel or change.path or "?")
      .. "`; the turn was stopped._",
    "",
  })
end

-- Mirrors bump_scope_rejection but for inline-review rejections: a
-- still-running agent can re-read disk after a reject and re-apply the same
-- hunk, the same loop the selection-scope path already caps. Keyed
-- separately from p.scope_rejections since these are unrelated counters.
local function bump_review_rejection(p, change)
  local path = vim.fs.normalize(diff.abs_path(change.path))
  p.review_rejections[path] = (p.review_rejections[path] or 0) + 1
  local cap = config.options.selection_scope.rejection_cap
  if p.review_rejections[path] >= cap and p.busy then
    cancel_inflight(p)
    review_rejection_cap_note(p, change)
  end
end

local function render_scope_rejection(p, change, reason)
  commit_stream(p)
  p.rendered_any = true

  -- change.rel can be nil (e.g. changes synthesized without a workspace-
  -- relative path); every message below must fall back like the rest of
  -- this file does, or a nil concat crashes this scheduled handler.
  local label = change.rel or change.path or "?"

  local disk_text = diff.read_file_text(change.path)
  if disk_text == nil or not diff.text_equal_snapshot(disk_text, change.after or "") then
    append(p, {
      "",
      "**⚠ could not revert `" .. label .. "`** (disk changed since agent edit)",
      "",
      "> " .. (reason or "edit outside selection zone"),
      "> Preserving on-disk content; change left pending.",
      "",
    })
    notify_one_line(
      "yana: disk diverged for " .. label .. "; not reverting",
      vim.log.levels.WARN
    )
    bump_scope_rejection(p, change, reason)
    return
  end

  if change.before == nil then
    append(p, {
      "",
      "**⚠ could not revert `" .. label .. "`** (no pre-edit snapshot)",
      "",
      "> " .. (reason or "edit outside selection zone"),
      "> No before-content was captured for this edit; leaving it pending.",
      "",
    })
    notify_one_line(
      "yana: no pre-edit snapshot for " .. label .. "; not reverting",
      vim.log.levels.WARN
    )
    bump_scope_rejection(p, change, reason)
    return
  end

  if control_plane.is_control_plane(diff.abs_path_literal(change.path or "")) then
    -- Legacy scope-revert is a direct real-tree write; the matcher guards it too
    -- A control-plane path is never written back.
    notify_one_line(
      "yana: refused to revert control-plane path " .. tostring(change.path),
      vim.log.levels.WARN
    )
    return
  end
  local apply = require("yana.shadow.apply")
  local ok, werr = apply.scope_revert(p, change)
  if not ok then
    append(p, {
      "",
      "**⚠ could not revert `" .. label .. "`** (outside selection scope)",
      "",
      "> " .. (reason or "edit outside selection zone"),
      "> Revert failed: " .. tostring(werr),
      "",
    })
    notify_one_line(
      "yana: could not revert " .. label .. ": " .. tostring(werr),
      vim.log.levels.WARN
    )
    bump_scope_rejection(p, change, reason)
    return
  end
  local rok, rerr = reload_after_scope_revert(change)
  if not rok then
    append(p, {
      "",
      "**⚠ reverted `" .. label .. "` on disk but buffer not reloaded**",
      "",
      "> " .. (reason or "edit outside selection zone"),
      "> " .. tostring(rerr),
      "",
    })
    notify_one_line("yana: " .. tostring(rerr), vim.log.levels.WARN)
  end
  change.status = "rejected"
  append(p, {
    "",
    "**✗ rejected `" .. label .. "`** (outside selection scope)",
    "",
    "> " .. (reason or "edit outside selection zone"),
    "",
  })
  notify_one_line("yana: " .. (reason or "edit outside selection zone"), vim.log.levels.WARN)
  bump_scope_rejection(p, change, reason)
end

local function panel_claimed_workspace(p)
  if not p then
    return require("yana.diff").abs_path(vim.fn.getcwd())
  end
  if p.shadow_turn and p.shadow_turn.workspace and p.shadow_turn.workspace ~= "" then
    return require("yana.diff").abs_path(p.shadow_turn.workspace)
  end
  local preview = require("yana.shadow.preview")
  return preview.workspace_for_turn({
    cwd = p.cwd or vim.fn.getcwd(),
  })
end

-- Shared on_accept/on_reject pair for an inline review of `change`. Used by
-- render_tool_change's first-time inline.enqueue AND by the accept_change/
-- reject_change retry path below, so a retried review behaves identically to
-- the original one instead of duplicating this callback pair.
-- Rewrite one change's claim line from what the review engine ACTUALLY did.
-- Same clamping contract as refresh_change_block: a stale stamp means the
-- block is gone, and a no-op beats corrupting an unrelated line.
local function refresh_review_claim(p, change)
  if not buf_valid(p.conv_buf) or not change.conv_claim_line then
    return
  end
  local total = vim.api.nvim_buf_line_count(p.conv_buf)
  if change.conv_claim_line < 1 or change.conv_claim_line > total then
    return
  end
  local inline = require("yana.inline_diff")
  local ws_opts = change.review_workspace and { workspace = change.review_workspace }
    or { workspace = panel_claimed_workspace(p) }
  local text
  if change.review_error then
    -- FLATTENED, and this is not cosmetic. review_error routinely carries a
    -- multi-line value: a failed save stamps the full nvim_exec2 error
    -- including its stack traceback. nvim_buf_set_lines REJECTS any item
    -- containing a newline, so the raw string throws inside this repaint --
    -- which the observer's pcall swallows, so claim lines just silently stop
    -- updating from that moment on (and the sweep below aborts, taking every
    -- later change with it). That is the "keeps falling off" symptom itself.
    -- Budgeted to two screen lines: the full text is already in the log.
    text = "_Review refused: "
      .. notify.one_line_text(change.review_error, math.max(16, (vim.o.columns - 1) * 2))
      .. " — this review changed nothing._"
  elseif change.status == "superseded" then
    text = "_Merged into the review for this file._"
  elseif change.status == "accepted" or change.status == "rejected" or change.status == "kept_unreviewed" then
    text = "_Resolved (" .. change.status .. ")._"
  elseif change.batched then
    -- Not queued and not open: waiting for the turn to end. Saying "queued
    -- behind N reviews" here would be the same class of lie the placeholder
    -- used to tell -- there is no queue entry for it yet.
    local merged = change.merged_count or 1
    text = merged > 1 and string.format("_Review opens when the turn ends (%d edits merged)._", merged)
      or "_Review opens when the turn ends._"
  elseif inline.active_change(ws_opts) == change then
    text = "_Hunks open in the source file — switch to that window._"
  else
    -- Ask the engine for THIS change's position; pending_count()-1 gave every
    -- queued change the same figure and counted items queued behind it.
    local ahead = inline.queue_wait(change, ws_opts) or math.max(0, inline.pending_count(ws_opts) - 1)
    text = ahead > 0 and string.format("_Queued behind %d review(s) — no hunks in this file yet._", ahead)
      or "_Queued — no hunks in this file yet._"
  end
  vim.bo[p.conv_buf].modifiable = true
  -- pcall + unconditional restore: a throw between these two lines used to
  -- leave the conversation buffer permanently editable, and killed the sweep
  -- in refresh_all_review_claims for every change after this one.
  pcall(vim.api.nvim_buf_set_lines, p.conv_buf, change.conv_claim_line - 1, change.conv_claim_line, false, { text })
  vim.bo[p.conv_buf].modifiable = false
end

local function preview_module()
  return require("yana.shadow.preview")
end

-- Close the workspace claim this turn holds, then drop the turn's private
-- state. Every path that finishes or abandons a review funnels through here.
--
-- Agent process exit is deliberately NOT one of those paths: while a review is
-- open the claim outlives the process that created it, which is what stops a
-- following turn from editing files still under review.
local function release_shadow_turn(p, reason)
  local turn = p.shadow_turn
  p.shadow_turn = nil
  p.shadow_pass = nil
  -- The review resolved, so the turn's durable record says so. `retain_shadow
  -- _turn` deliberately does NOT come through here: a turn whose evidence could
  -- not be read leaves its record open, which is what makes it recoverable.
  if p.turn_pass then
    require("yana.turn_lifecycle").close_turn(p.turn_pass, reason)
    p.turn_pass = nil
  end
  if not turn then
    return
  end
  local preview = preview_module()
  local ok, err = preview.release(turn)
  if not ok then
    log.write(
      log.levels.WARN,
      string.format(
        "yana: releasing the workspace claim failed (%s): %s",
        reason or "review closed",
        tostring(err)
      )
    )
  end
  preview.discard(turn)
end

-- A turn whose evidence could not be read leaves the claim and the private
-- state exactly where they are. Whether a review is owed is unknown, and the
-- module forbids guessing: the operator inspects and force-releases instead.
local function retain_shadow_turn(p, reason)
  local turn = p.shadow_turn
  if not turn or not turn.claim_dir then
    return
  end
  require("yana.shadow.jail").mark_review_open(turn.claim_dir)
  notify_one_line(
    string.format(
      "yana: %s is still claimed (%s) — inspect the turn state, then force-release to continue",
      turn.workspace,
      reason or "turn state unresolved"
    ),
    vim.log.levels.WARN
  )
end

-- When a review resolves, the queue advances: the change that was "queued"
-- is now the open one, and every remaining claim's position shifted. Sweep
-- them all so no block keeps describing a state the engine has left.
local function refresh_all_review_claims(p)
  for _, c in ipairs(p.changes or {}) do
    refresh_review_claim(p, c)
  end
end

local MAX_REVIEW_RETRY = 5
local REVIEW_RETRY_EXHAUSTED = "retry_exhausted"

local function inline_review_opts(p, change)
  local apply_mode = config.review_mode_active()
  local journaled = config.overlay_mode()
  local ws = (change and change.review_workspace) or panel_claimed_workspace(p)
  return {
    workspace = ws,
    review_owner = { panel_id = p.id, epoch = p.review_epoch },
    turn_pass = p.turn_pass,
    -- INTEGRATION NOTE (orchestrator, merging lane A with lane C). The two lanes
    -- changed the same expression for different reasons and both changes are
    -- required, so neither side was taken whole:
    --
    --   * lane A (3a) widened the journaled route from `apply_mode` to
    --     `journaled`, i.e. preview accepts are journaled too, and added
    --     `accept_standalone` for a panel that has no shadow pass. Narrowing
    --     this back to apply-only would restore an unjournaled preview accept —
    --     exactly the unjournaled-writer hole this path exists to close.
    --   * lane C (7a/7b) added the actionability predicate and the owning tuple.
    --     Dropping those would reopen arch BLOCKER-2.
    --
    -- So the route stays `journaled` and carries lane C's two guards, with the
    -- standalone path preserved for a panel with no shadow pass.
    shadow_apply = journaled,
    -- Two separate guards, and they are not the same guard twice:
    --
    --   * the ACTIONABILITY predicate — this accept waits for the turn's
    --     classified bundle to publish, so an accept issued while the review is
    --     still provisional does not write (the fixed safety contract, async principle);
    --   * the OWNING TUPLE — the pass that owned this review is captured HERE,
    --     at build time, and `bind_callback` refuses the delivery if the live
    --     pass is a different one. Resolving the pass through whatever panel
    --     happens to be current at delivery time is how a callback from turn N
    --     binds its change to turn N+1 (arch BLOCKER-2).
    --
    -- LIMIT, stated rather than implied: a panel with no lifecycle pass has not
    -- been through `submit_panel`, so this gate cannot judge it. That case logs
    -- rather than passing silently.
    on_shadow_accept = journaled and (function()
      local lifecycle = require("yana.turn_lifecycle")
      local owner = p.turn_pass
      local accept = function(c, composed)
        local panel = current_panel()
        if not panel then
          return false, "no panel"
        end
        -- BEFORE THE FIRST FSYNC, and that is why it is here rather than one
        -- statement above the applier. Every branch below this point does
        -- durable I/O: the refusals reach `log.write`, which fsyncs its line,
        -- and the acceptances reach the diary, which fsyncs thirteen times.
        -- There is no branch of a pressed accept that costs nothing, so the
        -- announcement belongs at the top of the funnel and not beside one of
        -- its outcomes.
        begin_accept_indication(panel)
        if owner then
          local allowed, why = lifecycle.action_allowed(owner, c and (c.rel or c.path))
          if not allowed then
            return false, why
          end
        else
          log.write(
            log.levels.WARN,
            "yana: shadow accept ran with no turn lifecycle pass — actionability was not checked"
          )
        end
        local apply = require("yana.shadow.apply")
        if panel.shadow_pass then
          return apply.accept_composed(panel.shadow_pass, c, composed)
        end
        return apply.accept_standalone(panel, c, composed)
      end
      return owner and lifecycle.bind_callback(owner, "shadow accept", accept) or accept
    end)() or nil,
    on_accept = function(c)
      refresh_change_block(p, c)
      refresh_all_review_claims(p)
      update_winbar(p)
      notify_one_line("yana: accepted " .. c.rel, vim.log.levels.INFO)
    end,
    on_kept_unreviewed = function(c)
      refresh_change_block(p, c)
      refresh_all_review_claims(p)
      update_winbar(p)
    end,
    on_reject = function(c)
      refresh_change_block(p, c)
      refresh_all_review_claims(p)
      update_winbar(p)
      notify_one_line("yana: rejected " .. c.rel .. " (reverted)", vim.log.levels.INFO)
      bump_review_rejection(p, c)
    end,
    on_close = function(_state, _accepted)
      if not apply_mode then
        return
      end
      local pending = 0
      for _, c in ipairs(p.changes or {}) do
        if c.shadow_apply and c.status == "pending" then
          pending = pending + 1
        end
      end
      if pending == 0 and p.shadow_pass then
        local apply = require("yana.shadow.apply")
        apply.finish_pass(p.shadow_pass)
        -- Last hunk resolved: the review is closed, so the claim goes back.
        release_shadow_turn(p, "review closed")
        maybe_drain_queue(p)
      end
    end,
  }
end

----------------------------------------------------------------------
-- turn-batched review (S8)
----------------------------------------------------------------------

-- Fold a later change to the same path into the turn's owning change.
-- `before` stays the FIRST edit's before (true pre-turn state); `after`
-- becomes the LAST one, which is what disk actually holds at turn end.
local function coalesce_into_owner(owner, change)
  -- Kind must be merged, not inherited. Without this, edit-then-delete left
  -- the owner kind="modify" with after=nil; open_review_buffer then took the
  -- "agent-created new file" branch and wrote nil (== "") to disk, recreating
  -- the file the agent had deleted as an empty file.
  if change.kind == "delete" then
    owner.kind = "delete"
    owner.after = nil
    if owner.before == nil then
      -- Created and deleted inside one turn: nothing on disk, nothing to
      -- review, and no snapshot to restore. Not an error, not a review.
      owner.net_noop = true
    end
  else
    owner.after = change.after
    owner.net_noop = nil
    owner.kind = (owner.before == nil) and "create" or "modify"
  end
  owner.diff = diff.synthesize_diff(owner.before or "", owner.after or "", owner.path)
  local added, removed = diff.count_stats(owner.diff)
  owner.added, owner.removed = added, removed
  owner.merged_count = (owner.merged_count or 1) + 1
  change.status = "superseded"
  change.superseded_by = owner.id
  change.batched = false
end

-- Enqueue everything the turn wrote, in the order it was written. Idempotent
-- and gen-independent by design: it is called from on_exit_confirmed (the ONLY
-- callback that fires for every job death, including a cancelled turn whose
-- on_done is dropped by the generation gate) and again from on_done (which is
-- the sole path for a spawn failure, where on_exit never fires at all).
local function flush_review_batch(p)
  local batch = p.review_batch
  p.review_batch = {}
  p.review_batch_by_path = {}
  if not batch or #batch == 0 then
    return 0
  end
  local inline = require("yana.inline_diff")
  local opts = inline_review_opts(p)
  local n = 0
  for _, owner in ipairs(batch) do
    inline.unmark_batched(owner.path, opts)
    owner.batched = false
    if owner.review_epoch ~= nil and owner.review_epoch ~= p.review_epoch then
      goto continue_flush
    end
    if owner.status == "pending" then
      if owner.net_noop then
        owner.status = "kept_unreviewed"
      else
        n = n + 1
        ledger.bump(turn_ledger(p, owner.turn_gen), "reviews_enqueued")
        inline.enqueue(owner, opts)
      end
    end
    ::continue_flush::
    refresh_review_claim(p, owner)
    refresh_change_block(p, owner)
  end
  update_winbar(p)
  return n
end

-- new_chat only. NOT panel close: there is no panel-destroy lifecycle here
-- (close is a WinClosed on the sibling window; the panel object, its job and
-- its changes all survive), inline reviews open in the SOURCE buffers rather
-- than the panel, and a turn finishing behind a closed panel reviews fine.
-- Dropping the batch on window close would silently discard reviewable edits
-- for the ordinary close-and-reopen flow.
local function drop_review_batch(p)
  local inline = require("yana.inline_diff")
  local opts = inline_review_opts(p)
  for _, owner in ipairs(p.review_batch or {}) do
    inline.unmark_batched(owner.path, opts)
    owner.batched = false
    if owner.status == "pending" then
      owner.status = "kept_unreviewed"
    end
  end
  p.review_batch = {}
  p.review_batch_by_path = {}
end

local function render_tool_change(p, change)
  commit_stream(p)
  p.rendered_any = true
  local k = config.options.keymaps
  stamp_undeclared_badge(p, change)
  if (not change.diff or change.diff == "") and change.before and change.after then
    change.diff = diff.synthesize_diff(change.before, change.after, change.path)
    local added, removed = diff.count_stats(change.diff)
    change.added = change.added or added
    change.removed = change.removed or removed
  end
  local counts = string.format("(+%s −%s)", change.added or "?", change.removed or "?")
  local block =
    { "", change_header_text(change, counts), "" }
  local claim_index = nil
  do
    -- Observed, not asserted. Only ONE review is open at a time; every other
    -- edit in the same turn is queued behind it, and some are refused outright
    -- (stale disk, unsaved edits, no snapshot). Claiming "hunks opened" for
    -- each of ten edits printed nine lines describing reviews that did not
    -- exist, which is the operator-visible face of every stall in this
    -- subsystem: "it says hunks opened but I see nothing in the file."
    -- The real status is stamped by refresh_review_claim once the engine has
    -- actually decided; this is the placeholder it overwrites.
    claim_index = #block + 1
    table.insert(block, "_Review opens when the turn ends._")
  end
  table.insert(block, change_footer_text(change, k))
  table.insert(block, "")
  local base = conv_base_line(p)
  append(p, block, "tool_change")
  change.conv_header_line = base + 2
  change.conv_footer_line = base + #block - 1
  change.conv_claim_line = claim_index and (base + claim_index) or nil
  p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
  do
    -- NOT enqueued here. Opening a review mid-turn is unwinnable: the agent
    -- has already written this edit to disk and will keep writing, so by the
    -- time the review opens (or the one ahead of it resolves) disk no longer
    -- equals this change's `after` and the CAS refuses it. It also paints
    -- `before` into the buffer while disk holds `after`, so the agent's next
    -- edit reads disk and silently diverges from the buffer under an open
    -- review. Batch instead; flush when the process is dead.
    local inline = require("yana.inline_diff")
    p.review_batch = p.review_batch or {}
    p.review_batch_by_path = p.review_batch_by_path or {}
    local owner = p.review_batch_by_path[change.path]
    if owner then
      ledger.bump(turn_ledger(p, change.turn_gen), "changes_coalesced")
      coalesce_into_owner(owner, change)
    else
      ledger.bump(turn_ledger(p, change.turn_gen), "changes_batched")
      change.batched = true
      change.merged_count = 1
      change.review_epoch = p.review_epoch
      p.review_batch_by_path[change.path] = change
      table.insert(p.review_batch, change)
      inline.mark_batched(change.path, inline_review_opts(p))
    end
    vim.schedule(function()
      log.guard("yana.ui review batch refresh", function()
        refresh_review_claim(p, change)
        if owner then
          refresh_review_claim(p, owner)
          refresh_change_block(p, owner)
        end
      end)
    end)
  end
end

local function render_error(p, msg)
  append(p, { "", "> **error:** " .. (msg or "unknown error"), "" }, "error")
end

local function finish_assistant_block(p, result_obj)
  local o = config.options
  -- Fallback: nothing rendered at all but we have a final result string.
  if not p.rendered_any and result_obj and type(result_obj.result) == "string" and result_obj.result ~= "" then
    append_stream(p, result_obj.result)
  end
  if o.ui.show_usage and result_obj and result_obj.usage then
    local u = result_obj.usage
    local secs = result_obj.duration_ms and string.format("%.1fs", result_obj.duration_ms / 1000) or nil
    local bits = {}
    if u.outputTokens then
      table.insert(bits, u.outputTokens .. " out")
    end
    if u.inputTokens then
      table.insert(bits, u.inputTokens .. " in")
    end
    if secs then
      table.insert(bits, secs)
    end
    if #bits > 0 then
      append(p, { "", "_" .. table.concat(bits, " · ") .. "_" }, "usage")
    end
  end
  append(p, { "", "---", "" }, "separator")
end

----------------------------------------------------------------------
-- session persistence
----------------------------------------------------------------------

-- Record the panel's session in the registry and snapshot the rendered
-- conversation so it can be listed and resumed later.
local function persist_session(p)
  if not p.session_id or p.session_id == "" then
    return
  end
  sessions.record({
    id = p.session_id,
    title = p.title,
    cwd = p.cwd or vim.fn.getcwd(),
    mode = config.panel_mode(p.mode),
    model = p.model,
    turns = p.turns,
  })
  local transcript_written = false
  if buf_valid(p.conv_buf) then
    sessions.save_transcript(p.session_id, vim.api.nvim_buf_get_lines(p.conv_buf, 0, -1, false))
    transcript_written = true
  end

  -- Invariant capture: a transcript on disk with no registry row is a session
  -- that cannot be listed or resumed — the work is there and unreachable. Both
  -- facts are in hand here, once per persist: the row from the registry the
  -- record above just wrote, and one stat for the transcript. The registry
  -- FILE is checked too, because the in-memory cache would agree with itself
  -- even when the write failed.
  do
    -- Read the registry FILE, not sessions.get(): the cache is written by
    -- sessions.record() BEFORE save_registry() attempts the file, so a check
    -- built on it compares the cache with itself and reports health for a
    -- registry the product could not write. The size>0 heuristic that stood
    -- beside it was no better — a file holding `{}` passes it. One small read
    -- per persist, wrapped so that observing a turn can never break it.
    local ok_reg, row_present, registry_status = pcall(sessions.registry_row_on_disk, p.session_id)
    if not ok_reg then
      row_present, registry_status = false, "unreadable"
    end
    local registry_file = sessions.registry_file()
    local reg_stat = uv.fs_stat(registry_file)
    local missing = transcript_written and not row_present
    local L = turn_ledger(p)
    ledger.record_session_check(L, {
      session_id = p.session_id,
      registry_row = row_present and true or false,
      registry_status = registry_status,
      registry_file = registry_file,
      registry_bytes = reg_stat and reg_stat.size or 0,
      transcript = transcript_written,
      missing = missing and true or false,
    })
    if missing and L.session_check_sig ~= p.session_id then
      L.session_check_sig = p.session_id
      log.write(
        "WARN",
        string.format(
          "yana.ui: session registry row missing for %s after writing its transcript (registry %s, %d bytes, on-disk status %s) — the session will not be listable or resumable",
          tostring(p.session_id),
          registry_file,
          reg_stat and reg_stat.size or 0,
          tostring(registry_status)
        )
      )
    end
  end
end

----------------------------------------------------------------------
-- event handling
----------------------------------------------------------------------

-- An edit that reached DISK cannot be dropped just because its turn was
-- cancelled. `cancel_inflight` bumps turn_gen and only SENDS SIGTERM, so the
-- old cursor-agent process keeps emitting for a while — and any
-- `tool_call completed` it emits describes a file it has already written.
-- Dropping those events wholesale (the old behaviour of the guard below) meant
-- the user pressed stop and silently kept unreviewed, unrevertable edits: no
-- change record, no review, no pending count, nothing in the panel. Stream
-- text, thinking and result events from a dead turn are still dropped — those
-- are cosmetic and would corrupt the new turn's block. Only disk-bearing tool
-- calls survive the generation check, and they are marked so the panel can say
-- where they came from.
local function is_disk_bearing_tool_call(obj)
  if obj.type ~= "tool_call" or obj.subtype ~= "completed" then
    return false
  end
  local name, payload = diff.parse_tool(obj)
  if not name then
    return false
  end
  return diff.change_from_payload(name, payload) ~= nil
end

local function on_event_body(p, gen, obj)
  local stale = gen ~= p.turn_gen
  -- Provenance, record 2 of 3. Stamped for EVERY decoded event, stale ones
  -- included, before any gate can drop it: an event the panel never rendered
  -- still happened, and the conservation sum in the flow report is only
  -- honest if it is counted here rather than where it survives.
  local L = ledger.ensure(p.id, gen)
  local seq = ledger.note_event(L, obj, stale)
  ledger.mark(L, "first_event_decoded")
  -- Appends made underneath this call name `seq` as their cause. Cleared on
  -- the way out (and again at turn end) so an append made outside event
  -- handling records no cause rather than borrowing this one.
  ledger.set_current_event(L, seq)
  if stale and not is_disk_bearing_tool_call(obj) then
    ledger.set_current_event(L, nil)
    return
  end
  if stale then
    ledger.bump(L, "events_stale_disk_bearing")
  end
  local o = config.options
  if obj.type == "system" and obj.subtype == "init" then
    ledger.mark(L, "session_init")
    p.session_id = obj.session_id or p.session_id
  elseif obj.type == "assistant" then
    local content = obj.message and obj.message.content or {}
    for _, item in ipairs(content) do
      if item.type == "text" then
        -- Streaming deltas carry timestamp_ms but NOT model_call_id. The
        -- consolidated messages carry model_call_id (intermediate) or neither
        -- (final), so we render only true deltas to avoid duplication.
        if obj.timestamp_ms and not obj.model_call_id then
          append_stream(p, item.text or "")
        end
      elseif item.type == "thinking" then
        if o.ui.show_thinking and obj.timestamp_ms and not obj.model_call_id then
          append_stream(p, item.text or item.thinking or "")
        end
      end
    end
  elseif obj.type == "tool_call" then
    -- Tool calls are top-level events. Render on completion so results (and
    -- diffs) are available.
    if obj.subtype == "completed" then
      ledger.mark(L, "first_tool_call")
      local name, payload = diff.parse_tool(obj)
      if name == "shellToolCall" then
        p.shell_steps_total = (p.shell_steps_total or 0) + 1
        local res = payload and payload.result
        local failed = true
        local exit_code
        if type(res) == "table" then
          if type(res.failure) == "table" then
            exit_code = res.failure.exitCode
          elseif type(res.success) == "table" then
            exit_code = res.success.exitCode
            failed = type(exit_code) ~= "number" or exit_code ~= 0
          else
            failed = true
          end
        end
        if failed then
          p.shell_steps_failed = (p.shell_steps_failed or 0) + 1
          if p.first_failed_shell_exit == nil then
            p.first_failed_shell_exit = exit_code
            local args = payload and payload.args
            if type(args) == "table" then
              p.first_failed_shell_command = args.command
            end
          end
        end
      end
      if name then
        local change = diff.change_from_payload(name, payload)
        if change then
          ledger.bump(L, "changes_parsed")
          change.turn_gen = gen
          require("yana.turn_lifecycle").note_declared(p.turn_pass, change.rel)
        end
        -- The overlay's typed change set is the ONLY review producer. The
        -- the agent's report is never authoritative evidence, so a tool_call event is
        -- rendered as a note and nothing more: it never becomes a change
        -- record and never reaches any writer. The legacy report-derived
        -- the legacy in-place writer that used to sit here is deleted;
        -- Wall 0), and with it the last real-tree writer outside the journaled
        -- applier. Its control-plane matcher guard went with it: it existed
        -- only to fence that writer, and the writer no longer exists. The
        -- control-plane refusals that carry evidence are the overlay's, at
        -- record_control_plane_refusals, and the scope-revert guard above.
        render_tool_note(p, name, payload)
      end
    end
  elseif obj.type == "result" then
    ledger.mark(L, "result_received")
    -- §2.7 usage retention: the numbers the panel renders once and forgets
    -- become a per-turn record, so "the agent got slower this week" and
    -- runaway-cost triage are queryable rather than anecdotal.
    ledger.set_usage(L, obj)
    p.got_result = true
    p.session_id = obj.session_id or p.session_id
    finish_assistant_block(p, obj)
    if obj.is_error then
      render_error(p, type(obj.result) == "string" and obj.result or "agent reported an error")
      p.turn_errored = true
    end
  elseif obj.type == "error" then
    render_error(p, obj.message or obj.error or "agent error")
    p.turn_errored = true
  end
  ledger.set_current_event(L, nil)
end

-- Provenance record 3 has to name the generation as well as the event seq. A
-- stopped turn's late disk-bearing edit still renders into the panel, and the
-- render helpers below `on_event_body` resolve their ledger through
-- `turn_ledger(p)`, which without this pin reads `p.turn_gen` — the turn that
-- has since started. Pinning `gen` for the whole callback keeps the event and
-- the output it produced in the SAME ledger.
local function on_event(p, gen, obj)
  with_render_gen(p, gen, on_event_body, p, gen, obj)
end

-- Drain one queued prompt if the panel is idle, open, and not held for
-- queue.pause_on_error. Shared by on_done (turn just finished) and
-- open_windows (panel reopened after a turn finished while it was closed —
-- see on_done's panel_open guard below, which leaves the queue untouched in
-- that case).
function maybe_drain_queue(p)
  if p.busy or p.job ~= nil or p.awaiting_exit or #p.queue == 0 or not panel_open(p) then
    return
  end
  if config.options.queue.pause_on_error and p.turn_errored then
    notify_one_line(
      string.format(
        "yana: turn errored — %d queued prompt(s) held; send with %s",
        #p.queue,
        config.options.keymaps.queue or "the queue picker"
      ),
      vim.log.levels.WARN
    )
    return
  end
  local next_prompt = table.remove(p.queue, 1)
  update_winbar(p)
  submit_panel(p, { text = next_prompt })
end

-- Consume the captured per-job overlay once. Generation-independent: a
-- cancelled turn bumps turn_gen so on_done no-ops, but the edits are still
-- in the private layer and must become a review. Idempotent so on_exit and
-- the spawn-failure on_done path can both call it.
-- Durable, session-surviving record of a turn's control-plane refusals.
--
-- Repository-internal paths (.git/.hg/.svn) the turn wrote are forced to the
-- non-content `control-plane` kind by ops.typed_ops: kept in the typed set,
-- never offered for review, discarded with the overlay. BOTH shadow modes
-- disclose the count transiently -- preview through the typed-op report lines,
-- apply through a panel note -- but that disclosure vanishes with the session.
-- The measured gap: a default-mode (preview) lab run ingested a 20-file .git
-- flood and yana.log grew by ZERO bytes, so CORE's "walked, counted, and
-- reported / nothing is silent" was true on screen and false on disk.
--
-- Both finalize paths call this ONE helper with their turn's typed set, so the
-- apply and preview lines are identical rather than two drifting copies. WARN
-- because log.lua persists only WARN/ERROR (INFO/DEBUG never reach disk), so a
-- durable record has to be a WARN. Emitted once per turn (finalize_shadow_turn
-- _body runs once, guarded by turn._review_finalized). Returns the count so a
-- caller that also renders it transiently reads the same number.
-- Both finalize paths call ops.record_control_plane_refusals with their turn's
-- typed set. Overlay ingestion (lab stub argv, CLI apply) records through the
-- same helper with an explicit recorder label — never from changes_from_session.
local function record_control_plane_refusals(turn, p, typed)
  return shadow_ops.record_control_plane_refusals(shadow_ops.control_plane_warn_scope({
    workspace = turn and turn.workspace,
    stream = turn and turn.stream,
    turn_id = turn and (tonumber(turn.turn_id) or (p and p.turn_gen)),
  }, {
    panel_id = p and p.id,
  }), typed)
end

local function finalize_shadow_turn_body(p, turn)
  if turn._review_finalized then
    return
  end
  turn._review_finalized = true
  p.shadow_turn = turn
  if not config.overlay_mode() then
    local preview = require("yana.shadow.preview")
    -- The agent wrote into the overlay's private upper layer. That layer IS the
    -- change set; nothing is folded anywhere first, and nothing is copied.
    -- On success the second return is the report table ({ ops = typed set,
    -- lines = ... }); on failure it is the error string. Named `report` and
    -- read only in the branch where it is the report.
    local rendered, report = preview.render_report(p, turn)
    if not rendered then
      render_error(p, report or "reading the change set failed")
      p.turn_errored = true
      retain_shadow_turn(p, report or "reading the change set failed")
    else
      -- Same durable control-plane record as the apply branch: the report's
      -- typed set carries the control-plane ops the render_report lines disclose
      -- only transiently. This is the path the measured default-mode gap ran on.
      record_control_plane_refusals(turn, p, report and report.ops)
      -- Preview mode reports and stops: the review is closed the moment the
      -- report is rendered, so the claim goes back now.
      release_shadow_turn(p, "preview report rendered")
    end
  elseif config.review_mode_active() then
    local ops = require("yana.shadow.ops")
    local apply = require("yana.shadow.apply")
    -- The third return is the FULL typed set, including the operations the
    -- review surface cannot represent. It is not decoration: without it, a turn
    -- whose only work was a chmod, a symlink or a directory reaches the `else`
    -- below and is released as "produced no changes", which is a lie about the
    -- private layer and drops the claim on files the agent really did touch.
    local changes, cerr, typed = ops.changes_from_session(turn)
    ledger.mark(turn_ledger(p, tonumber(turn.turn_id) or p.turn_gen), "change_set_read")
    -- Durable control-plane record (same helper the preview branch calls).
    -- Counted HERE, before the display branches, so a turn whose ONLY operations
    -- are control-plane -- which lands in the `typed and #typed > 0` branch
    -- below, where the transient panel note is never even reached -- is recorded
    -- too, not just the mixed ordinary-plus-control-plane turn. The returned
    -- count is reused by the transient panel note so both agree.
    local cp_count = record_control_plane_refusals(turn, p, typed)
    -- PUBLICATION. The walk is done and every typed operation carries its class,
    -- so this is the moment the turn's bundle becomes authoritative and the
    -- review stops being provisional. Nothing before this line may act, and the
    -- classification -- not the stream's label -- is what the bundle carries, so
    -- a `.git/config` the stream declared an ordinary edit is unactionable here
    -- even though it was displayed earlier.
    if p.turn_pass then
      local lifecycle = require("yana.turn_lifecycle")
      local classified = ops.classified_bundle_entries(typed)
      local bundle, berr = lifecycle.publish_bundle(p.turn_pass, classified)
      if not bundle then
        -- An unpublishable bundle leaves the review provisional rather than
        -- quietly actionable: refusing to act is the safe half of this claim.
        log.write(log.levels.WARN, "yana: bundle publication failed: " .. tostring(berr))
      end
    end
    if not changes then
      render_error(p, cerr or "reading the change set failed")
      p.turn_errored = true
      -- The turn's evidence is unreadable, so whether a review is owed is
      -- unknown. The module's rule is never to guess dead: keep the claim and
      -- the private state, and make the operator's way out explicit.
      retain_shadow_turn(p, cerr or "reading the change set failed")
    elseif #changes > 0 then
      local unreviewable = ops.unreviewable_ops(typed)
      if #unreviewable > 0 then
        local named = {}
        for _, op in ipairs(unreviewable) do
          named[#named + 1] = string.format(
            "%s %s%s",
            op.kind,
            op.rel,
            op.detail and (" (" .. op.detail .. ")") or ""
          )
        end
        local msg = "the turn produced reviewable changes and "
          .. tostring(#unreviewable)
          .. " typed operation(s) the inline review cannot represent together: "
          .. table.concat(named, ", ")
        render_error(p, msg)
        p.turn_errored = true
        retain_shadow_turn(p, msg)
      else
      local pass, perr = apply.begin_pass(turn, changes)
      if not pass then
        render_error(p, perr or "shadow apply pass failed")
        retain_shadow_turn(p, perr or "shadow apply pass failed")
      else
        -- Review is now OPEN. The agent process has exited, but the claim
        -- stays held until the review closes — see on_close below.
        local turn_gen = tonumber(turn.turn_id) or p.turn_gen
        ledger.mark(turn_ledger(p, turn_gen), "apply_pass_began")
        p.shadow_pass = pass
        p.changes = p.changes or {}
        for _, change in ipairs(changes) do
          -- The overlay-derived changes carry no generation of their own, and
          -- every later record about them (hunk model, render check, decision)
          -- correlates through it. The turn id IS the generation.
          change.turn_gen = change.turn_gen or turn_gen
          -- …and the bundle digest it was published under, so a decision can be
          -- checked against the bundle it was actually offered from rather than
          -- against whatever bundle is current when the decision arrives.
          change.bundle_digest = p.turn_pass
            and p.turn_pass.bundle
            and p.turn_pass.bundle.bundle_digest
            or nil
          change.panel_id = change.panel_id or p.id
          ledger.bump(turn_ledger(p, turn_gen), "changes_parsed")
          table.insert(p.changes, change)
          render_tool_change(p, change)
        end
        -- CORE requires control-plane writes to be walked, COUNTED and REPORTED
        -- ("the turn wrote N control-plane files — discarded with the overlay"),
        -- not silent. `cp_count` is the count the durable helper returned above,
        -- so this transient panel note and the durable WARN agree on the number.
        -- When a turn has ordinary changes AND control-plane records, this branch
        -- previously reported only the ordinary ones.
        if cp_count > 0 then
          render_note(p, string.format(
            "⚠ %d control-plane file(s) the turn wrote were recorded and discarded with the overlay (never offered for review)",
            cp_count
          ))
        end
      end
      end
    elseif typed and #typed > 0 then
      -- Typed operations exist and none of them is reviewable. Name them and
      -- keep the turn: the agent's work is real, it is still in the private
      -- layer, and no route here can apply it.
      local named = {}
      for _, op in ipairs(typed) do
        named[#named + 1] = string.format("%s %s%s", op.kind, op.rel, op.detail and (" (" .. op.detail .. ")") or "")
      end
      local msg = "the turn produced "
        .. tostring(#typed)
        .. " typed operation(s) the inline review cannot represent, so nothing was applied: "
        .. table.concat(named, ", ")
      render_error(p, msg)
      p.turn_errored = true
      retain_shadow_turn(p, msg)
    else
      release_shadow_turn(p, "turn produced no changes")
    end
  else
    -- `ask` (ruling R-3, the mode contract section 2): the turn ran confined
    -- exactly as `inline` does -- overlay_mode() is true for it -- but it
    -- proposes nothing, so no review can open and no change is ever offered.
    --
    -- This branch exists because "overlay ⇒ a review will consume it" stopped
    -- being true the moment confinement stopped implying review. Without it the
    -- turn falls off the end of the chain holding the workspace claim, the
    -- private layer and an unresolved lifecycle pass -- the leak that blocks the
    -- operator's own workspace. `release_shadow_turn` resolves all three.
    --
    -- The layer is read before it is discarded rather than dropped blind: an
    -- `ask` turn that WROTE is exactly the hostile case confinement exists for,
    -- and discarding it in silence would be a fresh instance of the Wall 3
    -- defect. Nothing here is offered, applied, or actionable.
    local ops = require("yana.shadow.ops")
    local ok_read, a, b, typed = pcall(ops.changes_from_session, turn)
    local turn_gen = tonumber(turn.turn_id) or p.turn_gen
    if ok_read and typed then
      record_control_plane_refusals(turn, p, typed)
      if #typed > 0 then
        log.write(
          log.levels.WARN,
          string.format(
            "yana: ask turn %s wrote %d path(s) into the private layer -- discarded with the overlay, never offered for review",
            tostring(turn_gen),
            #typed
          )
        )
        render_note(p, string.format(
          "⚠ this ask turn wrote %d path(s); they were confined to the private layer and discarded",
          #typed
        ))
      end
    else
      -- A throw or a returned failure is a halt. CORE requires it be recorded
      -- on the object being resolved; discarding the layer in silence is Wall 3
      -- again. Release still follows: an ask turn owes no review, so holding
      -- the claim would lock the workspace with nothing to unlock.
      local why = ok_read and tostring(b or "reading the change set failed") or tostring(a)
      log.write(
        "WARN",
        string.format(
          "yana: ask turn %s layer could not be read (%s) -- discarded with the overlay, never offered for review",
          tostring(turn_gen),
          why
        )
      )
      render_note(p, string.format(
        "⚠ this ask turn's private layer could not be read (%s); it was discarded",
        why
      ))
    end
    -- Released unconditionally: an unreadable layer is not a reason to keep a
    -- claim on a turn that can owe no review.
    release_shadow_turn(p, "ask turn — nothing is proposed, nothing to review")
  end
end

-- Same provenance pin as `on_event`: the overlay-derived review renders for
-- the turn whose id the overlay carries, which is NOT necessarily the panel's
-- current generation (a stopped turn is finalized after the next one has
-- started). The turn id IS the generation, so every note, change block and
-- error rendered under it is recorded in that turn's ledger.
finalize_shadow_turn = function(p, turn)
  if not p or not turn then
    return
  end
  with_render_gen(p, tonumber(turn.turn_id) or p.turn_gen, finalize_shadow_turn_body, p, turn)
end

local function on_done(p, gen, code, stderr)
  if gen ~= p.turn_gen then
    return
  end
  local L = ledger.ensure(p.id, gen)
  ledger.set_current_event(L, nil)
  p.busy = false
  local turn = p.job_shadow_turn or p.shadow_turn
  if turn and tostring(turn.turn_id) == tostring(gen) then
    finalize_shadow_turn(p, turn)
  end
  -- Idempotent; normally a no-op because on_exit_confirmed already flushed
  -- (agent.lua fires it first). This call exists for the spawn-failure path,
  -- which calls on_done(-1) synchronously and never produces an exit at all.
  flush_review_batch(p)
  local cancelled = p.cancelled
  p.cancelled = false
  -- jobstop() → exit 143 (SIGTERM). Intentional cancel already noted in the panel.
  local job_failed = (code ~= 0)
  if job_failed and not p.got_result and not cancelled then
    local msg = stderr ~= "" and stderr or ("cursor-agent exited with code " .. tostring(code))
    render_error(p, msg)
    p.turn_errored = true
  end
  -- p.job / awaiting_exit / job_spawn_gen: owned by on_exit_confirmed only
  -- (agent.lua fires that first). Never clear them here — a live turn's
  -- drain/redirect may already own a newer job by the time a stale on_done
  -- would have run, and even the live-path clear races that contract.
  p.active_turn_scope = nil
  stop_spinner(p)
  update_winbar(p)
  persist_session(p)

  -- Terminal state of the turn. Written here rather than at exit because this
  -- is the callback that knows the exit code and the stderr; the ledger merges
  -- rather than replaces, so the spawn-failure path (which reaches on_done
  -- without any exit at all) records the same shape.
  do
    local turn_changes, turn_pending = 0, 0
    for _, c in ipairs(p.changes or {}) do
      if c.turn_gen == gen then
        turn_changes = turn_changes + 1
        if c.status == "pending" then
          turn_pending = turn_pending + 1
        end
      end
    end
    ledger.close_turn(L, {
      exit_code = code,
      stderr_len = stderr and #stderr or 0,
      got_result = p.got_result and true or false,
      turn_errored = p.turn_errored and true or false,
      cancelled = cancelled and true or false,
      changes = turn_changes,
      changes_pending = turn_pending,
      queued = #p.queue,
      session_id = p.session_id,
      shell_steps_total = p.shell_steps_total or 0,
      shell_steps_failed = p.shell_steps_failed or 0,
    })
    if (p.shell_steps_failed or 0) > 0 then
      require("yana.log").write(
        require("yana.log").levels.WARN,
        string.format(
          "yana: turn finished with %d failed shell command(s) (first exit %s: %s)",
          p.shell_steps_failed,
          tostring(p.first_failed_shell_exit),
          tostring(p.first_failed_shell_command or "?")
        )
      )
      update_winbar(p)
    end
  end

  -- Drain one queued follow-up (queued via submit_panel while p.busy was
  -- true). Advice for a completed ask-no-edit turn must be decided BEFORE
  -- draining — drain submits the next prompt and overwrites p.last_question.
  local resolved_mode = p.turn_modes and p.turn_modes[gen]
  if resolved_mode == "ask" and not cancelled and not p.turn_errored then
    local turn_edits = 0
    for _, c in ipairs(p.changes or {}) do
      if c.turn_gen == gen then
        turn_edits = turn_edits + 1
      end
    end
    if turn_edits == 0 and #p.queue == 0 then
      local completed_question = p.turn_questions and p.turn_questions[gen]
      if completed_question and completed_question ~= "" then
        p.ask_advice_resend = completed_question
      end
      local k = config.options.keymaps
      local resend_hint
      if k.resend and k.resend ~= "" then
        resend_hint = k.resend .. "a"
      else
        resend_hint = ":YanaResend agent"
      end
      append(p, {
        "",
        "_Ask mode cannot apply edits, and this chat's mode is locked. Press "
          .. resend_hint
          .. " to resend this prompt in a new agent chat._",
        "",
      })
    end
  end

  maybe_drain_queue(p)

  -- A turn that never established an upstream session must not consume lock
  -- authority (spawn failure, early agent exit before init).
  if job_failed and not cancelled and not mode_locked(p) and p.turns > 0 then
    p.turns = p.turns - 1
  end
end

-- Gen-independent: fires for EVERY job death (stale or live) — the only
-- callback allowed to clear process bookkeeping. Correlated to the job via
-- its spawn gen so a late old exit can never clear a newer job (I2).
local function on_exit_confirmed(p, gen, _code)
  if p.job_spawn_gen ~= gen then
    return -- a newer job owns the panel; this is a late old exit
  end
  do
    local L = ledger.ensure(p.id, gen)
    ledger.mark(L, "exit_confirmed")
    ledger.set_current_event(L, nil)
  end
  -- Overlay consume first, then the report-batch flush. This is the only
  -- callback that fires for EVERY job death: a cancelled turn bumps turn_gen,
  -- so its on_done early-returns at the generation gate and would strand the
  -- overlay (and the old report batch) forever — unreviewed and unrevertable.
  -- It also must precede both the pending_redirect submit and the
  -- was_awaiting drain below, or a new turn starts owning the old turn's
  -- batch. Every emitted event is already scheduled ahead of this callback
  -- (agent.lua schedules per stdout line, exit last), so the overlay is
  -- complete by now.
  local captured = p.job_shadow_turn
  if captured and tostring(captured.turn_id) == tostring(gen) then
    finalize_shadow_turn(p, captured)
  elseif p.shadow_turn and tostring(p.shadow_turn.turn_id) == tostring(gen) then
    finalize_shadow_turn(p, p.shadow_turn)
  end
  flush_review_batch(p)
  p.job = nil
  p.job_spawn_gen = nil
  p.job_shadow_turn = nil
  local was_awaiting = p.awaiting_exit
  p.awaiting_exit = false
  local text = p.pending_redirect
  p.pending_redirect = nil
  update_winbar(p)
  local held = p.shadow_turn ~= nil
  if text then
    if held or not panel_open(p) then
      -- Held: prior turn is finalized but not released (review open). Do not
      -- start a new jailed turn on top of it. Closed panel: same as before.
      table.insert(p.queue, 1, text)
    else
      submit_panel(p, { text = text, redirect = true })
    end
  elseif was_awaiting and not held then
    -- Prompts submitted while the exit was pending queued up; fire them now.
    maybe_drain_queue(p)
  end
end

----------------------------------------------------------------------
-- submit
----------------------------------------------------------------------

-- opts.text: submit this text directly instead of reading p.prompt_buf (used
-- to drain a queued follow-up). Omit to submit whatever is in the prompt
-- buffer.
submit_panel = function(p, opts)
  if not panel_open(p) then
    return
  end
  opts = opts or {}

  local question
  if opts.text then
    question = vim.trim(opts.text)
  else
    -- Spawn barrier (I1): a single process per panel, ever. p.job ~= nil or
    -- p.awaiting_exit means either a live turn or a cancelled one whose exit
    -- hasn't been observed yet — either way, queue instead of spawning.
    if p.busy or p.job ~= nil or p.awaiting_exit then
      local lines = vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false)
      local queued_text = vim.trim(table.concat(lines, "\n"))
      if queued_text == "" then
        notify_one_line("yana: still responding (use stop to cancel)", vim.log.levels.WARN)
        return
      end
      table.insert(p.queue, queued_text)
      vim.bo[p.prompt_buf].modifiable = true
      vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })
      update_winbar(p)
      notify_one_line(
        string.format("yana: queued (%d pending) — sends when the current turn finishes", #p.queue),
        vim.log.levels.INFO
      )
      return
    end

    local lines = vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false)
    question = vim.trim(table.concat(lines, "\n"))
    if question == "" then
      return
    end

    -- CLI-parity input surface: if the FIRST line starts with a known
    -- /command, dispatch its callback instead of sending. Two legal
    -- outcomes (commands.lua's contract): cb(nil) means "handled locally,
    -- nothing to send"; cb(text) rewrites the outgoing prompt. An unknown
    -- /foo is not a command match at all, so it falls straight through and
    -- is sent verbatim below — never swallowed, never an error.
    local first_line = vim.split(question, "\n", { plain = true })[1] or ""
    local cmd_name, cmd_args = first_line:match("^/(%S+)%s*(.*)$")
    local dispatch = cmd_name and require("yana.commands").find(p, cmd_name) or nil

    if dispatch then
      -- Everything the user typed that is NOT the `/name` token: line 1's
      -- remainder AND lines 2..n. Taken by byte offset off `question` rather
      -- than reassembled from cmd_args, so there is exactly one definition of
      -- "the user's text" and no way for the two halves to drift.
      local user_text = vim.trim(question:sub(#("/" .. cmd_name) + 1))
      local got_result, result = false, nil
      -- `args` stays the LINE-1 remainder, not user_text: it is the command's
      -- argument string (commands.lua's contract), and a builtin that ever
      -- parses it (e.g. a future `/model sonnet`) wants a single line, not the
      -- whole multi-line prompt. Composition below uses the wider user_text.
      local ok, err = xpcall(function()
        return dispatch.callback(p, cmd_args, function(text)
          got_result = true
          result = text
        end)
      end, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
      end)
      if not ok then
        -- Throwing callback: log (with traceback, mirroring log.guard) + WARN,
        -- leave the prompt buffer untouched so the user's typed text is never
        -- lost.
        log.write("ERROR", "yana.commands: /" .. cmd_name .. " threw: " .. tostring(err))
        notify_one_line("yana: /" .. cmd_name .. " failed: " .. tostring(err), vim.log.levels.WARN)
        return
      end
      if not got_result then
        log.write("WARN", "yana.commands: /" .. cmd_name .. " never called cb()")
        return
      end
      if result == nil then
        -- Local command: handled, nothing to send. Clear the prompt now.
        vim.bo[p.prompt_buf].modifiable = true
        vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })
        return
      end
      -- Rewrite kind: the body is an instruction PREAMBLE and the user's text
      -- is the task it applies to, so body first, user text second — the shape
      -- the Cursor and Claude CLIs use for the same feature. Replacing the
      -- whole prompt with `result` (what this did) silently discarded the
      -- task itself. Composed here, not in each callback: there are two
      -- rewrite call sites today and both are generated per disk file, so
      -- per-callback composition would drift.
      question = user_text == "" and result or (result .. "\n\n" .. user_text)
    end

    -- Clear the prompt input.
    vim.bo[p.prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })
  end

  if question == "" then
    return
  end

  do
    local extracted = require("yana.mentions").extract_mentions(question)
    question = extracted.new_content
    p.pending_enable_diagnostics = extracted.enable_diagnostics
  end


  -- opts.text arrives from drain/redirect call sites that already believed
  -- the barrier was clear; re-check defensively (I1) — a race there must
  -- never spawn a second process alongside a live one. Head insert keeps
  -- FIFO order for a drained/redirect item that gets bounced back.
  if opts.text and (p.busy or p.job ~= nil or p.awaiting_exit) then
    table.insert(p.queue, 1, question)
    return
  end

  if p.shadow_turn then
    if not p.shadow_turn._review_finalized then
      finalize_shadow_turn(p, p.shadow_turn)
    end
    if p.shadow_turn then
      table.insert(p.queue, 1, question)
      notify_one_line(
        "yana: review still open — queued until it closes",
        vim.log.levels.INFO
      )
      update_winbar(p)
      return
    end
  end

  last_panel = p

  local exclude = {}
  for _, q in ipairs(panels) do
    if q.conv_buf then exclude[q.conv_buf] = true end
    if q.prompt_buf then exclude[q.prompt_buf] = true end
  end
  local origin = context.current_origin(exclude)
  local selection = p.pending_selection
  p.pending_selection = nil
  p.scope_rejections = {}
  p.review_rejections = {}

  if selection and selection.buf and vim.api.nvim_buf_is_valid(selection.buf) then
    vim.api.nvim_buf_call(selection.buf, function()
      if vim.bo.modified then
        -- Flush so agent (reads disk) sees current content. Failed :write
        -- (E13 file-now-on-disk, read-only, changed-on-disk, …) must NOT
        -- abort the ask with a transient red E5108 — warn and continue.
        -- Never force write! here: E13 repair belongs in inline_diff rename
        -- guard; a blind write! can clobber external disk edits.
        local ok, err = pcall(vim.cmd, "write")
        if not ok then
          local why = tostring(err):match("(E%d+:[^\n]*)") or tostring(err)
          notify_one_line(
            "yana: could not save buffer before asking; agent will see stale on-disk content ("
              .. why
              .. ")",
            vim.log.levels.WARN
          )
        end
      end
    end)
    selection.scope = selection_scope.compute(selection.buf, selection)
    p.active_turn_scope = selection.scope
  else
    p.active_turn_scope = nil
  end

  local enable_diagnostics = p.pending_enable_diagnostics
  p.pending_enable_diagnostics = nil
  local built = context.build(
    question,
    origin,
    selection,
    { mode = config.panel_mode(p.mode), enable_diagnostics = enable_diagnostics }
  )

  if opts.redirect then
    local marker = config.options.redirect.marker
    if marker and marker ~= "" then
      built.prompt = marker .. "\n\n" .. built.prompt
    end
    render_note(p, "redirect — previous turn interrupted")
  end

  -- CONTEXT CARRY (Stage 0). The mode switch ended the upstream session, so the
  -- new one starts with no history at all. Without this the chat would appear
  -- to continue on screen while the agent had silently forgotten everything --
  -- worse than refusing the switch, because the operator cannot see the loss.
  -- Consumed once: a brief replayed on every later turn would drift out of date
  -- and start contradicting the live conversation.
  if p.pending_brief and p.pending_brief ~= "" then
    built.prompt = "[Context carried from the earlier part of this conversation, which ran in a different mode]\n"
      .. p.pending_brief
      .. "\n\n"
      .. built.prompt
    p.pending_brief = nil
  end

  p.last_question = question
  if not p.title then
    p.title = sessions.title_from_prompt(question)
  end

  render_user(p, question, built.label)
  start_assistant_block(p)

  p.busy = true
  p.cancelled = false
  p.got_result = false
  p.turn_errored = false
  p.shell_steps_total = 0
  p.shell_steps_failed = 0
  p.first_failed_shell_exit = nil
  p.first_failed_shell_command = nil
  p.turns = p.turns + 1
  p.cwd = vim.fn.getcwd()
  p.turn_gen = p.turn_gen + 1
  local gen = p.turn_gen
  -- Open the turn's ledger here, before anything else can happen to it: the
  -- submit stamp is the zero every later phase is measured from, and a turn
  -- that dies in confinement still has a record with a beginning.
  local L = ledger.begin_turn(p.id, gen, {
    panel_id = p.id,
    session_id = p.session_id,
    mode = config.panel_mode(p.mode),
    model = p.model,
    cwd = p.cwd,
    redirect = opts.redirect and true or false,
    queued = #p.queue,
    prompt_bytes = #question,
    title = p.title,
  })
  p.turn_scopes[gen] = (selection and selection.scope) or false
  p.turn_modes[gen] = config.panel_mode(p.mode)
  p.turn_questions[gen] = question
  start_spinner(p)
  update_winbar(p)

  -- Assign BEFORE the run call so a fast exit can correlate (I2): a job that
  -- dies before agent.run() even returns must still match on_exit_confirmed.
  p.job_spawn_gen = gen
  p.shadow_pass = nil
  p.job_shadow_turn = nil
  if config.overlay_mode() then
    local preview = require("yana.shadow.preview")
    local turn, perr = preview.begin_turn({
      workspace = preview.workspace_for_turn({
        cwd = p.cwd,
        selection = selection,
        origin = origin,
      }),
      stream = p.session_id or ("panel-" .. tostring(p.conv_buf)),
      turn_id = gen,
    })
    if not turn then
      p.busy = false
      stop_spinner(p)
      ledger.close_turn(L, { exit_code = nil, confinement_failed = perr or "shadow turn failed" })
      render_error(p, perr or "shadow turn failed")
      update_winbar(p)
      return
    end
    ledger.mark(L, "confinement_established")
    L.turn.workspace = turn.workspace
    L.turn.turn_dir = turn.turn_dir
    p.shadow_turn = turn
    p.job_shadow_turn = turn
  end
  -- Open the turn's lifecycle pass. From here the turn has a DURABLE id and an
  -- owning tuple, and it is explicitly NOT actionable: nothing has been walked
  -- or classified yet, so a review rendered from the stream's declared edits is
  -- provisional by construction (the fixed safety contract, async principle).
  p.turn_pass = require("yana.turn_lifecycle").begin_turn({
    panel_id = p.id,
    generation = gen,
    stream = p.session_id or ("panel-" .. tostring(p.conv_buf)),
    workspace = p.shadow_turn and p.shadow_turn.workspace or p.cwd,
    claim_dir = p.shadow_turn and p.shadow_turn.claim_dir or nil,
    tracked_preturn = require("yana.turn_lifecycle").capture_tracked(p.cwd),
  })
  p.job = agent.run({
    prompt = built.prompt,
    mode = config.panel_mode(p.mode),
    model = p.model,
    session_id = p.session_id,
    cwd = p.cwd,
    jail_session = p.shadow_turn,
    panel_id = p.id,
    turn_gen = gen,
    spawn_reason = opts.redirect and "redirect" or (opts.text and "queue_drain" or "submit"),
    on_event = function(obj)
      on_event(p, gen, obj)
    end,
    on_done = function(code, stderr)
      on_done(p, gen, code, stderr)
    end,
    on_exit_confirmed = function(code)
      on_exit_confirmed(p, gen, code)
    end,
  })
  if not p.job then
    p.job_spawn_gen = nil
    -- The overlay never ran, so it never took a claim; nothing to release.
    if p.shadow_turn then
      preview_module().discard(p.shadow_turn)
      p.shadow_turn = nil
    end
  elseif p.shadow_turn then
    -- Make "a review is open for this workspace" durable while the agent is
    -- still alive, so an editor crash leaves a claim that is recoverable
    -- rather than one that looks abandoned.
    preview_module().arm_review_open(p.shadow_turn, function()
      ledger.mark(L, "review_claim_open")
    end)
  end
end

function M.submit()
  local p = current_panel()
  if p then
    submit_panel(p)
  end
end

-- Write queued prompts back into the prompt buffer (Claude Code / Codex CLI
-- Up-arrow semantics): first item as the buffer text, further items joined
-- by a blank line, cursor at the start. Overwrites whatever is currently in
-- the prompt buffer — at cancel time that's either empty or an unsent draft,
-- and returning the queue here takes priority (see cancel_inflight below).
local function requeue_to_prompt(p, items)
  if not buf_valid(p.prompt_buf) or #items == 0 then
    return
  end
  local lines = {}
  for i, item in ipairs(items) do
    if i > 1 then
      table.insert(lines, "")
    end
    vim.list_extend(lines, vim.split(item, "\n", { plain = true }))
  end
  vim.bo[p.prompt_buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, lines)
  if win_valid(p.prompt_win) then
    pcall(vim.api.nvim_win_set_cursor, p.prompt_win, { 1, 0 })
  end
end

-- SIGTERM (jobstop) was only SENT; a mid-tool process can ignore it. Escalate
-- to SIGKILL after confirm_exit_timeout_ms; if it STILL won't die after
-- kill_grace_ms, abort any pending redirect (text back to the prompt buffer)
-- and keep the spawn barrier up — never start a second process alongside a
-- live one (I1). Timers self-cancel via the job_spawn_gen token instead of
-- handles: once the exit is observed (or a new job spawned) they no-op.
local function schedule_exit_escalation(p, gen)
  local o = config.options.redirect
  vim.defer_fn(function()
    log.guard("yana.ui exit escalation (kill)", function()
      if p.job_spawn_gen ~= gen or not p.awaiting_exit or p.job == nil then return end
      agent.kill(p.job)
      vim.defer_fn(function()
        log.guard("yana.ui exit escalation (abort redirect)", function()
          if p.job_spawn_gen ~= gen or not p.awaiting_exit or p.job == nil then return end
          local text = p.pending_redirect
          p.pending_redirect = nil
          if text and text ~= "" then
            requeue_to_prompt(p, { text })
          end
          update_winbar(p)
          notify_one_line(
            "yana: previous cursor-agent process won't exit — redirect aborted; waiting for it to die",
            vim.log.levels.ERROR
          )
        end)
      end, o.kill_grace_ms)
    end)
  end, o.confirm_exit_timeout_ms)
end

-- Fold an armed pending_redirect (if any) and the queue (if any) back into
-- the prompt buffer — redirect text FIRST, ahead of the queue — and clear
-- both. Shared by cancel_inflight's main cancel path and its awaiting_exit
-- disarm branch below, so a plain stop behaves identically whether it
-- catches a still-live job or one already mid-wait for its confirmed exit.
-- Returns true if anything was actually folded (queue+redirect both empty
-- is a no-op: nothing to notify about).
local function fold_pending_to_prompt(p)
  local items = {}
  if p.pending_redirect then
    table.insert(items, p.pending_redirect)
    p.pending_redirect = nil
  end
  if #p.queue > 0 then
    vim.list_extend(items, p.queue)
    p.queue = {}
  end
  if #items == 0 then
    return false
  end
  requeue_to_prompt(p, items)
  update_winbar(p)
  notify_one_line(
    string.format("yana: stopped — %d queued prompt(s) returned to input", #items),
    vim.log.levels.WARN
  )
  return true
end

-- Cancel in-flight job. Bump turn_gen so stale on_event/on_done no-op, and
-- clear busy immediately — stop cannot wait for on_done (gen mismatch).
-- opts.keep_queue: leave p.queue untouched (used by the interrupt-and-steer
-- keybind, which cancels only to immediately resubmit — the pre-existing
-- queue is not part of that resubmit and must keep waiting its turn).
cancel_inflight = function(p, opts)
  if not p or not p.job then
    return false
  end
  opts = opts or {}
  if p.awaiting_exit then
    -- A previous cancel is already waiting for the confirmed exit — the
    -- spawn barrier and escalation timers are already up. This branch only
    -- DISARMS an armed redirect/queue (e.g. plain stop after steer, or
    -- new_chat while a redirect is still waiting to fire into a session
    -- that's about to be reset out from under it); it must NOT re-stop the
    -- process, re-bump turn_gen, or touch awaiting_exit/job — those stay
    -- exactly as the original cancel left them until the real exit lands.
    if not opts.keep_queue and (p.pending_redirect or #p.queue > 0) then
      fold_pending_to_prompt(p)
      return true
    end
    return false
  end
  p.cancelled = true
  p.turn_gen = p.turn_gen + 1
  agent.stop(p.job)
  -- p.job is deliberately NOT cleared here — jobstop() only SENDS SIGTERM;
  -- the spawn barrier (I1) must stay up until the exit is actually OBSERVED
  -- (on_exit_confirmed), never assumed. See schedule_exit_escalation for the
  -- SIGTERM -> SIGKILL -> abort escalation while we wait.
  p.awaiting_exit = true
  schedule_exit_escalation(p, p.job_spawn_gen)
  p.busy = false
  p.active_turn_scope = nil
  -- A deliberate cancel (stop / new_chat / scope-rejection cap) must not
  -- auto-fire queued follow-ups typed while the turn was running — the user
  -- interrupted on purpose. Unlike the old behavior, the queue is never
  -- dropped: it's handed back to the prompt buffer so the user decides what
  -- to do with it (matches new_chat's "fresh conversation, old queued text
  -- goes to input for the user to decide" case too — same code path).
  if not opts.keep_queue then
    fold_pending_to_prompt(p)
  end
  stop_spinner(p)
  update_winbar(p)
  return true
end

-- The stop entry point every NON-key surface routes through: the `/stop`
-- command, and <leader>aS ("AI: stop") via yana.stop(). Unlike the <C-c>
-- on_key hook this does NOT depend on last_focused_panel, so it works from the
-- user's own code buffer while a turn streams — current_panel() falls back to
-- last_panel. That makes it the ONLY stop that works outside the panel.
--
-- A no-op is reported rather than swallowed: silence here is indistinguishable
-- from a dead keybinding, which is exactly how a working stop key gets
-- reported as broken. cancel_inflight returns false when there is no panel or
-- no in-flight job (and, deliberately, when a previous cancel is already
-- awaiting the confirmed exit — that one is already stopping, so say so
-- rather than claiming there was nothing to stop).
function M.stop()
  local p = current_panel()
  if cancel_inflight(p) then
    render_note(p, "⏹ stopped")
    return
  end
  if p and p.awaiting_exit then
    notify_one_line("yana: already stopping — waiting for the agent to exit", vim.log.levels.INFO)
  else
    notify_one_line("yana: nothing to stop (no turn in flight)", vim.log.levels.INFO)
  end
end

-- Interrupt-and-steer: cancel the in-flight turn and resubmit the current
-- prompt-buffer text as a new turn once (and only once) the old process's
-- exit is CONFIRMED (--resume keeps the same session context, since cancel
-- never clears session_id) — see on_exit_confirmed, which is the only place
-- that actually spawns the redirect. Any pre-existing queue is left
-- untouched — it is unrelated to this resubmit and keeps waiting its turn.
-- No-op (notify only) if the prompt buffer is empty; if the panel is idle (no
-- in-flight job), this degrades to a normal submit so the key is never a
-- dead end.
function M.steer()
  local p = current_panel()
  if not p or not buf_valid(p.prompt_buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false)
  local text = vim.trim(table.concat(lines, "\n"))
  if text == "" then
    notify_one_line("yana: nothing to steer with — type a prompt first", vim.log.levels.WARN)
    return
  end

  local function take_prompt()
    vim.bo[p.prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })
  end

  if p.awaiting_exit then
    -- Second steer while the first cancel is still waiting: last-wins (I4).
    p.pending_redirect = text
    take_prompt()
    notify_one_line("yana: redirect updated — waiting for the previous process to exit", vim.log.levels.INFO)
    return
  end
  if p.job then
    p.pending_redirect = text
    take_prompt()
    if not p.session_id or p.session_id == "" then
      notify_one_line(
        "yana: steering before session init — the redirect starts a fresh session (previous context not resumable)",
        vim.log.levels.WARN
      )
    end
    if cancel_inflight(p, { keep_queue = true, reason = "redirect" }) then
      render_note(p, "⏹ interrupted to steer — waiting for the previous process to exit")
    end
    return
  end
  submit_panel(p) -- idle: plain submit, key is never a dead end
end

----------------------------------------------------------------------
-- resend
----------------------------------------------------------------------

-- Resubmit the last prompt without retyping it.
--
-- opts.where:
--   "here"  -- same chat, same session (--resume), same mode. A plain retry.
--   "new"   -- a NEW chat: fresh upstream session, this chat's mode carried over.
--   "agent" -- a NEW chat forced to agent mode. This is the ask -> "now actually
--              do it" path, and it MUST be a new chat: a chat's mode is locked
--              once it has run a turn, because cursor-agent inherits a resumed
--              session's mode and offers no `--mode agent` to undo it (see
--              mode_locked). A new chat is a new session, so agent is reachable
--              there and nothing inherits the ask turn.
--
-- The prompt is read BEFORE new_chat, which clears it along with the rest of
-- the conversation state.
function M.resend(opts)
  opts = opts or {}
  local where = opts.where or "here"
  local p = current_panel()
  if not p then
    return false
  end
  local question = p.last_question
  if where == "agent" and p.ask_advice_resend and p.ask_advice_resend ~= "" then
    question = p.ask_advice_resend
  end
  if not question or question == "" then
    notify_one_line("yana: nothing to resend — submit a prompt first", vim.log.levels.WARN)
    return false
  end
  if p.busy or p.job ~= nil or p.awaiting_exit then
    notify_one_line("yana: still responding — use steer to redirect, or stop first", vim.log.levels.WARN)
    return false
  end

  if where == "here" then
    submit_panel(p, { text = question })
    return true
  end

  local carried = p.mode
  M.new_chat()
  p = current_panel() or p
  if where == "agent" then
    -- Unlocked by new_chat, so this cannot be refused; assert rather than hope.
    if not M.set_mode(p, "agent") then
      notify_one_line("yana: could not switch the new chat to agent mode", vim.log.levels.ERROR)
      return false
    end
  else
    M.set_mode(p, carried)
  end
  render_note(p, "resent in a new chat — " .. config.panel_mode(p.mode) .. " mode, fresh session")
  submit_panel(p, { text = question })
  if where == "agent" then
    p.ask_advice_resend = nil
  end
  return true
end

----------------------------------------------------------------------
-- queue: view / edit / delete / reorder queued follow-ups
----------------------------------------------------------------------

local function queue_preview(text)
  local first = vim.split(text, "\n", { plain = true })[1] or ""
  if #first > 60 then
    first = first:sub(1, 59) .. "…"
  end
  return first
end

-- Remove item `idx` from the queue and place it into the prompt buffer for
-- editing (Claude Code Up-arrow semantics). If the prompt buffer already
-- has unsent text, the item is prepended ahead of it (rather than
-- clobbering the draft) and the user is notified.
local function queue_edit(p, idx)
  local item = table.remove(p.queue, idx)
  if not item then
    return
  end
  update_winbar(p)
  if not buf_valid(p.prompt_buf) then
    return
  end
  local existing_lines = vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false)
  local existing = vim.trim(table.concat(existing_lines, "\n"))
  vim.bo[p.prompt_buf].modifiable = true
  if existing == "" then
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, vim.split(item, "\n", { plain = true }))
  else
    local combined = vim.split(item, "\n", { plain = true })
    table.insert(combined, "")
    vim.list_extend(combined, existing_lines)
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, combined)
    notify_one_line("yana: prepended queued prompt to existing input", vim.log.levels.INFO)
  end
  if win_valid(p.prompt_win) then
    pcall(vim.api.nvim_win_set_cursor, p.prompt_win, { 1, 0 })
  end
end

local function queue_delete(p, idx)
  local item = table.remove(p.queue, idx)
  if item then
    update_winbar(p)
    notify_one_line("yana: removed queued prompt", vim.log.levels.INFO)
  end
end

local function queue_send_next(p, idx)
  if idx < 1 or idx > #p.queue then
    return
  end
  local item = table.remove(p.queue, idx)
  table.insert(p.queue, 1, item)
  update_winbar(p)
  notify_one_line("yana: queued prompt moved to front", vim.log.levels.INFO)
end

-- :YanaQueue / <M-q>: view, edit, delete, or reorder queued follow-ups.
-- Two-step vim.ui.select, mirroring pick_pending's item-then-action shape.
function M.pick_queue()
  local p = current_panel()
  if not p or #p.queue == 0 then
    notify_one_line("yana: queue is empty", vim.log.levels.INFO)
    return
  end
  local items = {}
  for i, text in ipairs(p.queue) do
    items[#items + 1] = { idx = i, text = text }
  end
  vim.ui.select(items, {
    prompt = "yana: queued prompts",
    format_item = function(it)
      return string.format("%d. %s", it.idx, queue_preview(it.text))
    end,
  }, function(choice)
    if not choice then
      return
    end
    vim.ui.select({ "edit", "delete", "send next" }, {
      prompt = "yana: queue item " .. choice.idx .. " — " .. queue_preview(choice.text),
    }, function(action)
      if not action then
        return
      end
      -- The queue can change between the two selects (e.g. it finished
      -- draining); bail rather than acting on a now-wrong index.
      if p.queue[choice.idx] ~= choice.text then
        notify_one_line("yana: queue changed — pick again", vim.log.levels.WARN)
        return
      end
      if action == "edit" then
        queue_edit(p, choice.idx)
      elseif action == "delete" then
        queue_delete(p, choice.idx)
      elseif action == "send next" then
        queue_send_next(p, choice.idx)
      end
    end)
  end)
end

-- Read-only accessor for the panel <C-c> currently targets (nil if the user
-- last focused something outside yana). Exposed so tests/fixtures can
-- assert on tracked focus without reaching into module-local state.
function M.focused_panel()
  return last_focused_panel
end

----------------------------------------------------------------------
-- image / text paste (system clipboard -> prompt buffer)
----------------------------------------------------------------------

-- Insert `text` into `bufnr` at the cursor position in `winid`, splitting on
-- embedded newlines first. A naive single nvim_buf_set_lines() entry
-- containing "\n" throws "replacement string item contains newlines" (see
-- set_lines() above / tool_note_newline_smoke.lua for the prior incident
-- this codebase hit from the same mistake) — so the inserted text is always
-- split into real line entries and stitched onto the line the cursor is on.
-- The single deliberate interface widening this feature adds: mentions.lua
-- callbacks (@file, @buffers, @quickfix) need to insert text into the prompt
-- buffer without duplicating cursor/window handling, which is subtle. Do not
-- copy this function elsewhere — call M.insert_at_cursor.
function M.insert_at_cursor(bufnr, winid, text)
  if not buf_valid(bufnr) or type(text) ~= "string" or text == "" then
    return
  end
  local ok_pos, pos = pcall(vim.api.nvim_win_get_cursor, winid)
  if not ok_pos then
    return
  end
  local row, col = pos[1], pos[2]
  local cur_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local before = cur_line:sub(1, col)
  local after = cur_line:sub(col + 1)

  local pieces = vim.split(text, "\n", { plain = true })
  pieces[1] = before .. pieces[1]
  pieces[#pieces] = pieces[#pieces] .. after

  vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, pieces)

  local new_row = row - 1 + #pieces
  local new_col = math.max(#pieces[#pieces] - #after, 0)
  pcall(vim.api.nvim_win_set_cursor, winid, { new_row, new_col })
end
local insert_at_cursor = M.insert_at_cursor

-- Shared implementation for the prompt buffer's image_paste.key mapping and
-- the :YanaPasteImage command.
-- opts.force_image: only ever do the image branch (the command's contract);
-- clipboard text/none is reported as a WARN rather than falling back to a
-- normal text paste.
local function paste_into_panel(p, opts)
  opts = opts or {}
  if not p or not buf_valid(p.prompt_buf) or not win_valid(p.prompt_win) then
    return
  end

  local info = clipboard.detect()

  if info.kind == "image" then
    local path, err = clipboard.save_image({ mime = info.mime, keep = config.options.image_paste.keep })
    if not path then
      notify_one_line("yana: could not paste image: " .. tostring(err), vim.log.levels.WARN)
      return
    end
    insert_at_cursor(p.prompt_buf, p.prompt_win, path)
    notify_one_line("yana: attached image " .. path, vim.log.levels.INFO)
    return
  end

  if info.kind == "file" then
    -- A file manager copy of an existing image file: use it verbatim, no copy.
    insert_at_cursor(p.prompt_buf, p.prompt_win, info.path)
    notify_one_line("yana: attached image " .. info.path, vim.log.levels.INFO)
    return
  end

  if info.kind == "text" and not opts.force_image then
    local text, err = clipboard.read_text(info.mime)
    if not text or text == "" then
      notify_one_line("yana: could not read clipboard text: " .. tostring(err or "empty"), vim.log.levels.WARN)
      return
    end
    insert_at_cursor(p.prompt_buf, p.prompt_win, text)
    return
  end

  local reason = info.error
    or (opts.force_image and "clipboard does not hold an image" or "clipboard is empty or unsupported")
  notify_one_line("yana: nothing to paste (" .. reason .. ")", vim.log.levels.WARN)
end

-- :YanaPasteImage — the image branch unconditionally, so it can be
-- bound by the user even with image_paste.key unset/disabled.
function M.paste_image()
  paste_into_panel(current_panel(), { force_image = true })
end

-- Insert-mode <C-c> quits insert without running buffer maps (:help i_CTRL-C)
-- ONLY while no insert-mode mapping for it exists: if one does, Nvim delivers
-- the mapped result and vim.on_key never sees "\003" at all, which silently
-- blinds this hook. Catch the raw key while a panel job is active so real
-- terminal Stop works under startinsert and when focus is not on the prompt
-- buffer.
local stop_on_key_ns = vim.api.nvim_create_namespace("yana_stop_c")
local stop_on_key_installed = false

-- What the hook saw on the most recent <C-c>. Real <C-c> cannot be exercised
-- headlessly (nvim_feedkeys never reaches the on_key path the way a typed key
-- does), so when stop fails there is otherwise NO evidence of WHICH guard
-- bailed. The live realkey fixture reads this to name the cause instead of
-- reporting a bare "no stop happened".
M._stop_key_probe = { seen = 0, mode = nil, had_panel = nil, had_job = nil, scheduled = false, error = nil }

-- The on_key callback proper is only the key filter plus a pcall; all real
-- work lives here so a throw can be caught.
local function stop_on_key_body()
  local probe = M._stop_key_probe
  probe.seen = probe.seen + 1
  probe.error = nil
  probe.scheduled = false

  -- The user's only use for <C-c> is copying (terminal/tmux passthrough);
  -- it must never do anything else in yana. Never in terminal mode (a
  -- live terminal buffer, e.g. inside :terminal, owns <C-c> for its own
  -- job). And use TRACKED focus (last_focused_panel), not the buffer
  -- current at this exact instant: a plugin window (e.g. noice's message
  -- view, a real non-floating split) can become "current" the moment a
  -- notification fires, which would make a same-instant buftype sample
  -- wrongly conclude the user left the panel.
  --
  -- mode() == "t" is terminal-insert/job mode; mode() == "nt" is
  -- terminal-NORMAL mode (:help mode()). Both belong to a live terminal
  -- buffer's own <C-c>, not yana's — bailing on "t" alone let a
  -- <C-c> pressed in a terminal buffer's normal mode slip through and
  -- stop the panel. (The YanaFocusTrack buftype=="terminal" clearing
  -- above is the primary fix for that; this is defense in depth.)
  local mode_now = vim.fn.mode()
  probe.mode = mode_now
  if mode_now == "t" or mode_now == "nt" then
    return
  end
  local p = last_focused_panel
  probe.had_panel = p ~= nil
  probe.had_job = p ~= nil and p.job ~= nil
  if not p or not p.job then
    return
  end
  -- Defer so normal-mode <C-c> on the prompt map can run first and avoid a
  -- duplicate stopped note when both handlers see the same key.
  probe.scheduled = true
  vim.schedule(function()
    log.guard("yana.ui stop-on-key", function()
      if cancel_inflight(p) then
        render_note(p, "⏹ stopped")
      end
    end)
  end)
end

local function install_stop_on_key()
  if stop_on_key_installed then
    return
  end
  local stop = config.options.keymaps.stop
  if not stop or stop == "" or (stop ~= "<C-c>" and stop ~= "<C-C>") then
    return
  end
  stop_on_key_installed = true
  vim.on_key(function(key)
    if key ~= "\003" and key ~= "<C-c>" and key ~= "<C-C>" then
      return
    end
    -- HARD REQUIREMENT: this callback must never throw. `:help vim.on_key` —
    -- "{fn} will be removed on error" — so ONE throw silently unbinds stop for
    -- the whole nvim session, and the stop_on_key_installed latch above then
    -- stops any later panel from re-arming it. Nothing surfaces to the user;
    -- only restarting nvim recovers. So the body is pcall'd and any throw is
    -- logged, rather than trusted not to happen.
    local ok, err = pcall(stop_on_key_body)
    if not ok then
      M._stop_key_probe.error = tostring(err)
      log.write("ERROR", "yana: <C-c> stop hook threw (hook stays armed): " .. tostring(err))
    end
  end, stop_on_key_ns)
end

----------------------------------------------------------------------
-- mode / chat management
----------------------------------------------------------------------

function M.toggle_mode()
  local p = current_panel()
  if not p then
    return
  end
  local blocked, reason = mode_change_blocked(p)
  if blocked and reason ~= "locked" then
    -- in_flight and friends are still hard refusals; only the session lock is
    -- now answerable by renewal.
    mode_change_refused_notify(p, reason)
    return
  end
  -- A chat with an upstream session used to end here ("start a new chat"). It
  -- can now RENEW instead, but only at a quiescent boundary, and only after
  -- every precondition has been measured. Fail closed: no best-effort switch,
  -- and no partial switch that leaves a review orphaned in the old mode.
  local renewing = blocked and reason == "locked"
  if renewing then
    local why = renewal_blocked_reason(p)
    if why then
      notify_one_line("yana: cannot switch mode — " .. why, vim.log.levels.WARN)
      return
    end
  end
  -- Mode is one product-level dial now, not a per-panel cycle, so switching it
  -- is a SESSION RENEWAL rather than a flag flip: cursor's upstream session
  -- carries a fixed mode chain, which is why mode_change_blocked above exists.
  -- Stage 0 of the mode contract permits ask <-> inline at a quiescent
  -- boundary; `agentic` is refused here until Stage 1 builds the interlock that
  -- leaving the harness requires.
  local ORDER = { "ask", "inline" }
  local cur = config.options.mode
  local idx = 1
  for i, m in ipairs(ORDER) do
    if m == cur then
      idx = i
      break
    end
  end
  local nextmode = ORDER[(idx % #ORDER) + 1]
  local ok, err = pcall(config.normalize_mode, nextmode)
  if not ok then
    notify.one_line(tostring(err), vim.log.levels.ERROR)
    return
  end
  -- `agentic` is unreachable at Stage 0 by construction: it is not in ORDER.
  -- Leaving the harness needs the interlock Stage 1 builds, and a mode you can
  -- reach by pressing a key twice is not a mode anyone chose deliberately.
  local from_mode = config.options.mode
  local brief = renewing and renewal_brief(p, from_mode, nextmode) or nil
  config.options.mode = nextmode
  p.mode = config.agent_permission_mode()
  if renewing then
    -- END the upstream session. The next submit starts a fresh one in the new
    -- mode and carries the brief as its opening context; nothing tries to
    -- mutate the old session, because that is the thing cursor does not allow.
    p.session_id = nil
    p.pending_brief = brief
    -- Shown to the operator at the moment of switching, not buried in a log:
    -- they are the one who can tell that a handoff dropped something.
    render_note(
      p,
      "**Mode → " .. nextmode .. "**. This chat renewed its session. The next message carries:\n\n```\n" .. brief .. "\n```"
    )
  end
  notify_one_line("yana: mode = " .. nextmode, vim.log.levels.INFO)
  update_winbar(p)
  notify_one_line("yana: mode → " .. p.mode, vim.log.levels.INFO)
end

-- Set a panel's mode programmatically (entry-point maps that imply a mode, e.g.
-- an ask map vs an edit map). Subject to the same per-chat lock as the <M-t>
-- toggle: callers must go through here rather than assigning p.mode, so the
-- lock cannot be bypassed by a caller outside the plugin.
-- Returns true when the panel is in `mode` on return, false when refused.
function M.set_mode(p, mode)
  p = p or current_panel()
  if not p then
    return false
  end
  local want = config.panel_mode(mode)
  if config.panel_mode(p.mode) == want then
    p.mode = want
    update_winbar(p)
    return true
  end
  local blocked, reason = mode_change_blocked(p)
  if blocked then
    if reason == "locked" then
      notify_one_line(
        "yana: this chat is locked to " .. config.panel_mode(p.mode) .. " mode — start a new chat to use " .. want,
        vim.log.levels.WARN
      )
    else
      mode_change_refused_notify(p, reason)
    end
    update_winbar(p)
    return false
  end
  p.mode = want
  update_winbar(p)
  return true
end

function M.ensure_agent_mode(p)
  p = p or current_panel()
  if not p then
    return
  end
  -- Never widens a locked chat: resolve_mode only normalises what is already
  -- set, and the lock is enforced at the one place that changes it (set_mode).
  p.mode = config.resolve_mode(p.mode)
  update_winbar(p)
end

-- Pick a model via cursor-agent --list-models + vim.ui.select.
-- Sets the model for the current panel only, so parallel panels can use
-- different models.
function M.pick_model()
  local p = current_panel()
  notify_one_line("yana: loading models…", vim.log.levels.INFO)
  agent.list_models(function(models, code)
    if code ~= 0 or #models == 0 then
      notify_one_line("yana: could not list models (is cursor-agent installed?)", vim.log.levels.ERROR)
      return
    end
    local current = (p and p.model) or "auto"
    vim.ui.select(models, {
      prompt = "yana: select model",
      format_item = function(m)
        local mark = (m.id == current) and "● " or "  "
        return mark .. m.label .. "  (" .. m.id .. ")"
      end,
    }, function(choice)
      if not choice then
        return
      end
      if p then
        p.model = (choice.id == "auto") and nil or choice.id
        update_winbar(p)
      end
      notify_one_line("yana: model → " .. choice.label, vim.log.levels.INFO)
    end)
  end)
end

-- View the file changes the agent made this session as a side-by-side diff.
function M.show_changes()
  local p = current_panel()
  if not p or #p.changes == 0 then
    notify_one_line("yana: no file changes this session", vim.log.levels.INFO)
    return
  end
  if #p.changes == 1 then
    diff.show(p.changes[1])
    return
  end
  vim.ui.select(p.changes, {
    prompt = "yana: view change",
    format_item = function(c)
      return string.format("%s %s  (+%s −%s)", diff.status_icon(c), c.rel, c.added or "?", c.removed or "?")
    end,
  }, function(choice)
    if choice then
      diff.show(choice)
    end
  end)
end

local function pick_pending(prompt, cb)
  local p = current_panel()
  local pending = p and diff.pending(p.changes) or {}
  if #pending == 0 then
    notify_one_line("yana: no pending changes to review", vim.log.levels.INFO)
    return
  end
  if #pending == 1 then
    cb(pending[1])
    return
  end
  vim.ui.select(pending, {
    prompt = prompt,
    format_item = function(c)
      return string.format("%s %s  (+%s −%s)", diff.status_icon(c), c.rel, c.added or "?", c.removed or "?")
    end,
  }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

local function retry_refused_review(p, change)
  local inline = require("yana.inline_diff")
  if change.review_error == REVIEW_RETRY_EXHAUSTED then
    change.review_error = nil
    change.review_retry_count = 0
    notify_one_line(
      "yana: review retry counter reset for " .. (change.rel or change.path),
      vim.log.levels.INFO
    )
  end
  local prior_err = change.review_error
  local prior_count = change.review_retry_count or 0
  local outcome = inline.enqueue(change, inline_review_opts(p, change))
  -- inserted / already_queued: not an open attempt. Restore count and error
  -- so a blocked click cannot manufacture retry_exhausted (enqueue clears
  -- review_error on first insert).
  if outcome ~= "opened" then
    change.review_error = prior_err
    change.review_retry_count = prior_count
    return false
  end
  local tries = prior_count + 1
  change.review_retry_count = tries
  local attempt_err = change.review_error
  -- Its own class, not a user decision and not a refusal: this is Yana
  -- re-attempting a review that was refused, and the corpus showed retry
  -- rounds being mistaken for the operator changing their mind.
  do
    local L = turn_ledger(p, change.turn_gen)
    ledger.bump(L, "review_retries")
    ledger.record_decision(L, {
      action = "review_retry",
      actor = "system",
      attempt = tries,
      max_attempts = MAX_REVIEW_RETRY,
      change_id = change.id,
      rel = change.rel or change.path,
      detail = attempt_err or prior_err,
    })
  end
  -- Successful open clears review_error. Never exhaust a live review just
  -- because the counter crossed MAX.
  if not attempt_err then
    return false
  end
  if tries > MAX_REVIEW_RETRY then
    change.review_error = REVIEW_RETRY_EXHAUSTED
    notify_one_line(
      "yana: review retries exhausted for " .. (change.rel or change.path)
        .. " — last refusal: " .. tostring(attempt_err),
      vim.log.levels.WARN
    )
    return false
  end
  notify_one_line(
    "yana: retrying review for " .. (change.rel or change.path)
      .. " (" .. tostring(tries) .. "/" .. tostring(MAX_REVIEW_RETRY) .. ")"
      .. " — was refused: " .. tostring(attempt_err),
    vim.log.levels.INFO
  )
  return false
end

function M.accept_change(change)
  if not change or change.status ~= "pending" then
    return false
  end
  do
    local inline = require("yana.inline_diff")
    if inline.resolve_change(change, "accept") then
      local p = current_panel()
      if p then
        refresh_change_block(p, change)
        update_winbar(p)
      end
      return true
    end
    -- No active session to resolve against (the row is "pending" but there
    -- is nothing to press ct/co on) is either the healthy "review is active
    -- for a DIFFERENT change" case, or — when review_error is set — this
    -- change's own review was refused earlier (disk drifted, buffer had
    -- unrelated edits, no window was available, …). The refusal reasons are
    -- all transient user-side state, so the natural reading of "user pressed
    -- accept on a stuck row" is retry, not print advice for hunks that were
    -- never painted.
    if change.review_error then
      local p = current_panel()
      if p then
        return retry_refused_review(p, change)
      end
      -- No panel to build retry callbacks against; fall through to the
      -- ordinary advice path below.
    end
    if change.batched then
      notify_one_line(
        "yana: review for " .. (change.rel or change.path) .. " opens when the turn ends",
        vim.log.levels.INFO
      )
      return false
    end
    local p = current_panel()
    local ws_opts = change.review_workspace and { workspace = change.review_workspace }
      or (p and { workspace = panel_claimed_workspace(p) } or nil)
    if ws_opts then
      inline.focus_active(ws_opts)
    end
    notify_one_line("yana: resolve hunks in file (`ct` accept · `co` reject · `ca` all)", vim.log.levels.INFO)
    return false
  end
end

function M.reject_change(change)
  if not change or change.status ~= "pending" then
    return false
  end
  do
    local inline = require("yana.inline_diff")
    if inline.resolve_change(change, "reject") then
      local p = current_panel()
      if p then
        refresh_change_block(p, change)
        update_winbar(p)
      end
      return true
    end
    -- See the matching comment in M.accept_change: retry the review when
    -- this change's own attempt was refused, rather than giving advice for
    -- hunks that were never painted.
    if change.review_error then
      local p = current_panel()
      if p then
        return retry_refused_review(p, change)
      end
      -- No panel to build retry callbacks against; fall through to the
      -- ordinary advice path below.
    end
    if change.batched then
      notify_one_line(
        "yana: review for " .. (change.rel or change.path) .. " opens when the turn ends",
        vim.log.levels.INFO
      )
      return false
    end
    local p = current_panel()
    local ws_opts = change.review_workspace and { workspace = change.review_workspace }
      or (p and { workspace = panel_claimed_workspace(p) } or nil)
    if ws_opts then
      inline.focus_active(ws_opts)
    end
    notify_one_line("yana: reject in file (`cb` abort file · `co` reject hunk)", vim.log.levels.INFO)
    return false
  end
end

function M.accept_changes()
  pick_pending("yana: accept change", function(c)
    M.accept_change(c)
  end)
end

function M.reject_changes()
  pick_pending("yana: reject change", function(c)
    M.reject_change(c)
  end)
end

function M.review_changes()
  local p = current_panel()
  pick_pending("yana: review change", function(change)
    -- Use the panel's own review handlers. The old inline table called
    -- M.accept_change, which no-ops once the engine has already marked the
    -- change accepted, so a picker-opened review left both the change block
    -- and its claim line stale.
    local opened = diff.review(change, p and inline_review_opts(p, change) or {})
    -- `review` returns true for "queued behind an active review" as well as
    -- "opened now". Say which, or picking a change looks like it did nothing.
    local inline = require("yana.inline_diff")
    -- `status ~= "pending"` filters the zero-hunk case: M.open auto-accepts a
    -- change with no diff blocks and never sets `active`, which otherwise
    -- looks identical to "queued" here and announced a queue that is empty.
    if opened and change.status == "pending" and p
      and inline.active_change({ workspace = panel_claimed_workspace(p) }) ~= change then
      notify_one_line(
        "yana: queued " .. (change.rel or "change") .. " behind the open review",
        vim.log.levels.INFO
      )
    end
  end)
end

function M.new_chat()
  local p = current_panel()
  if not p then
    return
  end
  cancel_inflight(p)
  -- The conversation these changes belong to is being thrown away; enqueuing
  -- reviews against blocks that no longer exist in the buffer is the H4 shape.
  local inline = require("yana.inline_diff")
  local owner = { panel_id = p.id, epoch = p.review_epoch }
  p.review_epoch = p.review_epoch + 1
  drop_review_batch(p)
  -- Tear down only this panel/epoch's active and queued inline reviews for the
  -- claimed workspace before releasing the shadow claim (H4).
  inline.discard_for_owner(owner, inline_review_opts(p))
  -- The reviews for this conversation are being discarded, so the review that
  -- was holding the workspace claim is closed too.
  release_shadow_turn(p, "conversation discarded")
  persist_session(p)
  p.session_id = nil
  p.title = nil
  p.turns = 0
  p.got_result = false
  p.stream_text = ""
  p.changes = {}
  p.last_question = nil
  p.ask_advice_resend = nil
  p.mode = config.panel_mode(nil)
  if buf_valid(p.conv_buf) then
    set_lines(p, 0, -1, {})
  end
  M.render_greeting(p)
  update_winbar(p)
end

----------------------------------------------------------------------
-- workspace claim recovery
----------------------------------------------------------------------

-- What holds this workspace, if anything. Named holder and review state, so a
-- refusal can be explained rather than guessed at.
--- The applier diary session of whichever panel currently holds an apply pass,
--- for `:YanaDump`. Read-only: the dump reads the diary's own
--- introspection rather than inventing a second format for the same journal.
function M.dump_diary_session()
  for _, p in ipairs(panels) do
    if p.shadow_pass and p.shadow_pass.diary_session then
      return p.shadow_pass.diary_session
    end
  end
  return nil
end

--- Every live panel's turn ledger key, for diagnostics that want to name the
--- panels rather than walk the registry themselves.
function M.panel_turn_keys()
  local out = {}
  for _, p in ipairs(panels) do
    out[#out + 1] = { panel_id = p.id, gen = p.turn_gen, session_id = p.session_id, busy = p.busy }
  end
  return out
end

function M.claim_status(workspace)
  local p = current_panel()
  local ws = workspace
  if not ws then
    local preview = preview_module()
    ws = preview.workspace_for_turn({ cwd = (p and p.cwd) or vim.fn.getcwd() })
  end
  return preview_module().claim_status(ws)
end

-- Release a claim whose review is already closed. Refuses while a review is
-- open or the state is incomplete: the module's rule is never to guess dead,
-- and the way out of those cases is force_release_claim with a reason.
function M.release_claim(workspace)
  local status = M.claim_status(workspace)
  if not status.held then
    notify_one_line("yana: no claim held on " .. status.workspace, vim.log.levels.INFO)
    return false
  end
  if status.review_open then
    notify_one_line(
      string.format(
        "yana: %s is claimed with a review still open (holder: %s) — use force release with a reason",
        status.workspace,
        status.holder or "unknown"
      ),
      vim.log.levels.WARN
    )
    return false
  end
  local ok, err = preview_module().release(
    { claim_dir = status.claim_dir }
  )
  if not ok then
    notify_one_line("yana: releasing the claim failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  notify_one_line("yana: released the claim on " .. status.workspace, vim.log.levels.INFO)
  return true
end

-- Explicit override for a claim left behind by a crashed editor. Requires a
-- reason, which the overlay appends to its force-release log.
function M.force_release_claim(reason, workspace)
  reason = reason and vim.trim(reason) or ""
  if reason == "" then
    notify_one_line("yana: force release needs a reason", vim.log.levels.ERROR)
    return false
  end
  local status = M.claim_status(workspace)
  if not status.held then
    notify_one_line("yana: no claim held on " .. status.workspace, vim.log.levels.INFO)
    return false
  end
  local ok, err = preview_module().force_release(status.claim_dir, reason)
  if not ok then
    notify_one_line("yana: force release failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  notify_one_line(
    string.format("yana: force-released %s (was held by %s): %s", status.workspace, status.holder or "unknown", reason),
    vim.log.levels.WARN
  )
  return true
end

function M.render_greeting(p)
  -- No welcome boilerplate; panel opens ready for input.
end

----------------------------------------------------------------------
-- window construction
----------------------------------------------------------------------

local function compute_width()
  local w = config.options.ui.width
  if w <= 1 then
    return math.max(30, math.floor(vim.o.columns * w))
  end
  return math.floor(w)
end

-- is_prompt: flags the PROMPT buffer only with b:yana_prompt, alongside
-- the existing b:yana_panel both buffers get. Both panel buffers stay
-- filetype=markdown (a dedicated filetype would regress rendering,
-- treesitter and the panel keymaps); this variable is how a completion
-- source or any other scoping check tells prompt from conversation without
-- keying off filetype.
local function set_panel_buf_opts(buf, ft, is_prompt)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = ft
  vim.b[buf].yana_panel = true
  if is_prompt then
    vim.b[buf].yana_prompt = true
  end
end

local function apply_panel_keymaps(p)
  local k = config.options.keymaps
  local function map(buf, modes, lhs, rhs, desc)
    if not lhs or lhs == "" then
      return
    end
    -- Every panel keymap funnels through here, so wrapping the function-typed
    -- rhs in log.guard covers all of them at one choke point: on error the
    -- traceback is logged before it surfaces exactly as before.
    if type(rhs) == "function" then
      local fn = rhs
      rhs = function(...)
        log.guard("panel keymap " .. lhs, fn, ...)
      end
    end
    vim.keymap.set(modes, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  -- which-key group for the resend prefix, buffer-local so it only shows in the
  -- panel. Optional dependency: absent which-key must not break keymaps.
  local function register_resend_which_key(buf)
    if not k.resend or k.resend == "" then
      return
    end
    local ok, wk = pcall(require, "which-key")
    if not ok then
      return
    end
    pcall(wk.add, {
      buffer = buf,
      { k.resend, group = "resend last prompt", icon = "󰑖", mode = { "n", "i" } },
      { k.resend .. "r", desc = "here — same chat, same session", mode = { "n", "i" } },
      { k.resend .. "n", desc = "new chat — fresh session, same mode", mode = { "n", "i" } },
      { k.resend .. "a", desc = "new agent chat — fresh session, agent mode", mode = { "n", "i" } },
    })
  end

  -- Prompt buffer: submit & control.
  map(p.prompt_buf, { "n", "i" }, k.submit, function()
    submit_panel(p)
  end, "yana: submit")
  map(p.prompt_buf, "n", k.submit_normal, function()
    submit_panel(p)
  end, "yana: submit")
  map(p.prompt_buf, { "n", "i" }, k.stop, function()
    if cancel_inflight(p) then
      render_note(p, "⏹ stopped")
    end
  end, "yana: stop")
  map(p.prompt_buf, { "n", "i" }, k.steer, function()
    M.steer()
  end, "yana: interrupt and steer")

  -- Manual completion-menu open: prompt buffer, insert mode only, works on
  -- an empty line with no trigger character (blink's `/` and `@` sources
  -- otherwise only fire on those trigger characters). Bare cmp.show() with
  -- no providers override — blink.lua's sources.default already scopes to
  -- { "yana_commands", "yana_mentions" } for any buffer flagged
  -- b:yana_prompt, so this reaches the same two sources without
  -- duplicating that scoping decision here.
  --
  -- Default key is <C-Space> (config.lua), same chord blink.cmp itself binds
  -- and re-applies buffer-locally on every InsertEnter. That is not a
  -- conflict — see config.lua's completion_menu comment: blink's own
  -- <C-Space> already resolves to the identical yana-scoped cmp.show()
  -- in this buffer, so this mapping only ever matters for the sliver of time
  -- before blink's InsertEnter autocmd (re-)applies its own, and as a
  -- fallback if blink.cmp is ever absent/disabled (the pcall below).
  map(p.prompt_buf, "i", k.completion_menu, function()
    local ok, blink = pcall(require, "blink.cmp")
    if ok then
      blink.show()
    end
  end, "yana: open completion menu")

  local ip = config.options.image_paste
  if ip and ip.enable then
    -- normalize_image_paste always yields a list. <C-v>/<C-V> collapse to one
    -- keycode, so binding both is idempotent, not a conflict.
    for _, key in ipairs(ip.key) do
      map(p.prompt_buf, "i", key, function()
        paste_into_panel(p, {})
      end, "yana: paste image/text from clipboard")
    end
  end

  for _, buf in ipairs({ p.prompt_buf, p.conv_buf }) do
    vim.keymap.set("n", "<Tab>", "<Nop>", { buffer = buf, silent = true, desc = "yana: ignore harpoon tab" })
    local modes = (buf == p.prompt_buf) and { "n", "i" } or "n"
    map(buf, modes, k.new_chat, function()
      M.new_chat()
    end, "yana: new chat")
    map(buf, modes, k.toggle_mode, function()
      M.toggle_mode()
    end, "yana: toggle mode")
    -- Resend is a PREFIX, not a single key: the useful question after "resend"
    -- is always "where", and a chat's mode is locked once it has run a turn, so
    -- "in agent mode" necessarily means "in a new chat". which-key renders the
    -- three leaves; register_resend_which_key below labels them.
    if k.resend and k.resend ~= "" then
      register_resend_which_key(buf)
      map(buf, modes, k.resend .. "r", function()
        M.resend({ where = "here" })
      end, "resend here (same session)")
      map(buf, modes, k.resend .. "n", function()
        M.resend({ where = "new" })
      end, "resend in a new chat")
      map(buf, modes, k.resend .. "a", function()
        M.resend({ where = "agent" })
      end, "resend in a new agent chat")
    end
    map(buf, modes, k.model, function()
      M.pick_model()
    end, "yana: pick model")
    map(buf, modes, k.sessions, function()
      M.pick_session()
    end, "yana: sessions")
    map(buf, modes, k.new_panel, function()
      M.open_new_panel()
    end, "yana: new panel")
    map(buf, modes, k.queue, function()
      M.pick_queue()
    end, "yana: queued prompts")
    map(buf, "n", k.review or k.diff, function()
      M.review_changes()
    end, "yana: review changes")
    map(buf, "n", k.accept, function()
      M.accept_changes()
    end, "yana: accept change")
    map(buf, "n", k.reject, function()
      M.reject_changes()
    end, "yana: reject change")
    map(buf, "n", k.close, function()
      M.close_panel(p)
    end, "yana: close panel")
  end

  map(p.conv_buf, "n", k.focus_prompt, function()
    M.focus_prompt(p)
  end, "yana: focus prompt")
end

local function setup_panel_autocmds(p)
  p.augroup = vim.api.nvim_create_augroup("YanaPanel" .. p.id, { clear = true })

  -- Track the most recently used panel.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = p.augroup,
    callback = function(ev)
      log.guard("yana.ui panel BufEnter", function()
        if ev.buf == p.conv_buf or ev.buf == p.prompt_buf then
          last_panel = p
        end
      end)
    end,
  })

  -- <C-c> stop-hook focus tracking (see last_focused_panel above): claim
  -- focus whenever this panel's own conv_buf or prompt_buf is entered,
  -- either by switching windows or by switching buffers within a window.
  -- Buffer-scoped (not a global BufEnter/WinEnter that inspects ev.buf) so
  -- it only ever fires for these two buffers.
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = p.augroup,
    buffer = p.conv_buf,
    callback = function()
      last_focused_panel = p
    end,
  })
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    group = p.augroup,
    buffer = p.prompt_buf,
    callback = function()
      last_focused_panel = p
    end,
  })

  -- If one of the pair of windows is closed directly (:q), close its sibling
  -- so half-panels are never left behind.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = p.augroup,
    callback = function(ev)
      log.guard("yana.ui panel WinClosed", function()
        local w = tonumber(ev.match)
        if p.closing or (w ~= p.conv_win and w ~= p.prompt_win) then
          return
        end
        p.closing = true
        vim.schedule(function()
          log.guard("yana.ui panel WinClosed cleanup", function()
            if win_valid(p.prompt_win) then
              pcall(vim.api.nvim_win_close, p.prompt_win, true)
            end
            if win_valid(p.conv_win) then
              pcall(vim.api.nvim_win_close, p.conv_win, true)
            end
            p.conv_win = nil
            p.prompt_win = nil
            p.closing = false
          end)
        end)
      end)
    end,
  })
end

local function win_opts(win, is_prompt)
  local o = config.options
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = o.ui.wrap
  vim.wo[win].linebreak = o.ui.wrap
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winfixwidth = true
  if is_prompt then
    vim.wo[win].winbar = "%#Comment#  prompt — type your question %*"
  end
end

-- Distribute the sidebar column height between the open panels: every prompt
-- gets its configured height and the conversations share the rest.
local function relayout()
  local open = {}
  for _, q in ipairs(panels) do
    if panel_open(q) then
      table.insert(open, q)
    end
  end
  if #open < 2 then
    return
  end
  local o = config.options
  local total = 0
  for _, q in ipairs(open) do
    total = total + vim.api.nvim_win_get_height(q.conv_win) + vim.api.nvim_win_get_height(q.prompt_win)
  end
  local conv_h = math.max(3, math.floor(total / #open) - o.ui.prompt_height - 1)
  for _, q in ipairs(open) do
    pcall(vim.api.nvim_win_set_height, q.conv_win, conv_h)
    pcall(vim.api.nvim_win_set_height, q.prompt_win, o.ui.prompt_height)
  end
end

-- Open (or reopen) the windows for a panel. If another panel is already open,
-- the new panel stacks below it inside the same sidebar column; otherwise a
-- fresh sidebar vsplit is created.
local function open_windows(p)
  if panel_open(p) then
    return
  end

  local o = config.options
  local anchor = nil
  for _, q in ipairs(panels) do
    if q ~= p and panel_open(q) then
      anchor = q
    end
  end

  -- Stack below an existing panel when the column is tall enough for two
  -- panels; otherwise fall back to a fresh sidebar column.
  local stacked = false
  if anchor then
    local total = vim.api.nvim_win_get_height(anchor.conv_win) + vim.api.nvim_win_get_height(anchor.prompt_win)
    local min_panel_h = o.ui.prompt_height + 6
    if total >= 2 * min_panel_h then
      vim.api.nvim_set_current_win(anchor.prompt_win)
      pcall(vim.api.nvim_win_set_height, anchor.prompt_win, math.max(4, math.floor(total / 2)))
      stacked = pcall(vim.cmd, "belowright split")
    end
  end
  if not stacked then
    vim.cmd(o.ui.position == "left" and "topleft vsplit" or "botright vsplit")
  end
  p.conv_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(p.conv_win, p.conv_buf)
  if not stacked then
    vim.api.nvim_win_set_width(p.conv_win, compute_width())
  end

  -- Prompt window below the conversation, inside the same column.
  vim.cmd("belowright split")
  p.prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(p.prompt_win, p.prompt_buf)
  pcall(vim.api.nvim_win_set_height, p.prompt_win, o.ui.prompt_height)

  win_opts(p.conv_win, false)
  win_opts(p.prompt_win, true)
  -- Refresh every winbar: panel indices are shown once there is more than one.
  for _, q in ipairs(panels) do
    update_winbar(q)
  end
  relayout()

  -- A turn that finished while this panel was closed leaves its queue intact
  -- (on_done's panel_open guard) instead of losing an item to a submit_panel
  -- early-return; drain it now that the panel is open and visible again.
  maybe_drain_queue(p)
end

local function create_panel()
  -- Deferred to first panel creation rather than module load: at load time
  -- config.setup() may not have run yet, so config.options.keymaps.stop
  -- would still read the default instead of the user's configured value.
  -- install_stop_on_key() is idempotent (stop_on_key_installed guard), so
  -- this is safe to call on every panel creation.
  install_stop_on_key()
  local p = new_panel_state()
  p.mode = config.panel_mode(nil)
  -- Repaint claims on EVERY engine transition, not only on the edges this
  -- panel drives itself. Without this, a change queued behind another keeps
  -- saying "queued" for the whole time its own review is open, and a review
  -- aborted after its claim was stamped keeps saying "open" forever.
  p.unsubscribe_review = require("yana.inline_diff").on_state_change(function()
    refresh_all_review_claims(p)
  end)
  if config.options.model and config.options.model ~= "" then
    p.model = config.options.model
  end

  p.conv_buf = vim.api.nvim_create_buf(false, true)
  set_panel_buf_opts(p.conv_buf, "markdown", false)
  vim.bo[p.conv_buf].modifiable = false

  p.prompt_buf = vim.api.nvim_create_buf(false, true)
  set_panel_buf_opts(p.prompt_buf, "markdown", true)
  vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })

  table.insert(panels, p)
  -- Release the subscription the moment the panel actually dies, rather than
  -- whenever the user next touches yana. prune_panels only runs from
  -- entry points (current_panel/is_open/panel_count), so a panel wiped by a
  -- user who then walks away kept its observer -- and the panel table,
  -- conv_buf handle and changes list behind it -- for the rest of the session.
  -- Scheduled: at BufWipeout the buffer still reads valid, so panel_alive
  -- would say the panel is fine.
  --
  -- BOTH buffers, not just conv_buf: panel_alive requires each of them, so
  -- wiping the prompt buffer alone kills the panel just as dead while firing
  -- nothing. Buffer-local autocmds die with their buffer, so there is no
  -- double-fire to guard against and prune_panels is idempotent regardless.
  for _, buf in ipairs({ p.conv_buf, p.prompt_buf }) do
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function()
        vim.schedule(function()
          log.guard("yana.ui BufWipeout prune_panels", prune_panels)
        end)
      end,
    })
  end
  apply_panel_keymaps(p)
  setup_panel_autocmds(p)
  open_windows(p)
  M.render_greeting(p)
  last_panel = p
  return p
end

function M.is_open()
  prune_panels()
  for _, p in ipairs(panels) do
    if panel_open(p) then
      return true
    end
  end
  return false
end

function M.panel_count()
  prune_panels()
  return #panels
end

-- Session id of the current panel (nil for a fresh chat). Handy for
-- statuslines and tests.
function M.current_session_id()
  local p = current_panel()
  return p and p.session_id or nil
end

function M.focus_prompt(p)
  p = p or current_panel()
  if p and win_valid(p.prompt_win) then
    vim.api.nvim_set_current_win(p.prompt_win)
    last_panel = p
    vim.cmd("startinsert")
  end
end

function M.open()
  local p = current_panel()
  if p then
    if not panel_open(p) then
      open_windows(p)
      -- Belt and braces for the toggle path: the subscription now survives
      -- close_panel, but if anything ever drops it the panel re-arms itself
      -- here rather than silently going claim-blind.
      if not p.unsubscribe_review then
        p.unsubscribe_review = require("yana.inline_diff").on_state_change(function()
          refresh_all_review_claims(p)
        end)
      end
      -- Reviews resolve while the panel is closed. Repaint from the engine
      -- on the way back in so the first thing shown is current state.
      refresh_all_review_claims(p)
    end
    M.focus_prompt(p)
    return p
  end
  p = create_panel()
  M.focus_prompt(p)
  return p
end

-- Open an additional, independent panel (its own session/mode/model/job),
-- stacked below any panel already visible.
function M.open_new_panel()
  local p = create_panel()
  M.focus_prompt(p)
  return p
end

-- Permanently destroy one panel. Unlike close_panel(), this stops its agent,
-- releases its observers/autocmds, removes it from the panel registry, and
-- wipes both scratch buffers. File edits already made by the agent are left
-- for the normal review flow; quitting never silently accepts or reverts them.
local function quit_panel(p)
  local idx = panel_index(p)
  if idx == 0 then
    return false
  end

  cancel_inflight(p)
  persist_session(p)
  stop_spinner(p)
  p.closing = true
  destroy_panel(p)
  table.remove(panels, idx)
  if last_panel == p then
    last_panel = nil
  end
  if last_focused_panel == p then
    last_focused_panel = nil
  end

  local bufs = { p.prompt_buf, p.conv_buf }
  for _, buf in ipairs(bufs) do
    if buf_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  p.conv_win = nil
  p.prompt_win = nil
  p.closing = false
  -- The panel is gone for good, so its ledger records are dead UI state. Panel
  -- ids only ever increase, so without this every open/quit cycle left up to
  -- eight retained turns behind and grew every dump and flow report with them.
  -- Last, after persist_session and destroy_panel, so nothing above can still
  -- want to record against this panel.
  ledger.drop_panel(p.id)
  relayout()
  return true
end

-- Quit only when the cursor is inside that panel. Deliberately do not fall
-- back to current_panel(): from a source buffer that would kill a background
-- agent merely because it happened to be used most recently.
function M.quit_current()
  prune_panels()
  local p = panel_for_buf(vim.api.nvim_get_current_buf())
  if not p then
    notify_one_line("yana: current buffer is not a panel", vim.log.levels.INFO)
    return false
  end
  return quit_panel(p)
end

function M.quit_all()
  prune_panels()
  local count = #panels
  for i = #panels, 1, -1 do
    quit_panel(panels[i])
  end
  return count
end

-- Close a single panel's windows (buffers/state are kept, so it can be
-- reopened and any in-flight job keeps streaming into its buffer).
function M.close_panel(p)
  p = p or current_panel()
  if not p then
    return
  end
  stop_spinner(p)
  p.closing = true
  -- The review subscription deliberately SURVIVES a window close. This only
  -- closes windows; the panel, its buffers and its pending reviews all live
  -- on, and unsubscribing here meant a toggle closed->open froze every claim
  -- for the rest of the session (the exact bug the observer exists to kill).
  -- Repainting a hidden-but-valid buffer is cheap and keeps it correct for
  -- the reopen. The subscription is released in prune_panels, when the panel
  -- is actually destroyed.
  if win_valid(p.prompt_win) then
    pcall(vim.api.nvim_win_close, p.prompt_win, true)
  end
  if win_valid(p.conv_win) then
    pcall(vim.api.nvim_win_close, p.conv_win, true)
  end
  p.conv_win = nil
  p.prompt_win = nil
  p.closing = false
end

-- Close every open panel.
function M.close()
  for _, p in ipairs(panels) do
    if panel_open(p) then
      M.close_panel(p)
    end
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

----------------------------------------------------------------------
-- sessions: view / resume
----------------------------------------------------------------------

-- Resume a session entry ({ id, title?, mode?, model?, turns? }).
-- opts.new_panel: open in a fresh panel instead of reusing the current one.
function M.resume(sess, opts)
  opts = opts or {}
  if not sess or not sess.id or sess.id == "" then
    return
  end

  local p
  if not opts.new_panel then
    p = current_panel()
    -- Don't hijack a panel that is mid-response.
    if p and p.busy then
      p = nil
    end
  end
  if p then
    if not panel_open(p) then
      open_windows(p)
    end
    persist_session(p)
  else
    p = create_panel()
  end

  p.session_id = sess.id
  p.title = sess.title
  local restored = config.panel_mode(sess.mode or p.mode)
  if config.options.mode == "agentic" and (restored == "ask" or restored == "plan") then
    local nk = (config.options.keymaps or {}).new_chat
    notify_one_line(
      "yana: cannot resume a "
        .. restored
        .. " session while mode = \"agentic\" — start a fresh chat"
        .. ((nk and nk ~= "") and (" with " .. nk) or " (:YanaNew)"),
      vim.log.levels.WARN
    )
    return nil
  end
  p.mode = restored
  p.model = sess.model or p.model
  p.changes = {}
  p.turns = sess.turns or 0
  p.stream_text = ""
  p.pending_selection = nil

  set_lines(p, 0, -1, {})
  local transcript = sessions.load_transcript(sess.id)
  if transcript then
    set_lines(p, 0, -1, transcript)
    append(p, { "", "_↩ resumed session — follow-ups continue where it left off_", "" })
  else
    append(p, {
      "# yana",
      "",
      "_↩ resumed session `" .. sess.id .. "`_",
      "",
      "_No local transcript for this session (it was likely started outside",
      "Neovim), but the agent still has the full history — just keep asking._",
      "",
      "---",
      "",
    })
  end
  scroll_to_bottom(p)
  update_winbar(p)
  M.focus_prompt(p)
  return p
end

-- Pick a session from the registry (+ discovered CLI sessions) and resume it.
-- opts.new_panel: resume into a new panel (parallel session).
function M.pick_session(opts)
  opts = opts or {}
  local list = sessions.list(vim.fn.getcwd())
  if #list == 0 then
    notify_one_line("yana: no previous sessions for this directory", vim.log.levels.INFO)
    return
  end
  vim.ui.select(list, {
    prompt = "yana: sessions (resume)",
    format_item = function(s)
      local mark = find_panel_by_session(s.id) and "● " or "  "
      return mark .. sessions.format(s)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local existing = find_panel_by_session(choice.id)
    if existing and not opts.new_panel then
      -- Already open in a panel: just focus it.
      if not panel_open(existing) then
        open_windows(existing)
      end
      M.focus_prompt(existing)
      return
    end
    M.resume(choice, opts)
  end)
end

-- Resume the most recent session for this cwd, or a specific session id.
function M.resume_last(id, opts)
  local sess
  if id and id ~= "" then
    sess = sessions.get(id) or { id = id }
  else
    sess = sessions.list(vim.fn.getcwd())[1]
  end
  if not sess then
    notify_one_line("yana: no previous sessions for this directory", vim.log.levels.INFO)
    return
  end
  local existing = find_panel_by_session(sess.id)
  if existing then
    if not panel_open(existing) then
      open_windows(existing)
    end
    M.focus_prompt(existing)
    return existing
  end
  return M.resume(sess, opts)
end

-- Attach a selection to the next submitted prompt and open the panel.
-- selection: table from context.selection_from_range (or nil).
-- question: optional; if given, submit immediately.
function M.ask(selection, question)
  local p = M.open()
  if not p then
    return
  end
  p.pending_selection = selection
  if question and question ~= "" then
    vim.bo[p.prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, vim.split(question, "\n", { plain = true }))
    submit_panel(p)
  end
end

-- Run an inline edit ("Ctrl-K") as an ordinary agent turn.
--
-- Deliberately NOT a new kind of turn. The selection and the instruction are
-- the same two things `M.ask` already carries; the only differences are that
-- agent mode is required (an inline edit that cannot edit is not one) and that
-- focus stays in the source window instead of moving to the prompt. Everything
-- downstream — scope enforcement, the private layer, hunk review, accept and
-- reject — is reached by exactly the path a typed prompt reaches it by.
--
-- Panel selection has one real constraint: a chat's mode locks once it has run
-- a turn, because cursor-agent inherits a resumed session's mode and has no
-- `--mode agent` to undo it. So a panel already locked into ask can never serve
-- an inline edit, and the only way to get agent mode is a fresh chat. Reusing
-- an eligible panel keeps repeat edits in one session (cheaper, and the agent
-- keeps the context of the last edit); a new panel is the fallback, not the
-- default.
---@param selection table  from context.selection_from_range
---@param instruction string  non-empty; the user's edit request
---@return boolean started
function M.inline_edit(selection, instruction)
  if not selection or type(instruction) ~= "string" or instruction == "" then
    return false
  end
  local origin_win = vim.api.nvim_get_current_win()

  local p = current_panel()
  if p and (p.busy or p.job ~= nil or p.awaiting_exit) then
    -- Queuing would be wrong here, not merely inconvenient: pending_selection
    -- is single-valued, so a queued inline edit would run against whatever
    -- selection the NEXT submit attaches, silently editing the wrong lines.
    notify_one_line("yana: still responding — stop the turn first, or wait", vim.log.levels.WARN)
    return false
  end
  if not (p and M.set_mode(p, "agent")) then
    p = create_panel()
    if not p then
      return false
    end
    if not M.set_mode(p, "agent") then
      -- A brand-new chat is unlocked by construction, so this cannot happen
      -- from mode locking; assert rather than run the edit read-only.
      notify_one_line("yana: could not start an agent chat for the inline edit", vim.log.levels.ERROR)
      return false
    end
  end

  p.pending_selection = selection
  render_note(p, string.format("inline edit — %s L%d-%d", selection.name or "buffer", selection.l1, selection.l2))
  submit_panel(p, { text = instruction })

  -- Give the buffer back. The panel renders and the review arrives in the
  -- source buffer; the user never had to visit the sidebar to ask for it.
  if vim.api.nvim_win_is_valid(origin_win) then
    pcall(vim.api.nvim_set_current_win, origin_win)
  end
  return true
end

M._test = M._test or {}
M._test.on_done = on_done
M._test.on_event = on_event
M._test.on_exit_confirmed = on_exit_confirmed
M._test.finalize_shadow_turn = finalize_shadow_turn
M._test.render_tool_change = render_tool_change
M._test.flush_review_batch = flush_review_batch
M._test.REVIEW_RETRY_EXHAUSTED = REVIEW_RETRY_EXHAUSTED
M._test.MAX_REVIEW_RETRY = MAX_REVIEW_RETRY
M._test.inline_review_opts = inline_review_opts
M._test.begin_accept_indication = begin_accept_indication
M._test.panel_claimed_workspace = panel_claimed_workspace
M._test.new_chat = M.new_chat
-- Stage 0 renewal seams. Exported so a row can prove the REFUSALS fire, not
-- merely that a switch succeeds: a precondition that never blocks is the same
-- defect as a check that never fails.
M._test.renewal_blocked_reason = renewal_blocked_reason
M._test.renewal_brief = renewal_brief

return M
