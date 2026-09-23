-- Shadow-turn finalize + unsafe-turn release (middle third of the turn-end cluster; see ui_events, ui_turn_end).
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local shadow_apply = require("yana.shadow.apply")

local M = {}

local function turn_generation(turn, panel)
  if turn and turn.turn_gen ~= nil then
    return turn.turn_gen
  end
  if turn and turn.turn_id ~= nil then
    return turn.turn_id
  end
  return panel and panel.turn_gen or 0
end

-- deps.state: shared S; this module assigns S.finalize_shadow_turn onto it. render_*/turn_ledger/with_render_gen: ui_render and ui_review facade locals.
function M.new(deps)
  local S = deps.state
  local shadow_turn_gen = S.shadow_turn_gen
  local render_error = deps.render_error
  local turn_ledger = deps.turn_ledger
  local with_render_gen = deps.with_render_gen
  local render_tool_change = deps.render_tool_change
  local preview_module = deps.preview_module
  local release_shadow_turn = deps.release_shadow_turn
  local retain_shadow_turn = deps.retain_shadow_turn
  local record_confinement_refusals = deps.record_confinement_refusals
  local write_through_ignored = deps.write_through_ignored
  local record_artifact_refusals = deps.record_artifact_refusals
  local record_control_plane_refusals = deps.record_control_plane_refusals

