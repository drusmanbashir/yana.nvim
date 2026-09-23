-- Size split of review_open_bind: one permission driver per live Turn.
local review_permissions = require("yana.review_permissions")
local review_tabs_module = require("yana.review_tabs")

local M = {}

--- The permission question UI, adapted from the one this plugin already speaks
--- (`vim.ui.select` over labelled choices) rather than a new dialog framework.
--- `done(value)` takes the resolver's own `"allow" | "keep" | nil`; a cancelled
--- select answers nil, which the resolver reads as Keep.
local function ask_permission(question, choices, done)
  vim.ui.select(choices, {
    prompt = question,
    format_item = function(item)
      return type(item) == "table" and tostring(item.label) or tostring(item)
    end,
  }, function(item)
    done(type(item) == "table" and item.value or nil)
  end)
end

--- Task 11's frozen `record_mode_decision(file, {proposal_key, previous, next})`,
--- injected BY NAME through `review_decisions`. It is not implemented here and
--- not defaulted: while `review_decisions` does not carry it, an approval cannot
--- be recorded, and the resolver is told so -- the verdict then stays Keep,
--- which is the honest answer. Authorising an unrecorded chmod would be the
--- fallback this refuses to be.
local function record_mode_decision(file, decision)
  local ok, decisions = pcall(require, "yana.review_decisions")
  local record = ok and type(decisions) == "table" and decisions.record_mode_decision or nil
  if type(record) ~= "function" then
    return false, "review_decisions.record_mode_decision is not available"
  end
  -- A verdict that stays what it was (Keep over the default Keep) goes on the
  -- File, so the ask gate sees it, but it is not an undoable decision: a history
  -- row for it would spend an undo press on nothing and strand a created file's
  -- safe removal behind it (R1, R6). Approval still records its own history.
  local unchanged = type(decision) == "table" and decision.previous == decision.next
  return record(file, decision, unchanged and { history = false } or nil)
end

--- ONE permission driver per live Turn (design :58-66). The resolver decides;
--- this is the part that knows WHEN a human actually looked at a file, and it
--- is the only thing that ever sets `opts.user_visit`.
local perm_driver = nil

function M.for_turn(pool, turn)
  if perm_driver and perm_driver.turn == turn then
    return perm_driver
  end
  if perm_driver then
    perm_driver.dispose()
  end
  local resolver = review_permissions.new({
    ask = ask_permission,
    record_mode_decision = record_mode_decision,
  })
  -- Keyed by PATH, not by the File table. `Turn:add_file` REPLACES the record
  -- for a path each time that file's review binds again (a resume that rebuilds
  -- is a new record for the same file), and a mark tied to the old table would
  -- be lost with it -- the file would then be asked a second time for a proposal
  -- it has already answered. The Turn and the path together are what the
  -- proposal key names; the driver is per-Turn, so the path is the identity.
  local marks = {}

  --- PROPOSAL IDENTITY is what stops a duplicate question across the two entry
  --- points (a tab visit and the bind of an already-current file). Within one
  --- File the Turn and the path are fixed, so the proposed mode alone names the
  --- proposal: the same value is never driven twice, and a REVISED proposal is a
  --- different value and is driven again, exactly as R9 requires.
  local function drive(file, user_visit)
    if type(file) ~= "table" or type(file.change) ~= "table" then
      return
    end
    -- NO FIRST QUESTION AT END (design :60). The End process pumps the event
    -- loop -- the dialog, the settlement and the tab close all do -- and closing
    -- an owned tab lands the operator in whatever tab is left, which may show an
    -- unvisited member. That is the Turn leaving, not a human arriving.
    if turn ~= nil and (turn.ending == true or (type(turn.is_live) == "function" and not turn:is_live())) then
      return
    end
    local path = file.path or file.change.path
    if type(path) ~= "string" then
      return
    end
    -- The File's Turn reference (rule 7a). The bind of a file sets it, but a
    -- member whose own review has NOT bound yet -- intake builds the Turn's
    -- file list from the whole queued batch -- carries no Turn at all, and the
    -- resolver reads the policy snapshot, the Turn's liveness and the proposal
    -- key's Turn identity through exactly this field. Without it the first
    -- visit of an unbound member is judged with no Turn: measured, that asked a
    -- question under `permissions = "deny"`.
    if file.turn == nil then
      file.turn = turn
    end
    local mark = marks[path]
    if mark == nil then
      mark = {}
      marks[path] = mark
    end
    local proposal = file.change.after_mode
    if mark.driving == proposal then
      return
    end
    -- An answer is only as current as the File's record of it: once the File no
    -- longer records the verdict the mark saw (an undo walked it back), the mark
    -- is void and the visit is driven again (I3).
    if mark.answered == proposal and not (mark.recorded and review_permissions.recorded_verdict(file) == nil) then
      return
    end
    mark.answered, mark.recorded = nil, nil
    mark.driving = proposal
    resolver.resolve(file, { user_visit = user_visit }, function()
      mark.driving = nil
      local recorded = review_permissions.recorded_verdict(file) ~= nil
      -- Only a recorded verdict marks the proposal answered: a background pass
      -- under ask and a dismissed question decide nothing, so the next real
      -- visit is still driven.
      if recorded then
        mark.answered, mark.recorded = proposal, recorded
      end
    end)
  end

  local driver = { turn = turn, drive = drive }
  local dispose_observer = review_tabs_module.observe_visits(pool, turn, function(path, tab_id, win_id)
    local file = turn and type(turn.file) == "function" and turn:file(path) or nil
    require("yana.log").lifecycle_info("review.permissions.visit", {
      path = path,
      tab = tab_id,
      win = win_id,
      member = file ~= nil,
    })
    if file ~= nil then
      drive(file, true)
    end
  end)
  driver.dispose = function()
    dispose_observer()
    if perm_driver == driver then
      perm_driver = nil
    end
  end
  -- Disposed through Turn cleanup: the observer is scoped to the Turn whose
  -- members it resolves, and outlives nothing.
  if turn and type(turn.register) == "function" then
    turn:register({
      name = "permissions",
      turn_end = function()
        driver.dispose()
      end,
    })
  end
  perm_driver = driver
  return driver
end

return M
