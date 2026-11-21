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

-- When the agent replies done.
-- The overlay copy makes every snapshotted buffer with unsaved edits look changed; a record whose agent revision is
-- still B0 is that copy, not an agent edit, so it is dropped unless it carries a create, delete or permission decision.
local function drop_snapshot_copies(changes, snaps)
  if not (changes and snaps) then return end
  local diff = require("yana.diff")
  local review_permissions = require("yana.review_permissions")
  for i = #changes, 1, -1 do
    local change = changes[i]
    local snap = type(change.path) == "string" and snaps[diff.abs_path(change.path)] or nil
    if snap and change.after == snap.b0 and not (change.kind == "delete" or change.kind == "create"
      or review_permissions.proposes_mode(change)) then
      table.remove(changes, i)
    end
  end
end

-- Put each file's snapshot on its record, with B1 and the edit counter read once, now.
local function attach_snapshots(changes, snaps)
  if not (changes and snaps) then return end
  local diff = require("yana.diff")
  for _, change in ipairs(changes) do
    local snap = type(change.path) == "string" and snaps[diff.abs_path(change.path)] or nil
    if snap then
      change.buffer_capture = snap
      change.buf_org = snap.b0
      if vim.api.nvim_buf_is_valid(snap.bufnr) and vim.api.nvim_buf_is_loaded(snap.bufnr) then
        change.buf_updated = diff.buffer_bytes_snapshot(snap.bufnr)
        change.tick_done = vim.api.nvim_buf_get_changedtick(snap.bufnr)
      end
      snap.carried = true
    end
  end
end

