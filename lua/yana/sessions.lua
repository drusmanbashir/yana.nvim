-- yana: session registry + transcript persistence.
--
-- Every session used through the panel is recorded in a small JSON registry
-- (stdpath("data")/yana/sessions.json) together with a per-session
-- transcript of the rendered conversation, so sessions can be listed and
-- resumed later with their history restored.
--
-- Sessions created outside Neovim (plain `cursor-agent` in a terminal) are
-- discovered best-effort from the CLI's own chat store
-- (~/.cursor/chats/<md5(cwd)>/<session-id>/).
local config = require("yana.config")

local M = {}

local uv = vim.uv or vim.loop

----------------------------------------------------------------------
-- paths
----------------------------------------------------------------------

local function data_dir()
  local dir = config.options.sessions.dir
  if dir and dir ~= "" then
    return vim.fn.expand(dir)
  end
  return vim.fn.stdpath("data") .. "/yana"
end

local function registry_path()
  return data_dir() .. "/sessions.json"
end

local function transcripts_dir()
  return data_dir() .. "/transcripts"
end

function M.transcript_path(id)
  return transcripts_dir() .. "/" .. id .. ".md"
end

-- Exposed for the per-turn registry-consistency capture: a transcript on disk
-- with no registry row is a real observed failure (a session that cannot be
-- listed or resumed), and the capture needs the file the row should live in,
-- not just the in-memory cache that would agree with itself.
function M.registry_file()
  return registry_path()
end

----------------------------------------------------------------------
-- registry (JSON on disk)
----------------------------------------------------------------------

local _cache = nil

local function load_registry()
  if _cache then
    return _cache
  end
  _cache = {}
  local f = io.open(registry_path(), "r")
  if f then
    local raw = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, raw)
    if ok and type(decoded) == "table" then
      _cache = decoded
    end
  end
  return _cache
end

local function save_registry()
  if not _cache then
    return
  end
  vim.fn.mkdir(data_dir(), "p")
  local f = io.open(registry_path(), "w")
  if not f then
    return
  end
  f:write(vim.json.encode(_cache))
  f:close()
end

-- Upsert a session entry. entry.id is required.
-- fields: id, title, cwd, mode, model, turns
-- Monotonic tie-breaker for M.list()'s recency sort. `os.time()` has 1s
-- resolution; several sessions persisted inside one second (a fast synthetic
-- replay, or just a quick real one -- issue log row 27 measured three
-- sessions landing in the same wall-clock second) would otherwise sort in an
-- order `table.sort` does not guarantee, since it is not stable. Lazily
-- initialised from the highest `seq` already on disk, so a fresh process
-- picking the registry back up after a restart keeps counting forward
-- rather than colliding with rows an earlier process already wrote.
local _seq = nil
local function next_seq(reg)
  if not _seq then
    _seq = 0
    for _, e in pairs(reg) do
      if type(e.seq) == "number" and e.seq > _seq then
        _seq = e.seq
      end
    end
  end
  _seq = _seq + 1
  return _seq
end

