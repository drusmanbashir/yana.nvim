-- One rule for "are these two hunk records the same hunk", shared so a resume
-- rebind (review_open_bind_resume.lua) and a redo rebind (undo_action_buffer_edit.lua)
-- can never drift into two identity rules.
--
-- IDENTITY IS A NAME, NEVER BYTES. `lineage_id` first, as a VETO: a mint-once
-- token stamped when a hunk enters a ledger (hunk_ledger.lua) or is born from
-- a split/merge (hunk_ledger_lifecycle.lua), copied -- never regenerated --
-- when a rebuild inherits a hunk (review_open_bind.lua), so two records
-- carrying DIFFERENT ones are two hunks whatever else they share. Then
-- `model_index` when both carry one: assigned from the model mirror, it
-- survives a slow-resume rebuild. Then `lineage_id` again where no index exists.
--
-- NOT the proposal bytes. Two unrelated hunks with the same `old_lines` and
-- `new_lines` are two hunks, and a record whose hunk is GONE matches the
-- survivor's bytes exactly as well as its own would have: bytes select a
-- stranger and call it lineage. They may VALIDATE a name (see `looks_like`)
-- but they may not create one. NOT `model_join` either -- that is repeated
-- provenance, e.g. every split child inherits "payload_run"
-- (review_hunk_split.lua), so it cannot tell two hunks apart.
local M = {}

local next_lineage = 0

--- Mint a lineage id if this hunk has none. Called where a hunk BEGINS
--- existing; never called to refresh one, because an id that can be reassigned
--- is not an identity.
function M.stamp(block)
  if type(block) == "table" and block.lineage_id == nil then
    next_lineage = next_lineage + 1
    block.lineage_id = "lin-" .. next_lineage
  end
  return block
end

--- Carry a dead hunk's lineage onto the live hunk that replaced it. The ONLY
--- writer of an existing id, and it refuses to overwrite one.
function M.inherit(block, ancestor)
  if type(block) == "table" and type(ancestor) == "table"
    and block.lineage_id == nil and ancestor.lineage_id ~= nil then
    block.lineage_id = ancestor.lineage_id
  end
  return block
end

--- Bytes as VALIDATION, not identity: does this candidate still hold the
--- proposal the record was taken against? Callers that want to notice a name
--- resolving to a hunk whose content has since changed ask this AFTER `same`.
function M.looks_like(a, b)
  if a == nil or b == nil then
    return false
  end
  return table.concat(a.old_lines or {}, "\n") == table.concat(b.old_lines or {}, "\n")
    and table.concat(a.new_lines or {}, "\n") == table.concat(b.new_lines or {}, "\n")
end

function M.same(a, b)
  if a == nil or b == nil then
    return false
  end
  -- LINEAGE VETOES A SHARED MODEL SLOT: a slot is reusable and a lineage is
  -- not, so two lineages that disagree end it before the slot is read. One
  -- side without a lineage is not a disagreement and falls through.
  local al, bl = a.lineage_id, b.lineage_id
  if al ~= nil and bl ~= nil and al ~= bl then
    return false
  end
  local ai, bi = a.model_index, b.model_index
  if ai ~= nil and bi ~= nil then
    return ai == bi
  end
  -- ONE NAME OR NOTHING. An index on one side and none on the other is a
  -- refusal, not a reason to look at bytes: a hunk that has a model index
  -- keeps it, so the two are not the same hunk.
  if ai ~= nil or bi ~= nil then
    return false
  end
  if a.lineage_id ~= nil and b.lineage_id ~= nil then
    return a.lineage_id == b.lineage_id
  end
  -- Neither record carries a name this one can read. Nothing is known, and
  -- bytes are content: a record whose hunk is GONE matches a live stranger's
  -- identical proposal exactly as well as its own would have.
  return false
end

--- THE one answer to "which live hunk is this recorded hunk". Identity of the
--- table itself is proof and is the caller's to check first (it survives every
--- move that does not rebuild); this is the rebuild case, where the recorded
--- table is dead and only its NAME can name a hunk.
---
--- EXACTLY ONE match, or nothing. Two candidates that answer `same` name
--- nothing between them, and writing a recorded hunk's whole state into a
--- guessed one is worse than restoring none -- so ambiguity resolves like
--- absence. Returns the match (or nil) and the number of candidates that
--- matched, so a caller can say WHY it refused.
function M.resolve_unique(candidates, record)
  local found, count = nil, 0
  for _, candidate in ipairs(candidates or {}) do
    if M.same(candidate, record) then
      found = found or candidate
      count = count + 1
    end
  end
  if count ~= 1 then
    return nil, count
  end
  return found, count
end

return M
