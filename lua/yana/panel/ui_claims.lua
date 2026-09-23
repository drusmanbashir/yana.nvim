-- Claim-block refresh, out-of-scope/re-edit rejection caps, and shadow-turn
-- claim release/retain -- split out of yana.ui (cluster 5, claims half; see
-- yana.ui_review's header for why this cluster is two files instead of one,
-- the same reasoning session ui-3 used for ui_submit/ui_queue).
--
-- `preview_module`, `release_shadow_turn`, `retain_shadow_turn`, `emit_turn_end`,
-- `refresh_change_block`, and `panel_claimed_workspace` stay as facade locals for
-- not-yet-split clusters.
local config = require("yana.config")
local diff = require("yana.diff")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local control_plane = require("yana.safety.control_plane")
local shadow_apply = require("yana.shadow.apply")
local log = require("yana.log")

local M = {}

-- MODULE SCOPE, not factory scope: `preview_module`, `emit_turn_end` and the two
-- shadow-turn release halves close over nothing the factory supplies -- only
-- `config`, `log` and `require` -- and `finalize_shadow_turn_release` has to be
-- reachable by name on the module, because the caller that defers local release
-- is the Turn, not a panel holding a factory instance. Moved here, not copied.

local function preview_module()
  return require("yana.shadow.preview")
end
-- Row 85: one helper for both turn.end emission sites so the payload cannot
-- fork. Serialises ledger.close_turn's outcome onto the lifecycle line — not a
-- second schema. Vendor claim counts are deliberately absent (raw stream is
-- already teed; they fail the retention tests).
local function emit_turn_end(p, pass, reason, outcome)
  -- Release may run from on_exit_confirmed before on_done stashes the
  -- close_turn outcome. Skip then; on_done emits with the full payload.
  if type(outcome) ~= "table" then
    return
  end
  outcome = outcome or {}
  local gen = (pass and pass.generation) or outcome.generation or (p and p.turn_gen)
  if p then
    p.turn_end_emitted = p.turn_end_emitted or {}
    if gen and p.turn_end_emitted[gen] then
      return true
    end
  end
  local mode = nil
  local backend = nil
  if p and gen and p.turn_modes then
    mode = p.turn_modes[gen]
  end
  if p and gen and p.turn_backends then
    backend = p.turn_backends[gen]
  end
  mode = mode or (p and config.panel_mode(p.mode)) or nil
  backend = backend or (config.options.backend or "cursor")
  log.lifecycle("turn.end", {
    turn_id = pass and pass.turn_id or outcome.turn_id,
    panel = pass and pass.panel or (p and p.id) or outcome.panel,
    generation = gen,
    reason = reason,
    mode = mode,
    backend = backend,
    changes = outcome.changes,
    changes_pending = outcome.changes_pending,
    exit_code = outcome.exit_code,
    got_result = outcome.got_result,
    cancelled = outcome.cancelled,
    turn_errored = outcome.turn_errored,
    session_id = outcome.session_id,
  })
  if p and gen then
    p.turn_end_emitted[gen] = true
  end
  return true
end
-- Close the workspace claim this turn holds, then drop the turn's private
-- state. Every path that finishes or abandons a review funnels through here.
--
-- Agent process exit is deliberately NOT one of those paths: while a review is
-- open the claim outlives the process that created it, which is what stops a
-- following turn from editing files still under review.
--
-- THE SPLIT (design :107). `release_shadow_turn` is the REQUEST half: it asks
-- the daemon to release the claim and reports the ACK. `finalize_shadow_turn_release`
-- is the LOCAL half: it drops local ownership, publishes and discards. A Turn
-- close passes `opts.defer_local_release = true` and gets the receipt back, so
-- local release happens only after the Turn's mandatory cleanup succeeded; a
-- cleanup that refuses after the ACK still has the exact panel, epoch, turn and
-- pass to retry with, and needs no second close and no second file write.
-- Every non-Turn caller omits the flag and finalises inside the ACK, exactly as
-- before.

