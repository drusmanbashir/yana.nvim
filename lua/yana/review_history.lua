-- THE REWIND WATCHER: which files are being listened to, and what an observed
-- history move means for them.
--
--
--
-- S2/P-D (item 12): the watch/record/drift/withdraw/floor machinery -- `attach`, the
-- `YanaRewindWatch` augroup, the `reconcile` stub, `peek`, `drift`, `note_open`,
-- `mark_withdrawn`, `floor_gate_pending` -- is GUTTED.

local M = {}

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
