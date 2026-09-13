-- File-wide and turn-wide review decisions.
local queued_hunks = require("yana.review_queued_hunks")
local hunk_ledger = require("yana.hunk_ledger")
local parked = require("yana.review_bulk_parked")
local disclosure = require("yana.review_bulk_disclosure")
local claims = require("yana.review_bulk_claims")

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
  local ledger = deps.ledger
  local change_ledger = deps.change_ledger
  local notify_owner = deps.notify_owner
  local attribute_drift = deps.attribute_drift
  local notify_one_line = deps.notify_one_line
  local log = deps.log
  local NS = deps.ns
  local AUTH_NS = deps.authority_ns
  local HINT_NS = deps.hint_ns
  local process_next_for = deps.process_next_for
  local record_last_hunk_decided = deps.record_last_hunk_decided
  local absorb_review_blocks_over_drift = deps.absorb_review_blocks_over_drift
  local model_target = deps.model_target
  local base_fingerprint = deps.base_fingerprint

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
            require("yana.turn_register"):push({
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
    local function accept_everything_claimed(drained, grant_token)
      local st = pool_for(state.opts or {})
      local shadow_apply = require("yana.shadow.apply")
      local active_refusal = shadow_apply.single_file_accept_refusal(state.change, state.bufnr)
      if active_refusal then
        -- THE PRESS IS OVER BEFORE ANY WRITE. Every claim this press won is
        -- surrendered here: a grant left on a change would still be sitting
        -- there when that file is next accepted singly, and would authorise
        -- that second, unrelated attempt.
        local sessions_mod = require("yana.shadow.apply_sessions")
        sessions_mod.clear_file_claim_grant(state.change)
        for _, item in ipairs(drained or {}) do
          sessions_mod.clear_file_claim_grant(item.change)
        end
        M._record_shadow_accept_refusal(state, active_refusal)
        return false
      end
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
      local turn = require("yana.turn_bind").get(st)

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
        local ok, err
        if item._yanad_claim_error then
          change_i.review_error = item._yanad_claim_error
          item._yanad_claim_error = nil
          table.insert(skipped, change_i.rel or path)
          table.insert(to_requeue, item)
          goto continue
        end
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
        local file_ledger, composed_i, conflicted, materialize_err, absorbed_from
        if parked_text ~= nil then
          file_ledger, composed_i, conflicted = parked_ledger(change_i), parked_text, {}
        else
          file_ledger, composed_i, conflicted, materialize_err, absorbed_from =
            queued_hunks.materialize(queued_deps, change_i)
        end
        if not file_ledger then
          change_i.review_error = change_i.review_error or materialize_err or "queued change has no hunks to decide"
          table.insert(skipped, change_i.rel or path)
          table.insert(to_requeue, item)
          goto continue
        end
        if turn then
          -- By-path refresh (Turn:add_file), same primitive
          -- `turn_bind.observe_open` uses when a review actually opens: this
          -- REPLACES whatever ledger intake seeded for `path` with the one
          -- about to be written from, so the decisions `decide_all` records
          -- on it below are visible to `Turn:pending_count` immediately --
          -- same object, no second copy.
          turn:add_file({ path = path, ledger = file_ledger, change = change_i })
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

        -- SOLE-WRITER CONTRACT. Under shadow mode the journaled applier is the only
        -- thing allowed to change the real tree (CORE: "The journaled applier is the
        -- sole real-tree writer"). The active file was fine because the ordinary Turn
        -- settle route owns it, which is exactly why this stayed invisible.
        --
        -- `composed_i` is the composition the materialize step just produced --
        -- the agent's bytes for an untouched file, and the operator's file with
        -- the absorbed hunks laid over it for one they edited. Freshness is not
        -- re-checked in this branch because the diary revalidates base_hash
        -- immediately before it acts, which is the authoritative check.
        if item.opts and item.opts.shadow_apply then
          if not item.opts.on_shadow_accept then
            change_i.review_error = "shadow accept handler missing for a queued change"
            table.insert(skipped, change_i.rel or path)
            table.insert(to_requeue, item)
            goto continue
          end
          if change_i.kind == "delete" then
            composed_i = nil
          elseif composed_i == nil then
            change_i.review_error = change_i.review_error or "queued change has no after content"
            table.insert(skipped, change_i.rel or path)
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
          -- THE BASE EVIDENCE MOVES WITH THE BYTES.
          if absorbed_from ~= nil then
            local rehash = base_fingerprint(absorbed_from)
            if rehash then
              change_i.base_hash = rehash
              change_i.base_state = "file"
              local st_now = (vim.uv or vim.loop).fs_lstat(path)
              if st_now and st_now.mode then
                change_i.base_mode = st_now.mode
              end
            end
          end
          local accept_opts = parked_bufnr and { staged_bufnr = parked_bufnr } or nil
          local aok, aerr, applied_i = item.opts.on_shadow_accept(change_i, composed_i, accept_opts)
          -- The applier consumed this file's grant. Whatever it left behind is
          -- dropped unconditionally at `::continue::` below, so no press can
          -- hand its authority to the next one.
          if aok == true then
            change_i.status = "accepted"
            -- Recorded here rather than before the applier is asked, because a refused
            -- write requeues this file: verdicts written ahead of the write would zero
            -- the turn's pending count for a file that is still pending, and the close
            -- edge below would fire over it. Every one of them goes through the
            -- ledger's own `decide_all` -- the turn parent never assigns a verdict
            -- (tests/test_verdict_writer_gate.sh).
            --
            -- `pre_decide_blocks` is taken HERE, before `decide_all` below moves
            -- anything -- the exact set `cA` itself decided for this file (every hunk
            -- it had, since a freshly materialized file's whole ledger was pending).
            -- `composed_i`/ `accept_opts` are kept too so `<C-r>` can replay the
            -- identical `on_shadow_accept` call rather than re-materializing.
            bulk_files[#bulk_files + 1] = {
              rel = change_i.rel or path,
              ledger = file_ledger,
              blocks = file_ledger:pending(),
              change = change_i,
              opts = item.opts,
              composed = composed_i,
              accept_opts = accept_opts,
              -- THE QUEUE SLOT THIS FILE CAME OUT OF. `cA` empties `st.queue` (above)
              -- -- which is where a turn member with no open review LIVES
              -- (review_queue.lua's W8 note: a file the Turn already saw stays a parked
              -- member on the queue, driven by `queue_insert_original`). The whole
              -- ORIGINAL item, not a rebuilt `{change, opts}` pair, so `_review_order`
              -- and anything else the queue carries survive the round trip.
              item = item,
              -- `materialize` returns them as `absorbed_from` only when there WAS an
              -- operator edit to absorb (review_queued_hunks.lua's `now`), so this is
              -- nil for the untouched file -- and for that file turn-start IS the
              -- pre-press disk state, which is why `change.before` stays correct there.
              -- When it is set, `u` owes THESE bytes: the operator's edit was already
              -- on disk when `cA` was pressed, so it was never part of `cA`'s step and
              pre_press_bytes = absorbed_from,
            }
            file_ledger:decide_all("accept")
            if type(applied_i) == "table" and applied_i.kind == "transfer" then
              vim.bo[applied_i.bufnr].modified = true
              change_i._accept_regime = "transfer"
              change_i._accept_bufnr = applied_i.bufnr
              change_i._accept_composed_hash = applied_i.composed_hash
              ledger.mark(change_ledger(change_i, item.opts), "accept_transferred")
            else
              change_i._accept_regime = "durable"
              ledger.mark(change_ledger(change_i, item.opts), "accept_applied")
            end
            -- The park is over: nothing may reopen this review from the parked
            -- staging once its bytes are on disk.
            change_i._parked_review = nil
            change_i._parked_item = nil
            -- CLEAR PAINTED BANDS. The active review's own buffer gets its
            -- incoming/authority/hint namespaces cleared once, below, after this whole
            -- loop (on `bufnr`/`state.bufnr`) -- but this accept is for a change that
            -- was never `state`, so that clear never touches its buffer. A parked
            -- review keeps its pending hunks painted on purpose while parked (ROW 112,
            -- `park_and_open_state`'s `retrace_repaint`), and nothing else is
            local band_bufnr = parked_bufnr or vim.fn.bufnr(path, false)
            if band_bufnr and band_bufnr > 0 and vim.api.nvim_buf_is_valid(band_bufnr) then
              vim.api.nvim_buf_clear_namespace(band_bufnr, NS, 0, -1)
              vim.api.nvim_buf_clear_namespace(band_bufnr, AUTH_NS, 0, -1)
              vim.api.nvim_buf_clear_namespace(band_bufnr, HINT_NS, 0, -1)
            end
            notify_owner(item.opts.on_accept, change_i, "on_accept")
            -- No `diff.reload_file(path)` here any more. shadow/apply.lua now
            -- reconciles this buffer itself, against the stat its own write left
            -- behind. The old call ran a BARE `checktime`, which sweeps EVERY
            -- loaded buffer and so could raise the blocking dialog for some
            -- unrelated stale one, and it re-read the file with no proof that
            -- disk still held the applier's result.
            if applied_i and applied_i.reconcile_error then
              notify_one_line(
                "yana: applied " .. (change_i.rel or path) .. " but could not reconcile its buffer: "
                  .. tostring(applied_i.reconcile_error),
                vim.log.levels.WARN
              )
            end
          else
            change_i.review_error = tostring(aerr or "shadow accept failed")
            local qlog = change_ledger(state.change, state.opts)
            ledger.record_decision(qlog, {
              action = "review_refused",
              actor = "system",
              reason = "shadow_accept_failed",
              detail = tostring(aerr),
              change_id = change_i.id,
              rel = change_i.rel or path,
            })
            local detail = change_i.shadow_refusal
            if type(detail) == "table" and type(detail.actual_fp) == "string" then
              local origin, drift_reason = attribute_drift(change_i, detail.reason or "stale_file", detail.actual_fp)
              detail = vim.tbl_extend("force", {}, detail)
              if origin then
                detail.origin = origin
              end
              if drift_reason then
                detail.reason = drift_reason
              end
            end
            ledger.attach_refusal(qlog, detail)
            table.insert(skipped, change_i.rel or path)
            table.insert(to_requeue, item)
          end
          goto continue
        end

        change_i.review_error = "queued accept reached the removed legacy path — shadow_apply required"
        table.insert(skipped, change_i.rel or path)
        table.insert(to_requeue, item)
        ::continue::
      end

      -- NO PRESS LEAVES ITS AUTHORITY BEHIND. Accepted, skipped or clashed,
      -- every file this press claimed gives its grant up here. A skipped file
      -- is requeued and may be accepted singly later; that later attempt must
      -- win its own claim rather than inherit this one's. (Swept after the
      -- loop, not at `::continue::`: a `goto` may only reach a label that ends
      -- its block, so nothing may follow the label inside the loop body.)
      do
        local sessions_mod = require("yana.shadow.apply_sessions")
        for _, item in ipairs(drained) do
          sessions_mod.clear_file_claim_grant(item.change)
        end
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
      -- `clear("teardown")` keeps its remaining callers, where a teardown is what
      -- actually happens.
      local active_entry = nil
      if state.hunk_ledger and state.hunk_ledger:is_open() and #active_blocks > 0 then
        active_entry = { rel = change.rel or change.path, ledger = state.hunk_ledger, blocks = active_blocks }
      end
      if state.hunk_ledger and state.hunk_ledger:is_open() then
        state.hunk_ledger:decide_all("accept")
      end
      -- `U` stays the unrelated, unchanged undo-ALL.
      if active_entry or #bulk_files > 0 then
        pcall(function()
          require("yana.turn_register"):push({
            kind = "accept_turn_step",
            rel = change.rel or change.path,
            workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd(),
            turn_id = change.turn_id or change.turn_gen,
            active = active_entry,
            files = bulk_files,
          })
        end)
      end
      record_last_hunk_decided("accept", nil)
      vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
      vim.api.nvim_buf_clear_namespace(bufnr, AUTH_NS, 0, -1)
      vim.api.nvim_buf_clear_namespace(bufnr, HINT_NS, 0, -1)
      -- Polled at this door's tail like every other (A1); `_poll_leave_edge` asks the
      -- real Turn, which is permanent for the session -- no per-drain scope to switch
      -- or dissolve any more. A `cA` the applier refuses resurrects this review
      -- (`_record_shadow_accept_refusal`) with its ledger still a live Turn member,
      -- still counted, still able to reach its own boundary on retry.
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

    local accept_everything = claims.new({
      facade = M,
      state = state,
      pool_for = pool_for,
      accept_everything_claimed = accept_everything_claimed,
    })

  return {
    reject_all = reject_all,
    accept_everything = accept_everything,
  }
end

return Factory
