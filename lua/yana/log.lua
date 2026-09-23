-- yana: lightweight error/warning logger + async guard.
--
-- Purpose: capture the transient "red flash" errors/warnings that appear for a
-- second while the agent is processing and then vanish, so they can be read
-- after the fact (:YanaLog / :checkhealth yana).
--
-- Designed to stay off the hot path:
--   * INFO notifications forward to vim.notify with no disk I/O.
--   * Only WARN/ERROR are written, and those are rare.
--   * guard() adds negligible xpcall overhead on the success path and re-raises
--     on failure so runtime behaviour is unchanged: the error still surfaces,
--     but is now also persisted with a full traceback.

local M = {}

-- Disabled observers read no editor state. Diagnostic failure cannot change
-- the result of the operation supplying these synchronous observations.
local buffer_observer
function M.observe_buffers(observer)
  buffer_observer = observer
end

function M.buffer_event(point, facts)
  if not buffer_observer then return end
  local ok, err = pcall(buffer_observer, point, facts or {})
  if not ok then pcall(M.write, "WARN", "buffer snapshot capture_failed: " .. tostring(err)) end
end

local flush = require("yana.safety.flush")
local uv = vim.uv or vim.loop

local function log_path()
  local dir = vim.fn.stdpath("log")
  vim.fn.mkdir(dir, "p")
  return dir .. "/yana.log"
end

M.path = log_path()

-- Mirrors vim.log.levels (TRACE=0..ERROR=4 on this Neovim), plus OFF -- same
-- names as $VIMRUNTIME's vim.lsp.log.levels (also TRACE=0..ERROR=4, OFF=5).
-- M.levels.WARN is the number; use NAME_TO_LEVEL/LEVEL_NAME below for
-- number<->string in write()/set_level().
--
-- OFF is taken from vim.log.levels itself when present (current Neovim already defines
-- it, at 5) and computed as one past ERROR only as a fallback for a Neovim old enough
-- to lack it. Never re-hardcode this without first checking it cannot equal
-- vim.log.levels.ERROR.
M.levels = vim.deepcopy(vim.log.levels)
if M.levels.OFF == nil then
  M.levels.OFF = (vim.log.levels.ERROR or 4) + 1
end

local LEVEL_NAME = {
  [vim.log.levels.TRACE] = "TRACE",
  [vim.log.levels.DEBUG] = "DEBUG",
  [vim.log.levels.INFO] = "INFO",
  [vim.log.levels.WARN] = "WARN",
  [vim.log.levels.ERROR] = "ERROR",
  [M.levels.OFF] = "OFF",
}
local NAME_TO_LEVEL = {}
for nr, name in pairs(LEVEL_NAME) do
  NAME_TO_LEVEL[name] = nr
end

-- Minimum level that actually reaches disk (vim.log.levels threshold).
-- A record writes iff its severity number >= this floor (DEBUG < INFO < WARN
-- < ERROR). Operator default `info` → vim.log.levels.INFO.
local current_level = vim.log.levels.INFO
-- Closed-set name mirroring current_level (error|warn|info|debug).
local current_config_level = "info"

-- Maps the four standard names onto vim.log.levels (not a parallel scale).
local CONFIG_TO_NR = {
  error = vim.log.levels.ERROR,
  warn = vim.log.levels.WARN,
  info = vim.log.levels.INFO,
  debug = vim.log.levels.DEBUG,
}

--- Canonical lowercase name for the closed config set, or nil if invalid.
--- Accepts the four names in any case, plus legacy WARN/ERROR/INFO/DEBUG.
function M.canonicalize_config_level(level)
  if type(level) ~= "string" then
    return nil
  end
  local low = level:lower()
  if CONFIG_TO_NR[low] then
    return low
  end
  local up = level:upper()
  if up == "ERROR" then
    return "error"
  elseif up == "WARN" or up == "WARNING" then
    return "warn"
  elseif up == "INFO" then
    return "info"
  elseif up == "DEBUG" then
    return "debug"
  end
  return nil
