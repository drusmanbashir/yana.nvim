-- Claim fan-out orchestration for bulk accept.
local M = {}

function M.new(ctx)
  local M = ctx.facade
  local state = ctx.state
  local pool_for = ctx.pool_for
  local accept_everything_claimed = ctx.accept_everything_claimed

  return function()
      if state._yanad_bulk_pending ~= nil then
        return true
      end
	  local st = pool_for(state.opts or {})
	  if st.active ~= state then
		return false
	  end
	  local turn = require("yana.turn_bind").get(st)
	  if turn and turn:pending_count() == 0 then
		if turn.close_error then
		  M._poll_leave_edge(state, "accept_turn_retry")
		end
		return true
	  end
	  local drained = st.queue
      local queue_snapshot = {}
      local queue_owners = {}
      for i, item in ipairs(drained) do
        queue_snapshot[i] = item
        queue_owners[i] = {
          change = item.change,
          opts = item.opts,
          review_turn = item.opts and item.opts.review_turn,
          turn_id = item.change and (item.change.turn_id or item.change.turn_gen),
          generation = item.change and item.change.turn_gen,
        }
      end
      local token = {}
      local turn_id = state.change and (state.change.turn_id or state.change.turn_gen)
      local generation = state.change and state.change.turn_gen
      local review_owner = state.opts and state.opts.review_owner or {}
      local panel_id = review_owner.panel_id
      local epoch = review_owner.epoch
      local turn_pass = state.opts and state.opts.turn_pass
      local review_turn = state.opts and state.opts.review_turn
      local bundle_digest = turn_pass and turn_pass.bundle and turn_pass.bundle.bundle_digest or nil
      local grants, refusals = {}, {}
      state._yanad_bulk_pending = token

      local bulk_session = state.opts and state.opts.yanad_session_id
      local bulk_session_alt = state.opts and state.opts.session_id

      local function current()
        if state._yanad_bulk_pending ~= token or st.active ~= state or st.queue ~= drained then
          return false
        end
        -- The SESSION that opened this press must still be the session settling
        -- it; the claims were won for that session and nothing else revalidates it.
        if (state.opts and state.opts.yanad_session_id) ~= bulk_session
          or (state.opts and state.opts.session_id) ~= bulk_session_alt
        then
          return false
        end
        if #drained ~= #queue_snapshot then
          return false
        end
        for i, item in ipairs(queue_snapshot) do
          if drained[i] ~= item then
            return false
          end
          local owner = queue_owners[i]
          if item.change ~= owner.change
            or item.opts ~= owner.opts
            or (item.opts and item.opts.review_turn) ~= owner.review_turn
            or (item.change and (item.change.turn_id or item.change.turn_gen)) ~= owner.turn_id
            or (item.change and item.change.turn_gen) ~= owner.generation
          then
            return false
          end
        end
        local now_owner = state.opts and state.opts.review_owner or {}
        local now_pass = state.opts and state.opts.turn_pass
        return state.change ~= nil
          and (state.change.turn_id or state.change.turn_gen) == turn_id
          and state.change.turn_gen == generation
          and now_owner.panel_id == panel_id
          and now_owner.epoch == epoch
          and now_pass == turn_pass
          and (state.opts and state.opts.review_turn) == review_turn
          and (now_pass and now_pass.bundle and now_pass.bundle.bundle_digest or nil) == bundle_digest
      end

      local apply_sessions = require("yana.shadow.apply_sessions")
      local function context_for(item)
        local item_opts = item and item.opts or state.opts or {}
        return {
          review_turn = item_opts.review_turn,
          turn_id = item and item.change and (item.change.turn_id or item.change.turn_gen) or turn_id,
          yanad_session_id = item_opts.yanad_session_id,
          session_id = item_opts.session_id,
          workspace = item_opts.workspace,
        }
      end

      -- They are now all in flight at once and the drain runs at the JOIN, when the
      -- last of them has reported.
      --
      -- Only the hunk BUILD stays synchronous and in-process, which is the other
      -- half of the same ruling: a queued file's hunks are materialized inside
      -- `accept_everything_claimed`, not fetched.
      local outstanding = #queue_snapshot + 1
      local aborted = false

      local function join()
        if aborted or not current() then
          return
        end
        state._yanad_bulk_pending = nil
        for _, grant in ipairs(grants) do
          -- The grant is frozen against the SAME context the request was made
          -- with, so the door that consumes it can recompute root, rel,
          -- absolute path, session and turn and compare them exactly.
          -- `grant.identity` is the record frozen BEFORE that file's request was
          -- dispatched. Recomputing a context here would re-read a change that
          -- may have been retargeted while the claims were in flight.
          -- A REFUSED GRANT IS A REFUSAL. Its return value decides whether this
          -- file keeps any authority at all; ignoring it left a file whose owner
          -- or claimed path no longer checked out inside the accept loop.
          if apply_sessions.grant_file_claim(
            grant.change,
            token,
            grant.path,
            grant.identity or grant.context,
            context_for(grant.item)
          ) == false then
            apply_sessions.clear_file_claim_grant(grant.change)
            apply_sessions.record_file_claim_refusal(grant.change, "claim_owner_changed", nil)
            if grant.item ~= nil then
              grant.item._yanad_claim_error = "the yanad file.claim no longer names this attempt"
            end
          end
        end
        for _, refusal in ipairs(refusals) do
          -- A refused file keeps no authority from this press.
          apply_sessions.clear_file_claim_grant(refusal.change)
          apply_sessions.record_file_claim_refusal(refusal.change, refusal.code, refusal.detail)
          refusal.item._yanad_claim_error = refusal.message
        end
        accept_everything_claimed(drained, token)
      end

      -- The join fires on the LAST report, whether the claims answered
      -- asynchronously or (as the fakes and the in-process path do) synchronously
      -- inside `request_file_claim`. `outstanding` is seeded with the full count
      -- BEFORE any request is made, so a synchronous chain cannot reach zero
      -- early and drain a turn whose later claims were never asked for.
      local function settle_one()
        outstanding = outstanding - 1
        if outstanding == 0 then
          join()
        end
      end

      -- The ACTIVE file's claim is still asked FIRST and still aborts the whole press
      -- on its own: it is the one file `cA` cannot proceed without, and a refusal there
      -- is reported through `_record_shadow_accept_refusal` on the live review.
      local function request_one(item)
        local target = item and item.change or state.change
        local function report(ok, value, code, detail, unavailable, frozen)
          if not current() then
            return
          end
          if ok then
            grants[#grants + 1] = { change = target, path = value, context = context_for(item), identity = frozen, item = item }
          elseif item == nil then
            aborted = true
            state._yanad_bulk_pending = nil
            apply_sessions.record_file_claim_refusal(target, code, detail)
            M._record_shadow_accept_refusal(state, value)
            return
          else
            refusals[#refusals + 1] = {
              item = item,
              change = target,
              message = value,
              code = unavailable and "claim_unavailable" or code,
              detail = detail,
            }
          end
          settle_one()
        end
        local started, start_err = apply_sessions.request_file_claim(context_for(item), target, function(ok, value, code, detail, frozen)
          report(ok, value, code, detail, false, frozen)
        end)
        if not started then
          report(false, start_err, "claim_unavailable", nil, true)
        end
      end

      request_one(nil)
      for _, item in ipairs(queue_snapshot) do
        if aborted or not current() then
          break
        end
        request_one(item)
      end
      return true
    end
end

return M
