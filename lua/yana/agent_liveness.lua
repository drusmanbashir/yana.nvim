-- Turn liveness decoding, split out of lua/yana/agent.lua. Pure
-- functions of a decoded stream event (`obj`); no upvalue on any agent.lua
-- local. `M.describe_event` is called from M.run() as `M.describe_event(obj)`
-- (already through the module table, not a bare local), so that call site is
-- unchanged text once agent.lua's own `M.describe_event` is this module's.
local M = {}

----------------------------------------------------------------------
-- Turn liveness: what the agent last DID
----------------------------------------------------------------------
--
-- One decoder, two consumers. The panel's status line needs a short label for
-- the last stream event so "working" and "hung" stop looking the same, and the
-- turn's durable `meta.json` needs the same fact so a turn that never finished
-- still says where it stopped. Deriving it twice would let the two disagree
-- exactly when they matter, so it is derived once, here, in the module that
-- already owns stream-json decoding.
--
-- Subagent output is not forwarded into the parent stream, so the only honest thing the
-- parent can say is what it last saw and how long ago.

--- The single `<name>ToolCall` member of a tool_call envelope, if there is one.
--- Vendor envelopes carry exactly one; anything else is not a tool call this
--- can describe, and nil is the honest answer.
local function tool_member(obj)
  local tc = obj.tool_call
  if type(tc) ~= "table" then
    return nil, nil
  end
  for k, v in pairs(tc) do
    if type(k) == "string" and type(v) == "table" and k:match("ToolCall$") then
      return k, v
    end
  end
  return nil, nil
end

--- Describe one decoded stream event for the liveness surfaces.
---
--- Returns a table { type, subtype, tool, call_id, description, nested, label,
--- timestamp_ms } or nil. nil means "this event carries no operator-meaningful
--- progress" (the echoed user prompt is the only such case today) and the
--- caller must KEEP its previous label rather than blanking it: an event with
--- nothing to say is not the same as the agent having said nothing.
function M.describe_event(obj)
  if type(obj) ~= "table" then
    return nil
  end
  local t, st = obj.type, obj.subtype
  if t == "tool_call" then
    local name, call = tool_member(obj)
    if not name then
      return nil
    end
    local info = {
      type = t,
      subtype = st,
      tool = name,
      call_id = obj.call_id,
      timestamp_ms = obj.timestamp_ms,
    }
    if name == "taskToolCall" then
      -- A nested subagent. Its `description` is the only thing the parent
      -- stream ever says about what the subagent is doing, so it IS the label.
      local args = type(call.args) == "table" and call.args or {}
      info.nested = true
      info.description = type(args.description) == "string" and args.description or nil
      local what = info.description or "nested task"
      info.label = (st == "completed") and ("task done: " .. what) or ("task: " .. what)
    else
      local short = name:gsub("ToolCall$", "")
      info.label = (st == "completed") and (short .. " done") or short
    end
    return info
  elseif t == "thinking" then
    return { type = t, subtype = st, label = "thinking", timestamp_ms = obj.timestamp_ms }
  elseif t == "assistant" then
    local only_thinking = true
    local any = false
    for _, item in ipairs((obj.message or {}).content or {}) do
      any = true
      if item.type ~= "thinking" then
        only_thinking = false
      end
    end
    return {
      type = t,
      subtype = st,
      label = (any and only_thinking) and "thinking" or "answering",
      timestamp_ms = obj.timestamp_ms,
    }
  elseif t == "result" then
    return { type = t, subtype = st, label = "result", timestamp_ms = obj.timestamp_ms }
  elseif t == "error" then
    return { type = t, subtype = st, label = "error", timestamp_ms = obj.timestamp_ms }
  elseif t == "system" then
    return {
      type = t,
      subtype = st,
      label = (st == "init") and "session start" or ("system " .. tostring(st)),
      timestamp_ms = obj.timestamp_ms,
    }
  end
  return nil
end

return M
