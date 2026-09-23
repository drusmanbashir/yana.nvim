-- Inline review queue, status, and guarded-open coordination.
local hunk_ledger = require("yana.hunk_ledger")

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
function M.carryable_review_opts(opts)
  opts = opts or {}
  return {
    on_close = opts.on_close,
    review_tabs_state_path = opts.review_tabs_state_path,
    review_owner = opts.review_owner,
    review_turn = opts.review_turn,
    on_accept = opts.on_accept,
    on_reject = opts.on_reject,
    on_kept_unreviewed = opts.on_kept_unreviewed,
    on_system_refused = opts.on_system_refused,
  }
end

-- Registers fn as a state observer; returns a function that removes it.
function M.on_state_change(fn)
  observers[#observers + 1] = fn
  return function()
    for i, f in ipairs(observers) do
      if f == fn then
        table.remove(observers, i)
        return
      end
    end
  end
end

-- Observers must be READ-ONLY with respect to this engine: they run mid-fan-
-- out and, on the M.open path, before the session is fully built, so calling
-- back into resolve_change/focus_active would reenter a half-constructed
-- review. Iterate a snapshot so an observer that unsubscribes itself here
-- cannot make the walk skip the next one.
local function announce_state()
  local snapshot = { unpack(observers) }
  for _, fn in ipairs(snapshot) do
    -- An observer is panel code; a throw here must not break the engine, for
    -- the same reason notify_owner exists.
    pcall(fn)
  end
end

--
-- NOT a single pre-existing funnel: `announce_state()` above looks like the one
-- function every transition passes through, but it is not -- a per-hunk accept/reject
-- that leaves the review open (`accept_block_at`/ `reject_block_at`) never calls it;
-- only a FULL close does (`finish_session` and its three tails). So this is the
-- documented fallback: one shared helper, called at each transition's own tail, always
-- strictly after that transition's own `render_blocks`/`render_invariant` call -- never
--
-- `pcall`-guarded like `announce_state`: a throwing `autocmd User` handler is the
-- LISTENER's bug, and must not break the engine emitting it.
--
-- Defined as `M._emit_review_settled`, not a bare local: `M.open` (the function every
-- hunk/undo/redo/reload closure below is nested inside) is already at Lua's 60-upvalue
-- ceiling -- `M` itself is already one of its upvalues (`M._test`, `M.cleanup`,
-- `M.build_diff_blocks`, ... are called from inside it throughout), so reaching this
-- function as an `M` FIELD adds zero new upvalues to every nested closure that calls
-- it.
function M._emit_review_settled(bufnr, turn, reason)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "YanaReviewSettled",
    data = { buf = bufnr, turn = turn, reason = reason },
  })
end

-- M.open installs real, buffer-visible side effects -- augroup, BufWriteCmd guard,
-- keymaps, extmarks, winhl -- and keeps going. false").
local reactivate_parked_state = require("yana.review_park_snapshot").reactivate_factory(pool_for, announce_state)
M._reactivate_parked_state = reactivate_parked_state

