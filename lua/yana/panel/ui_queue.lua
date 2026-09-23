-- Cancel / stop / steer + queue view. `steer` calls back into ui_submit via S.submit_panel, resolved at CALL time.
local config = require("yana.config")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local agent = require("yana.agent.agent")
local log = require("yana.log")
local views = require("yana.panel.ui_panel_views")
local uv = vim.uv or vim.loop

local M = {}

-- deps.state = parent S (S.render_note, S.submit_panel); deps.panel_open is unused on purpose; the rest are the parent's bookkeeping locals.
function M.new(deps)
  local S = deps.state
  local buf_valid = deps.buf_valid
  local win_valid = deps.win_valid
  local current_panel = deps.current_panel
  local update_winbar = deps.update_winbar
  local stop_spinner = deps.stop_spinner
  local liveness_for = deps.liveness_for
  local stall_threshold_ms = deps.stall_threshold_ms

-- Overwrites the prompt buffer (empty or an unsent draft at cancel time); returning the queue takes priority.
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
  local pwin = views.prompt(p)
  if win_valid(pwin) then
    pcall(vim.api.nvim_win_set_cursor, pwin, { 1, 0 })
  end
end

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

-- Fold pending_redirect (first) and the queue back into the prompt buffer and clear both; shared by
-- cancel_inflight's cancel path and its awaiting_exit disarm branch. True if anything was folded.
local function fold_pending_to_prompt(p)
  local items = {}
  if p.pending_redirect then
    table.insert(items, p.pending_redirect)
    p.pending_redirect = nil
  end
  if p.steer_pending and p.steer_pending.text then
    table.insert(items, p.steer_pending.text)
    p.steer_pending = nil
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

-- Cancel in-flight job. Bump turn_gen so stale on_event/on_done no-op; clear busy now (stop cannot wait
-- for on_done). opts.keep_queue: interrupt-and-steer cancels only to resubmit; the queue keeps waiting.
local function cancel_inflight(p, opts)
  if not p or not p.job then
    return false
  end
  opts = opts or {}
  if p.awaiting_exit then
    -- A previous cancel already holds the spawn barrier and escalation timers; only DISARM a pending redirect/queue.
    if not opts.keep_queue and (p.pending_redirect or #p.queue > 0) then
      fold_pending_to_prompt(p)
      return true
    end
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
  agent.stop(p.job, nil, stop_extra)
  -- p.job is NOT cleared: jobstop only SENDS SIGTERM; the spawn barrier stays up until on_exit_confirmed
  -- OBSERVES the exit (see schedule_exit_escalation).
  p.awaiting_exit = true
  schedule_exit_escalation(p, p.job_spawn_gen)
  p.busy = false
  p.active_turn_scope = nil
  -- A deliberate cancel must not auto-fire queued follow-ups; the queue is handed back to the prompt buffer,
  -- never dropped (same path as new_chat).
  if not opts.keep_queue then
    fold_pending_to_prompt(p)
  end
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

-- Any pre-existing queue is untouched. An idle panel degrades to a normal submit so the key is never a dead end.
  local function steer_text(p, text, opts)
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
    p.pending_redirect = text
    take_prompt()
    if not p.session_id or p.session_id == "" then
      notify_one_line(
        "yana: steering before session init — the redirect starts a fresh session (previous context not resumable)",
        vim.log.levels.WARN
      )
    end
    if cancel_inflight(p, { keep_queue = true, reason = "redirect" }) then
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

-- queue: view / edit / delete / reorder

local function queue_preview(text)
  local first = vim.split(text, "\n", { plain = true })[1] or ""
  if #first > 60 then
    first = first:sub(1, 59) .. "…"
  end
  return first
end

-- Move item `idx` into the prompt buffer for editing; existing unsent text is kept after it (draft not clobbered).
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
  local pwin = views.prompt(p)
  if win_valid(pwin) then
    pcall(vim.api.nvim_win_set_cursor, pwin, { 1, 0 })
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
local function pick_queue()
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
      -- The queue can change between the two selects; bail rather than act on a wrong index.
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


  return {
    cancel_inflight = cancel_inflight,
    stop = stop,
    steer = steer,
    pick_queue = pick_queue,
  }
end

return M
