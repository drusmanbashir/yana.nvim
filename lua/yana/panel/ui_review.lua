-- Turn-batched review lifecycle: opts, coalesce, flush, drop, render. Split out
-- of yana.ui alongside yana.ui_claims and yana.ui_changes.
local config = require("yana.config")
local diff = require("yana.diff")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local ledger = require("yana.ledger")
local shadow_apply = require("yana.shadow.apply")
local log = require("yana.log")

local M = {}

-- deps: the parent's shared state table plus the ui_render / ui_winbar /
-- ui_claims facade locals of the same names.
function M.new(deps)
  local S = deps.state
  local append = deps.append
  local commit_stream = deps.commit_stream
  local turn_ledger = deps.turn_ledger
  local update_winbar = deps.update_winbar
  local current_panel = deps.current_panel
  local panel_claimed_workspace = deps.panel_claimed_workspace
  local refresh_change_block = deps.refresh_change_block
  local refresh_review_claim = deps.refresh_review_claim
  local release_shadow_turn = deps.release_shadow_turn
  local preview_module = deps.preview_module
  local begin_accept_indication = deps.begin_accept_indication
  local change_header_text = deps.change_header_text
  local change_footer_text = deps.change_footer_text
  local conv_base_line = deps.conv_base_line
  local stamp_undeclared_badge = deps.stamp_undeclared_badge
  local bump_review_rejection = deps.bump_review_rejection

-- Queue advances when a review resolves; sweep header glyph, claim line and footer together, since a transition
-- the panel did not drive (retrace reopen) fires no decision callback.
local function refresh_all_review_claims(p)
  for _, c in ipairs(p.changes or {}) do
    refresh_change_block(p, c)
    refresh_review_claim(p, c)
  end
end

local MAX_REVIEW_RETRY = 5
local REVIEW_RETRY_EXHAUSTED = "retry_exhausted"

