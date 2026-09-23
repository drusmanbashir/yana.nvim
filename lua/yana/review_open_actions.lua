local review_open_save_factory = require("yana.review_open_save")
-- Decision, undo, save, and bulk actions for one open review.
local Factory = {}

function Factory.new(deps)
  local env = setmetatable({}, {
    __index = function(_, key)
      local value = deps[key]
      if value ~= nil then
        return value
      end
      return _G[key]
    end,
  })
  local function setup()
  local function record_last_hunk_decided(action, block)
    log.lifecycle_later("review.last_hunk_decided", {
      turn_id = change.turn_id or change.turn_gen,
      generation = change.turn_gen,
      path = change.rel or change.path,
      change_id = change.id,
      action = action,
      hunk = block and block.model_index or nil,
    })
  end

  local review_decisions = M._review_decisions_factory.new({
    state = state,
    change = change,
    bufnr = bufnr,
    facade = M,
    ns = NS,
    authority_ns = AUTH_NS,
    anchor_ns = ANCHOR_NS,
    hint_ns = HINT_NS,
    diff = diff,
    park_decision_anchor = park_decision_anchor,
    break_undo_block = break_undo_block,
    live_block_range = live_block_range,
    reject_restoration = reject_restoration,
    record_decision = record_decision,
    notify_one_line = notify_one_line,
    buf_undo_seq = buf_undo_seq,
    remove_block = remove_block,
    render_blocks = render_blocks,
    land_on = land_on,
    nearest_block = nearest_block,
    current_block = current_block,
    finish_session = finish_session,
    pool_for = pool_for,
    record_last_hunk_decided = record_last_hunk_decided,
  })
  local park_anchor = review_decisions.park_anchor
  local anchor_range = review_decisions.anchor_range
  local drop_anchor = review_decisions.drop_anchor
  local clear_extmarks = review_decisions.clear_extmarks
  local reject_block_at = review_decisions.reject_block_at
  local accept_block_at = review_decisions.accept_block_at
  local reject_hunk = review_decisions.reject_hunk
  local accept_hunk = review_decisions.accept_hunk
  local accept_all = review_decisions.accept_all

  ----------------------------------------------------------------------
  -- DECISION UNWIND -- `u` and `U` while the review is open.
  --
  -- THE RULE THIS OBEYS. There are two owners here and there always were: Neovim owns
  -- the buffer's TEXT history, and this module already owns the DECISION history
  -- (state.hunk_ledger, record_decision, the ledger rows). Each undoes only its own
  -- state.
  --
  -- WHY A DECISION STACK AT ALL, when the ruling says "u hunk by hunk". Because ACCEPT
  -- MOVES NO BYTES. The review buffer holds the agent's content from the moment it
  -- opens, so accepting a hunk is bookkeeping: there is no undo block for it and no
  -- boundary placement can create one.
  --
  -- WHY THIS CANNOT REACH THE APPLIER, structurally rather than by discipline. No
  -- decision is durable while the review is open: the Turn settles only at its end
  -- path, and the review closes there, releasing these maps with it. So the window in
  -- which `u` and `U` are bound is exactly the window in which un-deciding touches
  -- nothing but extmarks and a Lua table.
  ----------------------------------------------------------------------

  --- One WARN line naming what is wrong, and the hunk keys still work. Never
  --- silent, and never a write.
  local review_undo = M._review_undo_factory.new({
    facade = M,
    state = state,
    change = change,
    bufnr = bufnr,
    notify_one_line = notify_one_line,
    diff = diff,
    buf_undo_seq = buf_undo_seq,
    log = log,
    live_block_range = live_block_range,
    clear_extmarks = clear_extmarks,
    park_anchor = park_anchor,
    record_decision = record_decision,
    anchor_range = anchor_range,
    lines_equal = lines_equal,
    reject_restoration = reject_restoration,
    drop_anchor = drop_anchor,
    land_on = land_on,
    -- These three are the queue's OWN primitives, injected like every other dep;
    -- nothing here reaches through `_test`.
    pool_for = pool_for,
    queue_insert_original = queue_insert_original,
    queue_remove_change = queue_remove_change,
  })
  local undo_refuse = review_undo.undo_refuse
  local rerender_after_history_move = review_undo.rerender_after_history_move
  local native_undo = review_undo.native_undo
  local redo_local = review_undo.redo_local
  local pop_decision = review_undo.pop_decision

  -- A history move also changes whether a pending
  -- hunk is reachable -- `u` after `cA`, and `cU` after it, put every hunk
  -- back on a Turn that never ended. A decision reports itself through
  -- `_poll_leave_edge`; a history move reported through nothing, so the panel
  -- stayed deleted while the hunks came back.
  --
  -- Wrapped HERE, where the doors are BUILT, so there is one door per action
  -- and every route shares it: the buffer-local keymaps (`u`, `U`, `<C-r>`),
  -- `state._ops` below, and `review_api.reset_active_review`, which reaches
  -- `U`'s body through `_ops.undo_turn`. Wrapping at a call site instead left
  -- that last one raw. Each door returns at most one value.
  local function report_history_move(door)
    if type(door) ~= "function" then
      return door
    end
    return function(...)
      local moved = door(...)
      -- A cross-file undo opened another review without focusing it; focus it
      -- now that neovim's undo has run there. No block: focus only, no cursor.
      local active = pool_for(opts or {}).active
      if active and active ~= state and active._focus_after_history_move then
        active._focus_after_history_move = nil
        land_on(active.change.path, active.bufnr, nil)
      end
      require("yana.turn.turn_bind").refresh_review_liveness(pool_for(opts or {}))
      return moved
    end
  end
  local redo_key = report_history_move(review_undo.redo_key)
  local undo_key = report_history_move(review_undo.undo_key)
  local undo_turn = report_history_move(review_undo.undo_turn)

  if not opts.preview then
    -- BufWriteCmd on the review buffer. `:w!` is IDENTICAL to `:w` -- withholding is
    -- not a refusal, so `!` has nothing to force. Product saves use `noautocmd write!`
    -- (diff.save_buffer) and bypass this handler entirely; keep it that way.
    --
    -- The representation relied on is `state.hunk_ledger:pending()`. Either way this
    -- loop iterates exactly the undecided hunks.
    --
    -- THE WRITE MECHANISM, and why it is neither of the two obvious ones.
    -- `diff.save_buffer` writes the buffer VERBATIM (diff.lua:494-499) and so cannot
    -- write a composition at all.
    --
    -- What is NOT recovered by construction: Neovim's recorded file info for this
    -- buffer, because the bytes did not travel through `buf_write`. Neovim exposes no
    -- way to re-stamp it that does not RELOAD the buffer, and a reload would replace
    -- the review composition. * a `:checktime` in between lands on the
    -- FileChangedShellPost handler's tier-1 branch, which is exactly why `disk_at_open`
    -- advances to the bytes written and `state.staged_text` stays the BUFFER snapshot
    review_open_save_factory.new(deps)
  end

  local review_bulk = M._review_bulk_factory.new({
    facade = M,
    state = state,
    change = change,
    bufnr = bufnr,
    opts = opts,
    record_decision = record_decision,
    reject_block_at = reject_block_at,
    finish_session = finish_session,
    pool_for = pool_for,
    diff = diff,
    control_plane = control_plane,
    review_action_allowed = review_action_allowed,
    ledger = ledger,
    change_ledger = change_ledger,
    notify_owner = notify_owner,
    attribute_drift = attribute_drift,
    notify_one_line = notify_one_line,
    log = log,
    ns = NS,
    authority_ns = AUTH_NS,
    hint_ns = HINT_NS,
    process_next_for = process_next_for,
    record_last_hunk_decided = record_last_hunk_decided,
    model_target = model_target,
    absorb_review_blocks_over_drift = absorb_review_blocks_over_drift,
    base_fingerprint = base_fingerprint,
  })
  local reject_all = review_bulk.reject_all
  local accept_everything = review_bulk.accept_everything

  ledger.mark(change_ledger(change, opts), "review_profile_actions_ready")

  state._ops = {
    accept_block_at = accept_block_at,
    reject_block_at = reject_block_at,
    -- The button strip dispatches by these names (`ui_review_buttons.lua`,
    -- `names` map). Without them a click on "accept hunk" / "reject hunk" was
    -- swallowed with no error: the press was logged, no decision followed.
    -- These are the SAME cursor-resolving functions `ca`/`cr` are bound to, so
    -- mouse and keyboard cannot drift apart.
    accept_hunk = accept_hunk,
    reject_hunk = reject_hunk,
    accept_all = accept_all,
    reject_all = reject_all,
    accept_everything = accept_everything,
    redo_local = redo_local,
    pop_decision = pop_decision,
    native_undo = native_undo,
    undo_turn = undo_turn,
    rerender = function()
      -- This site asks for the ONE coalesced repaint instead of calling the painter
      -- itself.
      state.hunk_ledger:request_paint()
    end,
  }
    return {
      reject_block_at = reject_block_at,
      accept_block_at = accept_block_at,
      reject_hunk = reject_hunk,
      accept_hunk = accept_hunk,
      accept_all = accept_all,
      redo_local = redo_local,
      redo_key = redo_key,
      undo_key = undo_key,
      undo_turn = undo_turn,
      reject_all = reject_all,
      accept_everything = accept_everything,
    }
  end
  setfenv(setup, env)
  return setup()
  end

return Factory