--- The receipt names the exact panel, epoch, turn and pass this ACK belongs to.
--- `finalized` is on the receipt itself, so finalisation happens ONCE however
--- many times a caller replays it.
local finalize_shadow_turn_release

local function release_receipt(p, reason, turn, pass)
  return {
    panel = p and p.id or nil,
    epoch = p and p.review_epoch or nil,
    turn = turn,
    pass = pass,
    reason = reason,
    p = p,
    finalized = false,
    -- The receipt carries its own finalisation, so the deferring caller needs no
    -- second seam to reach it and cannot pair a receipt with a foreign helper.
    finalize = nil,
  }
end

--- Drop local ownership, publish and discard -- once, and only after the caller
--- that deferred it says the terminal work succeeded. A finalisation that
--- cannot run keeps its receipt: nothing here clears it.
function finalize_shadow_turn_release(receipt)
  if type(receipt) ~= "table" or receipt.finalized then
    return false, "shadow turn release receipt is invalid or already finalized"
  end
  local p, turn, pass, reason = receipt.p, receipt.turn, receipt.pass, receipt.reason
  if not p then
    return false, "shadow turn release receipt names no panel"
  end
  if receipt.panel ~= p.id or receipt.epoch ~= p.review_epoch then
    return false, "shadow turn release receipt does not name the current panel epoch"
  end
  if not rawequal(p.shadow_turn, turn) or not rawequal(p.turn_pass, pass) then
    return false, "shadow turn release receipt does not name the current turn and pass"
  end
  local loaded, preview = pcall(preview_module)
  if not loaded then
    return false, preview
  end
  if pass then
    local published, publish_err = pcall(
      emit_turn_end,
      p,
      pass,
      reason,
      p.turn_end_outcome and p.turn_end_outcome[pass.generation]
    )
    if not published then
      return false, publish_err
    end
  end
  if turn then
    local called, discarded, discard_err = pcall(preview.discard, turn)
    if not called then
      return false, discarded
    end
    if discarded ~= true then
      return false, discard_err or "shadow turn discard refused"
    end
  end
  p.shadow_turn = nil
  p.shadow_pass = nil
  p.turn_pass = nil
  receipt.finalized = true
  return true
end

-- deps.state: the parent's shared state table `S` (S.cancel_inflight read by the
-- rejection-cap helpers below). deps.append / deps.commit_stream: yana.ui_render facade
-- locals. deps.update_winbar: yana.ui_winbar facade local.
M.finalize_shadow_turn_release = finalize_shadow_turn_release

function M.new(deps)
  local S = deps.state
  local append = deps.append
  local commit_stream = deps.commit_stream
  local update_winbar = deps.update_winbar
  local buf_valid = deps.buf_valid
  local start_spinner = deps.start_spinner
  local stop_spinner = deps.stop_spinner

-- ANNOUNCING THE GATED ACCEPT.
--
-- CORE licenses that wait on the ACTION and names a spinner as the remedy; until now
-- `start_spinner` was called only from the submit path, so the operator got an
-- unannounced freeze at the exact moment they pressed accept -- indistinguishable from
-- a hang.
--
-- WHAT THIS CAN AND CANNOT DO, stated here rather than implied. The frame is painted
-- BEFORE the first fsync, and `redraw` forces that paint out to the terminal, because
-- setting 'winbar' only marks the window dirty and Neovim would otherwise repaint after
-- the stall -- i.e. after the thing the notice exists to announce.
--
-- ONE OPERATION, ONE INDICATION. The same property is what clears it on EVERY exit: the
-- clear is queued before the durable work is entered, so a refusal, a `return false` or
-- a THROW out of the applier all leave it queued. A THROW IS A HALT (CORE), and a
-- spinner that outlives its operation is a lie about state.
local function begin_accept_indication(p)
  if not p or p.applying then
    return
  end
  p.applying = true
  -- Reuse the submit path's timer rather than adding a second one. When the
  -- panel is already busy its timer is running and owns the frame; restarting
  -- it here would reset a live turn's animation for nothing.
  if not p.busy then
    start_spinner(p)
  end
  update_winbar(p)
  pcall(vim.cmd, "redraw")
  vim.schedule(function()
    log.guard("yana.ui accept indication clear", function()
      p.applying = nil
      -- Only the accept's own spinner stops here. A turn still in flight owns
      -- the timer and must keep it.
      if not p.busy then
        stop_spinner(p)
      end
      update_winbar(p)
    end)
  end)
