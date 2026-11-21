-- Stop a running job or redirect its conversation when exit is confirmed.
local config = require("yana.config")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local agent = require("yana.agent.agent")
local log = require("yana.log")
local restore_prompt = require("yana.panel.ui_followup").restore_prompt
local uv = vim.uv or vim.loop

local M = {}

-- deps.state = parent S (S.render_note, S.submit_panel); deps.panel_open is unused on purpose; the rest are the parent's bookkeeping locals.
function M.new(deps)
  local S = deps.state
  local buf_valid = deps.buf_valid
  local current_panel = deps.current_panel
  local update_winbar = deps.update_winbar
  local stop_spinner = deps.stop_spinner
  local liveness_for = deps.liveness_for
  local stall_threshold_ms = deps.stall_threshold_ms

-- jobstop only SENDS SIGTERM. Escalate to SIGKILL after confirm_exit_timeout_ms; if it still won't die after
-- kill_grace_ms abort any pending redirect (text back to the prompt) and keep the spawn barrier up: never
-- start a second process alongside a live one. Timers self-cancel via the job_spawn_gen token.
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
          if not p.finish_quit then
            p.pending_redirect = nil
            if text and text ~= "" then
              restore_prompt(p, text)
            end
          end
          update_winbar(p)
          local message = p.finish_quit and "yana: Quit is still waiting for the agent to stop"
            or (text and text ~= "" and "yana: agent exit unconfirmed; redirect cancelled"
              or "yana: agent exit unconfirmed")
          notify_one_line(message, vim.log.levels.ERROR)
        end)
      end, o.kill_grace_ms)
    end)
  end, o.confirm_exit_timeout_ms)
end

local function return_submission(p)
  local handover = p.prompt_handover
  local text = p.pending_redirect or (handover and handover.text)
  p.pending_redirect, p.prompt_handover = nil, nil
  if not text then return false end
  if handover and not p.pending_selection then p.pending_selection = handover.selection end
  restore_prompt(p, text)
  update_winbar(p)
  notify_one_line("yana: stopped — prompt returned to input", vim.log.levels.WARN)
  return true
end

-- Cancel in-flight job. Bump turn_gen so stale on_event/on_done no-op; clear busy now (stop cannot wait
-- for on_done). A redirect keeps its replacement prompt until exit is confirmed.
local function cancel_inflight(p, opts)
  if not p or not p.job then
    return false
  end
  opts = opts or {}
  if p.awaiting_exit then
    if not opts.redirect and not p.finish_quit then return return_submission(p) end
    return false
  end
  local live = liveness_for(p)
  local now = uv.hrtime()
  local quiet = math.floor((now - (live.last_event_hr or live.started_hr)) / 1e6)
  local ast = agent.status(p.job) or {}
  local stalled = quiet >= stall_threshold_ms() and (tonumber(ast.cpu_pct) or 0) <= 0.1
  local stop_extra = nil
  if stalled and p.shadow_turn and p.shadow_turn.private_dir then
    local dir, verdict = require("yana.forensics").snapshot({
      private_dir = p.shadow_turn.private_dir,
      pid = ast.pid or agent.pid(p.job),
      cwd = p.cwd,
      turn_id = p.turn_pass and p.turn_pass.turn_id or nil,
      duration_ms = math.floor((now - live.started_hr) / 1e6),
      last_event = live.last_event,
      cpu_pct_at_stop = tonumber(ast.cpu_pct) or 0,
    })
    live.forensics = { path = dir, verdict = verdict }
    stop_extra = {
      cpu_pct_at_stop = tonumber(ast.cpu_pct) or 0,
      stall_cause = verdict and (verdict.code .. " " .. verdict.cause) or nil,
      forensics_path = dir,
    }
  end
  p.cancelled = true
  p.turn_gen = p.turn_gen + 1
  agent.stop(p.job, p.finish_quit and "chat quit" or nil, stop_extra)
  -- p.job is NOT cleared: jobstop only SENDS SIGTERM; the spawn barrier stays up until on_exit_confirmed
  -- OBSERVES the exit (see schedule_exit_escalation).
  p.awaiting_exit = true
  schedule_exit_escalation(p, p.job_spawn_gen)
  p.busy = false
  if not opts.redirect and not p.finish_quit then return_submission(p) end
  stop_spinner(p)
  update_winbar(p)
  return true
end

-- Stop entry point for every NON-key surface (`/stop`, <leader>aS): unlike the <C-c> hook it does not depend on
-- the tracked focus, so it works from a code buffer. A no-op is reported, not swallowed (silence looks like a
-- dead key); cancel_inflight is false with no job or when a cancel is already awaiting exit.
local function stop()
  local p = current_panel()
  if cancel_inflight(p) then
    S.render_note(p, "⏹ stopped")
    return
  end
  if p and p.awaiting_exit then
    notify_one_line("yana: already stopping — waiting for the agent to exit", vim.log.levels.INFO)
  else
    notify_one_line("yana: nothing to stop (no turn in flight)", vim.log.levels.INFO)
  end
end

-- An idle panel treats redirect as a normal submit.
  local function steer_text(p, text, opts)
    if p.finish_quit then return false end
    opts = opts or {}
    local function take_prompt()
      if opts.take_prompt and buf_valid(p.prompt_buf) then
        vim.bo[p.prompt_buf].modifiable = true
        vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })
      end
    end

    if p.awaiting_exit then
      -- Second steer while the first cancel is still waiting: last-wins (I4).
      p.pending_redirect = text
    take_prompt()
    notify_one_line("yana: redirect updated — waiting for the previous process to exit", vim.log.levels.INFO)
    return
  end
  if p.job then
    take_prompt()
    local handover = p.prompt_handover
    if handover then
      p.prompt_handover = nil
      restore_prompt(p, handover.text)
    end
    p.pending_redirect = text
    if not p.session_id or p.session_id == "" then
      notify_one_line(
        "yana: steering before session init — the redirect starts a fresh session (previous context not resumable)",
        vim.log.levels.WARN
      )
    end
    if cancel_inflight(p, { redirect = true }) then
      S.render_note(p, opts.note or "⏹ interrupted to steer — waiting for the previous process to exit")
    end
    return
  end
  if opts.take_prompt then
    S.submit_panel(p) -- idle: plain submit, key is never a dead end
  else
    S.submit_panel(p, { text = text, redirect = true })
  end
end

S.steer_text = steer_text

  local function steer()
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
    steer_text(p, text, { take_prompt = true })
  end

  return {
    cancel_inflight = cancel_inflight,
    stop = stop,
    steer = steer,
  }
end

return M