local function open_or_abandon(change, opts)
  -- Three answers, not two. `true` resumed the parked review in place; `false,
  -- nil` declined to (not resumable this way -- rebuild it below); `false, err`
  -- STARTED the resume and could not finish it.
  --
  -- The third is why this is not a plain boolean. The rebuild below is the one
  -- route that consumes `change._parked_review`, and a replacement that has
  -- already failed to bind once is exactly the case the recovery snapshot exists
  -- for (design: keep `_parked_review` until a replacement has bound
  -- successfully). Falling through would spend the snapshot on a second attempt
  -- with no more chance than the first and leave nothing to retry from. So a
  -- failed resume refuses here, with the review still parked and still
  -- recoverable, and the caller's own recovery decides what to put on screen.
  local resumed, resume_err = reactivate_parked_state(change, opts)
  if resumed then
    return true, nil
  end
  if resume_err ~= nil then
    local err_text = tostring(resume_err)
    if change and change.review_error == nil then
      change.review_error = err_text
    end
    -- Same reason the throw branch below announces: the panel is already
    -- painting a claim line for a review that is not going to appear.
    announce_state()
    return false, err_text
  end
  local pcall_ok, a, b = pcall(M.open, change, opts)
  if not pcall_ok then
    local st = pool_for(opts or {})
    if st.active and st.active.change == change then
      pcall(M.cleanup, st.active)
      st.active = nil
    end
    -- STAMP BEFORE ANNOUNCE. The claim renderer reads review_error first; if the
    -- announce runs while it is still nil the row falls through to the queued branch
    -- and paints "Queued — no hunks in this file yet" for a change that is not queued
    -- and will never open. Stamping at the call sites instead was too late: the direct
    -- M.review path re-raises straight after stamping and never announces again.
    local err_text = tostring(a)
    if change and change.review_error == nil then
      change.review_error = err_text
    end
    -- M.open announces "open" the instant it sets `active`, BEFORE it can
    -- still throw. Without an announce here the panel keeps a claim line
    -- asserting an open review that was just torn down -- "it says hunks
    -- opened but I see nothing in the file" -- until some unrelated engine
    -- transition happens to repaint it. Announcing here covers every entry.
    announce_state()
    return false, err_text
  end
  if a == true then
    return true, nil
  end
  -- M.open refused cleanly (no throw): `b` is its own reason string where it named one;
  -- `change.review_error` (stamped by the refusing branch itself) is the fallback for
  -- the rare site that has not been given one, so the caller never renders the bare
  -- boolean `a` again. REC-PLANT seam (`raw_refusal`, default off, see FAULT above):
  -- forward pcall's own boolean in the reason slot again, so the caller's message reads
  -- "... could not reopen <file>: false".
  return false,
    (FAULT.raw_refusal and tostring(a))
      or (b ~= nil and tostring(b))
      or (change and change.review_error)
      or "review did not open"
end

--- A refused open, said ONCE and in the right register.
---
--- Two of these fired for a single refused reopen and both reached the operator: an
--- ERROR "inline review failed: <reason>" from whichever entry point was used, and a
--- WARN "could not open review buffer: <reason>" from `open_review_buffer` underneath
--- it. That is right for a review the OPERATOR asked for -- they pressed a key and
--- nothing opened, so they must be told why. It is wrong for a reopen the WALK asked
--- for: `u` is a key shared with Neovim, the operator asked for an undo and got one,
---
function M._announce_open_failure(change, text, level)
  local line = "yana: " .. text
  log.write("WARN", line)
  notify_one_line(line, level)
end

-- The guarded entry for callers outside the queue (the diff-theme preview).
-- M.open must never be called raw: a throw after `active = state` leaves the
-- singleton set forever, which stalls process_next and makes every later
-- review refuse with "close active inline review first" -- a ghost review
-- nobody can close.
function M.open_guarded(change, opts)
  local ok, err = open_or_abandon(change, opts)
  if not ok then
    -- review_error is already stamped by open_or_abandon, before its announce.
    M._announce_open_failure(change, "inline review failed: " .. notify.error_headline(err), vim.log.levels.ERROR)
    return false, nil
  end
  -- M.open sets `active` on the pool synchronously, before it can still
  -- throw (see the comment above M.cleanup) -- open_or_abandon's own (ok,
  -- err) collapsed the state out of its return, but it is still right there.
  local st = pool_for(opts or {})
  local state = (st.active and st.active.change == change) and st.active or nil
  return true, state
end

local process_next_for

--- Forward declaration. Defined with the rest of the rewind machinery in
--- "WHOLE-REVIEW REWIND AT THE SINGLE INSERT BOUNDARY" far below, and used
--- up here by `schedule_queue_advance`: deferred work started while Yana
--- owns a transaction is still Yana's own transaction, and must run under
--- the same guard rather than after it.
local rewind_schedule