end
local function change_footer_text(change, _k)
  if change.status == "pending" then
    local maps = config.options.mappings
    return string.format(
      "Review changes in file buffer: Reject hunk `%s` · Accept hunk `%s` · Accept file `%s` · Accept all `%s` · Reject file `%s`",
      maps.reject_hunk,
      maps.accept_hunk,
      maps.accept_file,
      maps.accept_all,
      maps.reject_file
    )
  end
  if change.status == "accepted" then
    return "Accepted · agent edit kept"
  end
  if change.status == "kept_unreviewed" then
    return "_kept unreviewed — agent edit kept, no consent recorded_"
  end
  if change.status == "system_refused" then
    return "_system refused — "
      .. notify.flatten(change.review_error or "real file unchanged; proposal was not reviewable")
      .. "_"
  end
  return "Rejected · file restored to pre-edit content"
end

local function conv_base_line(p)
  local n = vim.api.nvim_buf_line_count(p.conv_buf)
  if n == 1 and vim.api.nvim_buf_get_lines(p.conv_buf, 0, 1, false)[1] == "" then
    return 0
  end
  return n
end

local function change_header_text(change, counts)
  local badge = change.undeclared and " · undeclared" or ""
  return "**"
    .. diff.status_icon(change)
    .. " "
    .. diff.kind_verb(change)
    .. " `"
    .. notify.flatten(change.rel)
    .. "`** "
    .. counts
    .. badge
end

local function stamp_undeclared_badge(p, change)
  if change.undeclared ~= nil then
    return
  end
  change.undeclared = require("yana.turn.turn_lifecycle").is_undeclared_tracked(p.turn_pass, change.rel)
end

-- The change's block is addressed by ABSOLUTE line numbers stamped when it was rendered
-- (conv_header_line/conv_footer_line). Anything that shortens or replaces the
-- conversation after that — `new_chat`, a session resume — leaves those numbers
-- pointing past the end of the buffer, and nvim_buf_set_lines THROWS on an out-of-range
-- index. Clamp instead: a stale stamp means the block this change belonged to is gone,
-- so there is nothing to refresh and silently doing nothing is correct.
local function refresh_change_block(p, change)
  if not buf_valid(p.conv_buf) or not change.conv_header_line then
    return
  end
  local total = vim.api.nvim_buf_line_count(p.conv_buf)
  if change.conv_header_line < 1 or change.conv_header_line > total then
    return
  end
  local k = config.options.mappings
  local counts = string.format("(+%s −%s)", change.added or "?", change.removed or "?")
  local header = change_header_text(change, counts)
  vim.bo[p.conv_buf].modifiable = true
  -- pcall + unconditional restore, matching refresh_review_claim: a throw
  -- between these lines left the conversation buffer permanently editable and
  -- skipped the rest of on_accept (claim sweep, winbar).
  pcall(function()
    vim.api.nvim_buf_set_lines(p.conv_buf, change.conv_header_line - 1, change.conv_header_line, false, { header })
    if change.conv_footer_line and change.conv_footer_line >= 1 and change.conv_footer_line <= total then
      vim.api.nvim_buf_set_lines(
        p.conv_buf,
        change.conv_footer_line - 1,
        change.conv_footer_line,
        false,
        { change_footer_text(change, k) }
      )
    end
  end)
  vim.bo[p.conv_buf].modifiable = false
end

