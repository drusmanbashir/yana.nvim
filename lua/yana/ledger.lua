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
--   * It OBSERVES. Nothing here changes control flow, refuses anything, or
--     repairs anything. Every entry point is total: an unknown panel, an
--     unknown turn or a malformed record stores what it can and returns.
--   * ZERO disk I/O on the clean path. Everything is a table assignment or an
--     integer increment; the ledger reaches disk only through `:YanaDump`
--     / `:YanaFlowReport`, or when a capture site decides to WARN. A
--     clean turn leaves `yana.log` byte-identical (CTL-CLEAN).
--   * O(1) memory per turn. Counters, not event copies; the append ring and
--     the decision/render-check lists are capped and drop-counted.
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
  -- Per-panel retention alone is not a bound. Panel ids increase
  -- monotonically and a quit panel used to keep its eight turns forever, so
  -- open/quit cycles grew `by_panel` and `all_turns` without limit and every
  -- dump and flow report grew with dead UI state. Two things fix it: panel
  -- teardown calls `M.drop_panel`, and this global cap holds even if a
  -- teardown path is ever missed.
  turns_total = 32,
  appends = 200,
  spawns = 32,
  decisions = 200,
  refusal_groups = 64,
  render_checks = 24,
  hunk_files = 64,
  append_text = 120,
}

-- The 14 once-per-turn transitions of the turn spine, plus `review_redraw`:
-- the post-render `vim.schedule` stamp that is the closest in-process proxy
-- for "the user can see it" (limitations register L6; true paint time is only
-- observable from the oracle capture tier).
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

--- Release every record for a panel that no longer exists. Called from
--- ui.lua's quit_panel: the ledger cannot observe panel teardown itself, and
--- without this the records of a destroyed panel outlive it for the rest of
--- the session.
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
    session_check = nil,
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

function M.bump(L, counter, n)
  if type(L) ~= "table" or type(counter) ~= "string" then
    return nil
  end
  local c = L.counters
  c[counter] = (c[counter] or 0) + (n or 1)
  return c[counter]
end

----------------------------------------------------------------------
-- provenance 1: spawn records
----------------------------------------------------------------------

