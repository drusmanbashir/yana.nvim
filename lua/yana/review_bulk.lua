-- File-wide and turn-wide review decisions.
local queued_hunks = require("yana.review_queued_hunks")
local parked = require("yana.review_bulk_parked")
local disclosure = require("yana.review_bulk_disclosure")

local Factory = {}

function Factory.new(deps)
  local M = deps.facade
  local state = deps.state
  local change = deps.change
  local bufnr = deps.bufnr
  local opts = deps.opts
  local record_decision = deps.record_decision
  local reject_block_at = deps.reject_block_at
  local pool_for = deps.pool_for
  local diff = deps.diff
  local control_plane = deps.control_plane
  local review_action_allowed = deps.review_action_allowed
  local notify_one_line = deps.notify_one_line
  local log = deps.log
  local NS = deps.ns
  local AUTH_NS = deps.authority_ns
  local HINT_NS = deps.hint_ns
  local process_next_for = deps.process_next_for
  local record_last_hunk_decided = deps.record_last_hunk_decided
  local absorb_review_blocks_over_drift = deps.absorb_review_blocks_over_drift
  local model_target = deps.model_target

  local function operation_transition(file, verdict)
    if type(file) ~= "table" or file.operation == nil then
      return nil
    end
    local members = file.ledger and type(file.ledger.members) == "function" and file.ledger:members() or {}
    if #members > 0 or file.operation_verdict == verdict then
      return nil
    end
    return {
      file = file,
      file_path = file.path,
      change = file.change,
      change_id = file.change_id,
      previous = file.operation_verdict or "pending",
      next = verdict,
    }
  end

  local function operation_ready(transition)
    if transition == nil then
      return true
    end
    local file = transition.file
    return type(file) == "table"
      and rawequal(file.change, transition.change)
      and file.path == transition.file_path
      and file.change_id == transition.change_id
      and file.operation_verdict == transition.previous
  end

    local function reject_all()
      record_decision(state, "reject_file", { hunks_remaining = state.hunk_ledger:count() })
      -- A hunk already decided is a RECORDED decision and stands. This record has only
      -- ever claimed the REMAINING hunks (hunks_remaining), so the old whole-file
      -- restore contradicted the ledger row it had just written: an accepted hunk's
      -- accept_hunk record survived while its bytes vanished. With prior decisions,
      -- reject the remaining hunks through the same path `co` takes, letting
      -- try_finalize compose base + exactly the accepted hunks; a hunk that refuses
      if #state.decisions > 0 then
        -- Skip-and-continue on a refused hunk (human edit inseparable from the
        -- agent's), exactly like the whole-file path: the refused hunk stays
        -- pending and the review stays open for it, while every other remaining
        -- hunk is still swept. Terminates because each pass either shrinks the
        -- block list or advances past a refusal.
        --
        -- `reject_block_at` is told to suppress its own per-hunk push; this door pushes
        -- exactly one row after the loop, counting how many hunks it actually rejected
        -- -- not the ledger's starting count, which would over-count a hunk this pass
        -- skipped over on a refusal.
        local i = 1
        local all_rejected = true
        local rejected_count = 0
        while i <= state.hunk_ledger:count() do
          local before = state.hunk_ledger:count()
          reject_block_at(i, true)
          if state.hunk_ledger:count() >= before then
            all_rejected = false
            i = i + 1
          else
            rejected_count = rejected_count + (before - state.hunk_ledger:count())
          end
        end
        if rejected_count > 0 then
          pcall(function()
            require("yana.turn.turn_register"):push({
              kind = "decision",
              rel = change.rel or change.path,
              workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd(),
              turn_id = change.turn_id or change.turn_gen,
              count = rejected_count,
            })
          end)
        end
        return all_rejected
      end
      local pending = state.hunk_ledger:pending()
      if #pending == 0 then
        local pool = pool_for(state.opts or {})
        local turn = require("yana.turn.turn_bind").get(pool)
        local file = turn and turn:file(diff.abs_path(change.path)) or nil
        if file and file.operation ~= nil then
          local ok, err = require("yana.review_decisions").record_operation_decision(file, "rejected", state)
          if not ok then
            notify_one_line("yana: could not record operation rejection: " .. tostring(err), vim.log.levels.WARN)
            return false
          end
          M._poll_leave_edge(state, "reject_all")
          return true
        end
      end
      record_last_hunk_decided("reject", pending[#pending])
      local ok = M._settle_bulk_reject(state, "reject_all") -- A1/call 2: the same edge + finalize as every other door
      local pool = pool_for(state)
      if state._redo_hold_active and pool.active == nil then
        pool.active = state
      end
      return ok
    end

    -- cA: accept every pending change for the whole turn — the active review
    -- plus everything still queued behind it. Drain the selection queue first
    -- so the ordinary Turn decision edge cannot open a review cA just settled.
    -- The active file remains owned by the Turn's normal settle path.
    --
    -- So an operator who fixed a typo three hundred lines away from any hunk had that
    -- file skipped, and no queued file's hunks were ever decided at all.
    --
    -- Now each queued file's hunks are MATERIALIZED here, synchronously, by the same
    -- diff a review open runs (lua/yana/review_queued_hunks.lua).
    local function select_everything(drained)
      local st = pool_for(state.opts or {})
      -- `active_blocks` is exactly the active file's pending set at THIS moment, taken
      -- before anything below moves it; `bulk_files` collects the same per queued file
      -- the loop below actually accepts.
      local active_blocks = state.hunk_ledger and state.hunk_ledger:pending() or {}
      local bulk_files = {}
      record_decision(state, "accept_turn", {
        hunks_remaining = state.hunk_ledger:count(),
        queued_files = #drained,
      })
      st.queue = {}
      local skipped = {}
      local clashed = {}
      local to_requeue = {}

      -- The active review's own ledger is already a member of the real Turn (it joined
      -- when this file's review opened, `turn_bind.observe_open`); every queued file's
      -- materialized ledger joins/refreshes as the loop below reaches it
      -- (`turn:add_file`, by-path).
      local turn = require("yana.turn.turn_bind").get(st)

      -- The materialize/absorb inputs, gathered once: this is the whole of what
      -- `review_queued_hunks` needs, and it is deliberately not the review's
      -- `deps` table -- a queued file has no review to lend it one.
      local queued_deps = {
        facade = M,
        diff = diff,
        model_target = model_target,
        absorb_review_blocks_over_drift = absorb_review_blocks_over_drift,
      }

      local parked_composition, parked_ledger = parked.new({ diff = diff })

      disclosure.emit(state, drained, log, notify_one_line)

      for _, item in ipairs(drained) do
        local change_i = item.change
        local path = diff.abs_path(change_i.path)
        change_i.path = path
        -- What a PARKED change contributes: its own staged bytes, and the
        -- reason it cannot be used if the human moved them after the park.
        local parked_text, parked_err, parked_bufnr = parked_composition(change_i)
        -- Control-plane fail-safe before any accept write, covering
        -- BOTH the shadow_apply route and the legacy direct write/delete below.
        -- Classify the lexical path so a `.git` name is not resolved away.
        if control_plane.is_control_plane(diff.abs_path_literal(change_i.path)) then
          change_i.review_error = "refused — control-plane path (never written): " .. change_i.path
          table.insert(skipped, change_i.rel or path)
          table.insert(to_requeue, item)
          goto continue
        end
        if parked_err then
          change_i.review_error = parked_err
          table.insert(clashed, change_i.rel or path)
          table.insert(to_requeue, item)
          goto continue
        end
        -- Built here, synchronously, before anything is written: a parked change
        -- contributes the hunks its own review still had pending, and every other
        -- queued change is diffed exactly as a review open diffs it. The ledger joins
        -- the turn immediately, pending, so the turn's count is honest even if the
        -- write below refuses.
        --
        -- THE DELETED GUARD, named so it cannot come back: `buffer_clash` stood here
        -- and refused any queued file whose buffer was `modified`. It was a per-FILE
        -- answer to a per-HUNK question. A file whose edit misses every hunk is
        -- therefore ACCEPTED WITH THAT EDIT rather than skipped.
        local file_ledger, conflicted, materialize_err
        if parked_text ~= nil then
          file_ledger, conflicted = parked_ledger(change_i), {}
        else
          local _composed
          file_ledger, _composed, conflicted, materialize_err = queued_hunks.materialize(queued_deps, change_i)
        end
        if not file_ledger then
          change_i.review_error = change_i.review_error or materialize_err or "queued change has no hunks to decide"
          table.insert(skipped, change_i.rel or path)
          table.insert(to_requeue, item)
          goto continue
        end
        local turn_file
        if turn then
          -- By-path refresh (Turn:add_file), same primitive
          -- `turn_bind.observe_open` uses when a review actually opens: this
          -- REPLACES whatever ledger intake seeded for `path` with the one
          -- about to be written from, so the decisions `decide_all` records
          -- on it below are visible to `Turn:pending_count` immediately --
          -- same object, no second copy.
          turn_file = turn:add_file({
            path = path,
            ledger = file_ledger,
            change = change_i,
            -- The press no longer spends these inputs. Turn exit needs them to
            -- compose and journal this selected file's projection.
            base_text = change_i.before or "",
            bufnr = parked_bufnr,
            review_opts = item.opts,
            review_owner = item.opts and item.opts.review_owner,
          })
        end
        if #conflicted > 0 then
          -- REFUSED BY NAME, and the file is left for a review of its own: the
          -- turn's pending count still holds these hunks, so no close edge is
          -- crossed and `process_next_for` below opens the file the operator has
          -- to arbitrate. Nothing of it is written -- a half-written file with a
          -- reviewable remainder is a worse thing to hand back than an untouched
          -- one.
          change_i.review_error = queued_hunks.conflict_reason(change_i, conflicted)
          table.insert(clashed, change_i.rel or path)
          table.insert(to_requeue, item)
          goto continue
        end

        local allowed, why = review_action_allowed({ opts = item.opts }, change_i)
        if not allowed then
          change_i.review_error = tostring(why)
          table.insert(skipped, change_i.rel or path)
          table.insert(to_requeue, item)
          goto continue
        end

        -- Capture only the verdicts this press will change. Projection, claims,
        -- bytes and modes remain untouched until :w or Turn exit.
        bulk_files[#bulk_files + 1] = {
          rel = change_i.rel or path,
          ledger = file_ledger,
          blocks = file_ledger:pending(),
          change = change_i,
          file = turn_file,
          operation = operation_transition(turn_file, "accepted"),
          opts = item.opts,
          item = item,
          band_bufnr = parked_bufnr or vim.fn.bufnr(path, false),
        }
        ::continue::
      end

      if #clashed > 0 then
        local reasons = {}
        for _, item in ipairs(to_requeue) do
          local why = item.change and item.change.review_error
          if why and vim.tbl_contains(clashed, item.change.rel or item.change.path) then
            reasons[#reasons + 1] = (item.change.rel or item.change.path) .. ": " .. tostring(why)
          end
        end
        notify_one_line(
          "yana: refused " .. #clashed .. " change(s) — " .. table.concat(reasons, "; "),
          vim.log.levels.WARN
        )
      end
      if #skipped > 0 then
        notify_one_line(
          "yana: skipped " .. #skipped .. " stale queued change(s), left on disk unchanged: "
            .. table.concat(skipped, ", "),
          vim.log.levels.WARN
        )
      end
      local active_entry = nil
      local active_file = turn and turn:file(diff.abs_path(change.path)) or nil
      local active_operation = operation_transition(active_file, "accepted")
      if state.hunk_ledger and state.hunk_ledger:is_open()
        and (#active_blocks > 0 or active_operation ~= nil)
      then
        active_entry = {
          rel = change.rel or change.path,
          ledger = state.hunk_ledger,
          blocks = active_blocks,
          change = change,
          file = active_file,
          operation = active_operation,
        }
      end

      if active_entry and not operation_ready(active_entry.operation) then
        st.queue = drained
        notify_one_line("yana: cA refused — the active operation verdict moved", vim.log.levels.WARN)
        return false
      end
      for _, entry in ipairs(bulk_files) do
        if not operation_ready(entry.operation) then
          st.queue = drained
          notify_one_line("yana: cA refused — an operation verdict moved for " .. tostring(entry.rel), vim.log.levels.WARN)
          return false
        end
      end

      local ca_modes = {}
      -- `U` stays the unrelated, unchanged undo-ALL.
      if active_entry or #bulk_files > 0 then
        local pushed, push_err = pcall(function()
          require("yana.turn.turn_register"):push({
            kind = "accept_turn_step",
            rel = change.rel or change.path,
            workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd(),
            turn_id = change.turn_id or change.turn_gen,
            active = active_entry,
            files = bulk_files,
            modes = ca_modes,
          })
        end)
        if not pushed then
          st.queue = drained
          notify_one_line("yana: cA refused — decision history failed: " .. tostring(push_err), vim.log.levels.WARN)
          return false
        end
      end

      -- B8: cA answers every unseen permission proposal with an unasked Keep
      -- BEFORE anything below moves focus or opens another file. The records
      -- ride on this cA step (`modes`), so its `u` / `<C-r>` restore / re-apply them.
      local keep_seen = {}
      local function keep_unseen(file)
        if type(file) ~= "table" or keep_seen[file] then
          return
        end
        keep_seen[file] = true
        -- Unseen = no record for THIS proposal (I3 content key): a record left by
        -- a since-revised proposal does not answer the revised one.
        local settle = require("yana.turn.turn_settle")
        local key = settle.mode_proposal_key(file)
        if key == nil or settle.current_mode_verdict(file) ~= nil then
          return
        end
        local c = file.change
        local policy = require("yana.review_permissions").permission_policy(file, turn)
        -- I3: an unasked resolution records the POLICY's verdict -- allow applies
        -- the proposal at Save/End; ask and deny keep.
        local next_verdict = policy == "allow" and "allow" or "keep"
        local transition = {
          proposal_key = key, previous = "keep", next = next_verdict, policy = policy, asked = false,
        }
        local recorded, record_err = require("yana.review_decisions").record_mode_decision(file, {
          proposal_key = key, previous = "keep", next = next_verdict, policy = policy, asked = false,
        }, { history = false })
        if recorded == true then
          ca_modes[#ca_modes + 1] = {
            file = file, file_path = file.path, change = c, change_id = file.change_id, mode = transition,
          }
        else
          notify_one_line("yana: cA could not record Keep for " .. tostring(file.path) .. ": " .. tostring(record_err), vim.log.levels.WARN)
        end
      end
      keep_unseen(active_file)
      for _, entry in ipairs(bulk_files) do
        keep_unseen(entry.file)
      end
      for _, item in ipairs(to_requeue) do
        keep_unseen(turn and item.change and item.change.path and turn:file(diff.abs_path(item.change.path)) or nil)
      end

      if active_entry and active_entry.operation then
        active_entry.file:decide_operation(active_entry.operation.next)
      end
      if state.hunk_ledger and state.hunk_ledger:is_open() then
        state.hunk_ledger:decide_all("accept")
      end
      for _, entry in ipairs(bulk_files) do
        if entry.operation then
          entry.file:decide_operation(entry.operation.next)
        end
        entry.ledger:decide_all("accept")
        local band_bufnr = entry.band_bufnr
        if band_bufnr and band_bufnr > 0 and vim.api.nvim_buf_is_valid(band_bufnr) then
          -- Paint and hints go; the AUTHORITY marks stay. cA moves no bytes, and a
          -- parked review is never repainted by its undo (only the current one
          -- flushes), so clearing them here left `u`-restored hunks with no
          -- authority range and a later reject failed "hunk extmark invalidated".
          vim.api.nvim_buf_clear_namespace(band_bufnr, NS, 0, -1)
          vim.api.nvim_buf_clear_namespace(band_bufnr, HINT_NS, 0, -1)
        end
      end
      record_last_hunk_decided("accept", nil)
      vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
      vim.api.nvim_buf_clear_namespace(bufnr, AUTH_NS, 0, -1)
      vim.api.nvim_buf_clear_namespace(bufnr, HINT_NS, 0, -1)
      -- Polled at this door's tail like every other (A1); `_poll_leave_edge`
      -- asks the real Turn, which is permanent for the session.
      for _, item in ipairs(to_requeue) do
        table.insert(st.queue, item)
      end
      local edge = M._poll_leave_edge(state, "accept_turn")
      if edge == "stay" then
        if #to_requeue > 0 then
          process_next_for(state.opts)
        end
        return
      end
      -- cA owns selection only. Completion is the ordinary decision edge
      -- above; it must never invent a second finish_session/teardown route.
      return
    end

    local function accept_everything()
      local st = pool_for(state.opts or {})
      if st.active ~= state then
        return false
      end
      local turn = require("yana.turn.turn_bind").get(st)
      if turn and turn:pending_count() == 0 then
        -- ZERO PENDING IS NOT "NOTHING TO DO". cA here means finish the turn,
        -- and the accepted projection is still owed. Keep cancels the End, not
        -- the cA decision that preceded it, and a cancelled ask leaves no
        -- error -- so testing for `close_error or settle_error` made the second
        -- cA a silent no-op and the operator had no way back to End (F-END-02).
        -- Any LIVE turn is re-offered; a turn already gone has nothing owed.
        if turn.state == "live" then
          M._poll_leave_edge(state, "accept_turn_retry")
        end
        return true
      end
      return select_everything(st.queue)
    end

  return {
    reject_all = reject_all,
    accept_everything = accept_everything,
  }
end

return Factory