local function release_unsafe_turn(p, turn, classification)
  local recovery, recovery_note = preview_module().recover_layer(turn)
  local names = {}
  local L = turn_ledger(p, shadow_turn_gen(turn, p))
  for _, op in ipairs(classification.unsafe or {}) do
    op.turn = turn.turn_id
    op.recovery_path = recovery
    names[#names + 1] = tostring(op.kind) .. " " .. tostring(op.rel)
    ledger.record_decision(L, {
      action = "unsafe_operation_refused",
      actor = "system",
      reason = op.refusal_reason,
      rel = op.rel,
      kind = op.kind,
      recovery_path = recovery,
    })
  end
  local msg = string.format(
    "unsafe filesystem operation(s) were not applied; the real tree is unchanged; recover the proposal at %s: %s",
    tostring(recovery),
    table.concat(names, ", ")
  )
  if recovery_note then
    msg = msg .. " (" .. tostring(recovery_note) .. ")"
  end
  render_error(p, msg)
  p.turn_errored = true
  p.system_refusals = p.system_refusals or {}
  for _, op in ipairs(classification.unsafe or {}) do
    p.system_refusals[#p.system_refusals + 1] = op
  end
  release_shadow_turn(p, "unsafe artifact operation refused", function(ok)
    if ok then S.maybe_drain_queue(p) end
  end)
end

local function finalize_shadow_turn_body(p, turn)
  if turn._review_finalized then
    return
  end
  turn._review_finalized = true
  -- The launch answer binds layer_dir/upper_dir; it MUST precede the walk
  -- because on_exit_confirmed runs before on_done.
  local launch_answer = require("yana.shadow.jail").consume_answer(turn)
  local refusal = type(launch_answer) == "table" and launch_answer.refuse
  if type(refusal) == "table" then
    local code = refusal.code
    local retried = code == "unknown_session"
      and not turn._yanad_session_retry
      and p.yanad_start_session
      and p.turn_questions
      and p.turn_questions[turn_generation(turn, p)]
    if retried then
      -- Unknown session: park the prompt, clear the stale identity, let the parked-submit door fire it once.
      -- The failed turn has no layer and must never enter the change-set walk.
      turn._yanad_session_retry = true
      local question = p.turn_questions[turn_generation(turn, p)]
      p.yanad_session_id = nil
      turn.yanad_session_id = nil
      p.yanad_submit_queue = p.yanad_submit_queue or {}
      table.insert(p.yanad_submit_queue, 1, question)
      p.yanad_start_session(p)
    else
      -- The refusal is already the operator-facing error; release locally without asking the daemon to close it.
      turn.yanad_session_id = nil
    end
    p.turn_errored = true
    release_shadow_turn(p, "overlay launch refused: " .. tostring(code or "unknown"))
    return
  end
  if not turn.upper_dir then
    -- Spawn/setup failure: no layer. Keep the primary process error; do not invent a second diagnosis.
    turn.yanad_session_id = nil
    p.turn_errored = true
    release_shadow_turn(p, "overlay launch did not establish a layer")
    return
  end
  local turn_gen = turn_generation(turn, p)
  local home_capture = p.turn_home_buffer_captures and p.turn_home_buffer_captures[turn_gen]
  if home_capture then
    if p.cancelled or p.turn_errored or tonumber(turn.agent_exit_code or 1) ~= 0 then
      release_shadow_turn(p, "buffer-only proposal discarded because the turn did not complete successfully")
      return
    end
    local response = p.turn_answers and p.turn_answers[turn_gen]
    local published, publish_err = require("yana.input.home_buffer_proposal").publish(turn, home_capture, response)
    if not published then
      render_error(p, publish_err)
      p.turn_errored = true
      retain_shadow_turn(p, publish_err)
      return
    end
  end
  p.shadow_turn = turn
  -- p.system_refusals is a never-cleared history, so snapshot its count to tell whether THIS turn refused.
  local system_refusals_before_turn = #(p.system_refusals or {})
  -- Confinement-refused writes become operator-visible refusals before any branch decides what the turn produced.
  record_confinement_refusals(p, turn)
  if not config.overlay_mode() then
    local preview = require("yana.shadow.preview")
    -- The upper layer IS the change set. render_report's second return is the report table on success, else an error string.
    local rendered, report = preview.render_report(p, turn)
    if not rendered then
      render_error(p, report or "reading the change set failed")
      p.turn_errored = true
      retain_shadow_turn(p, report or "reading the change set failed")
    else
      -- Same durable control-plane record as the apply branch (render_report shows it only transiently).
      record_control_plane_refusals(turn, p, report and report.ops)
      -- Preview mode reports and stops: release the claim now.
      release_shadow_turn(p, "preview report rendered")
    end
  elseif config.review_mode_active() then
    local ops = require("yana.shadow.ops")
    -- The third return is the FULL typed set incl. ops review cannot represent; without it a chmod/symlink/dir-only
    -- turn is released as "no changes", dropping the claim on files the agent touched.
    local changes, cerr, typed, classification = ops.changes_from_session(turn, {
      tracked_evidence = p.turn_pass and p.turn_pass.tracked_evidence or nil,
    })
    changes, typed, classification = require("yana.input.home_buffer_proposal")
      .classify_buffer_restore(turn, home_capture, changes, typed, classification)
    if home_capture then
      if turn.home_buffer_noop and (not changes or #changes == 0) then
        -- Exact unsaved baseline returned: no edit, no review; the unsaved bytes stay unsaved.
      elseif not changes or #changes ~= 1 or changes[1].path ~= home_capture.path then
        render_error(p, "buffer-only proposal did not classify as its one pinned target")
        p.turn_errored = true
        retain_shadow_turn(p, "buffer-only proposal target mismatch")
        return
      else
        changes[1].review_before = home_capture.buffer_bytes
        changes[1].home_buffer_capture = home_capture
        changes[1].diff = require("yana.diff").synthesize_diff(home_capture.buffer_bytes, changes[1].after or "", home_capture.path)
		S.render_note(p, "Edit ready for review.")
      end
    end
    ledger.mark(turn_ledger(p, shadow_turn_gen(turn, p)), "change_set_read")
    log.buffer_event("classified", { panel_id = p.id, generation = turn_gen, turn_id = turn.turn_id,
      cwd = turn.workspace or p.cwd, proposal_count = changes and #changes, reason = cerr })
    for _, change in ipairs(changes or {}) do
      log.buffer_event("proposal", { panel_id = p.id, generation = turn_gen,
        turn_id = turn.turn_id, change = change })
    end
    -- Recorded on the turn so every hunk header asks the same settled question.
    do
      local seen, count, names = {}, 0, {}
      for _, c in ipairs(changes or {}) do
        local root = type(c.root) == "string" and c.root or nil
        if root and not seen[root] then
          seen[root] = true
          count = count + 1
          names[#names + 1] = root
        end
      end
      table.sort(names)
      turn.repo_count = count
      turn.touched_repos = names
    end
    -- Durable control-plane record, taken BEFORE the display branches so a turn whose only ops are control-plane
    -- is recorded too; the count is reused by the panel note so both agree.
    local cp_count = record_control_plane_refusals(turn, p, typed)
    -- CORE: control-plane writes are walked, COUNTED and REPORTED, not silent.
    if cp_count > 0 then
      S.render_note(p, string.format(
        "⚠ %d control-plane file(s) the turn wrote were recorded and discarded with the overlay (never offered for review)",
        cp_count
      ))
    end
    -- PUBLICATION: typed ops carry their class, so the bundle becomes authoritative and the review stops being provisional.
    if p.turn_pass then
      local lifecycle = require("yana.turn.turn_lifecycle")
      local classified = ops.classified_bundle_entries(typed)
      local bundle, berr = lifecycle.publish_bundle(p.turn_pass, classified)
      if not bundle then
        -- Unpublishable bundle leaves the review provisional rather than quietly actionable.
        log.write(log.levels.WARN, "yana: bundle publication failed: " .. tostring(berr))
      end
    end
    if not changes then
      render_error(p, cerr or "reading the change set failed")
      p.turn_errored = true
      -- Unreadable evidence: whether a review is owed is unknown; never guess dead -- keep claim and private state.
      retain_shadow_turn(p, cerr or "reading the change set failed")
    elseif classification and #classification.unsafe > 0 then
      release_unsafe_turn(p, turn, classification)
    else
      -- BEFORE the review opens or any refusal is recorded: ignored paths are not in the review, and an ignored-only
      -- turn must still land them (it reaches the `#changes == 0` branch and releases).
      local wrote_ignored, ignored_error = write_through_ignored(p, turn, classification)
      if not wrote_ignored then
        render_error(p, ignored_error)
        p.turn_errored = true
        retain_shadow_turn(p, ignored_error)
        return
      end
      local recorded, refusal_error = record_artifact_refusals(p, turn, classification)
      if not recorded then
        render_error(p, refusal_error)
        p.turn_errored = true
        retain_shadow_turn(p, refusal_error)
      elseif #changes > 0 then
        local pass, perr = shadow_apply.begin_pass(turn, changes)
        if not pass then
          render_error(p, perr or "shadow apply pass failed")
          p.turn_errored = true
          retain_shadow_turn(p, perr or "shadow apply pass failed")
        else
        -- Review is OPEN; the claim stays held until it closes (on_close).
        local turn_gen = shadow_turn_gen(turn, p)
        ledger.mark(turn_ledger(p, turn_gen), "apply_pass_began")
        p.shadow_pass = pass
        p.changes = p.changes or {}
        for _, change in ipairs(changes) do
          -- Every later record (hunk model, render check, decision) correlates through the generation; the turn id IS it.
          change.turn_gen = change.turn_gen or turn_gen
          -- Stamp the published bundle digest so a decision is checked against the bundle it was offered from.
          change.bundle_digest = p.turn_pass
            and p.turn_pass.bundle
            and p.turn_pass.bundle.bundle_digest
            or nil
          change.panel_id = change.panel_id or p.id
          ledger.bump(turn_ledger(p, turn_gen), "changes_parsed")
          table.insert(p.changes, change)
          render_tool_change(p, change)
        end
        -- yanad owns the durable review record; publish absolute paths and turn-start evidence together.
        turn.review_files = {}
        turn.review_bundle = {}
        for _, change in ipairs(changes) do
          turn.review_files[#turn.review_files + 1] = change.path
		  turn.review_bundle[#turn.review_bundle + 1] = {
            id = change.id,
            path = change.path,
            rel = change.rel,
            root = change.root,
            root_index = change.root_index,
            root_is_primary = change.root_is_primary,
            kind = change.kind,
            base_state = change.base_state,
            base_hash = change.base_hash,
            base_mode = change.base_mode,
            base_hash_captured_ts = change.base_hash_captured_ts,
            after_mode = change.after_mode,
		    upper_path = change.upper_path,
		    -- Recovery cannot rebuild an unsaved buffer baseline from disk; keep it in the daemon-owned bundle.
		    home_buffer_only = change.home_buffer_capture ~= nil or nil,
		    review_before = change.home_buffer_capture and change.review_before or nil,
		  }
        end
        preview_module().arm_review_open(turn, function(ok)
          if ok then
            ledger.mark(turn_ledger(p, turn_gen), "review_claim_open")
            log.lifecycle("claim.open", {
              turn_id = tostring(turn.turn_id),
              panel = p.id,
              generation = turn_gen,
              stream = turn.stream,
            })
          end
        end)
        end
      else
        -- Empty `changes` is reached by a genuinely system-refused turn AND by a turn that produced nothing;
        -- only the former may claim a refusal.
        local turn_had_refusals = #(p.system_refusals or {}) > system_refusals_before_turn
        local ignored_count = #((classification and classification.ignored) or {})
        local release_reason
        if turn_had_refusals then
          release_reason = "all artifact operations system-refused"
        elseif ignored_count > 0 then
          -- An all-ignored turn landed real changes, so "no_changes" would be false.
          release_reason = string.format("all %d change(s) were ignored paths, written through", ignored_count)
        else
          release_reason = "no_changes"
        end
        release_shadow_turn(p, release_reason, function(ok)
          if ok then S.maybe_drain_queue(p) end
        end)
      end
    end
  else
    -- `ask`: confined like inline but proposes nothing, so no review opens. Without this branch the turn holds the
    -- workspace claim, private layer and lifecycle pass. The layer is read before discard so a writing ask turn is
    -- disclosed rather than silently dropped.
    local ops = require("yana.shadow.ops")
    local ok_read, a, b, typed = pcall(ops.changes_from_session, turn)
    local turn_gen = shadow_turn_gen(turn, p)
    if ok_read and typed then
      record_control_plane_refusals(turn, p, typed)
      if #typed > 0 then
        log.write(
          log.levels.WARN,
          string.format(
            "yana: ask turn %s wrote %d path(s) into the private layer -- discarded with the overlay, never offered for review",
            tostring(turn_gen),
            #typed
          )
        )
        S.render_note(p, string.format(
          "⚠ this ask turn wrote %d path(s); they were confined to the private layer and discarded",
          #typed
        ))
      end
    else
      -- A throw or returned failure is a halt and must be recorded; release still follows (no review is owed).
      local why = ok_read and tostring(b or "reading the change set failed") or tostring(a)
      log.write(
        "WARN",
        string.format(
          "yana: ask turn %s layer could not be read (%s) -- discarded with the overlay, never offered for review",
          tostring(turn_gen),
          why
        )
      )
      S.render_note(p, string.format(
        "⚠ this ask turn's private layer could not be read (%s); it was discarded",
        why
      ))
    end
    -- Released unconditionally: an unreadable layer is no reason to keep the claim.
    release_shadow_turn(p, "ask turn — nothing is proposed, nothing to review")
  end
end

-- Pin to the turn id the overlay carries, not the panel's current generation (a stopped turn is finalized after the
-- next one started); every note/change/error is recorded in that turn's ledger.
S.finalize_shadow_turn = function(p, turn)
  if not p or not turn then
    return
  end
  with_render_gen(p, shadow_turn_gen(turn, p), finalize_shadow_turn_body, p, turn)
end

  return {
    release_unsafe_turn = release_unsafe_turn,
    finalize_shadow_turn_body = finalize_shadow_turn_body,
  }
end

return M