local function reload_after_scope_revert(change)
  local path = change.path
  if not path or path == "" then
    return true
  end
  local bufnr = vim.fn.bufnr(path)
  if bufnr <= 0 or not vim.api.nvim_buf_is_loaded(bufnr) then
    return true
  end
  if not vim.bo[bufnr].modified then
    return diff.reload_file(path)
  end
  local buf_text = diff.buffer_text_normalized(bufnr)
  if diff.text_equal_snapshot(buf_text, change.before or "") then
    return diff.reload_file(path, { force = true })
  end
  return false, "buffer has divergent edits; not reloaded"
end

local function scope_rejection_cap_note(p, change, reason)
  local scope = change.scope
  local zone = scope
    and string.format("L%d–L%d (%s)", scope.zone_l1, scope.zone_l2, scope.node_kind or "zone")
    or "selection zone"
  local wanted = reason or "edit outside selection scope"
  append(p, {
    "",
    "**⏹ stopped — repeated out-of-zone edits**",
    "",
    "> Enforced zone: " .. zone,
    "> Agent wanted: " .. wanted,
    "",
    "_Widen or clear the visual selection and re-ask, or set `selection_scope.enforce = \"warn\"` in yana config to keep out-of-zone hunks reviewable._",
    "",
  })
end

local function bump_scope_rejection(p, change, reason)
  local path = vim.fs.normalize(diff.abs_path(change.path))
  p.scope_rejections[path] = (p.scope_rejections[path] or 0) + 1
  local cap = config.options.selection_scope.rejection_cap
  if p.scope_rejections[path] >= cap and p.busy then
    S.cancel_inflight(p)
    scope_rejection_cap_note(p, change, reason)
  end
end

local function review_rejection_cap_note(p, change)
  append(p, {
    "",
    "**⏹ stopped — repeated re-edits after rejection**",
    "",
    "> File: " .. (change.rel or change.path or "?"),
    "",
    "_The agent kept re-applying hunks you rejected in `"
      .. (change.rel or change.path or "?")
      .. "`; the turn was stopped._",
    "",
  })
end

-- Mirrors bump_scope_rejection but for inline-review rejections: a
-- still-running agent can re-read disk after a reject and re-apply the same
-- hunk, the same loop the selection-scope path already caps. Keyed
-- separately from p.scope_rejections since these are unrelated counters.
local function bump_review_rejection(p, change)
  local path = vim.fs.normalize(diff.abs_path(change.path))
  p.review_rejections[path] = (p.review_rejections[path] or 0) + 1
  local cap = config.options.selection_scope.rejection_cap
  if p.review_rejections[path] >= cap and p.busy then
    S.cancel_inflight(p)
    review_rejection_cap_note(p, change)
  end
end

local function render_scope_rejection(p, change, reason)
  commit_stream(p)
  p.rendered_any = true

  -- change.rel can be nil (e.g. changes synthesized without a workspace-
  -- relative path); every message below must fall back like the rest of
  -- this file does, or a nil concat crashes this scheduled handler.
  local label = change.rel or change.path or "?"

  local disk_text = diff.read_file_text(change.path)
  if disk_text == nil or not diff.text_equal_snapshot(disk_text, change.after or "") then
    append(p, {
      "",
      "**⚠ could not revert `" .. label .. "`** (disk changed since agent edit)",
      "",
      "> " .. (reason or "edit outside selection zone"),
      "> Preserving on-disk content; change left pending.",
      "",
    })
    notify_one_line(
      "yana: disk diverged for " .. label .. "; not reverting",
      vim.log.levels.WARN
    )
    bump_scope_rejection(p, change, reason)
    return
  end

  if change.before == nil then
    append(p, {
      "",
      "**⚠ could not revert `" .. label .. "`** (no pre-edit snapshot)",
      "",
      "> " .. (reason or "edit outside selection zone"),
      "> No before-content was captured for this edit; leaving it pending.",
      "",
    })
    notify_one_line(
      "yana: no pre-edit snapshot for " .. label .. "; not reverting",
      vim.log.levels.WARN
    )
    bump_scope_rejection(p, change, reason)
    return
  end

  if control_plane.is_control_plane(diff.abs_path_literal(change.path or "")) then
    -- Legacy scope-revert is a direct real-tree write; the matcher guards it too
    -- A control-plane path is never written back.
    notify_one_line(
      "yana: refused to revert control-plane path " .. tostring(change.path),
      vim.log.levels.WARN
    )
    return
  end
  local ok, werr = shadow_apply.scope_revert(p, change)
  if not ok then
    append(p, {
      "",
      "**⚠ could not revert `" .. label .. "`** (outside selection scope)",
      "",
      "> " .. (reason or "edit outside selection zone"),
      "> Revert failed: " .. tostring(werr),
      "",
    })
    notify_one_line(
      "yana: could not revert " .. label .. ": " .. tostring(werr),
      vim.log.levels.WARN
    )
    bump_scope_rejection(p, change, reason)
    return
  end
  local rok, rerr = reload_after_scope_revert(change)
  if not rok then
    append(p, {
      "",
      "**⚠ reverted `" .. label .. "` on disk but buffer not reloaded**",
      "",
      "> " .. (reason or "edit outside selection zone"),
      "> " .. tostring(rerr),
      "",
    })
    notify_one_line("yana: " .. tostring(rerr), vim.log.levels.WARN)
  end
  change.status = "rejected"
  append(p, {
    "",
    "**✗ rejected `" .. label .. "`** (outside selection scope)",
    "",
    "> " .. (reason or "edit outside selection zone"),
    "",
  })
  notify_one_line("yana: " .. (reason or "edit outside selection zone"), vim.log.levels.WARN)
  bump_scope_rejection(p, change, reason)
