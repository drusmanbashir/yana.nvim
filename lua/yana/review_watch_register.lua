-- Size split of review_watch.lua: the register rows one native sequence carries.
local M = {}

function M.new(deps)
  -- `seq` is the NATIVE UNDO SEQUENCE this action belongs to, passed in by the
  -- flush rather than read here: one flush can carry several sequences, and
  -- reading the live one would give every action the last sequence's number and
  -- collapse them all into the single `actions[seq]` entry.
  local function push_buffer_edit(state, seq)
    local bufnr = state.bufnr
    if seq == nil then
      seq = (deps.buf_undo_seq and bufnr) and deps.buf_undo_seq(bufnr) or nil
    end
    local change = state.change
    if seq == nil or type(change) ~= "table" then return end
    local workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
    local register = require("yana.turn_register").for_workspace(workspace)
    local actions = state._buffer_edit_actions or {}
    state._buffer_edit_actions = actions
    if actions[seq] then return actions[seq] end
    local action = require("yana.undo_action_buffer_edit").new({
      rel = change.rel or change.path,
      workspace = workspace,
      turn_id = change.turn_id or change.turn_gen,
      undo_seq = seq,
    })
    register:push(action)
    actions[seq] = action
    return action
  end

  -- ONE RECORD PER `Ledger:merge` CALL, carried BY that native sequence's own
  -- `buffer_edit` row rather than pushed beside it.
  --
  -- WHY NOT A ROW OF ITS OWN: the deletion and the fusion are ONE forward group
  -- -- one native undo sequence, one keypress -- and the operator's group law
  -- (2026-09-06) says such a group reverses as ONE unit on the boundaries it
  -- applied forward. A separate register row would cost a SECOND `u` press and
  -- would leave a state in between with the text back and the ledger still
  -- merged, which is precisely the defect. Measured: with merges as their own
  -- rows the cross-file walk in r_breaker_32 needed one extra press per merge
  -- and ACTION16/17/18 stopped restoring C1/B2/A1 inside their budgets.
  --
  -- `review_undo.spend_buffer_edit` reads `hunk_merges` and moves them in the
  -- same press, membership before text on `u` and after it on `<C-r>`.
  --
  -- BOTH KINDS RIDE THE SAME LIST. `action.hunk_merges` is the buffer row's
  -- structural-record list; it carries `hunk_merge` rows AND `hunk_split` rows,
  -- in mutation order, and `review_undo.move_structural` dispatches on
  -- `row.kind`. The field keeps its original name because it is the shape a
  -- register row already has on disk and in `u_ledger_merge_restores_one_parent`.
  --
  -- A SPLIT NEEDS A LOSSLESS RECORD, not the merge row's two block lists:
  -- `try_split` touches `change._retrace_absorbed` as well as ledger
  -- membership, so the retrace entry and the model mirror either side of the
  -- mutation travel with it (`review_hunk_split.try_split`).
  local function attach_structural(state, action, entry)
    local change = state.change
    if type(action) ~= "table" or type(change) ~= "table" or type(entry) ~= "table" then return end
    local row
    if entry.kind == "hunk_split" then
      if type(entry.parent) ~= "table" or type(entry.children) ~= "table" then return end
      row = {
        kind = "hunk_split",
        parent = entry.parent,
        children = entry.children,
        before = entry.before,
        after = entry.after,
        model = entry.model,
        model_before = entry.model_before,
        model_after = entry.model_after,
        review_change = entry.review_change,
        retrace_key = entry.retrace_key,
        retrace_before = entry.retrace_before,
      }
    else
      if type(entry.members) ~= "table" or type(entry.merged) ~= "table" then return end
      row = {
        kind = "hunk_merge",
        members = entry.members,
        merged = entry.merged,
        before = entry.before,
        after = entry.after,
        pivot = entry.record and entry.record.pivot or nil,
      }
    end
    row.rel = change.rel or change.path
    row.workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
    row.turn_id = change.turn_id or change.turn_gen
    action.hunk_merges = action.hunk_merges or {}
    action.hunk_merges[#action.hunk_merges + 1] = row
  end

  return {

    push_buffer_edit = push_buffer_edit,

    attach_structural = attach_structural,

  }

end



return M
