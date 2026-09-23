-- yana.review_permissions — permission policy resolver (F-REVIEW-PERMISSIONS).
--
-- An agent-proposed mode change is a separate decision from the text hunks. It
-- is authorised ONCE, for one exact proposal, before anything is written:
--
--   * `allow` authorises without a question, `deny` keeps without a question.
--   * `ask` asks on a REAL USER VISIT only. A tab opened in the background is
--     not a visit: it asks nothing and decides nothing, so the first real visit
--     still asks.
--   * The `proposal_key` is {Turn, path, proposed mode}. A revised proposal is a
--     different key, so it needs fresh authorisation, and an answer that arrives
--     for a key the file no longer carries — or after the Turn ended — does
--     nothing at all.
--
-- THE RESOLVER NEVER CHANGES A VERDICT. It decides, and hands the decision to
-- the injected `record_mode_decision`, which is the only writer of the File's
-- `mode_verdict` and of the undo history. If that call fails the decision is
-- reported and the verdict stays Keep, so a failed record can never leave an
-- authorisation standing for the applier to act on. No file is written here and
-- no dialog is built here: the question UI is injected as `ask`.
local M = {}

-- The closed set of policies, in message order. `config_normalize` reads this
-- list, so the accepted config values and the branches below cannot drift.
M.policies = { "ask", "allow", "deny" }

--- True when `value` is one of the three accepted policies.
function M.is_policy(value)
  if type(value) ~= "string" then
    return false
  end
  for _, policy in ipairs(M.policies) do
    if policy == value then
      return true
    end
  end
  return false
end

-- Display only; the proposal key carries the raw value. A change carries the
-- mode either as git's 6-digit string (file type + permissions) or as the octal
-- number the product parses in `cli/turn.lua`, and both must read as `0644`.
local function mode_label(mode)
  if type(mode) == "number" then
    return string.format("%04o", mode)
  end
  local text = tostring(mode)
  if #text == 6 and text:match("^%d+$") then
    return text:sub(3)
  end
  return text
end

-- F-TRL01B-02: product changes spell the original mode `base_mode` in 18
-- modules; the frozen unit fixtures spell it `before_mode`. Renaming either is
-- outside this lane, so the original mode is read under both spellings and is
-- used for the question text only. The proposed mode has one spelling.
local function original_mode(change)
  return change.base_mode or change.before_mode
end

local function turn_is_live(turn)
  if turn ~= nil and type(turn.is_live) == "function" then
    return turn:is_live() and true or false
  end
  return true
end

-- The Turn's snapshot is authoritative (rule 7a: `review_opts.permissions`); the
-- File's copy answers for a file resolved outside a Turn. Absent means the
-- config default, `ask`.
function M.permission_policy(file, turn)
  local from_turn = turn and turn.review_opts and turn.review_opts.permissions
  if from_turn ~= nil then
    return from_turn
  end
  local from_file = file.review_opts and file.review_opts.permissions
  if from_file ~= nil then
    return from_file
  end
  return "ask"
end

local function path_of(file, change)
  return file.path or (change and change.path) or "?"
end

-- Returns the proposal key table and its identity string, or nil when the change
-- proposes no mode of its own. The key comes from its one owner,
-- `turn_settle.mode_proposal_key`, so resolver, navigation, cA and settlement
-- cannot disagree on it.
local function key_for(file)
  local key = type(file) == "table" and require("yana.turn.turn_settle").mode_proposal_key(file) or nil
  if key == nil then
    return nil
  end
  return key, key.turn .. "\0" .. key.path .. "\0" .. key.mode
end

-- Proposal keys compare BY CONTENT (Turn, path, mode): the File's record holds
-- its own key table, never the one this resolver just built (I3).
local function same_key(a, b)
  return type(a) == "table" and type(b) == "table" and require("yana.turn.turn_file").same_proposal_key(a, b)
end