local function inline_review_opts(p, change)
  local apply_mode = config.review_mode_active()
  local journaled = config.overlay_mode()
  local ws = (change and change.review_workspace) or panel_claimed_workspace(p)
  local turn = p.shadow_turn or (p.shadow_pass and p.shadow_pass.shadow_turn)
  return {
    workspace = ws,
    review_tabs = not (config.options.review and config.options.review.tabs == false),
    review_tabs_state_path = nil,
    review_paths = p.shadow_pass and p.shadow_pass.paths or nil,
    review_owner = { panel_id = p.id, epoch = p.review_epoch },
    review_turn = turn,
    turn_pass = p.turn_pass,
    -- A daemon restart can remint the panel session while an earlier review still owns the file; decisions belong
    -- to that review's holder identity, not the new panel identity.
    yanad_session_id = (turn and turn.yanad_session_id) or p.yanad_session_id or nil,
    session_id = (turn and (turn.yanad_session_id or turn.session_id)) or p.yanad_session_id or p.session_id or nil,
    -- Journaled route, not apply-only: a preview accept is journaled too.
    shadow_apply = journaled,
    -- Two guards: actionability makes an accept wait for the classified bundle; the owner tuple is captured at build
    -- time so one turn's callback cannot bind the next turn's change. No lifecycle pass: log, do not pass.
    on_shadow_accept = journaled and (function()
      local lifecycle = require("yana.turn.turn_lifecycle")
      local owner = p.turn_pass
      local accept = function(c, composed, opts)
        local panel = p
        if not panel then
          return false, "no panel"
        end
        -- Before the first fsync: every branch does durable I/O, so announce at the top of the funnel.
        begin_accept_indication(panel)
        if owner then
          local allowed, why = lifecycle.action_allowed(owner, c and (c.rel or c.path))
          if not allowed then
            return false, why
          end
        else
          log.write(
            log.levels.WARN,
            "yana: shadow accept ran with no turn lifecycle pass — actionability was not checked"
          )
        end
        -- One applier for finish_session and Turn settle (F8).
        if panel.shadow_pass then
          return shadow_apply.accept_composed(panel.shadow_pass, c, composed, opts)
        end
        return shadow_apply.accept_standalone(panel, c, composed, opts)
      end
      return owner and lifecycle.bind_callback(owner, "shadow accept", accept) or accept
    end)() or nil,
    -- `U` undoes the whole turn; an already-accepted file is put back by a journaled write.
    on_shadow_revert = journaled and function(c)
      local panel = current_panel()
      if not panel then
        return false, "no panel"
      end
      return shadow_apply.revert_to_turn_start(panel, c)
    end or nil,
    on_shadow_revert_bytes = journaled and function(c, content)
      local panel = current_panel()
      if not panel then
        return false, "no panel"
      end
      return shadow_apply.revert_to_bytes(panel, c, content)
    end or nil,
    on_accept = function(c)
      refresh_change_block(p, c)
      refresh_all_review_claims(p)
      update_winbar(p)
      notify_one_line("yana: accepted " .. c.rel, vim.log.levels.INFO)
    end,
    on_kept_unreviewed = function(c)
      refresh_change_block(p, c)
      refresh_all_review_claims(p)
      update_winbar(p)
    end,
    on_system_refused = function(c)
      if c.shadow_apply and p.shadow_turn then
        preview_module().retain_system_refused(p.shadow_turn, c)
        ledger.attach_refusal(turn_ledger(p, c.turn_gen), {
          retention_strength = c.retention_strength,
          retained_path = c.retained_path,
          retention_error = c.retention_error,
        })
      end
      refresh_change_block(p, c)
      refresh_all_review_claims(p)
      update_winbar(p)
    end,
    on_reject = function(c)
      refresh_change_block(p, c)
      refresh_all_review_claims(p)
      update_winbar(p)
      notify_one_line("yana: rejected " .. c.rel .. " (reverted)", vim.log.levels.INFO)
      bump_review_rejection(p, c)
    end,
    on_close = function(_state, _accepted, on_closed)
      if not apply_mode then
        if on_closed then on_closed(true) end
        return true
      end
      -- Authority is `turn_undecided_hunks`: close means zero undecided hunks.
      -- Never latch: every >0-to-0 edge must fire again.
      local inline_ok, inline = pcall(require, "yana.inline_diff")
      if not inline_ok then
        if on_closed then on_closed(false, "inline_diff_unavailable") end
        return false
      end
      local pending = inline.turn_undecided_hunks({
        changes = p.changes or {},
        opts = (_state and _state.opts) or inline_review_opts(p),
      })
      -- A decision edge may close only at zero. A whole-Turn End (close_cause, written by turn_bind alone) already
      -- passed the End dialog and settlement, so testing pending would veto a decision already taken and leave the
      -- Turn live (F-TRL03-03). The zero test guards only the non-Turn doors.
      local close_cause = _state and _state.close_cause
      if pending ~= 0 and close_cause == nil then
        if on_closed then on_closed(false, "review_still_pending") end
        return false
      end
      -- The daemon's review_close ACK is the durable boundary; tabs, preview evidence and the next queue item stay
      -- owned until Turn cleanup succeeds and the receipt is finalised.
      release_shadow_turn(p, "review closed", function(ok, err, receipt)
        -- Defer until every owner callback returned and turn_bind completed the aggregate turn_end; draining in
        -- the first owner callback can attach the next owner to a still-closing Turn.
        local function drain()
          if not (_state and _state._redo_hold_active) then
            vim.schedule(function() S.maybe_drain_queue(p) end)
          end
        end
        -- REGISTER BEFORE ANSWERING. `on_closed` hands the ACK to the Turn, and
        -- the Turn may run cleanup and publish `gone` inside that very call --
        -- so anything registered afterwards is registered against a Turn that
        -- has already finished. The old code registered a `turn_end` listener
        -- here, one line too late to ever fire, and a listener has no answer
        -- the Turn reads anyway.
        if ok and receipt ~= nil then
          local bound = require("yana.turn.turn_bind").get(p)
          if bound ~= nil then
            -- Keyed per receipt, so several file owners are each tracked and
            -- each finalised exactly once. The refusal is REAL: it keeps the
            -- Turn live with this release still owed.
            bound:require_cleanup(receipt, function()
              local finalized, reason = receipt.finalize(receipt)
              if finalized == false then
                return false, reason or "panel receipt finalization refused"
              end
              refresh_all_review_claims(p)
              drain()
              return true
            end)
          end
        end
        if on_closed then on_closed(ok, err) end
        if not ok then
          return
        end
        -- A Turn close defers local finalisation to the receipt: ownership drops only once the Turn published, so a
        -- refusing cleanup keeps panel/epoch/turn/pass to retry with. Non-Turn callers finalise in the request helper.
        if receipt == nil then
          drain()
          return
        end
        -- A Turn took the receipt as required cleanup above. Without one, the
        -- non-Turn path finalises here exactly as it always has.
        if require("yana.turn.turn_bind").get(p) == nil then
          receipt.finalize(receipt)
          refresh_all_review_claims(p)
          drain()
        end
      end, { defer_local_release = true })
      return "pending"
    end,
  }
