-- Turn liveness decoding: pure functions of a decoded stream event (`obj`).
local M = {}

-- One decoder, two consumers: the panel status line and the turn's durable
-- `meta.json` need the same fact, so it is derived once, here. Subagent output
-- is not forwarded into the parent stream, so the parent can only say what it
-- last saw and how long ago.

--- The single `<name>ToolCall` member of a tool_call envelope, or nil.
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
--- Returns { type, subtype, tool, call_id, description, nested, label,
--- timestamp_ms } or nil. nil means the event carries no operator-meaningful
--- progress (the echoed user prompt); the caller must KEEP its previous label.
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
      -- Nested subagent: its `description` is the only thing the parent sees.
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
