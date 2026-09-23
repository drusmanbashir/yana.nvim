-- yana: runs cursor-agent headless and parses its stream-json (NDJSON) output.
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local record = require("yana.record")
local dependencies = require("yana.runtime.dependencies")
local notify = require("yana.notify")

local M = {}
local uv = vim.uv or vim.loop

-- req: { prompt, mode, model, session_id, images? }
--
-- Layer 1 (which backend/binary/account) is decided by config.cmd() through the
-- active backend entry; layer 2 (which flags its argv carries) is decided here from
-- the descriptor in config.lua's `M.defaults.backends`. The shipped "cursor"
-- descriptor reproduces the original hard-coded argv byte-for-byte.
local function build_cmd(req, resolved_command)
  local o = config.options
  local backend_name = o.backend or config.defaults.backend
  local bd = config.backend_descriptor(backend_name) or {}
  local cmd = { resolved_command or config.cmd() }
  local stream_channel = req.steer_enabled and bd.steer_channel == "stream-json"

  if bd.subcommand then
    vim.list_extend(cmd, bd.subcommand)
  end

  -- Resume-as-subcommand shape: when the backend resumes via a subcommand rather
  -- than a flag (bd.resume_subcommand), the session id follows it. The two shapes
  -- are mutually exclusive at setup (M.normalize_backends).
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

  -- INVARIANT: every turn requests the JSON event stream this file's parser
  -- depends on; bd.stream_json_args is validated at setup to contain the
  -- vendor's protocol token (M.normalize_backends).
  vim.list_extend(cmd, bd.stream_json_args or {})
  if stream_channel then
    -- Hold stdin open for user/control frames.
    vim.list_extend(cmd, { "--input-format", "stream-json" })
  end

  -- `o.trust` / `o.approve_mcps` only ever meant "cursor-agent, don't prompt me
  -- for this", so they stay cursor-only rather than a generic per-backend field.
  if backend_name == "cursor" then
    if o.trust then
      table.insert(cmd, "--trust")
    end
    if o.approve_mcps then
      table.insert(cmd, "--approve-mcps")
    end
  end

  -- Vendor sandbox levels: Yana selects one level; the descriptor supplies the
  -- tokens. Ask is always read-only; vendor-default is a deliberate empty list.
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

  -- Non-sandbox permission/launch tokens stay separate; `plan` survives only as
  -- the historical ask alias.
  if mode == "ask" or mode == "plan" then
    -- ask_args contains only non-sandbox tokens and may be empty or absent.
    if bd.ask_args then
      vim.list_extend(cmd, bd.ask_args)
    end
  elseif config.agent_needs_permission_flag() then
    -- bd.allow_edits_args holds only tokens the selected sandbox level does not
    -- already carry, so it may be empty.
    vim.list_extend(cmd, bd.allow_edits_args)
  end

  -- Per-request model, else the configured one. "auto" / "" let the backend pick:
  -- the literal "auto" is NEVER sent, and a backend with no select_model_flag
  -- never gets a --model argument.
  local model = req.model or o.model
  if model and model ~= "" and model ~= "auto" and bd.select_model_flag then
    vim.list_extend(cmd, { bd.select_model_flag, model })
  end

  -- Only spellings the backend descriptor names are emitted; never invent suffixes.
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

  -- Resume keeps the conversation for follow-up turns. Session ids are
  -- VENDOR-SPECIFIC: pick_backend drops the live session before the active
  -- backend changes, so only ids minted by that backend arrive here.
  if has_session and not resumes_by_subcommand and bd.resume_flag then
    vim.list_extend(cmd, { bd.resume_flag, req.session_id })
  end

  -- Use the vendor's native image flag when it has one; other backends receive the
  -- expanded path in the prompt.
  if bd.image_flag and type(req.images) == "table" then
    for _, image in ipairs(req.images) do
      if type(image) == "table" and type(image.path) == "string" and image.path ~= "" then
        vim.list_extend(cmd, { bd.image_flag, image.path })
      end
    end
  end

  -- Prompt is positional unless the stream-json channel sends it as stdin.
  if not stream_channel then
    table.insert(cmd, req.prompt)
  end
  return cmd
