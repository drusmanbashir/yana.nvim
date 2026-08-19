-- yana: turn records → a markdown flow report.
--
-- Deliberately shaped like the video-derived ground truth
-- (`n8_ground_truth.md`): turn facts, a timeline table, the tool/event
-- inventory, usage, a per-hunk table with intended vs applied decoration, the
-- decisions, and the outcome. Same sections in the same order, so a log and a
-- screen recording of the same turn can be read side by side and disagreements
-- are visible by row rather than by argument.
--
-- Pure rendering: it reads a ledger and returns lines. No API calls, no I/O, no
-- mutation of what it reads — the caller decides where the text goes.
local M = {}

local ledger = require("yana.ledger")

local function fmt_ms(ms)
  if type(ms) ~= "number" then
    return "-"
  end
  if ms >= 1000 then
    return string.format("%.2fs", ms / 1000)
  end
  return string.format("%.1fms", ms)
end

local function yes(v)
  if v == nil then
    return "-"
  end
  return v and "yes" or "no"
end

local function nn(v)
  if v == nil then
    return "-"
  end
  return tostring(v)
end

-- Markdown table cells are pipe-delimited, and argv, prompts and paths all
-- contain pipes eventually. Escaping here keeps a report readable rather than
-- silently mangled into extra columns.
local function cell(s)
  s = tostring(s == nil and "-" or s)
  s = s:gsub("\n", " ")
  s = s:gsub("|", "\\|")
  return s
end

