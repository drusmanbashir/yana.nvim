-- Whole-review abort and consequence confirmation.
local Factory = {}

function Factory.new(deps)
  local M = deps.facade
  local diff = deps.diff
  local NS = deps.ns
  local AUTH_NS = deps.authority_ns
  local ANCHOR_NS = deps.anchor_ns
  local HINT_NS = deps.hint_ns
  local queue_remove_change = deps.queue_remove_change
  local notify_one_line = deps.notify_one_line
  local change_ledger = deps.change_ledger
  local ledger = deps.ledger
  local finish_session = deps.finish_session
  local pool_for = deps.pool_for
  local review_tabs = deps.review_tabs

  --- Abort the WHOLE review: every file it touched — the active buffer and any parked
  --- or still-queued sibling — rewinds to its pre-stage state in one act, behind a
  --- confirmation dialog that discloses the consequence first.
  ---
  --- Raw `u` cannot deliver that, and the reason is structural rather than a missing
  --- key. Undo walks Neovim's tree one state at a time, and between the pre-turn file
  --- and the review there are several: each rejected hunk's restoration, whatever the
  --- operator typed, and the staging. Walking them is what "landing in the middle" IS.
  ---
  --- So this is a TRANSACTION, not a bigger undo: the decision state is unwound
  --- first, then each buffer is moved in ONE jump to its own pre-staging
  --- bookmark, then the review is closed and its marks and keymaps released. At
  --- no point is there a buffer without a review or a review without its buffer.
  ---
  --- `U` remains what it was — take back every decision and return to the review
  --- AS OPENED, hunks still staged, still deciding. This goes one bookmark
  --- further and ends the review. Both are kept because they answer different
  --- questions: "let me start these decisions again" and "take this whole thing
  --- away".
  ---
  --- SAFETY. Nothing here writes the real tree, and nothing needs to: no decision
  --- is durable while a review is open (`finish_session` is the single writer and
  --- it also closes). Aborting after the review has closed is not this operation
  --- and is refused — by then the applier has moved the real file and the answer
  --- is the journaled revert, not a buffer undo.
  ---
  --- Recoverable: each jump is `:undo {seq}`, so `<C-r>` still reaches that
  --- file's proposal until its tree is otherwise disturbed -- right up until the
  --- Yes-abort itself releases the key back to Neovim (see `M.cleanup` above).
  function M.abort_active(opts)
    local st = pool_for(opts or {})
    local state = st.active
    if not state then
      notify_one_line("yana: no review is open to abort", vim.log.levels.WARN)
      return false
    end
    -- Abort is a TRIGGER of the Turn's one two-step End, not its own door. "keep"
    -- changes nothing. The v1 undo-every-buffer-by-hand body (the whole-review confirm
    -- dialog plus the per-file rewind it drove) is gone: every review now binds a Turn,
    -- so this door always defers to `turn_bind.abort`.
    local tb = require("yana.turn_bind")
    return tb.abort(st)
  end

  -- Opens the next queued change in opts' pool, if any is pending.
  return M
end

return Factory
