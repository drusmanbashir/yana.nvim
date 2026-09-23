-- claude protocol normalizer (V2-2), split out of lua/yana/agent/vendor_stream.lua
--. Turns
-- claude's own JSONL event shape into cursor-agent's own event shape --
-- see vendor_stream.lua's module header for the full account of why this
-- exists and the HOOK REQUIRED contract in lua/yana/agent/agent.lua.
--
local diff = require("yana.diff")
local uv = vim.uv or vim.loop

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

local M = {}

function M.new(deps)
-- claude: file-affecting tools -> cursor's ToolCall name (V2-2).
local FILE_TOOL_MAP = {
  Edit = "editToolCall",
  Write = "writeToolCall",
  NotebookEdit = "notebookEditToolCall",
  -- Handled defensively from the public tool contract: `edits` is a list of
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
    local before = deps.nilify(tur.originalFile)
    if before == nil then
      return nil
    end
    local old = deps.nilify(tur.oldString)
    if old == nil then
      old = inp.old_string or ""
    end
    local new = deps.nilify(tur.newString)
    if new == nil then
      new = inp.new_string or ""
    end
    local replace_all = deps.nilify(tur.replaceAll)
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
    local after = deps.nilify(tur.content)
    if after == nil then
      after = inp.content
    end
    after = after or ""
    -- nil on create (JSON null -> vim.NIL -> nilified to Lua nil), full
    -- text on overwrite.
    local before = deps.nilify(tur.originalFile)
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
    local before = deps.nilify(tur.original_file)
    local after = deps.nilify(tur.updated_file)
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
    local before = deps.nilify(tur.originalFile)
    local edits = deps.nilify(tur.edits)
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
      local f = deps.nilify(tur.file)
      if type(f) == "table" then
        local content = deps.nilify(f.content)
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

-- Bash-driven delete narration (claude_emit_deletes) is a SEPARATE mechanism from this
-- map and is deliberately NOT counted here -- this pass scopes the count to the
-- Edit/Write/NotebookEdit/MultiEdit family the task named; widening it to deletes is a
-- follow-up, not this change.
local function claude_emit_synthetic(state, obj, tid, name, inp, tur, is_error, out)
  local cursor_name, args, result
  local is_file_tool = FILE_TOOL_MAP[name] and not is_error
  if is_file_tool then
    cursor_name, args, result = claude_file_payload(state, name, inp, tur)
  else
    cursor_name, args, result = claude_note_payload(state, name, inp, tur, is_error)
  end
  if not cursor_name then
    return
  end
  if is_file_tool then
    state.file_change_count = state.file_change_count + 1
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

-- This synthetic exists purely so the panel says "deleted <path>" during the turn
-- instead of silence. Existence confirmed via `uv.fs_stat`, content read ONLY from the
-- in-state cache (no git lookup, unlike the python probe this ports) -- `prevContent`
-- is simply omitted when the cache has nothing.
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
  local tur = deps.nilify(obj.tool_use_result)
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

-- `assistant` tool_use items -> remembered by id, nothing emitted yet. `user`
-- tool_result -> emit the forwarded event PLUS a synthetic cursor tool_call/completed
-- per matched tool_use_id. `system/init` -> forwarded (ui.lua reads session_id from
-- it); also tracked locally for Bash delete-candidate path resolution.
local function normalize_claude(state, obj)
  deps.stamp_timestamp_ms(obj)
  local out = {}
  local t = obj.type
  if t == "system" and obj.subtype == "init" then
    state.cwd = obj.cwd or state.cwd
  elseif t == "assistant" then
    claude_note_tool_uses(state, obj)
  elseif t == "user" then
    claude_handle_user(state, obj, out)
  elseif t == "result" then
    obj.file_change_count = state.file_change_count
  end
  out[#out + 1] = obj
  return out
end

  return {
    normalize = normalize_claude,
  }
end

return M
