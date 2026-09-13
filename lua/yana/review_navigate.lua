-- Navigation across hunks, files, workspaces, and registered decisions.
local review_park_census = require("yana.review_park_census")
local review_park_snapshot = require("yana.review_park_snapshot")
local park_teardown = review_park_snapshot.park_teardown
local M = {}

function M.new(deps)
  local facade = deps.facade
  local pools = deps.pools
  local pool_for = deps.pool_for
  local freeze_review_owner = deps.freeze_review_owner
  local focus_buf = deps.focus_buf
  local current_block = deps.current_block
  local nearest_block = deps.nearest_block
  local land_on = deps.land_on
  local block_signature = deps.block_signature
  local parked_pending_blocks = deps.parked_pending_blocks
  local pending_hunk_count_for = deps.pending_hunk_count_for
  local remember_batch_item = deps.remember_batch_item
  local queue_remove_change = deps.queue_remove_change
  local queue_insert_original = deps.queue_insert_original
  local announce_state = deps.announce_state
  local notify_one_line = deps.notify_one_line
  local notify = deps.notify
  local log = deps.log
  local break_undo_block = deps.break_undo_block
  local record_decision = deps.record_decision
  local open_or_abandon = deps.open_or_abandon
  local diff = deps.diff
  local M = facade

  require("yana.review_navigate_registry").new({
    facade = facade,
    pool_for = pool_for,
    remember_batch_item = remember_batch_item,
  })

