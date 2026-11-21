-- Submit and resend. Redirect and stop are owned by the run controls.
-- Every turn and event callback arrives by name, so who answers a turn is decided where
-- this service is built.
local config = require("yana.config")
local prompts = require("yana.prompts")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local sessions = require("yana.runtime.sessions")
local context = require("yana.input.context")
local ledger = require("yana.ledger")
local agent = require("yana.agent.agent")
local log = require("yana.log")
local steer_channel = require("yana.agent.steer_channel")
local uv = vim.uv or vim.loop
local renewal = require("yana.agent.renewal")
local conversation = require("yana.panel.conversation")

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

  local function clear_prompt(p)
    vim.bo[p.prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })
  end

  local function hold_handover(p, text)
    p.prompt_handover = { text = text, selection = p.pending_selection }
    p.pending_selection = nil
    notify_one_line("yana: prompt will start when this result is ready", vim.log.levels.INFO)
  end

  local function submit_during_run(p, text, from_prompt)
    if p.awaiting_exit then
      notify_one_line("yana: waiting for the agent to stop", vim.log.levels.INFO)
    elseif p.got_result then
      if text ~= "" then
        hold_handover(p, text)
        if from_prompt then clear_prompt(p) end
        return true
      end
    elseif conversation.can_steer(p) then
      if text ~= "" then
        local mentions = require("yana.input.mentions").extract_mentions(text)
        local agent_text = expand_attachments(p, mentions.new_content, { expand_paths = true })
        local built = context.build(agent_text, context.current_origin(), p.pending_selection, {
          mode = config.panel_mode(p.mode), announce_mode = false, announce_file = false,
          enable_diagnostics = mentions.enable_diagnostics,
        })
        local id, reason = conversation.deliver(p, built.prompt)
        if not id then
          notify_one_line("yana: prompt was not sent (" .. reason .. ")", vim.log.levels.WARN)
          return
        end
        if from_prompt then clear_prompt(p) end
        p.pending_selection = nil
        p.last_question = text
        render_user(p, text, built.label)
        start_assistant_block(p)
        return true
      else
        local input = conversation.last_input(p)
        if input and input.steered and not input.acknowledged and not input.interrupting then
          local id, reason = conversation.interrupt(p, nil)
          if id then
            p.prompt_interrupt_id = id
            render_note(p, "⏸ interrupted", true)
          else
            notify_one_line("yana: interrupt failed (" .. reason .. ")", vim.log.levels.WARN)
          end
        else
          notify_one_line("yana: still responding (use stop to cancel)", vim.log.levels.WARN)
        end
      end
    elseif text == "" then
      notify_one_line("yana: still responding (use stop to cancel)", vim.log.levels.WARN)
    else
      -- The draft stays in the prompt. Track the job and buffer version only.
      local tick = vim.api.nvim_buf_get_changedtick(p.prompt_buf)
      local offer = p.interrupt_offer
      if from_prompt and offer and offer.job == p.job and offer.tick == tick then
        local ok, reason = conversation.interrupt(p, text, function(prompt, session, job)
          if p.job ~= job or p.session_id ~= session then
            return nil, "run_changed"
          end
          return steer_text(p, prompt, { take_prompt = true }) ~= false
        end)
        if not ok then
          notify_one_line("yana: interrupt failed (" .. reason .. ")", vim.log.levels.WARN)
        end
      else
        if from_prompt then p.interrupt_offer = { job = p.job, tick = tick } end
        local backend = (p.turn_backends or {})[p.job_spawn_gen or p.turn_gen] or config.options.backend
        notify_one_line("yana: " .. backend .. " cannot take a prompt mid-run. Press submit again to interrupt.",
          vim.log.levels.INFO)
      end
    end
  end

