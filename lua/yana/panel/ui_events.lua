-- Event-stream handling + refusal/confinement recording, split out of yana.ui (cluster
-- 6, front half -- see yana.ui_turn_shadow's and yana.ui_turn_end's headers for the
-- other two thirds of this cluster). `shadow_turn_gen` is exposed onto the shared state
-- table `S` (see deps.state below) rather than kept as a plain local, because BOTH this
-- file and yana.ui_turn_shadow/yana.ui_turn_end call it -- the same mechanism already
-- used for `S.submit_panel`/`S.cancel_inflight`.
local config = require("yana.config")
local diff = require("yana.diff")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local shadow_ops = require("yana.shadow.ops")
local log = require("yana.log")
local ledger = require("yana.ledger")
local steer_channel = require("yana.agent.steer_channel")

local M = {}
local uv = vim.uv or vim.loop

local function is_raw_tool_result(obj)
  if obj.type ~= "user" then
    return false
  end
  local content = obj.message and obj.message.content
  if type(content) ~= "table" then
    return false
  end
  for _, item in ipairs(content) do
    if type(item) == "table" and item.type == "tool_result" then
      return true
    end
  end
  return false
end

local function is_tool_boundary(obj)
  return (obj.type == "tool_call" and obj.subtype == "completed") or is_raw_tool_result(obj)
end

local function pending_is_armed(p)
  local pending = p.steer_pending
  if not pending or pending.at ~= "tool_boundary" then
    return false
  end
  if not pending.armed_hr then
    return true
  end
  -- Ignore stale same-tick tool results.
  return ((uv.hrtime() - pending.armed_hr) / 1e6) >= 50
end

-- deps.state: the parent's shared state table `S` -- read S.render_note,
-- S.submit_panel; this module ALSO assigns S.maybe_drain_queue and S.shadow_turn_gen
-- onto it (parent facade wires those after M.new returns). deps.append /
-- deps.append_stream / deps.render_tool_note / deps.render_error / deps.turn_ledger /
-- deps.with_render_gen: yana.ui_render facade locals. deps.update_winbar:
-- yana.ui_winbar facade local.
function M.new(deps)
  local S = deps.state
  local append = deps.append
  local append_stream = deps.append_stream
  local render_tool_note = deps.render_tool_note
  local render_user = deps.render_user
  local start_assistant_block = deps.start_assistant_block
  local render_error = deps.render_error
  local turn_ledger = deps.turn_ledger
  local with_render_gen = deps.with_render_gen
  local update_winbar = deps.update_winbar
  local panel_open = deps.panel_open
  local preview_module = deps.preview_module
  local remember_seat_session = deps.remember_seat_session
  local note_liveness_event = deps.note_liveness_event

local function turn_evidence_dir(p)
  if p.turn_pass and p.turn_pass.state_dir then
    return p.turn_pass.state_dir
  end
  local turn = p.job_shadow_turn or p.shadow_turn
  if turn and turn.turn_dir then
    return turn.turn_dir
  end
  return nil
end
local function finish_assistant_block(p, result_obj, gen)
	local o = config.options
	-- Fallback: nothing rendered at all but we have a final result string.
	local internal_proposal = p.turn_home_buffer_captures and p.turn_home_buffer_captures[gen]
	if not internal_proposal and not p.rendered_any and result_obj and type(result_obj.result) == "string" and result_obj.result ~= "" then
		append_stream(p, result_obj.result)
  end
  if o.ui.show_usage and result_obj and result_obj.usage then
    local u = result_obj.usage
    local secs = result_obj.duration_ms and string.format("%.1fs", result_obj.duration_ms / 1000) or nil
    local bits = {}
    if u.outputTokens then
      table.insert(bits, u.outputTokens .. " out")
    end
    if u.inputTokens then
      table.insert(bits, u.inputTokens .. " in")
    end
    if secs then
      table.insert(bits, secs)
    end
    if #bits > 0 then
      append(p, { "", "_" .. table.concat(bits, " · ") .. "_" }, "usage")
    end
  end
  append(p, { "", "---", "" }, "separator")
end
local function is_disk_bearing_tool_call(obj)
  if obj.type ~= "tool_call" or obj.subtype ~= "completed" then
    return false
  end
  local name, payload = diff.parse_tool(obj)
  if not name then
    return false
  end
  return diff.change_from_payload(name, payload) ~= nil
