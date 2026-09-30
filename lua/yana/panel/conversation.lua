-- Sole owner of resumable backend mini-conversations and last successfully
-- sent mode per mini. p.session_id is an owner-written read projection only.
local config = require("yana.config")

local Conversation = {}
Conversation.__index = Conversation

local function seat_of(mode, backend_name)
  local bd = config.backend_descriptor(backend_name or config.options.backend) or {}
  mode = config.panel_mode(mode)
  if bd.mode_switch == "two_seat" and type(bd.seats) == "table" then
    for seat_name, modes in pairs(bd.seats) do
      if type(modes) == "table" then
        for _, m in ipairs(modes) do
          if m == mode then
            return seat_name
          end
        end
      end
    end
  end
  return "main"
end

local function mini_key(backend, seat)
  return tostring(backend or "cursor") .. "\0" .. tostring(seat or "main")
end

--- Class/static seat query (backend descriptor seats).
function Conversation.seat_of(mode, backend_name)
  return seat_of(mode, backend_name)
end

local function project(self, mini)
  local p = self.panel
  p.session_id = (mini and mini.id and mini.id ~= "") and mini.id or nil
end

function Conversation:owns(mini)
  return mini ~= nil and mini.key ~= nil and self.minis[mini.key] == mini
end

--- Select (creating if needed) the mini for mode/backend; becomes active.
function Conversation:activate(mode, backend_name)
  local p = self.panel
  mode = config.panel_mode(mode or p.mode)
  backend_name = backend_name or config.options.backend or "cursor"
  local key = mini_key(backend_name, seat_of(mode, backend_name))
  local mini = self.minis[key]
  if not mini then
    mini = { key = key, id = nil, last_mode = nil }
    self.minis[key] = mini
  end
  self.active = mini
  project(self, mini)
  return mini
end

--- True when this launch must carry the mode sentence.
function Conversation:needs_mode_notice(mini, mode)
  mode = config.panel_mode(mode)
  if not self:owns(mini) then
    return true
  end
  if mini.id == nil or mini.id == "" then
    return true
  end
  if mini.last_mode == nil then
    return true
  end
  return mini.last_mode ~= mode
end

--- First upstream ID wins for a still-owned mini. Projects p.session_id only
--- when that mini is the active seat (never switches active).
function Conversation:bind_upstream(mini, session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return false
  end
  if not self:owns(mini) then
    return false
  end
  if mini.id == nil or mini.id == "" then
    mini.id = session_id
  end
  if self.active == mini then
    project(self, mini)
  end
  return true
end

--- Record a successful send for this mini.
function Conversation:mark_sent(mini, mode)
  if not self:owns(mini) then
    return
  end
  mini.last_mode = config.panel_mode(mode)
end

--- Retire every mini and clear the session projection.
function Conversation:reset()
  self.minis = {}
  self.active = nil
  self.panel.session_id = nil
  self.panel.session_seats = nil
end

local M = {}

--- Attach (or return) the Conversation instance for panel `p`.
function M.attach(p)
  if not p then
    return nil
  end
  if p._conversation then
    return p._conversation
  end
  local self = setmetatable({
    panel = p,
    minis = {},
    active = nil,
  }, Conversation)
  p._conversation = self
  p.session_seats = nil
  -- Adopt a pre-existing upstream id with unknown last_mode (notice required).
  if type(p.session_id) == "string" and p.session_id ~= "" then
    local mode = config.panel_mode(p.mode)
    local backend = config.options.backend or "cursor"
    local key = mini_key(backend, seat_of(mode, backend))
    local mini = { key = key, id = p.session_id, last_mode = nil }
    self.minis[key] = mini
    self.active = mini
  end
  return self
end

M.get = M.attach
M.seat_of = Conversation.seat_of

return M
