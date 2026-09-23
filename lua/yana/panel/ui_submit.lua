-- Submit + resend. Queue/steer/cancel live in yana.ui_queue, which calls submit_panel back.
-- Every turn and event callback arrives by name, so who answers a turn is decided where
-- this service is built.
local config = require("yana.config")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local sessions = require("yana.runtime.sessions")
local context = require("yana.input.context")
local selection_scope = require("yana.input.selection_scope")
local ledger = require("yana.ledger")
local agent = require("yana.agent.agent")
local log = require("yana.log")
local steer_channel = require("yana.agent.steer_channel")
local uv = vim.uv or vim.loop
local renewal = require("yana.agent.renewal")

local function preview_module()
  return require("yana.shadow.preview")
end

local function consume_next_launch_flags()
  local flags = vim.g.yana_next_launch_flags
  vim.g.yana_next_launch_flags = nil
  if type(flags) ~= "table" then
    return {}
  end
  return vim.deepcopy(flags)
end

-- Session failures the client never recovers from itself (yanad ensure() autostarts only when the
-- socket is absent/refused). Value = operator action.
local FINAL_SESSION_REFUSALS = {
  no_daemon = "start yanad",
  version_mismatch = "upgrade the daemon to this plugin's version",
  identity_mismatch = "the running daemon belongs to another user; start your own",
}

local M = {}

-- TEST SEAM: called on every submit_panel entry BEFORE any guard (guards swallow duplicate submits,
-- so a counter at agent.run would miss them).
M._test = M._test or {}
M._test.on_submit_panel = nil

-- Every dependency this service needs, by name. Building it one short is refused here,
-- where the map is written, rather than failing later inside a turn.
local REQUIRED = {
  "focus", "finalize_shadow_turn", "render_note", "steer_text",
  "on_event", "set_model_actual", "on_done", "on_exit_confirmed",
  "panels", "panel_open", "panel_open_in", "buf_valid", "current_panel", "update_winbar",
  "render_user", "start_assistant_block", "start_spinner", "stop_spinner", "render_error",
  "seat_shared_context", "expand_attachments", "M",
}

-- deps.M is the parent's own module table, looked up at call time.
function M.new(deps)
  for _, name in ipairs(REQUIRED) do
    if deps == nil or deps[name] == nil then
      error("yana.panel.ui_submit.new: missing dependency " .. name, 0)
    end
  end
  local focus = deps.focus
  local finalize_shadow_turn = deps.finalize_shadow_turn
  local render_note = deps.render_note
  local steer_text = deps.steer_text
  local on_event = deps.on_event
  local set_model_actual = deps.set_model_actual
  local on_done = deps.on_done
  local on_exit_confirmed = deps.on_exit_confirmed
  local ui_M = deps.M
  local panel_open = deps.panel_open
  local buf_valid = deps.buf_valid
  local current_panel = deps.current_panel
  local panels = deps.panels
  local update_winbar = deps.update_winbar
  local render_user = deps.render_user
  local start_assistant_block = deps.start_assistant_block
  local start_spinner = deps.start_spinner
  local stop_spinner = deps.stop_spinner
  local render_error = deps.render_error
  local seat_shared_context = deps.seat_shared_context
  local expand_attachments = deps.expand_attachments

----------------------------------------------------------------------
-- submit
----------------------------------------------------------------------

-- Park a submit made before the panel has a daemon session; text captured now, kept in submit order
-- in p.yanad_submit_queue. False when there is nothing to send.
  local function park_submit(p, opts)
    local text = opts.text
    if text == nil then
      local lines = vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false)
      text = vim.trim(table.concat(lines, "\n"))
      if text == "" then
        return false
      end
      vim.bo[p.prompt_buf].modifiable = true
      vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })
    end
    p.yanad_submit_queue = p.yanad_submit_queue or {}
    table.insert(p.yanad_submit_queue, text)
    update_winbar(p)
    return true
  end

