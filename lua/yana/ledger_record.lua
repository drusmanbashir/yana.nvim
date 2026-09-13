-- Same schema, same counters, same retention caps as before the split: this is the
-- block of recorder functions that take the ledger table `L` (plus small extra args)
-- and touch nothing module-global, moved verbatim behind `M.new(deps)`.
--
-- `note_notify` stayed behind in `ledger.lua`: it is the one function in this
-- stretch that walks the module-level turn table directly, so it belongs
-- with the core state, not with these pure per-turn recorders.
local M = {}

function M.new(deps)
  local since = deps.since
  local wall_stamp = deps.wall_stamp
  local bump = deps.bump
  local LIMITS = deps.LIMITS

  ----------------------------------------------------------------------
  -- provenance 1: spawn records
  ----------------------------------------------------------------------

  --- One record per `jobstart`, whether or not the spawn succeeded. Two spawn
  --- records inside one turn is the signature of a Yana respawn, which is
  --- one of the three explanations a repeated panel sentence can have.
  local function record_spawn(L, rec)
    if type(L) ~= "table" then
      return nil
    end
    rec = rec or {}
    local entry = {
      seq = #L.spawns + 1,
      at_ms = since(L),
      wall = wall_stamp(),
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
    if #L.spawns < LIMITS.spawns then
      L.spawns[#L.spawns + 1] = entry
    else
      L.spawns_dropped = L.spawns_dropped + 1
    end
    return entry
  end

  --- Late-bound spawn facts: the pid is only knowable after `jobstart` returns,
  --- the exit code only when the process dies.
  local function update_spawn(entry, fields)
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
  local function note_event(L, obj, stale)
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

  -- Count a decode failure and stamp its size/time in the reused slot.
  local function note_decode_failure(L, bytes)
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
  local function set_current_event(L, seq)
    if type(L) ~= "table" then
      return
    end
    L.event_seq_current = seq
  end

  -- Return the event seq currently attributed to appends, or nil.
  local function current_event(L)
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
  --- Retains a truncated FIRST LINE, not the appended content: repetition attribution
  --- needs comparable text, and the module's redaction invariant forbids retaining file
  --- contents. The ring is capped and drop-counted, and the counters keep the true
  --- totals either way. The agent announcing that it is redoing blocked work ("Retrying
  --- edits — prior attempt was blocked …") is its own event class: the corpus showed
  --- those rounds read as ordinary streaming, which hid how much of a turn was re-work.
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
  --- The streaming path needs this: a stream segment is rendered under the assistant
  --- events that produced it but only committed later, while the NEXT event (the tool
  --- call that froze it, or the result) is current. Reading `event_seq_current` at
  --- commit time therefore attributed a repeated assistant sentence to the tool-call
  --- sequence that followed it, which is precisely the question the provenance chain
  --- exists to answer. Callers that ARE the current event use `note_append` below;
  ---
  --- `seq_last` is optional: when the segment spans several assistant deltas the
  --- record carries the range's first seq in `event_seq` (so all existing
  --- readers keep working) and the last in `event_seq_last`.
  local function note_append_at(L, kind, lines, seq, seq_last)
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
    if #L.appends >= LIMITS.appends then
      L.appends_dropped = L.appends_dropped + 1
      return nil
    end
    if #text > LIMITS.append_text then
      text = text:sub(1, LIMITS.append_text) .. "…"
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

  -- Record a panel append against the turn's current event seq.
  local function note_append(L, kind, lines)
    if type(L) ~= "table" then
      return nil
    end
    return note_append_at(L, kind, lines, L.event_seq_current, nil)
  end
  ----------------------------------------------------------------------
  -- usage, hunk model, render checks, decisions, outcome
  ----------------------------------------------------------------------

  --- §2.7 usage retention: the `result` event's own numbers, kept per turn.
  local function set_usage(L, result_obj)
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
  local function record_hunks(L, entry)
    if type(L) ~= "table" or type(entry) ~= "table" or not entry.change_id then
      return nil
    end
    if not L.hunks[entry.change_id] then
      if #L.hunk_order >= LIMITS.hunk_files then
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
  local function record_render_check(L, result)
    if type(L) ~= "table" or type(result) ~= "table" then
      return nil
    end
    local c = L.counters
    c.render_checks = c.render_checks + 1
    if not result.ok then
      c.render_violations = c.render_violations + #(result.violations or {})
    end
    result.at_ms = since(L)
    if #L.render_checks >= LIMITS.render_checks then
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
  --- `reviews_refused` is counted HERE and nowhere else. A report then listed a refusal
  --- while claiming none had happened.
  ---
  --- Counted BEFORE the ring cap, exactly as `note_append_at` classifies before
  --- its own: the counters are the totals, and a refusal that stops being
  --- counted once the ring fills would understate precisely the long turns where
  --- refusals matter. `attach_refusal` enriches this same record in place and so
  --- adds nothing to the count.
  local function record_decision(L, decision)
    if type(L) ~= "table" or type(decision) ~= "table" then
      return nil
    end
    decision.at_ms = since(L)
    decision.wall = wall_stamp()
    if decision.action == "review_refused" then
      local c = L.counters
      c.reviews_refused = (c.reviews_refused or 0) + 1
    end
    if #L.decisions >= LIMITS.decisions then
      L.decisions_dropped = L.decisions_dropped + 1
      return nil
    end
    L.decisions[#L.decisions + 1] = decision
    return decision
  end

  -- Count a refusal group and store a capped, deep-copied record.
  local function record_refusal_group(L, group)
    if type(L) ~= "table" or type(group) ~= "table" then
      return nil
    end
    local count = tonumber(group.count) or 0
    L.counters.ops_system_refused = (L.counters.ops_system_refused or 0) + count
    if #L.refusal_groups >= LIMITS.refusal_groups then
      L.refusal_groups_dropped = L.refusal_groups_dropped + 1
      return nil
    end
    local row = {
      at_ms = since(L),
      wall = wall_stamp(),
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
    -- The stable, greppable slug (`stale_file`, `evidence_error`,
    -- `delete_target_absent`, `observe_failed`, `generic_pre_apply`) beside the
    -- free-text `reason` prose, so a refusal is findable by vocabulary rather
    -- than by matching a sentence.
    "reason_code",
    "origin",
    "expected_fp",
    "actual_fp",
    "expected_state",
    "found_state",
    -- WHEN the turn-start fingerprint (`expected_fp`) was captured -- the field
    -- a `stale_file` refusal needs to tell a human edit from a stale capture.
    "base_hash_captured_ts",
    "st_ino",
    "st_mtime",
    "evidence_check",
    "evidence_rejected",
    "oerr",
    "retention_strength",
    "retained_path",
    "retention_error",
  }

  -- Merge known refusal-detail fields onto the last refused decision.
  local function attach_refusal(L, detail)
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
  local function close_turn(L, outcome)
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
    -- Both are fed by the same stream, so agreement is near-tautological — what this
    -- really catches is a Yana pipeline bug or a lying shim Yana itself ships. Absent
    -- normaliser count => no-op (sibling may land after this).
    do
      local claimed = o.normaliser_tool_calls
      if claimed == nil and type(L.normaliser_tool_calls) == "number" then
        claimed = L.normaliser_tool_calls
      end
      if type(claimed) == "number" and type(o.changes) == "number" and claimed ~= o.changes then
        local log = require("yana.log")
        log.write(
          log.levels.WARN,
          string.format(
            "yana: TURN_END_DESYNC panel=%s gen=%s normaliser_tool_calls=%s changes=%s",
            tostring(L.panel_id or (L.turn and L.turn.panel_id)),
            tostring(L.gen or (L.turn and L.turn.generation)),
            tostring(claimed),
            tostring(o.changes)
          )
        )
      end
    end
    return o
  end

  --- The two counters the user is shown ("N pending" in the winbar) against the
  --- review engine's own, at render time. Overwritten each render — the LAST
  --- state is the one a stuck counter is judged on — and `stuck` is the named
  --- desync: the panel claims pending work while the engine holds none, with
  --- nothing in flight that could still produce it.
  local function record_pending(L, rec)
    if type(L) ~= "table" or type(rec) ~= "table" then
      return nil
    end
    rec.at_ms = since(L)
    L.pending_check = rec
    if rec.stuck then
      bump(L, "pending_desyncs")
    end
    return rec
  end

  --- Session-registry consistency, once per persist. A transcript on disk with
  --- no registry row is a session that cannot be listed or resumed.
  local function record_session_check(L, rec)
    if type(L) ~= "table" or type(rec) ~= "table" then
      return nil
    end
    rec.at_ms = since(L)
    L.session_check = rec
    if rec.missing then
      bump(L, "session_registry_misses")
    end
    return rec
  end

  -- Attach a recording descriptor and its writer to the ledger.
  local function set_recording(L, rec, writer)
    if type(L) ~= "table" then
      return nil
    end
    L.recording = rec
    L._recording_writer = writer
    return rec
  end

  -- Forward a decoded event to the turn's recording writer, if any.
  local function record_decoded_event(L, event_seq, obj, stale)
    local writer = type(L) == "table" and L._recording_writer or nil
    if writer and type(writer.event) == "function" then
      return writer:event(event_seq, obj, stale)
    end
    return false
  end

  -- Detach the recording writer from the turn's ledger.
  local function clear_recording_writer(L)
    if type(L) == "table" then
      L._recording_writer = nil
    end
  end

  return {
    record_spawn = record_spawn,
    update_spawn = update_spawn,
    note_event = note_event,
    note_decode_failure = note_decode_failure,
    set_current_event = set_current_event,
    current_event = current_event,
    note_append_at = note_append_at,
    note_append = note_append,
    set_usage = set_usage,
    record_hunks = record_hunks,
    record_render_check = record_render_check,
    record_decision = record_decision,
    record_refusal_group = record_refusal_group,
    attach_refusal = attach_refusal,
    close_turn = close_turn,
    record_pending = record_pending,
    record_session_check = record_session_check,
    set_recording = set_recording,
    record_decoded_event = record_decoded_event,
    clear_recording_writer = clear_recording_writer,
  }
end

return M
