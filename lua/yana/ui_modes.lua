-- Seat / mode-switch cluster, split out of yana.ui. Mode switch re-attaches the
-- destination seat — never renews a session (O4). `reconcile_pending` is the winbar
-- pending-badge desync check.
--
-- `reconcile_pending` is handed to `yana.ui_winbar` as a plain function-
-- reference dep (captured once, at `ui_winbar_factory.new` call time, in
-- ui.lua) -- ui.lua MUST instantiate this module before that call.
local config = require("yana.config")
local ledger = require("yana.ledger")
local log = require("yana.log")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
--- Refusal / brief helpers for G2/G3 still live in `lua/yana/renewal.lua`.
--- Switch itself never renews; renewal.blocked gates review-open / in-flight.
local renewal = require("yana.renewal")

local M = {}

-- deps.current_panel: parent's `current_panel()` — the cursor/MRU panel.
-- deps.update_winbar: parent's `update_winbar(p)` — repaint one panel's
-- winbar chip (model/mode/backend) after a switch.
-- deps.turn_ledger: parent's per-(panel,gen) ledger lookup (yana.ui_render),
-- needed by `reconcile_pending`'s desync record.
function M.new(deps)
  local current_panel = deps.current_panel
  local update_winbar = deps.update_winbar
  local turn_ledger = deps.turn_ledger


  --- Seat key for `mode` under the active backend descriptor (O5/O6). The ONLY
  --- place vendor seat maps are read — never `if backend == "cursor"`.
  local function seat_of(mode, backend_name)
    local bd = config.backend_descriptor(backend_name or config.options.backend) or {}
    mode = config.panel_mode(mode)
    if bd.mode_switch == "two_seat" and type(bd.seats) == "table" then
      for seat_name, modes in pairs(bd.seats) do
        if type(modes) == "table" then
          for _, m in ipairs(modes) do
            if m == mode then
              return seat_name
            end
          end
        end
      end
    end
    return "main"
  end

  -- G1 first: refuse while a turn is in flight. The old "locked" arm is gone (O4).
  local function mode_change_blocked(p)
    if not p then
      return true, "in_flight"
    end
    if p.busy or p.job ~= nil or p.awaiting_exit then
      return true, "in_flight"
    end
    return false, nil
  end

  -- Seat-keyed conversation map (O1/O6).
  local function remember_seat_session(p)
    if not p then
      return
    end
    local seat = seat_of(p.mode, config.options.backend)
    p.session_seats = p.session_seats or {}
    -- O1: first id on a seat wins. A later vendor echo must not retarget the
    -- conversation; snap the live panel id back to the seat when it drifts.
    if p.session_id == nil or p.session_id == "" then
      return
    end
    if p.session_seats[seat] == nil then
      p.session_seats[seat] = p.session_id
    else
      p.session_id = p.session_seats[seat]
    end
  end

  local function restore_seat_session(p, mode)
    if not p then
      return
    end
    local seat = seat_of(mode, config.options.backend)
    p.session_seats = p.session_seats or {}
    p.session_id = p.session_seats[seat]
    p.model_actual = nil
  end

  ----------------------------------------------------------------------
  -- MID-CHAT SWITCH (O1/O4/O6): seat re-attach, never session renewal.
  --
  -- A toggle remembers the current seat's vendor id and restores the destination seat's
  -- id. G1/G2/G3 still refuse while a turn is in flight or a review is open.
  ----------------------------------------------------------------------

  --- Why this chat cannot renew right now, or nil if it can. Returns a message
  --- naming the failing condition AND the action that clears it: a refusal the
  --- operator cannot act on is only marginally better than a hang.
  local function renewal_blocked_reason(p)
    return renewal.blocked_reason(p)
  end

  --- The `ask` answer's artifact, re-composed as an instruction the next turn can
  --- act on directly. The artifact extraction is the renewal module's, so the
  --- resend path and the brief can never disagree about what "the answer" is.
  local function build_apply_resend(question, answer)
    local artifact = renewal.answer_artifact(answer)
    if artifact == nil or artifact == "" then
      return question
    end
    return table.concat({
      "Apply exactly what we agreed in the previous ask answer.",
      "Treat this artifact as the source of truth for the edits.",
      "",
      artifact,
    }, "\n")
  end

  --- The brief AS THE OPERATOR SEES IT at the moment of switching. Explicitly
  --- NOT the raw transcript: a brief the operator can read in five lines beats a
  --- replay nobody checks, and a handoff they cannot see is a handoff they
  --- cannot correct.
  local function renewal_brief(p, from_mode, to_mode)
    return renewal.display_text(renewal.build(p, from_mode, to_mode))
  end

  local function seat_shared_context(p)
    -- O6.5/O7: only for two_seat backends on a seat with no id yet (cross-seat
    -- first turn). per_turn backends already share one vendor conversation.
    if not p or p.session_id ~= nil then
      return nil
    end
    local bd = config.backend_descriptor(config.options.backend) or {}
    if bd.mode_switch ~= "two_seat" then
      return nil
    end
    if not ((p.last_question and p.last_question ~= "") or (p.last_answer_text and p.last_answer_text ~= "")) then
      return nil
    end
    local lines = { "[Context from the other seat on this panel]" }
    if p.last_question and p.last_question ~= "" then
      lines[#lines + 1] = "Previous request:"
      lines[#lines + 1] = p.last_question
    end
    if p.last_answer_text and p.last_answer_text ~= "" then
      lines[#lines + 1] = "Previous answer:"
      lines[#lines + 1] = p.last_answer_text
    end
    return table.concat(lines, "\n")
  end

  local function mode_change_refused_notify(p, reason)
    local nk = config.options.mappings.new_chat
    local new_hint = (nk and nk ~= "") and (" with " .. nk) or " (:YanaNew)"
    if reason == "in_flight" then
      notify_one_line(
        "yana: wait for the current turn to finish before changing mode",
        vim.log.levels.WARN
      )
      return
    end
    notify_one_line(
      "yana: cannot switch mode right now — finish the current turn or review"
        .. new_hint,
      vim.log.levels.WARN
    )
  end

  -- Invariant capture: the number the user is SHOWN against the number the review
  -- engine holds. That is a counter the user cannot clear by any action, which is
  -- exactly the observed failure.
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

  -- Cycle the panel's mode. O1/O4/O6: seat re-attach, never session renewal.
  local function toggle_mode()
    local p = current_panel()
    if not p then
      return
    end
    -- G1: synchronous in_flight refusal first (never the slow renewal wording).
    local blocked, reason = mode_change_blocked(p)
    if blocked then
      mode_change_refused_notify(p, reason)
      return
    end
    -- G2/G3: every panel — including session-less — must hit review_open / pending.
    local arbitration = renewal.blocked(p)
    if arbitration then
      if arbitration.code == "turn_in_flight" then
        mode_change_refused_notify(p, "in_flight")
        return
      end
      local why = renewal.blocked_reason(p) or arbitration.condition
      notify_one_line("yana: cannot switch mode — " .. tostring(why), vim.log.levels.WARN)
      return
    end
    local nextmode = renewal.next_mode(config.options.mode)
    local from_mode = config.options.mode
    local from_session = p.session_id
    remember_seat_session(p)
    config.options.mode = nextmode
    p.mode = nextmode
    restore_seat_session(p, nextmode)
    log.lifecycle("mode.switch", {
      panel = p.id,
      from = from_mode,
      to = nextmode,
      session = from_session,
      from_session = from_session,
      to_session = p.session_id,
      from_seat = seat_of(from_mode, config.options.backend),
      to_seat = seat_of(nextmode, config.options.backend),
    })
    update_winbar(p)
    notify_one_line("yana: mode → " .. p.mode, vim.log.levels.INFO)
  end

  -- Set a panel's mode programmatically (entry-point maps that imply a mode, e.g.
  -- an ask map vs an edit map). Subject to the same per-chat lock as the <M-t>
  -- toggle: callers must go through here rather than assigning p.mode, so the
  -- lock cannot be bypassed by a caller outside the plugin.
  -- Returns true when the panel is in `mode` on return, false when refused.
  local function set_mode(p, mode)
    p = p or current_panel()
    if not p then
      return false
    end
    -- A mode missing from config.modes cannot be entered.
    if config.mode_enabled(mode) == false then
      notify_one_line("yana: mode " .. tostring(mode) .. " is not in config.modes", vim.log.levels.WARN)
      return false
    end
    local want = config.resolve_mode(mode)
    if config.resolve_mode(p.mode) == want then
      p.mode = want
      config.options.mode = want
      restore_seat_session(p, want)
      update_winbar(p)
      return true
    end
    local blocked, reason = mode_change_blocked(p)
    if blocked then
      mode_change_refused_notify(p, reason)
      update_winbar(p)
      return false
    end
    local arbitration = renewal.blocked(p)
    if arbitration then
      if arbitration.code == "turn_in_flight" then
        mode_change_refused_notify(p, "in_flight")
      else
        local why = renewal.blocked_reason(p) or arbitration.condition
        notify_one_line("yana: cannot switch mode — " .. tostring(why), vim.log.levels.WARN)
      end
      update_winbar(p)
      return false
    end
    remember_seat_session(p)
    p.mode = want
    config.options.mode = want
    restore_seat_session(p, want)
    update_winbar(p)
    return true
  end

  -- Whether `p` can currently produce an EDIT at all -- true for "inline" and
  -- "agentic", false for "ask" (which only reads and answers). This is the
  -- question a view like `:YanaEdit` actually needs answered, and answering
  -- it must never itself pick a confinement level: only `M.set_mode` (behind
  -- the documented `<M-t>` toggle / `M.resend({ where = "agentic" })`) may
  -- assign `config.options.mode`.
  --
  -- This replaces `inline_edit`'s old `M.set_mode(p, "agent")` call: "agent" was never
  -- a real mode, it was resolve_mode's alias for "agentic" (config.lua, now removed),
  -- so a fresh panel already sitting in the operator's configured `inline` mode got
  -- silently promoted to unconfined `agentic` on its very first turn. A fresh panel is
  -- already write-capable when the configured mode is not "ask" -- `create_panel` seeds
  -- `p.mode` from `config.options.mode` (`config.panel_mode(nil)`) -- so the fix here
  local function panel_write_capable(p)
    p = p or current_panel()
    if not p then
      return false
    end
    return config.resolve_mode(p.mode) ~= "ask"
  end

  -- Normalize the panel's mode in place without widening a locked chat.
  local function ensure_agent_mode(p)
    p = p or current_panel()
    if not p then
      return
    end
    -- Never widens a locked chat: resolve_mode only normalises what is already
    -- set, and the lock is enforced at the one place that changes it (set_mode).
    p.mode = config.resolve_mode(p.mode)
    config.options.mode = p.mode
    update_winbar(p)
  end

  return {
    seat_of = seat_of,
    mode_change_blocked = mode_change_blocked,
    remember_seat_session = remember_seat_session,
    restore_seat_session = restore_seat_session,
    renewal_blocked_reason = renewal_blocked_reason,
    build_apply_resend = build_apply_resend,
    renewal_brief = renewal_brief,
    seat_shared_context = seat_shared_context,
    mode_change_refused_notify = mode_change_refused_notify,
    reconcile_pending = reconcile_pending,
    toggle_mode = toggle_mode,
    set_mode = set_mode,
    panel_write_capable = panel_write_capable,
    ensure_agent_mode = ensure_agent_mode,
  }
end

return M