function M.record(entry)
  if not entry or not entry.id or entry.id == "" then
    return
  end
  local reg = load_registry()
  local now = os.time()
  local cur = reg[entry.id] or { created_at = now }
  cur.id = entry.id
  cur.title = entry.title or cur.title
  cur.cwd = entry.cwd or cur.cwd
  cur.mode = entry.mode or cur.mode
  cur.model = entry.model or cur.model
  -- Which backend (layer 1) issued this session's upstream id. Absent on
  -- rows written before backends existed, and on CLI-discovered rows
  -- (M.discover tags those "cursor" explicitly, since that discovery only
  -- ever reads cursor-agent's own chat store) -- M.resume treats an absent
  -- backend as unknown-but-compatible rather than refusing it, since there
  -- is no evidence it belongs to a different vendor.
  cur.backend = entry.backend or cur.backend
  cur.turns = entry.turns or cur.turns
  cur.updated_at = now
  cur.seq = next_seq(reg)
  reg[entry.id] = cur
  save_registry()
end

function M.get(id)
  return load_registry()[id]
end

--- The registry row for `id` READ BACK FROM DISK — never from `_cache`.
---
--- The per-turn consistency check cannot use `M.get`: `record()` fills the
--- in-memory cache BEFORE `save_registry()` attempts the file, so a registry
--- the product could not write still answers "row present". A check built on
--- that compares the cache with itself and can never fail, which is exactly
--- what let a transcript exist on disk with no registry row — a session that
--- can be neither listed nor resumed. So this opens the file every time and
--- ignores the cache entirely, including the cache-priming `load_registry`.
---
--- Returns `(present, status)`, status one of:
---   `present`      the file parsed and holds a row for `id`
---   `absent`       the file parsed and holds no row for `id`
---   `no_file`      no registry file exists
---   `unreadable`   it exists but could not be opened or read
---   `unparseable`  it was read but is not a decodable JSON object
--- Only `present` is consistent; an unreadable or unparseable registry is a
--- failure, not a pass. Total and non-throwing — this runs off the end of a
--- real turn and observation must never break the turn it observes. One small
--- read per persist: no watcher, no per-event I/O.
function M.registry_row_on_disk(id)
  if type(id) ~= "string" or id == "" then
    return false, "absent"
  end
  local path = registry_path()
  local f = io.open(path, "r")
  if not f then
    -- "never written" and "there but unopenable" send an operator to two
    -- different places (the writer versus the permissions), so they are not
    -- collapsed into one status.
    if uv.fs_stat(path) == nil then
      return false, "no_file"
    end
    return false, "unreadable"
  end
  local read_ok, raw = pcall(f.read, f, "*a")
  pcall(f.close, f)
  if not read_ok or type(raw) ~= "string" then
    return false, "unreadable"
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    -- Includes the empty file: zero bytes is not a registry that recorded
    -- anything, and vim.json.decode throws on it.
    return false, "unparseable"
  end
  if type(decoded[id]) ~= "table" then
    return false, "absent"
  end
  return true, "present"
end

----------------------------------------------------------------------
-- transcripts
----------------------------------------------------------------------

-- Persist the rendered conversation (list of lines) for a session.
function M.save_transcript(id, lines)
  if not id or id == "" or type(lines) ~= "table" then
    return
  end
  vim.fn.mkdir(transcripts_dir(), "p")
  local f = io.open(M.transcript_path(id), "w")
  if not f then
    return
  end
  f:write(table.concat(lines, "\n"))
  f:close()
end

-- Returns the transcript as a list of lines, or nil if none saved.
function M.load_transcript(id)
  if not id or id == "" then
    return nil
  end
  local f = io.open(M.transcript_path(id), "r")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  if raw == "" then
    return nil
  end
  return vim.split(raw, "\n", { plain = true })
end

----------------------------------------------------------------------
-- discovery of CLI-created sessions (best effort)
----------------------------------------------------------------------

-- md5 hex digest via an external binary (md5sum on Linux, md5 on macOS).
-- Returns nil when neither is available; discovery is then skipped.
local function md5_hex(s)
  local out
  if vim.fn.executable("md5sum") == 1 then
    out = vim.fn.system({ "md5sum" }, s)
  elseif vim.fn.executable("md5") == 1 then
    out = vim.fn.system({ "md5" }, s)
  else
    return nil
  end
  if vim.v.shell_error ~= 0 or type(out) ~= "string" then
    return nil
  end
  local hex = out:match("%x+")
  if hex and #hex == 32 then
    return hex
  end
  return nil
end

-- Read the chat name from the CLI's store.db meta row (needs sqlite3).
-- The value is hex-encoded JSON: {"agentId":...,"name":...,...}.
local function store_title(dbpath)
  if vim.fn.executable("sqlite3") ~= 1 then
    return nil
  end
  local uri = "file:" .. dbpath .. "?mode=ro&immutable=1"
  local out = vim.fn.system({ "sqlite3", uri, "SELECT value FROM meta WHERE key='0';" })
  if vim.v.shell_error ~= 0 or type(out) ~= "string" then
    return nil
  end
  out = vim.trim(out)
  if out == "" then
    return nil
  end
  if out:match("^%x+$") and #out % 2 == 0 then
    out = out:gsub("%x%x", function(h)
      return string.char(tonumber(h, 16))
    end)
  end
  local ok, obj = pcall(vim.json.decode, out)
  if ok and type(obj) == "table" and type(obj.name) == "string" and obj.name ~= "" then
    return obj.name
  end
  return nil
end

local function read_json_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  local ok, obj = pcall(vim.json.decode, raw)
  if ok and type(obj) == "table" then
    return obj
  end
  return nil
end

-- Scan ~/.cursor/chats/<md5(cwd)>/ for sessions the CLI knows about.
-- Returns a list of { id, title, cwd, created_at, updated_at, external = true }.
--
-- The CLI names its chat directory after a hash of the RAW cwd string it saw
-- when the chat started. On a case-insensitive mount (e.g. a Linux CIFS/SMB
-- share) the exact same directory can be entered with a different letter
-- case from a different terminal/editor and hash to a different, equally
-- "valid" name that this scan would never look in -- the session silently
-- vanishes from discovery even though both spellings name one real
-- directory. Hashing fs_realpath(cwd) instead of the bare argument fixes
-- this whenever the kernel/filesystem driver resolves path components to
-- their on-disk stored spelling during lookup (true for many
-- case-insensitive-mount configurations), and also fixes the same defect
-- shape for symlinked workspace paths and a cwd carrying "..", "." or a
-- trailing slash -- all of which broke the raw-string hash identically.
-- fs_realpath can fail (e.g. cwd no longer exists); the raw string is kept
-- as a fallback rather than discovering nothing. This does not, and cannot,
-- fix the case where the CLI itself hashed an uncanonicalized cwd on ITS
-- side too (unverified, closed-source; PORT-11,
-- packets/env-portability-adversarial-20260820.md).
function M.discover(cwd)
  cwd = cwd or vim.fn.getcwd()
  local base = config.options.sessions.chats_dir or "~/.cursor/chats"
  base = vim.fn.expand(base)
  local canonical_cwd = uv.fs_realpath(cwd) or cwd
  local hash = md5_hex(canonical_cwd)
  if not hash then
    return {}
  end
  local dir = base .. "/" .. hash
  local handle = uv.fs_scandir(dir)
  if not handle then
    return {}
  end

  local out = {}
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "directory" then
      local meta = read_json_file(dir .. "/" .. name .. "/meta.json")
      if meta and meta.hasConversation then
        table.insert(out, {
          id = name,
          title = store_title(dir .. "/" .. name .. "/store.db"),
          cwd = cwd,
          created_at = meta.createdAtMs and math.floor(meta.createdAtMs / 1000) or nil,
          updated_at = meta.updatedAtMs and math.floor(meta.updatedAtMs / 1000) or nil,
          external = true,
          -- This scan only ever reads cursor-agent's OWN chat store
          -- (~/.cursor/chats), so every discovered session is a cursor
          -- session by construction.
          backend = "cursor",
        })
      end
    end
  end
  return out
end

----------------------------------------------------------------------
-- listing
----------------------------------------------------------------------

-- All known sessions for a cwd (registry + discovered), most recent first.
function M.list(cwd)
  cwd = cwd or vim.fn.getcwd()
  local by_id = {}
  local out = {}

  for id, entry in pairs(load_registry()) do
    if entry.cwd == cwd then
      by_id[id] = entry
      table.insert(out, entry)
    end
  end

  local ok, discovered = pcall(M.discover, cwd)
  if ok then
    for _, entry in ipairs(discovered) do
      local known = by_id[entry.id]
      if known then
        -- Registry wins for title/mode/model but take the CLI's fresher
        -- timestamp if it has one.
        if entry.updated_at and (not known.updated_at or entry.updated_at > known.updated_at) then
          known.updated_at = entry.updated_at
        end
      else
        by_id[entry.id] = entry
        table.insert(out, entry)
      end
    end
  end

  table.sort(out, function(a, b)
    local au, bu = (a.updated_at or a.created_at or 0), (b.updated_at or b.created_at or 0)
    if au ~= bu then
      return au > bu
    end
    -- Same second: `seq` is the tie-break (see next_seq's docstring). A
    -- discovered (CLI-only) entry carries no seq and sorts after anything
    -- this process actually recorded in that same second -- we know their
    -- relative order exactly and only guess at the discovered one's.
    return (a.seq or 0) > (b.seq or 0)
  end)

  local max = config.options.sessions.max or 50
  while #out > max do
    table.remove(out)
  end
  return out
end

-- Short human "time ago" for pickers.
function M.time_ago(ts)
  if not ts then
    return "?"
  end
  local d = os.time() - ts
  if d < 0 then
    d = 0
  end
  if d < 60 then
    return d .. "s ago"
  elseif d < 3600 then
    return math.floor(d / 60) .. "m ago"
  elseif d < 86400 then
    return math.floor(d / 3600) .. "h ago"
  end
  return math.floor(d / 86400) .. "d ago"
end

-- One-line label for a session entry in pickers.
function M.format(entry)
  local title = entry.title
  if not title or title == "" or title == "New Agent" then
    title = "(untitled) " .. tostring(entry.id):sub(1, 8)
  end
  if #title > 48 then
    title = title:sub(1, 47) .. "…"
  end
  local bits = { title, M.time_ago(entry.updated_at or entry.created_at) }
  if entry.turns and entry.turns > 0 then
    table.insert(bits, entry.turns .. " turn" .. (entry.turns == 1 and "" or "s"))
  end
  if entry.external then
    table.insert(bits, "cli")
  end
  -- `entry.review_open` is a transient decoration the caller sets on the
  -- entry table before formatting (see yana.ui M.session_history) -- never
  -- persisted here, so it can never go stale: claims serialize, so at most
  -- the single most-recent session for a workspace can ever be the one an
  -- open claim belongs to, and it is read fresh from the claim every time.
  if entry.review_open then
    table.insert(bits, "review open")
  end
  return table.concat(bits, "  · ")
end

-- Derive a session title from the first prompt of a conversation.
function M.title_from_prompt(prompt)
  local first = vim.split(prompt or "", "\n", { plain = true })[1] or ""
  first = vim.trim(first)
  if #first > 60 then
    first = first:sub(1, 59) .. "…"
  end
  return first ~= "" and first or nil
end

----------------------------------------------------------------------
-- delete
----------------------------------------------------------------------

--- Forget one session: registry row, transcript, and CLI chat dir when present.
--- Returns true when something was removed.
function M.delete(id, cwd)
  if not id or id == "" then
    return false
  end
  cwd = cwd or vim.fn.getcwd()
  local removed = false
  local reg = load_registry()
  if reg[id] ~= nil then
    reg[id] = nil
    save_registry()
    removed = true
  end
  local transcript = M.transcript_path(id)
  if uv.fs_stat(transcript) then
    pcall(vim.fn.delete, transcript)
    removed = true
  end
  local base = config.options.sessions.chats_dir or "~/.cursor/chats"
  base = vim.fn.expand(base)
  local canonical_cwd = uv.fs_realpath(cwd) or cwd
  local hash = md5_hex(canonical_cwd)
  if hash then
    local dir = base .. "/" .. hash .. "/" .. id
    if uv.fs_stat(dir) then
      pcall(vim.fn.delete, dir, "rf")
      removed = true
    end
  end
  return removed
end

--- Delete every listed session for `cwd` (registry + discovered). Returns count.
function M.delete_all(cwd)
  cwd = cwd or vim.fn.getcwd()
  local list = M.list(cwd)
  for _, entry in ipairs(list) do
    M.delete(entry.id, cwd)
  end
  return #list
end

return M