--- One record per `jobstart`, whether or not the spawn succeeded. Two spawn
--- records inside one turn is the signature of a Yana respawn, which is
--- one of the three explanations a repeated panel sentence can have.
function M.record_spawn(L, rec)
  if type(L) ~= "table" then
    return nil
  end
  rec = rec or {}
  local entry = {
    seq = #L.spawns + 1,
    at_ms = since(L),
    wall = M.wall_stamp(),
    panel_id = L.panel_id,
    gen = L.gen,
    argv = rec.argv,
    cmd = rec.cmd,
    job = rec.job,
    pid = rec.pid,
    cwd = rec.cwd,
    mode = rec.mode,
    model = rec.model,
    resume_session_id = rec.resume_session_id,
    reason = rec.reason or "submit",
    jailed = rec.jailed and true or false,
    ok = rec.ok ~= false,
    error = rec.error,
    tee_path = rec.tee_path,
    exit_code = nil,
  }
  if #L.spawns < M.LIMITS.spawns then
    L.spawns[#L.spawns + 1] = entry
  else
    L.spawns_dropped = L.spawns_dropped + 1
  end
  return entry
end

--- Late-bound spawn facts: the pid is only knowable after `jobstart` returns,
--- the exit code only when the process dies.
function M.update_spawn(entry, fields)
  if type(entry) ~= "table" or type(fields) ~= "table" then
    return
  end
  for k, v in pairs(fields) do
    entry[k] = v
  end
end

----------------------------------------------------------------------
-- provenance 2: event sequence
----------------------------------------------------------------------

local TYPE_COUNTER = {
  system = "events_system",
  assistant = "events_assistant",
  tool_call = "events_tool_call",
  result = "events_result",
  error = "events_error",
}

--- Stamp one decoded stream event. Returns its monotonic per-turn seq, which
--- the caller keeps as "the event being handled" so every panel append made
--- underneath it can name its cause.
function M.note_event(L, obj, stale)
  if type(L) ~= "table" then
    return nil
  end
  L.event_seq = L.event_seq + 1
  local seq = L.event_seq
  local c = L.counters
  c.events_total = c.events_total + 1
  local is_tbl = type(obj) == "table"
  local otype = is_tbl and obj.type or nil
  local counter = TYPE_COUNTER[otype] or "events_other"
  c[counter] = c[counter] + 1
  if stale then
    c.events_stale_dropped = c.events_stale_dropped + 1
  end
  if otype == "tool_call" and is_tbl and obj.subtype == "completed" then
    c.tool_calls_completed = c.tool_calls_completed + 1
  end
  -- Fixed slot, mutated in place: one decoded event costs counter increments
  -- and field stores, and allocates nothing. `since` returns a number, which
  -- LuaJIT keeps unboxed, so there is no hidden allocation here either.
  local e = L._event_slot
  e.seq = seq
  e.type = otype
  e.subtype = is_tbl and obj.subtype or nil
  e.call_id = is_tbl and obj.call_id or nil
  e.model_call_id = is_tbl and obj.model_call_id or nil
  e.timestamp_ms = is_tbl and obj.timestamp_ms or nil
  e.at_ms = since(L)
  L.last_event = e
  return seq
end

function M.note_decode_failure(L, bytes)
  if type(L) ~= "table" then
    return nil
  end
  local c = L.counters
  c.decode_failures = c.decode_failures + 1
  local d = L._decode_slot
  d.at_ms = since(L)
  d.bytes = bytes or 0
  L.last_decode_failure = d
  return c.decode_failures
end

--- The event seq a panel append should be attributed to. Set for the duration
--- of one `on_event` call and cleared after, so an append made outside event
--- handling (the submit echo, a queue notice) records `event_seq = nil`
--- rather than borrowing the previous event's identity.
function M.set_current_event(L, seq)
  if type(L) ~= "table" then
    return
  end
  L.event_seq_current = seq
end

function M.current_event(L)
  return type(L) == "table" and L.event_seq_current or nil
end

----------------------------------------------------------------------
-- provenance 3: panel append records
----------------------------------------------------------------------

local function first_line_of(lines)
  if type(lines) == "string" then
    return lines
  end
  if type(lines) ~= "table" then
    return ""
  end
  for _, l in ipairs(lines) do
    if type(l) == "string" and l ~= "" then
      return l
    end
  end
  return ""
end

--- One record per write into the conversation buffer, naming the event seq
--- that caused it. Several appends citing ONE seq is render duplication;
--- several appends citing distinct seqs under one spawn is vendor churn.
---
--- Retains a truncated FIRST LINE, not the appended content: repetition
--- attribution needs comparable text, and the module's redaction invariant
--- forbids retaining file contents. The ring is capped and drop-counted, and
--- the counters keep the true totals either way.
-- The agent announcing that it is redoing blocked work ("Retrying edits —
-- prior attempt was blocked …") is its own event class: the corpus showed
-- those rounds read as ordinary streaming, which hid how much of a turn was
-- re-work. Classified by shape, and deliberately conservative — it is an
-- observation about panel text, so a miss costs a label, never behaviour.
-- Case-insensitive by character class rather than `text:lower()`: lowering
-- allocates a second string on every append, and this runs on the panel's hot
-- path. Same matches, no garbage.
local function is_retry_announcement(text)
  if type(text) ~= "string" or text == "" then
    return false
  end
  if not text:find("[Rr][Ee][Tt][Rr][Yy]") then
    return false
  end
  return text:find("[Bb][Ll][Oo][Cc][Kk]") ~= nil
    or text:find("[Rr][Ee][Ff][Uu][Ss]") ~= nil
    or text:find("[Pp][Rr][Ii][Oo][Rr] [Aa][Tt][Tt][Ee][Mm][Pp][Tt]") ~= nil
end

--- Record one panel append against an EXPLICIT event seq (or seq range).
---
--- The streaming path needs this: a stream segment is rendered under the
--- assistant events that produced it but only committed later, while the NEXT
--- event (the tool call that froze it, or the result) is current. Reading
--- `event_seq_current` at commit time therefore attributed a repeated
--- assistant sentence to the tool-call sequence that followed it, which is
--- precisely the question the provenance chain exists to answer. Callers that
--- ARE the current event use `note_append` below; callers holding the
--- originating seq call this.
---
--- `seq_last` is optional: when the segment spans several assistant deltas the
--- record carries the range's first seq in `event_seq` (so all existing
--- readers keep working) and the last in `event_seq_last`.
function M.note_append_at(L, kind, lines, seq, seq_last)
  if type(L) ~= "table" then
    return nil
  end
  local c = L.counters
  local n = type(lines) == "table" and #lines or 1
  c.panel_appends = c.panel_appends + 1
  c.panel_append_lines = c.panel_append_lines + n
  L.append_seq = L.append_seq + 1
  local text = first_line_of(lines)
  kind = kind or "append"
  -- Classified BEFORE the ring cap: the counters are the totals, and a class
  -- that stops being counted once the ring fills would understate exactly the
  -- long turns where re-work matters. Classification reads the UNTRUNCATED
  -- first line, and truncation happens only for a record that is kept — so an
  -- append past the cap allocates nothing at all.
  if (kind == "stream" or kind == "note") and is_retry_announcement(text) then
    kind = "retry_announcement"
    c.retry_announcements = c.retry_announcements + 1
  end
  if #L.appends >= M.LIMITS.appends then
    L.appends_dropped = L.appends_dropped + 1
    return nil
  end
  if #text > M.LIMITS.append_text then
    text = text:sub(1, M.LIMITS.append_text) .. "…"
  end
  local entry = {
    seq = L.append_seq,
    event_seq = seq,
    event_seq_last = (seq_last ~= seq) and seq_last or nil,
    kind = kind,
    lines = n,
    first = text,
    at_ms = since(L),
  }
  L.appends[#L.appends + 1] = entry
  return entry
end

function M.note_append(L, kind, lines)
  if type(L) ~= "table" then
    return nil
  end
  return M.note_append_at(L, kind, lines, L.event_seq_current, nil)
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

----------------------------------------------------------------------
-- usage, hunk model, render checks, decisions, outcome
----------------------------------------------------------------------

--- §2.7 usage retention: the `result` event's own numbers, kept per turn.
function M.set_usage(L, result_obj)
  if type(L) ~= "table" or type(result_obj) ~= "table" then
    return nil
  end
  local u = type(result_obj.usage) == "table" and result_obj.usage or {}
  L.usage = {
    input_tokens = u.inputTokens,
    output_tokens = u.outputTokens,
    cache_read_tokens = u.cacheReadTokens,
    cache_write_tokens = u.cacheWriteTokens,
    duration_ms = result_obj.duration_ms,
    duration_api_ms = result_obj.duration_api_ms,
    is_error = result_obj.is_error and true or false,
    session_id = result_obj.session_id,
    at_ms = since(L),
  }
  return L.usage
end

--- The change model as the review engine received it: per file, per hunk,
--- old/new line counts and the buffer row the hunk starts at. This is the
--- side the rung-1 model-extent check compares applied decoration against.
function M.record_hunks(L, entry)
  if type(L) ~= "table" or type(entry) ~= "table" or not entry.change_id then
    return nil
  end
  if not L.hunks[entry.change_id] then
    if #L.hunk_order >= M.LIMITS.hunk_files then
      L.hunk_files_dropped = L.hunk_files_dropped + 1
      return nil
    end
    L.hunk_order[#L.hunk_order + 1] = entry.change_id
  end
  entry.at_ms = since(L)
  L.hunks[entry.change_id] = entry
  return entry
end

--- One rung-1 reconciliation result. Kept whether it passed or failed: a
--- green check is the witness that the capture executed at all.
function M.record_render_check(L, result)
  if type(L) ~= "table" or type(result) ~= "table" then
    return nil
  end
  local c = L.counters
  c.render_checks = c.render_checks + 1
  if not result.ok then
    c.render_violations = c.render_violations + #(result.violations or {})
  end
  result.at_ms = since(L)
  if #L.render_checks >= M.LIMITS.render_checks then
    -- Keep the newest: a defect that appears late in a long review is the one
    -- worth having, and the earliest checks are already summarized by the
    -- counters above.
    table.remove(L.render_checks, 1)
    L.render_checks_dropped = L.render_checks_dropped + 1
  end
  L.render_checks[#L.render_checks + 1] = result
  return result
end

--- Operator review actions: accept/reject per hunk, file, or turn, plus the
--- system's own `review_refused` class.
---
--- `reviews_refused` is counted HERE and nowhere else. Every refusing branch
--- already funnels through this one recording site, but the counter used to be
--- bumped by each caller separately -- so the DEFAULT shadow-accept drift
--- branch, which was added later, wrote a correct record and left the count at
--- zero. A report then listed a refusal while claiming none had happened.
--- Deriving the count from the record it belongs to makes the two impossible
--- to disagree: one record, one count, and a branch that forgets to count is
--- no longer expressible.
---
--- Counted BEFORE the ring cap, exactly as `note_append_at` classifies before
--- its own: the counters are the totals, and a refusal that stops being
--- counted once the ring fills would understate precisely the long turns where
--- refusals matter. `attach_refusal` enriches this same record in place and so
--- adds nothing to the count.
function M.record_decision(L, decision)
  if type(L) ~= "table" or type(decision) ~= "table" then
    return nil
  end
  decision.at_ms = since(L)
  decision.wall = M.wall_stamp()
  if decision.action == "review_refused" then
    local c = L.counters
    c.reviews_refused = (c.reviews_refused or 0) + 1
  end
  if #L.decisions >= M.LIMITS.decisions then
    L.decisions_dropped = L.decisions_dropped + 1
    return nil
  end
  L.decisions[#L.decisions + 1] = decision
  return decision
end

function M.record_refusal_group(L, group)
  if type(L) ~= "table" or type(group) ~= "table" then
    return nil
  end
  local count = tonumber(group.count) or 0
  L.counters.ops_system_refused = (L.counters.ops_system_refused or 0) + count
  if #L.refusal_groups >= M.LIMITS.refusal_groups then
    L.refusal_groups_dropped = L.refusal_groups_dropped + 1
    return nil
  end
  local row = {
    at_ms = since(L),
    wall = M.wall_stamp(),
    status = "system_refused",
    root = group.root,
    count = count,
    kind_counts = vim.deepcopy(group.kind_counts or {}),
    sample = vim.deepcopy(group.sample or {}),
    members_truncated = group.members_truncated and true or false,
    listing_path = group.listing_path,
    layer_path = group.layer_path,
    retention_strength = "momentary",
  }
  L.refusal_groups[#L.refusal_groups + 1] = row
  return row
end

--- Enrich the decision just recorded with a structured refusal detail.
---
--- The default shadow-accept route detects drift deep in the applier, where
--- the fingerprint pair and the reason CLASS are in hand, but the recording
--- site sits several layers up in the review engine and only ever saw an error
--- string. Rather than reshape four return signatures, the applier attaches
--- the structured detail to the change and the recording site merges it here.
---
--- Total, like every other entry point: no ledger, no last decision or no
--- detail leaves the record exactly as it was built. Only the schema fields
--- the delta names are copied, so the applier cannot rewrite `actor`, the
--- change identity, or the timestamps.
local REFUSAL_FIELDS = {
  "reason",
  "origin",
  "expected_fp",
  "actual_fp",
  "expected_state",
  "found_state",
  "retention_strength",
  "retained_path",
  "retention_error",
}

function M.attach_refusal(L, detail)
  if type(L) ~= "table" or type(detail) ~= "table" then
    return nil
  end
  local last = L.decisions[#L.decisions]
  if type(last) ~= "table" or last.action ~= "review_refused" then
    return nil
  end
  for _, field in ipairs(REFUSAL_FIELDS) do
    if detail[field] ~= nil then
      last[field] = detail[field]
    end
  end
  return last
end

--- Terminal state of the turn. Idempotent: `on_done` and `on_exit_confirmed`
--- both reach it, so later facts merge into the record rather than replacing
--- it.
function M.close_turn(L, outcome)
  if type(L) ~= "table" then
    return nil
  end
  local o = L.outcome or {}
  if type(outcome) == "table" then
    for k, v in pairs(outcome) do
      o[k] = v
    end
  end
  o.closed_at_ms = since(L)
  L.outcome = o
  L.closed = true
  return o
end

--- The two counters the user is shown ("N pending" in the winbar) against the
--- review engine's own, at render time. Overwritten each render — the LAST
--- state is the one a stuck counter is judged on — and `stuck` is the named
--- desync: the panel claims pending work while the engine holds none, with
--- nothing in flight that could still produce it.
function M.record_pending(L, rec)
  if type(L) ~= "table" or type(rec) ~= "table" then
    return nil
  end
  rec.at_ms = since(L)
  L.pending_check = rec
  if rec.stuck then
    M.bump(L, "pending_desyncs")
  end
  return rec
end

--- Session-registry consistency, once per persist. A transcript on disk with
--- no registry row is a session that cannot be listed or resumed.
function M.record_session_check(L, rec)
  if type(L) ~= "table" or type(rec) ~= "table" then
    return nil
  end
  rec.at_ms = since(L)
  L.session_check = rec
  if rec.missing then
    M.bump(L, "session_registry_misses")
  end
  return rec
end

function M.set_recording(L, rec, writer)
  if type(L) ~= "table" then
    return nil
  end
  L.recording = rec
  L._recording_writer = writer
  return rec
end

function M.record_decoded_event(L, event_seq, obj, stale)
  local writer = type(L) == "table" and L._recording_writer or nil
  if writer and type(writer.event) == "function" then
    return writer:event(event_seq, obj, stale)
  end
  return false
end

function M.clear_recording_writer(L)
  if type(L) == "table" then
    L._recording_writer = nil
  end
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
