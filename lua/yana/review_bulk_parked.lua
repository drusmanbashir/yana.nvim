-- Parked-change composition and ledger construction for bulk accept.
local hunk_ledger = require("yana.hunk_ledger")
local hunk_identity = require("yana.hunk_identity")

local M = {}

function M.new(deps)
  local diff = deps.diff

  --
  -- The composition is the parked review's OWN bytes, not `change.after`:
  -- a hunk the operator rejected before parking is already back to base in
  -- them, so accepting the parked file covers what was still pending and
  -- reverts nothing that was decided. Accept-all is not a reset (that is
  -- `U`, row 48).
  --
  -- The buffer is still compared against what the park recorded, so a HUMAN
  -- edit made after the park is a clash exactly as before.
  local function parked_composition(change_i)
    local parked = change_i and change_i._parked_review
    if not parked then
      return nil, nil, nil
    end
    local staged = parked.staged_text
    local b = vim.fn.bufnr(change_i.path, false)
    if b > 0 and vim.api.nvim_buf_is_loaded(b) then
      local live = diff.buffer_bytes_snapshot(b)
      if live ~= nil then
        if staged ~= nil and not diff.text_equal_snapshot(live, staged) then
          return nil, "the parked review buffer was edited after it was parked"
        end
        return live, nil, b
      end
    end
    if staged == nil then
      return nil, "the parked review kept no staged content to accept"
    end
    return staged, nil, nil
  end

  -- Copied and scrubbed of paint through the one shared scrub (A2), for the same reason
  -- the parked REOPEN copies them (review_open.lua): the ids name another buffer's
  -- extmarks.
  local function parked_ledger(change_i)
    local parked = change_i and change_i._parked_review
    local blocks = {}
    local function add(block)
      if type(block) ~= "table" then
        return
      end
      for _, existing in ipairs(blocks) do
        if hunk_identity.same(existing, block) then
          return
        end
      end
      blocks[#blocks + 1] = hunk_ledger.scrub_paint(vim.deepcopy(block))
    end
    for _, block in ipairs((parked and parked.blocks) or {}) do
      add(block)
    end
    -- `parked.blocks` is the pending set. Decisions sealed before parking are
    -- still members of the retained ledger and remain acceptance evidence.
    for _, decision in ipairs((parked and parked.sealed_decisions) or {}) do
      add(decision.block)
    end
    table.sort(blocks, function(a, b)
      return (a.new_start_line or a.start_line or math.huge)
        < (b.new_start_line or b.start_line or math.huge)
    end)
    return hunk_ledger.open(blocks)
  end

  return parked_composition, parked_ledger
end

return M
