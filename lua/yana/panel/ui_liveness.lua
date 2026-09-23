-- Turn liveness clock + spinner (split from yana.ui).
local agent = require("yana.agent.agent")
local config = require("yana.config")
local log = require("yana.log")
local uv = vim.uv or vim.loop

local M = {}

function M.new(deps)
  local S = deps.state
  local update_winbar = deps.update_winbar

  local STALL_THRESHOLD_MS = 90000
  local stall_threshold_override = nil

  local function stall_threshold_ms()
    return stall_threshold_override or STALL_THRESHOLD_MS
  end

  -- Durations an operator reads at a glance, not a precise instrument: seconds
  -- under a minute, m+s under an hour, h+m above it.
  local function fmt_duration(ms)
    local secs = math.floor((tonumber(ms) or 0) / 1000)
    if secs < 0 then
      secs = 0
    end
    if secs < 60 then
      return string.format("%ds", secs)
    end
    local mins = math.floor(secs / 60)
    if mins < 60 then
      return string.format("%dm%02ds", mins, secs % 60)
    end
    return string.format("%dh%02dm", math.floor(mins / 60), mins % 60)
  end

  -- The label is AGENT TEXT on a statusline-syntax option. A nested task's
  -- description is whatever the model wrote, so it gets the same treatment the
  -- session title needed after a prompt containing "%" wedged a whole session:
  -- control characters folded to spaces (one would split the line), length
  -- bounded, and every "%" doubled LAST, after truncation, so the escape cannot
  -- itself be cut in half.
  local LABEL_MAX = 40
  local function status_label(text)
    if type(text) ~= "string" then
      return nil
    end
    local s = text:gsub("%c", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then
      return nil
    end
    if #s > LABEL_MAX then
      s = s:sub(1, LABEL_MAX - 1) .. "…"
    end
    return (s:gsub("%%", "%%%%"))
  end

  -- Liveness state is per TURN, keyed by the generation, so it is created by the
  -- first thing that asks for it after a submit and can never carry a previous
  -- turn's clock into a new one. Lazy on purpose: the submit path already calls
  -- update_winbar immediately after start_spinner, so the clock starts within
  -- microseconds of the turn starting without this having to reach into the
  -- submit path at all.
  local function liveness_for(p)
    local live = p.liveness
    if not live or live.gen ~= p.turn_gen then
      live = {
        gen = p.turn_gen,
        started_hr = uv.hrtime(),
        last_event_hr = nil,
        label = nil,
        last_event = nil,
        events = 0,
        open_tasks = {},
        open_task_count = 0,
        tasks_started = 0,
        tasks_completed = 0,
        forensics = nil,
      }
      p.liveness = live
    end
    return live
  end

  -- Stamp the last event. Called for EVERY decoded event of the current turn,
  -- before any rendering gate can drop it: an event the panel chose not to
  -- render still proves the agent is producing output, and "time since the last
  -- event" would lie if it only counted the ones that reached the buffer.
  --
  -- Nested tasks pair by `call_id`, which is the only identity the vendor gives
  -- them. Pairing is what lets a completion whose own payload has lost the
  -- description still name the task the operator was watching, and what keeps
  -- an unrelated completion from closing it.
  local function note_liveness_event(p, gen, obj)
    if not p or gen ~= p.turn_gen then
      return
    end
    local live = liveness_for(p)
    live.last_event_hr = uv.hrtime()
    live.events = (live.events or 0) + 1
    local info = agent.describe_event(obj)
    if not info then
      -- Nothing meaningful to say; the previous label stands. Blanking it would
      -- report "the agent is doing nothing", which is a different claim.
      return
    end
    if info.nested and info.call_id then
      if info.subtype == "completed" then
        local open = live.open_tasks[info.call_id]
        if open then
          live.open_tasks[info.call_id] = nil
          live.open_task_count = math.max(0, live.open_task_count - 1)
          live.tasks_completed = live.tasks_completed + 1
          if open.description and not info.description then
            info.description = open.description
            info.label = "task done: " .. open.description
          end
        end
      elseif info.subtype == "started" and live.open_tasks[info.call_id] == nil then
        live.open_tasks[info.call_id] = {
          description = info.description,
          started_hr = live.last_event_hr,
          marker_emitted = false,
        }
        live.open_task_count = live.open_task_count + 1
        live.tasks_started = live.tasks_started + 1
        -- If the task is still open but young, wait the remainder and look again.
        local function arm_open_marker(delay_ms)
        vim.defer_fn(function()
          log.guard("yana.ui tool_call.open marker", function()
            local cur = p and p.liveness
            local open = cur and cur.open_tasks and cur.open_tasks[info.call_id]
            if not open or open.marker_emitted or cur.gen ~= gen then
              return
            end
            local age_exact = (uv.hrtime() - open.started_hr) / 1e6
            local age_ms = math.floor(age_exact)
            if age_exact < stall_threshold_ms() then
              arm_open_marker(math.max(1, math.ceil(stall_threshold_ms() - age_exact)))
              return
            end
            open.marker_emitted = true
            local desc = open.description or "nested task"
            log.lifecycle("tool_call.open", {
              panel = p.id,
              generation = gen,
              call_id = info.call_id,
              age_ms = age_ms,
              description = desc,
            })
            if S.render_note then
              S.render_note(p, string.format("sub-task open for %s: %s", fmt_duration(age_ms), desc))
            end
          end)
        end, delay_ms)
        end
        arm_open_marker(stall_threshold_ms())
      end
    end
    live.last_event = info
    live.label = status_label(info.label) or live.label
  end

  -- The status segment itself. Empty unless a turn is in flight: an idle panel
  -- has no elapsed time to report and a counter that keeps running after the
  -- turn ended would be the same lie a spinner that outlives its operation is.
  local function liveness_text(p)
    if not p.busy then
      return ""
    end
    local live = liveness_for(p)
    local now = uv.hrtime()
    local elapsed = math.floor((now - live.started_hr) / 1e6)
    local quiet = math.floor((now - (live.last_event_hr or live.started_hr)) / 1e6)
    local ast = agent.status(p.job)
    local cpu = ast and tonumber(ast.cpu_pct) or 0
    -- Turn liveness: system/init starts
    -- the same clock already shown as elapsed time, so its quiet clock adds no
    -- fact. Begin the `since` field with the first later event.
    local initialization_only = live.last_event == nil
      or (live.last_event.type == "system" and live.last_event.subtype == "init")
    local label = live.label or "starting"
    if quiet >= stall_threshold_ms() and cpu > 0.1 then
      return string.format(
        " · %s · working silently (CPU %.1f%%) · last: %s",
        fmt_duration(elapsed),
        cpu,
        label
      )
    end
    if quiet >= stall_threshold_ms() then
      return string.format(
        " · %s · stalled %s — :YanaStop · last: %s",
        fmt_duration(elapsed),
        fmt_duration(quiet),
        label
      )
    end
    if initialization_only then
      return string.format(" · %s", fmt_duration(elapsed))
    end
    return string.format(" · %s · %s since %s", fmt_duration(elapsed), fmt_duration(quiet), label)
  end

  local function stop_spinner(p)
    if p.spinner.timer then
      p.spinner.timer:stop()
      if not p.spinner.timer:is_closing() then
        p.spinner.timer:close()
      end
      p.spinner.timer = nil
    end
  end

  local function start_spinner(p)
    stop_spinner(p)
    p.spinner.idx = 1
    local timer = uv.new_timer()
    p.spinner.timer = timer
    timer:start(0, 100, vim.schedule_wrap(function()
      log.guard("yana.ui spinner timer", function()
        if not p.busy and not p.applying then
          stop_spinner(p)
          return
        end
        local frames = config.options.ui.spinner
        p.spinner.idx = (p.spinner.idx % #frames) + 1
        update_winbar(p)
      end)
    end))
  end

  return {
    stall_threshold_ms = stall_threshold_ms,
    liveness_for = liveness_for,
    liveness_text = liveness_text,
    note_liveness_event = note_liveness_event,
    stop_spinner = stop_spinner,
    start_spinner = start_spinner,
    set_stall_threshold_override = function(ms)
      stall_threshold_override = (type(ms) == "number" and ms > 0) and ms or nil
    end,
  }
end

return M
