-- Live stdin belongs to the job that opened it. A write is distinct from
-- Claude replaying the prompt and from Claude producing its result.
local agent = require("yana.agent.agent")
local M = {}
local panels = {}

local function uuid()
  local bytes = { assert(vim.uv.random(16)):byte(1, 16) }
  bytes[7] = 64 + bytes[7] % 16
  bytes[9] = 128 + bytes[9] % 64
  return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
    unpack(bytes))
end

local function user_frame(id, text)
  return {
    type = "user",
    uuid = id,
    message = { role = "user", content = { { type = "text", text = text } } },
  }
end

local function nonempty(text)
  return type(text) == "string" and text ~= ""
end

local function live(p)
  local channel = p and p.steer_delivery
  if channel and channel.job == p.job and not channel.closed and not channel.exited then
    return channel
  end
end

local function write(channel, text, steered)
  local id = uuid()
  if not agent.send_frame(channel.job, user_frame(id, text)) then
    return nil, "write_failed"
  end
  channel.last = { id = id, steered = steered, acknowledged = false, result_ready = false }
  channel.last_text = steered and text or nil
  return id
end

function M.can_steer(bd)
  return type(bd) == "table" and bd.steer_channel == "stream-json"
end

function M.open(p, job, prompt)
  if not p or not job then
    return nil, "no_channel"
  end
  local channel = { job = job }
  p.steer_delivery = channel
  panels[job] = p
  return write(channel, prompt or "", false)
end

function M.deliver(p, text)
  local channel = live(p)
  if not channel then
    return nil, "no_channel"
  end
  if not nonempty(text) then
    return nil, "empty_input"
  end
  return write(channel, text, true)
end

local function interrupt(channel, text)
  if channel.interrupt then
    return nil, "interrupt_in_progress"
  end
  local last = channel.last
  local pending = text == nil and last and last.steered and not last.acknowledged
  if pending then
    text = channel.last_text
  end
  if not nonempty(text) then
    return nil, "no_pending_input"
  end
  local id = uuid()
  if not agent.send_frame(channel.job, {
    type = "control_request", request_id = id, request = { subtype = "interrupt" },
  }) then
    return nil, "write_failed"
  end
  channel.interrupt = { id = id, last = last, pending_id = pending and last.id or nil, text = text }
  if last then
    last.result_ready = false
    last.failure = nil
  end
  return id
end

function M.interrupt(p, text, bd, session_id, restart)
  if M.can_steer(bd) then
    local channel = live(p)
    if not channel then
      return nil, "no_channel"
    end
    return interrupt(channel, text)
  end
  if not p or not p.job then
    return nil, "no_job"
  end
  if not nonempty(text) then
    return nil, "no_pending_input"
  end
  if not nonempty(session_id) then
    return nil, "no_session"
  end
  local accepted, reason = restart(text, session_id, p.job)
  if not accepted then
    return nil, reason or "restart_refused"
  end
  return true
end

function M.last_input(p)
  local channel = p and p.steer_delivery
  local last = channel and channel.last
  if last and (not p.job or p.job == channel.job) then
    local receipt = vim.tbl_extend("force", {}, last)
    receipt.interrupting = channel.interrupt ~= nil
    return receipt
  end
end

local function on_interrupt(channel, response)
  local request = channel.interrupt
  if not request or response.request_id ~= request.id then
    return
  end
  channel.interrupt = nil
  if channel.last ~= request.last then
    return -- A newer prompt has already been written.
  end
  if response.subtype ~= "success" then
    if channel.last then
      channel.last.failure = "interrupt_failed"
    end
    return
  end
  local response_body = response.response
  local queued = type(response_body) == "table" and response_body.still_queued
  if request.pending_id and request.last.acknowledged then
    return -- Claude replayed this input while the interrupt was in flight.
  end
  if request.pending_id and type(queued) == "table" and vim.tbl_contains(queued, request.pending_id) then
    return -- Claude retained this operator input across the interrupt.
  end
  local id, reason = write(channel, request.text, true)
  if not id and channel.last then
    channel.last.failure = reason
  end
end

function M.observe(job, event)
  local channel = live(panels[job])
  if not channel or channel.job ~= job then
    return
  end
  if event.type == "control_response" and type(event.response) == "table" then
    on_interrupt(channel, event.response)
    return
  end
  local last = channel.last
  if not last then
    return
  end
  if event.type == "user" and event.isReplay == true and event.uuid == last.id then
    last.acknowledged = true
    channel.last_text = nil
  elseif event.type == "result" and not channel.interrupt then
    -- A one-shot reader may return a result for its sole input without a replay.
    last.result_ready = last.acknowledged or not last.steered
  end
end

function M.exited(job)
  local p = panels[job]
  panels[job] = nil
  local channel = p and p.steer_delivery
  if channel and channel.job == job then
    channel.exited = true
    channel.interrupt = nil
    if channel.last and not channel.last.result_ready then
      channel.last.failure = channel.last.failure or "process_exited"
    end
    channel.last_text = nil
  end
end

-- An older result cannot close the pipe while a later input is unacknowledged.
function M.close(p)
  local channel = live(p)
  if not channel or channel.interrupt then
    return false
  end
  local last = channel.last
  if not last or not last.result_ready then
    return false
  end
  local ok, result = agent.close_stdin(channel.job)
  channel.closed = ok and (result == nil or result == 1)
  return channel.closed
end

return M
