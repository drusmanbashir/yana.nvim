-- yana: opt-in raw stream recorder (config `debug_record`, default OFF).
--
-- When recording is on, every raw stdout line from cursor-agent is teed
-- VERBATIM to `<turn_dir>/private/stream.ndjson` and a `meta.json` sidecar
-- (argv, cwd, mode, model, timestamps, exit code, stderr, the last stream
-- event and the stop reason) is written when the process exits. Together they are a replayable turn: `tests/fake-cursor-agent`
-- plays the NDJSON back through the real `jobstart`/`emit` pipeline, and the
-- sidecar is the argv comparison target.
--
-- Why this is opt-in and why it never touches the log:
--
--   * It is per-event disk I/O, which the default configuration forbids
--     (CTL-CLEAN: a clean turn leaves `yana.log` byte-identical). Gating
--     it behind an explicit diagnostic flag is what keeps that true.
--   * The tee writes its OWN files. Nothing here ever appends to
--     `yana.log`, so even a recording turn leaves the log untouched.
--
-- Failure behaviour: recording is diagnostic, so a failure to open or write
-- degrades to "not recording" and is counted, never raised. Losing a
-- diagnostic must not cost the user their turn.
local M = {}

local uv = vim.uv or vim.loop
local config = require("yana.config")

local Rec = {}
Rec.__index = Rec

-- Fault-injection seam. Product code never sets these; the gates do, so the
-- short-write and write-failure paths are driven rather than reasoned about.
M._test = { fault = {} }

local function env_enabled()
  local raw = vim.env.YANA_DEBUG_EVENTS
  if raw == nil then
    return false
  end
  local val = tostring(raw):lower()
  return val == "1" or val == "true" or val == "yes" or val == "on"
end

--- The model the vendor actually used, taken from the stream's own
--- system/init event. Distinct from `meta.model` (what Yana requested):
--- comparing the two is the only way to catch a switch that silently did not
--- take. First write wins — the turn's opening fact, not its last word.
function Rec:note_model_actual(model)
  if self.meta.model_actual == nil and type(model) == "string" and model ~= "" then
    self.meta.model_actual = model
  end
end

function M.enabled()
  return config.options.debug_record == true or env_enabled()
end

local function fallback_dir(panel_id, gen)
  local base = vim.fn.stdpath("log") .. "/yana-record"
  return string.format(
    "%s/%s-p%s-g%s",
    base,
    os.date("%Y%m%d-%H%M%S"),
    tostring(panel_id or 0),
    tostring(gen or 0)
  )
end

--- Start recording a turn. Returns nil when recording is off, or when the
--- destination cannot be created — in both cases the caller simply has no
--- recorder and behaves exactly as before.
---
--- opts: { session, panel_id, gen, argv, cwd, mode, model, resume_session_id }
--- `session` is the shadow turn (it owns `private_dir`); without one the
--- recording lands under `stdpath("log")/yana-record/`, so `debug_record`
--- or `YANA_DEBUG_EVENTS=1`
--- still works with the shadow ladder disabled.
function M.open(opts)
  if not M.enabled() then
    return nil
  end
  opts = opts or {}
  local dir = opts.session and opts.session.private_dir or nil
  if not dir or dir == "" then
    dir = fallback_dir(opts.panel_id, opts.gen)
  end
  local ok_mk = pcall(vim.fn.mkdir, dir, "p")
  if not ok_mk then
    return nil
  end
  local stream_path = dir .. "/stream.ndjson"
  local fd = uv.fs_open(stream_path, "a", tonumber("644", 8))
  if not fd then
    return nil
  end
  local events_path = dir .. "/events.jsonl"
  local events_fd, events_open_error = uv.fs_open(events_path, "a", tonumber("644", 8))
  local self = setmetatable({
    dir = dir,
    stream_path = stream_path,
    events_path = events_path,
    meta_path = dir .. "/meta.json",
    fd = fd,
    events_fd = events_fd,
    lines = 0,
    bytes = 0,
    write_errors = 0,
    truncated = false,
    bytes_lost = 0,
    last_write_error = nil,
    events = 0,
    event_bytes = 0,
    event_write_errors = events_fd and 0 or 1,
    event_truncated = events_fd == nil,
    event_bytes_lost = 0,
    event_last_write_error = events_open_error and tostring(events_open_error) or nil,
    malformed_raw_lines = 0,
    malformed_raw_bytes = 0,
    stderr_len = 0,
    started_wall = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    started_hr = uv.hrtime(),
    meta = {
      argv = opts.argv,
      cmd = opts.argv and opts.argv[1] or nil,
      cwd = opts.cwd,
      mode = opts.mode,
      model = opts.model,
      resume_session_id = opts.resume_session_id,
      panel_id = opts.panel_id,
      gen = opts.gen,
      turn_id = opts.turn_id,
      jailed = opts.jailed and true or false,
    },
  }, Rec)
  return self