--- The File's recorded mode verdict when it records THIS proposal, else nil.
function M.recorded_verdict(file)
  return require("yana.turn.turn_settle").current_mode_verdict(file)
end

--- True when `change` proposes a mode of its own (a permission proposal).
function M.proposes_mode(change)
  return type(change) == "table" and key_for({ change = change }) ~= nil
end

local function question_for(file)
  local change = file.change
  local from = original_mode(change)
  local from_label = from ~= nil and mode_label(from) or "its current mode"
  local to_label = mode_label(change.after_mode)
  local question = string.format(
    "%s: the agent proposes file permissions %s -> %s. Allow this change?",
    path_of(file, change),
    from_label,
    to_label
  )
  local choices = {
    { value = "allow", label = "Allow " .. to_label },
    { value = "keep", label = "Keep " .. from_label },
  }
  return question, choices
end

--- Builds a resolver over an injected question UI and decision recorder.
---
--- `ask(question, choices, done)` answers with `"allow" | "keep" | nil`; nil is
--- Keep. `record_mode_decision(file, {proposal_key, previous, next})` returns
--- `true` or `false, reason` and is the only thing that may change a verdict.
function M.new(deps)
  deps = deps or {}
  assert(type(deps.ask) == "function", "review_permissions.new: deps.ask is required")
  assert(
    type(deps.record_mode_decision) == "function",
    "review_permissions.new: deps.record_mode_decision is required"
  )
  local ask, record = deps.ask, deps.record_mode_decision

  -- Per-File decision state, weakly keyed so a closed File is collectable. It
  -- lives here and never on the File: the File's record is written by
  -- `record_mode_decision` alone.
  local states = setmetatable({}, { __mode = "k" })

  local function state_for(file)
    local state = states[file]
    if not state then
      state = {}
      states[file] = state
    end
    return state
  end

  -- Completes every resolve() call waiting on one question, exactly once each.
  local function settle(pending, ok, reason, verdict, key)
    local waiting = pending.waiting
    pending.waiting = {}
    for _, finish in ipairs(waiting) do
      finish(ok, reason, verdict, key)
    end
  end

  local function discard(state, reason)
    local pending = state.pending
    if not pending then
      return
    end
    state.pending = nil
    settle(pending, false, reason, "keep", pending.key)
  end

  -- The one authorisation route. A refusal or a throw from the recorder leaves
  -- the verdict unset, which is Keep, and reports the reason.
  --
  -- `policy` and `asked` travel with the decision because the File's record is
  -- `{proposal_key, policy, asked, verdict}` (rule 7a) and this resolver is the
  -- only place that knows which policy decided and whether a human was asked.
  local function authorise(file, state, key, keystr, taken, report)
    local verdict = taken.next or "allow"
    -- `previous` is the File's current verdict for THIS proposal (a record for
    -- another proposal is Keep): its door refuses a decision whose `previous`
    -- disagrees with the record, and after an undo the private state can be stale.
    local current = require("yana.turn.turn_file").mode_verdict_for(file, key)
    local previous = (current and current.verdict) or "keep"
    local called, ok, reason = pcall(record, file, {
      proposal_key = key,
      previous = previous,
      next = verdict,
      policy = taken.policy,
      asked = taken.asked,
    })
    if not called then
      return report(false, "record_mode_decision threw: " .. tostring(ok), "keep", key)
    end
    if ok ~= true then
      local what = verdict == "allow" and "the approval" or "the keep"
      return report(false, reason or ("record_mode_decision refused " .. what), "keep", key)
    end
    local now = file.mode_verdict
    state.keystr, state.verdict = keystr, verdict
    state.recorded = (type(now) == "table" and same_key(now.proposal_key, key)) or nil
    return report(true, nil, verdict, key)
  end

  --- Resolves the mode proposal on `file`. `opts.user_visit` is true only when a
  --- human actually entered the file's review. `done(ok, reason, detail)` fires
  --- exactly once, including when the answer is synchronous; `detail` carries
  --- `{proposal_key, verdict}`. Returns `true`, `false, reason` or `"pending"`.
  local function resolve(file, opts, done)
    opts = opts or {}
    local fired, outcome, outcome_reason = false, nil, nil
    local function finish(ok, reason, verdict, key)
      if fired then
        return
      end
      fired, outcome, outcome_reason = true, ok, reason
      if done then
        done(ok, reason, { proposal_key = key, verdict = verdict })
      end
    end
    local function settled()
      if outcome == true then
        return true
      end
      return false, outcome_reason
    end

    local key, keystr = key_for(file)
    if not key then
      -- No mode of its own to authorise.
      finish(true, nil, "keep", nil)
      return settled()
    end

    local turn = file.turn
    if not turn_is_live(turn) then
      finish(false, "turn_ended", "keep", key)
      return settled()
    end

    local state = state_for(file)
    local on_record = M.recorded_verdict(file)
    if state.keystr ~= keystr then
      -- A revised proposal: the old decision and any outstanding question for it
      -- are void, and this proposal starts unauthorised.
      discard(state, "proposal_changed")
      state.keystr, state.verdict, state.recorded = keystr, nil, nil
    elseif state.recorded and on_record == nil then
      -- The File no longer records the verdict this state mirrored (an undo
      -- walked it back): the private cache is void and the proposal is open.
      state.verdict, state.recorded = nil, nil
    end
    if on_record ~= nil and not state.pending then
      -- I3: a recorded verdict for this very proposal (asked or not) is the
      -- answer; nothing is asked and nothing is recorded again.
      state.verdict, state.recorded = on_record.verdict, true
      finish(true, nil, on_record.verdict, key)
      return settled()
    end
    if state.verdict ~= nil then
      finish(true, nil, state.verdict, key)
      return settled()
    end

    local policy = M.permission_policy(file, turn)
    if policy == "allow" then
      authorise(file, state, key, keystr, { policy = policy, asked = false }, finish)
      return settled()
    end
    if policy == "deny" then
      -- I3: an unasked policy verdict is recorded, like allow's.
      authorise(file, state, key, keystr, { policy = policy, asked = false, next = "keep" }, finish)
      return settled()
    end
    if policy ~= "ask" then
      finish(false, "unknown review.permissions policy: " .. tostring(policy), "keep", key)
      return settled()
    end

    if not opts.user_visit then
      -- Background: no question, and nothing decided, so the first real visit
      -- still asks.
      finish(true, nil, "keep", key)
      return settled()
    end

    if state.pending then
      state.pending.waiting[#state.pending.waiting + 1] = finish
      return "pending"
    end

    local pending = { keystr = keystr, key = key, waiting = { finish } }
    state.pending, state.asked = pending, true

    local answered = false
    local function answer(choice)
      if answered then
        return
      end
      answered = true
      if state.pending ~= pending then
        return
      end
      state.pending = nil
      if not turn_is_live(file.turn) then
        return settle(pending, false, "turn_ended", "keep", key)
      end
      local _, current = key_for(file)
      if current ~= keystr then
        return settle(pending, false, "proposal_changed", "keep", key)
      end
      -- An explicit Allow or Keep is a decision and records through the one
      -- authorisation route. A dismissal decides nothing: the mode stays kept,
      -- nothing is recorded, and the next real visit asks again (I3).
      if choice ~= "allow" and choice ~= "keep" then
        return settle(pending, true, nil, "keep", key)
      end
      local taken = { policy = "ask", asked = true, next = choice }
      return authorise(file, state, key, keystr, taken, function(ok, reason, verdict, k)
        settle(pending, ok, reason, verdict, k)
      end)
    end

    local question, choices = question_for(file)
    local called, err = pcall(ask, question, choices, answer)
    if not called then
      state.pending = nil
      settle(pending, false, "ask failed: " .. tostring(err), "keep", key)
    end
    if fired then
      return settled()
    end
    return "pending"
  end

  return { resolve = resolve }
end

return M