end

-- Fold a later change to the same path into the turn's owning change. `before`
-- stays the first edit's; `after` becomes the last, which is what disk holds.
local function coalesce_into_owner(owner, change)
  -- Merge kind: edit-then-delete must not stay kind=modify (open_review_buffer would write "" over the deleted file).
  if change.kind == "delete" then
    owner.kind = "delete"
    owner.after = nil
    if owner.before == nil then
      -- Created and deleted inside one turn: nothing to review.
      owner.net_noop = true
    end
  else
    owner.after = change.after
    owner.net_noop = nil
    owner.kind = (owner.before == nil) and "create" or "modify"
  end
  owner.diff = diff.synthesize_diff(owner.before or "", owner.after or "", owner.path)
  local added, removed = diff.count_stats(owner.diff)
  owner.added, owner.removed = added, removed
  owner.merged_count = (owner.merged_count or 1) + 1
  change.status = "superseded"
  change.superseded_by = owner.id
  change.batched = false
end

-- Enqueue everything the turn wrote, in write order. Idempotent and gen-independent: called from on_exit_confirmed
-- (every job death) and on_done (sole path for a spawn failure).
local function flush_review_batch(p)
  local batch = p.review_batch
  p.review_batch = {}
  p.review_batch_by_path = {}
  if not batch or #batch == 0 then
    return 0
  end
  local inline = require("yana.inline_diff")
  local opts = inline_review_opts(p)

  do
    local queued_hunks = require("yana.review_queued_hunks")
    local turn_bind = require("yana.turn.turn_bind")
    -- inline.build_diff_blocks is a facade field; model_target/absorb_review_blocks_over_drift are plain locals in
    -- inline_diff, so they are required directly.
    local materialize_deps = {
      facade = inline,
      diff = diff,
      model_target = require("yana.review_model").model_target,
      absorb_review_blocks_over_drift = require("yana.review_ownership").absorb_review_blocks_over_drift,
    }
    local intake_files = {}
    for _, owner in ipairs(batch) do
      if owner.status == "pending" then
		local L, composed = queued_hunks.materialize(materialize_deps, owner)
		if L then
		  intake_files[#intake_files + 1] = {
			path = diff.abs_path(owner.path),
			ledger = L,
			base_text = (owner.review_before ~= nil and owner.review_before or owner.before) or "",
			overlay_text = composed,
			change = owner,
          }
        end
      end
    end
    if #intake_files > 0 then
      -- `pool` (first arg) is ignored by turn_bind (one singleton Turn per session); nil matches observe_open.
      turn_bind.bind(nil, intake_files, {
        opts_fn = function()
          return config.options
        end,
        -- Intake usually creates the Turn, so these hooks own its cleanup; resolve each member's pool from its
        -- stamped workspace, else this panel's.
        queue_pool_for = function(file)
          return inline._pool_for(inline_review_opts(p, file and file.change))
        end,
      })
    end
  end

  local n = 0
  for _, owner in ipairs(batch) do
    inline.unmark_batched(owner.path, opts)
    owner.batched = false
    if owner.review_epoch ~= nil and owner.review_epoch ~= p.review_epoch then
      goto continue_flush
    end
    if owner.status == "pending" then
      if owner.net_noop then
        owner.status = "kept_unreviewed"
      else
        n = n + 1
        ledger.bump(turn_ledger(p, owner.turn_gen), "reviews_enqueued")
        inline.enqueue(owner, opts)
      end
    end
    ::continue_flush::
    refresh_review_claim(p, owner)
    refresh_change_block(p, owner)
  end
  update_winbar(p)
  return n
