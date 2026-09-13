-- yana: the per-turn flight recorder.
--
-- One in-memory table per (panel, gen). It stamps the turn's phase spine,
-- counts every event class, and holds the three-record provenance chain
-- (spawns, event seqs, panel appends) that makes a repeated panel sentence
-- attributable: one spawn with distinct event seqs is vendor churn, several
-- spawns is a Yana respawn, one event seq with several appends is render
-- duplication.
--
-- Rules this module obeys, and which every capture site inherits:
--
-- * It OBSERVES. Nothing here changes control flow, refuses anything, or repairs
-- anything. Every entry point is total: an unknown panel, an unknown turn or a
-- malformed record stores what it can and returns.
--
-- Calling convention: every recorder takes the ledger TABLE as its first
-- argument. Capture sites resolve it once with `ensure(panel_id, gen)` and
-- then call directly, so a hot path costs one hash lookup and one increment.
--
-- Schema note for tests: the field names in this file ARE the log schema. The
-- flow report and the gate fixtures read them, so renaming one is a schema
-- change, not a refactor.
local M = {}

local uv = vim.uv or vim.loop

-- Retention. Bounded so a long editing session cannot grow the ledger without
-- limit; old turns are pruned whole rather than truncated in place, so the
-- turns that remain are always complete.
M.LIMITS = {
  turns_per_panel = 8,
  -- Per-panel retention alone is not a bound. Two things fix it: panel teardown calls
  -- `M.drop_panel`, and this global cap holds even if a teardown path is ever missed.
  turns_total = 32,
  appends = 200,
  spawns = 32,
  decisions = 200,
  refusal_groups = 64,
  render_checks = 24,
  hunk_files = 64,
  append_text = 120,
}

-- `accept_applied` means a journaled write completed. `accept_transferred` means
-- accepted lines crossed to a loaded buffer and nothing was written.
M.PHASES = {
  "turn_submitted",
  "confinement_established",
  "process_spawned",
  "first_event_decoded",
  "session_init",
  "first_tool_call",
  "result_received",
  "exit_confirmed",
  "change_set_read",
  "apply_pass_began",
  "review_claim_open",
  "first_review_opened",
  "review_setup_complete",
  "review_redraw",
  "review_resolved",
  "accept_applied",
  "accept_transferred",
}

local PHASE_ORDER = {}
for i, name in ipairs(M.PHASES) do
  PHASE_ORDER[name] = i
end

-- Every counter that exists, declared up front: a counter that springs into
-- existence when it first fires cannot be told apart from a capture that
-- never ran, and "the field is missing" is exactly the ambiguity this ledger
-- exists to remove.
local function new_counters()
  return {
    events_total = 0,
    events_system = 0,
    events_assistant = 0,
    events_tool_call = 0,
    events_result = 0,
    events_error = 0,
    events_other = 0,
    events_stale_dropped = 0,
    events_stale_disk_bearing = 0,
    decode_failures = 0,
    tool_calls_completed = 0,
    changes_parsed = 0,
    changes_batched = 0,
    changes_coalesced = 0,
    reviews_enqueued = 0,
    reviews_opened = 0,
    reviews_refused = 0,
    ops_system_refused = 0,
    scope_rejections = 0,
    panel_appends = 0,
    panel_append_lines = 0,
    stream_renders = 0,
    notify_info = 0,
    notify_warn = 0,
    notify_error = 0,
    render_checks = 0,
    render_violations = 0,
    recorded_lines = 0,
    review_retries = 0,
    retry_announcements = 0,
    pending_desyncs = 0,
    session_registry_misses = 0,
  }
end

-- panel_id -> { [gen] = ledger }, plus a creation-ordered list for the dump.
local by_panel = {}
local all_turns = {}
local _turn_seq = 0

local function now_ns()
  return uv.hrtime()
end

local function wall_ms()
  local ok, sec, usec = pcall(uv.gettimeofday)
  if ok and type(sec) == "number" then
    return sec * 1000 + math.floor((usec or 0) / 1000)
  end
  return os.time() * 1000
end

