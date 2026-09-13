-- Turn-completion callbacks (process exit / vendor confirmation), split out of yana.ui
-- (cluster 6, back third -- see yana.ui_events's header for the front third and
-- yana.ui_turn_shadow's for the middle third that this module's
-- `on_done`/`on_exit_confirmed` call into via `S.finalize_shadow_turn`).
-- `M._test.force_turn_edits` (a test-only mutation hook `on_done` reads) is reached
-- through `deps.M` -- the parent's own module table, never reassigned, so this resolves
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local sessions = require("yana.sessions")
local uv = vim.uv or vim.loop

local M = {}

-- deps.state: the parent's shared state table `S` -- read S.shadow_turn_gen (set by
-- yana.ui_events's facade), S.submit_panel, S.maybe_drain_queue, S.finalize_shadow_turn
-- (set by yana.ui_turn_shadow's facade). deps.turn_evidence_dir: yana.ui_events facade
-- local. deps.append / deps.render_error / deps.backend_label: yana.ui_render facade
-- locals.
function M.new(deps)
  local S = deps.state
  local shadow_turn_gen = S.shadow_turn_gen
  local turn_evidence_dir = deps.turn_evidence_dir
  local append = deps.append
  local render_error = deps.render_error
  local backend_label = deps.backend_label
  local turn_ledger = deps.turn_ledger
  local inline_review_opts = deps.inline_review_opts
  local flush_review_batch = deps.flush_review_batch
  local emit_turn_end = deps.emit_turn_end
  local build_apply_resend = deps.build_apply_resend
  local update_winbar = deps.update_winbar
  local panel_open = deps.panel_open
  local stop_spinner = deps.stop_spinner
  local buf_valid = deps.buf_valid
  local ui_M = deps.M

-- Row 69: the ONE stderr line that names the failure. Usually the vendor's last line.
-- Gate: tests/headless/r_codex_resume_argv_accepted_by_vendor.lua (C).
local function last_stderr_line(stderr)
  if not stderr or stderr == "" then
    return nil
  end
  local ls = vim.split(stderr, "\n", { plain = true, trimempty = true })
  for _, l in ipairs(ls) do
    if l:match("^%s*[Ee]rror:%s*%S") then
      return l
    end
  end
  return ls[#ls]
end
----------------------------------------------------------------------
-- session persistence
----------------------------------------------------------------------

-- Record the panel's session in the registry and snapshot the rendered
-- conversation so it can be listed and resumed later.
local function persist_session(p)
  if not p.session_id or p.session_id == "" then
    return
  end
  sessions.record({
    id = p.session_id,
    title = p.title,
    cwd = p.cwd or vim.fn.getcwd(),
    mode = config.panel_mode(p.mode),
    model = config.options.model,
    backend = config.options.backend,
    turns = p.turns,
  })
  local transcript_written = false
  if buf_valid(p.conv_buf) then
    sessions.save_transcript(p.session_id, vim.api.nvim_buf_get_lines(p.conv_buf, 0, -1, false))
    transcript_written = true
  end
  if p.image_attachments and #p.image_attachments > 0 then
    sessions.save_attachments(p.session_id, p.image_attachments)
  end

  -- Invariant capture: a transcript on disk with no registry row is a session
  -- that cannot be listed or resumed — the work is there and unreachable. Both
  -- facts are in hand here, once per persist: the row from the registry the
  -- record above just wrote, and one stat for the transcript. The registry
  -- FILE is checked too, because the in-memory cache would agree with itself
  -- even when the write failed.
  do
    -- Read the registry FILE, not sessions.get(): the cache is written by
    -- sessions.record() BEFORE save_registry() attempts the file, so a check
    -- built on it compares the cache with itself and reports health for a
    -- registry the product could not write. The size>0 heuristic that stood
    -- beside it was no better — a file holding `{}` passes it. One small read
    -- per persist, wrapped so that observing a turn can never break it.
    local ok_reg, row_present, registry_status = pcall(sessions.registry_row_on_disk, p.session_id)
    if not ok_reg then
      row_present, registry_status = false, "unreadable"
    end
    local registry_file = sessions.registry_file()
    local reg_stat = uv.fs_stat(registry_file)
    local missing = transcript_written and not row_present
    local L = turn_ledger(p)
    ledger.record_session_check(L, {
      session_id = p.session_id,
      registry_row = row_present and true or false,
      registry_status = registry_status,
      registry_file = registry_file,
      registry_bytes = reg_stat and reg_stat.size or 0,
      transcript = transcript_written,
      missing = missing and true or false,
    })
    if missing and L.session_check_sig ~= p.session_id then
      L.session_check_sig = p.session_id
      log.write(
        "WARN",
        string.format(
          "yana.ui: session registry row missing for %s after writing its transcript (registry %s, %d bytes, on-disk status %s) — the session will not be listable or resumable",
          tostring(p.session_id),
          registry_file,
          reg_stat and reg_stat.size or 0,
          tostring(registry_status)
        )
      )
    end
  end
end
local function on_done(p, gen, code, stderr, agent_outcome)
  if gen ~= p.turn_gen then
    return
  end
  local L = ledger.ensure(p.id, gen)
  ledger.set_current_event(L, nil)
  p.busy = false
  local cancelled = p.cancelled
  p.cancelled = false
  local completed_turn = p.job_shadow_turn or p.shadow_turn
  -- jobstop() → exit 143 (SIGTERM). Intentional cancel already noted in the panel.
  local job_failed = (code ~= 0)
  if job_failed and not p.got_result and not cancelled then
    -- A real exit code is never -1 (jobstop() -> 143, a real vendor failure -> its own
    -- nonzero code), so this split changes nothing about a real process's rendered
    -- error.
    local msg
    if code == -1 and stderr and stderr ~= "" then
      msg = stderr
    else
      local last_line = last_stderr_line(stderr)
      msg = last_line or (backend_label() .. " process exited with no output")
    end
    render_error(p, msg, {
      exit_code = code,
      evidence_dir = turn_evidence_dir(p),
    })
    p.turn_errored = true
    -- RULINGS-MAP #103. AFTER the render, never instead of it: the launcher's sentence
    -- is the record and the gates match on it, so it is in the panel before anything
    -- else happens and stays there whatever the operator answers. The prompt is
    -- housekeeping beside it -- it decides nothing, and a dismissal is a no-op
    -- (review-apply.md:114-116, the same rule the close-tabs prompt is held to).
    pcall(function()
      local turn = p.job_shadow_turn or p.shadow_turn
      local ap = turn and turn.yanad_answer_out
      if type(ap) ~= "string" or ap == "" or vim.fn.filereadable(ap) ~= 1 then
        return
      end
      local raw = table.concat(vim.fn.readfile(ap), "\n")
      local okj, ans = pcall(vim.json.decode, raw)
      if okj and type(ans) == "table" and type(ans.refuse) == "table" then
        require("yana.review_open_prompt").offer_from_refuse(ans.refuse)
      end
    end)
  end

  -- Close-turn outcome FIRST so release's turn.end (and the agentic no-claim
  -- path below) can serialise it. Row 85: plumbing, not a second schema.
  local turn_changes, turn_pending = 0, 0
  local gen_changes = {}
  for _, c in ipairs(p.changes or {}) do
    if c.turn_gen == gen then
      turn_changes = turn_changes + 1
      gen_changes[#gen_changes + 1] = c
    end
  end
  do
    local ok_inline, inline = pcall(require, "yana.inline_diff")
    if ok_inline then
      turn_pending = inline.turn_undecided_hunks({
        changes = gen_changes,
        opts = inline_review_opts(p),
      })
    end
  end
  local outcome = {
    exit_code = code,
    stderr_len = stderr and #stderr or 0,
    got_result = p.got_result and true or false,
    turn_errored = p.turn_errored and true or false,
    cancelled = cancelled and true or false,
    changes = turn_changes,
    changes_pending = turn_pending,
    queued = #p.queue,
    session_id = p.session_id,
    shell_steps_total = p.shell_steps_total or 0,
    shell_steps_failed = p.shell_steps_failed or 0,
    generation = gen,
    panel = p.id,
    turn_id = p.turn_pass and p.turn_pass.turn_id or nil,
    argv0 = agent_outcome and agent_outcome.argv0 or nil,
  }
  p.turn_end_outcome = p.turn_end_outcome or {}
  p.turn_end_outcome[gen] = outcome
  ledger.close_turn(L, outcome)
  if (p.shell_steps_failed or 0) > 0 then
    require("yana.log").write(
      require("yana.log").levels.WARN,
      string.format(
        "yana: turn finished with %d failed shell command(s) (first exit %s: %s)",
        p.shell_steps_failed,
        tostring(p.first_failed_shell_exit),
        tostring(p.first_failed_shell_command or "?")
      )
    )
    update_winbar(p)
  end

  local turn = completed_turn
  if turn and tostring(shadow_turn_gen(turn, p)) == tostring(gen) then
    S.finalize_shadow_turn(p, turn)
  end
  -- Idempotent; normally a no-op because on_exit_confirmed already flushed
  -- (agent.lua fires it first). This call exists for the spawn-failure path,
  -- which calls on_done(-1) synchronously and never produces an exit at all.
  flush_review_batch(p)

  -- p.job / awaiting_exit / job_spawn_gen: owned by on_exit_confirmed only
  -- (agent.lua fires that first). Never clear them here — a live turn's
  -- drain/redirect may already own a newer job by the time a stale on_done
  -- would have run, and even the live-path clear races that contract.
  p.active_turn_scope = nil
  stop_spinner(p)
  update_winbar(p)
  persist_session(p)

  -- Recalc witness AFTER finalize: overlay walk may have just appended changes.
  turn_changes, turn_pending = 0, 0
  gen_changes = {}
  for _, c in ipairs(p.changes or {}) do
    if c.turn_gen == gen then
      turn_changes = turn_changes + 1
      gen_changes[#gen_changes + 1] = c
    end
  end
  do
    local ok_inline, inline = pcall(require, "yana.inline_diff")
    if ok_inline then
      turn_pending = inline.turn_undecided_hunks({
        changes = gen_changes,
        opts = inline_review_opts(p),
      })
    end
  end
  outcome.changes = turn_changes
  outcome.changes_pending = turn_pending
  p.turn_end_outcome[gen] = outcome
  ledger.close_turn(L, outcome)

  -- Emit turn.end once process outcome is known. * Zero-edit inline: finalize already
  -- released and emitted (may have lacked the post-finalize change counts — re-emit is
  -- suppressed by turn_end_emitted). * Review still open: pass stays; emit turn.end
  -- WITHOUT closing the pass.
  local end_reason = p.turn_end_reasons and p.turn_end_reasons[tostring(gen)] or nil
  if not (p.turn_end_emitted and p.turn_end_emitted[gen]) then
    if not end_reason and not cancelled and not p.turn_errored and turn_changes == 0 and turn_pending == 0 and #p.queue == 0 then
      end_reason = "no_changes"
    end
    end_reason = end_reason or "process exited"
    if p.turn_end_reasons then
      p.turn_end_reasons[tostring(gen)] = nil
    end
    if p.turn_pass and tostring(p.turn_pass.generation) == tostring(gen) and p.shadow_turn == nil then
      local pass = p.turn_pass
      require("yana.turn_lifecycle").close_turn(pass, end_reason)
      emit_turn_end(p, pass, end_reason, outcome)
      p.turn_pass = nil
    else
      emit_turn_end(p, p.turn_pass, end_reason, outcome)
    end
  elseif p.turn_end_emitted and p.turn_end_emitted[gen] then
    -- Released during finalize before post-finalize recalc: the first emit may
    -- have carried changes=0 correctly for the empty walk. Nothing more to do.
    if p.turn_end_reasons then
      p.turn_end_reasons[tostring(gen)] = nil
    end
  end

  -- Drain one queued follow-up (queued via S.submit_panel while p.busy was
  -- true). Zero-edit advice must be decided BEFORE draining. Row 85: the
  -- turn_edits loop already existed for ask; extend it for edit-capable modes.
  -- Witness is p.changes for this generation (and optional force_turn_edits
  -- mutation hook) — NEVER a vendor subtype / tool_calls field.
  local resolved_mode = p.turn_modes and p.turn_modes[gen]
  local turn_edits = turn_changes
  if type(ui_M._test.force_turn_edits) == "number" then
    turn_edits = ui_M._test.force_turn_edits
  end
  if not cancelled and not p.turn_errored and turn_edits == 0 and #p.queue == 0 then
    if resolved_mode == "ask" then
      local completed_question = p.turn_questions and p.turn_questions[gen]
      local completed_answer = p.turn_answers and p.turn_answers[gen]
      if completed_question and completed_question ~= "" then
        p.ask_advice_resend = build_apply_resend(completed_question, completed_answer)
      end
      local k = config.options.mappings
      local resend_hint
      if k.resend and k.resend ~= "" then
        resend_hint = k.resend .. "a"
      else
        resend_hint = ":YanaResend agent"
      end
      append(p, {
        "",
        "_Ask mode cannot apply edits, and this conversation's mode is locked. Press "
          .. resend_hint
          .. " to resend this prompt in a new Agent conversation._",
        "",
      })
    end
    if resolved_mode ~= "ask" then
      append(p, {
        "",
        "_This turn produced no reviewable changes._",
        "",
      })
      log.write("WARN", string.format(
        "turn produced no reviewable changes (gen=%s exit_code=%s got_result=%s cancelled=%s reason=%s argv0=%s)",
        tostring(gen),
        tostring(outcome and outcome.exit_code),
        tostring(outcome and outcome.got_result),
        tostring(outcome and outcome.cancelled),
        tostring(end_reason),
        tostring(outcome and outcome.argv0)
      ))
      if p.turn_end_reasons then
        p.turn_end_reasons[tostring(gen)] = "no_changes"
      end
    end
  end

  S.maybe_drain_queue(p)

  -- A turn that never established an upstream session must not consume lock
  -- authority (spawn failure, early agent exit before init).
  if job_failed and not cancelled and p.turns > 0 then
    p.turns = p.turns - 1
  end
end
local function on_exit_confirmed(p, gen, _code)
  if p.job_spawn_gen ~= gen then
    return -- a newer job owns the panel; this is a late old exit
  end
  do
    local L = ledger.ensure(p.id, gen)
    ledger.mark(L, "exit_confirmed")
    ledger.set_current_event(L, nil)
  end
  -- Overlay consume first, then the report-batch flush. This is the only callback that
  -- fires for EVERY job death: a cancelled turn bumps turn_gen, so its on_done
  -- early-returns at the generation gate and would strand the overlay (and the old
  -- report batch) forever — unreviewed and unrevertable. It also must precede both the
  -- pending_redirect submit and the was_awaiting drain below, or a new turn starts
  -- owning the old turn's batch.
  local captured = p.job_shadow_turn
  -- job_shadow_turn is already bound to this job, and job_spawn_gen above
  -- proved this callback owns that job. Older/recovered turn records may not
  -- carry turn_gen; stamp the generation from the validated job boundary
  -- instead of falling back to p.turn_gen, which may already have advanced.
  if captured and captured.turn_gen == nil then
    captured.turn_gen = gen
  end
  if captured and tostring(shadow_turn_gen(captured, p)) == tostring(gen) then
    S.finalize_shadow_turn(p, captured)
  elseif p.shadow_turn and tostring(shadow_turn_gen(p.shadow_turn, p)) == tostring(gen) then
    S.finalize_shadow_turn(p, p.shadow_turn)
  end
  flush_review_batch(p)
  p.job = nil
  p.job_spawn_gen = nil
  p.job_shadow_turn = nil
  local was_awaiting = p.awaiting_exit
  p.awaiting_exit = false
  local text = p.pending_redirect
  p.pending_redirect = nil
  update_winbar(p)
  local held = p.shadow_turn ~= nil
  if text then
    if held or not panel_open(p) then
      -- Held: prior turn is finalized but not released (review open). Do not
      -- start a new jailed turn on top of it. Closed panel: same as before.
      table.insert(p.queue, 1, text)
    else
      S.submit_panel(p, { text = text, redirect = true })
    end
  elseif was_awaiting and not held then
    -- Prompts submitted while the exit was pending queued up; fire them now.
    S.maybe_drain_queue(p)
  end
end
local function set_model_actual(p, gen, model)
  if gen ~= p.turn_gen then
    return
  end
  p.model_actual = model
  update_winbar(p)
end

  return {
    last_stderr_line = last_stderr_line,
    persist_session = persist_session,
    on_done = on_done,
    on_exit_confirmed = on_exit_confirmed,
    set_model_actual = set_model_actual,
  }
end

return M
