-- The panel subscribes its button strip to Turn and review-resource changes.
-- Model modules publish state; only this panel adapter knows the painter.
local turn_bind = require("yana.turn.turn_bind")
local resources = require("yana.review_resources")
local function buttons() return require("yana.panel.ui_review_buttons") end

local M = {}
local installed = false
local observed_turns = setmetatable({}, { __mode = "k" })

local function subscribe(turn, pool)
  if observed_turns[turn] then return end
  observed_turns[turn] = true
  turn:register({
    name = "buttons",
    turn_start = function() buttons().open(pool) end,
    review_alive = function() buttons().open(pool) end,
    review_finished = function() buttons().refresh() end,
    turn_sealed = function() buttons().remove() end,
    turn_end = function() buttons().remove(pool) end,
  })
  if turn.started and turn:is_live() and not turn:is_frozen() then
    buttons().open(pool)
  end
end

function M.install()
  if installed then return end
  installed = true
  turn_bind.on_turn_wired(subscribe)
  resources.on_change(function() buttons().refresh() end)
end

return M