end
local function panel_claimed_workspace(p)
  if not p then
    return require("yana.diff").abs_path(vim.fn.getcwd())
  end
  if p.shadow_turn and p.shadow_turn.workspace and p.shadow_turn.workspace ~= "" then
    return require("yana.diff").abs_path(p.shadow_turn.workspace)
  end
  local preview = require("yana.shadow.preview")
  return preview.workspace_for_turn({
    cwd = p.cwd or vim.fn.getcwd(),
  })
end
-- Shared on_accept/on_reject pair for an inline review of `change`. Used by
-- render_tool_change's first-time inline.enqueue AND by the accept_change/
-- reject_change retry path below, so a retried review behaves identically to the
-- original one instead of duplicating this callback pair. Rewrite one change's claim
-- line from what the review engine ACTUALLY did.
local function refresh_review_claim(p, change)
  if not buf_valid(p.conv_buf) or not change.conv_claim_line then
    return
  end
  local total = vim.api.nvim_buf_line_count(p.conv_buf)
  if change.conv_claim_line < 1 or change.conv_claim_line > total then
    return
  end
  local inline = require("yana.inline_diff")
  local ws_opts = change.review_workspace and { workspace = change.review_workspace }
    or { workspace = panel_claimed_workspace(p) }
  local text
  if change.review_error then
    -- FLATTENED, and this is not cosmetic. review_error routinely carries a multi-line
    -- value: a failed save stamps the full nvim_exec2 error including its stack
    -- traceback. nvim_buf_set_lines REJECTS any item containing a newline, so the raw
    -- string throws inside this repaint -- which the observer's pcall swallows, so
    -- claim lines just silently stop updating from that moment on (and the sweep below
    -- aborts, taking every later change with it).
    text = "_Review refused: "
      .. notify.one_line_text(change.review_error, math.max(16, (vim.o.columns - 1) * 2))
      .. " — this review changed nothing._"
  elseif change.status == "superseded" then
    text = "_Merged into the review for this file._"
  elseif change.status == "accepted"
    or change.status == "rejected"
    or change.status == "kept_unreviewed"
    or change.status == "system_refused"
  then
    text = "_Resolved (" .. change.status .. ")._"
  elseif change.batched then
    -- Not queued and not open: waiting for the turn to end.
    local merged = change.merged_count or 1
    text = merged > 1 and string.format("_Review opens when the turn ends (%d edits merged)._", merged)
      or "_Review opens when the turn ends._"
  elseif inline.active_change(ws_opts) == change then
    text = "_Hunks open in the source file — switch to that window._"
  else
    -- Ask the engine for THIS change's position; pending_count()-1 gave every
    -- queued change the same figure and counted items queued behind it.
    local ahead = inline.queue_wait(change, ws_opts) or math.max(0, inline.pending_count(ws_opts) - 1)
    text = ahead > 0 and string.format("_Queued behind %d review(s) — no hunks in this file yet._", ahead)
      or "_Queued — no hunks in this file yet._"
  end
  vim.bo[p.conv_buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, p.conv_buf, change.conv_claim_line - 1, change.conv_claim_line, false, { text })
  vim.bo[p.conv_buf].modifiable = false
