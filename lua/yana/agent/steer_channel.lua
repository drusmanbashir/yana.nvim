-- Transport for §11 tool-call-boundary steering; UI modules keep MCP/stdio details here.
local agent = require("yana.agent.agent")

local M = {}

local function user_frame(text)
  return {
    type = "user",
    message = {
      role = "user",
      content = {
        { type = "text", text = text },
      },
    },
  }
end

-- The backend advertises stdin steering.
function M.can_steer(bd)
  return type(bd) == "table" and bd.steer_channel == "stream-json"
end

-- The first operator prompt is a stdin frame.
function M.open(p, job, prompt)
  if not p then
    return false
  end
  p.steer_job = job
  p.steer_request_seq = p.steer_request_seq or 0
  return agent.send_frame(job, user_frame(prompt or ""))
end

-- Interrupt, then send only operator text.
function M.deliver(p, text, opts)
  local job = p and (p.job or p.steer_job)
  if not p or not job or type(text) ~= "string" or text == "" then
    return false
  end
  opts = opts or {}
  if opts.interrupt then
    p.steer_request_seq = (p.steer_request_seq or 0) + 1
    p.self_interrupted = true
    agent.send_frame(job, {
      type = "control_request",
      request_id = "yana-" .. tostring(p.turn_gen or 0) .. "-" .. tostring(p.steer_request_seq),
      request = { subtype = "interrupt" },
    })
    p.steer_pending = nil
    vim.schedule(function()
      agent.send_frame(p.job or p.steer_job, user_frame(text))
    end)
    return true
  end
  p.steer_pending = nil
  return agent.send_frame(job, user_frame(text))
end

-- An idle result closes stdin so a one-shot turn exits.
function M.close(p)
  if not p then
    return false
  end
  return agent.close_stdin(p.job)
end

return M
