-- yana: runs cursor-agent headless and parses its stream-json (NDJSON) output.
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local record = require("yana.record")
local dependencies = require("yana.dependencies")

local M = {}
local uv = vim.uv or vim.loop
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
  ffi.cdef("typedef long ssize_t; ssize_t pread(int fd, void *buf, unsigned long count, long offset);")
end

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

----------------------------------------------------------------------
-- Turn liveness: what the agent last DID
----------------------------------------------------------------------
--
-- One decoder, two consumers. The panel's status line needs a short label for
-- the last stream event so "working" and "hung" stop looking the same, and the
-- turn's durable `meta.json` needs the same fact so a turn that never finished
-- still says where it stopped. Deriving it twice would let the two disagree
-- exactly when they matter, so it is derived once, here, in the module that
-- already owns stream-json decoding.
--
-- It exists because of a measured failure: on 2026-08-20 an inline turn's last
-- event was a vendor `taskToolCall` `started` (a nested subagent) and nothing
-- followed for 11 minutes. Subagent output is not forwarded into the parent
-- stream, so the only honest thing the parent can say is what it last saw and
-- how long ago.

--- The single `<name>ToolCall` member of a tool_call envelope, if there is one.
--- Vendor envelopes carry exactly one; anything else is not a tool call this
--- can describe, and nil is the honest answer.
local function tool_member(obj)
  local tc = obj.tool_call
  if type(tc) ~= "table" then
    return nil, nil
  end
  for k, v in pairs(tc) do
    if type(k) == "string" and type(v) == "table" and k:match("ToolCall$") then
      return k, v
    end
  end
  return nil, nil
end

--- Describe one decoded stream event for the liveness surfaces.
---
--- Returns a table { type, subtype, tool, call_id, description, nested, label,
--- timestamp_ms } or nil. nil means "this event carries no operator-meaningful
--- progress" (the echoed user prompt is the only such case today) and the
--- caller must KEEP its previous label rather than blanking it: an event with
--- nothing to say is not the same as the agent having said nothing.
function M.describe_event(obj)
  if type(obj) ~= "table" then
    return nil
  end
  local t, st = obj.type, obj.subtype
  if t == "tool_call" then
    local name, call = tool_member(obj)
    if not name then
      return nil
    end
    local info = {
      type = t,
      subtype = st,
      tool = name,
      call_id = obj.call_id,
      timestamp_ms = obj.timestamp_ms,
    }
    if name == "taskToolCall" then
      -- A nested subagent. Its `description` is the only thing the parent
      -- stream ever says about what the subagent is doing, so it IS the label.
      local args = type(call.args) == "table" and call.args or {}
      info.nested = true
      info.description = type(args.description) == "string" and args.description or nil
      local what = info.description or "nested task"
      info.label = (st == "completed") and ("task done: " .. what) or ("task: " .. what)
    else
      local short = name:gsub("ToolCall$", "")
      info.label = (st == "completed") and (short .. " done") or short
    end
    return info
  elseif t == "thinking" then
    return { type = t, subtype = st, label = "thinking", timestamp_ms = obj.timestamp_ms }
  elseif t == "assistant" then
    local only_thinking = true
    local any = false
    for _, item in ipairs((obj.message or {}).content or {}) do
      any = true
      if item.type ~= "thinking" then
        only_thinking = false
      end
    end
    return {
      type = t,
      subtype = st,
      label = (any and only_thinking) and "thinking" or "answering",
      timestamp_ms = obj.timestamp_ms,
    }
  elseif t == "result" then
    return { type = t, subtype = st, label = "result", timestamp_ms = obj.timestamp_ms }
  elseif t == "error" then
    return { type = t, subtype = st, label = "error", timestamp_ms = obj.timestamp_ms }
  elseif t == "system" then
    return {
      type = t,
      subtype = st,
      label = (st == "init") and "session start" or ("system " .. tostring(st)),
      timestamp_ms = obj.timestamp_ms,
    }
  end
  return nil
end

-- Why a turn ended, recorded BEFORE the signal is sent. The exit callback that
-- writes the durable evidence runs once the process is already gone and has
-- nothing left to ask, so a stop that did not say why at the time is a stop
-- whose reason is lost. Keyed by job id and cleared at exit.
local stop_reasons = {}
local job_status = {}
local sample_interval_ms = 2000
M._test = M._test or {}

