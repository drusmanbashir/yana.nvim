-- Native buffer undo/redo. Neovim moves bytes; HunkLedger restores any
-- absorbed proposal transition recorded for that same undo sequence.
--
-- Both directions return one structured outcome, `{ ok, changed, reason,
-- byte_location, before_seq, after_seq }`, so the caller (`BufferEditAction`)
-- can refuse without guessing whether the buffer moved.
--
-- `byte_location` is a THIRD question, not a restatement of the first two.
-- `ok` says whether the operation succeeded; `changed` says whether anything in
-- the world is still out of place; `byte_location` says WHERE THE BYTES ENDED
-- UP, which is the only thing that can choose a compensation DIRECTION:
--   "pre_call" -- the bytes are where the call found them (never moved, moved
--                 and verifiably put back, or a command that never ran).
--   "moved"    -- the bytes are on the far side of the move and stayed there.
--   "unknown"  -- the command ran and the landing could not be read. A caller
--                 must NOT guess a direction from this; it compensates nothing
--                 and reports.
-- A boolean cannot carry three states, which is why `ok = false` appears with
-- all three of them.
local Factory = {}

--- `env` carries the review-local closures both directions need: `facade`
--- (for `M._rewind_suppress`), `state`, `bufnr`, `log` and
--- `rerender_after_history_move`. `env.current_seq` overrides the sequence
--- reader below; it is the seam a row uses to make the read fail on demand,
--- because an unreadable sequence has no other deterministic cause.
function Factory.new(env)
  local M = env.facade
  local state = env.state
  local bufnr = env.bufnr
  local log = env.log
  local rerender_after_history_move = env.rerender_after_history_move

  local current_seq = env.current_seq or function()
    local seq
    pcall(vim.api.nvim_buf_call, bufnr, function()
      seq = (vim.fn.undotree() or {}).seq_cur
    end)
    return seq
  end

  --- `touched` collects the hunks the history transition actually wrote, in the
  --- order the ledger restored them. The caller lands the operator on one of
  --- these; the file's first pending hunk is a different hunk whenever the edit
  --- was not in it.
  local function restore_ledger_history(direction, touched)
    local ledger = state.hunk_ledger
    if not ledger or not ledger.is_open or not ledger:is_open() then
      return
    end
    ledger:restore_buffer_history(direction, current_seq(), function(block)
      touched[#touched + 1] = block
      if state.model_hunks and block.model_index and state.model_hunks[block.model_index] then
        state.model_hunks[block.model_index].new_end_line = block.new_end_line
        state.model_hunks[block.model_index].new_count = #(block.new_lines or {})
      end
    end)
  end

  --- Everything ONE direction can move that is not Neovim's own bytes: the
  --- ledger's hunks and observed sequence (captured BY the ledger -- only it may
  --- read a hunk's fields), this file's model mirror, and the watcher's
  --- suspension. Taken before the move so a move that raises can be put back.
  local function capture_transaction()
    local snapshot = {
      watch_suspended = state.watch_suspended,
      watch_pending = state.watch_pending,
      watch_changes = state.watch_changes,
      models = {},
    }
    local ledger = state.hunk_ledger
    if not ledger or not ledger.is_open or not ledger:is_open() then
      return snapshot
    end
    snapshot.ledger = ledger
    snapshot.ledger_state = ledger:capture_buffer_snapshot()
    for _, block in ipairs(ledger:members()) do
      local model = state.model_hunks and block.model_index and state.model_hunks[block.model_index] or nil
      if model and snapshot.models[model] == nil then
        snapshot.models[model] = {
          new_end_line = model.new_end_line,
          new_count = model.new_count,
        }
      end
    end
    return snapshot
  end

  --- The mirror image of the ledger and model halves. The ledger half can raise
  --- (it is the half that just did), so it is pcall'd and its failure REPORTED
  --- rather than thrown: the model half is put back either way, which is what
  --- leaves the review recoverable when the ledger cannot be.
  local function restore_transaction(snapshot)
    local failure
    if snapshot.ledger then
      local ok, err = pcall(snapshot.ledger.restore_buffer_snapshot, snapshot.ledger, snapshot.ledger_state)
      if not ok then
        failure = tostring(err)
      end
    end
    for model, value in pairs(snapshot.models) do
      model.new_end_line = value.new_end_line
      model.new_count = value.new_count
    end
    return failure == nil, failure
  end

  --- The watcher is put back to WHAT WAS CAPTURED, never to literal `false` and
  --- an empty list: this move may have been made under a suspension it did not
  --- take, and edits queued before it are still owed a flush.
  ---
  --- It is also the LAST thing either path does, because
  --- `rerender_after_history_move` blanks `watch_pending`/`watch_changes` itself
  --- (`lua/yana/review_undo.lua:59-60`) -- restoring before that repaint hands
  --- the blanking a second chance.
  local function release_watcher(snapshot)
    state.watch_suspended = snapshot.watch_suspended
    state.watch_pending = snapshot.watch_pending
    state.watch_changes = snapshot.watch_changes
  end

  local function move_history(command, suppress_rewind)
    local before = current_seq()
    local function move()
      return pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd(command)
      end)
    end
    local ok, err
    if suppress_rewind then
      ok, err = pcall(M._rewind_suppress, function()
        local moved, move_err = move()
        if not moved then
          error(move_err, 0)
        end
      end)
    else
      ok, err = move()
    end
    local after = current_seq()
    if not ok then
      -- The command never ran, so nothing moved. This is the ONE failure here
      -- that can honestly promise `changed = false`.
      return { ok = false, code = "command_failed", changed = false,
        byte_location = "pre_call", reason = tostring(err) }
    end
    -- `before == after` is how this decides nothing happened, and BOTH are `nil`
    -- when the sequence cannot be read -- `nil == nil` is true, so an unreadable
    -- history would report a clean no-op over a command that already ran.
    -- Unknown is not equal.
    if type(before) ~= "number" or type(after) ~= "number" then
      return {
        ok = false,
        code = "sequence_unreadable",
        changed = true,
        -- The command RAN. Where it left the bytes cannot be read, and an
        -- unreadable sequence is not evidence of either side: UNKNOWN.
        byte_location = "unknown",
        reason = string.format(
          "native history sequence is unreadable (before=%s after=%s), so what the move did is unknown",
          tostring(before), tostring(after)),
      }
    end
    if before == after then
      -- THE ONE EXPECTED NO-OP: the history had nowhere to go. Neovim prints
      -- its own message for it, so a caller tells it apart by this CODE and
      -- never by the prose, which is a message, not an interface.
      return { ok = false, code = "no_move", changed = false,
        byte_location = "pre_call", reason = "native history did not move" }
    end
    return { ok = true, changed = true, reason = nil, byte_location = "moved",
      before_seq = before, after_seq = after }
  end

  --- The inverse of a move that raised AFTER its bytes landed: put the bytes,
  --- the ledger, the model mirror, the watcher and the paint back where the call
  --- found them, in that order -- the ledger restore has to overwrite the
  --- geometry the rollback's own `on_lines` shifts.
  ---
  --- `changed = false` is a PROMISE the router spends a register row on, so it
  --- is made only when every one of those five is verified back. Otherwise the
  --- outcome says the state moved and NAMES each part that could not be put
  --- back, which is the operator's recovery handle.
  ---
  --- Every part is attempted even after an earlier one fails, INCLUDING the case
  --- where the bytes themselves would not go back. No state is consistent then,
  --- so the choice is between a fully-defined pre-call ledger that disagrees
  --- with the buffer and a half-applied one that agrees with nothing; the former
  --- is recoverable and the reason names the disagreement. The watcher is
  --- released for the same reason -- a review left permanently suspended is a
  --- dead one.
  --- `extra_stuck` seeds the failure list with parts the CALLER already found
  --- unrecoverable -- a hook whose own rollback raised. Seeding it here is what
  --- forces `changed=true` below, so a half-restored decision stack is reported
  --- as a move that happened (the router halts/consumes the row) rather than a
  --- `changed=false` the router would leave unspent over changed state.
  local function roll_back(snapshot, outcome, direction, suppress_rewind, err, extra_stuck)
    local stuck = {}
    if type(extra_stuck) == "table" then
      for _, s in ipairs(extra_stuck) do
        stuck[#stuck + 1] = s
      end
    end
    -- WHERE THE BYTES ARE is its own question, answered here and nowhere else.
    -- `ok` cannot answer it: this rollback fails both when the bytes never left
    -- the moved side (its own command refused, `changed = false`) and when it
    -- ran but its landing is unreadable. Those need OPPOSITE compensation, so
    -- they get different locations and `unknown` gets none.
    local byte_location = "pre_call"
    local rollback = move_history(direction == "undo" and "redo" or "silent undo", suppress_rewind)
    if not rollback.ok then
      stuck[#stuck + 1] = "bytes: " .. tostring(rollback.reason)
      byte_location = rollback.changed and "unknown" or "moved"
    elseif current_seq() ~= outcome.before_seq then
      stuck[#stuck + 1] = string.format(
        "bytes: native history landed on %s, not %s", tostring(current_seq()), tostring(outcome.before_seq))
      byte_location = "unknown"
    end
    local restored, restore_err = restore_transaction(snapshot)
    if not restored then
      stuck[#stuck + 1] = "ledger: " .. tostring(restore_err)
    end
    local repainted, repaint_err = pcall(rerender_after_history_move, "native_" .. direction .. "_rollback")
    if not repainted then
      stuck[#stuck + 1] = "paint: " .. tostring(repaint_err)
    end
    release_watcher(snapshot)
    require("yana.review_undo_trace").capture("native_rollback", state, {
      direction = direction, original_move = outcome, rollback = rollback,
      byte_location = byte_location, stuck = stuck, reason = tostring(err) })
    if #stuck == 0 then
      return { ok = false, code = "rolled_back", changed = false,
        byte_location = byte_location, reason = tostring(err) }
    end
    local reason = string.format("%s; rollback failed: %s", tostring(err), table.concat(stuck, "; "))
    log.write("WARN", "yana.inline_diff native " .. direction .. ": " .. reason)
    -- `changed = true` and `byte_location = "pre_call"` together are the
    -- hook-only failure: the bytes ARE back, some other part of the world is
    -- not. The caller must compensate toward the pre-call side AND halt.
    return { ok = false, code = "rollback_stuck", changed = true,
      byte_location = byte_location, reason = reason }
  end

  --- One direction: move Neovim's history, let the ledger follow the same
  --- sequence, repaint, and release the watcher on the next tick (the move's
  --- own `on_lines` events are the history's, not a human edit).
  ---
  --- ATOMIC. Everything after the bytes land is inside one pcall, so a raise
  --- from the ledger replay or the repaint is rolled back here rather than
  --- handed up half-applied -- `BufferEditAction` cannot tell from a raised
  --- error whether the buffer moved, and would leave the row unspent over a
  --- buffer that did.
  --- `expect_seq`, when given, is the sequence the CALLER's register row names.
  --- Neovim's own `:redo` follows the newest branch of the undo tree, which is
  --- not this row's branch once the operator has undone, typed, and undone
  --- again -- so the landing has to be checked, not assumed.
  --- `hooks`, when the caller gives them, carry effects it owns that must move
  --- with this sequence and no other -- the destroyed-hunk reject a
  --- `BufferEditAction` keeps tied to its own `undo_seq`. `hooks.apply(touched)`
  --- runs INSIDE the settle transaction, after the ledger has followed the
  --- bytes and before the repaint emits `review.settled`, so a raise from the
  --- repaint rolls the effect back with everything else. `hooks.rollback()`
  --- undoes a hook that applied but could not settle; the native layer stays
  --- unaware of what the effect actually is.
  local function move_and_settle(command, suppress_rewind, direction, expect_seq, hooks)
    local snapshot = capture_transaction()
    state.watch_suspended = true
    local outcome = move_history(command, suppress_rewind)
    require("yana.review_undo_trace").capture("native_moved", state, {
      direction = direction, outcome = outcome, expect_seq = expect_seq })
    if not outcome.ok then
      log.write("WARN", "yana.inline_diff native " .. direction .. ": " .. tostring(outcome.reason))
      release_watcher(snapshot)
      return outcome
    end
    -- BEFORE the ledger replay and the repaint, because the repaint emits
    -- `review.settled` (`lua/yana/review_undo.lua:67`). A move that is about to
    -- be rolled back must not announce itself settled first.
    if expect_seq ~= nil and outcome.after_seq ~= expect_seq then
      return roll_back(snapshot, outcome, direction, suppress_rewind, string.format(
        "native history landed on %s, not this buffer edit's %s",
        tostring(outcome.after_seq), tostring(expect_seq)))
    end
    local touched = {}
    local hook_applied = false
    local settled, err = pcall(function()
      restore_ledger_history(direction, touched)
      if hooks and hooks.apply then
        hooks.apply(touched)
        hook_applied = true
      end
      rerender_after_history_move("native_" .. direction)
    end)
    if not settled then
      -- Put the caller's own effect back FIRST, then the ledger/model/bytes:
      -- the effect was applied last, so it is undone first. A rollback that
      -- itself raises is REPORTED through `extra_stuck` -- not swallowed, not
      -- merely appended to the reason -- so `roll_back` counts it and returns
      -- `changed=true`; a half-restored decision stack must reach the router as
      -- a move that happened, or the row is left unspent over changed state.
      local extra_stuck
      if hook_applied and hooks and hooks.rollback then
        local rolled, rb_err = pcall(hooks.rollback)
        if not rolled then
          extra_stuck = { "hook: " .. tostring(rb_err) }
          log.write("WARN", "yana.inline_diff native " .. direction .. ": hook rollback failed -- " .. tostring(rb_err))
        end
      end
      return roll_back(snapshot, outcome, direction, suppress_rewind, err, extra_stuck)
    end
    vim.schedule(function()
      release_watcher(snapshot)
    end)
    require("yana.review_undo_trace").capture("native_settled", state, {
      direction = direction, outcome = outcome })
    outcome.touched_blocks = touched
    return outcome
  end

  local function native_undo(suppress_rewind, expect_seq, hooks)
    return move_and_settle("silent undo", suppress_rewind, "undo", expect_seq, hooks)
  end

  --- Plain `:redo`, unsilenced (Neovim's own "Already at newest change"
  --- shows when there is nothing left), then repainted. `_` is the unused
  --- suppression flag, so both directions share one call shape.
  local function native_redo(_, expect_seq, hooks)
    return move_and_settle("redo", false, "redo", expect_seq, hooks)
  end

  return {
    reverse = native_undo,
    forward = native_redo,
  }
end

return Factory
