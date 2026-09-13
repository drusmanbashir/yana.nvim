-- Submit + resend, split out of yana.ui (cluster 7, submit half).
-- `cancel_inflight`/`stop`/`steer`/the queue view moved to the sibling `yana.ui_queue`
-- instead (the combined submit+queue+cancel cluster was ~830 lines, over the 700-line
-- ceiling on its own) -- `steer` there calls back into this module's `submit_panel` via
-- `S.submit_panel`, the same late-bound path everything else outside this file uses.
--
-- Cross-cluster calls into the not-yet-split turn/event state machine
-- (on_event, set_model_actual, on_done, on_exit_confirmed) go through the
-- late-bound registry `F` (deps.fn): ui.lua assigns `F.on_event = on_event`
-- etc. right after those functions are defined, so this module never needs
-- to require its own parent and extraction order stops mattering.
local config = require("yana.config")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local sessions = require("yana.sessions")
local context = require("yana.context")
local selection_scope = require("yana.selection_scope")
local ledger = require("yana.ledger")
local agent = require("yana.agent")
local log = require("yana.log")
local steer_channel = require("yana.steer_channel")
local uv = vim.uv or vim.loop
-- Duplicated from ui.lua (same reasoning as ui_modes.lua's own copy): the
-- changed-mind-gap / context-carry contract submit_panel enforces is
-- renewal.lua's, and requiring the same cached module twice is
-- side-effect-free.
local renewal = require("yana.renewal")

-- Trivial lazy-require wrapper, duplicated from ui.lua rather than threaded
-- through deps (same as ui_sessions.lua's identical copy): yana.shadow.preview
-- is required this same way at other call sites unrelated to submit.
local function preview_module()
  return require("yana.shadow.preview")
end

-- Daemon-session failures the client will NEVER recover from on its own:
-- yana.yanad's ensure() autostarts only when the socket is absent or refuses
-- the connection (:251-252), so a hello refusal is final and `no_daemon` means
-- the retries are already spent. Value = what the operator must do.
local FINAL_SESSION_REFUSALS = {
  no_daemon = "start yanad",
  version_mismatch = "upgrade the daemon to this plugin's version",
  identity_mismatch = "the running daemon belongs to another user; start your own",
}

local M = {}

-- TEST SEAM. Every entry into `submit_panel` calls this, if set, with the panel
-- and opts -- BEFORE any guard. It exists because the guards downstream (a
-- panel already busy with a job) SWALLOW a duplicate submit: a defect that
-- sends the same parked turn twice is invisible to any counter placed at
-- yana.agent.run, which is where tests/headless/u_panel_session_retry_after_
-- timeout.lua used to count. The seam measures the ATTEMPT, which is the thing
-- ui_panel_lifecycle's clear-before-fire invariant actually promises.
M._test = M._test or {}
M._test.on_submit_panel = nil

-- deps.state: the parent's shared state table `S` -- read/write S.last_panel,
-- S.render_note, S.finalize_shadow_turn here; the caller assigns this module's
-- `submit_panel` return value onto `S.submit_panel`. deps.fn: the parent's late-bound
-- function registry `F`, for the cluster-6 (turn/event) calls submit_panel makes but
-- does not own. deps.M: the parent's own `M` table, for M.new_chat / M.set_mode inside
-- resend -- looked up at CALL time so definition order never matters.
function M.new(deps)
  local S = deps.state
  local F = deps.fn
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

-- opts.text: submit this text directly instead of reading p.prompt_buf (used
-- to drain a queued follow-up). Omit to submit whatever is in the prompt
-- buffer.
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
      p.yanad_submit_waiting = opts.text or true
      notify_one_line("yana: daemon session starting — turn queued", vim.log.levels.INFO)
    else
      -- NOT pending and no session id: the last session.create ANSWERED and
      -- failed -- in practice the client's fixed 5 s timeout (yana.yanad:4,
      -- armed at :222) expiring while the single-threaded daemon works through
      -- a queue that fsyncs per request. That is a transient condition, but the
      -- branch that used to live here only notified and returned, so the panel
      -- was dead for submits FOREVER: nothing else re-issues session.create for
      -- a panel that never got an id (ui_panel_lifecycle's other call site,
      -- :297-301, requires one). Park the turn and re-issue instead.
      --
      -- Only on a user submit -- there is deliberately NO background retry
      -- loop: a daemon that cannot answer must not be hammered by an idle
      -- editor, and the user pressing submit is the one signal that says the
      -- turn is still wanted.
      --
      -- Single slot, overwritten: two submits before an answer arrive as one
      -- queued turn, the later text winning, exactly as the `pending` branch
      -- above already behaves. The slot is cleared by the lifecycle callback
      -- BEFORE it schedules the re-submit (ui_panel_lifecycle.lua:100-101), so
      -- a slot can never fire twice.
      p.yanad_submit_waiting = opts.text or true
      -- SAY WHY. The refusal this replaced was the only reader of
      -- p.yanad_session_err, and a retry notice that never names the cause
      -- turns a permanent refusal into an INFO line repeating forever. Two of
      -- the causes are NOT transient: yana.yanad:251-252 refuses a hello
      -- mismatch outright and never autostarts, so `no_daemon`,
      -- `version_mismatch` and `identity_mismatch` mean the operator has
      -- something to do. Those get ERROR and the instruction; everything else
      -- (a 5 s timeout under a loaded daemon, the case this branch exists for)
      -- gets INFO. The turn is parked either way, so the submit the operator
      -- makes after fixing the daemon sends it.
      local err = tostring(p.yanad_session_err or "session.create failed")
      if FINAL_SESSION_REFUSALS[err] then
        notify_one_line(
          "yana: daemon session refused (" .. err .. ") — " .. FINAL_SESSION_REFUSALS[err] .. "; turn queued",
          vim.log.levels.ERROR
        )
      else
        notify_one_line("yana: daemon session retrying after " .. err .. " — turn queued", vim.log.levels.INFO)
      end
      -- The panel's own door onto its daemon session, installed for every panel
      -- by ui_panel_lifecycle's create_panel and REPLACED by yana.yanad_recover
      -- with a re-attach door on a panel that has a kept session (creating a
      -- second session for one conversation orphans one of them). Called
      -- unguarded on purpose: a panel without it is a construction bug that
      -- must be seen, not a state to degrade around.
      p.yanad_start_session(p)
    end
    return
  end

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
                  S.render_note(p, "⏸ interrupted — sending your message")
                  start_assistant_block(p)
                  update_winbar(p)
                end
              end,
            })
          elseif S.steer_text then
            local backend = p.turn_backends[p.turn_gen] or config.options.backend or "cursor"
            notify_one_line(
              string.format("yana: %s lacks an in-turn channel — restarting now", backend),
              vim.log.levels.INFO
            )
            local text = p.steer_pending.text
            p.steer_pending = nil
            S.steer_text(p, text, { note = "⏹ interrupted to steer — waiting for the previous process to exit" })
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
      -- Rewrite kind: the body is an instruction PREAMBLE and the user's text is the
      -- task it applies to, so body first, user text second — the shape the Cursor and
      -- Claude CLIs use for the same feature. Replacing the whole prompt with `result`
      -- (what this did) silently discarded the task itself. Composed here, not in each
      -- callback: there are two rewrite call sites today and both are generated per
      -- disk file, so per-callback composition would drift.
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
  local descriptor = config.backend_descriptor(config.options.backend) or {}
  local agent_question, attachments = expand_attachments(p, question, {
    expand_paths = descriptor.image_flag == nil,
  })

  -- THE CHANGED-MIND PROMPT (mode contract §3, context carry). "I changed my mind. Do
  -- my previous request in inline mode." is a POINTER: it says what to do only by
  -- reference to something said earlier.
  --
  -- So the referent is either supplied (a resumable upstream session, or a
  -- staged brief carrying the previous instruction/artifact) or the submit
  -- REFUSES, naming what is missing. It is never guessed at. The typed text is
  -- left in the prompt buffer: a refusal that also eats the sentence is worse
  -- than the amnesia it prevents.
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
      S.finalize_shadow_turn(p, p.shadow_turn)
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

  S.last_panel = p

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
    S.render_note(p, "redirect — previous turn interrupted")
  end

  -- The mode switch ended the upstream session, so the new one starts with no history
  -- at all. Without this the chat would appear to continue on screen while the agent
  -- had silently forgotten everything -- worse than refusing the switch, because the
  -- operator cannot see the loss.
  local carried, carried_brief, carried_state = renewal.consume(p)
  if carried then
    built.prompt = "[Context carried from the earlier part of this conversation, which ran in a different mode]\n"
      .. carried
      .. "\n\n"
      .. built.prompt
  elseif carried_state == "stale" then
    -- Dropped, and SAID so: a handoff that silently evaporates is the failure the
    -- operator cannot see, which is the one the whole contract is about.
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
  local lifecycle = require("yana.turn_lifecycle")
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
      single_file_flags = require("yana.single_file").consume_next_flags(),
      stream = p.session_id or ("panel-" .. tostring(p.conv_buf)),
      session_id = p.session_id,
      turn_id = turn_id,
      turn_gen = gen,
      panel_id = p.id,
      mode = p.turn_modes[gen],
      yanad_session_id = p.yanad_session_id,
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
    update_winbar(p)
  end
  -- Open the turn's lifecycle pass. From here the turn has a DURABLE id and an
  -- owning tuple, and it is explicitly NOT actionable: nothing has been walked
  -- or classified yet, so a review rendered from the stream's declared edits is
  -- provisional by construction (the fixed safety contract, async principle).
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
  p.job = agent.run({
    prompt = built.prompt,
    images = attachments,
    mode = config.agent_permission_mode(p.mode),
    -- the YANA dial value for this turn, distinct from the vendor
    -- permission-mode string above -- see agent.lua's M.run doc comment for
    -- the sibling defect this field once masked.
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
      F.on_event(p, gen, obj)
    end,
    on_model_actual = function(model)
      F.set_model_actual(p, gen, model)
    end,
    on_done = function(code, stderr, agent_outcome)
      F.on_done(p, gen, code, stderr, agent_outcome)
    end,
    on_exit_confirmed = function(code)
      F.on_exit_confirmed(p, gen, code)
    end,
  })
  if p.job and steer_channel.can_steer(config.backend_descriptor(p.turn_backends[gen])) then
    steer_channel.open(p, p.job, built.prompt)
  end
  if not p.job then
    p.job_spawn_gen = nil
    -- The overlay never ran, so it never took a claim; nothing to release.
    if p.shadow_turn then
      -- This IS "the turn ends without a review" (REV2 item 3): the launcher never
      -- spawned, so no review will ever exist to consume the scratch copy.
      pcall(function()
        require("yana.single_file").cleanup(p.shadow_turn)
      end)
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

-- Resubmit the last prompt without retyping it.
--
-- opts.where: "here" -- same chat, same session (--resume), same mode. A plain retry.
-- "new" -- a NEW chat: fresh upstream session, this chat's mode carried over.
--
-- The prompt is read BEFORE new_chat, which clears it along with the rest of
-- the conversation state.
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
  S.render_note(p, "resent in a new chat — " .. config.panel_mode(p.mode) .. " mode, fresh session")
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
