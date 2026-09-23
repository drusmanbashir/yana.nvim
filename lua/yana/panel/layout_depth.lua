-- How many column rebuilds are in progress (rule F-PANEL-REBUILD). One owner per
-- loaded panel; the count is private, the caller balances enter/leave.
local M = {}

function M.new()
  local depth = 0
  local self = {}

  function self:enter()
    depth = depth + 1
  end

  function self:leave()
    depth = depth - 1
  end

  function self:building()
    return depth > 0
  end

  return self
end

return M
