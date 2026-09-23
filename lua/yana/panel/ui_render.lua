-- Conversation buffer render primitives (raw `set_lines`/`append` plus the user/assistant header, stream, tool-note and
-- error renders built on them). Highest fan-in in the panel: later splits receive these as plain function references.
-- `render_note` is deliberately NOT here: it is a reassigned upvalue in ui.lua and stays a one-line wrapper over `append`.
local config = require("yana.config")
local diff = require("yana.diff")
local ledger = require("yana.ledger")
local log = require("yana.log")
local notify = require("yana.notify")
local views = require("yana.panel.ui_panel_views")

local M = {}

-- deps.buf_valid / win_valid: liveness checks; deps.ui_ns: namespace for user/tool_note/note line highlights.
function M.new(deps)
  local buf_valid = deps.buf_valid
  local win_valid = deps.win_valid
  local ui_ns = deps.ui_ns

  local function set_lines(p, start, finish, lines)
    if not buf_valid(p.conv_buf) then
      return
    end
    -- nvim_buf_set_lines rejects entries containing "\n"; flatten so a multi-line summary cannot abort the turn.
    local flat = {}
    for _, l in ipairs(lines) do
      if type(l) == "string" and l:find("\n", 1, true) then
        vim.list_extend(flat, vim.split(l, "\n", { plain = true }))
      else
        flat[#flat + 1] = l
      end
    end
    vim.bo[p.conv_buf].modifiable = true
    vim.api.nvim_buf_set_lines(p.conv_buf, start, finish, false, flat)
    vim.bo[p.conv_buf].modifiable = false
  end

  local function scroll_to_bottom(p)
    if not buf_valid(p.conv_buf) then
      return
    end
    local count = vim.api.nvim_buf_line_count(p.conv_buf)
    views.each(p, function(view)
      if win_valid(view.conv) then
        pcall(vim.api.nvim_win_set_cursor, view.conv, { count, 0 })
      end
    end)
  end

  local function decorate_append(p, first, last, kind)
    if not buf_valid(p.conv_buf) then
      return
    end
    local group = kind == "user" and "YanaUserPrompt"
      or kind == "tool_note" and "YanaActivity"
      or kind == "note" and "YanaMuted"
      or nil
    if not group then
      return
    end
    for row = first, last do
      pcall(vim.api.nvim_buf_set_extmark, p.conv_buf, ui_ns, row, 0, {
        line_hl_group = group,
        priority = 80,
      })
    end
  end

  -- Turn ledger for the panel's current (or named) turn; creates the record if a callback arrives for an unopened turn.
  -- `p.render_gen` is the OWNING generation of the output rendered now (set by with_render_gen), so render resolves the
  -- same (panel, gen) key as the event side and late events cannot misattribute.
  local function turn_ledger(p, gen)
    return ledger.ensure(p and p.id or 0, gen or (p and (p.render_gen or p.turn_gen)) or 0)
  end

  -- Run `fn` with p.render_gen pinned to `gen`, restoring the previous value even when `fn` throws (a leaked pin would
  -- misattribute later appends); the error is re-raised unchanged.
  local function with_render_gen(p, gen, fn, ...)
    local prev = p.render_gen
    p.render_gen = gen
    local ok, err = pcall(fn, ...)
    p.render_gen = prev
    if not ok then
      error(err, 0)
    end
  end

  -- Append lines to the end of the conversation buffer; `kind` names WHY ("user", "note", "tool_note", "tool_change", ...).
  local function append(p, lines, kind)
    if not buf_valid(p.conv_buf) then
      return
    end
    local count = vim.api.nvim_buf_line_count(p.conv_buf)
    local first
    -- A fresh scratch buffer has a single empty line; overwrite it.
    if count == 1 and vim.api.nvim_buf_get_lines(p.conv_buf, 0, 1, false)[1] == "" then
      first = 0
      set_lines(p, 0, 1, lines)
    else
      first = count
      set_lines(p, count, count, lines)
    end
    decorate_append(p, first, vim.api.nvim_buf_line_count(p.conv_buf) - 1, kind)
    ledger.note_append(turn_ledger(p), kind or "append", lines)
    scroll_to_bottom(p)
  end

  local function render_user(p, question, label)
    local lines = { "" }
    for i, l in ipairs(vim.split(question, "\n", { plain = true })) do
      table.insert(lines, (i == 1 and "› " or "  ") .. l)
    end
    if label then
      table.insert(lines, "")
      table.insert(lines, "  Context · " .. label)
    end
    table.insert(lines, "")
    append(p, lines, "user")
  end

  -- The header names the ACTIVE BACKEND (`config.options.backend`).
  local function backend_label(name)
    name = name or config.options.backend or "cursor"
    if name == "cursor" then
      return "Cursor"
    end
    return name
  end

  local function start_assistant_block(p)
    p.stream_text = ""
    p.stream_seq_first = nil
    p.stream_seq_last = nil
    p.stream_gen = nil
    p.rendered_any = false
    -- Pinned contract (row 63): every assistant block opens with "## <backend> · <mode>" naming the ACTIVE backend.
    append(p, { "## " .. backend_label() .. " · " .. config.panel_mode(p.mode), "" }, "assistant_header")
    p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
  end

  -- Streaming REWRITES the assistant region once per delta, so it is counted, not ringed (a ring entry per delta would
  -- evict every structural append); the committed segment gets the ring entry (commit_stream).
  local function render_stream(p)
    local lines = vim.split(p.stream_text, "\n", { plain = true })
    set_lines(p, p.assistant_start, -1, lines)
    ledger.bump(turn_ledger(p), "stream_renders")
    scroll_to_bottom(p)
  end

  local function append_stream(p, delta)
    if delta == nil or delta == "" then
      return
    end
    p.rendered_any = true
    -- Provenance for the segment being BUILT: its ring entry is written at commit, when the current event is the
    -- following tool call, so carry the originating seq range and owning generation on the pending segment instead.
    local L = turn_ledger(p)
    local seq = ledger.current_event(L)
    if seq ~= nil then
      if p.stream_seq_first == nil then
        p.stream_seq_first = seq
        p.stream_gen = L.gen
      end
      p.stream_seq_last = seq
    end
    p.stream_text = p.stream_text .. delta
    render_stream(p)
  end

  -- "Freeze" the streamed text so later content appends after it and new deltas start a fresh segment.
  local function commit_stream(p)
    if p.stream_text ~= "" then
      ledger.note_append_at(
        turn_ledger(p, p.stream_gen),
        "stream",
        vim.split(p.stream_text, "\n", { plain = true }),
        p.stream_seq_first,
        p.stream_seq_last
      )
    end
    p.stream_text = ""
    p.stream_seq_first = nil
    p.stream_seq_last = nil
    p.stream_gen = nil
    p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
  end

  local function tool_activity(name)
    local lower = tostring(name or ""):lower()
    if lower:find("edit", 1, true) or lower:find("write", 1, true) or lower:find("apply", 1, true) then
      return "Edited"
    end
    if lower:find("shell", 1, true) or lower:find("command", 1, true)
      or lower:find("exec", 1, true) or lower:find("run", 1, true)
    then
      return "Ran"
    end
    if lower:find("read", 1, true) or lower:find("search", 1, true)
      or lower:find("grep", 1, true) or lower:find("glob", 1, true)
      or lower:find("list", 1, true)
    then
      return "Explored"
    end
    return "Ran"
  end

  local function render_tool_note(p, name, payload)
    commit_stream(p)
    p.rendered_any = true
    append(p, {
      "✓ " .. tool_activity(name) .. " · " .. notify.flatten(diff.tool_summary(name, payload)),
      "",
    }, "tool_note")
    p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
  end

  -- UTF-8-safe prefix of at most max_bytes bytes: never ends mid multibyte sequence (invalid UTF-8 for the JSON encoder).
  local function utf8_safe_truncate(s, max_bytes)
    if #s <= max_bytes then
      return s
    end
    local i = max_bytes
    while i > 0 do
      local b = s:byte(i)
      if b < 0x80 or b >= 0xC0 then
        break -- ASCII byte, or the leading byte of a multibyte sequence
      end
      i = i - 1 -- continuation byte (0x80-0xBF); keep walking back
    end
    local lead = s:byte(i)
    if lead and lead >= 0xC0 then
      local seqlen = 2
      if lead >= 0xF0 then
        seqlen = 4
      elseif lead >= 0xE0 then
        seqlen = 3
      end
      if i + seqlen - 1 > max_bytes then
        i = i - 1 -- the sequence starting at i does not fit; drop it whole
      else
        i = i + seqlen - 1 -- it fits exactly: keep the whole sequence, not just its lead byte
      end
    end
    return s:sub(1, i)
  end

  local function render_error(p, msg, extra)
    local lines = { "", "> **error:** " .. (msg or "unknown error") }
    if extra then
      if extra.exit_code ~= nil then
        table.insert(lines, "> exit code: " .. tostring(extra.exit_code))
      end
      if extra.vendor_backend then
        table.insert(lines, "> backend: " .. tostring(extra.vendor_backend))
      end
      if extra.evidence_dir then
        table.insert(lines, "> evidence: `" .. tostring(extra.evidence_dir) .. "`")
      end
    end
    table.insert(lines, "")
    append(p, lines, "error")
    -- Leave a durable turn.error row (YANA_LIFECYCLE_LOG-gated) so an unwatched terminal error has a trace; pcall'd so
    -- a logging failure cannot take the render down.
    pcall(function()
      log.lifecycle("turn.error", {
        panel = p and p.id or nil,
        message = utf8_safe_truncate(tostring(msg or "unknown error"), 200),
        exit_code = extra and extra.exit_code or nil,
      })
    end)
  end

  -- Panel greeting hook: deliberately empty, no boilerplate is shown.
  local function render_greeting(p)
    -- No welcome boilerplate; panel opens ready for input.
  end

  return {
    set_lines = set_lines,
    scroll_to_bottom = scroll_to_bottom,
    decorate_append = decorate_append,
    turn_ledger = turn_ledger,
    with_render_gen = with_render_gen,
    append = append,
    render_user = render_user,
    backend_label = backend_label,
    start_assistant_block = start_assistant_block,
    render_stream = render_stream,
    append_stream = append_stream,
    commit_stream = commit_stream,
    tool_activity = tool_activity,
    render_tool_note = render_tool_note,
    utf8_safe_truncate = utf8_safe_truncate,
    render_error = render_error,
    render_greeting = render_greeting,
  }
end

return M
