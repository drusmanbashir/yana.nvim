-- yana: normalizes a non-cursor vendor's JSONL event stream into cursor-agent's
-- own event shape, so `lua/yana/ui.lua`'s `on_event_body` (the ONLY place the
-- panel learns "a file changed": `obj.type == "tool_call"` /
-- `obj.subtype == "completed"` -> `diff.parse_tool` -> `diff.change_from_payload`)
-- renders every vendor exactly as it renders cursor-agent, without knowing any
-- vendor exists.
--
--
-- 1. Once per turn, BEFORE `local function emit(line)` is defined
--    (agent.lua ~line 617), create ONE normalizer state for the whole turn:
--
--        local vs = require("yana.vendor_stream")
--        local bd = config.backend_descriptor(config.options.backend) or {}
--        local vstate = vs.new_state({ protocol = bd.stream_protocol or "cursor", cwd = req.cwd })
--
-- 2. Inside `emit(line)`, the single line
--
--        log.guard("yana.agent on_event", req.on_event, obj)
--
--    becomes
--
--        for _, ev in ipairs(vs.normalize(vstate, obj)) do
--          log.guard("yana.agent on_event", req.on_event, ev)
--        end
--
--
-- CONTRACT (V2-1, the VENDORS work order)
--   local vs = require("yana.vendor_stream")
--   local state = vs.new_state({ protocol = "claude", cwd = <turn cwd> })
--   local events = vs.normalize(state, obj)  -- obj = one decoded vendor line
--   -- returns a LIST (possibly empty) of cursor-shaped event tables, in order
--
-- - PURE with respect to the process: no `jobstart`, no `system()`, no git subprocess,
-- no blocking I/O on the event path. The python probe this module ports
-- (`tests/bin/claude_stream_translate.py`) shelled out to `git show HEAD:...` for
-- deleted-file content; that lookup is NOT ported. Deletion narration uses the in-state
-- content cache only, and omits `prevContent` when the cache has nothing.
--
-- BINDING CONTRACT: `file_change_count`.
--
-- For cursor the count is of recognised file-affecting tool-call ENVELOPE NAMES on
-- `tool_call`/`completed` events (the same ToolCall$ member `agent.lua`'s
-- `tool_member()` already pulls). That is deliberate and separate from
-- `diff.change_from_payload()`: ATTEMPTED vs SHOWN must not share an origin, or "agent
-- wrote N times but review shows zero" becomes comparing a number with itself.

local M = {}

