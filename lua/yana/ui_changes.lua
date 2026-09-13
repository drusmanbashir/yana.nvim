-- Accept/reject/show commands for pending changes -- split out of yana.ui (cluster 5,
-- the third of three files this cluster needed; see yana.ui_review's header for why).
-- `M.show_changes`, `M.accept_change`, `M.reject_change`, `M.accept_changes`,
-- `M.reject_changes`, `M.review_changes` moved here verbatim (as plain locals,
-- re-exported by ui.lua under their original `M.*` names so no call site changes);
-- `M.accept_changes`/`M.reject_changes`'s internal calls to
local diff = require("yana.diff")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local ledger = require("yana.ledger")

local M = {}

-- deps.current_panel: parent-local panel bookkeeping (module-level, not reassigned).
-- deps.update_winbar: yana.ui_winbar facade local. deps.turn_ledger: yana.ui_render
-- facade local.
function M.new(deps)
  local current_panel = deps.current_panel
  local update_winbar = deps.update_winbar
  local turn_ledger = deps.turn_ledger
  local refresh_change_block = deps.refresh_change_block
  local panel_claimed_workspace = deps.panel_claimed_workspace
  local inline_review_opts = deps.inline_review_opts
  local MAX_REVIEW_RETRY = deps.MAX_REVIEW_RETRY
  local REVIEW_RETRY_EXHAUSTED = deps.REVIEW_RETRY_EXHAUSTED

-- View the file changes the agent made this session as a side-by-side diff.
local function show_changes()
  local p = current_panel()
  if not p or #p.changes == 0 then
    notify_one_line("yana: no file changes this session", vim.log.levels.INFO)
    return
  end
  if #p.changes == 1 then
    diff.show(p.changes[1])
    return
  end
  vim.ui.select(p.changes, {
    prompt = "yana: view change",
    format_item = function(c)
      return string.format("%s %s  (+%s −%s)", diff.status_icon(c), c.rel, c.added or "?", c.removed or "?")
    end,
  }, function(choice)
    if choice then
      diff.show(choice)
    end
  end)
end

local function pick_pending(prompt, cb)
  local p = current_panel()
  local pending = p and diff.pending(p.changes) or {}
  if #pending == 0 then
    notify_one_line("yana: no pending changes to review", vim.log.levels.INFO)
    return
  end
  if #pending == 1 then
    cb(pending[1])
    return
  end
  vim.ui.select(pending, {
    prompt = prompt,
    format_item = function(c)
      return string.format("%s %s  (+%s −%s)", diff.status_icon(c), c.rel, c.added or "?", c.removed or "?")
    end,
  }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

local function retry_refused_review(p, change)
  local inline = require("yana.inline_diff")
  if change.review_error == REVIEW_RETRY_EXHAUSTED and (change.review_retry_count or 0) > MAX_REVIEW_RETRY then
    change.review_error = nil
    change.review_retry_count = 0
    notify_one_line(
      "yana: review retry counter reset for " .. (change.rel or change.path),
      vim.log.levels.INFO
    )
  end
  local prior_err = change.review_error
  local prior_count = change.review_retry_count or 0
  local outcome = inline.enqueue(change, inline_review_opts(p, change))
  -- inserted / already_queued: not an open attempt. Restore count and error
  -- so a blocked click cannot manufacture retry_exhausted (enqueue clears
  -- review_error on first insert).
  if outcome ~= "opened" then
    if prior_err then
      local tries = prior_count + 1
      change.review_retry_count = tries
      if tries >= MAX_REVIEW_RETRY then
        change.review_error = REVIEW_RETRY_EXHAUSTED
        notify_one_line(
          "yana: review retries exhausted for " .. (change.rel or change.path)
            .. " — last refusal: " .. tostring(prior_err),
          vim.log.levels.WARN
        )
      else
        change.review_error = prior_err
        notify_one_line(
          "yana: retrying review for " .. (change.rel or change.path)
            .. " (" .. tostring(tries) .. "/" .. tostring(MAX_REVIEW_RETRY) .. ")"
            .. " — was refused: " .. tostring(prior_err),
          vim.log.levels.INFO
        )
      end
    else
      change.review_error = prior_err
      change.review_retry_count = prior_count
    end
    return false
  end
  local tries = prior_count + 1
  change.review_retry_count = tries
  local attempt_err = change.review_error
  -- Its own class, not a user decision and not a refusal: this is Yana
  -- re-attempting a review that was refused, and the corpus showed retry
  -- rounds being mistaken for the operator changing their mind.
  do
    local L = turn_ledger(p, change.turn_gen)
    ledger.bump(L, "review_retries")
    ledger.record_decision(L, {
      action = "review_retry",
      actor = "system",
      attempt = tries,
      max_attempts = MAX_REVIEW_RETRY,
      change_id = change.id,
      rel = change.rel or change.path,
      detail = attempt_err or prior_err,
    })
  end
  -- Successful open clears review_error. Never exhaust a live review just
  -- because the counter crossed MAX.
  if not attempt_err then
    return false
  end
  if tries >= MAX_REVIEW_RETRY then
    change.review_error = REVIEW_RETRY_EXHAUSTED
    notify_one_line(
      "yana: review retries exhausted for " .. (change.rel or change.path)
        .. " — last refusal: " .. tostring(attempt_err),
      vim.log.levels.WARN
    )
    return false
  end
  notify_one_line(
    "yana: retrying review for " .. (change.rel or change.path)
      .. " (" .. tostring(tries) .. "/" .. tostring(MAX_REVIEW_RETRY) .. ")"
      .. " — was refused: " .. tostring(attempt_err),
    vim.log.levels.INFO
  )
  return false
end

-- Accept a pending change: resolve via inline review, else retry/notify.
local function accept_change(change)
  if not change or change.status ~= "pending" then
    return false
  end
  do
    local inline = require("yana.inline_diff")
    if inline.resolve_change(change, "accept") then
      local p = current_panel()
      if p then
        refresh_change_block(p, change)
        update_winbar(p)
      end
      return true
    end
    -- The refusal reasons are all transient user-side state, so the natural reading of
    -- "user pressed accept on a stuck row" is retry, not print advice for hunks that
    -- were never painted.
    if change.review_error then
      local p = current_panel()
      if p then
        return retry_refused_review(p, change)
      end
      -- No panel to build retry callbacks against; fall through to the
      -- ordinary advice path below.
    end
    if change.batched then
      notify_one_line(
        "yana: review for " .. (change.rel or change.path) .. " opens when the turn ends",
        vim.log.levels.INFO
      )
      return false
    end
    local p = current_panel()
    local ws_opts = change.review_workspace and { workspace = change.review_workspace }
      or (p and { workspace = panel_claimed_workspace(p) } or nil)
    if ws_opts then
      inline.focus_active(ws_opts)
    end
    notify_one_line("yana: resolve hunks in file (`ca` accept · `cr` reject · `cf` all)", vim.log.levels.INFO)
    return false
  end
end

-- Reject a pending change: resolve via inline review, else retry/notify.
local function reject_change(change)
  if not change or change.status ~= "pending" then
    return false
  end
  do
    local inline = require("yana.inline_diff")
    if inline.resolve_change(change, "reject") then
      local p = current_panel()
      if p then
        refresh_change_block(p, change)
        update_winbar(p)
      end
      return true
    end
    -- See the matching comment in M.accept_change: retry the review when
    -- this change's own attempt was refused, rather than giving advice for
    -- hunks that were never painted.
    if change.review_error then
      local p = current_panel()
      if p then
        return retry_refused_review(p, change)
      end
      -- No panel to build retry callbacks against; fall through to the
      -- ordinary advice path below.
    end
    if change.batched then
      notify_one_line(
        "yana: review for " .. (change.rel or change.path) .. " opens when the turn ends",
        vim.log.levels.INFO
      )
      return false
    end
    local p = current_panel()
    local ws_opts = change.review_workspace and { workspace = change.review_workspace }
      or (p and { workspace = panel_claimed_workspace(p) } or nil)
    if ws_opts then
      inline.focus_active(ws_opts)
    end
    notify_one_line("yana: reject in file (`cx` reject file · `cr` reject hunk)", vim.log.levels.INFO)
    return false
  end
end

-- Prompt to pick a pending change, then accept it.
local function accept_changes()
  pick_pending("yana: accept change", function(c)
    accept_change(c)
  end)
end

-- Prompt to pick a pending change, then reject it.
local function reject_changes()
  pick_pending("yana: reject change", function(c)
    reject_change(c)
  end)
end

-- Prompt to pick a pending change and open its diff review.
local function review_changes()
  local p = current_panel()
  pick_pending("yana: review change", function(change)
    -- Use the panel's own review handlers. The old inline table called
    -- M.accept_change, which no-ops once the engine has already marked the
    -- change accepted, so a picker-opened review left both the change block
    -- and its claim line stale.
    local opened = diff.review(change, p and inline_review_opts(p, change) or {})
    -- `review` returns true for "queued behind an active review" as well as
    -- "opened now". Say which, or picking a change looks like it did nothing.
    local inline = require("yana.inline_diff")
    -- `status ~= "pending"` filters the zero-hunk case: M.open auto-accepts a
    -- change with no diff blocks and never sets `active`, which otherwise
    -- looks identical to "queued" here and announced a queue that is empty.
    if opened and change.status == "pending" and p
      and inline.active_change({ workspace = panel_claimed_workspace(p) }) ~= change then
      notify_one_line(
        "yana: queued " .. (change.rel or "change") .. " behind the open review",
        vim.log.levels.INFO
      )
    end
  end)
end

  return {
    show_changes = show_changes,
    pick_pending = pick_pending,
    retry_refused_review = retry_refused_review,
    accept_change = accept_change,
    reject_change = reject_change,
    accept_changes = accept_changes,
    reject_changes = reject_changes,
    review_changes = review_changes,
  }
end

return M
