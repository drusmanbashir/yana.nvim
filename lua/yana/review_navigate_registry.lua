-- Change lookup, review-order bookkeeping, and register-decision reads --
-- split out of review_navigate.lua to hold it under the 500-line ceiling
-- (S2 P-C, action 14). `M.new(deps)` attaches these onto `deps.facade`
-- exactly as review_navigate.lua's own `M.new` did before the split.
local M = {}

function M.new(deps)
  local pool_for = deps.pool_for
  local remember_batch_item = deps.remember_batch_item
  local facade = deps.facade

--- Mint `_review_order` for `change` the SAME WAY `M.enqueue` and `park_and_open_state`
--- do -- both call `remember_batch_item` (above) on the workspace pool's own
--- `st.order`/`st.order_seq`, and nowhere else in this module assigns the field. No
--- second ordering scheme: this calls the exact same `remember_batch_item` the other
--- two paths call, so a reintegrated change sorts into `st.order` exactly where a fresh
--- `M.enqueue` of it would have placed it. Idempotent (`remember_batch_item` no-ops
function facade._ensure_review_order(change, opts)
  if not change then
    return
  end
  remember_batch_item(pool_for(opts or {}), { change = change })
end

--- The old fresh-object reintegration got that behaviour accidentally because it had no
--- `_review_order`, so `_ensure_review_order` appended it after every still-pending
--- sibling. Reusing the original table preserves identity; this helper deliberately
--- refreshes only its position in the turn navigation order so `[x`/`]x` see the same
--- sibling relation a fresh object would have had.
function facade._reopen_review_order(change, opts)
  if not change then
    return
  end
  local st = pool_for(opts or {})
  for i = #st.order, 1, -1 do
    if st.order[i] == change then
      table.remove(st.order, i)
    end
  end
  change._review_order = nil
  remember_batch_item(st, { change = change })
end

--- Searches `st.order`, the same accumulated list `turn_changes` (above, the set
--- `undo_rest_of_turn` iterates) draws from -- `pool_for` already partitions it by
--- workspace, so matching on `rel` alone is matching on `(workspace, rel)`. Returns the
--- LAST match (`st.order` only ever grows, never prunes a settled entry), which is the
--- most recently recorded change for this rel -- the one a same-turn accept/undo cycle
--- keeps reusing. Returns nil when nothing has ever been recorded for this rel in this
function facade._find_change_for_rel(rel, opts)
  if not rel then
    return nil
  end
  local st = pool_for(opts or {})
  local found = nil
  for _, c in ipairs(st.order or {}) do
    if c.rel == rel then
      found = c
    end
  end
  return found
end

--- Any change in this workspace pool that still carries `_last_review_opts`
--- with an `on_close`. Used when reopening a never-opened accept (cA sibling)
--- that never got its own opts stamped.
function facade._find_any_review_opts(ws)
  local st = pool_for({ workspace = ws })
  for _, c in ipairs(st.order or {}) do
    local o = c and c._last_review_opts
    if type(o) == "table" and type(o.on_close) == "function" then
      return o
    end
  end
  return nil
end

end

return M
