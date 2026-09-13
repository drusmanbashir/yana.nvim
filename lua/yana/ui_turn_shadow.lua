-- Shadow-turn finalize + unsafe-turn release, split out of yana.ui (cluster 6, middle
-- third -- see yana.ui_events's header for the front third and yana.ui_turn_end's for
-- the back third).
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local shadow_apply = require("yana.shadow.apply")

local M = {}

-- deps.state: the parent's shared state table `S` -- read S.shadow_turn_gen (see header
-- above), S.render_note, S.maybe_drain_queue; this module assigns
-- S.finalize_shadow_turn onto it (parent facade wires that after M.new returns).
-- deps.render_error / deps.turn_ledger / deps.with_render_gen: yana.ui_render facade
-- locals. deps.render_tool_change: yana.ui_review facade local.
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
  local apply_single_file_filter = deps.apply_single_file_filter
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
  require("yana.shadow.jail").consume_answer(turn)
  p.shadow_turn = turn
  -- ROW 86 WITNESS: `p.system_refusals` is a bounded, NEVER-cleared history
  -- (":YanaRefusals" reads all of it back across every turn a panel has ever run), so
  -- its total count cannot say whether THIS turn refused anything.
  local system_refusals_before_turn = #(p.system_refusals or {})
  -- Writes the confinement itself refused during the turn (EROFS outside the
  -- claimed workspace) become operator-visible refusals here, before any
  -- branch decides what the turn produced: a turn with none carries no rows
  -- and this returns 0 without rendering, logging or recording anything.
  record_confinement_refusals(p, turn)
  if not config.overlay_mode() then
    local preview = require("yana.shadow.preview")
    -- The agent wrote into the overlay's private upper layer. That layer IS the
    -- change set; nothing is folded anywhere first, and nothing is copied.
    -- On success the second return is the report table ({ ops = typed set,
    -- lines = ... }); on failure it is the error string. Named `report` and
    -- read only in the branch where it is the report.
    local rendered, report = preview.render_report(p, turn)
    if not rendered then
      render_error(p, report or "reading the change set failed")
      p.turn_errored = true
      retain_shadow_turn(p, report or "reading the change set failed")
    else
      -- Same durable control-plane record as the apply branch: the report's typed set
      -- carries the control-plane ops the render_report lines disclose only
      -- transiently.
      record_control_plane_refusals(turn, p, report and report.ops)
      -- Preview mode reports and stops: the review is closed the moment the
      -- report is rendered, so the claim goes back now.
      release_shadow_turn(p, "preview report rendered")
    end
  elseif config.review_mode_active() then
    local ops = require("yana.shadow.ops")
    -- The third return is the FULL typed set, including the operations the
    -- review surface cannot represent. It is not decoration: without it, a turn
    -- whose only work was a chmod, a symlink or a directory reaches the `else`
    -- below and is released as "produced no changes", which is a lie about the
    -- private layer and drops the claim on files the agent really did touch.
    local changes, cerr, typed, classification = ops.changes_from_session(turn, {
      tracked_evidence = p.turn_pass and p.turn_pass.tracked_evidence or nil,
    })
    changes, classification = apply_single_file_filter(turn, changes, classification)
    ledger.mark(turn_ledger(p, shadow_turn_gen(turn, p)), "change_set_read")
    -- Recorded on the turn so every hunk header rendered below asks the same,
    -- already-settled question.
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
    -- Durable control-plane record (same helper the preview branch calls).
    -- Counted HERE, before the display branches, so a turn whose ONLY operations
    -- are control-plane -- which lands in the `typed and #typed > 0` branch
    -- below, where the transient panel note is never even reached -- is recorded
    -- too, not just the mixed ordinary-plus-control-plane turn. The returned
    -- count is reused by the transient panel note so both agree.
    local cp_count = record_control_plane_refusals(turn, p, typed)
    -- CORE requires control-plane writes to be walked, COUNTED and REPORTED
    -- ("the turn wrote N control-plane files — discarded with the overlay"),
    -- not silent. `cp_count` is the count the durable helper returned above, so
    -- this transient panel note and the durable WARN agree on the number.
    --
    -- RENDERED HERE, before the display branches, for the same reason the COUNT is
    -- taken here. That was unreachable while every non-control-plane path was either
    -- offered or refused; the ignore list makes it reachable, because a turn whose
    -- every other path is written through has no review to hang the note on.
    if cp_count > 0 then
      S.render_note(p, string.format(
        "⚠ %d control-plane file(s) the turn wrote were recorded and discarded with the overlay (never offered for review)",
        cp_count
      ))
    end
    -- PUBLICATION. The walk is done and every typed operation carries its class, so
    -- this is the moment the turn's bundle becomes authoritative and the review stops
    -- being provisional.
    if p.turn_pass then
      local lifecycle = require("yana.turn_lifecycle")
      local classified = ops.classified_bundle_entries(typed)
      local bundle, berr = lifecycle.publish_bundle(p.turn_pass, classified)
      if not bundle then
        -- An unpublishable bundle leaves the review provisional rather than
        -- quietly actionable: refusing to act is the safe half of this claim.
        log.write(log.levels.WARN, "yana: bundle publication failed: " .. tostring(berr))
      end
    end
    if not changes then
      render_error(p, cerr or "reading the change set failed")
      p.turn_errored = true
      -- The turn's evidence is unreadable, so whether a review is owed is
      -- unknown. The module's rule is never to guess dead: keep the claim and
      -- the private state, and make the operator's way out explicit.
      retain_shadow_turn(p, cerr or "reading the change set failed")
    elseif classification and #classification.unsafe > 0 then
      release_unsafe_turn(p, turn, classification)
    else
      -- BEFORE the review opens and before any refusal is recorded: an ignored
      -- path is not part of the review, and a turn whose ONLY work was ignored
      -- paths must still land them (that turn reaches the `#changes == 0`
      -- branch below and releases).
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
        -- Review is now OPEN. The agent process has exited, but the claim
        -- stays held until the review closes — see on_close below.
        local turn_gen = shadow_turn_gen(turn, p)
        ledger.mark(turn_ledger(p, turn_gen), "apply_pass_began")
        p.shadow_pass = pass
        p.changes = p.changes or {}
        for _, change in ipairs(changes) do
          -- The overlay-derived changes carry no generation of their own, and
          -- every later record about them (hunk model, render check, decision)
          -- correlates through it. The turn id IS the generation.
          change.turn_gen = change.turn_gen or turn_gen
          -- …and the bundle digest it was published under, so a decision can be
          -- checked against the bundle it was actually offered from rather than
          -- against whatever bundle is current when the decision arrives.
          change.bundle_digest = p.turn_pass
            and p.turn_pass.bundle
            and p.turn_pass.bundle.bundle_digest
            or nil
          change.panel_id = change.panel_id or p.id
          ledger.bump(turn_ledger(p, turn_gen), "changes_parsed")
          table.insert(p.changes, change)
          render_tool_change(p, change)
        end
        -- yanad owns the durable review record; publish absolute paths and the
        -- immutable turn-start evidence together.
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
        -- ROW 86 FIX. `changes` empty is reached by TWO different turns: one where
        -- every artifact operation was genuinely system-refused
        -- (`record_artifact_refusals` just above grew `p.system_refusals`), and one
        -- where the agent simply produced nothing at all -- no edits, no artifact
        -- writes, no confinement refusals either. The old unconditional reason named
        -- the first case even for the second, reporting a refusal that never happened.
        local turn_had_refusals = #(p.system_refusals or {}) > system_refusals_before_turn
        local ignored_count = #((classification and classification.ignored) or {})
        local release_reason
        if turn_had_refusals then
          release_reason = "all artifact operations system-refused"
        elseif ignored_count > 0 then
          -- Same lie ROW 86 fixed for refusals, in a new shape: a turn whose
          -- every path was on the operator's ignore list produced real changes
          -- and landed them, so "no_changes" would be false.
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
    -- `ask` (ruling R-3, the mode contract section 2): the turn ran confined
    -- exactly as `inline` does -- overlay_mode() is true for it -- but it
    -- proposes nothing, so no review can open and no change is ever offered.
    --
    -- This branch exists because "overlay ⇒ a review will consume it" stopped
    -- being true the moment confinement stopped implying review. Without it the
    -- turn falls off the end of the chain holding the workspace claim, the
    -- private layer and an unresolved lifecycle pass -- the leak that blocks the
    -- operator's own workspace. `release_shadow_turn` resolves all three.
    --
    -- The layer is read before it is discarded rather than dropped blind: an
    -- `ask` turn that WROTE is exactly the hostile case confinement exists for,
    -- and discarding it in silence would be a fresh instance of the Wall 3
    -- defect. Nothing here is offered, applied, or actionable.
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
      -- A throw or a returned failure is a halt. CORE requires it be recorded
      -- on the object being resolved; discarding the layer in silence is Wall 3
      -- again. Release still follows: an ask turn owes no review, so holding
      -- the claim would lock the workspace with nothing to unlock.
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
    -- Released unconditionally: an unreadable layer is not a reason to keep a
    -- claim on a turn that can owe no review.
    release_shadow_turn(p, "ask turn — nothing is proposed, nothing to review")
  end
end

-- Same provenance pin as `on_event`: the overlay-derived review renders for
-- the turn whose id the overlay carries, which is NOT necessarily the panel's
-- current generation (a stopped turn is finalized after the next one has
-- started). The turn id IS the generation, so every note, change block and
-- error rendered under it is recorded in that turn's ledger.
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
