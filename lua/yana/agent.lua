-- yana: runs cursor-agent headless and parses its stream-json (NDJSON) output.
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local record = require("yana.record")
local dependencies = require("yana.dependencies")

local M = {}

-- Build the argv used to invoke cursor-agent for a single request.
-- req: { prompt, mode, model, session_id }
local function build_cmd(req)
  local o = config.options
  local cmd = {
    config.cmd(),
    "-p",
    "--output-format", "stream-json",
    "--stream-partial-output",
  }

  if o.trust then
    table.insert(cmd, "--trust")
  end

  if o.approve_mcps then
    table.insert(cmd, "--approve-mcps")
  end

  -- The vendor permission mode is a CONSEQUENCE of the dial, never an operator
  -- option. `plan` is gone as a mode: it was a way of asking, and it is reached
  -- by asking for a plan in `ask` (the mode contract).
  local mode = req.mode or config.agent_permission_mode()
  if mode == "ask" or mode == "plan" then
    vim.list_extend(cmd, { "--mode", "ask" })
  elseif config.agent_needs_permission_flag() then
    -- config.agent_needs_permission_flag() is the single place this is decided;
    -- see its comment for the adjudicated reasoning and the revisit trigger.
    -- Asking it here rather than reading a flag is what makes the reversal one
    -- line when a non-force headless edit becomes demonstrable.
    table.insert(cmd, "--force")
  end

  -- Per-request model (panels can use different models); falls back to the
  -- globally configured one. "auto" / "" mean: let cursor-agent pick.
  local model = req.model or o.model
  if model and model ~= "" and model ~= "auto" then
    vim.list_extend(cmd, { "--model", model })
  end

  -- Resume keeps the same conversation/session for follow-up turns.
  if req.session_id and req.session_id ~= "" then
    vim.list_extend(cmd, { "--resume", req.session_id })
  end

  -- Prompt is positional and passed as a single argv element (no shell), so
  -- newlines and special characters are safe.
  table.insert(cmd, req.prompt)
  return cmd
end

-- run a request.
-- req fields:
--   prompt      (string)   final prompt text
--   mode        (string)   "ask" | "agent" | "plan"
--   model       (string?)  model id for this request (nil => config/auto)
--   session_id  (string?)  resume an existing session
--   cwd         (string?)  working directory for the agent
--   on_event    (fn(obj))  called per decoded JSON event (on main loop)
--   on_done     (fn(code, stderr)) called when the process exits (on main loop)
--   panel_id    (number?)  owning panel, for the turn ledger
--   turn_gen    (number?)  owning turn generation, for the turn ledger
--   spawn_reason(string?)  why this process exists ("submit", "redirect", …)
-- returns the job id (number) or nil on failure.
function M.run(req)
  -- CONFINEMENT IS AN INVARIANT OF THE MODE, NOT A COURTESY OF THE CALLER.
  --
  -- Adjudication 2026-08-17 (fresh reviewer, FAIL verdict) found that the
  -- overlay boundary held "only when invoked": the wrap below is guarded by
  -- `req.jail_session`, so a caller that supplies none falls straight through
  -- to jobstart with the raw argv -- unconfined, and in a permission-flagged
  -- mode that means unconfined WITH the flag. ui.lua does fail closed before
  -- reaching here, so the shipping path was safe; but it was safe by caller
  -- discipline, and that is the difference between a hole being currently
  -- absent and being structurally impossible.
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

  local ready, dependency_error = dependencies.preflight(config.options.mode)
  if not ready then
    if req.on_done then
      req.on_done(-1, "yana: dependency preflight refused before agent start: " .. dependency_error)
    end
    return nil
  end
  local cmd = build_cmd(req)
  -- The resolved agent binary, captured once here (cmd[1], exactly what
  -- config.cmd() produced inside build_cmd) before `cmd` is potentially
  -- reassigned to a jail-wrapped argv below (bwrap/sh, not cursor-agent).
  -- Every ledger/error-message site past this point reports THIS, not a
  -- fresh config.cmd() call, so provenance always names the binary that was
  -- actually resolved for this spawn rather than whatever a second
  -- resolution (env var mutated mid-flight, however unlikely) might answer.
  local resolved_cmd = cmd[1]
  -- Provenance, record 1 of 3: every jobstart is logged into the turn ledger
  -- with its argv, pid, panel, gen, resume id and reason. A repeated panel
  -- sentence is attributable only if "did Yana start a second process?"
  -- has a recorded answer; two spawn records inside one turn is that answer.
  local L = req.panel_id and ledger.ensure(req.panel_id, req.turn_gen) or nil
  local spawn = nil
  local job_env = nil
  if config.overlay_mode() and req.jail_session then
    local jail = require("yana.shadow.jail")
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

  local function emit(line)
    if line == nil or line == "" then
      return
    end
    local ok, obj = pcall(vim.json.decode, line)
    if ok and type(obj) == "table" then
      log.guard("yana.agent on_event", req.on_event, obj)
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

  local ok_start, job = pcall(vim.fn.jobstart, cmd, {
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
    on_exit = function(_, code)
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
          if rec then
            local stderr_text = table.concat(stderr_acc, "\n")
            rec:finish({ code = code, stderr = stderr_text, pid = spawn and spawn.pid or nil })
            if L then
              ledger.bump(L, "recorded_lines", rec.lines)
              ledger.clear_recording_writer(L)
            end
          end
          if spawn then
            ledger.update_spawn(spawn, { exit_code = code })
          end
          -- Gen-independent: fires for EVERY real job death, stale or not, so a
          -- redirect can wait for a CONFIRMED exit rather than assuming one
          -- from jobstop() (which only sends SIGTERM). Not called on the
          -- job<=0 spawn-failure branch below — no process ever existed there.
          if req.on_exit_confirmed then
            req.on_exit_confirmed(code)
          end
          if req.on_done then
            req.on_done(code, table.concat(stderr_acc, "\n"))
          end
        end)
      end)
    end,
  })

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

