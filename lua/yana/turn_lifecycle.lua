-- yana: the turn lifecycle — durable turn ids, classified bundle
-- publication, the actionability predicate every durable action waits on,
-- turn-bound callbacks, and a resume path that inspects a retained claim
-- before any cleanup runs.
--
-- Why this module exists (the fixed safety contract, "Async principle"):
--
--   claim committed → agent runs → upper layer sealed → walk + classify +
--   bundle published → review becomes ACTIONABLE → generation-bound accept →
--   applier re-read → write.
--
-- The panel must never block, but DISPLAY and ACTION are different things. A
-- review may open early and provisionally from the stream's declared edits,
-- because opening changes nothing durable. Every action that changes durable
-- state waits for the complete, classified, published bundle: an accept that
-- runs before its evidence exists is not a latency win, it is a write with no
-- authority behind it. A hostile agent that mislabels `.git/config` as an
-- ordinary edit is stopped here, because actionability is a property of the
-- CLASSIFICATION and not of what the stream said.
--
-- Three things are kept apart on purpose:
--   * `begin_turn` — the turn exists, has a durable id, and is NOT actionable.
--   * `publish_bundle` — classification is complete and durable; only now does
--     the turn become actionable.
--   * `action_allowed` — the single predicate every durable action asks.
--
-- This module owns no files of its own. Durable turn records are written by
-- `yana.record`, which is the module that already owns durable turn-scoped
-- writes; claim release goes through `yana.shadow.jail`, which is the only
-- actor allowed to release a claim.

local log = require("yana.log")
local record = require("yana.record")

local M = {}

-- The live pass per panel. A callback resolves its owner from the tuple it
-- captured, never from this table — the table is only ever the answer to "what
-- is running NOW", which is precisely the question a stale callback must not be
-- allowed to ask on its own behalf.
M._passes = {}

-- The five fields of the callback tuple, in the order CORE names them. Every
-- one is load-bearing: `turn` alone cannot separate two passes over the same
-- turn id, and `generation` alone cannot separate two panels.
M.TUPLE_FIELDS = { "panel", "stream", "turn", "generation", "bundle_digest" }

--- Git-tracked paths as of the PRE-TURN workspace, before the agent can mutate
--- `.git/index`. Used for undeclared-write badging (shortlist 2b).
function M.capture_tracked(workspace)
  local set = {}
  if not workspace or workspace == "" then
    return set
  end
  local out = vim.fn.systemlist({ "git", "-C", workspace, "ls-files" })
  if vim.v.shell_error ~= 0 then
    return set
  end
  for _, rel in ipairs(out) do
    if rel ~= "" then
      set[rel] = true
    end
  end
  return set
end

function M.note_declared(pass, rel)
  if pass and rel and rel ~= "" then
    pass.declared[rel] = true
  end
end

function M.tracked_preturn(pass, rel)
  return pass ~= nil and rel ~= nil and pass.tracked_preturn[rel] == true
end

function M.is_undeclared_tracked(pass, rel)
  if not pass or not rel or rel == "" then
    return false
  end
  if pass.declared[rel] then
    return false
  end
  return M.tracked_preturn(pass, rel)
end

----------------------------------------------------------------------
-- durable turn ids
----------------------------------------------------------------------

local seq = 0

--- A durable, human-readable turn id. Durable because it is written into the
--- turn record before anything can die, and because it is derived from wall
--- time plus the panel rather than from an in-memory counter that a restart
--- resets: after a crash the recovered turn still has a name.
function M.new_turn_id(panel_id, generation)
  seq = seq + 1
  return string.format(
    "%s-p%s-g%s-%d",
    os.date("!%Y%m%dT%H%M%SZ"),
    tostring(panel_id or 0),
    tostring(generation or 0),
    seq
  )
end

----------------------------------------------------------------------
-- 7a — open early, act only after the classified bundle publishes
----------------------------------------------------------------------