end

-- new_chat only, not panel close: there is no panel-destroy lifecycle, inline
-- reviews open in the source buffers, and a turn finishing behind a closed panel
-- reviews fine. Dropping on window close would discard reviewable edits.
local function drop_review_batch(p)
  local inline = require("yana.inline_diff")
  local opts = inline_review_opts(p)
  for _, owner in ipairs(p.review_batch or {}) do
    inline.unmark_batched(owner.path, opts)
    owner.batched = false
    if owner.status == "pending" then
      owner.status = "kept_unreviewed"
    end
  end
  p.review_batch = {}
  p.review_batch_by_path = {}
end

local function render_tool_change(p, change)
  commit_stream(p)
  p.rendered_any = true
  local k = config.options.mappings
  stamp_undeclared_badge(p, change)
  local review_before = change.review_before ~= nil and change.review_before or change.before
  if (not change.diff or change.diff == "") and review_before and change.after then
    change.diff = diff.synthesize_diff(review_before, change.after, change.path)
    local added, removed = diff.count_stats(change.diff)
    change.added = change.added or added
    change.removed = change.removed or removed
  end
  local counts = string.format("(+%s −%s)", change.added or "?", change.removed or "?")
  local header = change_header_text(change, counts)
  do
    -- Name the root only when the turn touched several repos (repo_count is computed once from the finished walk).
    local turn = p.shadow_turn
    local multi = type(turn) == "table"
      and ((type(turn.roots) == "table" and #turn.roots > 1) or (turn.repo_count or 1) > 1)
    if multi and type(change.root) == "string" and change.root ~= "" then
      header = header .. " _in_ `" .. notify.flatten(vim.fn.fnamemodify(change.root, ":~")) .. "`"
    end
  end
  local block = { "", header, "" }
  local claim_index = nil
  do
    -- Observed, not asserted: only one review is open at a time; refresh_review_claim overwrites this placeholder.
    claim_index = #block + 1
    table.insert(block, "_Review opens when the turn ends._")
  end
  table.insert(block, change_footer_text(change, k))
  table.insert(block, "")
  local base = conv_base_line(p)
  append(p, block, "tool_change")
  change.conv_header_line = base + 2
  change.conv_footer_line = base + #block - 1
  change.conv_claim_line = claim_index and (base + claim_index) or nil
  p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
  do
    -- Not enqueued here. Batch instead, and flush when the process is dead.
    local inline = require("yana.inline_diff")
    p.review_batch = p.review_batch or {}
    p.review_batch_by_path = p.review_batch_by_path or {}
    local owner = p.review_batch_by_path[change.path]
    if owner then
      ledger.bump(turn_ledger(p, change.turn_gen), "changes_coalesced")
      coalesce_into_owner(owner, change)
    else
      ledger.bump(turn_ledger(p, change.turn_gen), "changes_batched")
      change.batched = true
      change.merged_count = 1
      change.review_epoch = p.review_epoch
      p.review_batch_by_path[change.path] = change
      table.insert(p.review_batch, change)
      inline.mark_batched(change.path, inline_review_opts(p))
    end
    vim.schedule(function()
      log.guard("yana.ui review batch refresh", function()
        refresh_review_claim(p, change)
        if owner then
          refresh_review_claim(p, owner)
          refresh_change_block(p, owner)
        end
      end)
    end)
  end
end

  return {
    refresh_all_review_claims = refresh_all_review_claims,
    MAX_REVIEW_RETRY = MAX_REVIEW_RETRY,
    REVIEW_RETRY_EXHAUSTED = REVIEW_RETRY_EXHAUSTED,
    inline_review_opts = inline_review_opts,
    coalesce_into_owner = coalesce_into_owner,
    flush_review_batch = flush_review_batch,
    drop_review_batch = drop_review_batch,
    render_tool_change = render_tool_change,
  }
end

return M