end

--- Write every byte of `data`, looping over short writes.
---
--- `uv.fs_write` returns a BYTE COUNT, not a boolean: a full pipe, a signal or
--- an ENOSPC boundary can write a prefix and return a positive number smaller
--- than the request. Treating that as success is how a truncated recording gets
--- reported as a faithful one — the stream loses a suffix, `write_errors` stays
--- zero and the sidecar claims counts nothing wrote. The repo's durable writer
--- (`diff.lua`) already loops for exactly this reason.
---
--- Returns the number of bytes actually written and, when short, the error. It
--- never raises: this runs from the stdout callback, and a diagnostic must not
--- cost the user their turn.
local function write_all(fd, data)
  local total = #data
  local written = 0
  while written < total do
    local chunk = written == 0 and data or data:sub(written + 1)
    -- Mutation/injection seam: `short_write` caps every syscall at N bytes so
    -- the partial-write path can be driven without an ENOSPC filesystem, and
    -- `fail_after` makes the next write fail outright.
    local cap = M._test.fault.short_write
    if type(cap) == "number" and cap > 0 and #chunk > cap then
      chunk = chunk:sub(1, cap)
    end
    if M._test.fault.fail_after ~= nil and written >= M._test.fault.fail_after then
      return written, "injected write failure"
    end
    local ok, n, ferr = pcall(uv.fs_write, fd, chunk, -1)
    if not ok then
      return written, tostring(n)
    end
    if type(n) ~= "number" then
      return written, tostring(ferr or "write failed")
    end
    if n <= 0 then
      return written, "zero-length write"
    end
    written = written + n
  end
  return written, nil
end

--- Tee one raw stdout line, byte for byte, with the newline `jobstart` split
--- off restored. Verbatim is the whole point: a replay must decode the same
--- bytes the production decoder saw, including anything malformed.
---
--- The counters are advanced by what was ACTUALLY written, so a short write
--- degrades the recording honestly: the partial bytes are counted, the failure
--- is counted, and `meta.json` reports both rather than the requested length.
function Rec:line(raw)
  if not self.fd or type(raw) ~= "string" then
    return
  end
  local want = #raw + 1
  local written, err = write_all(self.fd, raw .. "\n")
  self.bytes = self.bytes + written
  if written < want then
    self.write_errors = self.write_errors + 1
    self.truncated = true
    self.last_write_error = err or "short write"
    self.bytes_lost = (self.bytes_lost or 0) + (want - written)
    return
  end
  self.lines = self.lines + 1
end