end

--- Sorted closed-set names for refusals and command completion.
function M.config_level_names()
  return { "debug", "error", "info", "warn" }
end

--- Human-readable name for a level number. Prefers the closed-set name when
--- the number matches error|warn|info|debug.
function M.level_name(nr)
  for name, n in pairs(CONFIG_TO_NR) do
    if n == nr then
      return name
    end
  end
  return LEVEL_NAME[nr] or tostring(nr)
end

--- Sorted list of every accepted level name for legacy callers; the
--- operator-facing closed set is `config_level_names()`.
function M.level_names()
  return M.config_level_names()
end

local durable_unhealthy = false
local durable_unhealthy_reason = nil
local durable_unhealthy_notified = false

local function mark_durable_unhealthy(reason)
  if durable_unhealthy then
    return
  end
  durable_unhealthy = true
  durable_unhealthy_reason = tostring(reason)
  local function notify_once()
    if durable_unhealthy_notified then
      return
    end
    durable_unhealthy_notified = true
    vim.notify(
      "yana: durable log is unhealthy — " .. durable_unhealthy_reason,
      vim.log.levels.ERROR,
      { title = "Yana" }
    )
  end
  if vim.in_fast_event() then
    vim.schedule(notify_once)
  else
    notify_once()
  end
end

-- Return true if the durable log is healthy (no write/fsync failure).
function M.durable_healthy()
  return not durable_unhealthy
end

-- Return the reason string for the last durable-log failure, or nil.
function M.durable_unhealthy_reason()
  return durable_unhealthy_reason
end

M._test = M._test or {}

-- Test-only: reset durable-log health flags back to healthy/unnotified.
function M._test.reset_durable_health()
  durable_unhealthy = false
  durable_unhealthy_reason = nil
  durable_unhealthy_notified = false
end

-- Accepts a closed-set name ("info"/"debug"/…) or legacy WARN/DEBUG string.
function M.set_level(level)
  local name = M.canonicalize_config_level(level)
  assert(name, string.format("Invalid log level: %q", tostring(level)))
  current_config_level = name
  current_level = CONFIG_TO_NR[name]
  pcall(function()
    local config = require("yana.config")
    if type(config.options) == "table" then
      config.options.log_level = name
    end
  end)
end

-- Return the current minimum log level number.
function M.get_level()
  return current_level
end

-- Return the current closed-set config name ("info", "debug", …).
function M.get_config_level()
  return current_config_level
end

-- Cap the log file at ~5MB: once past it, rotate the whole file to
-- <path>.old (overwriting any previous .old) and start fresh. This is a
-- much chattier per-error log than LSP's (guard() writes on every caught
-- error, not just RPC traffic), so -- unlike LSP's log, which only WARNS
-- past 1GB and never rotates -- an unbounded file here is a real disk-fill
-- risk, so this rotates instead of just warning.
local MAX_BYTES = 5 * 1024 * 1024

local function rotate_if_large()
  local stat = uv.fs_stat(M.path)
  if stat and stat.size > MAX_BYTES then
    uv.fs_unlink(M.path .. ".old")
    uv.fs_rename(M.path, M.path .. ".old")
  end
end

local function normalize_level(level)
  if type(level) == "number" then
    return level, LEVEL_NAME[level] or tostring(level)
  end
  local name = tostring(level or "ERROR"):upper()
  return NAME_TO_LEVEL[name] or vim.log.levels.ERROR, name
end