local function argv_str(argv)
  if type(argv) ~= "table" then
    return "-"
  end
  local parts = {}
  for i, a in ipairs(argv) do
    local one = tostring(a)
    -- The prompt is the last argv element and can be enormous; the report
    -- names its size instead of pasting the whole turn into a table cell.
    if i == #argv and #one > 60 then
      one = string.format("<prompt %d bytes>", #one)
    elseif #one > 60 then
      one = one:sub(1, 57) .. "…"
    end
    parts[#parts + 1] = one
  end
  return table.concat(parts, " ")
end

----------------------------------------------------------------------
-- sections
----------------------------------------------------------------------

local function section_facts(L, out)
  local t = L.turn or {}
  out[#out + 1] = string.format("## Turn %s", L.turn_key)
  out[#out + 1] = ""
  out[#out + 1] = string.format("- Started: `%s` (monotonic zero = turn submitted)", L.wall_start)
  out[#out + 1] = string.format("- Panel: %s · generation: %s%s", nn(L.panel_id), nn(L.gen), L.synthetic and " · synthetic (no submit record)" or "")
  out[#out + 1] = string.format("- Mode: %s · model: %s", nn(t.mode), nn(t.model or "auto"))
  out[#out + 1] = string.format("- Session: %s", nn(t.session_id or (L.outcome and L.outcome.session_id)))
  out[#out + 1] = string.format("- Cwd: %s", nn(t.cwd))
  if t.workspace then
    out[#out + 1] = string.format("- Turn workspace: %s", nn(t.workspace))
  end
  if t.turn_dir then
    out[#out + 1] = string.format("- Turn dir: %s", nn(t.turn_dir))
  end
  if L.recording then
    out[#out + 1] = string.format("- Recording: `%s` (+ meta.json)", nn(L.recording.stream_path))
  end
  out[#out + 1] = ""
end

local function section_timeline(L, out)
  out[#out + 1] = "### Phase timeline"
  out[#out + 1] = ""
  local rows = ledger.timeline(L)
  if #rows == 0 then
    out[#out + 1] = "_no phase stamps recorded_"
    out[#out + 1] = ""
    return
  end
  out[#out + 1] = "| t (from submit) | Δ | phase | wall clock | repeats |"
  out[#out + 1] = "|---|---|---|---|---|"
  for _, row in ipairs(rows) do
    out[#out + 1] = string.format(
      "| %s | %s | %s | %s | %s |",
      fmt_ms(row.ms),
      fmt_ms(row.delta_ms),
      cell(row.phase),
      cell(row.wall),
      row.count > 1 and tostring(row.count) or ""
    )
  end
  out[#out + 1] = ""
  -- Name what did NOT happen. A missing phase is the diagnosis in every stall
  -- report, and a table that only lists what fired hides it.
  local missing = {}
  for _, phase in ipairs(ledger.PHASES) do
    if not L.phases[phase] then
      missing[#missing + 1] = phase
    end
  end
  if #missing > 0 then
    out[#out + 1] = string.format("_never reached: %s_", table.concat(missing, ", "))
    out[#out + 1] = ""
  end
end

local function section_spawns(L, out)
  out[#out + 1] = "### Spawns (provenance 1)"
  out[#out + 1] = ""
  if #L.spawns == 0 then
    out[#out + 1] = "_no process spawned for this turn_"
    out[#out + 1] = ""
    return
  end
  out[#out + 1] = "| # | t | pid | ok | exit | reason | resume session | jailed | argv |"
  out[#out + 1] = "|---|---|---|---|---|---|---|---|---|"
  for _, s in ipairs(L.spawns) do
    out[#out + 1] = string.format(
      "| %d | %s | %s | %s | %s | %s | %s | %s | `%s` |",
      s.seq,
      fmt_ms(s.at_ms),
      nn(s.pid),
      yes(s.ok),
      nn(s.exit_code),
      cell(s.reason),
      cell(s.resume_session_id or "-"),
      yes(s.jailed),
      cell(argv_str(s.argv))
    )
  end
  out[#out + 1] = ""
  if #L.spawns > 1 then
    out[#out + 1] = string.format(
      "**%d spawns in one turn** — repeated panel output for this turn is Yana relaunching cursor-agent, not vendor churn.",
      #L.spawns
    )
    out[#out + 1] = ""
  end
  if L.spawns_dropped > 0 then
    out[#out + 1] = string.format("_%d spawn(s) dropped past the cap_", L.spawns_dropped)
    out[#out + 1] = ""
  end
end

local function section_events(L, out)
  local c = L.counters
  out[#out + 1] = "### Event accounting (provenance 2)"
  out[#out + 1] = ""
  out[#out + 1] = "| class | count |"
  out[#out + 1] = "|---|---|"
  local rows = {
    { "events decoded (total)", c.events_total },
    { "· system", c.events_system },
    { "· assistant", c.events_assistant },
    { "· tool_call", c.events_tool_call },
    { "· result", c.events_result },
    { "· error", c.events_error },
    { "· other", c.events_other },
    { "tool_call completed", c.tool_calls_completed },
    { "dropped stale at the generation gate", c.events_stale_dropped },
    { "· of those, disk-bearing survivors", c.events_stale_disk_bearing },
    { "lines that failed to decode", c.decode_failures },
    { "changes parsed", c.changes_parsed },
    { "· batched as turn owners", c.changes_batched },
    { "· coalesced into an owner", c.changes_coalesced },
    { "reviews enqueued", c.reviews_enqueued },
    { "reviews opened", c.reviews_opened },
    { "reviews refused", c.reviews_refused },
    { "review retries", c.review_retries },
    { "agent retry announcements", c.retry_announcements },
    { "scope rejections", c.scope_rejections },
    { "panel appends", c.panel_appends },
    { "· lines appended", c.panel_append_lines },
    { "stream re-renders", c.stream_renders },
    { "notifications (info/warn/error)", string.format("%d/%d/%d", c.notify_info, c.notify_warn, c.notify_error) },
    { "render checks run", c.render_checks },
    { "render violations recorded", c.render_violations },
    { "raw lines recorded to disk", c.recorded_lines },
  }
  for _, row in ipairs(rows) do
    out[#out + 1] = string.format("| %s | %s |", cell(row[1]), nn(row[2]))
  end
  out[#out + 1] = ""
end

local function section_usage(L, out)
  out[#out + 1] = "### Usage"
  out[#out + 1] = ""
  local u = L.usage
  if not u then
    out[#out + 1] = "_no result event carried usage_"
    out[#out + 1] = ""
    return
  end
  out[#out + 1] = string.format(
    "%s out · %s in · %s%s",
    nn(u.output_tokens),
    nn(u.input_tokens),
    u.duration_ms and string.format("%.1fs", u.duration_ms / 1000) or "-",
    u.is_error and " · agent reported an error" or ""
  )
  out[#out + 1] = ""
end

local function section_hunks(L, out)
  out[#out + 1] = "### Per-hunk model and decoration"
  out[#out + 1] = ""
  if #L.hunk_order == 0 then
    out[#out + 1] = "_no review opened for this turn_"
    out[#out + 1] = ""
    if L.hunk_files_dropped > 0 then
      out[#out + 1] = string.format("_%d hunk file(s) dropped past the cap_", L.hunk_files_dropped)
      out[#out + 1] = ""
    end
    return
  end
  -- Latest render check per change: what the decoration actually looked like
  -- the last time it was rendered.
  local latest = {}
  for _, rc in ipairs(L.render_checks) do
    if rc.change_id then
      latest[rc.change_id] = rc
    end
  end
  for _, change_id in ipairs(L.hunk_order) do
    local entry = L.hunks[change_id]
    if entry then
      out[#out + 1] = string.format(
        "**%s** (%s, +%s −%s) — model from %s",
        cell(entry.rel or change_id),
        cell(entry.kind or "modify"),
        nn(entry.added),
        nn(entry.removed),
        cell(entry.model_source or "change_payload")
      )
      out[#out + 1] = ""
      out[#out + 1] = "| # | old → new lines | buffer rows | intended hl rows | applied hl rows | hl group | verdict |"
      out[#out + 1] = "|---|---|---|---|---|---|---|"
      local rc = latest[change_id]
      local by_index = {}
      for _, h in ipairs(rc and rc.hunks or {}) do
        by_index[h.model_index or h.index] = h
      end
      for _, h in ipairs(entry.hunks or {}) do
        local applied = by_index[h.index]
        out[#out + 1] = string.format(
          "| H%d | %d → %d | %s–%s | %s | %s | %s | %s |",
          h.index,
          h.old_count or 0,
          h.new_count or 0,
          nn(h.new_start_line),
          nn(h.new_end_line),
          applied and nn(applied.intended_rows) or "-",
          applied and nn(applied.applied_rows) or "-",
          cell(applied and applied.hl_groups and table.concat(applied.hl_groups, ",") or "-"),
          cell(applied and applied.verdict or "not re-checked")
        )
      end
      out[#out + 1] = ""
    end
  end
  -- The N8 line: state it explicitly rather than leaving it to be inferred
  -- from two columns.
  local worst = nil
  for _, rc in ipairs(L.render_checks) do
    for _, v in ipairs(rc.violations or {}) do
      if v.kind == "model_extent" then
        worst = v
        break
      end
    end
    if worst then
      break
    end
  end
  if worst then
    out[#out + 1] = string.format(
      "**Decoration extent violation**: hunk %s of `%s` has %s new line(s) in the change model but %s highlighted buffer row(s) (extmark %s–%s, end_col %s).",
      nn(worst.hunk),
      cell(worst.rel or "?"),
      nn(worst.expected),
      nn(worst.got),
      nn(worst.start_row),
      nn(worst.end_row),
      nn(worst.end_col)
    )
    out[#out + 1] = ""
  end
  if L.hunk_files_dropped > 0 then
    out[#out + 1] = string.format("_%d hunk file(s) dropped past the cap_", L.hunk_files_dropped)
    out[#out + 1] = ""
  end
end

local function section_render_checks(L, out)
  out[#out + 1] = "### Render checks (rung 1)"
  out[#out + 1] = ""
  if #L.render_checks == 0 then
    out[#out + 1] = "_no render check ran_"
    out[#out + 1] = ""
    return
  end
  out[#out + 1] = "| t | site | file | blocks | marks | violations |"
  out[#out + 1] = "|---|---|---|---|---|---|"
  for _, rc in ipairs(L.render_checks) do
    local kinds = {}
    local seen = {}
    for _, v in ipairs(rc.violations or {}) do
      if not seen[v.kind] then
        seen[v.kind] = true
        kinds[#kinds + 1] = v.kind
      end
    end
    out[#out + 1] = string.format(
      "| %s | %s | %s | %s | %s | %s |",
      fmt_ms(rc.at_ms),
      cell(rc.site),
      cell(rc.rel or rc.change_id),
      nn(rc.counts and rc.counts.blocks),
      nn(rc.counts and rc.counts.marks),
      cell(#kinds == 0 and "none" or table.concat(kinds, ","))
    )
  end
  if L.render_checks_dropped > 0 then
    out[#out + 1] = string.format("| … | | | | | _%d earlier check(s) dropped_ |", L.render_checks_dropped)
  end
  out[#out + 1] = ""
end

local function section_appends(L, out)
  out[#out + 1] = "### Panel appends (provenance 3)"
  out[#out + 1] = ""
  out[#out + 1] = string.format(
    "%d append(s), %d line(s); ring holds %d%s.",
    L.counters.panel_appends,
    L.counters.panel_append_lines,
    #L.appends,
    L.appends_dropped > 0 and string.format(", %d dropped past the cap", L.appends_dropped) or ""
  )
  out[#out + 1] = ""
  local repeats = ledger.append_repeats(L)
  if #repeats == 0 then
    out[#out + 1] = "_no repeated panel line_"
    out[#out + 1] = ""
    return
  end
  out[#out + 1] = "| repeated line | appends | distinct event seqs | attribution |"
  out[#out + 1] = "|---|---|---|---|"
  for _, g in ipairs(repeats) do
    local seqs = {}
    for _, s in ipairs(g.event_seqs) do
      seqs[#seqs + 1] = s == nil and "none" or tostring(s)
    end
    -- The operator's three cases, decided from the records rather than by eye.
    local attribution
    if #g.event_seqs <= 1 then
      attribution = "render duplication (one event, several appends)"
    elseif #L.spawns > 1 then
      attribution = "Yana respawn (several spawns this turn)"
    else
      attribution = "vendor churn (one spawn, distinct events)"
    end
    out[#out + 1] = string.format(
      "| %s | %d | %s | %s |",
      cell(g.first),
      g.count,
      cell(table.concat(seqs, ",")),
      cell(attribution)
    )
  end
  out[#out + 1] = ""
end

local function section_decisions(L, out)
  out[#out + 1] = "### Decisions"
  out[#out + 1] = ""
  if #L.decisions == 0 then
    out[#out + 1] = "_no decision recorded_"
    out[#out + 1] = ""
    return
  end
  out[#out + 1] = "| t | actor | action | file | hunk | detail | fingerprints (expected → actual) |"
  out[#out + 1] = "|---|---|---|---|---|---|---|"
  for _, d in ipairs(L.decisions) do
    local fp = "-"
    if d.expected_fp or d.actual_fp then
      fp = string.format("%s → %s", nn(d.expected_fp), nn(d.actual_fp))
    end
    out[#out + 1] = string.format(
      "| %s | %s | %s | %s | %s | %s | %s |",
      fmt_ms(d.at_ms),
      cell(d.actor or "user"),
      cell(d.action),
      cell(d.rel or d.change_id),
      nn(d.hunk),
      cell(d.reason and (d.reason .. (d.detail and (": " .. d.detail) or "")) or d.detail),
      cell(fp)
    )
  end
  if L.decisions_dropped > 0 then
    out[#out + 1] = string.format("| … | | | | | _%d dropped past the cap_ | |", L.decisions_dropped)
  end
  out[#out + 1] = ""
end

local function section_outcome(L, out)
  out[#out + 1] = "### Outcome"
  out[#out + 1] = ""
  local o = L.outcome
  if not o then
    out[#out + 1] = "_turn not closed (still running, or the closing callback never fired)_"
    out[#out + 1] = ""
  else
    out[#out + 1] = string.format(
      "- exit code %s · result event %s · errored %s · cancelled %s",
      nn(o.exit_code),
      yes(o.got_result),
      yes(o.turn_errored),
      yes(o.cancelled)
    )
    out[#out + 1] = string.format(
      "- changes %s (%s still pending) · queued follow-ups %s · stderr %s bytes",
      nn(o.changes),
      nn(o.changes_pending),
      nn(o.queued),
      nn(o.stderr_len)
    )
    if o.confinement_failed then
      out[#out + 1] = string.format("- confinement refused: %s", cell(o.confinement_failed))
    end
    out[#out + 1] = ""
  end
  if L.pending_check then
    local pc = L.pending_check
    out[#out + 1] = string.format(
      "- pending counters at last render: panel %s, review engine %s (queued+active), batched %s%s",
      nn(pc.panel),
      nn(pc.pool),
      nn(pc.batched),
      pc.stuck and " — **DESYNC**" or ""
    )
  end
  if L.session_check then
    local sc = L.session_check
    out[#out + 1] = string.format(
      "- session registry: row %s, transcript %s%s",
      yes(sc.registry_row),
      yes(sc.transcript),
      sc.missing and " — **MISSING ROW**" or ""
    )
  end
  out[#out + 1] = ""
end

----------------------------------------------------------------------
-- public
----------------------------------------------------------------------

--- One turn as markdown lines.
function M.turn_lines(L)
  local out = {}
  if type(L) ~= "table" then
    return { "_no turn_" }
  end
  section_facts(L, out)
  section_timeline(L, out)
  section_spawns(L, out)
  section_events(L, out)
  section_usage(L, out)
  section_hunks(L, out)
  section_render_checks(L, out)
  section_appends(L, out)
  section_decisions(L, out)
  section_outcome(L, out)
  return out
end

--- Every retained turn, newest first, under one header.
function M.report_lines(turns)
  turns = turns or ledger.all()
  local out = {
    "# Yana flow report",
    "",
    string.format("Generated %s · %d retained turn(s).", ledger.wall_stamp(), #turns),
    "",
    "Sections mirror the screencast-derived ground truth so a log and a"
      .. " recording of the same turn can be compared row by row.",
    "",
  }
  for i = #turns, 1, -1 do
    vim.list_extend(out, M.turn_lines(turns[i]))
    out[#out + 1] = "---"
    out[#out + 1] = ""
  end
  if #turns == 0 then
    out[#out + 1] = "_no turns recorded in this session_"
  end
  return out
end

return M