-- vim.json.decode turns a JSON `null` into `vim.NIL` (a userdata sentinel),
-- NOT Lua `nil`. Every field read off a vendor's decoded payload that might
-- legitimately be JSON null (claude's `originalFile` on a create, most
-- prominently) MUST be passed through this before an `== nil` / `~= nil`
-- check, or a create is misread as having prior content (the exact trap
-- V2-2 names: "A create MUST OMIT beforeFullFileContent entirely").
local function nilify(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

local function now_ms()
  return os.time() * 1000
end

-- claude's `timestamp` is ISO-8601 with a trailing `Z` (UTC), optionally
-- with fractional seconds, e.g. "2026-08-21T10:15:23.456Z". `os.time()`
-- interprets its table argument as LOCAL time, so the local/UTC offset
-- (computed once per call from a known instant, cheap and DST-safe) is
-- subtracted back out.
local function iso_to_ms(ts)
  if type(ts) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s, frac = ts:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)%.?(%d*)")
  if not y then
    return nil
  end
  local ok, epoch_local = pcall(os.time, {
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  if not ok or not epoch_local then
    return nil
  end
  local now = os.time()
  local utc_now = os.time(os.date("!*t", now))
  local ms = (epoch_local + (now - utc_now)) * 1000
  if frac ~= "" then
    ms = ms + math.floor(tonumber("0." .. frac) * 1000 + 0.5)
  end
  return ms
end

-- Stamp `timestamp_ms` on every forwarded event, derived from the vendor's
-- ISO `timestamp`, falling back to wall clock. Never invent `model_call_id`
-- (ui.lua's live-text dedup rule keys on its absence; see the module header
-- of claude_stream_translate.py for the full account of why this restores
-- live streaming without touching cursor's own dedup rule).
local function stamp_timestamp_ms(obj)
  if obj.timestamp_ms == nil or obj.timestamp_ms == vim.NIL then
    obj.timestamp_ms = iso_to_ms(obj.timestamp) or now_ms()
  end
end

-- claude protocol (V2-2) moved to vendor_stream_claude.lua (: per- vendor
-- shape tables vs the shared state machine).
local vendor_stream_claude = require("yana.vendor_stream_claude").new({
  nilify = nilify,
  stamp_timestamp_ms = stamp_timestamp_ms,
})
local normalize_claude = vendor_stream_claude.normalize

--------------------------------------------------------------------------
-- Nothing here may let an unrecognised shape produce a change row.
--------------------------------------------------------------------------

local function codex_item_completed(state, obj)
  local item = obj.item
  if type(item) ~= "table" then
    state.unknown_count = state.unknown_count + 1
    return {}
  end
  local ts = obj.timestamp_ms
  local itype = item.type
  if itype == "agent_message" then
    local text = item.text or item.message or item.content
    return { { type = "assistant", message = { content = { { type = "text", text = text } } }, timestamp_ms = ts } }
  end
  if itype == "reasoning" then
    local text = item.text or item.content
    return { { type = "assistant", message = { content = { { type = "thinking", text = text } } }, timestamp_ms = ts } }
  end
  if itype == "command_execution" then
    local exit_code = item.exit_code
    local result
    if type(exit_code) == "number" and exit_code ~= 0 then
      result = { failure = { exitCode = exit_code } }
    else
      result = { success = { exitCode = exit_code or 0 } }
    end
    return {
      {
        type = "tool_call",
        subtype = "completed",
        call_id = item.id,
        tool_call = { shellToolCall = { args = { command = item.command }, result = result } },
        timestamp_ms = ts,
      },
    }
  end
  if itype == "file_change" then
    -- Note-only by construction: no diffString/afterFullFileContent, so
    -- `diff.change_from_payload` returns nil and this produces NO change row -- the
    -- review list comes only from the overlay walk (finalize_shadow_turn_body ->
    -- bin/yana-changeset), the cardinal ruling in the core spec, never from this
    -- stream.
    --
    state.file_change_count = state.file_change_count + 1
    local paths = {}
    local changes = nilify(item.changes)
    if type(changes) == "table" then
      for _, c in ipairs(changes) do
        if type(c) == "table" and c.path then
          paths[#paths + 1] = c.path
        end
      end
    end
    return {
      {
        type = "tool_call",
        subtype = "completed",
        call_id = item.id,
        tool_call = { fileChangeToolCall = { args = { paths = paths }, result = { success = { note = true } } } },
        timestamp_ms = ts,
      },
    }
  end
  if itype == "todo_list" then
    return {
      {
        type = "tool_call",
        subtype = "completed",
        call_id = item.id,
        tool_call = { todoToolCall = { args = {}, result = { success = { note = true } } } },
        timestamp_ms = ts,
      },
    }
  end
  if itype == "error" then
    return { { type = "error", message = item.message, timestamp_ms = ts } }
  end
  state.unknown_count = state.unknown_count + 1
  return {}
end

local function normalize_codex(state, obj)
  stamp_timestamp_ms(obj)
  local t = obj.type
  if t == "thread.started" then
    return { { type = "system", subtype = "init", session_id = obj.thread_id, timestamp_ms = obj.timestamp_ms } }
  end
  if t == "turn.started" or t == "item.started" then
    return {}
  end
  if t == "item.completed" then
    return codex_item_completed(state, obj)
  end
  if t == "turn.completed" then
    local usage = nilify(obj.usage)
    local result = {
      type = "result",
      subtype = "success",
      is_error = false,
      timestamp_ms = obj.timestamp_ms,
      file_change_count = state.file_change_count,
    }
    if usage ~= nil then
      result.usage = usage
    end
    return { result }
  end
  if t == "turn.failed" then
    local err = nilify(obj.error)
    local message = (type(err) == "table") and err.message or nil
    return {
      {
        type = "result",
        subtype = "error",
        is_error = true,
        result = message,
        timestamp_ms = obj.timestamp_ms,
        file_change_count = state.file_change_count,
      },
    }
  end
  if t == "error" then
    return { { type = "error", message = obj.message, timestamp_ms = obj.timestamp_ms } }
  end
  state.unknown_count = state.unknown_count + 1
  return {}
end

--------------------------------------------------------------------------
-- public interface
--------------------------------------------------------------------------

-- Build a fresh per-turn normalizer state for the given vendor protocol.
function M.new_state(opts)
  opts = opts or {}
  return {
    protocol = opts.protocol or "cursor",
    cwd = opts.cwd,
    -- claude: tool_use_id -> {name=, input=}
    pending = {},
    -- claude: tool_use_id -> list of candidate absolute paths a Bash call
    -- might delete, captured when the tool_use line is seen.
    delete_candidates = {},
    -- claude: abs path -> last known full content, refreshed on every
    -- Read/Edit-after/Write-after/NotebookEdit-after translated. Used as
    -- the deletion prevContent source (no git fallback -- see module doc).
    content_cache = {},
    -- unrecognised event/item shapes this turn has seen; reachable for the
    -- flow report (V2-1: "bump a counter reachable for the flow report").
    unknown_count = 0,
    -- Initialised to 0 for every protocol; each protocol's `result`-emitting site
    -- stamps it onto the outgoing event. Cursor non-result events stay byte-identical;
    -- only `result` gains the field.
    file_change_count = 0,
  }
end

-- Cursor file-affecting envelope names. Counted by NAME on completed
-- tool_call events, not by whether `diff.change_from_payload` later builds
-- a reviewable change -- attempted vs shown stay separate (see BINDING
-- CONTRACT above). `started` is ignored so a started+completed pair for
-- one call_id counts once.
local CURSOR_FILE_TOOL_CALLS = {
  editToolCall = true,
  writeToolCall = true,
  deleteToolCall = true,
  multiEditToolCall = true,
  notebookEditToolCall = true,
}

local function cursor_tool_member_name(obj)
  local tc = obj.tool_call
  if type(tc) ~= "table" then
    return nil
  end
  for k, v in pairs(tc) do
    if type(k) == "string" and type(v) == "table" and k:match("ToolCall$") then
      return k
    end
  end
  return nil
end

-- Cursor path: count recognised file-affecting envelopes; stamp
-- file_change_count onto result; every other event stays the same table.
local function normalize_cursor(state, obj)
  if obj.type == "tool_call" and obj.subtype == "completed" then
    local name = cursor_tool_member_name(obj)
    if name and CURSOR_FILE_TOOL_CALLS[name] then
      -- Deliberate: count the envelope by name, never via
      -- diff.change_from_payload -- ATTEMPTED vs SHOWN must diverge.
      state.file_change_count = state.file_change_count + 1
    end
    return { obj }
  end
  if obj.type == "result" then
    -- Ours wins over any vendor-supplied / pre-set value (same rule as
    -- claude's lying-num_edits path).
    obj.file_change_count = state.file_change_count
    return { obj }
  end
  return { obj }
end

-- Dispatch obj by state.protocol; return a list of cursor-shaped events.
function M.normalize(state, obj)
  if type(obj) ~= "table" then
    return {}
  end
  local protocol = (state and state.protocol) or "cursor"
  if protocol == "claude" then
    return normalize_claude(state, obj)
  end
  if protocol == "codex" then
    return normalize_codex(state, obj)
  end
  -- "cursor", and any other/unset protocol (config validates the closed set
  -- before a turn ever reaches here). Non-result events stay byte-identical;
  -- result gains file_change_count.
  return normalize_cursor(state, obj)
end

return M
