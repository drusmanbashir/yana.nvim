-- Split out of review_turn.lua to meet the 500-line ceiling.
local M = {}

function M.new(deps)
  local M = deps.facade
  local pool_for = deps.pool_for
  local queue_remove_change = deps.queue_remove_change
  local queue_insert_original = deps.queue_insert_original
  local freeze_review_owner = deps.freeze_review_owner
  -- Same callback shape as review_finalize.lua:11 -- reset announces a kept
  -- file to its owner; a nil dep is a silent no-op, never a nil-call crash
  -- (builder finding, r_turn_reset control leg).
  local notify_owner = deps.notify_owner or require("yana.review_turn").notify_owner or function() end
  local diff = deps.diff
  local break_undo_block = deps.break_undo_block
  local buffer_lines = deps.buffer_lines
  local notify = deps.notify
  local notify_one_line = deps.notify_one_line
  local log = deps.log
  local announce_state = deps.announce_state
  local land_on = deps.land_on
  local park_and_open_state = deps.park_and_open_state

----------------------------------------------------------------------
--
-- `u` is unchanged: the last step, per hunk, in the file under the cursor.
-- `U` is the RESET, and there is no separate command for it: every file the
-- turn touched goes back to the state the operator was FIRST SHOWN, and the
-- cursor lands on the turn's first pending hunk.
--
-- The two hard cases are the ones the ruling names: (a) A file already settled and
-- CLOSED has no buffer to pop and no review to unwind. It is REOPENED -- put back in
-- the queue at its original position with its decision cleared -- so the operator gets
-- the review they were shown, not an empty one. (b) A file already ACCEPTED may already
-- be on disk.
--
-- Created/deleted members use the same memory-only load.
----------------------------------------------------------------------

--- THIS turn, and only this turn. The pool's `order` is never cleared between turns --
--- it is the panel's whole review history for that workspace -- so a sweep over it
--- reaches changes the operator settled in EARLIER turns, whose bytes `U` has no
--- business putting back.
local function same_turn(a, b)
  if a == b then
    return true
  end
  if a.turn_id ~= nil or b.turn_id ~= nil then
    return a.turn_id == b.turn_id
  end
  return a.turn_gen == b.turn_gen
end

--- Every change of this turn, in the order the operator was shown them.
local function turn_changes(state)
  local st = pool_for(state and state.opts or {})
  local this = state and state.change
  local ordered = {}
  for _, c in ipairs(st.order or {}) do
    if this == nil or same_turn(c, this) then
      ordered[#ordered + 1] = c
    end
  end
  table.sort(ordered, function(a, b)
    return (a._review_order or math.huge) < (b._review_order or math.huge)
  end)
  return ordered, st
end

local function turn_change_count(st, anchor)
  if type(st) ~= "table" then
    return 0
  end
  local n = 0
  for _, c in ipairs(st.order or {}) do
    if type(c) == "table" and (anchor == nil or same_turn(c, anchor)) then
      n = n + 1
    end
  end
  return n
end

function M.mark_turn_closed(turn)
  if type(turn) ~= "table" then
    return
  end
  local opts = turn.opts or turn.pool_opts or {}
  local st = pool_for(opts)
  local changes = turn.changes or {}
  local anchor = turn.anchor
  for _, c in ipairs(changes) do
    if type(c) == "table" then
      c._turn_closed = true
      c._parked_item = nil
      c._parked_review = nil
    end
  end
  if st and st.active and st.active.change and (anchor == nil or same_turn(st.active.change, anchor)) then
    st.active.decisions = {}
  end
end

--- Put one settled/parked change back in the queue exactly where it was, with
--- its decision cleared, so the review the operator was first shown reopens.
local function revive_change(st, c, opts)
  local item = queue_remove_change(st, c)
    or c._parked_item
    or { change = c, opts = opts, owner = freeze_review_owner(opts) }
  c._parked_item = nil
  c._parked_review = nil
  c.review_error = nil
  c.status = "pending"
  queue_insert_original(st, item)
end

local function load_file_snapshot(file, review_state, saved)
  if not (file and file.ledger and saved) then
    return false, "turn-start overlay is unavailable"
  end
  file.ledger:load_snapshot(saved.blocks)

  local bufnr = review_state and review_state.bufnr or vim.fn.bufnr(file.path, false)
  if saved.has_text and type(bufnr) == "number" and bufnr > 0
    and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
  then
    if review_state then
      review_state.watch_suspended = true
    end
    local wants_eol = saved.text:match("\n$") ~= nil
    vim.bo[bufnr].fixendofline = wants_eol
    vim.bo[bufnr].endofline = wants_eol
    break_undo_block(bufnr)
    local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, buffer_lines(saved.text))
    break_undo_block(bufnr)
    if not ok then
      if review_state then
        review_state.watch_suspended = false
      end
      return false, tostring(err)
    end
    M._recompute_modified(bufnr, file.ledger:pending(), file.path)
  end

  if review_state then
    review_state.decisions = {}
    review_state.sealed_decisions = {}
    review_state.undone_decisions = {}
    review_state.staged_text = saved.text
    if review_state._flush_paint then
      review_state._flush_paint("turn_start_overlay_load")
    end
    vim.schedule(function()
      review_state.watch_suspended = false
      review_state.watch_changes = {}
    end)
  end
  return true