--- Begin a turn. The pass exists, carries its tuple, and is explicitly NOT
--- actionable: nothing has been classified yet.
---
--- opts: { panel_id, generation, stream, turn_id, workspace, claim_dir,
---         state_dir, declared }
function M.begin_turn(opts)
  opts = opts or {}
  local generation = opts.generation or 0
  local turn_id = opts.turn_id and tostring(opts.turn_id)
    or M.new_turn_id(opts.panel_id, generation)
  local pass = {
    panel = opts.panel_id,
    stream = opts.stream and tostring(opts.stream) or "unbound",
    turn_id = turn_id,
    generation = generation,
    workspace = opts.workspace,
    claim_dir = opts.claim_dir,
    state_dir = opts.state_dir,
    -- What the stream DECLARED. A provisional review may render from this; no
    -- action may be decided from it.
    declared = opts.declared or {},
    tracked_preturn = opts.tracked_preturn or M.capture_tracked(opts.workspace),
    -- The classified, published bundle. nil until publication, and that nil is
    -- the whole of the actionability decision.
    bundle = nil,
    diagnostics = {},
  }
  M._passes[pass.panel] = pass
  M.persist(pass, "open")
  return pass
end

--- The live pass for a panel, or nil.
function M.current(panel_id)
  return M._passes[panel_id]
end

--- Canonical bytes of a classified entry list. Sorted, so two walks that
--- visited the same tree in different orders publish the same digest, and
--- carrying the class, so a reclassification changes the digest even when the
--- file set does not.
local function canonical(turn_id, classified)
  local rows = {}
  for _, entry in ipairs(classified) do
    rows[#rows + 1] = table.concat({
      tostring(entry.class),
      tostring(entry.rel or entry.path),
      tostring(entry.hash or ""),
    }, "\t")
  end
  table.sort(rows)
  return turn_id .. "\n" .. table.concat(rows, "\n")
end

--- The digest of a classified entry list. Callbacks validate against it, so a
--- callback built for one bundle cannot act on a different one.
function M.bundle_digest(turn_id, classified)
  local ok, digest = pcall(function()
    return require("yana.safety.hash").hash_bytes(canonical(turn_id, classified))
  end)
  if not ok or type(digest) ~= "string" then
    return nil, "could not digest the bundle: " .. tostring(digest)
  end
  return digest:sub(1, 32)
end

--- Publish the classified bundle. This is the ONE step that makes a turn
--- actionable, and it refuses to publish an incomplete classification: an entry
--- with no class would be an unclassified path wearing a published bundle's
--- authority, which is the exact confusion the ordering exists to prevent.
---
--- `classified` is a list of { rel, class, hash? }. Classification itself is
--- the caller's: this module is the ordering, not the classifier.
function M.publish_bundle(pass, classified)
  if not pass then
    return nil, "no turn pass"
  end
  classified = classified or {}
  for i, entry in ipairs(classified) do
    if type(entry) ~= "table" or entry.class == nil or entry.class == "" then
      return nil,
        string.format(
          "refusing to publish an unclassified bundle: entry %d (%s) carries no class",
          i,
          tostring(type(entry) == "table" and (entry.rel or entry.path) or entry)
        )
    end
  end
  local digest, derr = M.bundle_digest(pass.turn_id, classified)
  if not digest then
    return nil, derr
  end
  -- A turn publishes ONCE. Republishing a different bundle under the same turn
  -- id would silently revalidate every callback that was bound to the first
  -- one, which is the same misbinding this module exists to prevent, one level
  -- down. Republishing the identical bundle is a harmless retry and is allowed.
  if pass.bundle and pass.bundle.bundle_digest ~= digest then
    return nil,
      string.format(
        "refusing to republish turn %s: a different bundle already published (%s)",
        tostring(pass.turn_id),
        tostring(pass.bundle.bundle_digest)
      )
  end
  pass.bundle = {
    classified = classified,
    bundle_digest = digest,
    published_at = os.time(),
  }
  -- Durable before it is usable: a bundle that only exists in memory cannot be
  -- the authority a crash-surviving review is judged against.
  M.persist(pass, "published")
  return pass.bundle
end

--- The actionability predicate. A review with no published bundle is
--- PROVISIONAL: it may be displayed, and nothing more.
function M.is_actionable(pass)
  return pass ~= nil and pass.bundle ~= nil and pass.bundle.bundle_digest ~= nil
end

