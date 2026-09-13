-- Resumed-decision reconciliation -- split out of review_open_bind.lua to hold it under
-- the 500-line ceiling (S2 P-C, action 14).
local M = {}

--- `bufnr`, `blocks` (mutated in place), `parked`, `parked_undone_decisions`,
--- `park_decision_anchor` -- same names review_open_bind.lua's `bind()` used locally
--- before the split.
function M.reconcile(bufnr, blocks, parked, parked_undone_decisions, park_decision_anchor)
  local resumed_decisions, resumed_sealed = {}, {}
  local resumed_undone = vim.deepcopy(parked_undone_decisions or {})
  -- `_retrace_reintegration` died with the retrace writer (S2 P-C).
  if parked then
    resumed_decisions = vim.deepcopy(parked.sealed_decisions or {})
    -- Give each resumed decision a live anchor again, from the rows the park resolved
    -- before `cleanup` cleared ANCHOR_NS.
    for _, d in ipairs(resumed_decisions) do
      local rows = d.anchor_rows
      if type(rows) == "table" and type(rows[1]) == "number" then
        d.anchor = park_decision_anchor(bufnr, rows[1], rows[2] or rows[1])
      end
    end
  else
    resumed_sealed = parked and vim.deepcopy(parked.sealed_decisions or {}) or {}
  end

  local function splice_in_order(block)
    local at = #blocks + 1
    for i, placed in ipairs(blocks) do
      if block.new_start_line < placed.new_start_line then
        at = i
        break
      end
    end
    table.insert(blocks, at, block)
  end
  local same_identity = require("yana.hunk_identity").same

  for _, d in ipairs(resumed_decisions) do
    splice_in_order(d.block)
  end

  -- An undone decision is already pending and therefore already represented
  -- in parked.blocks. Reuse that exact member; only a missing A4 match splices.
  for _, d in ipairs(resumed_undone) do
    local member
    for _, block in ipairs(blocks) do
      if same_identity(d.block, block) then
        member = block
        break
      end
    end
    if member then
      d.block = member
    else
      splice_in_order(d.block)
    end
  end

  return resumed_decisions, resumed_sealed, resumed_undone
end

return M
