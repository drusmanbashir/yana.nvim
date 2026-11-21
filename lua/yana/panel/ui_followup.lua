-- Size split of ui_turn_end.lua and ui_turn_shadow.lua: a follow-up on an open review, from its prompt to its
-- publication (panel rules F-ADDENDUM-TRIGGER, -NO-RESUME, -MEMORY, -PUBLISH, -RECOMPUTE,
-- F-PROMPT-HANDOVER; plan followup-addendum-turn.md "### Publication and
-- history"). ui_submit asks `follow_up`, then `begin_follow_up` / `drop_launch`; ui_turn_shadow hands a refused
-- launch to `launch_refused` and a recorded result to `publish_result`.
local say = require("yana.notify").one_line
local prompts = require("yana.prompts")
local clog = require("yana.turn.turn_cycle_log")

local M = {}

-- The panel doors this route uses, handed over by the factories that own them: ui_turn_end (review_opts =
-- ui_review's inline_review_opts, flush = flush_review_batch) and ui_turn_shadow (render_error,
-- render_tool_change, preview, turn_ledger, shadow_turn_gen, set_review_bundle, finish_handover).
local doors = {}
function M.set_doors(t) for k, v in pairs(t) do doors[k] = v end end

-- F-ADDENDUM-MEMORY: the one bounded Yana line before the operator's text: this continues the open review, the
-- paths whose hunks (or proposed operation) were rejected, and the buf-3 note.
function M.rejected_paths(turn)
  local rejected = {}
  for _, f in ipairs(turn.files) do
    if (f.ledger and f.ledger:count("rejected") > 0) or f.operation_verdict == "rejected" then
      rejected[#rejected + 1] = (f.change and f.change.rel) or f.path
    end
  end
  table.sort(rejected)
  return rejected
end

function M.prompt_line(turn)
  local rejected = M.rejected_paths(turn)
  local names = #rejected == 0 and prompts.render("followup_no_files") or table.concat(vim.list_slice(rejected, 1, 8), ", ")
    .. (#rejected > 8 and prompts.render("followup_more_files", { count = #rejected - 8 }) or "")
  return prompts.render("followup_open_review", { files = names })
end

-- A handover is waiting on release, the first review receipt, or an in-progress publication.
function M.handover_waiting(p)
  local session = p.shadow_turn or p.mcp_run
  if not session then return false end
  if session.result_release_pending or (session.review_open_requested and session.review_open_marked == nil) then
    return true
  end
  local owner = require("yana.turn.turn_cycle").run_of(session).owner
  local state = owner and owner.state
  return state == "preparing" or state == "publishing"
end

-- Route a prompt to the current review once its publication permits a new run.
function M.follow_up(p, question)
  local session = p.shadow_turn or p.mcp_run
  if M.handover_waiting(p) then return "handover" end
  local turn = require("yana.turn.turn_bind").get()
  local function refused(code)
    clog.submit_refused(code, { turn_id = session.turn_id, panel_id = p.id, resume_id = p.session_id,
      generation = doors.shadow_turn_gen and doors.shadow_turn_gen(session, p) or nil })
  end
  local owned = turn ~= nil and vim.iter(turn.files):any(function(f)
    return f.change ~= nil and tostring(f.change.turn_id) == tostring(session.turn_id) end)
  if owned and turn:cycles().state == "recovery_required" then
    refused("recovery_required")
    say("yana: follow-up refused -- the last follow-up result was not published; End or Abort the review",
      vim.log.levels.WARN)
    return M.restore_prompt(p, question)
  end
  if not owned or turn:cycles().state ~= "reviewing" or session.review_open_marked == false then
    refused("review_unavailable")
    say("yana: follow-up refused because the review is unavailable. Resolve the review before resubmitting.",
      vim.log.levels.WARN)
    return M.restore_prompt(p, question)
  end
  if not p.session_id or p.session_id == "" then
    refused("no_resume")
    say("yana: follow-up refused -- this conversation has no resume ID; End or Abort the review, then start a "
      .. "new chat", vim.log.levels.WARN)
    return M.restore_prompt(p, question)
  end
  return { turn = turn, turn_id = session.turn_id, cycles = turn:cycles(), prior = session, line = M.prompt_line(turn) }
end

-- Restore an unsent submission before any new draft without losing either.
function M.restore_prompt(p, question)
  if p.prompt_buf and vim.api.nvim_buf_is_valid(p.prompt_buf) then
    local draft = table.concat(vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false), "\n")
    if draft ~= "" then question = question .. "\n\n" .. draft end
    vim.bo[p.prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, vim.split(question, "\n", { plain = true }))
  end
  return "refused"
end

-- Capture the CycleInput at submit and start the next Run on the same Turn. The overlay also includes
-- snapshotted buffers outside the review. Adopt cycle 1 first. Return false if the new Run cannot start.
function M.begin_follow_up(p, follow, gen)
  local turn_cycle, cycles, turn = require("yana.turn.turn_cycle"), follow.cycles, follow.turn
  if #cycles.runs == 0 and cycles:begin_run(follow.prior, follow.prior.turn_pass, nil) then
    cycles:set_state("reviewing")
  end
  local session = p.shadow_turn or p.mcp_run
  local ws, buffers = session.workspace, {}
  for _, f in ipairs(turn.files) do
    ws = (f.change and f.change.review_workspace) or (f.review_opts and f.review_opts.workspace) or ws
  end
  for path, snap in pairs((p.turn_buffer_captures or {})[gen] or {}) do
    buffers[#buffers + 1] = { path = path, bufnr = snap.bufnr }
  end
  local files = turn_cycle.input_files(turn, buffers)
  if session.source == "buffer" then
    -- MCP keeps non-members in its submit snapshots. Their first proposal uses the engine's first-run path.
    files = vim.tbl_filter(function(entry) return entry.member end, files)
  end
  local register = require("yana.turn.turn_register").for_workspace(ws)
  local input, why = turn_cycle.capture_input({ turn_id = follow.turn_id, workspace_id = ws, workspace = ws,
    pass = p.turn_pass, cycle_id = cycles:next_cycle_id(), register = register, files = files,
    seq_of = require("yana.undo_action_followup_cycle").seq_of })
  local run
  if input then run, why = cycles:begin_run(session, p.turn_pass, input) end
  if not run then
    if input then turn_cycle.release_input(input, register) end
    clog.submit_refused(input and "run_refused" or "input_not_captured", { turn_id = follow.turn_id, panel_id = p.id, generation = gen,
      resume_id = p.session_id })
    say("yana: follow-up not started -- " .. tostring(why or "the run was refused"), vim.log.levels.WARN)
    M.drop_launch(p, follow)
    return false
  end
  -- run.review_opts: the cycle's write door for every member (S4 `File:install_version`), on this run's live pass.
  run.prior_session, run.register, run.workspace = follow.prior, register, ws
  run.review_opts = function(file) return doors.review_opts(p, file and file.change) end
  p.turn_followups = vim.tbl_extend("force", p.turn_followups or {}, { [gen] = true })
  clog.submit_started(run, input, { resume_id = p.session_id, prefix = follow.line ~= nil,
    rejected = #M.rejected_paths(turn) })
  return true
end

-- A follow-up launch that will not run: the Turn gets its prior session back, input released, reviewing again.
function M.drop_launch(p, follow)
  local run = require("yana.turn.turn_cycle").recording_run(p.shadow_turn or p.mcp_run)
  if run then
    follow.cycles:release_run(run, run.register)
    if follow.cycles:current() == run then table.remove(follow.cycles.runs) end
  end
  follow.cycles:set_state("reviewing")
  if follow.prior.source == "buffer" then p.mcp_run = follow.prior else p.shadow_turn = follow.prior end
end

-- A refused follow-up launch (S2): an unconfirmed writer exit stays a running follow-up; a daemon too old for
-- turn.resume says so in one line and keeps the prompt; any refusal gives the Turn its prior run back.
function M.launch_refused(p, run, code, reason)
  local stale = code == "unknown_command"
  clog.submit_launch_refused(run, stale and "stale_daemon" or code or "launch_refused")
  if code == "writer_unconfirmed" then
    clog.result(run, run.session_ref and run.session_ref.s, p, nil, true)
    return doors.render_error(p, "follow-up writer exit unconfirmed (" .. tostring(reason) .. "); the review stays as it was")
  elseif code == "unknown_command" then
    doors.render_error(p, "Yana's background daemon is older than this plugin: close all Neovim sessions (the daemon "
      .. "restarts) and resubmit")
    local question = p.turn_questions and p.turn_questions[run.run_generation]
    local typed = vim.trim(table.concat(vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false), "\n"))
    if question and typed == "" then M.restore_prompt(p, question) end
  else
    doors.render_error(p, "follow-up launch refused: " .. tostring(code or reason) .. "; the prior review is kept")
  end
  run.owner:release_run(run, run.register)
  run.owner:set_state("reviewing")
  if run.prior_session.source == "buffer" then p.mcp_run = run.prior_session else p.shadow_turn = run.prior_session end
end

-- Not published: the prior review stays and the result and its pins are kept (retryable). A failed compensation
-- or an unacknowledged durable review record is `recovery_required` (End/Abort/Reset stay reachable; no new cycle).
-- Once the daemon acknowledged R2 (`run.acked`), a local failure leaves durable R2 and local R1 apart: never
-- ordinary reviewing again; recovery_required, reconciled only by End or Abort (they close both; Reset refuses).
local function unpublished(p, run, code, reason, prepared)
  local recovery = run.acked or code == "halted"
  clog.publish(run, recovery and "recovery_required" or "refused", code, prepared)
  if recovery then
    doors.render_error(p, "follow-up result acknowledged but not shown -- " .. tostring(reason)
      .. "; End or Abort the review to reconcile")
    run.owner:set_state("recovery_required")
    return doors.finish_handover(p)
  end
  doors.render_error(p, "follow-up result not published -- " .. tostring(reason) .. "; the prior review is kept")
  run.owner:set_state("reviewing")
  doors.finish_handover(p)
end

-- A refused run's files, for `:YanaRefusals` and the next prompt's decision note: the agent would otherwise resume
-- believing its changes landed.
function M.record_refused_run(p, session, changes, reason)
  p.system_refusals = p.system_refusals or {}
  for _, change in ipairs(changes) do
    p.system_refusals[#p.system_refusals + 1] = { status = "system_refused", turn = session.turn_id, rel = change.rel,
      kind = change.kind, reason = reason, retention_strength = "recovered" }
  end
end

-- A refused result (over review.max_files, or with an unsafe operation) is never prepared or shown: its files are copied to a recovery folder and the open
-- review stays as it was. Hunk decisions, End and Abort still work; no further follow-up starts until it closes.
function M.refuse_result(p, session, run, changes, reason)
  M.record_refused_run(p, session, changes, reason)
  local folders, err = doors.preview().recover_run(session, changes)
  clog.publish(run, "recovery_required", "too_large")
  -- The daemon holds the stopped run's Turn until a review is published; republish the open one unchanged, as a
  -- follow-up that changed nothing does, so End and Abort can close it.
  local members = {}
  for _, f in ipairs(require("yana.turn.turn_bind").get().files) do
    members[#members + 1] = f.change
  end
  doors.set_review_bundle(session, members, run.prior_session and run.prior_session.review_bundle)
  doors.preview().arm_review_open(session, function(ok)
    if not ok then doors.render_error(p, "the daemon did not acknowledge the kept review (review.open)") end
  end)
  local recover = not folders and ("; recover it at nowhere (" .. tostring(err) .. ")")
    or #folders > 0 and ("; recover it at " .. table.concat(folders, " and "))
    or ""
  doors.render_error(p, string.format("follow-up result not shown -- %s; nothing was applied%s; the open review is"
    .. " kept: accept what you want and End, or Abort", reason, recover))
  return run.owner:set_state("recovery_required")
end

-- A newly changed file joins the publication through the first-run door: render and batch flush admit its Turn
-- membership and open its review. The action owns native endpoints; these callbacks own panel membership.
local function join_new_file(p, live, f)
  local change = f.change
  local path = require("yana.diff").abs_path(change.path)
  -- A redo of the publication re-admits the change its undo withdrew (kept_unreviewed) as pending again.
  change.review_withdrawn = nil
  change.status = "pending"
  table.insert(p.changes, change)
  doors.render_tool_change(p, change)
  doors.flush(p)
  return { file = assert(live:file(require("yana.diff").abs_path(change.path)), "the new file did not join the Turn") }
end

-- Rollback of a join: Turn membership, its attached review and the panel's change record.
local function withdraw_new_file(p, path, change, forget_uncommitted_history)
  local st = require("yana.inline_diff")._pool_for(doors.review_opts(p, change))
  local state = st and st.open[change]
  if state then
    local closed = require("yana.review_lifecycle").cleanup(state)
    if not closed then return false end
    local turn = require("yana.turn.turn_bind").get()
    if turn then
      local detached = turn:detach_review(require("yana.diff").abs_path(path), state)
      if not detached then return false end
    end
  end
  for _, list in ipairs({ st and st.queue or {}, st and st.order or {} }) do
    for i = #list, 1, -1 do
      if list[i] == change or list[i].change == change then table.remove(list, i) end
    end
  end
  change.status = "kept_unreviewed"
  change.review_withdrawn = true
  doors.render_review_status(p)
  for i = #(p.changes or {}), 1, -1 do
    if p.changes[i] == change then table.remove(p.changes, i) end
  end
  doors.render_review_status(p)
  local abs = require("yana.diff").abs_path(path)
  if require("yana.turn.turn_bind").withdraw_unopened(abs) ~= true then return false end
  if forget_uncommitted_history then
    local turn = require("yana.turn.turn_bind").get()
    if turn and not turn:forget_uncommitted_review(abs) then return false end
    require("yana.review_open_bind_keys").sync_queued()
  end
  return true
end

-- A follow-up run's recorded result (plan "### Publication and history"; F-ADDENDUM-PUBLISH, -RECOMPUTE,
-- F-PROMPT-HANDOVER): waits until the review buffers have left Insert and their edit groups are flushed (no forced
-- Insert break) and is prepared; the cumulative review is recorded durably first (review.open; review.none would
-- close the Turn) and only its acknowledgement commits the publication locally, as ONE register row across every
-- affected file, new ones included. Then the run is released and a held prompt starts the next cycle.
function M.publish_result(p, turn, run, attempt)
  local live, cycle = require("yana.turn.turn_bind").get(), require("yana.turn.turn_cycle")
  local publication = require("yana.undo_action_followup_cycle")
  if not live or run.published then return doors.finish_handover(p) end
  if not run.result_logged then
    run.result_logged = true
    clog.result(run, turn, p, nil, false)
  end
  local states, files, members = {}, {}, {}
  for _, f in ipairs(live.files) do
    local path = cycle.canonical_path(f.path)
    states[path], files[path], members[#members + 1] = f.review_state, f, f.change
  end
  local wait = publication.blocking(states)
  if wait and not run.wait_logged then
    run.wait_logged = true
    clog.publish(run, "waiting_insert", wait.bufnr and "insert_mode" or "edit_group_open")
  end
  if wait and wait.bufnr then
    return vim.api.nvim_create_autocmd("InsertLeave", { buffer = wait.bufnr, once = true, callback = function()
      vim.schedule(function() M.publish_result(p, turn, run, attempt) end)
    end })
  elseif wait then
    return vim.defer_fn(function() M.publish_result(p, turn, run, attempt) end, 20)
  end
  local prepared = run.owner:prepare_publication(run, cycle.view_of(live, run.register))
  local failed = next(prepared.failures)
  if failed then return unpublished(p, run, "failed", failed .. ": " .. tostring(prepared.failures[failed]), prepared) end
  if not run.acked then
    for _, path in ipairs(prepared.order) do
      local change = prepared.files[path].mode == "first_run" and prepared.files[path].change
      if change then
        change.turn_gen, change.turn_id, change.panel_id = doors.shadow_turn_gen(turn, p), turn.turn_id, p.id
        members[#members + 1] = change
      end
    end
    doors.set_review_bundle(turn, members, run.prior_session and run.prior_session.review_bundle)
    return doors.arm_review_open(turn, function(ok)
      if not ok then return unpublished(p, run, "halted", "the daemon did not acknowledge the review (review.open)") end
      run.acked = true
      require("yana.ledger").mark(doors.turn_ledger(p, doors.shadow_turn_gen(turn, p)), "review_claim_open")
      M.publish_result(p, turn, run, attempt)
    end)
  end
  local row, err = publication.commit_publication(prepared, { register = run.register, workspace = run.workspace,
    states = states, files = files, turn_id = turn.turn_id, results = run.result.files, review_opts = run.review_opts,
    join = function(_, f) return join_new_file(p, live, f) end,
    was_reviewed = function(path) return live:reviewed_paths()[path] == true end,
    leave = function(path, change, forget_history) return withdraw_new_file(p, path, change, forget_history) end })
  if err and err.code == "stale" and (attempt or 0) < 5 then
    clog.publish(run, "refused", "stale_retry", prepared)
    run.owner:set_state("preparing")
    return vim.schedule(function() M.publish_result(p, turn, run, (attempt or 0) + 1) end)
  elseif err then
    return unpublished(p, run, err.code, err.reason, prepared)
  end
  clog.publish(run, "published", "ok", prepared, type(row) == "table" and row.idem_key or prepared.idem_key)
  run.published, run.row = true, row
  run.owner:set_state("publishing")
  run.owner:release_run(run, run.register)
  run.owner:set_state("reviewing")
  live:refresh_review_liveness()
  local tabs_ok, tabs_err = pcall(function()
    require("yana.inline_diff").reopen_pending_review_tabs(live, run.review_opts)
  end)
  if not tabs_ok then
    doors.render_error(p, "follow-up review tabs could not be restored: " .. tostring(tabs_err))
  end
  doors.finish_handover(p)
end

return M
