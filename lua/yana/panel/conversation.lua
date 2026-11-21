-- Sole owner of resumable backend mini-conversations and the last successfully
-- sent mode and file per mini. p.session_id is an owner-written read projection only.
local config = require("yana.config")
local context = require("yana.input.context")
local steer_channel = require("yana.agent.steer_channel")

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

-- The agent behind this mini has heard nothing: not ours, or nothing to resume.
local function is_fresh(self, mini)
  return not self:owns(mini) or mini.id == nil or mini.id == ""
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
  if is_fresh(self, mini) or mini.last_mode == nil then
    return true
  end
  return mini.last_mode ~= mode
end

--- True when this prompt must name `path`: the last file this mini heard differs.
function Conversation:needs_file_notice(mini, path)
  return is_fresh(self, mini) or mini.last_file ~= path
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

--- Record the file a sent prompt named; nil keeps the last one.
function Conversation:mark_file(mini, path)
  if path and self:owns(mini) then
    mini.last_file = path
  end
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
    local descriptor = config.backend_descriptor(backend) or {}
    if descriptor.seats and descriptor.seats.protected then
      p.session_id = nil
      return self
    end
    local key = mini_key(backend, seat_of(mode, backend))
    local mini = { key = key, id = p.session_id, last_mode = nil }
    self.minis[key] = mini
    self.active = mini
  end
  return self
end

M.get = M.attach
M.seat_of = Conversation.seat_of

local function running_descriptor(p)
  local backend = p and p.turn_backends and p.turn_backends[p.job_spawn_gen or p.turn_gen]
  return config.backend_descriptor(backend)
end

function M.can_steer(p)
  return steer_channel.can_steer(running_descriptor(p))
end

local function with_file_notice(p, text, send)
  if type(text) ~= "string" or text == "" then
    return nil, "empty_input"
  end
  local owner, origin = M.get(p), context.current_origin()
  local mini = owner.active
  local hint = owner:needs_file_notice(mini, origin.name) and context.file_hint(origin)
  local id, reason = send(p, hint and (hint .. "\n\n" .. text) or text)
  if id then
    owner:mark_file(mini, origin.name)
  end
  return id, reason
end

--- Send an input immediately and return its receipt ID.
function M.deliver(p, text)
  if not M.can_steer(p) then
    return nil, "unsupported"
  end
  if not p then
    return nil, "no_channel"
  end
  return with_file_notice(p, text, steer_channel.deliver)
end

--- With nil text, Claude interrupts with the last still-pending steered input.
--- For a backend without a live channel, restart receives (text, session_id, job).
function M.interrupt(p, text, restart)
  local owner = M.get(p)
  local mini = owner and owner.active
  return steer_channel.interrupt(p, text, running_descriptor(p), mini and mini.id, restart)
end

function M.last_input(p)
  return steer_channel.last_input(p)
end

return M
