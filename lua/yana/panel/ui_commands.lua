-- Small panel/claim commands: new_chat, diary/turn-key dumps, ask/inline_edit entry points, refusal listing.
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local renewal = require("yana.agent.renewal")

local M = {}

-- deps.state = parent S; deps.M = parent module table; the rest are the parent's panel bookkeeping locals.
function M.new(deps)
  local S = deps.state
  local ui_M = deps.M
  local panels = deps.panels
  local panel_open = deps.panel_open
  local buf_valid = deps.buf_valid
  local current_panel = deps.current_panel
  local panel_for_buf = deps.panel_for_buf
  local open_new_panel = deps.open_new_panel
  local update_winbar = deps.update_winbar
  local preview_module = deps.preview_module
  local release_shadow_turn = deps.release_shadow_turn
  local drop_review_batch = deps.drop_review_batch
  local inline_review_opts = deps.inline_review_opts
  local refusal_kind_summary = deps.refusal_kind_summary
  local set_lines = deps.set_lines

local function new_chat()
  local p = current_panel()
  if not p then
    return
  end
  if p._new_chat_pending then
    notify_one_line("yana: conversation close is still waiting for the review claim", vim.log.levels.WARN)
    return
  end
  S.cancel_inflight(p)
  local inline = require("yana.inline_diff")
  local owner = { panel_id = p.id, epoch = p.review_epoch }
  local review_opts = inline_review_opts(p)

  -- ORDER, and it is the whole fix. The review's End is asked FIRST; the claim
  -- is released only once that End completed; the conversation is reset only
  -- once the release succeeded. Releasing first tore the claim out from under
  -- a review that was still ending, and resetting on a merely STARTED End
  -- bumped the epoch out from under the live review's own owner.
  --
  -- The End result can arrive later, so this request carries its own
  -- continuation. The operator does not press new-chat twice.
  local finished = false
  local function reset_after_release(ok, err)
    p._new_chat_pending = nil
    if not ok then
      notify_one_line(
        "yana: conversation retained because its review claim did not close: " .. tostring(err),
        vim.log.levels.WARN
      )
      return
    end
    p.review_epoch = p.review_epoch + 1
    drop_review_batch(p)
    p.session_id = nil
    p.session_seats = {}
    -- New conversation: no vendor confirmation yet.
    p.model_actual = nil
    p.title = nil
    p.turns = 0
    p.got_result = false
    p.stream_text = ""
    p.changes = {}
    p.last_question = nil
    p.last_answer_text = nil
    p.ask_advice_resend = nil
    renewal.clear(p)
    p.mode = config.panel_mode(nil)
    if buf_valid(p.conv_buf) then
      set_lines(p, 0, -1, {})
    end
    ui_M.render_greeting(p)
    update_winbar(p)
  end

  -- A callback that can arrive synchronously must not reset twice, so the
  -- guard is the request's own, not the panel flag.
  local function on_end(result)
    if finished then
      return
    end
    local status = type(result) == "table" and result.status or nil
    if status ~= "completed" then
      finished = true
      p._new_chat_pending = nil
      notify_one_line(
        "yana: conversation retained, its review has not finished ending ("
          .. tostring(status or "unknown") .. ")",
        vim.log.levels.WARN
      )
      return
    end
    finished = true
    release_shadow_turn(p, "conversation discarded", reset_after_release)
  end

  p._new_chat_pending = true
  local discarded = inline.discard_for_owner(owner, review_opts, on_end)
  if discarded == true and not finished then
    -- The discard completed without answering through the callback.
    on_end({ status = "completed" })
  end
end


----------------------------------------------------------------------
-- workspace claim recovery
----------------------------------------------------------------------

--- Applier diary session of the panel holding an apply pass, for `:YanaDump` (read-only).
local function dump_diary_session()
  for _, p in ipairs(panels) do
    if p.shadow_pass and p.shadow_pass.diary_session then
      return p.shadow_pass.diary_session
    end
  end
  return nil
end