local function process_next_impl(st)
  if st.active or #st.queue == 0 then
    return nil
  end
  local item = table.remove(st.queue, 1)
  local change = item.change
  local ok, err = open_or_abandon(change, item.opts)
  if not ok then
    M._announce_open_failure(change, "inline review failed: " .. notify.error_headline(err), vim.log.levels.ERROR)
    vim.schedule(function()
      process_next_for(item.opts)
    end)
  end
  announce_state()
  return change
end

function process_next_for(opts)
  local attempted = nil
  log.guard("yana.inline_diff process_next", function()
    attempted = process_next_impl(pool_for(opts or {}))
  end)
  return attempted
end

local function process_next(opts)
  process_next_for(opts)
end

local function schedule_queue_advance(state)
  if not state then
    return
  end
  if state._skip_queue_advance then
    return
  end
  -- `rewind_schedule`, not `vim.schedule`. A queue advance is almost always
  -- queued by a close, and a close inside the cross-file retrace walk (a redo
  -- putting the last decision back, say) belongs to that walk: the advance
  -- opens the NEXT file's review and stages its proposal bytes, and those
  -- bytes are Yana's, not the operator time travelling. Outside a hold this
  -- is exactly `vim.schedule`.
  rewind_schedule(function()
    process_next_for(state.opts)
  end)
end

