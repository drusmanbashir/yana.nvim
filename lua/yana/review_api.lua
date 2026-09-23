-- Public queue, status, render, and close API for inline review.
local Factory = {}

function Factory.new(deps)
  local M = deps.facade
  local pool_for = deps.pool_for
  local process_next = deps.process_next
  local stamp_review_workspace = deps.stamp_review_workspace
  local freeze_review_owner = deps.freeze_review_owner
  local remember_batch_item = deps.remember_batch_item
  local process_next_for = deps.process_next_for
  local owners_match = deps.owners_match
  local queue_item_owner = deps.queue_item_owner
  local review_tabs = deps.review_tabs
  local announce_state = deps.announce_state
  local pools = deps.pools
  local open_or_abandon = deps.open_or_abandon
  local notify = deps.notify
  local find_active_for_change = deps.find_active_for_change
  local diff = deps.diff
  local NS = deps.ns
  -- The authority namespace is the painter's.
  local HINT_NS = deps.hint_ns
  local finish_session = deps.finish_session
  local land_on = deps.land_on
  local focus_buf = deps.focus_buf
  local apply_palette_highlights = deps.apply_palette_highlights
  local apply_review_winhl = deps.apply_review_winhl
  local render_invariant = deps.render_invariant
  local render_check = deps.render_check
  local EXT_HL = deps.ext_hl
  local PALETTE = deps.palette

  -- An agent-proposed NEW file is created on disk EMPTY the moment the turn proposes it
  -- -- not a decision, no prompt. What happens on the far side is the touch owner's
  -- (creation_touch.on_proposal); all this owes it is a normalised path, a rel and a
  -- stamped workspace.
  local function touch_proposed_creation(change, opts)
    local creation_touch = require("yana.paths.creation_touch")
    local path = creation_touch.is_creation(change) and diff.abs_path(change.path) or nil
    if path == nil or path == "" then return end
    change.path = path
    change.rel = change.rel or diff.relpath(path)
    stamp_review_workspace(change, opts)
    creation_touch.on_proposal(change)
  end
  M._touch_proposed_creation = touch_proposed_creation

  function M.enqueue(change, opts)
    opts = opts or {}
    require("yana.log").buffer_event("enqueue", { change = change, preview = opts.preview })
    touch_proposed_creation(change, opts)
    local st = pool_for(opts)
    if st.active and st.active.change == change then
      return false
    end
    for _, item in ipairs(st.queue) do
      if item.change == change then
        process_next(opts)
        return "already_queued"
      end
    end
    change.review_error = nil
    stamp_review_workspace(change, opts)
    local item = {
      change = change,
      opts = opts,
      owner = freeze_review_owner(opts),
    }
    remember_batch_item(st, item)
    table.insert(st.queue, item)
    local attempted = process_next_for(opts)
    if attempted == change then
      return "opened"
    end
    return "inserted"
  end

  -- Drop active and queued reviews owned by one panel/stream epoch inside a workspace
  -- pool. Other owners' work in the same pool survives (H4). No live Turn, or zero
  -- hunks -> silent today.
  -- The two discard doors live in `yana.review_discard`: one question -- may
  -- this caller drop its review state yet -- with one answer, and the only
  -- place that carries a pending End's completion into its own cleanup.
  local discard = require("yana.review_discard").new({
    facade = M,
    pool_for = pool_for,
    review_tabs = review_tabs,
    owners_match = owners_match,
    queue_item_owner = queue_item_owner,
    process_next_for = process_next_for,
    announce_state = announce_state,
  })
  M.discard_for_owner = discard.discard_for_owner
  M.discard_pool = discard.discard_pool

  -- M.open sets the `active` singleton with no guard, so reviewing change B while
  -- change A was open silently overwrote it: A's keymaps, BufWriteCmd guard and
  -- extmarks stayed live with nothing owning them, and A's eventual finish_session
  -- cleared `active` out from under B. Queueing instead makes that state unreachable —
  -- one review is open at a time by construction, which is the same invariant
  -- process_next already assumes. The queue is checked as well as `active`: between
  function M.review(change, opts)
    opts = opts or {}
    touch_proposed_creation(change, opts)
    local st = pool_for(opts)
    if st.active or #st.queue > 0 then
      M.enqueue(change, opts)
      return true
    end
    -- Same orphan contract as the queue path: a throw here must not leave the write
    -- guard and keymaps armed. Fail like the queue path does: stamped (in
    -- open_or_abandon), announced, reported in one line, and falsy to the caller.
    local ok, err = open_or_abandon(change, opts)
    if not ok then
      M._announce_open_failure(change, "inline review failed: " .. notify.error_headline(err), vim.log.levels.ERROR)
      return false
    end
    return true
  end

  -- Returns queued-plus-active review count for opts' pool, or all pools.
  function M.pending_count(opts)
    if opts then
      local st = pool_for(opts)
      return #st.queue + (st.active and 1 or 0)
    end
    local n = 0
    for _, st in pairs(pools) do
      n = n + #st.queue + (st.active and 1 or 0)
    end
    return n
  end

  -- Returns the active review's change for opts' pool, or any pool's.
  function M.active_change(opts)
    if opts then
      local st = pool_for(opts)
      return st.active and st.active.change or nil
    end
    for _, st in pairs(pools) do
      if st.active then
        return st.active.change
      end
    end
    return nil
  end

  -- How many reviews a queued change actually waits on: everything ahead of it
  -- in the queue, plus the open one. Callers used `pending_count() - 1`, which
  -- is position-blind -- it reports the same number for every queued change, so
  -- items queued BEHIND one inflated its own "behind N". Returns nil when the
  -- change is not queued (open, resolved, or unknown to the engine).
  function M.queue_wait(change, opts)
    local st
    if opts then
      st = pool_for(opts)
    else
      st = find_active_for_change(change)
      if not st then
        for _, candidate in pairs(pools) do
          for _, item in ipairs(candidate.queue) do
            if item.change == change then
              st = candidate
              break
            end
          end
          if st then break end
        end
      end
    end
    if not st then
      return nil
    end
    for i, item in ipairs(st.queue) do
      if item.change == change then
        return (i - 1) + (st.active and 1 or 0)
      end
    end
    return nil
  end

  -- Is `bufnr` under active or queued review? Consumed by the user's autosave
  -- config to suppress writes while a review is pending. Cheap and
  -- side-effect free: bufnr(path, false) never creates a buffer.
  function M.is_reviewing(bufnr)
    if not bufnr then
      return false
    end
    for _, st in pairs(pools) do
      if st.active and st.active.bufnr == bufnr then
        return true
      end
      for _, item in ipairs(st.queue) do
        if vim.fn.bufnr(diff.abs_path(item.change.path), false) == bufnr then
          return true
        end
      end
      for path in pairs(st.batched) do
        if vim.fn.bufnr(path, false) == bufnr then
          return true
        end
      end
    end
    return false
  end

  --- Panel-level accept/reject while inline review is open for this change.
  function M.resolve_change(change, action)
    local st = find_active_for_change(change)
    if not st or not st.active or not change or st.active.change.id ~= change.id then
      return false
    end
    local active = st.active
    if action == "accept" then
      -- So this door CALLS `cf`'s own function (`accept_all`, review_decisions.lua:342)
      -- instead of keeping a second copy of its body beside it.
      --
      -- The copy that stood here decided the verdicts with a bare `decide_all`
      -- and pushed NEITHER a `state.decisions` reversal entry NOR a turn-
      -- register row. Two faults followed from that one omission: a panel
      -- accept could not be undone at all, and the next `u` peeked a register
      -- whose newest row was whatever the operator pressed BEFORE, and walked
      -- THAT back ("u silently undoes the PREVIOUS action").
      --
      -- Same object, same edge, one door.
      local accept_all = active._ops and active._ops.accept_all
      if type(accept_all) ~= "function" then
        return false
      end
      accept_all()
      -- Return contract UNCHANGED.
      return false
    end
    if action == "reject" then
      -- The SAME lesson as `accept` above, at the other door. Calling
      -- `finish_session` here closed the review behind the Turn's back: no
      -- `state.decisions` reversal entry, no turn-register row, and the Turn's
      -- final-hunk leave edge never ran, so the Turn never learned its last
      -- decision had been made. The review's own `reject_all` is that edge.
      local reject_all = active._ops and active._ops.reject_all
      if type(reject_all) ~= "function" then
        return false
      end
      reject_all()
      -- Return contract UNCHANGED: a decision STARTED is not a session closed.
      return false
    end
    return false
  end

  -- Focuses the active review's buffer/window for opts' pool.
  function M.focus_active(opts)
    local st = pool_for(opts or {})
    if not st.active then
      return false
    end
    if not land_on(st.active.change.path, st.active.bufnr, nil) then
      focus_buf(st.active.change.path, st.active.bufnr)
    end
    return true
  end

  -- Returns the active review state for opts' pool, or any pool's.
  function M.active_state(opts)
    if opts then
      return pool_for(opts).active
    end
    for _, st in pairs(pools) do
      if st.active then
        return st.active
      end
    end
    return nil
  end

  -- Reset only when the current buffer owns an open review. This calls the
  -- same turn-wide unwind as the review's `U` map. `_ops.undo_turn` is the
  -- reporting door built in
  -- `review_open_actions.lua`, so a reset that puts every hunk back tells the
  -- Turn, which emits `review_alive` and the panel comes back. Do not swap
  -- this for a raw undo primitive; the panel would stay deleted with hunks
  -- pending.
  function M.reset_active_review()
    local current = vim.api.nvim_get_current_buf()
    for _, st in pairs(pools) do
      local active = st.active
      if active and active.bufnr == current and active._ops and type(active._ops.undo_turn) == "function" then
        active._ops.undo_turn()
        return true
      end
    end
    return false, "no_open_review_here"
  end

  -- Returns the on-disk path for opts' pool's review-tabs ownership record.

  -- Repaints palette highlights and diff blocks for state's buffer.
  function M.rerender(state)
    if not state or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    apply_palette_highlights()
    apply_review_winhl(state.bufnr, state)
    -- This site asks for the ONE coalesced repaint instead of calling the painter
    -- itself.
    state.hunk_ledger:request_paint()
  end

  --- Rung 1 on demand (`:YanaRenderCheck`). Same function the invariant
  --- capture runs, so what the operator sees is what production recorded.
  --- Returns a list of results, one per active review, newest pool order.
  function M.render_check(opts)
    local out = {}
    local states = {}
    if opts and (opts.workspace or opts.review_owner) then
      local st = pool_for(opts)
      if st.active then
        states[#states + 1] = st.active
      end
    else
      for _, st in pairs(pools) do
        if st.active then
          states[#states + 1] = st.active
        end
      end
    end
    for _, state in ipairs(states) do
      local result = render_invariant({
        site = "on_demand",
        bufnr = state.bufnr,
        blocks = state.hunk_ledger:pending(),
        model = state.model_hunks,
        model_source = state.model_source,
        change = state.change,
        opts = state.opts,
      })
      if result then
        out[#out + 1] = result
      end
    end
    return out
  end

  --- Read-only snapshot of every review pool and its decoration state, for
  --- `:YanaDump`. Pure reads: no repair, no rerender, no side effects.
  function M.introspect()
    local out = { pools = {}, ns = NS, hint_ns = HINT_NS }
    for key, st in pairs(pools) do
      local pool = {
        workspace = key,
        queued = #st.queue,
        batched = {},
        queue = {},
        active = nil,
      }
      for path in pairs(st.batched) do
        pool.batched[#pool.batched + 1] = path
      end
      for i, item in ipairs(st.queue) do
        pool.queue[i] = {
          change_id = item.change and item.change.id or nil,
          rel = item.change and (item.change.rel or item.change.path) or nil,
          status = item.change and item.change.status or nil,
          review_error = item.change and item.change.review_error or nil,
        }
      end
      if st.active then
        local state = st.active
        local blocks = {}
        for i, b in ipairs(state.hunk_ledger:pending()) do
          blocks[i] = {
            index = i,
            model_index = b.model_index,
            new_start_line = b.new_start_line,
            new_end_line = b.new_end_line,
            old_count = #(b.old_lines or {}),
            new_count = #(b.new_lines or {}),
            incoming_extmark_id = b.incoming_extmark_id,
            delete_extmark_id = b.delete_extmark_id,
            authority_extmark_id = b.authority_extmark_id,
          }
        end
        pool.active = {
          change_id = state.change and state.change.id or nil,
          rel = state.change and (state.change.rel or state.change.path) or nil,
          bufnr = state.bufnr,
          review_error = state.change and state.change.review_error or nil,
          model_source = state.model_source,
          blocks = blocks,
          decorations = render_check.collect({
            site = "dump",
            bufnr = state.bufnr,
            blocks = state.hunk_ledger:pending(),
            model = state.model_hunks,
            model_source = state.model_source,
            ns = NS,
            hint_ns = HINT_NS,
            ext_hl = EXT_HL,
            palette = PALETTE,
            change_id = state.change and state.change.id or nil,
            rel = state.change and (state.change.rel or state.change.path) or nil,
          }),
        }
      end
      out.pools[#out.pools + 1] = pool
    end
    return out
  end

  -- Rejects the active review in opts' pool THROUGH ITS OWN DECISION, so the
  -- Turn's leave edge owns the End. It does not tear the session down itself:
  -- `finish_session` here bypassed the Turn exactly as the panel Reject door
  -- did. The answer says a decision was made, not that the session is closed.
  function M.close_active(opts)
    local st = pool_for(opts or {})
    if not st.active then
      return false
    end
    local reject_all = st.active._ops and st.active._ops.reject_all
    if type(reject_all) ~= "function" then
      return false
    end
    reject_all()
    return true
  end

  ---
  --- A parked file's buffer genuinely holds proposal bytes and needs the same
  --- bookmarked `:undo {seq}` jump `M.abort_active` gives the active file — against ITS
  --- OWN bookmark, because a seq number from one buffer's undo tree means nothing on
  --- another's. An unopened file has no bookmark and skips the jump; there is nothing
  --- on its buffer to rewind. Either way the paint (all four yana namespaces) goes, and
  --- every buffer this abort touches keeps Neovim's own `u`/`<C-r>`.
  return M
end

return Factory
