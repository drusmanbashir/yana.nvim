-- Owns ONE FILE's membership in a Turn: the stable record, its review
-- reference, the original facts, the verdicts and the verified disk evidence.
--
-- The record is the identity. `Turn:add_file` must refresh this table in place,
-- never replace it: a partial re-add that drops `base_text`, the ledger, the
-- buffer, the review options or the owner is the R3 fault this module exists to
-- make impossible (F-HUNK-LEDGER).
--
-- NO VIM CALLS AND NO WRITES. Pure table surgery, so every clause is reachable
-- from a unit row. Nothing here reads disk, a buffer, a window or the config;
-- callers hand in what they verified and this module records it.
--
-- Names are frozen by pod-lead adjudication F-TRL01-01/F-TRL01B-02: the Turn
-- reference is `turn`; change identity is `change.id` falling back to `op_id`;
-- cached settlement is `settled_at_exit`/`settlement_stamp`; `attach(state)`
-- reads `state.ledger`/`state.bufnr`; the permission record is
-- `mode_verdict = {proposal_key, policy, asked, verdict}`.
--
-- THE CHANGE IS STORED VERBATIM. This module never renames, adds or interprets
-- a mode key: the unit fixtures spell `change.before_mode`, 18 product modules
-- spell `change.base_mode`, and both travel through here unharmed. Mode VALUES
-- are carried and compared, never parsed or formatted -- git's "100644" strings
-- and the product's octal numbers are equally opaque to this file.

local M = {}

local File = {}
File.__index = File

local OPERATION_VERDICTS = { pending = true, accepted = true, rejected = true }
local MODE_VERDICTS = { allow = true, keep = true }
-- A textless create/delete carries an operation decision; a modify does not.
local OPERATION_KINDS = { create = true, delete = true }

-- The established change identity. `id` is the modern spelling and `op_id` the
-- one the shadow change set still emits; either one names the same proposal.
local function identity_of(change)
  if type(change) ~= "table" then
    return nil
  end
  local id = change.id
  if id == nil then
    id = change.op_id
  end
  return id
end

local function operation_of(change)
  if type(change) ~= "table" then
    return nil
  end
  return OPERATION_KINDS[change.kind] and change.kind or nil
end

local function call(ledger, name)
  if type(ledger) ~= "table" then
    return nil
  end
  local fn = ledger[name]
  if type(fn) ~= "function" then
    return nil
  end
  local ok, result = pcall(fn, ledger)
  if not ok then
    return nil
  end
  return result
end

-- The RETAINED ledger, decided hunks included. A parked review keeps its
-- verdicts; rebuilding acceptance from pending hunks alone would forget every
-- decision the human already made.
local function hunks(self)
  local blocks = call(self.ledger, "members")
  if type(blocks) ~= "table" then
    return nil
  end
  return blocks
end

--- Build the stable record for one reviewed file inside `turn`.
--- Returns the File, or `nil, reason`.
function M.new(entry, turn)
  if type(entry) ~= "table" then
    return nil, "turn_file.new: entry must be a table, got " .. type(entry)
  end
  if type(entry.path) ~= "string" or entry.path == "" then
    return nil, "turn_file.new: entry needs a path, got " .. tostring(entry.path)
  end
  if turn == nil then
    return nil, "turn_file.new: " .. entry.path .. " needs its turn"
  end

  local self = setmetatable({}, File)
  -- The caller-visible record. Copied by reference and verbatim: an absent
  -- field stays absent, and `""` is only ever the caller's own explicit value.
  self.path = entry.path
  self.turn = turn
  self.change = entry.change
  self.ledger = entry.ledger
  self.base_text = entry.base_text
  self.overlay_text = entry.overlay_text
  self.bufnr = entry.bufnr
  self.review_opts = entry.review_opts
  self.review_owner = entry.review_owner
  self.review_state = entry.review_state

  -- Established facts, immutable once known. `change_id` and `operation` are
  -- derived once so a later refresh cannot turn a creation into a modify and
  -- lose the pending operation with it.
  self.change_id = identity_of(entry.change)
  self.operation = operation_of(entry.change)
  if self.operation ~= nil then
    self.operation_verdict = "pending"
  end
  return self
