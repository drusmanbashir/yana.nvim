-- F-VENDOR-FAILURES: one process's deadline and observed vendor failure;
-- health reads the latest completed outcome per backend in this editor only.
local M = {}
local latest, generations = {}, {}
local function message(ev)
  local value = ev.result or ev.message or ev.error
  if type(value) == "table" then value = value.message or vim.json.encode(value) end
  return type(value) == "string" and value ~= "" and value or "agent reported an error"
end
function M.new(backend, timeout_ms)
  generations[backend] = (generations[backend] or 0) + 1
  local generation = generations[backend]
  local state = {}
  function state.event(ev)
    if ev.type == "error" or (ev.type == "result" and ev.is_error) then state.error = message(ev) end
  end
  function state.start(job, stop)
    state.timer = vim.defer_fn(function()
      state.timer = nil
      state.timed_out = true
      stop(job, "vendor deadline exceeded", { deadline_ms = timeout_ms })
    end, timeout_ms)
  end
  function state.finish(code, stderr, got_result, cancelled)
    if state.timer then state.timer:stop();state.timer:close();state.timer = nil end
    local failure
    if not cancelled or state.timed_out then
      if state.timed_out then failure = "vendor deadline exceeded after " .. timeout_ms .. " ms" end
      if state.error then failure = (failure and failure .. "\n" or "") .. state.error end
      if code ~= 0 or not got_result or failure then
        local lines = vim.split(stderr or "", "\n", { plain = true, trimempty = true })
        local tail = table.concat(lines, "\n", math.max(1, #lines - 9))
        if tail ~= "" then failure = (failure and failure .. "\n" or "") .. tail end
        failure = failure or (got_result and "vendor process failed" or "vendor process exited without a result")
      end
    end
    if generation == generations[backend] then
      latest[backend] = failure and { message = failure, exit_code = code } or nil
    end
    return failure
  end
  return state
end
function M.last_failure(backend)
  return latest[backend] and vim.deepcopy(latest[backend]) or nil
end
return M