M.DEFAULT_STOP_REASON = "stopped by the operator (:YanaStop)"

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function proc_children(pid)
  local out = {}
  local req = uv.fs_scandir("/proc/" .. tostring(pid) .. "/task")
  if not req then
    return out
  end
  while true do
    local tid = uv.fs_scandir_next(req)
    if not tid then
      break
    end
    local data = read_file("/proc/" .. tostring(pid) .. "/task/" .. tid .. "/children") or ""
    for child in data:gmatch("%d+") do
      out[#out + 1] = tonumber(child)
    end
  end
  return out
end

local function proc_tree(root)
  local seen, out, queue = {}, {}, { tonumber(root) }
  while #queue > 0 do
    local pid = table.remove(queue, 1)
    if pid and not seen[pid] and uv.fs_stat("/proc/" .. tostring(pid)) then
      seen[pid] = true
      out[#out + 1] = pid
      for _, child in ipairs(proc_children(pid)) do
        queue[#queue + 1] = child
      end
    end
  end
  return out
end

local clk_tck = nil
local function clock_ticks_per_second()
  if clk_tck then
    return clk_tck
  end
  local ok, out = pcall(vim.fn.system, { "getconf", "CLK_TCK" })
  clk_tck = tonumber(ok and out or nil) or 100
  return clk_tck
end

local function proc_ticks(pid)
  local path = "/proc/" .. tostring(pid) .. "/stat"
  local fd = uv.fs_open(path, "r", 0)
  local stat = nil
  if fd then
    stat = uv.fs_read(fd, 4096, 0)
    uv.fs_close(fd)
  end
  if not stat then
    return 0
  end
  local rest = stat:match("^%d+ %b() (.+)$")
  if not rest then
    return 0
  end
  local i, utime, stime = 0, nil, nil
  for v in rest:gmatch("%S+") do
    i = i + 1
    if i == 12 then
      utime = tonumber(v) or 0
    elseif i == 13 then
      stime = tonumber(v) or 0
      break
    end
  end
  return (utime or 0) + (stime or 0)
end

local function tree_ticks(pid)
  local total = 0
  for _, p in ipairs(proc_tree(pid)) do
    total = total + proc_ticks(p)
  end
  return total
end

local function ticks_for_pids(pids)
  local total = 0
  local live = {}
  for _, p in ipairs(pids or {}) do
    if uv.fs_stat("/proc/" .. tostring(p)) then
      live[#live + 1] = p
      total = total + proc_ticks(p)
    end
  end
  return total, live
end

local function ticks_for_status(status)
  local total = 0
  local live = {}
  status.stat_fds = status.stat_fds or {}
  for _, p in ipairs(status.pids or {}) do
    if uv.fs_stat("/proc/" .. tostring(p)) then
      live[#live + 1] = p
      local fd = status.stat_fds[p]
      if not fd then
        fd = uv.fs_open("/proc/" .. tostring(p) .. "/stat", "r", 0)
        status.stat_fds[p] = fd
      end
      local stat = nil
      if fd and ffi_ok then
        local n = ffi.C.pread(fd, status.stat_buf, 4095, 0)
        if n > 0 then
          stat = ffi.string(status.stat_buf, n)
        end
      elseif fd then
        stat = uv.fs_read(fd, 4096, 0)
      end
      if stat then
        local rest = stat:match("^%d+ %b() (.+)$")
        if rest then
          local i, utime, stime = 0, nil, nil
          for v in rest:gmatch("%S+") do
            i = i + 1
            if i == 12 then
              utime = tonumber(v) or 0
            elseif i == 13 then
              stime = tonumber(v) or 0
              break
            end
          end
          total = total + (utime or 0) + (stime or 0)
        end
      end
    elseif status.stat_fds[p] then
      pcall(uv.fs_close, status.stat_fds[p])
      status.stat_fds[p] = nil
    end
  end
  return total, live
end

local function start_cpu_sampler(job, pid)
  if not (job and job > 0 and pid and pid > 0) then
    return
  end
  local pids = proc_tree(pid)
  local fds = {}
  for _, p in ipairs(pids) do
    fds[p] = uv.fs_open("/proc/" .. tostring(p) .. "/stat", "r", 0)
  end
  local status = {
    job = job,
    pid = pid,
    cpu_pct = 0,
    last_activity_ms = nil,
    sample_count = 0,
    sample_cost_ms_total = 0,
    sample_cpu_ms_total = 0,
    last_event_hr = nil,
    last_sample_hr = uv.hrtime(),
    last_ticks = tree_ticks(pid),
    hz = clock_ticks_per_second(),
    pids = pids,
    stat_fds = fds,
    stat_buf = ffi_ok and ffi.new("char[4096]") or nil,
  }
  job_status[job] = status
  local timer = uv.new_timer()
  status.timer = timer
  timer:start(sample_interval_ms, sample_interval_ms, vim.schedule_wrap(function()
    log.guard("yana.agent cpu sampler", function()
      if not job_status[job] then
        return
      end
      local t0 = uv.hrtime()
      if status.sample_count > 0 and status.sample_count % 30 == 0 then
        status.pids = proc_tree(pid)
      end
      local now = uv.hrtime()
      local ticks, live_pids = ticks_for_status(status)
      status.pids = (#live_pids > 0) and live_pids or { pid }
      local dt_ms = (now - status.last_sample_hr) / 1e6
      local dt_ticks = ticks - status.last_ticks
      if dt_ms > 0 and dt_ticks >= 0 then
        status.cpu_pct = (dt_ticks / status.hz) / (dt_ms / 1000) * 100
      end
      status.last_sample_hr = now
      status.last_ticks = ticks
      status.sample_count = status.sample_count + 1
      status.sample_cpu_ms_total = status.sample_cpu_ms_total + ((uv.hrtime() - t0) / 1e6)
      status.sample_cost_ms_total = status.sample_cost_ms_total + ((uv.hrtime() - t0) / 1e6)
    end)
  end))
end

local function stop_cpu_sampler(job)
  local status = job_status[job]
  if status and status.timer then
    status.timer:stop()
    if not status.timer:is_closing() then
      status.timer:close()
    end
    status.timer = nil
  end
  for _, fd in pairs(status and status.stat_fds or {}) do
    pcall(uv.fs_close, fd)
  end
  if status then
    status.stat_fds = nil
  end
end

function M.status(job)
  local status = job and job_status[job] or nil
  if not status then
    return nil
  end
  return {
    job = status.job,
    pid = status.pid,
    cpu_pct = status.cpu_pct or 0,
    sample_count = status.sample_count or 0,
    sample_cost_ms_total = status.sample_cost_ms_total or 0,
    sample_cpu_ms_total = status.sample_cpu_ms_total or 0,
    sample_cost_ms_avg = (status.sample_count or 0) > 0
      and ((status.sample_cost_ms_total or 0) / status.sample_count)
      or 0,
  }
end

function M._test.set_sample_interval_ms(ms)
  sample_interval_ms = (type(ms) == "number" and ms > 0) and ms or 2000
end

function M._test.force_status(job, status)
  job_status[job] = status
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
    req.jail_session.mode = req.mode or config.options.mode
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
      local described = M.describe_event(obj)
      if described then
        described.at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        last_event = described
      end
      local st = job_id and job_status[job_id] or nil
      if st then
        st.last_event_hr = uv.hrtime()
      end
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
          -- A stop recorded before the signal wins; otherwise the exit
          -- code is the reason. Either way the record always says something:
          -- "no reason" is the state that made the 2026-08-20 turn unreadable.
          local key = jid or job_id
          local stop_reason = key and stop_reasons[key] or nil
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
          if job_env and job_env.YANA_INLINE_EXEC_ALLOWLIST_ACTIVE == "1" then
            local stderr_text = table.concat(stderr_acc, "\n")
            -- AUTHORITATIVE FIRST: bin/yana-overlay-inner's own exec attempt,
            -- when it is the one that fails, prints a structured line naming
            -- the exact argv0 and the real errno the exec(2) call itself saw
            -- (`yana-exec-refused argv0=<path> errno=<NAME>`) -- see its
            -- refuse_exec(). That is sourced from the syscall, not inferred,
            -- so it is trusted outright and the free-text scan below never
            -- runs when it is present.
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
              -- FALLBACK ONLY: a refusal that happens deeper than this
              -- process's own final exec (e.g. inside the agent's own
              -- shelled-out children) never reaches the structured line
              -- above, so this free-text scan over the agent's raw stderr
              -- is the only signal left. It is a heuristic -- English
              -- shell error text, not a syscall errno -- and is labelled
              -- as such so a caller never mistakes it for the authoritative
              -- source.
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
  if job and job > 0 and not stop_reasons[job] then
    stop_reasons[job] = { reason = M.DEFAULT_STOP_REASON .. "; escalated to SIGKILL" }
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