-- yanad owns the durable review record; publish absolute paths and turn-start evidence together.
local function set_review_bundle(turn, changes, prior_bundle)
  turn.review_files, turn.review_bundle = {}, {}
  local latest, copies, prior_before = {}, {}, {}
  if turn.source == "buffer" then
    local current
    current, copies = turn:changes()
    for _, change in ipairs(current) do latest[change.path] = change end
    for _, row in ipairs(prior_bundle or {}) do prior_before[row.id] = row.review_before end
  end
  for _, change in ipairs(changes) do
    turn.review_files[#turn.review_files + 1] = change.path
    if turn.source == "buffer" then
      local current = latest[change.path]
      if current and (current.kind == "create" or current.kind == "delete" or current.renamed_from or current.renamed_to) then
        change = vim.tbl_extend("force", {}, current, { id = change.id })
      elseif current and change.id ~= current.id then
        -- Existing members keep the baseline of their published review row.
        current = nil
      end
      local review_before
      if change.kind ~= "create" then
        review_before = current and (current.buf_updated or current.before)
          or prior_before[change.id] or change.buf_updated or change.before
      end
      local buf = change.buffer_capture and change.buffer_capture.bufnr
      local copy = copies[require("yana.turn.turn_cycle").canonical_path(change.path)]
      local proposal = (copy and copy.bytes) or change.after
      local format_text = proposal or change.before or ""
      local action = change.kind == "create" or change.kind == "delete" or change.renamed_from or change.renamed_to
      local format = buf and vim.bo[buf] or {
        fileformat = format_text:find("\r\n", 1, true) and "dos" or (format_text:find("\r", 1, true) and "mac" or "unix"),
        endofline = format_text:sub(-1) == "\n" or format_text:sub(-1) == "\r",
        bomb = format_text:sub(1, 3) == "\239\187\191", fileencoding = "utf-8",
      }
      turn.review_bundle[#turn.review_bundle + 1] = {
        id = change.id, source = "buffer", path = change.path,
        kind = action and change.kind or nil,
        base_state = action and (change.kind == "create" and "absent" or "file") or nil,
        after_state = action and (proposal == nil and "absent" or "file") or nil,
        rel = action and change.rel or nil, root = action and change.root or nil,
        base_hash = action and change.base_hash or nil, base_mode = action and change.base_mode or nil,
        after_mode = action and change.after_mode or nil, renamed_to = change.renamed_to, renamed_from = change.renamed_from,
        review_before = review_before, after = proposal,
        observed_after = proposal, fileformat = format.fileformat,
        endofline = format.endofline, bomb = format.bomb, fileencoding = format.fileencoding,
      }
    else
    turn.review_bundle[#turn.review_bundle + 1] = {
      id = change.id, path = change.path, rel = change.rel, root = change.root, root_index = change.root_index,
      root_is_primary = change.root_is_primary, kind = change.kind, base_state = change.base_state,
      base_hash = change.base_hash, base_mode = change.base_mode, base_hash_captured_ts = change.base_hash_captured_ts,
      after_mode = change.after_mode, upper_path = change.upper_path,
      -- B0 for every snapshotted file (INTERFACE.md section 1).
      review_before = change.buf_org,
    }
    end
  end
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

local function release_result(p, turn, reason)
  turn.result_release_pending = true
  release_shadow_turn(p, reason, function()
    turn.result_release_pending = nil
    S.finish_handover(p)
  end)
end

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
  release_result(p, turn, "unsafe artifact operation refused")
end

-- Files the Turn would offer once this run's change set joins it: its live members on a follow-up, plus the run's own.
local function turn_file_count(changes, followup)
  local canonical, paths = require("yana.turn.turn_cycle").canonical_path, {}
  local live = followup and require("yana.turn.turn_bind").get()
  for _, f in ipairs(live and live.files or {}) do
    paths[canonical(f.path)] = true
  end
  for _, c in ipairs(changes) do
    paths[canonical(c.path)] = true
  end
  return vim.tbl_count(paths)
end

-- Refuse a change set over review.max_files before any per-file review work (one panel block, hunk model and
-- review per file) can stall the editor; the proposal is kept for recovery, like an unsafe turn's.
local function release_oversize_turn(p, turn, changes, offered, limit)
  require("yana.panel.ui_followup").record_refused_run(p, turn, changes,
    string.format("the review would hold %d files, more than review.max_files (%d)", offered, limit))
  local recovery, recovery_note = preview_module().recover_layer(turn)
  -- One recovery folder per capture root; name every one holding files, not just the primary's (most are empty).
  local folders = {}
  for _, r in ipairs(turn.recovered_paths or {}) do
    if r.path and #vim.fn.readdir(r.path .. "/upper") > 0 then
      folders[#folders + 1] = r.path
    end
  end
  if #folders == 0 then
    folders[1] = tostring(recovery)
  end
  ledger.record_decision(turn_ledger(p, shadow_turn_gen(turn, p)), {
    action = "oversize_turn_refused",
    actor = "system",
    reason = string.format("%d files exceed review.max_files %d", offered, limit),
    recovery_path = recovery,
  })
  local msg = string.format(
    "the review would hold %d files, more than review.max_files (%d); nothing was applied and the real tree is"
      .. " unchanged; recover the proposal at %s (first: %s)",
    offered, limit, table.concat(folders, " and "), tostring(changes[1].path)
  )
  if recovery_note then
    msg = msg .. " (" .. tostring(recovery_note) .. ")"
  end
  render_error(p, msg)
  p.turn_errored = true
  release_result(p, turn, "change set exceeded review.max_files")
end

-- MCP has buffer rows, so only the daemon envelope differs at this shared exit boundary.
local function arm_review_open(run, done)
  if run.source ~= "buffer" then return preview_module().arm_review_open(run, done) end
  run.review_open_requested = true
  require("yana.shadow.preview_settle").send_review_frame("review_open", { session_id = run.yanad_session_id,
    turn_id = run.turn_id, generation = run.turn_pass.generation, mode = run.mode,
    source = "buffer", files = run.review_files, bundle = run.review_bundle },
    run.turn_id .. ":review.open:" .. run.turn_pass.generation, function(ok)
      run.review_open_marked = ok == true
      if done then done(ok) end
    end)
end

-- A follow-up's refused launch and its recorded result belong to the follow-up route (ui_followup.lua).
local followup_route = require("yana.panel.ui_followup")
followup_route.set_doors({ render_error = render_error, render_tool_change = render_tool_change,
  preview = preview_module, turn_ledger = turn_ledger, shadow_turn_gen = shadow_turn_gen,
  arm_review_open = arm_review_open, set_review_bundle = set_review_bundle, finish_handover = function(p) S.finish_handover(p) end })

local function finalize_shadow_turn_body(p, turn)
  -- Run-once: the flag lives on this run's record (turn/turn_cycle.lua), not on an object that outlives the run.
  if not require("yana.turn.turn_cycle").once(turn, "review_finalized") then
    return
  end
  -- The launch answer binds layer_dir/upper_dir; it MUST precede the walk
  -- because on_exit_confirmed runs before on_done.
  local mcp = turn.source == "buffer" and turn
  if mcp and turn.mode == "ask" then
    release_result(p, turn, "ask turn — nothing is proposed, nothing to review")
    return
  end
  local launch_answer = not mcp and require("yana.shadow.jail").consume_answer(turn)
  local refusal = type(launch_answer) == "table" and launch_answer.refuse
  local followup = require("yana.turn.turn_cycle").recording_run(turn)
  if not mcp and followup and (type(refusal) == "table" or not turn.upper_dir) then
    return followup_route.launch_refused(p, followup, type(refusal) == "table" and refusal.code,
      type(refusal) == "table" and refusal.reason or "the overlay did not establish a layer")
  end
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
    release_result(p, turn, "overlay launch refused: " .. tostring(code or "unknown"))
    return
  end
  if not mcp and not turn.upper_dir then
    -- Spawn/setup failure: no layer. Keep the primary process error; do not invent a second diagnosis.
    turn.yanad_session_id = nil
    p.turn_errored = true
    release_result(p, turn, "overlay launch did not establish a layer")
    return
  end
  local turn_gen = turn_generation(turn, p)
  local snaps = p.turn_buffer_captures and p.turn_buffer_captures[turn_gen]
  if not mcp then p.shadow_turn = turn end
  -- p.system_refusals is a never-cleared history, so snapshot its count to tell whether THIS turn refused.
  local system_refusals_before_turn = #(p.system_refusals or {})
  -- Confinement-refused writes become operator-visible refusals before any branch decides what the turn produced.
  if not mcp then record_confinement_refusals(p, turn) end
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
      release_result(p, turn, "preview report rendered")
    end
  elseif config.review_mode_active() then
    local ops = require("yana.shadow.ops")
    -- The third return is the FULL typed set incl. ops review cannot represent; without it a chmod/symlink/dir-only
    -- turn is released as "no changes", dropping the claim on files the agent touched.
    local changes, cerr, typed, classification, copies
    if mcp then
      changes, copies = mcp:review_changes()
      typed, classification = {}, { unsafe = {}, ignored = {} }
      for _, change in ipairs(changes) do
        change.root = change.root or turn.workspace
        change.rel = vim.fs.relpath(change.root, change.path) or change.path
        change.root_index, change.root_is_primary = 1, change.root == turn.workspace
        change.turn_id, change.turn_gen = turn.turn_id, turn.turn_gen
        typed[#typed + 1] = { rel = change.rel, kind = change.kind }
      end
    else
      changes, cerr, typed, classification = ops.changes_from_session(turn, {
        tracked_evidence = p.turn_pass and p.turn_pass.tracked_evidence or nil,
      })
    end
    -- ONE ceiling for every run, on the shared walk and before any per-file work: the files the Turn would offer, its
    -- open review's members (none on a first run) plus this run's. Only the owner differs: a follow-up shares the open
    -- review's layer, so its files are copied out and the review is kept for the operator to End or Abort; a first
    -- run moves its own layer out and releases its turn.
    local limit, offered = config.options.review.max_files, changes and turn_file_count(changes, followup)
    if offered and offered > limit then
      record_control_plane_refusals(turn, p, typed)
      if followup then
        followup.owner:record_result(followup, changes, { session = not mcp and turn or nil, view = copies, stopped = p.cancelled == true })
        return followup_route.refuse_result(p, turn, followup, changes,
          string.format("the review would hold %d files, more than review.max_files (%d)", offered, limit))
      end
      return release_oversize_turn(p, turn, changes, offered, limit)
    end
    -- Result reading seam (plan "### Reconciliation" step 3): a follow-up run records its raw records BEFORE
    -- drop_snapshot_copies, which would drop a member the agent left unchanged, and goes to publication.
    if followup then
      record_control_plane_refusals(turn, p, typed)
      if p.turn_pass then
        local _, berr = require("yana.turn.turn_lifecycle").publish_bundle(p.turn_pass, ops.classified_bundle_entries(typed))
        if berr then log.write(log.levels.WARN, "yana: bundle publication failed: " .. tostring(berr)) end
      end
      if not changes then
        render_error(p, "follow-up result unreadable: " .. tostring(cerr))
        return followup.owner:set_state("reviewing")
      end
      followup.owner:record_result(followup, changes, { session = not mcp and turn or nil, view = copies, stopped = p.cancelled == true }) -- A: read_run_view
      -- Classified like a first run: an unsafe operation refuses the run's whole result.
      if classification and #classification.unsafe > 0 then
        local names = {}
        for _, op in ipairs(classification.unsafe) do
          names[#names + 1] = tostring(op.kind) .. " " .. tostring(op.rel)
        end
        p.system_refusals = p.system_refusals or {}
        vim.list_extend(p.system_refusals, classification.unsafe)
        return followup_route.refuse_result(p, turn, followup, changes,
          "unsafe filesystem operation(s): " .. table.concat(names, ", "))
      end
      local wrote_ignored, ignored_error = write_through_ignored(p, turn, classification)
      local recorded, refusal_error = wrote_ignored, nil
      if wrote_ignored then
        recorded, refusal_error = record_artifact_refusals(p, turn, classification)
      end
      if not recorded then
        render_error(p, ignored_error or refusal_error)
        return followup.owner:set_state("reviewing")
      end
      return followup_route.publish_result(p, turn, followup)
    end
    if not mcp then
      drop_snapshot_copies(changes, snaps)
      attach_snapshots(changes, snaps)
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
        local pass, perr
        if mcp then pass = true else pass, perr = shadow_apply.begin_pass(turn, changes) end
        if not pass then
          render_error(p, perr or "shadow apply pass failed")
          p.turn_errored = true
          retain_shadow_turn(p, perr or "shadow apply pass failed")
        else
        -- Review is OPEN; the claim stays held until it closes (on_close).
        local turn_gen = shadow_turn_gen(turn, p)
        ledger.mark(turn_ledger(p, turn_gen), "apply_pass_began")
        if not mcp then p.shadow_pass = pass end
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
        set_review_bundle(turn, changes)
        arm_review_open(turn, function(ok)
          if ok then
            ledger.mark(turn_ledger(p, turn_gen), "review_claim_open")
            log.lifecycle("claim.open", {
              turn_id = tostring(turn.turn_id),
              panel = p.id,
              generation = turn_gen,
              stream = turn.stream,
            })
          end
          S.finish_handover(p)
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
        release_result(p, turn, release_reason)
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
    release_result(p, turn, "ask turn — nothing is proposed, nothing to review")
  end
end

-- Pin to the turn id the overlay carries, not the panel's current generation (a stopped turn is finalized after the
-- next one started); every note/change/error is recorded in that turn's ledger.
S.finalize_shadow_turn = function(p, turn)
  if not p or not turn then
    return
  end
  with_render_gen(p, shadow_turn_gen(turn, p), finalize_shadow_turn_body, p, turn)
  -- The agent is done: snapshots no file record carries are deleted now (BUILD.md runtime row 11).
  require("yana.input.submit_snapshot").release_snapshots(p.turn_buffer_captures, turn_generation(turn, p), true)
end

  return {
    release_unsafe_turn = release_unsafe_turn,
    finalize_shadow_turn_body = finalize_shadow_turn_body,
  }
end

return M
