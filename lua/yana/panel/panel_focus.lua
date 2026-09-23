-- The panel's tracked focus (rule F-PANEL-FOCUS): the recently used conversation,
-- the one holding the stop target, and the one the sidebar shows. One owner per
-- loaded panel; the three references are private.
local M = {}

function M.new()
  local last, focused, primary = nil, nil, nil
  local self = {}

  function self:last()
    return last
  end

  function self:set_last(p)
    last = p
  end

  function self:focused()
    return focused
  end

  function self:set_focused(p)
    focused = p
  end

  function self:primary()
    return primary
  end

  function self:set_primary(p)
    primary = p
  end

  function self:forget(p)
    if last == p then
      last = nil
    end
    if focused == p then
      focused = nil
    end
    if primary == p then
      primary = nil
    end
  end

  -- `alive` answers liveness for one conversation.
  function self:prune(alive)
    if last and not alive(last) then
      last = nil
    end
    if focused and not alive(focused) then
      focused = nil
    end
    if primary and not alive(primary) then
      primary = nil
    end
  end

  return self
end

return M
