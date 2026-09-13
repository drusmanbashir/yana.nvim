-- yana: runs cursor-agent headless and parses its stream-json (NDJSON) output.
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local record = require("yana.record")
local dependencies = require("yana.dependencies")
local notify = require("yana.notify")

local M = {}
local uv = vim.uv or vim.loop

-- req: { prompt, mode, model, session_id, images? }
--
-- Layer 1 (which backend/binary/account) is decided by config.cmd(), which resolves
-- through the active `config.options.backend` entry (config.resolve_cmd). Layer 2
-- (which flags that backend's argv carries) is decided here. The descriptor table in
-- config.lua's `M.defaults.backends` is the declarative "zoo" entry (avante.nvim's
-- `providers` shape) an operator can extend without touching this file -- see its doc
-- comment for the exact list of what an entry cannot influence and what enforces each.
--
-- The shipped "cursor" descriptor's fields reproduce exactly what this
-- function hard-coded before backends existed, so the default argv is
-- byte-identical: an operator who sets nothing sees no change.
local function build_cmd(req, resolved_command)
  local o = config.options
  local backend_name = o.backend or config.defaults.backend
  local bd = config.backend_descriptor(backend_name) or {}
  local cmd = { resolved_command or config.cmd() }
  local stream_channel = req.steer_enabled and bd.steer_channel == "stream-json"

  if bd.subcommand then
    vim.list_extend(cmd, bd.subcommand)
  end

  -- Work order VENDORS, resume-as-subcommand shape ONLY: when this turn is a resume AND
  -- the active backend resumes via a subcommand rather than a flag
  -- (bd.resume_subcommand, e.g. The two shapes are mutually exclusive at setup
  -- (M.normalize_backends), so at most one of them ever fires for a given turn.
  local has_session = req.session_id and req.session_id ~= ""
  local resumes_by_subcommand = has_session and bd.resume_subcommand ~= nil
  if resumes_by_subcommand then
    vim.list_extend(cmd, bd.resume_subcommand)
    table.insert(cmd, req.session_id)
  end

  -- INVARIANT: every turn runs non-interactively.
  if bd.noninteractive_flag then
    table.insert(cmd, bd.noninteractive_flag)
  end

  -- INVARIANT: every turn requests the JSON event stream agent.lua's own
  -- parser depends on. bd.stream_json_args is required and validated at
  -- setup to literally contain this vendor's protocol request token
  -- (M.normalize_backends) so an entry cannot silently swap the format
  -- Yana parses.
  vim.list_extend(cmd, bd.stream_json_args or {})
  if stream_channel then
    -- Hold stdin open for user/control frames.
    vim.list_extend(cmd, { "--input-format", "stream-json" })
  end

  -- Promoting them to a generic per-backend field would force every future vendor entry
  -- to declare nil for something that was never theirs. `o.trust`/ `o.approve_mcps`
  -- predate the backends feature and have only ever meant "cursor-agent, don't prompt
  -- me for this"; if a future backend earns an equivalent concept, it gets its own
  -- named capability then, on evidence.
  if backend_name == "cursor" then
    if o.trust then
      table.insert(cmd, "--trust")
    end
    if o.approve_mcps then
      table.insert(cmd, "--approve-mcps")
    end
  end

  -- Vendor sandbox levels: Yana selects one
  -- level; the descriptor supplies this vendor's tokens. Ask is always the
  -- read-only level. vendor-default is a deliberate empty list.
  local mode = req.mode or config.agent_permission_mode()
  local sandbox_level
  if mode == "ask" or mode == "plan" then
    sandbox_level = "read-only"
  else
    local yana_mode = req.yana_mode or config.options.mode
    if yana_mode == "review" then
      yana_mode = "inline"
    end
    sandbox_level = config.options.sandbox[yana_mode]
  end
  local sandbox_tokens = bd.sandbox_args[sandbox_level]
  if type(sandbox_tokens) ~= "table" then
    error(
      "yana: backend " .. tostring(backend_name) .. " has no sandbox_args for level " .. tostring(sandbox_level),
      0
    )
  end
  vim.list_extend(cmd, sandbox_tokens)

  -- Non-sandbox permission/launch tokens remain separate. `plan` is gone as
  -- a user mode; it survives here only as the historical ask alias.
  if mode == "ask" or mode == "plan" then
    -- ask_args contains only non-sandbox tokens and may be empty or absent.
    if bd.ask_args then
      vim.list_extend(cmd, bd.ask_args)
    end
  elseif config.agent_needs_permission_flag() then
    -- config.agent_needs_permission_flag() remains the policy switch.
    -- bd.allow_edits_args contains only tokens not already represented by
    -- the selected sandbox level and may therefore be empty.
    vim.list_extend(cmd, bd.allow_edits_args)
  end

  -- Per-request model (panels can use different models); falls back to the
  -- globally configured one. "auto" / "" mean: let the backend pick -- the
  -- literal string "auto" is NEVER sent (this is Yana's own policy, not the
  -- entry's), and a backend whose descriptor carries no select_model_flag at
  -- all (layer 2 does not exist for it) never gets a --model argument
  -- regardless of what req.model says.
  local model = req.model or o.model
  if model and model ~= "" and model ~= "auto" and bd.select_model_flag then
    vim.list_extend(cmd, { bd.select_model_flag, model })
  end

  -- Only spellings the backend descriptor names are emitted; never invent suffixes
  -- here.
  local modes = req.model_modes or o.model_modes
  if type(modes) == "table" and type(bd.mode_tokens) == "table" then
    local keys = {}
    for k in pairs(bd.mode_tokens) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local tok = bd.mode_tokens[key]
      local val = modes[key]
      if type(tok) == "table" and type(val) == "string" and val ~= "" and val ~= "-" then
        if tok.kind == "config" and type(tok.key) == "string" and tok.key ~= "" then
          vim.list_extend(cmd, { "-c", string.format('%s="%s"', tok.key, val) })
        elseif tok.kind == "flag" and type(tok.flag) == "string" and tok.flag ~= "" then
          vim.list_extend(cmd, { tok.flag, val })
        end
      end
    end
  end

  -- Resume keeps the same conversation/session for follow-up turns. Session ids are
  -- VENDOR-SPECIFIC (row 58's sharp edge): pick_backend drops the live session before
  -- the active backend changes, so this function only receives ids minted by that
  -- backend. It adds the flag only when the descriptor has one.
  if has_session and not resumes_by_subcommand and bd.resume_flag then
    vim.list_extend(cmd, { bd.resume_flag, req.session_id })
  end

  -- Use the active vendor's native image flag when it has one. Backends
  -- without this capability receive the expanded path in the prompt.
  if bd.image_flag and type(req.images) == "table" then
    for _, image in ipairs(req.images) do
      if type(image) == "table" and type(image.path) == "string" and image.path ~= "" then
        vim.list_extend(cmd, { bd.image_flag, image.path })
      end
    end
  end

  -- Prompt is positional unless §11.2's stream-json channel sends it as stdin.
  if not stream_channel then
    table.insert(cmd, req.prompt)
  end
  return cmd
end

-- Turn liveness decoding moved to agent_liveness.lua: pure
-- functions of a decoded stream event, no dependency on this module's state.
M.describe_event = require("yana.agent_liveness").describe_event

-- Why a turn ended, recorded BEFORE the signal is sent. The exit callback that
-- writes the durable evidence runs once the process is already gone and has
-- nothing left to ask, so a stop that did not say why at the time is a stop
-- whose reason is lost. Keyed by job id and cleared at exit.
local stop_reasons = {}
M._test = M._test or {}
M._test.build_cmd = build_cmd

M.DEFAULT_STOP_REASON = "stopped by the operator (:YanaStop)"

-- Write one stream-json stdin frame.
function M.send_frame(job, obj)
  if not job or job <= 0 then
    return false
  end
  local ok, encoded = pcall(vim.json.encode, obj)
  if not ok then
    return false
  end
  local ok_send, sent = pcall(vim.fn.chansend, job, encoded .. "\n")
  return ok_send and tonumber(sent) ~= nil and tonumber(sent) > 0
end

-- Close held stdin after idle result.
function M.close_stdin(job)
  if not job or job <= 0 then
    return false
  end
  return pcall(vim.fn.chanclose, job, "stdin")
end

-- Per-turn CPU% sampling via /proc moved to agent_cpu_sampler.lua
--. `job_status` is aliased to the SAME table the sampler module
-- owns (not a copy), so the hot per-line event path below
-- (`job_status[job_id].last_event_hr = ...`) is unchanged text and still
-- mutates the one table the sampler's timer reads.
local agent_cpu_sampler = require("yana.agent_cpu_sampler")
local job_status = agent_cpu_sampler.job_status
local start_cpu_sampler = agent_cpu_sampler.start
local stop_cpu_sampler = agent_cpu_sampler.stop
local stderr_tail = agent_cpu_sampler.stderr_tail
M.status = agent_cpu_sampler.status
M._test.set_sample_interval_ms = agent_cpu_sampler.set_sample_interval_ms
M._test.force_status = agent_cpu_sampler.force_status

-- run a request. yana_mode (string?) the yana dial value for THIS turn
-- (config.panel_mode(p.mode) at submit time) -- the only field the jail session's own
-- mode may be set from.
function M.run(req)
  -- CONFINEMENT IS AN INVARIANT OF THE MODE, NOT A COURTESY OF THE CALLER.
  --
  -- ui.lua does fail closed before reaching here, so the shipping path was safe; but it
  -- was safe by caller discipline, and that is the difference between a hole being
  -- currently absent and being structurally impossible.
  --
  -- `inline` AND `ask` promise the agent is confined (ruling R-3: confinement is
  -- a property of the harness, not of whether the turn expects to propose
  -- anything). If it cannot be, the turn does not run. There is no degraded
  -- confined turn: silently becoming `agentic` because a session was missing is
  -- precisely the failure the mode dial exists to prevent
  -- (the public mode contract).
  if config.overlay_mode() and not req.jail_session then
    local msg = string.format(
      "yana: %s mode requires the agent to run confined, and no overlay session was established for this turn — refusing to run it unconfined",
      config.options.mode
    )
    if req.panel_id then
      local L0 = ledger.ensure(req.panel_id, req.turn_gen)
      ledger.record_spawn(L0, {
        cmd = config.cmd(),
        cwd = req.cwd,
        mode = req.mode,
        reason = req.spawn_reason or "submit",
        jailed = true,
        ok = false,
        error = msg,
      })
    end
    if req.on_done then
      req.on_done(-1, msg)
    end
    return nil
  end

  -- Resolved executable safety: resolve once before
  -- any agent spawn and refuse Cursor's desktop Electron launcher by static
  -- identity. Running it to ask what it is would itself raise the window.
  local resolution = config.resolve_cmd()
  local desktop_refusal = dependencies.desktop_cursor_refusal(resolution.value, resolution.backend)
  if desktop_refusal then
    if req.on_done then
      req.on_done(-1, desktop_refusal)
    end
    return nil
  end

  local ready, dependency_error = dependencies.preflight(config.options.mode)
  if not ready then
    if req.on_done then
      req.on_done(-1, "yana: dependency preflight refused before agent start: " .. dependency_error)
    end
    return nil
  end
  local cmd = build_cmd(req, resolution.value)
  -- The resolved agent binary, captured once here (cmd[1], exactly what config.cmd()
  -- produced inside build_cmd) before `cmd` is potentially reassigned to a jail-wrapped
  -- argv below (bwrap/sh, not cursor-agent). Every ledger/error-message site past this
  -- point reports THIS, not a fresh config.cmd() call, so provenance always names the
  -- binary that was actually resolved for this spawn rather than whatever a second
  -- resolution (env var mutated mid-flight, however unlikely) might answer.
  local resolved_cmd = cmd[1]
  -- Provenance, record 1 of 3: every jobstart is logged into the turn ledger
  -- with its argv, pid, panel, gen, resume id and reason. A repeated panel
  -- sentence is attributable only if "did Yana start a second process?"
  -- has a recorded answer; two spawn records inside one turn is that answer.
  local L = req.panel_id and ledger.ensure(req.panel_id, req.turn_gen) or nil
  local spawn = nil
  local job_env = nil
  local jail = nil
  if config.overlay_mode() and req.jail_session then
    jail = require("yana.shadow.jail")
    -- NEVER req.mode here: that is the VENDOR permission mode ("ask"/"agent" /"plan",
    -- config.agent_permission_mode's vocabulary), and jail.wrap_cmd feeds this straight
    -- into config.resolve_mode(session.mode) to decide inline_exec_allowlist_active.
    req.jail_session.mode = req.yana_mode or config.options.mode
    local wrapped, jail_env = jail.wrap_cmd(cmd, req.jail_session)
    if not wrapped then
      if L then
        ledger.record_spawn(L, {
          argv = cmd,
          cmd = resolved_cmd,
          cwd = req.cwd,
          mode = req.mode,
          model = req.model,
          resume_session_id = req.session_id,
          reason = req.spawn_reason or "submit",
          jailed = true,
          ok = false,
          error = jail_env or jail.UNAVAILABLE_MSG,
        })
      end
      if req.on_done then
        req.on_done(-1, jail_env or jail.UNAVAILABLE_MSG)
      end
      return nil
    end
    cmd = wrapped
    job_env = jail.merge_spawn_env(jail_env)
  end
  local pending = ""
  local stderr_acc = {}
  local exec_started_hr = uv.hrtime()
  -- Liveness: the last DESCRIBABLE event this process produced. Kept here, on
  -- the decode path, so the durable record and the panel see the same event
  -- even when the panel is closed or the turn is stale.
  local last_event = nil
  local job_id = nil
  -- Row 76: the requested/actual model comparison fires once per turn, from
  -- the first system event that names a model — a later disagreement would
  -- itself be a new fact, same "first write wins" rule `rec:note_model_actual`
  -- already follows.
  local model_mismatch_checked = false
  local got_result = false

  -- Opt-in raw tee (config.debug_record, default off). nil when recording is
  -- off, so every call site below is a plain nil check and the default path
  -- performs no I/O at all.
  local rec = record.open({
    session = req.jail_session,
    panel_id = req.panel_id,
    gen = req.turn_gen,
    turn_id = req.turn_id,
    argv = cmd,
    cwd = req.cwd,
    mode = req.mode,
    model = req.model,
    resume_session_id = req.session_id,
    jailed = req.jail_session ~= nil,
  })
  if rec and L then
    ledger.set_recording(L, {
      stream_path = rec.stream_path,
      events_path = rec.events_path,
      meta_path = rec.meta_path,
    }, rec)
  end

  -- LAYER 1 NARRATION. Every vendor speaks its own event dialect; the panel reads
  -- exactly one of them (cursor's). The normalizer translates the other protocols into
  -- that shape so `on_event` never learns there was a second vendor.
  --
  -- This is narration only. The review list is still derived from the overlay
  -- walk at turn end -- the cardinal rule in the core spec -- so a vendor that
  -- narrates nothing still yields reviewable hunks.
  local vendor_stream = require("yana.vendor_stream")
  local vstate = vendor_stream.new_state({
    protocol = (config.backend_descriptor(config.options.backend) or {}).stream_protocol or "cursor",
    cwd = req.cwd,
  })

  local function emit(line)
    if line == nil or line == "" then
      return
    end
      local ok, obj = pcall(vim.json.decode, line)
    if ok and type(obj) == "table" then
      if obj.type == "result" then
        got_result = true
      end
      local described = M.describe_event(obj)
      if described then
        described.at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        last_event = described
      end
      -- The vendor's system/init event carries the model it ACTUALLY used, which is a
      -- fact distinct from `req.model` (what Yana requested) and can disagree with it
      -- silently — the only way to catch a model switch that did not take. Recorded
      -- once, from the first system event that names one, since a later disagreement
      -- would itself be a new fact. This runs whether or not opt-in recording (`rec`)
      -- is on: the disagreement is a UX fact the operator needs regardless of whether
      if obj.type == "system" and type(obj.model) == "string" and obj.model ~= "" then
        if rec then
          rec:note_model_actual(obj.model)
        end
        -- Fired on every system event that names a model (not gated by
        -- model_mismatch_checked below, which only dedupes the mismatch notification),
        -- so a later system event's model — a fact, same as the first — still reaches
        -- the panel.
        if req.on_model_actual then
          req.on_model_actual(obj.model)
        end
        if not model_mismatch_checked then
          model_mismatch_checked = true
          -- "auto"/nil is NO PREFERENCE, never a mismatch (row 76): the
          -- operator did not ask for a specific model, so any vendor answer
          -- is agreement by definition.
          local requested = req.model
          if requested ~= nil and requested ~= "" and requested ~= "auto" and requested ~= obj.model then
            log.lifecycle("model.actual_mismatch", {
              panel = req.panel_id,
              requested = requested,
              actual = obj.model,
            })
            -- Once per turn, one plain line — not an error, not a modal.
            -- Same helper the panel's own switch notifications use
            -- (`notify.one_line`, aliased `notify_one_line` in ui.lua).
            notify.one_line(
              string.format("yana: model requested %s, vendor ran %s", requested, obj.model),
              vim.log.levels.INFO
            )
          end
        end
      end
      local st = job_id and job_status[job_id] or nil
      if st then
        st.last_event_hr = uv.hrtime()
      end
      for _, ev in ipairs(vendor_stream.normalize(vstate, obj)) do
        -- Track the normalized event, not only the raw cursor-shaped input, so the exit
        -- warning and outcome metadata agree with the decode path.
        if ev.type == "result" then
          got_result = true
        end
        log.guard("yana.agent on_event", req.on_event, ev)
      end
    elseif L then
      -- A line the decoder could not read is a lost event. The count is free
      -- here and makes the event-conservation sum in the flow report honest:
      -- "the agent reported N, the panel shows M" resolves to a named leak
      -- instead of an argument.
      ledger.note_decode_failure(L, #line)
      if rec then
        rec:note_decode_failure(#line)
      end
    end
  end

  -- Row 66: a backend declaring `close_stdin` (claude) pays a fixed wait
  -- for stdin data Yana never sends -- the default jobstart pipe is open
  -- but nobody ever writes to it or closes it. `stdin = "null"` gives the
  -- child immediate EOF instead. Omitted entirely (nil, not "pipe") for
  -- every backend that does not declare it, which is what keeps the cursor
  -- spawn path byte-identical to pre-row-66 Yana.
  local spawn_bd = config.backend_descriptor() or {}
  local jobstart_opts = {
    cwd = req.cwd,
    env = job_env,
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then
        return
      end
      -- jobstart splits on \n; rejoining with \n reproduces the raw bytes for
      -- this callback. We accumulate and split on real newlines ourselves so
      -- partial JSON lines across callbacks are handled correctly.
      pending = pending .. table.concat(data, "\n")
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        local line = pending:sub(1, nl - 1)
        pending = pending:sub(nl + 1)
        -- Tee BEFORE the scheduled decode, and from the raw line rather than
        -- the decoded object: a replay has to feed the production decoder the
        -- same bytes it saw here, malformed ones included.
        if rec then
          rec:line(line)
        end
        vim.schedule(function()
          emit(line)
        end)
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      for _, chunk in ipairs(data) do
        if chunk ~= "" then
          table.insert(stderr_acc, chunk)
        end
      end
    end,
    on_exit = function(jid, code)
      vim.schedule(function()
        log.guard("yana.agent on_exit", function()
          -- Flush any trailing line without a newline.
          if pending ~= "" then
            local leftover = pending
            pending = ""
            if rec then
              rec:line(leftover)
            end
            emit(leftover)
          end
          -- A stop recorded before the signal wins; otherwise the exit code is the
          -- reason.
          local key = jid or job_id
          local stop_reason = key and stop_reasons[key] or nil
          local stopped_by_yana = stop_reason ~= nil
          if key then
            stop_reasons[key] = nil
            stop_cpu_sampler(key)
          end
          if not stop_reason then
            stop_reason = (code == 0) and "completed" or ("agent exited with code " .. tostring(code))
          end
          if rec then
            local stderr_text = table.concat(stderr_acc, "\n")
            rec:finish({
              code = code,
              stderr = stderr_text,
              pid = spawn and spawn.pid or nil,
              last_event = last_event,
              stop_reason = type(stop_reason) == "table" and stop_reason.reason or stop_reason,
              cpu_pct_at_stop = type(stop_reason) == "table" and stop_reason.cpu_pct_at_stop or nil,
              stall_cause = type(stop_reason) == "table" and stop_reason.stall_cause or nil,
              forensics_path = type(stop_reason) == "table" and stop_reason.forensics_path or nil,
            })
            if L then
              ledger.bump(L, "recorded_lines", rec.lines)
              ledger.clear_recording_writer(L)
            end
          end
          if spawn then
            ledger.update_spawn(spawn, { exit_code = code })
          end
          local elapsed_ms = math.floor(((uv.hrtime() - exec_started_hr) / 1e6) + 0.5)
          log.lifecycle("exec.ran", {
            argv0 = resolved_cmd,
            exit = code,
            ms = elapsed_ms,
            mode = req.mode or config.options.mode,
          })
          if not got_result and not stopped_by_yana then
            local tail = stderr_tail(stderr_acc, 10)
            local cause = tail ~= ""
              and ("process stderr: " .. tail)
              or string.format(
                "process %s exited with code %s without stderr",
                tostring(resolved_cmd), tostring(code)
              )
            log.write("WARN", string.format(
              "agent produced no result (exit_code=%s elapsed_ms=%s argv0=%s cause=%s)",
              tostring(code),
              tostring(elapsed_ms),
              tostring(resolved_cmd),
              cause
            ))
            notify.one_line(
              string.format("yana: agent produced no result in %d ms — %s", elapsed_ms, cause),
              vim.log.levels.WARN
            )
          end
          if job_env and job_env.YANA_INLINE_EXEC_ALLOWLIST_ACTIVE == "1" then
            local stderr_text = table.concat(stderr_acc, "\n")
            -- AUTHORITATIVE FIRST: bin/yana-overlay-inner's own exec attempt, when it
            -- is the one that fails, prints a structured line naming the exact argv0
            -- and the real errno the exec(2) call itself saw (`yana-exec-refused
            -- argv0=<path> errno=<NAME>`) -- see its refuse_exec(). That is sourced
            -- from the syscall, not inferred, so it is trusted outright and the
            -- free-text scan below never runs when it is present.
            local structured_argv0, structured_errno =
              stderr_text:match("yana%-exec%-refused argv0=(%S+) errno=(%S+)")
            if structured_argv0 then
              log.lifecycle("exec.refused", {
                argv0 = structured_argv0,
                errno = structured_errno,
                allowlisted = false,
                mode = req.mode or config.options.mode,
              })
            else
              -- FALLBACK ONLY: a refusal that happens deeper than this process's own
              -- final exec (e.g. inside the agent's own shelled-out children) never
              -- reaches the structured line above, so this free-text scan over the
              -- agent's raw stderr is the only signal left. It is a heuristic --
              -- English shell error text, not a syscall errno -- and is labelled as
              -- such so a caller never mistakes it for the authoritative source.
              local denied = stderr_text:match("([%w%._%-%+/]+): Permission denied")
                or stderr_text:match("([%w%._%-%+/]+): Operation not permitted")
                or stderr_text:match("([%w%._%-%+/]+): not found")
                or stderr_text:match("exec[^:\n]*:%s*([%w%._%-%+/]+)")
              if denied then
                log.lifecycle("exec.refused", {
                  argv0 = denied,
                  errno = stderr_text:find("not found", 1, true) and "ENOENT" or "EACCES",
                  allowlisted = false,
                  mode = req.mode or config.options.mode,
                  source = "stderr-heuristic",
                })
              end
            end
          end
          if req.jail_session then
            -- A vendor may finish the model turn with exit 0 after one child
            -- write received EROFS. Classify only raw process stderr here;
            -- jail_refusal supplies the EROFS and filesystem-attribution gates.
            local stderr_text = table.concat(stderr_acc, "\n")
            if stderr_text ~= "" then
              pcall(jail.record_vendor_job_refusal, req.jail_session, resolved_cmd, stderr_text, code)
            end
          end
          -- Gen-independent: fires for EVERY real job death, stale or not, so a
          -- redirect can wait for a CONFIRMED exit rather than assuming one
          -- from jobstop() (which only sends SIGTERM). Not called on the
          -- job<=0 spawn-failure branch below — no process ever existed there.
          if req.on_exit_confirmed then
            req.on_exit_confirmed(code)
          end
          if req.on_done then
            req.on_done(code, table.concat(stderr_acc, "\n"), {
              argv0 = resolved_cmd,
              elapsed_ms = elapsed_ms,
              got_result = got_result,
            })
          end
        end)
      end)
    end,
  }
  if req.steer_enabled and spawn_bd.steer_channel == "stream-json" then
    jobstart_opts.stdin = "pipe"
  elseif spawn_bd.close_stdin then
    jobstart_opts.stdin = "null"
  end
  local ok_start, job = pcall(vim.fn.jobstart, cmd, jobstart_opts)

  if not ok_start or type(job) ~= "number" or job <= 0 then
    if L then
      ledger.record_spawn(L, {
        argv = cmd,
        cmd = resolved_cmd,
        cwd = req.cwd,
        mode = req.mode,
        model = req.model,
        resume_session_id = req.session_id,
        reason = req.spawn_reason or "submit",
        jailed = req.jail_session ~= nil,
        ok = false,
        error = ok_start and ("jobstart returned " .. tostring(job)) or tostring(job),
        tee_path = rec and rec.stream_path or nil,
      })
    end
    if req.on_done then
      req.on_done(-1, "failed to start '" .. tostring(resolved_cmd) .. "' (is cursor-agent installed and on PATH?)")
    end
    return nil
  end

  job_id = job
  start_cpu_sampler(job, M.pid(job))
  if L then
    spawn = ledger.record_spawn(L, {
      argv = cmd,
      cmd = resolved_cmd,
      job = job,
      pid = M.pid(job),
      cwd = req.cwd,
      mode = req.mode,
      model = req.model,
      resume_session_id = req.session_id,
      reason = req.spawn_reason or "submit",
      jailed = req.jail_session ~= nil,
      ok = true,
      tee_path = rec and rec.stream_path or nil,
    })
    ledger.mark(L, "process_spawned")
  end

  return job
end

-- Stop an in-flight job. `reason` is recorded for the turn's durable evidence
-- before the signal goes out; the default names the command an operator would
-- have typed, which is also what the stalled status tells them to type.
function M.stop(job, reason, extra)
  if job and job > 0 then
    local info = vim.tbl_extend("force", extra or {}, { reason = reason or M.DEFAULT_STOP_REASON })
    stop_reasons[job] = info
    pcall(vim.fn.jobstop, job)
  end
end

-- OS pid for a job (M.pid) moved to agent_cpu_sampler.lua.
M.pid = agent_cpu_sampler.pid

-- Escalate to SIGKILL when SIGTERM (jobstop) was ignored. pid may already be
-- gone (process died between the caller's check and this call) — pcall
-- swallows that. Returns true if a kill was attempted (pid resolved),
-- regardless of whether the signal actually landed.
function M.kill(job)
  local pid = M.pid(job)
  if not pid then
    return false
  end
  if job and job > 0 and not stop_reasons[job] then
    stop_reasons[job] = { reason = M.DEFAULT_STOP_REASON .. "; escalated to SIGKILL" }
  end
  pcall((vim.uv or vim.loop).kill, pid, "sigkill")
  return true
end

-- Per-backend model catalogue (--list-models spawn/parse/cache) moved to
-- agent_models.lua: self-contained, nothing else in this file
-- read or wrote its cache.
local agent_models = require("yana.agent_models")
M.cached_model_list = agent_models.cached_model_list
M.clear_model_list_cache = agent_models.clear_model_list_cache
M.list_models = agent_models.list_models
M.model_list_refreshing = agent_models.model_list_refreshing

return M
