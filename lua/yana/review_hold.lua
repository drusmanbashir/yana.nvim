-- YANA'S OWN TRANSACTIONS, and the two guards that say one is open.
--
-- This is scheduling, not lifecycle: `suppress_count` and `held_count` answer
-- "is Yana itself moving this buffer right now", which is a different question
-- from where a review sits, and folding the two would make an in-flight
-- transaction look like a review state. Both guards come down through
-- `vim.schedule`, so a reconcile that lands inside the window is DEFERRED (see
-- `review_history`'s `reconcile_when_quiet`), never dropped.
--
-- The suppression and hold seams are re-exported on the frozen `inline_diff`
-- facade and called by review undo paths. Scheduling stays private to the
-- review queue; ownership cleanup stays on the lifecycle facade.
local log = require("yana.log")

local M = {}

function M.new(deps)
  local suppress_count = 0
  local held_count = 0
  local current_hold = nil

  local H = {}

  local function note_positions()
    if type(deps.note_positions) == "function" then
      deps.note_positions()
    end
  end

  -- True while one of Yana's own transactions is open. The ACTING half of the
  -- watcher (drift, the gate) is withheld until this is false; the bookmark half
  -- is not, because a suppressed move is exactly where the buffer then sits.
  function H.suppress(fn)
    suppress_count = suppress_count + 1
    local ok, err = pcall(fn)
    pcall(note_positions)
    vim.schedule(function()
      suppress_count = math.max(0, suppress_count - 1)
    end)
    if not ok then
      error(err, 0)
    end
    return true
  end

  function H.hold()
    local hold = { refs = 1, released = false, settled = false }
    held_count = held_count + 1
    local function settle()
      if hold.settled or hold.refs > 0 then
        return
      end
      hold.settled = true
      vim.schedule(function()
        held_count = math.max(0, held_count - 1)
      end)
    end
    function hold.schedule(fn)
      if hold.settled then
        vim.schedule(fn)
        return
      end
      hold.refs = hold.refs + 1
      vim.schedule(function()
        local previous = current_hold
        current_hold = hold
        local ok, err = pcall(fn)
        current_hold = previous
        hold.refs = hold.refs - 1
        settle()
        if not ok then
          pcall(function()
            log.write("WARN", "yana.inline_diff rewind hold: " .. tostring(err))
          end)
        end
      end)
    end
    function hold.release()
      if hold.released then
        return
      end
      hold.released = true
      hold.refs = hold.refs - 1
      settle()
    end
    return hold
  end

  function H.hold_current()
    return current_hold
  end

  function H.schedule(fn)
    if current_hold then
      current_hold.schedule(fn)
    else
      vim.schedule(fn)
    end
  end

  function H.own_transaction(fn)
    local hold = H.hold()
    local previous = current_hold
    current_hold = hold
    local ok, result = pcall(fn)
    current_hold = previous
    pcall(note_positions)
    hold.release()
    if not ok then
      error(result, 0)
    end
    return result
  end

  return H
end

return M