end

  function S.deliver_steer_now(p)
    if not p
      or not p.steer_pending
      or p.steer_pending.at ~= "now"
      or p.steer_channel_active ~= "stream-json"
      or not p.job
    then
      return false
    end
    -- Submit #3 sends after the keyfeed unwinds.
    local text = p.steer_pending.text
    if not steer_channel.deliver(p, text, { interrupt = true }) then
      return false
    end
    render_user(p, text)
    S.render_note(p, "⏸ interrupted — sending your message")
    start_assistant_block(p)
    update_winbar(p)
    return true
  end

  local function on_event_body(p, gen, obj)
  local stale = gen ~= p.turn_gen
  -- Provenance, record 2 of 3. Stamped for EVERY decoded event, stale ones
  -- included, before any gate can drop it: an event the panel never rendered
  -- still happened, and the conservation sum in the flow report is only
  -- honest if it is counted here rather than where it survives.
  local L = ledger.ensure(p.id, gen)
  local seq = ledger.note_event(L, obj, stale)
  ledger.record_decoded_event(L, seq, obj, stale)
  ledger.mark(L, "first_event_decoded")
  -- Appends made underneath this call name `seq` as their cause. Cleared on
  -- the way out (and again at turn end) so an append made outside event
  -- handling records no cause rather than borrowing this one.
  ledger.set_current_event(L, seq)
  if stale and not is_disk_bearing_tool_call(obj) then
    ledger.set_current_event(L, nil)
    return
  end
  if stale then
    ledger.bump(L, "events_stale_disk_bearing")
  end
  local o = config.options
  if p.steer_pending and p.steer_pending.at == "now" and p.steer_channel_active == "stream-json" then
    S.deliver_steer_now(p)
  end
  if obj.type == "system" and obj.subtype == "init" then
    ledger.mark(L, "session_init")
    -- O1: once a seat has an id (resume / prior init), do not retarget it from
    -- a later vendor echo — fixtures and flaky vendors must not drift the seat.
    if p.session_id == nil or p.session_id == "" then
      p.session_id = obj.session_id
    end
    remember_seat_session(p)
  elseif obj.type == "assistant" then
    local content = obj.message and obj.message.content or {}
	local internal_proposal = p.turn_home_buffer_captures and p.turn_home_buffer_captures[gen]
    for _, item in ipairs(content) do
      if item.type == "text" then
        -- Streaming deltas carry timestamp_ms but NOT model_call_id. The
        -- consolidated messages carry model_call_id (intermediate) or neither
        -- (final), so we render only true deltas to avoid duplication.
		if not internal_proposal and obj.timestamp_ms and not obj.model_call_id then
          append_stream(p, item.text or "")
        end
      elseif item.type == "thinking" then
		if not internal_proposal and o.ui.show_thinking and obj.timestamp_ms and not obj.model_call_id then
          append_stream(p, item.text or item.thinking or "")
        end
      end
    end
  elseif obj.type == "tool_call" then
    -- Tool calls are top-level events. Render on completion so results (and
    -- diffs) are available.
    if obj.subtype == "completed" then
      ledger.mark(L, "first_tool_call")
      local name, payload = diff.parse_tool(obj)
      if name == "shellToolCall" then
        p.shell_steps_total = (p.shell_steps_total or 0) + 1
        local res = payload and payload.result
        local failed = true
        local exit_code
        if type(res) == "table" then
          if type(res.failure) == "table" then
            exit_code = res.failure.exitCode
          elseif type(res.success) == "table" then
            exit_code = res.success.exitCode
            failed = type(exit_code) ~= "number" or exit_code ~= 0
          else
            failed = true
          end
        end
        if failed then
          p.shell_steps_failed = (p.shell_steps_failed or 0) + 1
          if p.first_failed_shell_exit == nil then
            p.first_failed_shell_exit = exit_code
            local args = payload and payload.args
            if type(args) == "table" then
              p.first_failed_shell_command = args.command
            end
          end
        end
      end
      if name then
        local change = diff.change_from_payload(name, payload)
        if change then
          ledger.bump(L, "changes_parsed")
          change.turn_gen = gen
          require("yana.turn.turn_lifecycle").note_declared(p.turn_pass, change.rel)
        end
        -- The overlay's typed change set is the ONLY review producer. The the agent's
        -- report is never authoritative evidence, so a tool_call event is rendered as a
        -- note and nothing more: it never becomes a change record and never reaches any
        -- writer. The control-plane refusals that carry evidence are the overlay's, at
        -- record_control_plane_refusals, and the scope-revert guard above.
        render_tool_note(p, name, payload)
      end
      if pending_is_armed(p) then
        -- Boundary delivery trigger.
        local text = p.steer_pending.text
        if p.steer_channel_active == "stream-json" then
          if steer_channel.deliver(p, text, { interrupt = true }) then
            render_user(p, text)
            S.render_note(p, "⏸ interrupted at tool boundary — sending your message")
            start_assistant_block(p)
          end
        elseif S.steer_text then
          p.steer_pending = nil
          S.steer_text(p, text, { note = "⏹ interrupted to steer — waiting for the previous process to exit" })
        end
        update_winbar(p)
      end
    end
  elseif is_tool_boundary(obj) and pending_is_armed(p) then
    -- A raw tool_result is a degradation seam.
    local text = p.steer_pending.text
    if S.steer_text then
      p.steer_pending = nil
      S.steer_text(p, text, { note = "⏹ interrupted to steer — waiting for the previous process to exit" })
    end
    update_winbar(p)
  elseif obj.type == "result" then
    ledger.mark(L, "result_received")
    -- §2.7 usage retention: the numbers the panel renders once and forgets
    -- become a per-turn record, so "the agent got slower this week" and
    -- runaway-cost triage are queryable rather than anecdotal.
    local usage = ledger.set_usage(L, obj)
    p.got_result = true
    if type(obj.result) == "string" and obj.result ~= "" then
      p.turn_answers[gen] = obj.result
      p.last_answer_text = obj.result
    end
    if p.session_id == nil or p.session_id == "" then
      p.session_id = obj.session_id
    end
    if usage then
      local lifecycle = require("yana.turn.turn_lifecycle")
      local function persist_usage(pass)
        if not pass then
          return
        end
        pass.usage = usage
        pass.session_id = p.session_id
        -- Persist the vendor result while the turn is still recoverable. A
        -- process crash after the result but before review settlement must not
        -- erase the only durable copy of the usage facts.
        lifecycle.persist(pass, "open")
      end
      persist_usage(p.turn_pass)
      local shadow_pass = p.shadow_turn and p.shadow_turn.turn_pass
      if shadow_pass ~= p.turn_pass then
        persist_usage(shadow_pass)
      end
    end
    remember_seat_session(p)
		finish_assistant_block(p, obj, gen)
    local self_interrupted = p.self_interrupted
    if self_interrupted then
      p.self_interrupted = nil
    end
    if p.steer_channel_active == "stream-json" then
      if p.steer_pending then
        local text = p.steer_pending.text
        if steer_channel.deliver(p, text, { interrupt = false }) then
          render_user(p, text)
          start_assistant_block(p)
        end
        update_winbar(p)
      elseif not self_interrupted then
        steer_channel.close(p)
      end
    end
    if obj.is_error and not self_interrupted then
      render_error(p, type(obj.result) == "string" and obj.result ~= "" and obj.result or "agent reported an error", {
        vendor_backend = config.options.backend,
        evidence_dir = turn_evidence_dir(p),
      })
      p.turn_errored = true
    end
  elseif obj.type == "error" then
    render_error(p, obj.message or obj.error or "agent error", {
      vendor_backend = config.options.backend,
      evidence_dir = turn_evidence_dir(p),
    })
    p.turn_errored = true
  end
  ledger.set_current_event(L, nil)