end

--- Refresh the record in place from a partial `entry`.
--- An omitted field preserves the established value; it never clears it.
--- A different path, Turn or change identity is a named refusal that mutates
--- nothing. Returns `true`, or `false, reason`.
function File:refresh(entry)
  if type(entry) ~= "table" then
    return false, "turn_file.refresh: " .. self.path .. " needs a table entry, got " .. type(entry)
  end

  if entry.path ~= nil and entry.path ~= self.path then
    return false,
      "turn_file.refresh: a different path " .. tostring(entry.path) .. " cannot refresh " .. self.path
  end
  if entry.turn ~= nil and not rawequal(entry.turn, self.turn) then
    return false, "turn_file.refresh: a different turn cannot refresh " .. self.path
  end
  local offered = identity_of(entry.change)
  if entry.change ~= nil and self.change_id ~= nil and offered ~= self.change_id then
    return false,
      "turn_file.refresh: a different change "
        .. tostring(offered)
        .. " cannot refresh "
        .. self.path
        .. " (established change "
        .. tostring(self.change_id)
        .. ")"
  end

  -- Past the identity gate nothing below can fail, so the record never lands
  -- half-updated.
  if entry.change ~= nil and self.change == nil then
    -- First time the change is known. Creation identity is fixed here.
    self.change = entry.change
    self.change_id = offered
    self.operation = operation_of(entry.change)
    if self.operation ~= nil and self.operation_verdict == nil then
      self.operation_verdict = "pending"
    end
  end
  -- An established change is NOT replaced: `change.before`, `base_hash` and
  -- `disk_at_open` are rebased applier evidence, and `record_projection` is
  -- their only writer. Swapping in a same-identity copy would quietly restore a
  -- pre-save snapshot over bytes the human has already durably saved.

  if entry.base_text ~= nil and self.base_text == nil then
    -- Original content, immutable ONCE KNOWN: the first explicit value wins and
    -- a later rebase offer is ignored, never applied.
    self.base_text = entry.base_text
  end
  if entry.ledger ~= nil then
    self.ledger = entry.ledger
  end
  if entry.overlay_text ~= nil then
    self.overlay_text = entry.overlay_text
  end
  if entry.bufnr ~= nil then
    self.bufnr = entry.bufnr
  end
  if entry.review_opts ~= nil then
    self.review_opts = entry.review_opts
  end
  if entry.review_owner ~= nil then
    self.review_owner = entry.review_owner
  end
  if entry.review_state ~= nil then
    self.review_state = entry.review_state
  end
  return true
end

--- Explicit review (re)build: ledger, buffer and state move together, and the
--- cached settlement is no longer about this attachment.
--- Returns `true`, or `false, reason`.
function File:attach(state)
  if type(state) ~= "table" then
    return false, "turn_file.attach: " .. self.path .. " needs a review state, got " .. type(state)
  end
  self.review_state = state
  -- Review states carry their ledger as `hunk_ledger`; without it this attach
  -- would move buffer and state but leave the old ledger behind.
  local ledger = state.ledger
  if ledger == nil then
    ledger = state.hunk_ledger
  end
  if ledger ~= nil then
    self.ledger = ledger
  end
  if state.bufnr ~= nil then
    self.bufnr = state.bufnr
  end
  self:invalidate_settlement()
  return true
end

--- Drop the review reference, but only for the attachment the caller still
--- believes is current. A newer review on the same file is never retired by an
--- older owner's teardown. Membership, ledger and original facts are retained.
--- Returns `true`, or `false, reason`.
function File:detach(expected_state)
  if not rawequal(self.review_state, expected_state) then
    return false, "turn_file.detach: that review state is not the current one for " .. self.path
  end
  self.review_state = nil
  return true
end

--- Canonical acceptance: accepted text in the retained ledger, or an accepted
--- textless operation. Permission approval alone is NEVER acceptance, and
--- `change.status` is presentation, never a fallback.
function File:accepted()
  if self.operation_verdict == "accepted" then
    return true
  end
  local blocks = hunks(self)
  if blocks ~= nil then
    for _, block in ipairs(blocks) do
      if block.verdict == "accepted" then
        return true
      end
    end
  end
  return false