-- Format a wall-clock ms timestamp as an ISO string with millis.
function M.wall_stamp(ms)
  ms = ms or wall_ms()
  local secs = math.floor(ms / 1000)
  return string.format("%s.%03d", os.date("%Y-%m-%dT%H:%M:%S", secs), ms % 1000)
end

--- Milliseconds since the turn opened, to microsecond resolution, kept as a
--- number so a report can sum or sort it.
local function since(L, ns)
  return math.floor(((ns or now_ns()) - L.t0) / 1000) / 1000
end

M.since = since

--- Forget one turn everywhere it is held. Both tables or neither: a turn left
--- in `all_turns` after its panel bucket is gone still shows up in every dump.
local function forget(L)
  local turns = by_panel[L.panel_id]
  if turns then
    turns[L.gen] = nil
    if next(turns) == nil then
      -- Drop the empty bucket too, or `by_panel` keeps one table per panel id
      -- ever created, which is the leak in a smaller form.
      by_panel[L.panel_id] = nil
    end
  end
  for j = #all_turns, 1, -1 do
    if all_turns[j] == L then
      table.remove(all_turns, j)
      break
    end
  end
end

--- The global bound. `all_turns` is append-ordered, so the oldest live at the
--- front; drop whole turns from there until the cap holds.
local function prune_global()
  while #all_turns > M.LIMITS.turns_total do
    forget(all_turns[1])
  end
end

--- Called from ui.lua's quit_panel: the ledger cannot observe panel teardown itself,
--- and without this the records of a destroyed panel outlive it for the rest of the
--- session.
function M.drop_panel(panel_id)
  local turns = by_panel[panel_id or 0]
  if not turns then
    return 0
  end
  local dropped = 0
  for _, L in pairs(turns) do
    for j = #all_turns, 1, -1 do
      if all_turns[j] == L then
        table.remove(all_turns, j)
        break
      end
    end
    dropped = dropped + 1
  end
  by_panel[panel_id or 0] = nil
  return dropped
end