-- opts.text: submit this text instead of the prompt buffer (queue drain).
  local function submit_panel(p, opts)
    if M._test.on_submit_panel then
      M._test.on_submit_panel(p, opts)
    end
    if not panel_open(p) then
      return
    end
  opts = opts or {}

  if config.overlay_mode() and not p.yanad_session_id then
    if p.yanad_session_pending then
      if park_submit(p, opts) then
        notify_one_line("yana: daemon session starting — turn queued", vim.log.levels.INFO)
      end
    else
      -- Not pending, no session id: the last session.create answered and failed (e.g. 5 s client timeout).
      -- Park the turn and re-issue, only on a user submit (no background retry loop; an idle editor must
      -- not hammer the daemon). The lifecycle callback takes the whole queue BEFORE re-submitting, so no
      -- parked submit fires twice.
      park_submit(p, opts)
      -- Name the cause: no_daemon/version_mismatch/identity_mismatch are not transient (ERROR + instruction);
      -- anything else (timeout under load) is INFO.
      local err = tostring(p.yanad_session_err or "session.create failed")
      if FINAL_SESSION_REFUSALS[err] then
        notify_one_line(
          "yana: daemon session refused (" .. err .. ") — " .. FINAL_SESSION_REFUSALS[err] .. "; turn queued",
          vim.log.levels.ERROR
        )
      else
        notify_one_line("yana: daemon session retrying after " .. err .. " — turn queued", vim.log.levels.INFO)
      end
      -- The panel's door onto its daemon session (replaced by yanad_recover for a kept session).
      -- Unguarded on purpose: absence is a construction bug that must be seen.
      p.yanad_start_session(p)
    end
    return
  end

  local question
  if opts.text then
    question = vim.trim(opts.text)
  else
    -- Spawn barrier: one process per panel; a live or awaiting-exit turn queues instead.
    if p.busy or p.job ~= nil or p.awaiting_exit then
      local lines = vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false)
      local queued_text = vim.trim(table.concat(lines, "\n"))
      if queued_text == "" then
        if p.steer_pending and p.steer_pending.at == "tool_boundary" then
          -- Submit #3 sends now.
          p.steer_pending.at = "now"
          notify_one_line("yana: interrupting — sending now", vim.log.levels.INFO)
          if p.steer_channel_active == "stream-json" then
            vim.api.nvim_create_autocmd("SafeState", {
              once = true,
              callback = function()
                if not p
                  or not p.steer_pending
                  or p.steer_pending.at ~= "now"
                  or p.steer_channel_active ~= "stream-json"
                  or not p.job
                then
                  return
                end
                -- Submit #3 sends after the keyfeed unwinds.
                local text = p.steer_pending.text
                if steer_channel.deliver(p, text, { interrupt = true }) then
                  render_user(p, text)
                  render_note(p, "⏸ interrupted — sending your message")
                  start_assistant_block(p)
                  update_winbar(p)
                end
              end,
            })
          elseif steer_text then
            local backend = p.turn_backends[p.turn_gen] or config.options.backend or "cursor"
            notify_one_line(
              string.format("yana: %s lacks an in-turn channel — restarting now", backend),
              vim.log.levels.INFO
            )
            local text = p.steer_pending.text
            p.steer_pending = nil
            steer_text(p, text, { note = "⏹ interrupted to steer — waiting for the previous process to exit" })
          end
          update_winbar(p)
        elseif #p.queue > 0 then
          -- Submit #2 promotes the queue tail.
          local text = table.remove(p.queue)
          p.steer_pending = { text = text, at = "tool_boundary", armed_hr = uv.hrtime() }
          if p.steer_channel_active == "stream-json" then
            notify_one_line(
              "yana: promoted — sends at the end of the current tool call (press again to send now)",
              vim.log.levels.INFO
            )
          else
            local backend = p.turn_backends[p.turn_gen] or config.options.backend or "cursor"
            notify_one_line(
              string.format(
                "yana: %s lacks an in-turn channel — restart at next tool boundary",
                backend
              ),
              vim.log.levels.INFO
            )
          end
          update_winbar(p)
        else
          notify_one_line("yana: still responding (use stop to cancel)", vim.log.levels.WARN)
        end
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

    -- CLI-parity: a known first-line /command dispatches its callback; cb(nil) = handled locally,
    -- cb(text) rewrites the prompt. An unknown /foo is sent verbatim.
    local first_line = vim.split(question, "\n", { plain = true })[1] or ""
    local cmd_name, cmd_args = first_line:match("^/(%S+)%s*(.*)$")
    local dispatch = cmd_name and require("yana.commands").find(p, cmd_name) or nil

    if dispatch then
      -- Everything typed except the `/name` token, by byte offset off `question` (one definition of user text).
      local user_text = vim.trim(question:sub(#("/" .. cmd_name) + 1))
      local got_result, result = false, nil
      -- `args` stays the line-1 remainder (commands.lua contract).
      local ok, err = xpcall(function()
        return dispatch.callback(p, cmd_args, function(text)
          got_result = true
          result = text
        end)
      end, function(e)
        return tostring(e) .. "\n" .. debug.traceback("", 2)
      end)
      if not ok then
        -- Throwing callback: log + WARN; prompt buffer untouched so typed text is never lost.
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
      -- Rewrite kind: body is a preamble, user text the task: body first, user text second. Composed here, not per callback.
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
    local extracted = require("yana.input.mentions").extract_mentions(question)
    question = extracted.new_content
    p.pending_enable_diagnostics = extracted.enable_diagnostics
  end
  local descriptor = config.backend_descriptor(config.options.backend) or {}
  local agent_question, attachments = expand_attachments(p, question, {
    expand_paths = descriptor.image_flag == nil,
  })

  -- Changed-mind prompt (mode contract 3): a pointer to earlier context. The referent must be supplied
  -- (resumable session or staged brief) or the submit REFUSES naming what is missing; typed text stays.
  local gap = renewal.changed_mind_gap(p, question)
  if gap then
    notify_one_line("yana: " .. gap.condition .. " — " .. gap.action, vim.log.levels.WARN)
    if buf_valid(p.prompt_buf) then
      local cur = vim.trim(table.concat(vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false), "\n"))
      if cur == "" then
        vim.bo[p.prompt_buf].modifiable = true
        vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, vim.split(question, "\n", { plain = true }))
      end
    end
    return
  end


  -- opts.text callers believed the barrier clear; re-check (a race must never spawn a second process).
  -- Head insert keeps FIFO.
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

  focus:set_last(p)

  local exclude = {}
  for _, q in ipairs(panels) do
    if q.conv_buf then exclude[q.conv_buf] = true end
    if q.prompt_buf then exclude[q.prompt_buf] = true end
  end
  local origin = context.current_origin(exclude)
  local selection = p.pending_selection
  p.pending_selection = nil
  if not selection and config.panel_mode(p.mode) == "inline" and origin and origin.buf then
    local capture, capture_err = require("yana.input.home_buffer_proposal").capture(origin.buf)
    if capture_err then
      notify_one_line("yana: " .. capture_err, vim.log.levels.WARN)
      return
    end
    if capture then
      selection = context.selection_from_range(origin.buf, 1, vim.api.nvim_buf_line_count(origin.buf))
      selection.home_buffer_capture = capture
    end
  end
  p.scope_rejections = {}
  p.review_rejections = {}

  log.buffer_event("submit", { panel_id = p.id, generation = p.turn_gen + 1,
    cwd = vim.fn.getcwd(), bufnr = selection and selection.buf or (origin and origin.buf), selection = selection })
  if selection and selection.buf and vim.api.nvim_buf_is_valid(selection.buf) then
    selection.scope = selection_scope.compute(selection.buf, selection)
    p.active_turn_scope = selection.scope
  else
    p.active_turn_scope = nil
  end

  local enable_diagnostics = p.pending_enable_diagnostics
  p.pending_enable_diagnostics = nil
  local built = context.build(
    agent_question,
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

  -- Mode switch ended the upstream session: carry context so the agent does not silently forget.
  local carried, carried_brief, carried_state = renewal.consume(p)
  if carried then
    built.prompt = "[Context carried from the earlier part of this conversation, which ran in a different mode]\n"
      .. carried
      .. "\n\n"
      .. built.prompt
  elseif carried_state == "stale" then
    -- Dropped, and SAID so.
    log.write(
      "WARN",
      "yana: a staged renewal brief did not belong to this conversation and was dropped (panel "
        .. tostring(carried_brief and carried_brief.panel_id)
        .. ")"
    )
  else
      local decision_brief = renewal.build(p, config.panel_mode(p.mode), config.panel_mode(p.mode))
      if decision_brief and decision_brief.decision_note then
        built.prompt = decision_brief.decision_note .. "\n\n" .. built.prompt
      end
      local shared = seat_shared_context(p)
      if shared then
        built.prompt = shared .. "\n\n" .. built.prompt
    end
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
  -- Allocate the one durable identity before confinement. Preview, recorder,
  -- lifecycle and recovery must name the same turn even across editor processes.
  local lifecycle = require("yana.turn.turn_lifecycle")
  local turn_id = lifecycle.new_turn_id(p.id, gen)
  local L = ledger.begin_turn(p.id, gen, {
    panel_id = p.id,
    session_id = p.session_id,
    mode = config.panel_mode(p.mode),
    model = config.options.model,
    backend = config.options.backend,
    cwd = p.cwd,
    redirect = opts.redirect and true or false,
    queued = #p.queue,
    prompt_bytes = #agent_question,
    title = p.title,
    turn_id = turn_id,
    attachments = vim.deepcopy(attachments),
  })
  p.turn_scopes[gen] = (selection and selection.scope) or false
  p.turn_home_buffer_captures = p.turn_home_buffer_captures or {}
  p.turn_home_buffer_captures[gen] = selection and selection.home_buffer_capture or nil
  p.turn_modes[gen] = config.panel_mode(p.mode)
  p.turn_backends[gen] = config.options.backend or "cursor"
  p.steer_channel_active = (config.backend_descriptor(p.turn_backends[gen]) or {}).steer_channel
  p.turn_questions[gen] = question
  p.turn_attachments = p.turn_attachments or {}
  p.turn_attachments[gen] = vim.deepcopy(attachments)
  p.turn_answers[gen] = nil
  p.turn_end_outcome[gen] = nil
  p.turn_end_emitted[gen] = nil
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
      cwd = p.cwd,
      selection = selection,
      origin = origin,
      launch_flags = consume_next_launch_flags(),
      stream = p.session_id or ("panel-" .. tostring(p.conv_buf)),
      session_id = p.session_id,
      turn_id = turn_id,
      turn_gen = gen,
      panel_id = p.id,
      mode = p.turn_modes[gen],
      yanad_session_id = p.yanad_session_id,
      read_only_workspace = selection and selection.home_buffer_capture ~= nil,
    })
    if not turn then
      log.buffer_event("launch_failed", { panel_id = p.id, generation = gen, turn_id = turn_id, reason = perr })
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
    update_winbar(p)
  end
  -- Open the lifecycle pass: durable id + owning tuple, explicitly NOT actionable until walked and classified.
  p.turn_pass = lifecycle.begin_turn({
    panel_id = p.id,
    generation = gen,
    stream = p.session_id or ("panel-" .. tostring(p.conv_buf)),
    session_id = p.session_id,
    workspace = p.shadow_turn and p.shadow_turn.workspace or p.cwd,
    state_dir = p.shadow_turn and p.shadow_turn.turn_dir or lifecycle.state_dir(),
    tracked_evidence = lifecycle.capture_tracked_evidence(
      p.shadow_turn and p.shadow_turn.workspace or p.cwd
    ),
    turn_id = turn_id,
  })
  log.buffer_event("launch", { panel_id = p.id, generation = gen, turn_id = turn_id,
    cwd = p.cwd, bufnr = selection and selection.buf or (origin and origin.buf), selection = selection })
  p.job = agent.run({
    prompt = built.prompt,
    images = attachments,
    mode = config.agent_permission_mode(p.mode),
    -- YANA dial value, distinct from the vendor permission-mode above.
    yana_mode = p.turn_modes[gen],
    model = config.options.model,
    session_id = p.session_id,
    cwd = p.cwd,
    jail_session = p.shadow_turn,
    panel_id = p.id,
    turn_gen = gen,
    turn_id = turn_id,
    steer_enabled = true,
    spawn_reason = opts.redirect and "redirect" or (opts.text and "queue_drain" or "submit"),
    on_event = function(obj)
      on_event(p, gen, obj)
    end,
    on_model_actual = function(model)
      set_model_actual(p, gen, model)
    end,
    on_done = function(code, stderr, agent_outcome)
      on_done(p, gen, code, stderr, agent_outcome)
    end,
    on_exit_confirmed = function(code)
      on_exit_confirmed(p, gen, code)
    end,
  })
  if p.job and steer_channel.can_steer(config.backend_descriptor(p.turn_backends[gen])) then
    steer_channel.open(p, p.job, built.prompt)
  end
  if not p.job then
    log.buffer_event("launch_failed", { panel_id = p.id, generation = gen, turn_id = turn_id, reason = "agent did not start" })
    p.job_spawn_gen = nil
    -- The overlay never ran, so it never took a claim; nothing to release.
    if p.shadow_turn then
      preview_module().discard(p.shadow_turn)
      p.shadow_turn = nil
    end
  end
end

-- Submit the current panel's prompt buffer as a new turn.
local function submit()
  local p = current_panel()
  if p then
    submit_panel(p)
  end
end
----------------------------------------------------------------------
-- resend
----------------------------------------------------------------------

-- Resubmit the last prompt. where: "here" = same chat/session/mode; "new" = fresh chat, mode carried.
-- Prompt is read BEFORE new_chat clears it.
local function resend(opts)
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
  ui_M.new_chat()
  p = current_panel() or p
  if where == "agent" then
    -- Unlocked by new_chat, so this cannot be refused; assert rather than hope.
    if not ui_M.set_mode(p, "agentic") then
      notify_one_line("yana: could not switch the new chat to agent mode", vim.log.levels.ERROR)
      return false
    end
  else
    ui_M.set_mode(p, carried)
  end
  render_note(p, "resent in a new chat — " .. config.panel_mode(p.mode) .. " mode, fresh session")
  submit_panel(p, { text = question })
  if where == "agent" then
    p.ask_advice_resend = nil
  end
  return true
end


  return {
    submit_panel = submit_panel,
    submit = submit,
    resend = resend,
  }
end

return M