--- The classification the published bundle recorded for a path, or nil when the
--- bundle never mentioned it.
function M.classification(pass, rel)
  if not M.is_actionable(pass) then
    return nil
  end
  for _, entry in ipairs(pass.bundle.classified) do
    if (entry.rel or entry.path) == rel then
      return entry.class
    end
  end
  return nil
end

-- Classes that may never be acted on, whatever the stream declared them to be.
local NEVER_ACTIONABLE = {
  ["control-plane"] = "control-plane path is never offered, whatever the stream declared",
  ["binary"] = "binary content is never offered for review",
}

--- The question every durable action (accept, delete, revert) asks before it
--- does anything at all. Returns true, or false plus the reason it waits.
function M.action_allowed(pass, rel)
  if not pass then
    return false, "refused: no turn pass owns this action"
  end
  if not M.is_actionable(pass) then
    return false, "refused: the classified bundle for this turn has not published yet"
  end
  local class = M.classification(pass, rel)
  if class == nil then
    return false, "refused: no classified entry for " .. tostring(rel)
  end
  local never = NEVER_ACTIONABLE[class]
  if never then
    return false, "refused: " .. never
  end
  return true
end

----------------------------------------------------------------------
-- 7b — a callback carries and validates its owning tuple
----------------------------------------------------------------------

local function tuple_of(pass)
  return {
    panel = pass and pass.panel,
    stream = pass and pass.stream,
    turn = pass and pass.turn_id,
    generation = pass and pass.generation,
    bundle_digest = pass and pass.bundle and pass.bundle.bundle_digest or nil,
  }
end

M.tuple_of = tuple_of