local function prune_panel(panel_id)
  local turns = by_panel[panel_id]
  if not turns then
    return
  end
  local gens = {}
  for gen in pairs(turns) do
    gens[#gens + 1] = gen
  end
  if #gens <= M.LIMITS.turns_per_panel then
    return
  end
  table.sort(gens, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local drop = #gens - M.LIMITS.turns_per_panel
  for i = 1, drop do
    forget(turns[gens[i]])
  end
end

local function make(panel_id, gen)
  _turn_seq = _turn_seq + 1
  local started_ms = wall_ms()
  return {
    seq = _turn_seq,
    panel_id = panel_id,
    gen = gen,
    turn_key = string.format("p%s#%s", tostring(panel_id), tostring(gen)),
    t0 = now_ns(),
    wall_start_ms = started_ms,
    wall_start = M.wall_stamp(started_ms),
    synthetic = false,
    closed = false,
    phases = {},
    phase_marks = {},
    counters = new_counters(),
    spawns = {},
    appends = {},
    appends_dropped = 0,
    append_seq = 0,
    event_seq = 0,
    event_seq_current = nil,
    usage = nil,
    hunks = {},
    hunk_order = {},
    render_checks = {},
    render_checks_dropped = 0,
    spawns_dropped = 0,
    hunk_files_dropped = 0,
    decisions = {},
    decisions_dropped = 0,
    refusal_groups = {},
    refusal_groups_dropped = 0,
    recording = nil,
    outcome = nil,
    pending_check = nil,
    turn = {},
    -- Preallocated record slots. The default hot path must allocate NOTHING
    -- per decoded event, so `note_event` / `note_decode_failure` MUTATE these
    -- fixed tables instead of building one per event. The public fields
    -- (`last_event`, `last_decode_failure`) are published — pointed at the
    -- slot — on first use, so "nothing decoded yet" is still distinguishable
    -- from "decoded an event with empty fields".
    _event_slot = {
      seq = 0,
      type = nil,
      subtype = nil,
      call_id = nil,
      model_call_id = nil,
      timestamp_ms = nil,
      at_ms = 0,
    },
    _decode_slot = { at_ms = 0, bytes = 0 },
  }
end

--- The ledger for (panel, gen), created on first touch. Total by design: a
--- capture site never has to know whether the turn was registered, and a
--- record from a path the ledger has not seen (a test driving the review
--- engine directly, a callback from a pruned turn) lands in a ledger marked
--- `synthetic` rather than being dropped on the floor.
function M.ensure(panel_id, gen)
  panel_id = panel_id or 0
  gen = gen or 0
  local turns = by_panel[panel_id]
  if not turns then
    turns = {}
    by_panel[panel_id] = turns
  end
  local L = turns[gen]
  if not L then
    L = make(panel_id, gen)
    L.synthetic = true
    turns[gen] = L
    all_turns[#all_turns + 1] = L
    prune_panel(panel_id)
    prune_global()
  end
  return L
end

-- Return the existing ledger for (panel, gen), or nil if none.
function M.get(panel_id, gen)
  local turns = by_panel[panel_id or 0]
  return turns and turns[gen or 0] or nil
end

--- Open the turn. Called once from `ui.lua:submit_panel`, before the process
--- exists, so `turn_submitted` is the true zero of the turn.
function M.begin_turn(panel_id, gen, info)
  panel_id = panel_id or 0
  gen = gen or 0
  local turns = by_panel[panel_id]
  if not turns then
    turns = {}
    by_panel[panel_id] = turns
  end
  local L = make(panel_id, gen)
  turns[gen] = L
  all_turns[#all_turns + 1] = L
  prune_panel(panel_id)
  prune_global()
  if type(info) == "table" then
    for k, v in pairs(info) do
      L.turn[k] = v
    end
  end
  M.mark(L, "turn_submitted")
  return L
end

--- Stamp a phase. First write wins: the spine records the FIRST time a
--- transition happened and a later repeat only increments `count`, so a
--- re-rendered review cannot rewrite when the review first opened.
function M.mark(L, phase)
  if type(L) ~= "table" or type(phase) ~= "string" then
    return nil
  end
  local existing = L.phases[phase]
  if existing then
    existing.count = existing.count + 1
    return existing
  end
  local ns = now_ns()
  local entry = {
    phase = phase,
    order = PHASE_ORDER[phase] or (#M.PHASES + 1),
    hrtime = ns,
    ms = since(L, ns),
    wall = M.wall_stamp(),
    count = 1,
  }
  L.phases[phase] = entry
  L.phase_marks[#L.phase_marks + 1] = entry
  return entry
end

-- Increment counter on L by n (default 1); return the new total.
function M.bump(L, counter, n)
  if type(L) ~= "table" or type(counter) ~= "string" then
    return nil
  end
  local c = L.counters
  c[counter] = (c[counter] or 0) + (n or 1)
  return c[counter]
end

-- Every `M.*` name below stays reachable exactly as before the split.
local ledger_record_factory = require("yana.ledger_record")
local ledger_record = ledger_record_factory.new({
  since = since,
  wall_stamp = M.wall_stamp,
  bump = M.bump,
  LIMITS = M.LIMITS,
})

function M.record_spawn(L, rec)
  return ledger_record.record_spawn(L, rec)
end

function M.update_spawn(entry, fields)
  return ledger_record.update_spawn(entry, fields)
end

function M.note_event(L, obj, stale)
  return ledger_record.note_event(L, obj, stale)
end

function M.note_decode_failure(L, bytes)
  return ledger_record.note_decode_failure(L, bytes)
end

function M.set_current_event(L, seq)
  return ledger_record.set_current_event(L, seq)
end

function M.current_event(L)
  return ledger_record.current_event(L)
end

function M.note_append_at(L, kind, lines, seq, seq_last)
  return ledger_record.note_append_at(L, kind, lines, seq, seq_last)
end

function M.note_append(L, kind, lines)
  return ledger_record.note_append(L, kind, lines)
end
--- Notifications, by level, counted against the newest live turn. Deliberately
--- does NOT create a ledger: a notification outside any turn (startup, a
--- health check) is not a turn event and must not conjure a turn record.
function M.note_notify(level)
  local L = nil
  for _, cand in ipairs(all_turns) do
    if not cand.closed and (not L or cand.seq > L.seq) then
      L = cand
    end
  end
  if not L then
    return nil
  end
  local counter = "notify_info"
  if type(level) == "number" then
    if level >= vim.log.levels.ERROR then
      counter = "notify_error"
    elseif level >= vim.log.levels.WARN then
      counter = "notify_warn"
    end
  end
  return M.bump(L, counter)
end


function M.set_usage(L, result_obj)
  return ledger_record.set_usage(L, result_obj)
end

function M.record_hunks(L, entry)
  return ledger_record.record_hunks(L, entry)
end

function M.record_render_check(L, result)
  return ledger_record.record_render_check(L, result)
end

function M.record_decision(L, decision)
  return ledger_record.record_decision(L, decision)
end

function M.record_refusal_group(L, group)
  return ledger_record.record_refusal_group(L, group)
end

function M.attach_refusal(L, detail)
  return ledger_record.attach_refusal(L, detail)
end

function M.close_turn(L, outcome)
  return ledger_record.close_turn(L, outcome)
end

function M.record_pending(L, rec)
  return ledger_record.record_pending(L, rec)
end

function M.record_session_check(L, rec)
  return ledger_record.record_session_check(L, rec)
end

function M.set_recording(L, rec, writer)
  return ledger_record.set_recording(L, rec, writer)
end

function M.record_decoded_event(L, event_seq, obj, stale)
  return ledger_record.record_decoded_event(L, event_seq, obj, stale)
end

function M.clear_recording_writer(L)
  return ledger_record.clear_recording_writer(L)
end
----------------------------------------------------------------------
-- readers
----------------------------------------------------------------------

--- Every retained turn, oldest first.
function M.all()
  local out = {}
  for _, L in ipairs(all_turns) do
    out[#out + 1] = L
  end
  table.sort(out, function(a, b)
    return a.seq < b.seq
  end)
  return out
end

-- Return the highest-seq turn, optionally filtered to one panel.
function M.latest(panel_id)
  local best = nil
  for _, L in ipairs(all_turns) do
    if panel_id == nil or L.panel_id == panel_id then
      if not best or L.seq > best.seq then
        best = L
      end
    end
  end
  return best
end

--- Phase entries in spine order, each carrying the gap from the previous
--- stamp. The flow report and the dump both read the timeline through here so
--- there is one definition of "the phase table".
function M.timeline(L)
  if type(L) ~= "table" then
    return {}
  end
  local rows = {}
  for _, entry in ipairs(L.phase_marks) do
    rows[#rows + 1] = entry
  end
  table.sort(rows, function(a, b)
    if a.ms == b.ms then
      return a.order < b.order
    end
    return a.ms < b.ms
  end)
  local prev = 0
  for _, row in ipairs(rows) do
    row.delta_ms = math.floor((row.ms - prev) * 1000) / 1000
    prev = row.ms
  end
  return rows
end

--- Repeated panel lines with the distinct event seqs that produced them. This
--- answers the operator's three-way question directly: one seq and several
--- appends is render duplication; several seqs is churn upstream of us, which
--- the spawn table then splits into vendor churn or a respawn.
function M.append_repeats(L)
  if type(L) ~= "table" then
    return {}
  end
  local groups = {}
  local order = {}
  for _, entry in ipairs(L.appends) do
    local key = entry.first
    if key ~= "" then
      local g = groups[key]
      if not g then
        g = { first = key, count = 0, seen = {}, event_seqs = {}, kinds = {} }
        groups[key] = g
        order[#order + 1] = key
      end
      g.count = g.count + 1
      local tag = entry.event_seq == nil and "none" or tostring(entry.event_seq)
      if not g.seen[tag] then
        g.seen[tag] = true
        g.event_seqs[#g.event_seqs + 1] = entry.event_seq
      end
      g.kinds[entry.kind] = true
    end
  end
  local out = {}
  for _, key in ipairs(order) do
    local g = groups[key]
    if g.count > 1 then
      out[#out + 1] = g
    end
  end
  return out
end

--- Test/inspection seam. Not used by product code.
M._test = {
  reset = function()
    by_panel = {}
    all_turns = {}
    _turn_seq = 0
  end,
  by_panel = function()
    return by_panel
  end,
  all_turns = function()
    return all_turns
  end,
}

return M