local function block_signature(blocks)
  local sig = {}
  for i, block in ipairs(blocks or {}) do
    sig[i] = table.concat({
      tostring(block.model_index or i),
      tostring(#(block.old_lines or {})),
      tostring(#(block.new_lines or {})),
      tostring(block.new_start_line or ""),
      tostring(block.new_end_line or ""),
    }, ":")
  end
  return table.concat(sig, "|")
end

local function parked_pending_blocks(state)
  local out = {}
  for i, block in ipairs(state and state.hunk_ledger and state.hunk_ledger:pending() or {}) do
    -- A2: one scrub, owned by the ledger module (this was one of its five
    -- near-copies). It also nils `incoming_orphaned_sources`, which this copy
    -- kept: an orphan list names paint sources whose marks are being dropped
    -- one line up, so carrying it into a park outlives what it describes.
    out[i] = hunk_ledger.scrub_paint(vim.deepcopy(block))
  end
  return out
end

local function count_live_pending_blocks(state)
  local n = 0
  for _, block in ipairs(state and state.hunk_ledger and state.hunk_ledger:pending() or {}) do
    local has_incoming = block and (
      block.incoming_extmark_id ~= nil
      or block.delete_extmark_id ~= nil
      or block.authority_extmark_id ~= nil
      or (type(block.incoming_extmark_ids) == "table" and next(block.incoming_extmark_ids) ~= nil)
    )
    if has_incoming then
      n = n + 1
    end
  end
  return n
end

local function count_total_hunks_for_change(change)
  if not change then
    return 0
  end
  if type(change._parked_review) == "table" and type(change._parked_review.blocks) == "table" then
    return #(change._parked_review.blocks or {})
  end
  if type(change._authority_hunk_total) == "number" then
    return change._authority_hunk_total
  end
  local blocks = M.build_diff_blocks(change.before or "", change.after or "")
  local total = #(blocks or {})
  change._authority_hunk_total = total
  return total
end

local function undecided_hunks_for_change(change, st)
  if not (change and change.path) then
    return 0
  end
  local turn = require("yana.turn.turn_bind").get(st)
  local file = turn and turn:file(diff.abs_path(change.path)) or nil
  local ledger = file and file.ledger
  return ledger and #ledger:pending() or 0
end

local review_tabs = require("yana.review_tabs").new({
  pool_for = pool_for,
  pools = pools,
  undecided_hunks_for_change = undecided_hunks_for_change,
  notify_one_line = notify_one_line,
})

function M._review_tabs_init_for_turn(st, change, opts)
  return review_tabs.init_for_turn(st, change, opts)
end

-- The ONE placer of review windows, reached from review_geometry.focus_buf
-- when no window shows the review buffer.
function M._review_tabs_place(path, bufnr)
  return review_tabs.place_for_path(path, bufnr)
end

function M.review_tabs_state_path(opts)
  return review_tabs.state_path(opts or {})
end

function M.prompt_close_owned_tabs(opts)
  return review_tabs.prompt_close_owned_tabs(opts)
end

function M.close_owned_tabs(opts)
  return review_tabs.close_owned_tabs(opts)
end

function M.turn_undecided_hunks(turn)
  if type(turn) ~= "table" then
    return 0
  end
  local opts = turn.opts or turn.pool_opts or {}
  local st = pool_for(opts)
  local changes = turn.changes
  if type(changes) ~= "table" then
    return 0
  end
  local pending = 0
  for _, c in ipairs(changes) do
    pending = pending + undecided_hunks_for_change(c, st)
  end
  return pending
end

-- Navigation "undecided" (I5): the Turn File's own pending count -- ledger
-- pending hunks plus a textless operation still pending -- plus one for a
-- permission proposal still unresolved under `ask`. Close and tab authority
-- (`undecided_hunks_for_change`) stays text-only; this is what `]x`/`[x` walk.
local function pending_hunk_count_for(change, st)
  if not (change and change.path) then
    return 0
  end
  local turn = require("yana.turn.turn_bind").get(st)
  local file = turn and turn:file(diff.abs_path(change.path)) or nil
  if not file then
    return 0
  end
  local n = file:pending_count()
  local policy = require("yana.review_permissions").permission_policy(file, turn)
  -- Unresolved = no record for THIS proposal (I3 content key): a record left
  -- by an earlier, since-revised proposal does not resolve the new one.
  local settle = require("yana.turn.turn_settle")
  if policy == "ask" and settle.mode_proposal_key(file) ~= nil
    and settle.current_mode_verdict(file) == nil then
    n = n + 1
  end
  return n
end

local function remember_batch_item(st, item)
  local change = item and item.change
  if not (st and change) then
    return
  end
  if not change._review_order then
    st.order_seq = (st.order_seq or 0) + 1
    change._review_order = st.order_seq
    st.order[#st.order + 1] = change
  end
end

local function queue_remove_change(st, change)
  for i, item in ipairs((st and st.queue) or {}) do
    if item.change == change then
      return table.remove(st.queue, i)
    end
  end
  return nil
end

local function queue_insert_original(st, item)
  if not (st and item and item.change) then
    return
  end
  queue_remove_change(st, item.change)
  local order = item.change._review_order or math.huge
  local pos = #st.queue + 1
  for i, existing in ipairs(st.queue) do
    local eo = existing.change and existing.change._review_order or math.huge
    if order < eo then
      pos = i
      break
    end
  end
  table.insert(st.queue, pos, item)
end

-- A file the Turn already saw now stays a PARKED member (queue_insert_original above,
-- driven by the park/navigate doors), never an ended-and-reinserted one.

    return {
      announce_state = announce_state,
      open_or_abandon = open_or_abandon,
      process_next_for = process_next_for,
      process_next = process_next,
      schedule_queue_advance = schedule_queue_advance,
      block_signature = block_signature,
      parked_pending_blocks = parked_pending_blocks,
      count_live_pending_blocks = count_live_pending_blocks,
      count_total_hunks_for_change = count_total_hunks_for_change,
      undecided_hunks_for_change = undecided_hunks_for_change,
      pending_hunk_count_for = pending_hunk_count_for,
      remember_batch_item = remember_batch_item,
      queue_remove_change = queue_remove_change,
      queue_insert_original = queue_insert_original,
      review_tabs = review_tabs,
      set_rewind_schedule = function(fn)
        rewind_schedule = fn
      end,
    }
  end
  setfenv(setup, env)
  return setup()
end

return Factory
