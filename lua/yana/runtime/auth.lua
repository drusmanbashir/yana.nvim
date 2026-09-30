-- Vendor-owned authentication: status is read-only; interactive login is never
-- an edit turn and its terminal output never enters Yana's transcript or log.
local config = require("yana.config")
local dependencies = require("yana.runtime.dependencies")
local M = {}
local active
local login_generation = 0

function M.classify(entry, result)
  if not result or result.code == 124 or (result.signal or 0) ~= 0 then return "unknown" end
  if entry.auth_json_field then
    local ok, data = pcall(vim.json.decode, result.stdout or "")
    if ok and type(data) == "table" then
      if data[entry.auth_json_field] == true then return "signed_in" end
      if data[entry.auth_json_field] == false then return "signed_out" end
    end
    return "unknown"
  end
  local patterns = entry.auth_output_patterns
  if patterns then
    local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
    local yes = patterns.signed_in and output:find(patterns.signed_in) ~= nil
    local no = patterns.signed_out and output:find(patterns.signed_out) ~= nil
    if yes and not no then return "signed_in" end
    if no and not yes then return "signed_out" end
    return "unknown"
  end
  return result.code == 0 and "signed_in" or "unknown"
end

local function probe_args(name)
  local entry = config.backend_descriptor(name) or {}
  local resolved = config.resolve_cmd(name)
  local command = vim.fn.exepath(resolved.value)
  if command == "" or not entry.whoami_args
    or dependencies.desktop_cursor_refusal(resolved.value, name) then return nil, entry end
  local argv = { command }
  vim.list_extend(argv, entry.whoami_args)
  return argv, entry
end

function M.check(name)
  local argv, entry = probe_args(name)
  if not argv then return "unknown" end
  local ok, result = dependencies.probe(argv, 2000)
  return ok and M.classify(entry, result) or "unknown"
end

function M.check_async(name, done)
  local argv, entry = probe_args(name)
  if not argv then vim.schedule(function() done("unknown") end); return end
  local env = vim.fn.environ()
  env.DISPLAY, env.WAYLAND_DISPLAY = nil, nil
  env.ELECTRON_RUN_AS_NODE = "1"
  local ok = pcall(vim.system, argv, { text = true, timeout = 2000, env = env, clear_env = true }, function(result)
    local state = M.classify(entry, result)
    vim.schedule(function() done(state) end)
  end)
  if not ok then vim.schedule(function() done("unknown") end) end
end

function M.hint(name)
  local entry = config.backend_descriptor(name) or {}
  return entry.login_args and ":YanaLogin" or entry.auth_login_hint or "use the agent's own login command"
end

local function environment_auth(entry)
  for _, key in ipairs(entry.auth_env or {}) do
    if vim.env[key] and vim.env[key] ~= "" then return true end
  end
  return false
end

function M.after_failure(stamp)
  if not stamp.is_current then return end
  -- Environment credentials need no browser login. Values are never copied to
  -- a message or retained; the vendor continues to own credential selection.
  local entry = config.backend_descriptor(stamp.backend) or {}
  if environment_auth(entry) then return end
  local generation = login_generation
  M.check_async(stamp.backend, function(state)
    local selected = config.resolve_cmd()
    if state == "signed_out" and not environment_auth(entry)
      and generation == login_generation and stamp.is_current()
      and selected.backend == stamp.backend and selected.value == stamp.command then
      vim.notify("yana: " .. stamp.backend .. " is not signed in — run " .. M.hint(stamp.backend)
        .. ", then submit your prompt again", vim.log.levels.WARN)
    end
  end)
end

function M.login()
  local resolution = config.resolve_cmd()
  local entry = config.backend_descriptor(resolution.backend) or {}
  local refusal = dependencies.desktop_cursor_refusal(resolution.value, resolution.backend)
  local command = vim.fn.exepath(resolution.value)
  if refusal or command == "" or not entry.login_args then
    vim.notify(refusal or (command == "" and "yana: install the selected agent CLI first"
      or "yana: this backend has no declared interactive login command"), vim.log.levels.ERROR)
    return nil
  end
  login_generation = login_generation + 1
  if active and active.backend == resolution.backend and active.command == command
    and vim.api.nvim_buf_is_valid(active.buf) and vim.fn.jobwait({ active.job }, 0)[1] == -1 then
    if vim.api.nvim_win_is_valid(active.win) then vim.api.nvim_set_current_win(active.win)
    else vim.cmd("botright 12split"); vim.api.nvim_win_set_buf(0, active.buf); active.win = vim.api.nvim_get_current_win() end
    vim.cmd("startinsert")
    return active.job, active.buf
  end
  vim.cmd("botright 12new")
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].undofile = "wipe", false, false
  local argv = { command }
  vim.list_extend(argv, entry.login_args)
  local session = { buf = buf, win = win, backend = resolution.backend, command = command }
  local ok, job = pcall(vim.fn.jobstart, argv, { term = true, on_exit = function(_, code)
    vim.schedule(function()
      if active == session then active = nil end
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.notify(code == 0 and "yana: login command completed — submit your prompt again"
        or "yana: login did not complete — run :YanaLogin to retry", code == 0 and vim.log.levels.INFO or vim.log.levels.WARN)
    end)
  end })
  if not ok or job <= 0 then
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.notify("yana: could not start the selected agent login terminal", vim.log.levels.ERROR)
    return nil
  end
  session.job, active = job, session
  vim.keymap.set("n", "q", function() vim.api.nvim_buf_delete(buf, { force = true }) end,
    { buffer = buf, silent = true, desc = "Close or cancel agent sign-in" })
  vim.cmd("startinsert")
  return job, buf
end

return M