-- ONE CLOCK FOR THE WHOLE FILE. Every record line is stamped to the
-- millisecond off `uv.gettimeofday()` -- the SAME call the lifecycle rows'
-- `at_ms` field uses (`lifecycle_line` below), so a line's own stamp and the
-- `at_ms` inside it are the same instant read microseconds apart, and never
-- two clocks that can drift.
--
-- It used to be `os.date("%Y-%m-%d %H:%M:%S")`, a whole second. A reader that
-- has to order a logged line against a keypress -- the screen recorder in
-- tests/headless/xrec, whose gestures are paced in tens of milliseconds --
-- could not do it from the line at all, and had to bracket the line between
-- the product's own `at_ms` stamps either side of it; when the product stamped
-- nothing before the line that bracket was a whole second wide, and on bug 7
-- it named the wrong deciding frame. The millisecond here is the fact those
-- brackets were approximating.
local function stamp()
  local s, us = uv.gettimeofday()
  return string.format("%s.%03d", os.date("%Y-%m-%d %H:%M:%S", s), math.floor((us or 0) / 1000))
end

-- ONE DURABLE WRITE, whatever is being written: one open, one write, one fsync,
-- one close. `payload` is already-formatted record bytes -- one line or many
-- concatenated -- so a caller that has to batch (see M.append_lines) pays ONE
-- fsync for the batch instead of one per line.
local function write_durable(payload)
  rotate_if_large()
  local fd = uv.fs_open(M.path, "a", tonumber("644", 8))
  if not fd then
    mark_durable_unhealthy("could not open durable log at " .. tostring(M.path))
    return false
  end
  local nbytes = #payload
  local written, write_err = uv.fs_write(fd, payload, -1)
  if not written or write_err or written ~= nbytes then
    uv.fs_close(fd)
    mark_durable_unhealthy("durable log write failed: " .. tostring(write_err))
    return false
  end
  local sync_ok, sync_err = flush.fsync(fd)
  uv.fs_close(fd)
  if not sync_ok or sync_err then
    mark_durable_unhealthy("durable log fsync failed: " .. tostring(sync_err))
    return false
  end
  return true
end

-- The bytes of one record. Multi-line messages are indented so each record
-- stays visually grouped in the log.
local function record_line(level_name, msg)
  local body = tostring(msg):gsub("\n", "\n    ")
  return string.format("%s [%-5s] %s\n", stamp(), level_name, body)
end

-- BEFORE THE NEXT RECORD REACHES DISK. A caller that holds records of its own in
-- memory registers here and writes them out when this fires, so ORDER IN THE
-- FILE IS ORDER OF EVENTS even though its records were not written as they
-- happened. Nothing else may live here: a hook is not a place to decide, log or
-- notify, and a raising hook must not be able to lose the record that triggered
-- it, so each one is called under pcall and its failure is silent to the caller.
--
-- Re-entrancy: a hook writes through M.append_lines, which does NOT run hooks,
-- and the guard below makes a hook that reaches M.write anyway a no-op rather
-- than an unbounded recursion.
local before_append = {}
local running_hooks = false

