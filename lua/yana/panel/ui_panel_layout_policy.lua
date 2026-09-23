-- Layout policy: which existing panel views are visible. Does not create or
-- destroy windows; the window builder (ui_panel_layout) executes the decision.
-- Panel registry (lifecycle) owns chat identity; this module only answers
-- visibility and focus-order questions for `ui.multi_panel_layout`.
local config = require("yana.config")

local M = {}

local ACCEPTED = { split = true, rotate = true }

function M.accepted_values()
  return { "split", "rotate" }
end

function M.is_accepted(value)
  return type(value) == "string" and ACCEPTED[value] == true
end

--- Current layout mode; defaults to split when unset.
function M.mode()
  local ui = config.options and config.options.ui
  local value = ui and ui.multi_panel_layout
  if M.is_accepted(value) then
    return value
  end
  return "split"
end

function M.is_split()
  return M.mode() == "split"
end

function M.is_rotate()
  return M.mode() == "rotate"
end

--- Stable panel order for next/prev wrapping (registry order).
function M.ordered_panels(panels)
  local out = {}
  for _, p in ipairs(panels or {}) do
    out[#out + 1] = p
  end
  return out
end

--- Index of `p` in `ordered`, or nil.
function M.index_of(ordered, p)
  for i, q in ipairs(ordered) do
    if q == p then
      return i
    end
  end
  return nil
end

--- Next/previous panel in registry order, wrapping.
function M.step(ordered, p, delta)
  if not ordered or #ordered == 0 then
    return nil
  end
  local at = M.index_of(ordered, p) or 1
  return ordered[((at - 1 + delta) % #ordered) + 1]
end

--- In rotate mode only the focused panel should have windows in `tab`.
--- In split mode every panel that already has (or is opening) a view may.
function M.should_show(panel, focused, _tab)
  if M.is_split() then
    return true
  end
  return panel == focused
end

return M