end

-- Turn liveness decoding lives in agent_liveness.lua.
M.describe_event = require("yana.agent.agent_liveness").describe_event

-- Why a turn ended, recorded BEFORE the signal is sent: the exit callback that
-- writes the durable evidence runs after the process is gone and cannot ask.
-- Keyed by job id and cleared at exit.
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

-- Per-turn CPU% sampling lives in agent_cpu_sampler.lua. `job_status` is the SAME
-- table the sampler owns (not a copy), so the hot per-line event path mutates the
-- one table the sampler's timer reads.
local agent_cpu_sampler = require("yana.agent.agent_cpu_sampler")
local job_status = agent_cpu_sampler.job_status
local start_cpu_sampler = agent_cpu_sampler.start
local stop_cpu_sampler = agent_cpu_sampler.stop
local stderr_tail = agent_cpu_sampler.stderr_tail
M.status = agent_cpu_sampler.status
M._test.set_sample_interval_ms = agent_cpu_sampler.set_sample_interval_ms
M._test.force_status = agent_cpu_sampler.force_status

-- run a request. yana_mode (string?) is the yana dial value for THIS turn
-- (config.panel_mode(p.mode) at submit time); the jail session's mode is set only from it.
function M.run(req)
  -- CONFINEMENT IS AN INVARIANT OF THE MODE, NOT A COURTESY OF THE CALLER.
  -- `inline` AND `ask` promise the agent is confined (a property of the harness,
  -- not of whether the turn proposes anything). If it cannot be, the turn does not
  -- run: there is no degraded confined turn, and silently becoming `agentic`
  -- because a session was missing is the failure the mode dial exists to prevent.
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

  -- Resolved executable safety: resolve once before any spawn and refuse Cursor's
  -- desktop Electron launcher by static identity; running it would raise the window.
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
  -- The resolved agent binary (cmd[1]), captured before `cmd` may be reassigned to a
  -- jail-wrapped argv, so every ledger/error site reports the binary actually
  -- resolved for this spawn.
  local resolved_cmd = cmd[1]
  -- Provenance: every jobstart is logged into the turn ledger (argv, pid, panel, gen,
  -- resume id, reason), so two spawn records in one turn answers "did Yana start a
  -- second process?".
  local L = req.panel_id and ledger.ensure(req.panel_id, req.turn_gen) or nil
  local spawn = nil
  local job_env = nil
  local jail = nil
  if config.overlay_mode() and req.jail_session then
    jail = require("yana.shadow.jail")
    -- NEVER req.mode here: that is the VENDOR permission mode, while jail.wrap_cmd
    -- feeds this into config.resolve_mode(session.mode).
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
  -- Liveness: the last DESCRIBABLE event, kept on the decode path so the durable
  -- record and the panel see the same event.
  local last_event = nil
  local job_id = nil
  -- The requested/actual model comparison fires once per turn, from the first
  -- system event that names a model.
  local model_mismatch_checked = false
  local got_result = false

  -- Opt-in raw tee (config.debug_record, default off); nil when off, so the default
  -- path performs no I/O.
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

  -- LAYER 1 NARRATION. The normalizer translates every vendor's dialect into
  -- cursor's event shape so `on_event` never learns there was a second vendor. It is
  -- narration only: the review list is derived from the overlay walk at turn end,
  -- so a vendor that narrates nothing still yields reviewable hunks.
  local vendor_stream = require("yana.agent.vendor_stream")
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
      -- The vendor's system/init event carries the model it ACTUALLY used, which can
      -- silently disagree with `req.model`. Recorded once, from the first system event
      -- that names one, whether or not recording (`rec`) is on.
      if obj.type == "system" and type(obj.model) == "string" and obj.model ~= "" then
        if rec then
          rec:note_model_actual(obj.model)
        end
        -- Fired on every system event naming a model (only the mismatch notification
        -- is deduped below), so later models still reach the panel.
        if req.on_model_actual then
          req.on_model_actual(obj.model)
        end
        if not model_mismatch_checked then
          model_mismatch_checked = true
          -- "auto"/nil is NO PREFERENCE, never a mismatch.
          local requested = req.model
          if requested ~= nil and requested ~= "" and requested ~= "auto" and requested ~= obj.model then
            log.lifecycle("model.actual_mismatch", {
              panel = req.panel_id,
              requested = requested,
              actual = obj.model,
            })
            -- One plain line per turn, via the helper the panel's switch notices use.
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
        -- Track the normalized event too, so the exit warning agrees with the decode path.
        if ev.type == "result" then
          got_result = true
        end
        log.guard("yana.agent on_event", req.on_event, ev)
      end
    elseif L then
      -- A line the decoder could not read is a lost event; counting it keeps the
      -- flow report's event-conservation sum honest.
      ledger.note_decode_failure(L, #line)
      if rec then
        rec:note_decode_failure(#line)
      end
    end
  end

  -- A backend declaring `close_stdin` (claude) otherwise pays a fixed wait for
  -- stdin data Yana never sends; `stdin = "null"` gives it immediate EOF. Omitted
  -- for every other backend, which keeps the cursor spawn path unchanged.
  local spawn_bd = config.backend_descriptor() or {}
  local jobstart_opts = {
    cwd = req.cwd,
    env = job_env,
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then
        return
      end
      -- jobstart splits on \n; rejoining reproduces the raw bytes. We split on
      -- real newlines ourselves so partial JSON lines across callbacks work.
      pending = pending .. table.concat(data, "\n")
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        local line = pending:sub(1, nl - 1)
        pending = pending:sub(nl + 1)
        -- Tee BEFORE the scheduled decode, from the raw line, so a replay feeds
        -- the production decoder the same bytes, malformed ones included.
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
          -- A stop recorded before the signal wins; else the exit code is the reason.
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
            -- AUTHORITATIVE FIRST: bin/yana-overlay-inner's own exec attempt prints
            -- `yana-exec-refused argv0=<path> errno=<NAME>` from the syscall's errno,
            -- so it is trusted outright and the free-text scan never runs.
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
              -- FALLBACK ONLY: a refusal deeper than this process's own final exec
              -- never reaches the structured line, so this scan of raw stderr is a
              -- heuristic (English shell text, not an errno) and is labelled as such.
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
            -- A vendor may exit 0 after one child write hit EROFS. Classify only raw
            -- process stderr; jail_refusal supplies the EROFS and attribution gates.
            local stderr_text = table.concat(stderr_acc, "\n")
            if stderr_text ~= "" then
              pcall(jail.record_vendor_job_refusal, req.jail_session, resolved_cmd, stderr_text, code)
            end
          end
          -- Gen-independent: fires for EVERY real job death, stale or not, so a
          -- redirect can wait for a CONFIRMED exit (jobstop only sends SIGTERM).
          -- Not called on the spawn-failure branch below: no process existed.
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

-- Stop an in-flight job. `reason` is recorded before the signal goes out; the
-- default names the command the stalled status tells the operator to type.
function M.stop(job, reason, extra)
  if job and job > 0 then
    local info = vim.tbl_extend("force", extra or {}, { reason = reason or M.DEFAULT_STOP_REASON })
    stop_reasons[job] = info
    pcall(vim.fn.jobstop, job)
  end
end

-- OS pid for a job lives in agent_cpu_sampler.lua.
M.pid = agent_cpu_sampler.pid

-- Escalate to SIGKILL when SIGTERM (jobstop) was ignored. pid may already be gone;
-- pcall swallows that. Returns true if a kill was attempted (pid resolved).
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

-- Per-backend model catalogue (--list-models spawn/parse/cache) lives in
-- agent_models.lua.
local agent_models = require("yana.agent.agent_models")
M.cached_model_list = agent_models.cached_model_list
M.clear_model_list_cache = agent_models.clear_model_list_cache
M.list_models = agent_models.list_models
M.model_list_refreshing = agent_models.model_list_refreshing

return M