--- Register `fn` to run immediately before the next record is written.
function M.before_append(fn)
  before_append[#before_append + 1] = fn
end

local function run_before_append()
  if running_hooks or #before_append == 0 then
    return
  end
  running_hooks = true
  for _, fn in ipairs(before_append) do
    pcall(fn)
  end
  running_hooks = false
end

local function append_record(level, msg, bypass_level)
  local nr, name = normalize_level(level)
  if not bypass_level and nr < current_level then
    return true
  end
  -- Stamped BEFORE the hooks run, so this record's own instant is when it was
  -- asked for and not when somebody else's backlog finished draining; the
  -- backlog is older, so it still lands above this line in the file.
  local line = record_line(name, msg)
  run_before_append()
  return write_durable(line)
end

--- Append already-formatted record lines (each ending in "\n") in ONE durable
--- write, in list order. The threshold is not re-checked: these bytes were
--- formatted by M.lifecycle_record, which is the decision point. Runs no
--- before_append hooks -- this IS what those hooks call.
function M.append_lines(lines)
  if type(lines) ~= "table" or #lines == 0 then
    return true
  end
  return write_durable(table.concat(lines))
end

-- Append a single record. Multi-line messages are indented so each record
-- stays visually grouped in the log. `level` is checked against the
-- configured minimum before the line is even formatted (mirrors
-- vim.lsp.log's create_logger: cost is skipped entirely below threshold).
function M.write(level, msg)
  -- Off the operator's event loop, same flush, same place in the sequence
  -- (`safety/flush.lua`).
  return append_record(level, msg, false)
end

-- The event-type key `lifecycle_line` itself writes into `payload`. A caller field of
-- the same name must never reach the merge below unrenamed: it would silently overwrite
-- the type this row is filed under, and a caller has no way to know that "kind" is
-- reserved. Renaming (not dropping) is the less surprising choice of the two guards --
-- both facts survive: the event keeps its real type, and the caller's value is still
-- findable, just under its own key.
local LIFECYCLE_TYPE_KEY = "kind"
local LIFECYCLE_TYPE_COLLISION_KEY = "row_kind"

local event_seq = 0
local log_session = tostring(uv.os_getpid()) .. ":" .. tostring(uv.hrtime())

local function lifecycle_line(kind, fields)
  event_seq = event_seq + 1
  -- Additive millisecond epoch alongside the existing second-resolution
  -- `at`, which stays byte-identical. vim.uv falls back to vim.loop on
  -- older builds (module-level `uv` above already resolves this).
  local s, us = uv.gettimeofday()
  local payload = {
    kind = tostring(kind or "unknown"),
    log_session = log_session,
    log_seq = event_seq,
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    at_ms = s * 1000 + math.floor((us or 0) / 1000),
  }
  for k, v in pairs(fields or {}) do
    if v ~= nil then
      if k == LIFECYCLE_TYPE_KEY then
        payload[LIFECYCLE_TYPE_COLLISION_KEY] = v
      else
        payload[k] = v
      end
    end
  end
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return nil, tostring(encoded)
  end
  return "yana.lifecycle " .. encoded
end

--- The exact bytes `M.lifecycle_info(kind, fields)` would write, stamped NOW,
--- WITHOUT writing them. For a caller that must capture an instant on a hot path
--- and pay the durable write later, in one batch, through M.append_lines.
--- Returns nil plus the encode error when the fields do not encode.
function M.lifecycle_record(kind, fields)
  local line, err = lifecycle_line(kind, fields)
  if not line then
    return nil, err
  end
  return record_line("INFO", line)
end

local function lifecycle_harness_override()
  -- YANA_LIFECYCLE_LOG is harness-only: on → write lifecycle even when the
  -- configured threshold would filter DEBUG; off → suppress even at debug.
  -- Unset → plain DEBUG severity through append_record's threshold.
  local raw = vim.env.YANA_LIFECYCLE_LOG
  if raw == nil then
    return nil
  end
  raw = tostring(raw):lower()
  if raw == "1" or raw == "true" or raw == "yes" or raw == "on" then
    return true
  end
  if raw == "0" or raw == "false" or raw == "no" or raw == "off" then
    return false
  end
  return nil
end

-- True only when a DEBUG lifecycle row can reach disk. Expensive diagnostic
-- capture points use this before gathering state; lifecycle() remains the
-- sole writer and repeats the policy check before append.
function M.lifecycle_enabled()
  local force = lifecycle_harness_override()
  if force ~= nil then
    return force
  end
  return current_level <= vim.log.levels.DEBUG
end

-- Full undo-tree snapshots are materially heavier than ordinary lifecycle
-- rows. The headless harness enables lifecycle logging globally, so keep this
-- diagnostic on the real debug threshold unless a focused probe opts in.
function M.undo_trace_enabled()
  local raw = vim.env.YANA_UNDO_TRACE
  if raw ~= nil then
    raw = tostring(raw):lower()
    return raw == "1" or raw == "true" or raw == "yes" or raw == "on"
  end
  return current_level <= vim.log.levels.DEBUG
end

-- Lifecycle rows are plain DEBUG-severity messages (standard threshold).
-- No separate "lifecycle category" gate.
function M.lifecycle(kind, fields)
  local force = lifecycle_harness_override()
  if force == false then
    return true
  end
  local line, err = lifecycle_line(kind, fields)
  if not line then
    return append_record("WARN", "yana.lifecycle encode failed: " .. tostring(err), false)
  end
  return append_record("DEBUG", line, force == true)
end

-- Like M.lifecycle, but defers the write via vim.schedule.
function M.lifecycle_later(kind, fields)
  local force = lifecycle_harness_override()
  if force == false then
    return true
  end
  local line, err = lifecycle_line(kind, fields)
  if not line then
    return append_record("WARN", "yana.lifecycle encode failed: " .. tostring(err), false)
  end
  if force ~= true and current_level > vim.log.levels.DEBUG then return true end
  -- Freeze the outer timestamp too; deferred writes retain capture order via event_seq.
  local frozen = record_line("DEBUG", line)
  vim.schedule(function()
    run_before_append()
    write_durable(frozen)
  end)
  return true
end

-- Same structured-record shape as M.lifecycle, but at INFO severity: for the
-- rare rows that ARE a state transition (RFC 5424 honestly used), not a
-- boundary crossing -- e.g. ledger membership changes. Unlike DEBUG lifecycle
-- rows, INFO passes the default threshold and writes without
-- YANA_LIFECYCLE_LOG; the harness override still forces or suppresses it.
function M.lifecycle_info(kind, fields)
  local force = lifecycle_harness_override()
  if force == false then
    return true
  end
  local line, err = lifecycle_line(kind, fields)
  if not line then
    return append_record("WARN", "yana.lifecycle encode failed: " .. tostring(err), false)
  end
  return append_record("INFO", line, force == true)
end

-- Drop-in replacement for vim.notify used across the plugin. WARN/ERROR are
-- logged (subject to the configured minimum level); everything is forwarded
-- to the real vim.notify unchanged.
function M.notify(msg, level, opts)
  level = level or vim.log.levels.INFO
  if level >= vim.log.levels.WARN then
    M.write(LEVEL_NAME[level] or tostring(level), msg)
  end
  return vim.notify(msg, level, opts)
end

-- Run fn(...) protected. On error the context label + message + traceback are
-- logged, then the error is re-raised (error level 0) so behaviour is unchanged.
function M.guard(context, fn, ...)
  local args = { ... }
  local n = select("#", ...)
  local ok, err = xpcall(function()
    return fn(unpack(args, 1, n))
  end, function(e)
    M.write("ERROR", context .. ": " .. tostring(e) .. "\n" .. debug.traceback("", 2))
    return e
  end)
  if not ok then
    error(err, 0)
  end
end

-- Return the last n log lines (newest last), for :checkhealth / :YanaLog.
function M.recent(n)
  n = n or 20
  local f = io.open(M.path, "r")
  if not f then
    return {}
  end
  local all = {}
  for l in f:lines() do
    all[#all + 1] = l
  end
  f:close()
  local out = {}
  for i = math.max(1, #all - n + 1), #all do
    out[#out + 1] = all[i]
  end
  return out
end

-- Open the log file in a split for inspection (:YanaLog, like :LspLog). No record has
-- been written yet on a fresh install/state root, or after rotation started a new file
-- -- that is reported (never a raw Vim error about a missing file) and no split is
-- opened, since there is nothing to show. When the file exists, the split lands
-- non-modifiable (this is a log, not scratch) and jumps to the last line so the newest
-- records are what the operator sees first, exactly like :LspLog.
function M.open()
  if not uv.fs_stat(M.path) then
    vim.notify("yana: no log file yet at " .. M.path, vim.log.levels.INFO, { title = "Yana" })
    return
  end
  vim.cmd("split " .. vim.fn.fnameescape(M.path))
  vim.bo.filetype = "log"
  vim.bo.modifiable = false
  vim.cmd("normal! G")
end

return M