--- Record a stale delivery. A stale or cancelled callback may publish durable
--- diagnostics and NOTHING else — that is its one permitted effect.
local function drop(pass, name, field, owner, current)
  local msg = string.format(
    "yana: dropped a stale callback (%s): %s belongs to another pass (owner=%s current=%s)",
    tostring(name),
    field,
    tostring(owner[field]),
    tostring(current[field])
  )
  if pass then
    pass.diagnostics[#pass.diagnostics + 1] = msg
  end
  log.write(log.levels.WARN, msg)
  return false, "refused: " .. field .. " does not belong to the current pass"
end

--- Bind `fn` to the pass that OWNS it, and refuse to run it under any other.
---
--- The owning pass is captured here, at bind time, and never resolved through
--- the panel at delivery time — reaching through the panel to ask which turn a
--- callback "should" belong to is exactly how a callback from turn N binds its
--- change to turn N+1 (arch BLOCKER-2).
---
--- The owner's tuple is READ FROM THE CAPTURED PASS at delivery rather than
--- copied at bind time, because callbacks are legitimately built while a review
--- is still provisional, when the bundle digest does not exist yet. A pass table
--- is created once per turn and `publish_bundle` refuses to republish a
--- different bundle under it, so the captured pass's tuple is immutable in every
--- field that matters by the time any delivery can happen. A stale callback
--- holds turn N's pass table while the panel holds turn N+1's, so all five
--- fields are compared across two different passes and a mismatch on any single
--- one is a refusal.
function M.bind_callback(pass, name, fn)
  local owner_pass = pass
  return function(...)
    local live = owner_pass and M._passes[owner_pass.panel] or nil
    local owner = tuple_of(owner_pass)
    local current = tuple_of(live)
    for _, field in ipairs(M.TUPLE_FIELDS) do
      if owner[field] ~= current[field] then
        return drop(live or owner_pass, name, field, owner, current)
      end
    end
    return fn(...)
  end
end

----------------------------------------------------------------------
-- 7c — crash resume inspects the retained claim before any cleanup
----------------------------------------------------------------------

--- Where durable turn records live. One directory, so a restart has one place
--- to look and does not have to guess which panel it lost.
function M.state_dir()
  return vim.fn.stdpath("state") .. "/yana/turns"
end

--- Write the turn record. Durable BEFORE the process can die, not after: a
--- record written at review close would be exactly the record a crash loses.
function M.persist(pass, state)
  if not pass then
    return false, "no turn pass"
  end
  local dir = pass.state_dir or M.state_dir()
  return record.write_turn_record(dir, {
    turn_id = pass.turn_id,
    panel = pass.panel,
    stream = pass.stream,
    generation = pass.generation,
    bundle_digest = pass.bundle and pass.bundle.bundle_digest or nil,
    workspace = pass.workspace,
    claim_dir = pass.claim_dir,
    state = state or "open",
    -- The review is owed while the turn is open. `false` is written only by the
    -- paths that KNOW the review resolved; a crash never gets to write it, which
    -- is what makes a retained turn recognisable after a restart.
    open = state ~= "closed",
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  })
end

--- Mark the turn resolved. Called when a review closes normally.
function M.close_turn(pass, _reason)
  if not pass then
    return false, "no turn pass"
  end
  local ok, err = M.persist(pass, "closed")
  if M._passes[pass.panel] == pass then
    M._passes[pass.panel] = nil
  end
  return ok, err
end

--- Inspect one retained turn's claim. READ ONLY, and deliberately so: this runs
--- before any cleanup and its whole job is to report what is still owed.
---
--- `the claims and concurrency contract`: "Never guess dead." A claim directory
--- that exists and carries a review-open marker is an open review, whatever
--- happened to the process that created it. Unknown is reported as unknown and
--- is never rounded down to "safe to clean".
function M.inspect_claim(rec)
  local claim_dir = rec and rec.claim_dir
  local out = {
    turn_id = rec and rec.turn_id,
    claim_dir = claim_dir,
    -- The record's own opinion, written before the crash.
    record_open = rec ~= nil and rec.open == true,
  }
  if claim_dir == nil or claim_dir == "" then
    out.claim_held = false
    out.review_open = false
    out.open = out.record_open
    return out
  end
  local ok, jail = pcall(require, "yana.shadow.jail")
  if not ok then
    out.claim_held = nil
    out.review_open = nil
    out.open = true -- unreadable is not released
    out.unknown = "could not load the claim module"
    return out
  end
  out.claim_held = jail.claim_held(claim_dir)
  out.review_open = jail.review_open(claim_dir)
  out.open = out.record_open or out.review_open or out.claim_held
  return out
end

--- The production resume path.
---
--- THE ORDERING IS THE CLAIM. Every retained turn is INSPECTED first, and
--- cleanup only ever runs against what the inspection reported as released.
--- Cleanup that ran first would be a crash recovery that destroys the evidence
--- of the review it was recovering (arch BLOCKER-3), so the two steps are
--- recorded in the order they ran and the order is returned to the caller
--- rather than asserted in a comment.
---
--- opts: { state_dir?, release? }  `release` defaults to the real claim
--- release; it is a parameter so a caller can resume in report-only mode.
function M.resume_turn(opts)
  opts = opts or {}
  local dir = opts.state_dir or M.state_dir()
  local order = {}
  local result = {
    order = order,
    retained = {},
    inspected = {},
    cleaned = {},
    kept = {},
  }

  -- STEP 1, always first: read every retained turn and inspect its claim.
  order[#order + 1] = "inspect-claim"
  local records = record.read_turn_records(dir)
  for _, rec in ipairs(records) do
    -- A record this path already cleaned is not a retained turn; skipping it
    -- keeps resume idempotent across restarts.
    if rec.state ~= "cleaned" then
      result.retained[#result.retained + 1] = rec
      result.inspected[#result.inspected + 1] = M.inspect_claim(rec)
    end
  end

  -- STEP 2, never before step 1: clean up only what the inspection released.
  order[#order + 1] = "cleanup"
  for i, rec in ipairs(result.retained) do
    local claim = result.inspected[i]
    if claim.open then
      -- A still-open review keeps its claim and its record. The operator
      -- inspects and force-releases; nothing here guesses the turn dead.
      result.kept[#result.kept + 1] = rec.turn_id
    else
      local release = opts.release
      if release == nil then
        local ok, jail = pcall(require, "yana.shadow.jail")
        release = ok and jail.release_claim or nil
      end
      if release and rec.claim_dir and rec.claim_dir ~= "" then
        pcall(release, rec.claim_dir)
      end
      record.write_turn_record(dir, vim.tbl_extend("force", rec, {
        state = "cleaned",
        open = false,
        at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      }))
      result.cleaned[#result.cleaned + 1] = rec.turn_id
    end
  end

  return result
end

return M