-- opts.text supplies text from a caller such as the redirect or End continuation.
  local function submit_panel(p, opts)
    if p.finish_quit then return end
    if M._test.on_submit_panel then
      M._test.on_submit_panel(p, opts)
    end
    if not panel_open(p) then
      return
    end
  opts = opts or {}

  local yana_mode = config.panel_mode(p.mode)
  local backend_name = config.options.backend
  local protected = yana_mode == "inline" or yana_mode == "ask"
  local inline_policy = protected
    and require("yana.configuration.config_backends").inline_mcp_route(config.backend_descriptor(backend_name), yana_mode)
  if protected and not inline_policy then
    render_error(p, ("yana: %s does not support MCP in %s mode"):format(backend_name, yana_mode))
    return
  end
  local inline_mcp = inline_policy and true or false

  if protected and not p.yanad_session_id then
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
      if err == "state_root_owned" then
        notify_one_line("yana: daemon session refused — " .. p.yanad_session_detail.message .. "; turn queued", vim.log.levels.ERROR)
      elseif FINAL_SESSION_REFUSALS[err] then
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

  local from_prompt = opts.text == nil
  local question = vim.trim(opts.text or table.concat(vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false), "\n"))
  if not p.end_closing then
    if p.prompt_handover then
      notify_one_line("yana: the submitted prompt is waiting for the prior result", vim.log.levels.INFO)
      return false
    end
    if p.busy or p.job ~= nil or p.awaiting_exit then
      return submit_during_run(p, question, from_prompt) == true
    end
  end
  if from_prompt then
    if question == "" then return end

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

  -- A confirmed End owns the review until its result, including a partial result.
  if p.end_closing then
    table.insert(p.end_closing.prompts, question)
    return
  end

  local submitted_question = question
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


  -- An existing review continues on the same mini-conversation.
  local owns_open_review = not opts.ordinary and (p.shadow_turn ~= nil or p.mcp_run ~= nil)
  local follow = owns_open_review and require("yana.panel.ui_followup").follow_up(p, question)
  if follow == "handover" then
    hold_handover(p, submitted_question)
    return
  end
  if follow and type(follow) ~= "table" then return end

  focus:set_last(p)

  local exclude = {}
  for _, q in ipairs(panels) do
    if q.conv_buf then exclude[q.conv_buf] = true end
    if q.prompt_buf then exclude[q.prompt_buf] = true end
  end
  local origin = context.current_origin(exclude)
  local selection
  if opts.handover then
    selection = opts.handover.selection
  else
    selection, p.pending_selection = p.pending_selection, nil
  end

  log.buffer_event("submit", { panel_id = p.id, generation = p.turn_gen + 1,
    cwd = vim.fn.getcwd(), bufnr = selection and selection.buf or (origin and origin.buf), selection = selection })

  local enable_diagnostics = p.pending_enable_diagnostics
  p.pending_enable_diagnostics = nil
  local owner = conversation.get(p)
  local mini = owner:activate(yana_mode, backend_name)
  local announce = owner:needs_mode_notice(mini, yana_mode)
  local built = context.build(
    agent_question,
    origin,
    selection,
    {
      mode = yana_mode,
      enable_diagnostics = enable_diagnostics,
      announce_mode = announce,
      announce_file = owner:needs_file_notice(mini, origin.name),
    }
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
    built.prompt = prompts.render("carried_context_header") .. "\n"
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

  if follow then built.prompt = follow.line .. "\n\n" .. built.prompt end -- F-ADDENDUM-MEMORY
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
  local turn_id = follow and follow.turn_id or lifecycle.new_turn_id(p.id, gen)
  local L = ledger.begin_turn(p.id, gen, {
    panel_id = p.id,
    session_id = p.session_id,
    mode = config.panel_mode(p.mode),
    model = config.options.model,
    backend = config.options.backend,
    cwd = p.cwd,
    redirect = opts.redirect and true or false,
    prompt_bytes = #agent_question,
    title = p.title,
    turn_id = turn_id,
    attachments = vim.deepcopy(attachments),
  })
  p.turn_modes[gen] = config.panel_mode(p.mode)
  p.turn_backends[gen] = backend_name
  p.interrupt_offer, p.prompt_interrupt_id = nil, nil
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
  if not follow then p.shadow_pass = nil end
  p.job_shadow_turn = nil
  if inline_mcp then
    p.turn_buffer_captures = p.turn_buffer_captures or {}
    local refusals = {}
    p.turn_buffer_captures[gen] = require("yana.input.submit_snapshot").take_snapshots({ "/" },
      selection and selection.buf or origin and origin.buf, refusals)
    local open_folder = follow and follow.prior.open_folder or require("yana.shadow.preview").workspace_candidate({
      cwd = p.cwd, selection = selection, origin = origin,
    })
    p.mcp_run = require("yana.runtime.mcp_inline").new({
      snapshots = p.turn_buffer_captures[gen], snapshot_refusals = refusals,
      workspace = p.cwd, open_folder = open_folder,
    })
    local run = p.mcp_run
    run.open_folder = open_folder
    run.stream = follow and follow.prior.stream or p.session_id or ("panel-" .. tostring(p.conv_buf))
    run.turn_id, run.turn_gen, run.mode = turn_id, gen, p.turn_modes[gen]
    run.yanad_session_id, run.source = p.yanad_session_id, "buffer"
    p.job_mcp_run = run
  end
  -- Open the lifecycle pass: durable id + owning tuple, explicitly NOT actionable until walked and classified.
  p.turn_pass = lifecycle.begin_turn({
    panel_id = p.id,
    generation = gen,
    stream = follow and follow.prior.stream or p.session_id or ("panel-" .. tostring(p.conv_buf)),
    session_id = p.session_id,
    workspace = p.cwd,
    state_dir = lifecycle.state_dir(),
    tracked_evidence = { paths = {} },
    turn_id = turn_id,
  })
  if inline_mcp then p.mcp_run.turn_pass, p.mcp_run.run_generation = p.turn_pass, gen end
  if follow and not require("yana.panel.ui_followup").begin_follow_up(p, follow, gen) then
    p.busy, p.job_spawn_gen, p.job_shadow_turn = false, nil, nil
    if p.job_mcp_run then p.job_mcp_run:close(); p.job_mcp_run = nil end
    require("yana.input.submit_snapshot").release_snapshots(p.turn_buffer_captures, gen)
    stop_spinner(p)
    ledger.close_turn(L, { exit_code = nil, confinement_failed = "follow-up input not captured" })
    update_winbar(p)
    return
  end
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
    jail_session = inline_mcp and { workspace = p.cwd, turn_id = turn_id, mode = p.turn_modes[gen],
      yanad_session_id = p.yanad_session_id, generation = gen, resume = follow and true or nil } or nil,
    inline_mcp = inline_mcp,
    inline_policy = inline_policy,
    mcp_context = inline_mcp and p.mcp_run or nil,
    mcp_input = inline_mcp and require("yana.turn.turn_cycle").recording_run(p.mcp_run) or nil,
    turn_pass = p.turn_pass,
    panel_id = p.id,
    turn_gen = gen,
    turn_id = turn_id,
    steer_enabled = true,
    spawn_reason = opts.redirect and "redirect" or (opts.text and "queue_drain" or "submit"),
    is_current = function()
      return not p.finish_quit and p.turn_gen == gen
        and type(p.conv_buf) == "number" and vim.api.nvim_buf_is_valid(p.conv_buf)
    end,
    on_event = function(obj)
      on_event(p, gen, obj, mini)
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
  local send_ok = true
  if p.job and conversation.can_steer(p) then
    send_ok = steer_channel.open(p, p.job, built.prompt) and true or false
  end
  if p.job and send_ok then
    owner:mark_sent(mini, p.turn_modes[gen])
    owner:mark_file(mini, built.file)
  end
  if not p.job then
    log.buffer_event("launch_failed", { panel_id = p.id, generation = gen, turn_id = turn_id, reason = "agent did not start" })
    p.job_spawn_gen = nil
    require("yana.input.submit_snapshot").release_snapshots(p.turn_buffer_captures, gen)
    if follow then
      require("yana.panel.ui_followup").drop_launch(p, follow)

    end
    local run = p.job_mcp_run
    if run then
      run:close()
      if p.mcp_run == run then p.mcp_run = nil end
      p.job_mcp_run = nil
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