end

--- Pending ledger hunks plus one unresolved textless operation. A deletion that
--- carries text is counted through its hunks only, never hunk plus operation.
--- Permission questions are not text hunks and add nothing here.
function File:pending_count()
  local n = 0
  local textless = true
  local blocks = hunks(self)
  if blocks ~= nil then
    textless = (#blocks == 0)
    for _, block in ipairs(blocks) do
      if block.verdict == "pending" then
        n = n + 1
      end
    end
  end
  if textless and self.operation ~= nil and self.operation_verdict == "pending" then
    n = n + 1
  end
  return n
end

--- Record the create/delete decision. Returns `true`, or `false, reason`; a
--- refused verdict changes nothing.
function File:decide_operation(verdict)
  if self.turn and self.turn.frozen then
    return false, "turn is frozen for End"
  end
  if not OPERATION_VERDICTS[verdict] then
    return false,
      "turn_file.decide_operation: "
        .. self.path
        .. " got an unknown verdict "
        .. tostring(verdict)
        .. "; expected pending, accepted or rejected"
  end
  if self.operation == nil then
    return false, "turn_file.decide_operation: " .. self.path .. " has no create or delete operation to decide"
  end
  self.operation_verdict = verdict
  return true
end

--- True when two proposal keys name the same proposal BY CONTENT (Turn, path,
--- proposed mode). Table keys compare field by field as stored; any other key
--- compares by value. Key fields are compared here, never parsed.
function M.same_proposal_key(a, b)
  if type(a) == "table" and type(b) == "table" then
    return tostring(a.turn) == tostring(b.turn)
      and tostring(a.path) == tostring(b.path)
      and tostring(a.mode) == tostring(b.mode)
  end
  return a ~= nil and a == b
end

--- `file.mode_verdict` when it records the proposal `key`, else nil: a record
--- for another proposal authorises nothing for this one.
function M.mode_verdict_for(file, key)
  local mv = type(file) == "table" and file.mode_verdict or nil
  if key ~= nil and type(mv) == "table" and M.same_proposal_key(mv.proposal_key, key) then
    return mv
  end
  return nil
end

--- Record the permission decision for ONE exact proposal, as task 11's
--- `record_mode_decision(file, {proposal_key, previous, next})` supplies it.
--- `previous` is a compare-and-set against the verdict now on the record, so a
--- late answer for a verdict that has since moved cannot overwrite it. The
--- default verdict is "keep". Returns `true`, or `false, reason`.
function File:decide_mode(decision)
  if self.turn and self.turn.frozen then
    return false, "turn is frozen for End"
  end
  if type(decision) ~= "table" then
    return false, "turn_file.decide_mode: " .. self.path .. " needs a decision table, got " .. type(decision)
  end
  if decision.proposal_key == nil then
    return false, "turn_file.decide_mode: " .. self.path .. " needs the exact proposal_key"
  end
  local verdict = decision.verdict
  if verdict == nil then
    verdict = decision.next
  end
  if verdict == nil then
    verdict = "keep"
  end
  if not MODE_VERDICTS[verdict] then
    return false,
      "turn_file.decide_mode: "
        .. self.path
        .. " got an unknown mode verdict "
        .. tostring(verdict)
        .. "; expected allow or keep"
  end
  -- The compare-and-set reads the verdict for THIS proposal: a record left by a
  -- since-revised proposal is Keep for it.
  local on_key = M.mode_verdict_for(self, decision.proposal_key)
  local current = (on_key and on_key.verdict) or "keep"
  if decision.previous ~= nil and decision.previous ~= current then
    return false,
      "turn_file.decide_mode: "
        .. self.path
        .. " expected the previous mode verdict "
        .. tostring(decision.previous)
        .. " but it is "
        .. tostring(current)
  end
  self.mode_verdict = {
    proposal_key = decision.proposal_key,
    policy = decision.policy,
    asked = decision.asked,
    verdict = verdict,
  }
  return true
end

--- The ONLY door that advances rebased applier evidence after a confirmed disk
--- success: `change.before`, the base fingerprint pair and `disk_at_open`.
--- `before` and `disk_at_open` are read as a pair, so bytes supplied once move
--- both. Immutable original evidence -- `base_text`, the path, the change
--- identity and the creation kind -- is untouched, and mode values are copied
--- without being parsed or formatted. Returns `true`, or `false, reason`.
function File:record_projection(snapshot)
  if type(snapshot) ~= "table" then
    return false, "turn_file.record_projection: " .. self.path .. " needs a snapshot table, got " .. type(snapshot)
  end
  if snapshot.path ~= nil and snapshot.path ~= self.path then
    return false,
      "turn_file.record_projection: a different path " .. tostring(snapshot.path) .. " cannot rebase " .. self.path
  end
  local change = self.change
  if type(change) ~= "table" then
    return false, "turn_file.record_projection: " .. self.path .. " has no change to synchronise"
  end

  local bytes = snapshot.bytes
  if bytes == nil then
    bytes = snapshot.before
  end
  if bytes ~= nil then
    change.before = bytes
    change.disk_at_open = bytes
  end
  if snapshot.disk_at_open ~= nil then
    change.disk_at_open = snapshot.disk_at_open
  end
  if snapshot.base_hash ~= nil then
    change.base_hash = snapshot.base_hash
  end
  if snapshot.base_state ~= nil then
    change.base_state = snapshot.base_state
  end
  if snapshot.base_mode ~= nil then
    change.base_mode = snapshot.base_mode
  end
  if snapshot.last_verified_disk ~= nil then
    self.last_verified_disk = snapshot.last_verified_disk
  end
  if snapshot.receipt ~= nil then
    -- The commit receipt is retained for retry: committed-but-reconcile-failed
    -- is not the same as no write.
    self.commit_receipt = snapshot.receipt
  end
  return true
end

--- The ONLY door that writes the cached exit settlement pair. Both halves are
--- recorded verbatim -- no copy, no validation, no I/O -- so a caller holding
--- one half already hands that half back unchanged.
function File:record_settlement(stamp, settled_at_exit)
  self.settlement_stamp = stamp
  self.settled_at_exit = settled_at_exit
  return true
end

--- Forget the cached exit settlement, and nothing else.
function File:invalidate_settlement()
  return self:record_settlement(nil, nil)
end

--- THE ONLY DOOR that writes this File's settlement receipt. The Turn and the
--- settler both call it; neither assigns the fields, because three writers is
--- how a committed write came to be overwritten by a later step that had not
--- written anything.
---
--- A receipt that reports a WRITE is not replaced by one that does not. The
--- operation is on disk; a readback, reconcile or cleanup that fails afterwards
--- does not unwrite it, and the retry must see the committed receipt so it
--- reuses the operation instead of repeating it (F-APPLY-JOURNAL). Clearing is
--- explicit, through `clear_receipt`, and is the settler's word that the
--- operation is no longer owed.
function File:record_receipt(detail)
  if type(detail) ~= "table" then
    return false, "turn_file.record_receipt: a receipt must be a table"
  end
  local held = self.settle_receipt
  if type(held) == "table" and held.written == true and detail.written ~= true then
    return false, "turn_file.record_receipt: a committed receipt is not replaced by an unwritten one"
  end
  self.settle_receipt = detail
  return true
end

--- The RETRY TOKEN, and a separate thing from the receipt above. It says an
--- operation committed but a later step could not confirm it, so the next
--- attempt must spend this token rather than write again. Its lifecycle is the
--- settler's alone: recording an outcome must never resurrect a token the
--- settler has already spent, which is why this is not folded into
--- `record_receipt`.
function File:hold_commit(detail)
  if type(detail) ~= "table" then
    return false, "turn_file.hold_commit: a commit token must be a table"
  end
  self.commit_receipt = detail
  return true
end

--- The settler's word that the token is spent and nothing is owed here.
function File:clear_receipt()
  self.commit_receipt = nil
  return true
end

return M
