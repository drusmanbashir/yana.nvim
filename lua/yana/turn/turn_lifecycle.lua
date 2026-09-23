-- yana: the turn lifecycle — durable turn ids, classified bundle
-- publication, the actionability predicate every durable action waits on,
-- and turn-bound callbacks.
--
-- Why this module exists (the fixed safety contract, "Async principle"):
--
--   claim committed → agent runs → upper layer sealed → walk + classify +
--   bundle published → review becomes ACTIONABLE → generation-bound accept →
--   applier re-read → write.
--
-- The panel must never block, but DISPLAY and ACTION are different things. A review may
-- open early and provisionally from the stream's declared edits, because opening
-- changes nothing durable. Every action that changes durable state waits for the
-- complete, classified, published bundle: an accept that runs before its evidence
-- exists is not a latency win, it is a write with no authority behind it.
--
-- Three things are kept apart on purpose:
--   * `begin_turn` — the turn exists, has a durable id, and is NOT actionable.
--   * `publish_bundle` — classification is complete and durable; only now does
--     the turn become actionable.
--   * `action_allowed` — the single predicate every durable action asks.
--
-- This module owns no files of its own. Durable turn records are written by
-- `yana.record`; live yanad status is the only recovery view of
-- claims/reviews.

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

M._test = M._test or {}

local function repository_marker(workspace)
  local found = vim.fs.find(".git", { path = workspace, upward = true, limit = 1 })
  if #found > 0 then
    return true
  end
  return vim.fn.filereadable(workspace .. "/HEAD") == 1
    and vim.fn.isdirectory(workspace .. "/objects") == 1
end