--- Append one redacted decoded-event record at the UI provenance point.
--- Raw payloads, prompts, file contents and tool arguments/results never enter
--- this sidecar; `stream.ndjson` remains the opt-in verbatim replay source.
function Rec:event(event_seq, obj, stale)
  if not self.events_fd or type(obj) ~= "table" then
    return false
  end
  local safe = {
    turn_id = self.meta.turn_id,
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    event_seq = event_seq,
    type = obj.type,
    subtype = obj.subtype,
    stale = stale and true or false,
    call_id = obj.call_id,
    model_call_id = obj.model_call_id,
    timestamp_ms = obj.timestamp_ms,
  }
  local ok, encoded = pcall(vim.json.encode, safe)
  if not ok then
    self.event_write_errors = self.event_write_errors + 1
    self.event_truncated = true
    self.event_last_write_error = "event encode failed: " .. tostring(encoded)
    return false
  end
  local data = encoded .. "\n"
  local written, err = write_all(self.events_fd, data)
  self.event_bytes = self.event_bytes + written
  if written < #data then
    self.event_write_errors = self.event_write_errors + 1
    self.event_truncated = true
    self.event_bytes_lost = self.event_bytes_lost + (#data - written)
    self.event_last_write_error = err or "short event write"
    return false
  end
  self.events = self.events + 1
  return true
end

function Rec:note_decode_failure(bytes)
  self.malformed_raw_lines = self.malformed_raw_lines + 1
  self.malformed_raw_bytes = self.malformed_raw_bytes + (tonumber(bytes) or 0)
end

function Rec:note_stderr(chunk)
  if type(chunk) == "string" then
    self.stderr_len = self.stderr_len + #chunk
  end
end

--- Close the stream file and write the sidecar. Called from the exit path,
--- which already runs inside `vim.schedule`, so `vim.json.encode` is safe
--- here; nothing else in this module needs the Vim API.
function Rec:finish(info)
  info = info or {}
  if self.fd then
    pcall(uv.fs_close, self.fd)
    self.fd = nil
  end
  if self.events_fd then
    pcall(uv.fs_close, self.events_fd)
    self.events_fd = nil
  end
  local meta = self.meta
  meta.started_at = self.started_wall
  meta.finished_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  meta.duration_ms = math.floor((uv.hrtime() - self.started_hr) / 1e6)
  meta.exit_code = info.code
  meta.stderr = info.stderr
  meta.stderr_len = info.stderr and #info.stderr or self.stderr_len
  meta.stream_file = "stream.ndjson"
  meta.stream_lines = self.lines
  meta.stream_bytes = self.bytes
  meta.write_errors = self.write_errors
  -- Honest degradation: a recording that lost bytes says so, and says how
  -- many. Replay treats `truncated` as "this stream is not the whole turn"
  -- rather than discovering it as a decode failure at the end.
  meta.stream_truncated = self.truncated and true or false
  meta.stream_bytes_lost = self.bytes_lost or 0
  meta.last_write_error = self.last_write_error
  meta.event_file = "events.jsonl"
  meta.events_written = self.events
  meta.event_bytes = self.event_bytes
  meta.event_write_errors = self.event_write_errors
  meta.event_truncated = self.event_truncated and true or false
  meta.event_bytes_lost = self.event_bytes_lost
  meta.event_last_write_error = self.event_last_write_error
  meta.malformed_raw_lines = self.malformed_raw_lines
  meta.malformed_raw_bytes = self.malformed_raw_bytes
  meta.pid = info.pid
  -- LIVENESS EVIDENCE. A turn that never finished is exactly the turn whose
  -- sidecar has to say where it stopped and why: on 2026-08-20 an inline turn
  -- ended on a nested-task start and sat mute for 11 minutes, and nothing on
  -- disk named either fact. `last_event` is the decoder's own description of
  -- the last describable stream event (see agent.describe_event) and
  -- `stop_reason` is always present — a stop that recorded its reason before
  -- signalling, or the exit code.
  meta.last_event = info.last_event
  meta.stop_reason = info.stop_reason
  meta.cpu_pct_at_stop = info.cpu_pct_at_stop
  meta.stall_cause = info.stall_cause
  meta.forensics_path = info.forensics_path
  -- meta.model is the REQUESTED model (opts.model at open); meta.model_actual
  -- is what the vendor's own system/init event named. Left nil when no such
  -- event arrived (recording opened but the turn never got that far), which
  -- is itself distinguishable from "matched" by a reader.
  local ok, encoded = pcall(vim.json.encode, meta)
  if not ok then
    return false
  end
  local fd = uv.fs_open(self.meta_path, "w", tonumber("644", 8))
  if not fd then
    return false
  end
  -- The sidecar gets the same loop and the same honesty: a short sidecar write
  -- used to be ignored outright and reported as a complete recording, leaving
  -- an unparseable meta.json beside a stream that claimed to be faithful.
  local written, werr = write_all(fd, encoded)
  pcall(uv.fs_close, fd)
  if written < #encoded then
    self.write_errors = self.write_errors + 1
    self.last_write_error = werr or "short sidecar write"
    return false, self.last_write_error
  end
  return true
end

----------------------------------------------------------------------
-- durable turn records used by the turn lifecycle
----------------------------------------------------------------------
--
-- Unlike the raw stream tee above, these are NOT diagnostic and NOT opt-in.
-- They are the only thing a restarted editor has to learn that a review was
-- open when the process died, so they are written while the turn is still
-- running rather than when it finishes — a record written at review close is
-- exactly the record a crash never gets to write.
--
-- They live under `stdpath("state")`, never in the workspace and never in
-- `yana.log`, so a clean turn still leaves both untouched.
--
-- `yana.turn_lifecycle` owns their meaning; this module owns the bytes,
-- because it is where durable turn-scoped writes already live.

local function record_path(dir, turn_id)
  return dir .. "/" .. tostring(turn_id):gsub("[^%w%-%._]", "_") .. ".json"
end

--- Write (or replace) one turn record. Whole-file, so a reader never sees a
--- half-updated record, and returns the failure rather than raising: losing a
--- turn record must not cost the user their turn, but the caller is told.
function M.write_turn_record(dir, rec)
  if type(dir) ~= "string" or dir == "" or type(rec) ~= "table" or rec.turn_id == nil then
    return false, "a turn record needs a directory and a turn_id"
  end
  local ok_mk = pcall(vim.fn.mkdir, dir, "p")
  if not ok_mk then
    return false, "could not create the turn record directory: " .. dir
  end
  local ok_enc, encoded = pcall(vim.json.encode, rec)
  if not ok_enc then
    return false, "could not encode the turn record: " .. tostring(encoded)
  end
  local path = record_path(dir, rec.turn_id)
  local fd = uv.fs_open(path, "w", tonumber("644", 8))
  if not fd then
    return false, "could not open the turn record for writing: " .. path
  end
  local written, werr = write_all(fd, encoded)
  pcall(uv.fs_close, fd)
  if written < #encoded then
    return false, werr or "short turn-record write"
  end
  return true, path
end

--- Every turn record under `dir`, oldest id first. An unreadable or
--- unparseable record is REPORTED as an unreadable retained turn rather than
--- skipped: a turn whose state cannot be read is the one case where guessing
--- "nothing was owed" is most expensive.
function M.read_turn_records(dir)
  local out = {}
  if type(dir) ~= "string" or dir == "" or vim.fn.isdirectory(dir) ~= 1 then
    return out
  end
  local names = vim.fn.readdir(dir) or {}
  table.sort(names)
  for _, name in ipairs(names) do
    if name:match("%.json$") then
      local path = dir .. "/" .. name
      local f = io.open(path, "r")
      local raw = nil
      if f then
        raw = f:read("*a")
        f:close()
      end
      local ok, decoded = pcall(vim.json.decode, raw or "")
      if ok and type(decoded) == "table" and decoded.turn_id ~= nil then
        decoded.record_path = path
        out[#out + 1] = decoded
      else
        out[#out + 1] = {
          turn_id = name:gsub("%.json$", ""),
          record_path = path,
          unreadable = true,
          -- Unknown is never rounded down to released.
          open = true,
        }
      end
    end
  end
  return out
end

--- Append one JSON object as a line to `<private_dir>/stream.ndjson`.
--- Confined-shell and refusal paths use this when no cursor-agent recorder
--- is open (issue 24).
function M.append_stream_line(private_dir, obj)
  if not M.enabled() or type(private_dir) ~= "string" or private_dir == "" then
    return false
  end
  if type(obj) ~= "table" then
    return false
  end
  pcall(vim.fn.mkdir, private_dir, "p")
  local ok_enc, encoded = pcall(vim.json.encode, obj)
  if not ok_enc then
    return false
  end
  local path = private_dir .. "/stream.ndjson"
  local fd = uv.fs_open(path, "a", tonumber("644", 8))
  if not fd then
    return false
  end
  local written, _err = write_all(fd, encoded .. "\n")
  pcall(uv.fs_close, fd)
  return written == #encoded + 1
end

return M