-- Stop an in-flight job.
function M.stop(job)
  if job and job > 0 then
    pcall(vim.fn.jobstop, job)
  end
end

-- OS pid for a job, for signal escalation beyond jobstop()'s SIGTERM.
-- Returns the pid (number) or nil (job invalid / already gone).
function M.pid(job)
  local ok, pid = pcall(vim.fn.jobpid, job)
  if ok and type(pid) == "number" and pid > 0 then
    return pid
  end
  return nil
end

-- Escalate to SIGKILL when SIGTERM (jobstop) was ignored. pid may already be
-- gone (process died between the caller's check and this call) — pcall
-- swallows that. Returns true if a kill was attempted (pid resolved),
-- regardless of whether the signal actually landed.
function M.kill(job)
  local pid = M.pid(job)
  if not pid then
    return false
  end
  pcall((vim.uv or vim.loop).kill, pid, "sigkill")
  return true
end

-- List available models via `cursor-agent --list-models`.
-- cb(models, code) where models = { { id, label, current, default }, ... }.
-- Always includes an "auto" entry first.
--
-- The parse below requires literal English: `ID - label`, with optional
-- literal `(current)` / `(default)` markers. cursor-agent inherits Neovim's
-- (i.e. the operator's shell's) locale, and under a non-English LANG/LC_ALL
-- it may emit localized labels or a different separator, silently emptying
-- the model list or losing current/default status (PORT-12, portability
-- review). There is no documented machine-readable --list-models format to
-- switch to, so the fix is scoped to exactly this call: force the classic
-- "C" locale on the spawned process only (jobstart's `env` MERGES onto the
-- inherited environment rather than replacing it, so PATH/HOME etc. are
-- untouched) rather than requiring the operator's whole session to run
-- un-localized.
function M.list_models(cb)
  local out = {}
  local job = vim.fn.jobstart({ config.cmd(), "--list-models" }, {
    env = { LC_ALL = "C" },
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(out, data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        log.guard("yana.agent list_models on_exit", function()
          local models = {}
          local seen = {}
          for _, line in ipairs(out) do
            local id, label = line:match("^(%S+)%s+%-%s+(.+)$")
            if id and not seen[id] then
              seen[id] = true
              local current = label:match("%(current%)") ~= nil
              local default = label:match("%(default%)") ~= nil
              label = label:gsub("%s*%(current%)%s*$", ""):gsub("%s*%(default%)%s*$", "")
              table.insert(models, { id = id, label = label, current = current, default = default })
            end
          end
          cb(models, code)
        end)
      end)
    end,
  })

  if job <= 0 then
    cb({}, -1)
  end
end

return M
