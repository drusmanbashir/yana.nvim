-- THE REWIND WATCHER: which files are being listened to, and what an observed
-- history move means for them.
--
--
--
-- S2/P-D (item 12): the watch/record/drift/withdraw/floor machinery -- `attach`, the
-- `YanaRewindWatch` augroup, the `reconcile` stub, `peek`, `drift`, `note_open`,
-- `mark_withdrawn`, `floor_gate_pending` -- is GUTTED.

local M = {}
local moves = setmetatable({}, { __mode = "k" })
local owned_splices = setmetatable({}, { __mode = "k" })

local function review_register(state)
  local change = state.change
  local ws = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
  return require("yana.turn.turn_register").for_workspace(ws), change.rel or change.path
end

local function native_seq(bufnr)
  return vim.api.nvim_buf_call(bufnr, function() return vim.fn.undotree().seq_cur end)
end

local function history_error(reason)
  require("yana.notify").one_line("yana: " .. tostring(reason), vim.log.levels.WARN)
end

local function finish_native(state, move)
  if moves[state] ~= move then return end
  if state.closed or not vim.api.nvim_buf_is_loaded(state.bufnr) then moves[state] = nil; return end
  local bufnr = state.bufnr
  local target = native_seq(bufnr)
  if target == move.from then moves[state] = nil; return end
  -- The editor landed on the requested vertex. Return to the undisplayed
  -- starting vertex before replaying its existing ledger and publication actions.
  move.restoring = true
  local restored, why = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent undo " .. move.from)
  end)
  moves[state] = nil
  if not restored or native_seq(bufnr) ~= move.from then return history_error(why or "could not restore the history start") end
  local turn = require("yana.turn.turn_bind").get()
  if not turn or turn ~= move.turn or not turn:is_live() then return end
  local change = state.change
  local register, file = review_register(state)
  local ready, flush_error = require("yana.review_watch").finalize(bufnr, state)
  if not ready then return history_error(flush_error) end
  local plan, reason = register:native_plan(file, target, state.undo_open_seq,
    change.turn_id or change.turn_gen)
  if not plan then return history_error(reason) end
  local win = vim.api.nvim_get_current_win()
  for _, step in ipairs(plan) do
    local direction = step.back and "undo_key" or "redo_key"
    local ok, err = register:replay_native(step.row, step.back, function() return state._ops[direction](true) end)
    if not ok then history_error(err or "could not replay the selected history action"); break end
  end
  register:finish_native_replay()
  if vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_loaded(bufnr)
    and vim.api.nvim_win_get_buf(win) ~= bufnr then
    vim.api.nvim_win_set_buf(win, bufnr)
  end
end

-- Native history splices report the departing sequence while Neovim has its
-- undo tree synchronized. New text edits report an open edit sequence.
function M.native_splice(state, tree)
  local move = moves[state]
  if move and move.restoring then return true end
  if state.watch_suspended or state.closed or state._ops == nil or not tree or tree.synced ~= 1 then return false end
  if move then return true end
  local turn = require("yana.turn.turn_bind").get()
  if not (turn and turn:is_live() and not turn:is_frozen()) then return false end
  move = { from = tree.seq_cur, turn = turn }
  moves[state] = move
  vim.schedule(function() finish_native(state, move) end)
  return true
end

function M.native_pending(state)
  return moves[state] ~= nil
end

-- Capture the exact on_bytes splice before the rejection records its action.
function M.note_owned_splice(state, tree, sr, sc, oer, oec, ner, nec)
  if not (state._ops and tree and tree.synced == 0) then return end
  local record = owned_splices[state]
  if not record or record.seq ~= tree.seq_cur then
    local register, file = review_register(state)
    record = { seq = tree.seq_cur, from = register:position()[file], splices = {} }
    owned_splices[state] = record
  end
  record.splices[#record.splices + 1] = { sr, sc, oer, oec, ner, nec }
end

-- Record this rejection after its register row has been pushed.
function M.record_rejection(state, entry)
  local record = owned_splices[state]
  owned_splices[state] = nil
  if record and entry.pre_seq ~= entry.post_seq and entry.post_seq == record.seq then
    local register, file = review_register(state)
    if register:record_decision_native(file, record.from, entry.pre_seq, entry.post_seq, record.splices) then
      state.hunk_ledger:observe_buffer_seq(entry.post_seq)
    end
  end
end

function M.new(deps)
  assert(type(deps) == "table", "review_history dependencies required")

  local H = {}
  local watch = {}
  local function abs_path(path)
    if type(path) ~= "string" or path == "" then
      return nil
    end
    return vim.fn.fnamemodify(path, ":p")
  end

  local function lookup(path)
    if type(path) ~= "string" or path == "" then
      return nil, nil
    end
    if watch[path] then
      return path, watch[path]
    end
    local absolute = abs_path(path)
    if absolute and watch[absolute] then
      return absolute, watch[absolute]
    end
    if absolute then
      for key, record in pairs(watch) do
        if abs_path(key) == absolute then
          watch[absolute] = record
          if key ~= absolute then
            watch[key] = nil
          end
          return absolute, record
        end
      end
    end
    return nil, nil
  end

  -- `any -> gone`, and the ONLY way a record would leave the watch table.
  -- Kept for `H.forget_path`'s live callers outside this claim; `watch` is
  -- never populated any more, so this is a no-op in practice.
  local function forget(path)
    local key, record = lookup(path)
    if record then
      watch[key] = nil
    end
  end

  local holds = require("yana.review_hold").new({
    note_positions = function() end,
  })

  H.suppress = holds.suppress
  H.hold = holds.hold
  H.hold_current = holds.hold_current
  H.schedule = holds.schedule
  H.own_transaction = holds.own_transaction

  function H.forget_path(path)
    if type(path) == "string" then
      forget(path)
    end
  end

  function H.forget_owner(owner)
    for path, record in pairs(watch) do
      if owner == nil or deps.owners_match(record.owner, owner) then
        watch[path] = nil
      end
    end
  end

  return H
end

return M