end
local function on_event(p, gen, obj)
  -- Liveness first, and outside the render gate: the stamp is a fact about
  -- the PROCESS ("it produced output just now"), not about what the panel
  -- decided to draw, and it must survive every early return below.
  note_liveness_event(p, gen, obj)
  with_render_gen(p, gen, on_event_body, p, gen, obj)
end
function S.maybe_drain_queue(p)
  if p.busy or p.job ~= nil or p.awaiting_exit or #p.queue == 0 or not panel_open(p) then
    return
  end
  if config.options.queue.pause_on_error and p.turn_errored then
    notify_one_line(
      string.format(
        "yana: turn errored — %d queued prompt(s) held; send with %s",
        #p.queue,
        config.options.mappings.queue or "the queue picker"
      ),
      vim.log.levels.WARN
    )
    return
  end
  local next_prompt = table.remove(p.queue, 1)
  update_winbar(p)
  S.submit_panel(p, { text = next_prompt })
end
local function record_control_plane_refusals(turn, p, typed)
  return shadow_ops.record_control_plane_refusals(shadow_ops.control_plane_warn_scope({
    workspace = turn and turn.workspace,
    stream = turn and turn.stream,
    turn_id = turn and (turn.turn_id or (p and p.turn_gen)),
  }, {
    panel_id = p and p.id,
  }), typed)