-- The ledger monitors ALL buffers regardless of which is active: every file the Turn
-- touches stays a live navigation target, active or parked, for the WHOLE Turn, not
-- just the ones ahead of the CURRENT file in open-order. This walks the full cycle,
-- wrapping past either end exactly once, so every OTHER file in the turn is a reachable
-- candidate regardless of which end of `ordered` the current file sits at.
local function ordered_target_for_state(state, direction)
  local change = state and state.change
  local st = pool_for((state and state.opts) or {})
  local end_text = direction == "next"
      and "last pending hunk in the last affected file"
    or "first pending hunk in the first affected file"
  local ordered = {}
  for _, c in ipairs(st.order or {}) do
    ordered[#ordered + 1] = c
  end
  table.sort(ordered, function(a, b)
    return (a._review_order or math.huge) < (b._review_order or math.huge)
  end)
  local total = #ordered
  if total == 0 then
    return nil, end_text
  end
  local start
  for i, c in ipairs(ordered) do
    if c == change then
      start = i
      break
    end
  end
  -- `change` itself carries no `_review_order` yet (never enqueued or
  -- parked -- the turn's own first/last-opened file): it has no position in
  -- `ordered` to walk from, so start the wrap from the edge each direction
  -- reads as "just past the end", which visits every real entry exactly
  -- once without ever matching `change` (it is not a member of `ordered`).
  if not start then
    start = direction == "next" and 0 or (total + 1)
  end
  local step = direction == "next" and 1 or -1
  local i = start
  for _ = 1, total do
    i = i + step
    if i > total then
      i = 1
    elseif i < 1 then
      i = total
    end
    if i == start then
      break
    end
    local candidate = ordered[i]
    if pending_hunk_count_for(candidate, st) > 0 then
      local item = queue_remove_change(st, candidate)
        or candidate._parked_item
        or { change = candidate, opts = state.opts, owner = freeze_review_owner(state.opts) }
      candidate._parked_item = nil
      return item, nil
    end
    notify_one_line(
      "yana: " .. (candidate.rel or candidate.path or "?") .. " settled -- skipping",
      vim.log.levels.INFO
    )
  end
  return nil, end_text
end

  --- The OPEN half of `park_and_open_state`, lifted out whole so a caller
  --- that has ALREADY parked -- or that has nothing left to park -- can land
  --- on a target without parking a SECOND time.
  ---
  --- By then `undo_action_file_creation.detach` had already parked the removed file,
  --- snapshotting its 7 good lines into `change._parked_review.staged_text`, and THEN
  --- blanked its buffer -- so the second park re-snapshotted the BLANK over the good
  --- text. A probe at the `<C-r>` revive read `staged_len=1`, and the revive faithfully
  --- restored one empty line. Splitting the halves gives `staged_text` ONE writer per
  --- park again.
  ---
  --- Returns `ok, err`; `err` is `open_or_abandon`'s, for the burst guard
  --- that stays with the parking caller.
  local function open_target_item(st, target_item, landing, direction)
    local target_change = target_item and target_item.change
    if not st or not target_change then
      return false, nil
    end
    -- NEVER OPEN DIRECTLY OVER A STALE QUEUE DUPLICATE. Opening it here (below) sets
    -- `st.active` directly, bypassing `process_next_impl`'s own queue pop, so the old
    -- queue entry survives pointing at the SAME change.
    queue_remove_change(st, target_change)
    local ok, err = open_or_abandon(target_change, target_item.opts)
    if ok and st.active and st.active.change == target_change then
      target_change._nav_refusal_announced = nil
      st.active.queue_item = target_item
      announce_state()
      vim.schedule(function()
        local active_state = st.active
        if active_state and active_state.change == target_change then
          -- "none" is NOT "do nothing": `land_on` is two halves -- `focus_buf`
          -- (tabpage + window onto the file) and then the cursor placement, and
          -- only the second is retired. `land_on` with no block is exactly the
          -- first half (review_geometry.lua, `if not block then return true`),
          -- so the undo path makes its file current, as F-UNDO-CURSOR says, and
          -- leaves the cursor wherever neovim left it. Skipping the call
          -- outright stranded a cross-file `u` in the PARKED file, whose review
          -- keymaps the park had already deleted, so the next `u` there was raw
          -- neovim on a parked review's staged bytes.
          local block = nil
          if landing ~= "none" then
            local want_first = (landing == "first")
              or (landing == nil and direction == "next")
            local live = active_state.hunk_ledger:pending()
            block = want_first and live[1] or live[#live]
          end
          land_on(target_change.path, active_state.bufnr, block)
        end
      end)
      return true, nil
      end
    return false, err
  end

--- `landing` (optional): which hunk of the newly opened file to land on, "first",
--- "last" (default follows travel direction), or "none" -- focus the file and move
--- the cursor NOWHERE. "none" exists for the undo path: a cross-file `u` must make
--- the other buffer current for neovim's own undo to run in it, but the cursor that
--- undo restores is the answer (F-UNDO-CURSOR), and this
--- function's scheduled landing used to overwrite it after the press. `allow_empty` (optional, default false):
--- a file with zero pending hunks has nothing left to decide, so `]x`/`[x` pass it
--- true and walk on; without that the press is accepted and the user is stranded in
--- an already-settled file. Every other caller keeps the guard.
local function park_and_open_state(state, direction, target_item, landing, allow_empty)
  local change = state and state.change
  local bufnr = state and state.bufnr
  if not (state and change and bufnr) then
    return false
  end
  break_undo_block(bufnr)
  local staged, snap_err = diff.buffer_bytes_snapshot(bufnr)
  if staged == nil then
    change.review_error = tostring(snap_err or "could not snapshot review buffer")
    notify_one_line("yana: refused to park " .. (change.rel or change.path) .. " -- " .. change.review_error, vim.log.levels.WARN)
    return false
  end
  local pending_blocks = parked_pending_blocks(state)
  if #pending_blocks == 0 and not allow_empty then
    return false
  end
  local parked_item = state.queue_item or {
    change = change,
    opts = state.opts,
    owner = freeze_review_owner(state.opts),
  }
  local st = pool_for(state.opts or {})
  remember_batch_item(st, parked_item)
  -- Anchor-resolution + sealed/undone decision snapshotting lives in
  -- review_park_snapshot.lua (split out of this file on dev): a decision's
  -- anchor extmark dies with the park (`review_lifecycle.M.cleanup` clears
  -- ANCHOR_NS), so each anchor is resolved to rows there, while it is still
  -- alive, for the resumed review's `pop_decision` to use.
  local sealed, undone = review_park_snapshot.capture(state, bufnr)
  -- Increments once per park of this change; copied into the parked snapshot below so
  -- the matching resume (review_open_bind.lua) can quote the SAME number back -- the
  -- join key across a park/resume pair that may be separated by an arbitrary number of
  -- other files' presses.
  change._park_seq = (change._park_seq or 0) + 1
  change._parked_review = {
    staged_text = staged,
    blocks = pending_blocks,
    pending_signature = block_signature(pending_blocks),
    model_hunks = vim.deepcopy(state.model_hunks or {}),
    model_source = state.model_source,
    sealed_decisions = sealed,
    undone_decisions = undone,
    park_seq = change._park_seq,
    -- Carried, not copied: Neovim's undo history for this buffer survives the
    -- park untouched, so the ledger transitions keyed to those sequences must
    -- survive with it. A rebuild that starts from a fresh history cannot follow
    -- a `u` or `<C-r>` taken after the resume -- the bytes move and the ledger
    -- does not. The frames name the pre-park block tables; the resumed ledger
    -- resolves them by `hunk_identity` (hunk_ledger_buffer_history.lua).
    buffer_history = state.hunk_ledger and state.hunk_ledger.buffer_history or nil,
  }
  review_park_census.emit(change, state, bufnr, pending_blocks, sealed, direction)
  change._parked_item = parked_item
  change.status = "pending"

  record_decision(state, "review_parked", {
    direction = direction,
    hunks_remaining = #pending_blocks,
    target_rel = target_item and target_item.change and (target_item.change.rel or target_item.change.path) or nil,
  })
  require("yana.log").lifecycle_later("review.park", {
    turn_id = change.turn_id or change.turn_gen,
    generation = change.turn_gen,
    path = change.rel or change.path,
    direction = direction,
  })
  park_teardown(state, bufnr)
  change._parked_state = state
  -- A park that CROSSES TO ANOTHER FILE keeps its own
  -- still-pending hunks PAINTED, so it asks the ledger to re-emit its one
  -- signal (the render lands at site `ledger_dirty`).
  --
  -- Not when the file being opened IS this file: a reintegration that
  -- reopens the same buffer (a second `u` into a file the first `u` already
  -- reopened) rebuilds every hunk from the turn-start model and paints them
  -- itself. Painting the parked blocks here first describes lines the walk
  -- has just moved and withdraws a hunk that is not stale ("hunk ? no
  -- longer matches the buffer"; r75_redo_replays_mixed_decisions_in_order).
  local same_file = target_item
    and type(target_item.change) == "table"
    and (target_item.change.rel or target_item.change.path) == (change.rel or change.path)
  --
  -- The request used to be gated on `target_item.retrace_repaint` as well.
  -- NOTHING IN THE TREE EVER SETS THAT FIELD (no writer anywhere under `lua/`),
  -- so the branch was dead and the cross-file park ran no `ledger_dirty` render
  -- at all -- measured: the guard is reached with `retrace_repaint=nil`,
  -- `same_file=false`, a valid bufnr and a live ledger callback, and
  -- `request_paint` is never called. Crossing to ANOTHER file is the whole
  -- condition; the `same_file` case above is the one that must not repaint.
  if target_item and not same_file and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    if state.hunk_ledger then
      state.hunk_ledger:request_paint()
    end
  end
  st.active = nil
  queue_insert_original(st, parked_item)
  announce_state()

  local target_change = target_item and target_item.change
  if not target_change then
    return false
  end
  local ok, err = open_target_item(st, target_item, landing, direction)
  if ok then
    return true
  end

  -- Announce once per distinct reason; a later attempt that fails for a genuinely
  -- different reason, or that succeeds (cleared above), is still reported.
  local nav_err_text = tostring(err)
  if target_change._nav_refusal_announced ~= nav_err_text then
    target_change._nav_refusal_announced = nav_err_text
    notify_one_line(
      "yana: refused to navigate from " .. (change.rel or change.path)
        .. " -- could not reopen " .. (target_change.rel or target_change.path or "?")
        .. ": " .. notify.error_headline(err),
      vim.log.levels.WARN
    )
  end
  queue_remove_change(st, change)
  local reopen_ok, _reopen_err = open_or_abandon(change, parked_item.opts)
  if reopen_ok and st.active and st.active.change == change then
    st.active.queue_item = parked_item
    announce_state()
    return false
  end
  queue_insert_original(st, parked_item)
  announce_state()
  return false
end

local function navigate_or_park_state(state, direction)
  local bufnr = state and state.bufnr
  local blocks = state and state.hunk_ledger and state.hunk_ledger:pending() or {}
  local path = state.change and state.change.path
  -- Nothing left to decide here: there is no hunk to land on, so the only
  -- honest answer to the press is the next file. `allow_empty` because this
  -- file's own ledger IS empty -- that is the reason we are leaving.
  if #blocks == 0 then
    local item, end_msg = ordered_target_for_state(state, direction)
    if not item then
      notify_one_line("yana: already at the " .. end_msg, vim.log.levels.INFO)
      return
    end
    park_and_open_state(state, direction, item, nil, true)
    return
  end
  local block, idx = current_block(blocks, bufnr, direction)
  if not block then
    land_on(path, bufnr, nearest_block(blocks, bufnr, direction))
    return
  end
  local at_edge = (direction == "next" and idx == #blocks)
    or (direction == "prev" and idx == 1)
  if not at_edge then
    -- Step off the block the direction just resolved. `nearest_block` re-reads
    -- the cursor and, on a shared line, picks the FIRST containing block again,
    -- landing us back where we started; `blocks` is ordered, so the neighbour of
    -- the resolved index is the same answer everywhere the two can agree.
    local step = direction == "next" and 1 or -1
    land_on(path, bufnr, blocks[idx + step] or nearest_block(blocks, bufnr, direction))
    return
  end
  local item, end_msg = ordered_target_for_state(state, direction)
  if not item then
    notify_one_line("yana: already at the " .. end_msg, vim.log.levels.INFO)
    return
  end
  park_and_open_state(state, direction, item)
end
M._navigate_or_park_state = navigate_or_park_state

local function active_state_for_global_navigation()
  local current = pool_for({}).active
  if current then
    return current
  end
  for _, st in pairs(pools) do
    if st.active then
      return st.active
    end
  end
  return nil
end

--- Global `]x`/`[x`. Returns `true` when Yana navigated, else `false` plus a
--- REASON: "no-review" (nothing to navigate -- not a failure, the caller
--- stands aside so whatever else owns the key can run) or "bad-direction" /
--- "focus-failed" (a real navigation failure the user must be told about).
function M.navigate_active_review(direction)
  if direction ~= "next" and direction ~= "prev" then
    return false, "bad-direction"
  end
  local state = active_state_for_global_navigation()
  if not state then
    return false, "no-review"
  end
  if not focus_buf(state.change.path, state.bufnr) then
    notify_one_line("yana: cannot open the reviewed file " .. tostring(state.change.path), vim.log.levels.WARN)
    return false, "focus-failed"
  end
  navigate_or_park_state(state, direction)
  return true
end

M._park_and_open_state = park_and_open_state
M._open_target_item = open_target_item
-- Action C's advance hook (turn_bind.lua's `current_advance`, wired by
-- review_open_bind.lua) needs the SAME target-finder `]x`/`[x` use --
-- the next pending file in the turn's own order, wrapping once -- so it is
-- exposed here rather than reimplemented.
M._ordered_target_for_state = ordered_target_for_state


  return {
    park_and_open_state = park_and_open_state,
  }
end

return M