end

local function release_shadow_turn(p, reason, on_released, opts)
  local turn = p.shadow_turn
  local pass = p.turn_pass
  local defer = type(opts) == "table" and opts.defer_local_release == true
  -- Stash the caller reason per generation so on_done's later turn.end emit
  -- (when this call skips because turn_end_outcome is not yet set — the
  -- on_exit_confirmed → finalize path) carries THIS reason, never a
  -- hard-coded "process exited". Refusal / empty / ask reasons must win.
  if p and pass and pass.generation ~= nil then
    p.turn_end_reasons = p.turn_end_reasons or {}
    p.turn_end_reasons[tostring(pass.generation)] = reason
  end
  if not turn then
    if pass then
      require("yana.turn.turn_lifecycle").finish_turn(pass)
      emit_turn_end(p, pass, reason, p.turn_end_outcome and p.turn_end_outcome[pass.generation])
      p.turn_pass = nil
    end
    if on_released then on_released(true) end
    return true
  end
  local receipt = release_receipt(p, reason, turn, pass)
  receipt.finalize = finalize_shadow_turn_release
  local preview = preview_module()
  return preview.release(turn, function(ok, err)
    if not ok then
      log.write(
        log.levels.WARN,
        string.format(
          "yana: releasing the workspace claim failed (%s): %s",
          reason or "review closed",
          tostring(err)
        )
      )
      if on_released then on_released(false, err, receipt) end
      return
    end

    -- The ACK is the ownership boundary. A deferring caller owns the boundary
    -- from here; everyone else crosses it now.
    if not defer then
      local finalized, finalize_err = finalize_shadow_turn_release(receipt)
      if not finalized then
        if on_released then on_released(false, finalize_err, receipt) end
        return
      end
    end
    if on_released then on_released(true, nil, receipt) end
  end)
end
-- A turn whose evidence could not be read leaves its private state intact.
-- Whether a review is owed is unknown; the operator inspects it through
-- recovery and resolves it with :YanaRecover or :YanaAbortReview.
local function retain_shadow_turn(p, reason)
  local turn = p.shadow_turn
  if not turn then
    return
  end
  notify_one_line(
    string.format(
      "yana: %s still has unresolved turn state (%s) — inspect yanad status, then abort or delete the named session",
      turn.workspace,
      reason or "turn state unresolved"
    ),
    vim.log.levels.WARN
  )
end

  return {
    begin_accept_indication = begin_accept_indication,
    change_footer_text = change_footer_text,
    conv_base_line = conv_base_line,
    change_header_text = change_header_text,
    stamp_undeclared_badge = stamp_undeclared_badge,
    refresh_change_block = refresh_change_block,
    reload_after_scope_revert = reload_after_scope_revert,
    scope_rejection_cap_note = scope_rejection_cap_note,
    bump_scope_rejection = bump_scope_rejection,
    review_rejection_cap_note = review_rejection_cap_note,
    bump_review_rejection = bump_review_rejection,
    render_scope_rejection = render_scope_rejection,
    panel_claimed_workspace = panel_claimed_workspace,
    refresh_review_claim = refresh_review_claim,
    preview_module = preview_module,
    emit_turn_end = emit_turn_end,
    release_shadow_turn = release_shadow_turn,
    finalize_shadow_turn_release = finalize_shadow_turn_release,
    retain_shadow_turn = retain_shadow_turn,
  }
end

return M