end

local function shadow_turn_gen(turn, p)
  if turn and turn.turn_gen ~= nil then
    return turn.turn_gen
  end
  -- Legacy/recovered turns may predate the explicit turn_gen field. Their
  -- turn_id is still the durable owner and must win over the panel's current
  -- generation, which may already name a different turn.
  if turn and turn.turn_id ~= nil then
    return turn.turn_id
  end
  return p and p.turn_gen or 0
end
local REFUSAL_SAMPLE = 20

local function refusal_kind_summary(counts)
  local parts = {}
  for kind, count in pairs(counts or {}) do
    parts[#parts + 1] = tostring(kind) .. "=" .. tostring(count)
  end
  table.sort(parts)
  return table.concat(parts, ", ")
end
local function write_through_ignored(p, turn, classification)
  local entries = (classification and classification.ignored) or {}
  if #entries == 0 then
    return true
  end
  table.sort(entries, function(a, b)
    return tostring(a.rel) < tostring(b.rel)
  end)
  local ignore = require("yana.paths.ignore")
  local written, werr = ignore.write_through(entries)
  if not written then
    return false, "writing an ignored path through failed: " .. tostring(werr)
  end
  local NAME_CAP = 12
  local shown = {}
  for i = 1, math.min(#written, NAME_CAP) do
    shown[i] = written[i]
  end
  local names = table.concat(shown, ", ")
  if #written > NAME_CAP then
    names = names .. string.format(", … and %d more", #written - NAME_CAP)
  end
  S.render_note(p, string.format("%d ignored path(s) written through: %s", #written, names))
  log.lifecycle("review.ignored", {
    turn_id = turn and turn.turn_id or nil,
    generation = shadow_turn_gen(turn, p),
    workspace = turn and (turn.broad_root or turn.workspace) or nil,
    count = #written,
    paths = written,
  })
  log.write(
    log.levels.WARN,
    string.format(
      "yana: %d path(s) matched the review ignore list and were written through unreviewed: %s",
      #written,
      names
    )
  )
  return true
end

local function record_artifact_refusals(p, turn, classification)
  local L = turn_ledger(p, shadow_turn_gen(turn, p))
  p.system_refusals = p.system_refusals or {}
  for _, group in ipairs((classification and classification.groups) or {}) do
    group.sample = {}
    for i = 1, math.min(#group.members, REFUSAL_SAMPLE) do
      group.sample[#group.sample + 1] = group.members[i].rel
    end
    group.members_truncated = #group.members > #group.sample
    local listing, err = preview_module().retain_refusal_group(turn, group)
    if not listing then
      return false, "persisting artifact refusal listing failed: " .. tostring(err)
    end
    ledger.record_refusal_group(L, group)
    p.system_refusals[#p.system_refusals + 1] = {
      status = "system_refused",
      turn = turn.turn_id,
      root = group.root,
      count = group.count,
      kind_counts = group.kind_counts,
      listing_path = group.listing_path,
      layer_path = group.layer_path,
      retention_strength = "momentary",
    }
    S.render_note(p, string.format(
      "⛔ %s/: %d artifact operation(s) system-refused (%s); inspectable at %s until this turn settles; complete listing: %s",
      group.root,
      group.count,
      refusal_kind_summary(group.kind_counts),
      group.layer_path,
      group.listing_path
    ))
  end
  for _, op in ipairs((classification and classification.individual) or {}) do
    op.turn = turn.turn_id
    op.reason = op.refusal_reason
    ledger.record_decision(L, {
      action = "review_refused",
      actor = "system",
      reason = op.refusal_reason,
      detail = op.detail,
      rel = op.rel,
      status = "system_refused",
      retention_strength = "momentary",
    })
    ledger.bump(L, "ops_system_refused")
    p.system_refusals[#p.system_refusals + 1] = op
    S.render_note(p, string.format(
      "⛔ %s %s system-refused; inspectable at %s/%s until this turn settles",
      tostring(op.kind),
      tostring(op.rel),
      tostring(turn.upper_dir),
      tostring(op.rel)
    ))
  end
  return true
end
-- A write the confinement refused becomes an operator-visible refusal.
--
-- The panel, the change-set headers and the refusal records were all silent, and the
-- only account was the agent's own narration, which is not a yana surface. The operator
-- saw a turn that "worked" while half the requested work had silently not happened.
--
-- WHY HERE. The change-set producer walks the turn's upper layer (`shadow/ops.lua`
-- `read_records`), and a write that never landed leaves nothing under any upper dir —
-- it is invisible there by construction, not by a missing branch. The `tool_call`
-- branch above has only `diff.tool_summary`'s prose, the agent's own self-report, which
-- must never select what yana records.
--
-- The record reuses the existing `system_refused` machinery (panel note,
-- `p.system_refusals` → `:YanaRefusals`, a ledger decision, a durable WARN),
-- not a parallel one. Reason and remedy come from `jail.lua`'s single
-- constants, so operator-declared write roots extend the remedy in one place.
--
-- TOTAL AND INERT ON AN ORDINARY TURN: no refusal record on the turn means an
-- immediate `0`, nothing rendered, nothing logged, nothing recorded.
local function record_confinement_refusals(p, turn)
  local rows = turn and turn.confinement_refusals
  if type(rows) ~= "table" or #rows == 0 then
    return 0
  end
  local jail = require("yana.shadow.jail")
  local L = turn_ledger(p, shadow_turn_gen(turn, p))
  local reason = jail.OUT_OF_WORKSPACE_REASON
  p.system_refusals = p.system_refusals or {}
  local recorded = 0
	local home_input = vim.env.HOME
	local home = type(home_input) == "string" and home_input ~= "" and vim.fs.normalize(home_input):gsub("/+$", "") or nil
  for _, row in ipairs(rows) do
    local paths = type(row.paths) == "table" and row.paths or {}
    -- PER REFUSAL, not once per turn: the remedy names the `write_roots` line
    -- that would have made THIS write legal, derived from the refused path's
    -- own ancestors on disk (jail.declarable_write_root). A refusal that named
    -- no path gets the unspecialised sentence, exactly as before.
	local remedy = jail.out_of_workspace_remedy(paths)
	if home then
		for _, path in ipairs(paths) do
			local normalized = type(path) == "string" and vim.fs.normalize(path) or nil
			if normalized and vim.fn.fnamemodify(normalized, ":h") == home then
				local name = vim.fn.fnamemodify(normalized, ":t")
				remedy = string.format("Open ~/%s in a Neovim buffer and start the inline edit from that buffer", name)
				break
			end
		end
	end
    -- When the confinement's own message named no path, the record still says
    -- what happened rather than inventing one.
    local named = #paths > 0 and table.concat(paths, ", ") or "a path outside the claimed workspace"
    ledger.record_decision(L, {
      action = "write_refused",
      actor = "system",
      status = "system_refused",
      rel = named,
      reason = reason,
      detail = row.evidence,
      remedy = remedy,
      retention_strength = "none",
    })
    ledger.bump(L, "writes_refused")
    p.system_refusals[#p.system_refusals + 1] = {
      status = "system_refused",
      turn = row.turn or (turn and turn.turn_id),
      kind = "blocked_write",
      rel = named,
      reason = reason .. " -- " .. remedy,
      evidence = row.evidence,
      retention_strength = "none",
      recovery_path = "none",
    }
    S.render_note(p, string.format("⛔ write refused: %s -- %s. %s (%s)", named, reason, remedy, tostring(row.evidence)))
    -- WARN because log.lua persists only WARN/ERROR: a silently dropped half
    -- of a turn has to survive the session that dropped it.
    log.write(
      log.levels.WARN,
      string.format(
        "yana: turn %s attempted a write the confinement refused at %s -- %s; %s (%s)",
        tostring(row.turn or (turn and turn.turn_id)),
        named,
        reason,
        remedy,
        tostring(row.evidence)
      )
    )
    recorded = recorded + 1
  end
  if (turn.confinement_refusals_dropped or 0) > 0 then
    S.render_note(p, string.format(
      "⛔ %d further refused write(s) past this turn's record cap were not listed",
      turn.confinement_refusals_dropped
    ))
  end
  return recorded
end

  return {
    turn_evidence_dir = turn_evidence_dir,
    on_event = on_event,
    shadow_turn_gen = shadow_turn_gen,
    refusal_kind_summary = refusal_kind_summary,
    record_control_plane_refusals = record_control_plane_refusals,
    write_through_ignored = write_through_ignored,
    record_artifact_refusals = record_artifact_refusals,
    record_confinement_refusals = record_confinement_refusals,
  }
end

return M