local function nul_records(data)
  local records = {}
  local start = 1
  while start <= #(data or "") do
    local stop = data:find("\0", start, true)
    if not stop then break end
    records[#records + 1] = data:sub(start, stop - 1)
    start = stop + 1
  end
  return records
end

--- Evidence-grade Git trackedness captured before agent execution. Unlike the
--- display badge's old empty table, this distinguishes a real non-repository
--- from a failed query so destructive classification cannot fail open.
function M.capture_tracked_evidence(workspace)
  if not workspace or workspace == "" then
    return { status = "unavailable", reason = "empty workspace", paths = {} }
  end
  if vim.fn.executable("git") ~= 1 then
    return { status = "unavailable", reason = "git unavailable", paths = {} }
  end
  if not repository_marker(workspace) then
    return { status = "no_repo", paths = {} }
  end
  if M._test.capture_tracked_failure then
    return { status = "unavailable", reason = "injected trackedness failure", paths = {} }
  end
  local prefix_result = vim.system(
    { "git", "-C", workspace, "rev-parse", "--show-prefix" },
    { text = true }
  ):wait()
  if prefix_result.code ~= 0 then
    return {
      status = "unavailable",
      reason = vim.trim(prefix_result.stderr or "git rev-parse failed"),
      paths = {},
    }
  end
  local workspace_prefix = vim.trim(prefix_result.stdout or "")
  if workspace_prefix ~= "" and workspace_prefix:sub(-1) ~= "/" then
    workspace_prefix = workspace_prefix .. "/"
  end
  local function workspace_rel(repo_rel)
    if workspace_prefix == "" then
      return repo_rel
    end
    if repo_rel:sub(1, #workspace_prefix) == workspace_prefix then
      return repo_rel:sub(#workspace_prefix + 1)
    end
    return nil
  end
  local result = vim.system(
    { "git", "-C", workspace, "ls-files", "-z", "--full-name" },
    { text = false }
  ):wait()
  if result.code ~= 0 then
    return {
      status = "unavailable",
      reason = vim.trim(result.stderr or "git ls-files failed"),
      paths = {},
    }
  end
  local set = {}
  for _, rel in ipairs(nul_records(result.stdout)) do
    local local_rel = workspace_rel(rel)
    if local_rel and local_rel ~= "" then
      set[local_rel] = true
    end
  end
  local staged = vim.system(
    { "git", "-C", workspace, "ls-files", "-z", "--stage", "--full-name" },
    { text = false }
  ):wait()
  if staged.code ~= 0 then
    return {
      status = "unavailable",
      reason = vim.trim(staged.stderr or "git ls-files --stage failed"),
      paths = {},
    }
  end
  local submodules = {}
  for _, record in ipairs(nul_records(staged.stdout)) do
    local mode, repo_rel = record:match("^(%d+) [^ ]+ %d+\t(.+)$")
    local local_rel = repo_rel and workspace_rel(repo_rel) or nil
    if mode == "160000" and local_rel and local_rel ~= "" then
      submodules[local_rel] = true
    end
  end
  return { status = "repo", paths = set, submodules = submodules }
end

-- Return only the pre-turn tracked paths, discarding evidence detail.
function M.capture_tracked(workspace)
  return M.capture_tracked_evidence(workspace).paths
end

-- Mark rel as declared this turn by setting pass.declared[rel] = true.
function M.note_declared(pass, rel)
  if pass and rel and rel ~= "" then
    pass.declared[rel] = true
  end
end

function M.tracked_preturn(pass, rel)
  return pass ~= nil and rel ~= nil and pass.tracked_preturn[rel] == true
end

-- Return true if rel was tracked pre-turn but never declared this turn.
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
  local uv = vim.uv or vim.loop
  local pid = uv and uv.os_getpid and uv.os_getpid() or 0
  local hr = uv and uv.hrtime and uv.hrtime() or 0
  return string.format(
    "%s-p%s-g%s-pid%s-ns%s-%d",
    os.date("!%Y%m%dT%H%M%SZ"),
    tostring(panel_id or 0),
    tostring(generation or 0),
    tostring(pid),
    tostring(hr),
    seq
  )
end

----------------------------------------------------------------------
-- 7a — open early, act only after the classified bundle publishes
----------------------------------------------------------------------

--- Begin a turn. The pass exists, carries its tuple, and is explicitly NOT
--- actionable: nothing has been classified yet.
---
--- opts: { panel_id, generation, stream, turn_id, workspace,
---         state_dir, declared }
function M.begin_turn(opts)
  opts = opts or {}
  local generation = opts.generation or 0
  local turn_id = opts.turn_id and tostring(opts.turn_id)
    or M.new_turn_id(opts.panel_id, generation)
  local tracked_evidence = opts.tracked_evidence or M.capture_tracked_evidence(opts.workspace)
  local pass = {
    panel = opts.panel_id,
    stream = opts.stream and tostring(opts.stream) or "unbound",
    turn_id = turn_id,
    generation = generation,
    workspace = opts.workspace,
    state_dir = opts.state_dir,
    session_id = opts.session_id,
    -- What the stream DECLARED. A provisional review may render from this; no
    -- action may be decided from it.
    declared = opts.declared or {},
    tracked_evidence = tracked_evidence,
    tracked_preturn = opts.tracked_preturn
      or tracked_evidence.paths,
    -- The classified, published bundle. nil until publication, and that nil is
    -- the whole of the actionability decision.
    bundle = nil,
    diagnostics = {},
  }
  M._passes[pass.panel] = pass
  M.persist(pass, "open")
  log.lifecycle("turn.start", {
    turn_id = pass.turn_id,
    panel = pass.panel,
    generation = pass.generation,
    stream = pass.stream,
  })
  return pass
end

--- The live pass for a panel, or nil.
function M.current(panel_id)
  return M._passes[panel_id]
end

--- Forget one finished in-memory pass. Disk cannot extend its lifetime.
function M.finish_turn(pass)
  if not pass then
    return false, "no turn pass"
  end
  log.buffer_event("turn_finished", { panel_id = pass.panel, generation = pass.generation, turn_id = pass.turn_id })
  if M._passes[pass.panel] == pass then
    M._passes[pass.panel] = nil
  end
  return true
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
--- The owner's tuple is READ FROM THE CAPTURED PASS at delivery rather than copied at
--- bind time, because callbacks are legitimately built while a review is still
--- provisional, when the bundle digest does not exist yet. A pass table is created once
--- per turn and `publish_bundle` refuses to republish a different bundle under it, so
--- the captured pass's tuple is immutable in every field that matters by the time any
--- delivery can happen. A stale callback holds turn N's pass table while the panel
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
---
--- Same resolver as claims and layers (`shadow/preview.state_root`): YANA_STATE_ROOT,
--- then XDG_STATE_HOME/yana, then the default.
function M.state_dir()
  local preview = require("yana.shadow.preview")
  return preview.state_root() .. "/turns"
end

--- Write the turn record. Durable BEFORE the process can die, not after: a
--- record written at review close would be exactly the record a crash loses.
function M.persist(pass, state)
  if not pass then
    return false, "no turn pass"
  end
  local dir = pass.state_dir or M.state_dir()
  local usage = pass.usage or {}
  return record.write_turn_record(dir, {
    turn_id = pass.turn_id,
    panel = pass.panel,
    stream = pass.stream,
    generation = pass.generation,
    bundle_digest = pass.bundle and pass.bundle.bundle_digest or nil,
    workspace = pass.workspace,
    input_tokens = usage.input_tokens,
    output_tokens = usage.output_tokens,
    cache_read_tokens = usage.cache_read_tokens,
    cache_write_tokens = usage.cache_write_tokens,
    session_id = pass.session_id or usage.session_id,
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
  log.buffer_event("turn_closed", { panel_id = pass.panel, generation = pass.generation,
    turn_id = pass.turn_id, reason = _reason, persisted = ok })
  if M._passes[pass.panel] == pass then
    M._passes[pass.panel] = nil
  end
  return ok, err
end

return M