--- Every live panel's turn ledger key, for diagnostics.
local function panel_turn_keys()
  local out = {}
  for _, p in ipairs(panels) do
    out[#out + 1] = { panel_id = p.id, gen = p.turn_gen, session_id = p.session_id, busy = p.busy }
  end
  return out
end

local function ask(selection, question)
  local p = ui_M.open()
  if not p then
    return
  end
  p.pending_selection = selection
  if question and question ~= "" then
    vim.bo[p.prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, vim.split(question, "\n", { plain = true }))
    S.submit_panel(p)
  end
end

-- Run an inline edit (Ctrl-K) as an ordinary agent turn: same selection and instruction as `M.ask`;
-- agent mode required, focus stays in the source window. Scope, hunk review, accept/reject are reached
-- by the typed-prompt path.
--
-- A chat's mode locks after its first turn (cursor-agent inherits a resumed session's mode), so an `ask`
-- panel can never serve an edit; reuse an eligible panel, else a fresh chat. The mode of a fresh panel
-- comes from config.options.mode: this only ASKS panel_write_capable, never ASSIGNS a mode (reassigning
-- the dial once flipped an `inline` session to unconfined `agentic`).
---@param selection table  from context.selection_from_range
---@param instruction string  non-empty; the user's edit request
---@return boolean started
local function inline_edit(selection, instruction)
  if not selection or type(instruction) ~= "string" or instruction == "" then
    return false
  end
  local home_capture, home_err = require("yana.input.home_buffer_proposal").capture(selection.buf)
  if home_err then
    notify_one_line("yana: " .. home_err, vim.log.levels.WARN)
    return false
  end
  if home_capture then
    selection.home_buffer_capture = home_capture
  end
  local origin_win = vim.api.nvim_get_current_win()

  local p = current_panel()
  if p and (p.busy or p.job ~= nil or p.awaiting_exit) then
    -- Queuing is wrong: pending_selection is single-valued, so a queued edit would run against the NEXT
    -- submit's selection and edit the wrong lines.
    notify_one_line("yana: still responding — stop the turn first, or wait", vim.log.levels.WARN)
    return false
  end
  if not (p and ui_M.panel_write_capable(p)) then
    -- No panel, or the current one is locked to `ask`: a fresh chat through the ONE portal (a second
    -- way to build a side pane put two in the column).
    p = open_new_panel({ focus = false })
    if not p then
      return false
    end
    if not ui_M.panel_write_capable(p) then
      -- The configured mode itself is "ask": a view must not pick another mode on the operator's behalf; refuse and say why.
      notify_one_line(
        "yana: mode is ask (read-only) — switch to inline or agentic mode first, then retry :YanaEdit",
        vim.log.levels.WARN
      )
      return false
    end
  end

  p.pending_selection = selection
  S.render_note(p, string.format("inline edit — %s L%d-%d", selection.name or "buffer", selection.l1, selection.l2))
  S.submit_panel(p, { text = instruction })

  -- Give the buffer back; the review arrives in the source buffer.
  if vim.api.nvim_win_is_valid(origin_win) then
    pcall(vim.api.nvim_set_current_win, origin_win)
  end
  return true
end

-- Build formatted report lines for a panel's system-refused operations.
local function system_refused_lines(panel)
  local p = panel or current_panel()
  local lines = { "Yana system refusals", "" }
  local rows = p and p.system_refusals or {}
  if #rows == 0 then
    lines[#lines + 1] = "No system-refused operations in the current panel."
    return lines
  end
  for _, row in ipairs(rows) do
    if row.count then
      lines[#lines + 1] = string.format(
        "turn=%s  %s  aggregate=%s/  %d op(s)  %s  retention=%s  listing=%s",
        row.turn or "?",
        row.status or "system_refused",
        row.root or "?",
        row.count,
        refusal_kind_summary(row.kind_counts),
        row.retention_strength or "momentary",
        row.listing_path or "unavailable"
      )
      local listing_ok, listing = false, nil
      if row.listing_path then
        listing_ok, listing = pcall(vim.fn.readfile, row.listing_path)
      end
      if not listing_ok or type(listing) ~= "table" then
        lines[#lines + 1] = "  listing unavailable"
      else
        for _, encoded in ipairs(listing) do
          local ok, op = pcall(vim.json.decode, encoded)
          if ok and type(op) == "table" then
            lines[#lines + 1] = string.format(
              "  turn=%s  %s  kind=%s  rel=%s  reason=%s  aggregate=%s  retention=%s  recovery=%s",
              op.turn or row.turn or "?",
              op.status or "system_refused",
              op.kind or "?",
              op.rel or "?",
              op.reason or "artifact/build output excluded from review",
              op.aggregate_root or row.root or "?",
              op.retention_strength or row.retention_strength or "momentary",
              op.recovery_path or "none"
            )
          else
            lines[#lines + 1] = "  unreadable listing row"
          end
        end
      end
    else
      lines[#lines + 1] = string.format(
        "turn=%s  %s  kind=%s  rel=%s  reason=%s  aggregate=%s  retention=%s  recovery=%s",
        row.turn or "?",
        row.status or "unsafe",
        row.kind or "?",
        row.rel or "?",
        row.reason or row.refusal_reason or "unsafe operation",
        row.aggregate_root or "none",
        row.retention_strength or "recovered",
        row.recovery_path or "none"
      )
    end
  end
  return lines
end

-- Open a scratch buffer showing the current panel's refusal report.
local function show_refusals()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, system_refused_lines())
  vim.bo[buf].modifiable = false
  vim.api.nvim_set_current_buf(buf)
end

  return {
    new_chat = new_chat,
    dump_diary_session = dump_diary_session,
    panel_turn_keys = panel_turn_keys,
    ask = ask,
    inline_edit = inline_edit,
    system_refused_lines = system_refused_lines,
    show_refusals = show_refusals,
  }
end

return M
