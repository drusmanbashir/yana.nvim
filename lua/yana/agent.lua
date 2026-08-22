-- yana: runs cursor-agent headless and parses its stream-json (NDJSON) output.
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local record = require("yana.record")
local dependencies = require("yana.dependencies")
local notify = require("yana.notify")

local M = {}
local uv = vim.uv or vim.loop
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
  ffi.cdef("typedef long ssize_t; ssize_t pread(int fd, void *buf, unsigned long count, long offset);")
end

-- Build the argv used to invoke the ACTIVE BACKEND for a single request.
-- req: { prompt, mode, model, session_id }
--
-- Layer 1 (which backend/binary/account) is decided by config.cmd(), which
-- resolves through the active `config.options.backend` entry
-- (config.resolve_cmd). Layer 2 (which flags that backend's argv carries) is
-- decided here. THE INVARIANTS BELOW ARE YANA'S, NOT THE ENTRY'S (operator
-- ruling, 2026-08-21: "an entry declares spellings, never policy") -- this
-- function places every flag at a fixed point, in a fixed order, and only
-- ever asks the active backend's DESCRIPTOR (config.backend_descriptor) for
-- the TOKEN that vendor uses to say it, never for whether or where. The
-- descriptor table in config.lua's `M.defaults.backends` is the declarative
-- "zoo" entry (avante.nvim's `providers` shape) an operator can extend
-- without touching this file -- see its doc comment for the exact list of
-- what an entry cannot influence and what enforces each. No field read below
-- ever translates the STREAM (claude nests tool_use inside
-- assistant.message.content[] where cursor emits top-level tool_call
-- events) -- that stays out of scope here; see cp/ingest-from-disk, which
-- removes the dependency on stream shape entirely by deriving the review
-- list from the overlay instead of the stream.
--
-- The shipped "cursor" descriptor's fields reproduce exactly what this
-- function hard-coded before backends existed, so the default argv is
-- byte-identical: an operator who sets nothing sees no change.
local function build_cmd(req)
  local o = config.options
  local backend_name = o.backend or config.defaults.backend
  local bd = config.backend_descriptor(backend_name) or {}
  local cmd = { config.cmd() }

  -- Work order VENDORS: `subcommand` tokens (codex: {"exec"}) are placed
  -- IMMEDIATELY after `cmd`, before every flag Yana adds below.
  if bd.subcommand then
    vim.list_extend(cmd, bd.subcommand)
  end

  -- Work order VENDORS, resume-as-subcommand shape ONLY: when this turn is a
  -- resume AND the active backend resumes via a subcommand rather than a
  -- flag (bd.resume_subcommand, e.g. codex's `exec resume <id>`), those
  -- tokens plus the POSITIONAL session id go directly after `subcommand`,
  -- before every other flag -- never at the tail where bd.resume_flag's
  -- `--resume <id>` pair goes (see the tail of this function). The two
  -- shapes are mutually exclusive at setup (M.normalize_backends), so at
  -- most one of them ever fires for a given turn.
  local has_session = req.session_id and req.session_id ~= ""
  local resumes_by_subcommand = has_session and bd.resume_subcommand ~= nil
  if resumes_by_subcommand then
    vim.list_extend(cmd, bd.resume_subcommand)
    table.insert(cmd, req.session_id)
  end

  -- INVARIANT: every turn runs non-interactively. Yana places the flag;
  -- bd.noninteractive_flag only supplies this vendor's spelling of it
  -- (required, validated non-empty at setup -- config.lua's require_flag) --
  -- UNLESS it is the literal `false`, meaning this vendor's `subcommand`
  -- IS its non-interactive mode already (codex's `exec`), in which case
  -- Yana places no separate token at all.
  if bd.noninteractive_flag then
    table.insert(cmd, bd.noninteractive_flag)
  end

  -- INVARIANT: every turn requests the JSON event stream agent.lua's own
  -- parser depends on. bd.stream_json_args is required and validated at
  -- setup to literally contain this vendor's protocol request token
  -- (M.normalize_backends) so an entry cannot silently swap the format
  -- Yana parses.
  vim.list_extend(cmd, bd.stream_json_args or {})

  -- CURSOR-SPECIFIC SPELLING, deliberately NOT a schema field (operator
  -- ruling, 2026-08-21): --trust/--approve-mcps are cursor's own words for
  -- cursor's own ideas (a one-time workspace-trust prompt, MCP-server
  -- consent) that most vendors have no concept of at all. Promoting them to
  -- a generic per-backend field would force every future vendor entry to
  -- declare nil for something that was never theirs. `o.trust`/
  -- `o.approve_mcps` predate the backends feature and have only ever meant
  -- "cursor-agent, don't prompt me for this"; if a future backend earns an
  -- equivalent concept, it gets its own named capability then, on evidence.
  if backend_name == "cursor" then
    if o.trust then
      table.insert(cmd, "--trust")
    end
    if o.approve_mcps then
      table.insert(cmd, "--approve-mcps")
    end
  end

  -- The vendor permission mode is a CONSEQUENCE of the dial, never an operator
  -- option. `plan` is gone as a mode: it was a way of asking, and it is reached
  -- by asking for a plan in `ask` (the mode contract).
  local mode = req.mode or config.agent_permission_mode()
  if mode == "ask" or mode == "plan" then
    -- bd.ask_args == nil is a real, documented gap (see the "claude" entry's
    -- comment in config.lua): this backend has no non-interactive ask
    -- equivalent, so nothing is appended rather than guessing a flag that
    -- would hang a headless turn.
    if bd.ask_args then
      vim.list_extend(cmd, bd.ask_args)
    end
  elseif config.agent_needs_permission_flag() then
    -- config.agent_needs_permission_flag() is the single place this is
    -- decided; see its comment for the adjudicated reasoning and the
    -- revisit trigger. bd.allow_edits_args is REQUIRED and validated non-nil
    -- at setup (may be `{}`) -- a turn that needs edit permission always
    -- gets it, by construction: an entry cannot leave a mode able to write
    -- silently unable to (operator ruling, 2026-08-21).
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

  -- Resume keeps the same conversation/session for follow-up turns. Session
  -- ids are VENDOR-SPECIFIC (row 58's sharp edge): ui.lua is responsible for
  -- never handing this function a session_id that belongs to a different
  -- backend than the one currently active (see M.resume's refusal and
  -- pick_backend's session-drop in ui.lua) -- this function only adds the
  -- flag when the active backend's descriptor has one. Skipped entirely when
  -- `resumes_by_subcommand` already placed the session id earlier (right
  -- after `subcommand`) -- the two resume shapes never both fire.
  if has_session and not resumes_by_subcommand and bd.resume_flag then
    vim.list_extend(cmd, { bd.resume_flag, req.session_id })
  end

  -- Prompt is positional and passed as a single argv element (no shell), so
  -- newlines and special characters are safe. Placed last by Yana itself,
  -- always -- no capability list above can relocate or impersonate it.
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
  -- Row 76: the requested/actual model comparison fires once per turn, from
  -- the first system event that names a model — a later disagreement would
  -- itself be a new fact, same "first write wins" rule `rec:note_model_actual`
  -- already follows.
  local model_mismatch_checked = false

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

  -- LAYER 1 NARRATION. Every vendor speaks its own event dialect; the panel
  -- reads exactly one of them (cursor's). The normalizer translates the other
  -- protocols into that shape so `on_event` never learns there was a second
  -- vendor. It is per-turn state because claude reports a tool's ARGUMENTS and
  -- its RESULT in two separate events, so the pairing has to be remembered
  -- across lines. `cursor` returns each event unchanged, which is what keeps
  -- the default path byte-identical to pre-backends Yana.
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
      local described = M.describe_event(obj)
      if described then
        described.at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        last_event = described
      end
      -- The vendor's system/init event carries the model it ACTUALLY used,
      -- which is a fact distinct from `req.model` (what Yana requested) and
      -- can disagree with it silently — the only way to catch a model switch
      -- that did not take. Recorded once, from the first system event that
      -- names one, since a later disagreement would itself be a new fact.
      -- This runs whether or not opt-in recording (`rec`) is on: the
      -- disagreement is a UX fact the operator needs regardless of whether
      -- they also asked for a raw stream tee (row 76).
      if obj.type == "system" and type(obj.model) == "string" and obj.model ~= "" then
        if rec then
          rec:note_model_actual(obj.model)
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
  }
  if spawn_bd.close_stdin then
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

-- `list_models_format == "lines"` (default; cursor's shape) parser. Requires
-- literal English: `ID - label`, with optional literal `(current)` /
-- `(default)` markers. cursor-agent inherits Neovim's (i.e. the operator's
-- shell's) locale, and under a non-English LANG/LC_ALL it may emit localized
-- labels or a different separator, silently emptying the model list or
-- losing current/default status (PORT-12, portability review). There is no
-- documented machine-readable --list-models format to switch to, so the fix
-- is scoped to exactly this call: M.list_models forces the classic "C"
-- locale on the spawned process only (jobstart's `env` MERGES onto the
-- inherited environment rather than replacing it, so PATH/HOME etc. are
-- untouched) rather than requiring the operator's whole session to run
-- un-localized.
local function parse_lines_models(out)
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
  return models
end

-- `list_models_format == "json_models"` parser (codex's `debug models`
-- shape, work order VENDORS): `{"models":[{slug,display_name,visibility,...}]}`.
-- Keeps only `visibility == "list"` entries (`"hide"` entries -- e.g. codex's
-- `gpt-reserve`, `codex-auto-review` -- are filtered out, never offered to
-- the operator) and maps `slug` -> id, `display_name` -> label. Deliberately
-- NEVER reads `model_messages` or any other field: that object carries a
-- large prompt-template payload that must not enter the picker, a log, or a
-- fixture (see tests/fixtures/codex-models.json, trimmed to exactly these
-- three fields for the same reason). A malformed/undecodable payload yields
-- an empty list rather than throwing -- on_exit's log.guard would already
-- catch a throw, but an empty list is the more honest signal here (nothing
-- USABLE was found), not "something crashed".
local function parse_json_models(out)
  local ok, decoded = pcall(vim.json.decode, table.concat(out, "\n"))
  if not ok or type(decoded) ~= "table" or type(decoded.models) ~= "table" then
    return {}
  end
  local models = {}
  for _, m in ipairs(decoded.models) do
    if type(m) == "table" and m.visibility == "list" and type(m.slug) == "string" and m.slug ~= "" then
      local label = m.display_name
      if type(label) ~= "string" or label == "" then
        label = m.slug
      end
      table.insert(models, { id = m.slug, label = label })
    end
  end
  return models
end

-- Per-backend model catalogue cache (session-scoped). Keyed by backend name
-- so a vendor switch never shows another vendor's list (row 58). Filled at
-- setup via M.prefetch_model_lists and on first pick; successes stick for
-- the Neovim process so \am / :YanaModel do not re-spawn the CLI.
--
-- Entry shapes:
--   { status = "ready", models, code, reason }
--   { status = "pending", waiters = { cb, ... } }
-- Failed spawns are NOT cached (retry on next pick). Unsupported (-2) and
-- static `bd.models` catalogues ARE cached.
local model_list_cache = {}

local function cache_notify_waiters(entry, models, code, reason)
  local waiters = entry.waiters or {}
  entry.waiters = nil
  for _, w in ipairs(waiters) do
    w(models, code, reason)
  end
end

--- Snapshot if this backend's list is already warm. Returns
--- models, code, reason or nil when missing/pending.
function M.cached_model_list(backend)
  local entry = model_list_cache[backend]
  if entry and entry.status == "ready" then
    return entry.models, entry.code, entry.reason
  end
  return nil
end

--- Clear one backend (or every backend when nil). Tests / force-refresh.
function M.clear_model_list_cache(backend)
  if backend then
    model_list_cache[backend] = nil
  else
    model_list_cache = {}
  end
end

-- List available models via a backend's `list_models_args`.
-- cb(models, code, reason) where models = { { id, label, current, default }, ... }.
--
-- opts.backend  — which vendor (default: active). Prefetch and the vendor
--                 cascade pass the name explicitly.
-- opts.force    — bypass cache and re-spawn.
--
-- code -2 means "this backend's descriptor declares list_models =
-- false" -- reason names the backend. Requirement 4 (row 58): a backend that
-- cannot list models must degrade HONESTLY (say so in the picker) rather
-- than silently showing the PREVIOUS backend's list under the new backend's
-- name, which would recreate the exact vendor-confusion this feature exists
-- to remove. Checked before spawning anything, so an unsupported backend
-- never even attempts to list models against a binary that would not
-- understand it.
--
-- Work order VENDORS: the argv built below is DELIBERATELY `{cmd} ++
-- list_models_args` and nothing else -- it never prepends `bd.subcommand`.
-- codex's `debug models` is NOT a subcommand of `exec`; it REPLACES
-- `subcommand` entirely, so `codex debug models` is correct and
-- `codex exec debug models` (what prepending subcommand would produce) is
-- not a command codex understands at all.
function M.list_models(cb, opts)
  opts = opts or {}
  local backend = opts.backend or config.options.backend
  local bd = config.backend_descriptor(backend) or {}

  if not opts.force then
    local cached = model_list_cache[backend]
    if cached and cached.status == "ready" then
      cb(cached.models, cached.code, cached.reason)
      return
    end
    if cached and cached.status == "pending" then
      cached.waiters[#cached.waiters + 1] = cb
      return
    end
  end

  if not bd.list_models_args then
    -- Static catalogue (e.g. claude): treat as a ready cache entry so the
    -- picker and prefetch share one path. Empty/absent still degrades -2.
    if bd.models and #bd.models > 0 then
      local models = {}
      for _, m in ipairs(bd.models) do
        models[#models + 1] = { id = m.id, label = m.label }
      end
      model_list_cache[backend] = { status = "ready", models = models, code = 0, reason = nil }
      cb(models, 0, nil)
      return
    end
    local reason = backend .. " does not support listing models"
    model_list_cache[backend] = { status = "ready", models = {}, code = -2, reason = reason }
    cb({}, -2, reason)
    return
  end

  local pending = { status = "pending", waiters = { cb } }
  model_list_cache[backend] = pending

  local out = {}
  -- MUST resolve THIS backend's binary, not the active dial — prefetch runs
  -- for every vendor while the operator may still be on another one.
  local argv = { config.cmd(backend) }
  vim.list_extend(argv, bd.list_models_args)
  local job = vim.fn.jobstart(argv, {
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
          local models
          if bd.list_models_format == "json_models" then
            models = parse_json_models(out)
          else
            models = parse_lines_models(out)
          end
          local entry = model_list_cache[backend]
          if code == 0 and #models > 0 then
            model_list_cache[backend] = { status = "ready", models = models, code = 0, reason = nil }
          else
            -- Leave uncached on failure so the next pick retries.
            if entry and entry.status == "pending" then
              model_list_cache[backend] = nil
            end
          end
          cache_notify_waiters(entry or pending, models, code, nil)
        end)
      end)
    end,
  })

  if job <= 0 then
    model_list_cache[backend] = nil
    cache_notify_waiters(pending, {}, -1, nil)
  end
end

--- Warm every configured backend's model list in the background at setup.
--- Static catalogues fill synchronously; CLI listings spawn and fill the
--- cache without blocking setup() return.
function M.prefetch_model_lists()
  local backends = config.options.backends or {}
  for name, _ in pairs(backends) do
    M.list_models(function() end, { backend = name })
  end
end

return M
