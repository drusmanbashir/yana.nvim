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

local flush = require("yana.safety.flush")
local uv = vim.uv or vim.loop

local function log_path()
  local dir = vim.fn.stdpath("log")
  vim.fn.mkdir(dir, "p")
  return dir .. "/yana.log"
end

M.path = log_path()

-- Mirrors vim.log.levels (TRACE=0..ERROR=3), plus OFF -- same names as
-- $VIMRUNTIME's vim.lsp.log.levels. M.levels.WARN is the number; use
-- NAME_TO_LEVEL/LEVEL_NAME below for number<->string in write()/set_level().
M.levels = vim.deepcopy(vim.log.levels)
M.levels.OFF = 4

local LEVEL_NAME = {
  [vim.log.levels.TRACE] = "TRACE",
  [vim.log.levels.DEBUG] = "DEBUG",
  [vim.log.levels.INFO] = "INFO",
  [vim.log.levels.WARN] = "WARN",
  [vim.log.levels.ERROR] = "ERROR",
}
local NAME_TO_LEVEL = {}
for nr, name in pairs(LEVEL_NAME) do
  NAME_TO_LEVEL[name] = nr
end

-- Minimum level that actually reaches disk. Matches vim.lsp.log's default.
local current_level = vim.log.levels.WARN

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

function M.durable_healthy()
  return not durable_unhealthy
end

function M.durable_unhealthy_reason()
  return durable_unhealthy_reason
end

M._test = M._test or {}

function M._test.reset_durable_health()
  durable_unhealthy = false
  durable_unhealthy_reason = nil
  durable_unhealthy_notified = false
end

-- Accepts a level name ("WARN") or number (vim.log.levels.WARN), same
-- calling convention as vim.lsp.log.set_level.
function M.set_level(level)
  if type(level) == "string" then
    local nr = M.levels[level:upper()]
    assert(nr, string.format("Invalid log level: %q", level))
    current_level = nr
  else
    assert(LEVEL_NAME[level] or level == M.levels.OFF, string.format("Invalid log level: %s", tostring(level)))
    current_level = level
  end
end

function M.get_level()
  return current_level
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

local function append_record(level, msg, bypass_level)
  local nr, name = normalize_level(level)
  if not bypass_level and nr < current_level then
    return true
  end
  rotate_if_large()
  local body = tostring(msg):gsub("\n", "\n    ")
  local line = string.format("%s [%-5s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), name, body)
  local fd = uv.fs_open(M.path, "a", tonumber("644", 8))
  if not fd then
    mark_durable_unhealthy("could not open durable log at " .. tostring(M.path))
    return false
  end
  local nbytes = #line
  local written, write_err = uv.fs_write(fd, line, -1)
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

-- Append a single record. Multi-line messages are indented so each record
-- stays visually grouped in the log. `level` is checked against the
-- configured minimum before the line is even formatted (mirrors
-- vim.lsp.log's create_logger: cost is skipped entirely below threshold).
function M.write(level, msg)
  -- Off the operator's event loop, same flush, same place in the sequence
  -- (`safety/flush.lua`). This one sits inside `log.guard`, which wraps every
  -- review keymap, so an accept that warns or refuses used to freeze the editor
  -- for a whole fsync on top of whatever else it had already paid.
  return append_record(level, msg, false)
end

-- The event-type key `lifecycle_line` itself writes into `payload`. A caller
-- field of the same name must never reach the merge below unrenamed: it
-- would silently overwrite the type this row is filed under, and a caller
-- has no way to know that "kind" is reserved. Renaming (not dropping) is the
-- less surprising choice of the two guards -- both facts survive: the event
-- keeps its real type, and the caller's value is still findable, just under
-- its own key.
local LIFECYCLE_TYPE_KEY = "kind"
local LIFECYCLE_TYPE_COLLISION_KEY = "row_kind"

local function lifecycle_line(kind, fields)
  local payload = {
    kind = tostring(kind or "unknown"),
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
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

local function lifecycle_enabled()
  local raw = vim.env.YANA_LIFECYCLE_LOG
  if raw == nil then
    return false
  end
  raw = tostring(raw):lower()
  return raw == "1" or raw == "true" or raw == "yes" or raw == "on"
end

function M.lifecycle(kind, fields)
  if not lifecycle_enabled() then
    return true
  end
  local line, err = lifecycle_line(kind, fields)
  if not line then
    return append_record("WARN", "yana.lifecycle encode failed: " .. tostring(err), false)
  end
  return append_record("INFO", line, true)
end

function M.lifecycle_later(kind, fields)
  if not lifecycle_enabled() then
    return true
  end
  local line, err = lifecycle_line(kind, fields)
  if not line then
    return append_record("WARN", "yana.lifecycle encode failed: " .. tostring(err), false)
  end
  vim.schedule(function()
    append_record("INFO", line, true)
  end)
  return true
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

-- Open the log file in a split for inspection.
function M.open()
  vim.cmd("split " .. vim.fn.fnameescape(M.path))
  vim.bo.filetype = "log"
end

return M
