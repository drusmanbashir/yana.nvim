-- yana: normalizes a non-cursor vendor's JSONL event stream into cursor-agent's
-- own event shape, so `lua/yana/ui.lua`'s `on_event_body` (the ONLY place the
-- panel learns "a file changed": `obj.type == "tool_call"` /
-- `obj.subtype == "completed"` -> `diff.parse_tool` -> `diff.change_from_payload`)
-- renders every vendor exactly as it renders cursor-agent, without knowing any
-- vendor exists.
--
-- HOOK REQUIRED in `lua/yana/agent.lua`'s `M.run(req)` (applied by the
-- orchestrator; this lane does not touch agent.lua):
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
--    Everything ELSE in `emit()` — `M.describe_event(obj)`, `last_event`,
--    `rec:note_model_actual(obj.model)`, `st.last_event_hr`, and the
--    decode-failure counting in the `elseif L then` branch — keeps operating
--    on the ORIGINAL decoded `obj`, never on the normalized list: session/
--    model bookkeeping and the flow report's "one decoded vendor line per
--    callback" count must stay one-per-line regardless of how many (zero,
--    one, or several) cursor-shaped events that line expands into.
--
-- CONTRACT (V2-1, the VENDORS work order)
--   local vs = require("yana.vendor_stream")
--   local state = vs.new_state({ protocol = "claude", cwd = <turn cwd> })
--   local events = vs.normalize(state, obj)  -- obj = one decoded vendor line
--   -- returns a LIST (possibly empty) of cursor-shaped event tables, in order
--
-- - `protocol == "cursor"` (also the default, and any unrecognised protocol
--   string — a vendor's `stream_protocol` is validated at config setup, lane
--   V1's job, never here) returns `{ obj }` UNCHANGED: byte-identical
--   behaviour for every existing turn is the acceptance bar.
-- - PURE with respect to the process: no `jobstart`, no `system()`, no git
--   subprocess, no blocking I/O on the event path. The python probe this
--   module ports (`tests/bin/claude_stream_translate.py`) shelled out to
--   `git show HEAD:...` for deleted-file content; that lookup is NOT ported.
--   Deletion narration uses the in-state content cache only, and omits
--   `prevContent` when the cache has nothing. The one filesystem call this
--   module makes is a synchronous `uv.fs_stat` existence check for a Bash
--   deletion candidate (explicitly sanctioned by V2-2: "existence confirmed
--   via `uv.fs_stat`") — a single non-blocking stat syscall, not a
--   subprocess and not a wait on external process output.
-- - Unknown event types return `{}` and bump `state.unknown_count`; they
--   never throw and never produce a change row.

local M = {}

local diff = require("yana.diff")
local uv = vim.uv or vim.loop

-- claude: file-affecting tools -> cursor's ToolCall name (V2-2).
local FILE_TOOL_MAP = {
  Edit = "editToolCall",
  Write = "writeToolCall",
  NotebookEdit = "notebookEditToolCall",
  -- MultiEdit is NOT OBSERVED to fire in the probed claude build (2.1.238;
  -- claude-live-20260821.jsonl has no MultiEdit call). Handled defensively
  -- from the public tool contract: `edits` is a list of
  -- {old_string,new_string,replace_all} applied in order over the same
  -- originalFile/afterFullFileContent shape Edit uses.
  MultiEdit = "multiEditToolCall",
}

-- claude: every other tool -> a note-only synthetic (V2-2).
local NOTE_TOOL_MAP = {
  Read = "readToolCall",
  Grep = "grepToolCall",
  Glob = "globToolCall",
  Bash = "shellToolCall",
  Task = "taskToolCall",
  TodoWrite = "todoToolCall",
  WebFetch = "webFetchToolCall",
  WebSearch = "webSearchToolCall",
}

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

local function fs_exists(path)
  local ok, stat = pcall(function()
    return uv.fs_stat(path)
  end)
  return ok and stat ~= nil
end

-- Plain (non-pattern) single/all replacement -- claude's old_string/new_string
-- can contain arbitrary bytes, including Lua pattern magic characters, so a
-- gsub-based replace would misbehave; find(..., true) is a literal search.
local function replace_once(s, old, new)
  if old == "" then
    return s
  end
  local i, j = s:find(old, 1, true)
  if not i then
    return s
  end
  return s:sub(1, i - 1) .. new .. s:sub(j + 1)
end

local function replace_all_occurrences(s, old, new)
  if old == "" then
    return s
  end
  local parts = {}
  local pos = 1
  while true do
    local i, j = s:find(old, pos, true)
    if not i then
      parts[#parts + 1] = s:sub(pos)
      break
    end
    parts[#parts + 1] = s:sub(pos, i - 1)
    parts[#parts + 1] = new
    pos = j + 1
  end
  return table.concat(parts)
end

--------------------------------------------------------------------------
-- claude protocol (V2-2)
--------------------------------------------------------------------------

local function claude_add_diff_stats(success, path, before, after)
  local diffstr = diff.synthesize_diff(before, after, path)
  if diffstr ~= "" then
    success.diffString = diffstr
    local added, removed = diff.count_stats(diffstr)
    success.linesAdded = added
    success.linesRemoved = removed
  end
end

-- Edit/Write/NotebookEdit/MultiEdit -> cursor's <name>ToolCall with
-- result.success = {path, beforeFullFileContent?, afterFullFileContent,
-- diffString, linesAdded, linesRemoved}. Returns nil when the required
-- before/after evidence isn't present (no bogus change row).
local function claude_file_payload(state, name, inp, tur)
  tur = tur or {}
  if name == "Edit" then
    local path = inp.file_path
    local before = nilify(tur.originalFile)
    if before == nil then
      return nil
    end
    local old = nilify(tur.oldString)
    if old == nil then
      old = inp.old_string or ""
    end
    local new = nilify(tur.newString)
    if new == nil then
      new = inp.new_string or ""
    end
    local replace_all = nilify(tur.replaceAll)
    if replace_all == nil then
      replace_all = inp.replace_all
    end
    local after = replace_all and replace_all_occurrences(before, old, new) or replace_once(before, old, new)
    state.content_cache[path] = after
    local success = { path = path, afterFullFileContent = after }
    -- `before` is a real Lua string here (nilify already ran), never
    -- vim.NIL, so a create can never reach this branch with a bogus
    -- beforeFullFileContent -- Edit always requires prior content.
    success.beforeFullFileContent = before
    claude_add_diff_stats(success, path, before, after)
    return "editToolCall", { path = path }, { success = success }
  end
  if name == "Write" then
    local path = inp.file_path
    local after = nilify(tur.content)
    if after == nil then
      after = inp.content
    end
    after = after or ""
    -- nil on create (JSON null -> vim.NIL -> nilified to Lua nil), full
    -- text on overwrite.
    local before = nilify(tur.originalFile)
    state.content_cache[path] = after
    local success = { path = path, afterFullFileContent = after }
    -- MUST OMIT beforeFullFileContent entirely for a create -- the key is
    -- simply never set, rather than set to nil/vim.NIL (see nilify's doc
    -- comment above for why the JSON-null trap makes this the load-bearing
    -- line in this whole module).
    if before ~= nil then
      success.beforeFullFileContent = before
    end
    claude_add_diff_stats(success, path, before, after)
    return "writeToolCall", { path = path }, { success = success }
  end
  if name == "NotebookEdit" then
    local path = inp.notebook_path
    local before = nilify(tur.original_file)
    local after = nilify(tur.updated_file)
    if after == nil then
      return nil
    end
    state.content_cache[path] = after
    local success = { path = path, afterFullFileContent = after }
    if before ~= nil then
      success.beforeFullFileContent = before
    end
    claude_add_diff_stats(success, path, before, after)
    return "notebookEditToolCall", { path = path }, { success = success }
  end
  if name == "MultiEdit" then
    local path = inp.file_path
    local before = nilify(tur.originalFile)
    local edits = nilify(tur.edits)
    if edits == nil then
      edits = inp.edits
    end
    if before == nil or type(edits) ~= "table" then
      return nil
    end
    local after = before
    for _, e in ipairs(edits) do
      local old = e.old_string or ""
      local new = e.new_string or ""
      after = e.replace_all and replace_all_occurrences(after, old, new) or replace_once(after, old, new)
    end
    state.content_cache[path] = after
    local success = { path = path, afterFullFileContent = after }
    success.beforeFullFileContent = before
    claude_add_diff_stats(success, path, before, after)
    return "multiEditToolCall", { path = path }, { success = success }
  end
  return nil
end

-- Non-file tool -> note-only synthetic: no diffString/afterFullFileContent,
-- so `diff.change_from_payload` returns nil and the panel gets a note
-- without a phantom hunk.
local function claude_note_payload(state, name, inp, tur, is_error)
  local cursor_name = NOTE_TOOL_MAP[name]
  if not cursor_name then
    cursor_name = (name and name ~= "") and (name:sub(1, 1):lower() .. name:sub(2) .. "ToolCall") or "toolCall"
  end
  local args = {}
  local path = inp.file_path or inp.path or inp.notebook_path or inp.target_file
  if path then
    args.path = path
    if type(tur) == "table" then
      local f = nilify(tur.file)
      if type(f) == "table" then
        local content = nilify(f.content)
        if content ~= nil then
          state.content_cache[path] = content
        end
      end
    end
  end
  local command = inp.command
  if command then
    args.command = command
  end
  local query = inp.pattern or inp.query
  if query then
    args.query = query
  end
  local result = {}
  if name == "Bash" then
    local exit_code = is_error and 1 or 0
    if is_error then
      result.failure = { exitCode = exit_code }
    else
      result.success = { exitCode = exit_code }
    end
  else
    result.success = { note = true }
  end
  return cursor_name, args, result
end

local function claude_emit_synthetic(state, obj, tid, name, inp, tur, is_error, out)
  local cursor_name, args, result
  if FILE_TOOL_MAP[name] and not is_error then
    cursor_name, args, result = claude_file_payload(state, name, inp, tur)
  else
    cursor_name, args, result = claude_note_payload(state, name, inp, tur, is_error)
  end
  if not cursor_name then
    return
  end
  out[#out + 1] = {
    type = "tool_call",
    subtype = "completed",
    call_id = tid,
    tool_call = { [cursor_name] = { args = args, result = result } },
    session_id = obj.session_id,
    timestamp_ms = obj.timestamp_ms,
  }
end

local DELETE_HEAD_WORD = { rm = true, unlink = true, trash = true }

local function split_subcommands(cmd)
  local parts = {}
  local buf = {}
  local i, n = 1, #cmd
  while i <= n do
    local two = cmd:sub(i, i + 1)
    if two == "&&" or two == "||" then
      parts[#parts + 1] = table.concat(buf)
      buf = {}
      i = i + 2
    else
      local one = cmd:sub(i, i)
      if one == ";" or one == "|" then
        parts[#parts + 1] = table.concat(buf)
        buf = {}
        i = i + 1
      else
        buf[#buf + 1] = one
        i = i + 1
      end
    end
  end
  parts[#parts + 1] = table.concat(buf)
  return parts
end

-- Bash deletions have no dedicated claude tool; candidates are captured the
-- moment the Bash tool_use is seen. Only path tokens out of sub-commands
-- whose head word IS a delete (`rm`/`unlink`/`trash`, or `git rm`) are taken
-- -- not every token on the whole line (`rm note.md && ls DIR` must not
-- treat `DIR` as a delete candidate).
local function claude_note_delete_candidates(state, tid, inp)
  local cmd = inp.command
  if type(cmd) ~= "string" or cmd == "" then
    return
  end
  local has_delete_word = cmd:match("%f[%w]rm%f[%W]") or cmd:match("%f[%w]unlink%f[%W]") or cmd:match("%f[%w]trash%f[%W]")
  if not has_delete_word then
    return
  end
  local candidates = {}
  for _, sub in ipairs(split_subcommands(cmd)) do
    local words = {}
    for w in sub:gmatch("%S+") do
      words[#words + 1] = w
    end
    if #words > 0 then
      local head
      if words[1] == "git" and words[2] == "rm" then
        head = 3
      elseif DELETE_HEAD_WORD[words[1]] then
        head = 2
      end
      if head then
        for k = head, #words do
          local tok = words[k]:gsub("^['\"]", ""):gsub("['\"]$", "")
          if tok ~= "" and tok:sub(1, 1) ~= "-" then
            local abspath = tok:sub(1, 1) == "/" and tok or ((state.cwd or ".") .. "/" .. tok)
            candidates[#candidates + 1] = vim.fs.normalize(abspath)
          end
        end
      end
    end
  end
  if #candidates > 0 then
    state.delete_candidates[tid] = candidates
  end
end

local function claude_known_to_exist(state, abspath)
  if state.content_cache[abspath] ~= nil then
    return true
  end
  return fs_exists(abspath)
end

-- Narrative-only: the disk walk (finalize_shadow_turn_body ->
-- bin/yana-changeset) decides the real outcome, and Ruling 8 still
-- terminally refuses a delete outside an artifact root, for any agent. This
-- synthetic exists purely so the panel says "deleted <path>" during the turn
-- instead of silence. Existence confirmed via `uv.fs_stat`, content read
-- ONLY from the in-state cache (no git lookup, unlike the python probe this
-- ports) -- `prevContent` is simply omitted when the cache has nothing.
local function claude_emit_deletes(state, obj, candidates, out)
  for _, abspath in ipairs(candidates) do
    local existed = claude_known_to_exist(state, abspath)
    local gone = not fs_exists(abspath)
    if existed and gone then
      local prev = state.content_cache[abspath]
      local success = { path = abspath, deletedFile = abspath }
      if prev ~= nil then
        success.prevContent = prev
        success.fileSize = tostring(#prev)
      end
      out[#out + 1] = {
        type = "tool_call",
        subtype = "completed",
        call_id = "synthetic-delete-" .. abspath,
        tool_call = { deleteToolCall = { args = { path = abspath }, result = { success = success } } },
        session_id = obj.session_id,
        timestamp_ms = obj.timestamp_ms,
      }
      state.content_cache[abspath] = nil
    end
  end
end

local function claude_note_tool_uses(state, obj)
  local content = obj.message and obj.message.content
  if type(content) ~= "table" then
    return
  end
  for _, item in ipairs(content) do
    if type(item) == "table" and item.type == "tool_use" then
      local tid, name = item.id, item.name
      local inp = item.input
      if type(inp) ~= "table" then
        inp = {}
      end
      if tid and name then
        state.pending[tid] = { name = name, input = inp }
        if name == "Bash" then
          claude_note_delete_candidates(state, tid, inp)
        end
      end
    end
  end
end

local function claude_handle_user(state, obj, out)
  local content = obj.message and obj.message.content
  if type(content) ~= "table" then
    return
  end
  local tur = nilify(obj.tool_use_result)
  for _, item in ipairs(content) do
    if type(item) == "table" and item.type == "tool_result" then
      local tid = item.tool_use_id
      local entry = tid and state.pending[tid]
      if entry then
        state.pending[tid] = nil
        local is_error = item.is_error == true
        claude_emit_synthetic(state, obj, tid, entry.name, entry.input, tur, is_error, out)
        local cands = state.delete_candidates[tid]
        state.delete_candidates[tid] = nil
        if cands and not is_error then
          claude_emit_deletes(state, obj, cands, out)
        end
      end
    end
  end
end

-- `assistant` tool_use items -> remembered by id, nothing emitted yet.
-- `user` tool_result -> emit the forwarded event PLUS a synthetic cursor
-- tool_call/completed per matched tool_use_id.
-- `system/init` -> forwarded (ui.lua reads session_id from it); also tracked
-- locally for Bash delete-candidate path resolution.
-- `result` -> forwarded unchanged (already cursor-shaped enough).
-- Anything else (rate_limit_event, hook_started/hook_response, ...) ->
-- forwarded unchanged, same as cursor's own unrecognised-but-harmless lines.
local function normalize_claude(state, obj)
  stamp_timestamp_ms(obj)
  local out = {}
  local t = obj.type
  if t == "system" and obj.subtype == "init" then
    state.cwd = obj.cwd or state.cwd
  elseif t == "assistant" then
    claude_note_tool_uses(state, obj)
  elseif t == "user" then
    claude_handle_user(state, obj, out)
  end
  out[#out + 1] = obj
  return out
end

--------------------------------------------------------------------------
-- codex protocol (V2-3) -- UNVERIFIED beyond the envelope. The account was
-- out of quota for every probe run on 2026-08-21 (4 real turns, all
-- quota-refused before any tool call), so `item.started`, `turn.completed`,
-- and every non-error `item.type` below are implemented from the public
-- codex event naming and marked UNVERIFIED individually. Nothing here may
-- let an unrecognised shape produce a change row.
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
    -- UNVERIFIED (no live codex turn available 2026-08-21): text field name.
    local text = item.text or item.message or item.content
    return { { type = "assistant", message = { content = { { type = "text", text = text } } }, timestamp_ms = ts } }
  end
  if itype == "reasoning" then
    -- UNVERIFIED (no live codex turn available 2026-08-21).
    local text = item.text or item.content
    return { { type = "assistant", message = { content = { { type = "thinking", text = text } } }, timestamp_ms = ts } }
  end
  if itype == "command_execution" then
    -- UNVERIFIED (no live codex turn available 2026-08-21): field names for
    -- the command and its exit code.
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
    -- UNVERIFIED (no live codex turn available 2026-08-21). Note-only by
    -- construction: no diffString/afterFullFileContent, so
    -- `diff.change_from_payload` returns nil and this produces NO change
    -- row -- the review list comes only from the overlay walk
    -- (finalize_shadow_turn_body -> bin/yana-changeset), the cardinal
    -- ruling in the core spec, never from this stream.
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
    -- UNVERIFIED (no live codex turn available 2026-08-21).
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
    -- UNVERIFIED (no live codex turn available 2026-08-21) that
    -- item.started is safe to drop -- observed today only as an envelope
    -- token before quota refusal, never with real item content following.
    return {}
  end
  if t == "item.completed" then
    return codex_item_completed(state, obj)
  end
  if t == "turn.completed" then
    -- UNVERIFIED (no live codex turn available 2026-08-21).
    local usage = nilify(obj.usage)
    local result = { type = "result", subtype = "success", is_error = false, timestamp_ms = obj.timestamp_ms }
    if usage ~= nil then
      result.usage = usage
    end
    return { result }
  end
  if t == "turn.failed" then
    local err = nilify(obj.error)
    local message = (type(err) == "table") and err.message or nil
    return {
      { type = "result", subtype = "error", is_error = true, result = message, timestamp_ms = obj.timestamp_ms },
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
  }
end

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
  -- before a turn ever reaches here) -- byte-identical passthrough.
  return { obj }
end

return M