end

-- It never replays decision stacks and never asks the journaled applier to touch disk.
local function load_turn_start(state)
  local st = pool_for(state and state.opts or {})
  local turn_bind = require("yana.turn_bind")
  local turn = turn_bind.get(st)
  local overlay = turn_bind.overlay(st)
  local path = state and state.change and diff.abs_path(state.change.path)
  local file = turn and turn:file(path)
  local saved = overlay and overlay:get(path)
  return load_file_snapshot(file, state, saved)
end

--- Reset every non-active file in memory.
local function undo_rest_of_turn(state)
  local restored, refused = {}, {}
  local ordered, st = turn_changes(state)
  local opts = state.opts or {}
  local turn_bind = require("yana.turn_bind")
  local turn = turn_bind.get(st)
  local overlay = turn_bind.overlay(st)
  for _, c in ipairs(ordered) do
    if c ~= state.change then
      local rel = c.rel or c.path or "?"
      local path = diff.abs_path(c.path)
      local file = turn and turn:file(path)
      local saved = overlay and overlay:get(path)
      local parked_state = c._parked_state
      local ok, err = load_file_snapshot(file, parked_state, saved)
      if ok then
        revive_change(st, c, opts)
        local parked = overlay:get(path)
        c._parked_review = {
          staged_text = parked.text,
          blocks = parked.blocks,
          sealed_decisions = {},
          undone_decisions = {},
        }
        c._accept_regime = nil
        c._accept_bufnr = nil
        c._accept_composed_hash = nil
        notify_owner(opts.on_kept_unreviewed, c, "on_kept_unreviewed")
        restored[#restored + 1] = rel
      else
        refused[#refused + 1] = rel .. ": " .. tostring(err)
      end
    end
  end
  announce_state()
  return restored, refused
end

--- `U` removed the files this turn CREATED, staging their bytes in the turn's private
--- evidence dir; stepping forward again puts them back, byte for byte, through the
--- journaled applier, and says which.
---
--- Returns true when it consumed the press. A missing staged copy (the turn's
--- evidence was pruned) is REPORTED, never a silent no-op -- redo-scoped
--- recovery is not an archive, and the operator has to be told which of the
--- two happened.
local function redo_staged_restores(state)
  local st = pool_for(state and state.opts or {})
  local pending = st.staged_removals
  if type(pending) ~= "table" or #pending == 0 then
    return false
  end
  st.staged_removals = nil
  local opts = state.opts or {}
  local restore = opts.on_shadow_restore_staged
  local names, failed = {}, {}
  for _, entry in ipairs(pending) do
    local c = entry.change
    local rel = entry.rel or (c and (c.rel or c.path)) or "?"
    local ok, err = false, "no journaled restore available for this review"
    if restore then
      ok, err = restore(c)
    end
    if ok == true then
      -- The exact inverse of `revive_change`: the change leaves the queue
      -- again and stands accepted, which is what it was when `U` found it.
      queue_remove_change(st, c)
      c._parked_item = nil
      c._parked_review = nil
      c.status = "accepted"
      notify_owner(opts.on_kept_unreviewed, c, "on_kept_unreviewed")
      names[#names + 1] = rel
    else
      failed[#failed + 1] = rel .. ": " .. notify.error_headline(err or "restore failed")
    end
  end
  if #names > 0 then
    local msg = string.format("yana: restored %d file(s) removed by U: %s", #names, table.concat(names, ", "))
    log.write("WARN", msg)
    notify_one_line(msg, vim.log.levels.INFO)
  end
  if #failed > 0 then
    local msg = string.format(
      "yana: %d file(s) could NOT be restored -- the staged copy is redo-scoped, and this turn's evidence is gone: %s",
      #failed,
      table.concat(failed, "; ")
    )
    log.write("WARN", msg)
    notify_one_line(msg, vim.log.levels.WARN)
  end
  announce_state()
  return true
end

  return {
    load_turn_start = load_turn_start,
    undo_rest_of_turn = undo_rest_of_turn,
    redo_staged_restores = redo_staged_restores,
    mark_turn_closed = M.mark_turn_closed,
    turn_change_count = turn_change_count,
  }
end

return M
