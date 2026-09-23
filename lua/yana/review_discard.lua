-- Abandoning review state, and WHEN a caller is allowed to. Split out of
-- `review_api.lua`, which had reached 490 lines: this is one question with one
-- answer, and it is the question every discard caller got wrong.
--
-- THE RULE. `Turn:end_turn` answers STARTED, not finished. A truthy answer was
-- never permission to clear a queue; only a delivered `completed` result is.
-- Zero visible hunks is not a close receipt either -- a Turn with no hunks
-- still owes End and cleanup -- so a `hunks > 0` guard skips the request and
-- drops exactly the work it looks like it protects (F-END-DISCARD).
--
-- THE CONTINUATION. The result can arrive later. One request therefore carries
-- its own cleanup into the callback and runs it exactly once, whenever the
-- answer comes; the caller is never asked to discard a second time.
local M = {}

--- `new(deps)` returns the two discard doors bound to one review facade.
--- deps: facade, pool_for, review_tabs, owners_match, queue_item_owner,
--- process_next_for, announce_state.
function M.new(deps)
  local facade = deps.facade
  local pool_for = deps.pool_for
  local review_tabs = deps.review_tabs
  local owners_match = deps.owners_match
  local queue_item_owner = deps.queue_item_owner
  local process_next_for = deps.process_next_for
  local announce_state = deps.announce_state

  --- Run the cleanup now, asking nobody. The caller hears the same terminal
  --- `completed` a finished Turn would have delivered.
  local function without_end(source, owner, notify, continue)
    continue()
    if notify then notify({ status = "completed", source = source, owner = owner }) end
    return true
  end

  --- THE END IS THE ACTIVE REVIEW'S. `turn_bind.get(pool)` answers with the
  --- pool's ONE Turn whoever owns it, so asking it on a named discard ended a
  --- DIFFERENT owner's live work whenever the named owner held only queue
  --- items. End is owed only by the owner of the active review.
  local function owns_active(st, owner)
    if st.active == nil then
      return false
    end
    return owners_match(st.active.opts and st.active.opts.review_owner, owner) and true or false
  end

  --- Request the Turn's End, then run `continue` once, on `completed` only --
  --- synchronously if the Turn answers at once, otherwise from the callback.
  --- `notify` is the caller's own observer and hears every terminal status,
  --- so a panel can tell "kept editing" from "completed".
  local function when_ended(st, source, owner, notify, continue)
    local turn = require("yana.turn.turn_bind").get(st)
    if turn == nil or turn.state ~= "live" then
      return without_end(source, owner, notify, continue)
    end
    local ran, answer = false, nil
    turn:end_turn("abort", {
      source = source,
      owner = owner,
      on_result = function(result)
        answer = result
        if ran then return end
        if type(result) == "table" and result.status == "completed" then
          ran = true
          continue()
        end
        if notify then notify(result) end
      end,
    })
    if ran then return true end
    return false, (type(answer) == "table" and answer.status) or "end_pending"
  end

  -- Forward-declared: the named-owner door delegates to the pool door below,
  -- and a field on the module table would be shared between instances.
  local discard_pool

  --- Drop one owner's active review and queue items, keeping every other
  --- owner's. `on_end` hears the End result whenever it arrives.
  local function discard_for_owner(owner, opts, on_end)
    if not owner then
      return discard_pool(opts, on_end)
    end
    opts = opts or {}
    local st = pool_for(opts)
    local mine = owns_active(st, owner)
    local continue = function()
      -- Re-asked, not remembered: an async End answers later, and the active
      -- review may have been replaced by then.
      local cleared_active = owns_active(st, owner)
      if cleared_active then
        pcall(facade.cleanup, st.active)
        st.active = nil
      end
      local kept = {}
      for _, item in ipairs(st.queue) do
        if not owners_match(queue_item_owner(item), owner) then
          kept[#kept + 1] = item
        end
      end
      st.queue = kept
      facade._rewind_forget_owner(owner)
      announce_state()
      if cleared_active then
        process_next_for(opts)
      end
    end
    -- Only this owner's End may be asked for; anyone else's Turn stays live.
    if not mine then
      return without_end("owner_discard", owner, on_end, continue)
    end
    return when_ended(st, "owner_discard", owner, on_end, continue)
  end

  --- Abandon every review in a workspace pool without resolving hunks. Used
  --- when the owning conversation is discarded (new_chat) so active or queued
  --- work cannot outlive the claim release.
  function discard_pool(opts, on_end)
    opts = opts or {}
    local st = pool_for(opts)
    return when_ended(st, "pool_discard", nil, on_end, function()
      local tabs_path = review_tabs.state_path(opts)
      if tabs_path then
        pcall(vim.fn.delete, tabs_path)
      end
      if st.active then
        pcall(facade.cleanup, st.active)
        st.active = nil
      end
      st.queue = {}
      st.batched = {}
      st.order = {}
      st.order_seq = 0
      st.review_tabs = nil
      facade._rewind_forget_owner(nil)
      announce_state()
    end)
  end

  return { discard_for_owner = discard_for_owner, discard_pool = discard_pool }
end

return M
