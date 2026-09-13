-- Per-turn CPU% sampling via /proc, split out of lua/yana/agent.lua.
-- `M.start`/`M.stop` are called from M.run() around process spawn/exit; `M.stderr_tail`
-- is called from M.run()'s stderr accumulation.
local log = require("yana.log")
local uv = vim.uv or vim.loop
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
  ffi.cdef("typedef long ssize_t; ssize_t pread(int fd, void *buf, unsigned long count, long offset);")
end

local M = {}

local job_status = {}
local sample_interval_ms = 2000
M.job_status = job_status

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function stderr_tail(lines, max_lines)
  max_lines = max_lines or 10
  local out = {}
  local first = math.max(1, #lines - max_lines + 1)
  for i = first, #lines do
    out[#out + 1] = lines[i]
  end
  return table.concat(out, "\n")
end

local function proc_children(pid)
  local out = {}
  local req = uv.fs_scandir("/proc/" .. tostring(pid) .. "/task")
  if not req then
    return out
  end
  while true do
    local tid = uv.fs_scandir_next(req)
    if not tid then
      break
    end
    local data = read_file("/proc/" .. tostring(pid) .. "/task/" .. tid .. "/children") or ""
    for child in data:gmatch("%d+") do
      out[#out + 1] = tonumber(child)
    end
  end
  return out
end

local function proc_tree(root)
  local seen, out, queue = {}, {}, { tonumber(root) }
  while #queue > 0 do
    local pid = table.remove(queue, 1)
    if pid and not seen[pid] and uv.fs_stat("/proc/" .. tostring(pid)) then
      seen[pid] = true
      out[#out + 1] = pid
      for _, child in ipairs(proc_children(pid)) do
        queue[#queue + 1] = child
      end
    end
  end
  return out
end

local clk_tck = nil
local function clock_ticks_per_second()
  if clk_tck then
    return clk_tck
  end
  local ok, out = pcall(vim.fn.system, { "getconf", "CLK_TCK" })
  clk_tck = tonumber(ok and out or nil) or 100
  return clk_tck
end

local function proc_ticks(pid)
  local path = "/proc/" .. tostring(pid) .. "/stat"
  local fd = uv.fs_open(path, "r", 0)
  local stat = nil
  if fd then
    stat = uv.fs_read(fd, 4096, 0)
    uv.fs_close(fd)
  end
  if not stat then
    return 0
  end
  local rest = stat:match("^%d+ %b() (.+)$")
  if not rest then
    return 0
  end
  local i, utime, stime = 0, nil, nil
  for v in rest:gmatch("%S+") do
    i = i + 1
    if i == 12 then
      utime = tonumber(v) or 0
    elseif i == 13 then
      stime = tonumber(v) or 0
      break
    end
  end
  return (utime or 0) + (stime or 0)
end

local function tree_ticks(pid)
  local total = 0
  for _, p in ipairs(proc_tree(pid)) do
    total = total + proc_ticks(p)
  end
  return total
end

local function ticks_for_pids(pids)
  local total = 0
  local live = {}
  for _, p in ipairs(pids or {}) do
    if uv.fs_stat("/proc/" .. tostring(p)) then
      live[#live + 1] = p
      total = total + proc_ticks(p)
    end
  end
  return total, live
end

local function ticks_for_status(status)
  local total = 0
  local live = {}
  status.stat_fds = status.stat_fds or {}
  for _, p in ipairs(status.pids or {}) do
    if uv.fs_stat("/proc/" .. tostring(p)) then
      live[#live + 1] = p
      local fd = status.stat_fds[p]
      if not fd then
        fd = uv.fs_open("/proc/" .. tostring(p) .. "/stat", "r", 0)
        status.stat_fds[p] = fd
      end
      local stat = nil
      if fd and ffi_ok then
        local n = ffi.C.pread(fd, status.stat_buf, 4095, 0)
        if n > 0 then
          stat = ffi.string(status.stat_buf, n)
        end
      elseif fd then
        stat = uv.fs_read(fd, 4096, 0)
      end
      if stat then
        local rest = stat:match("^%d+ %b() (.+)$")
        if rest then
          local i, utime, stime = 0, nil, nil
          for v in rest:gmatch("%S+") do
            i = i + 1
            if i == 12 then
              utime = tonumber(v) or 0
            elseif i == 13 then
              stime = tonumber(v) or 0
              break
            end
          end
          total = total + (utime or 0) + (stime or 0)
        end
      end
    elseif status.stat_fds[p] then
      pcall(uv.fs_close, status.stat_fds[p])
      status.stat_fds[p] = nil
    end
  end
  return total, live
end

local function start_cpu_sampler(job, pid)
  if not (job and job > 0 and pid and pid > 0) then
    return
  end
  local pids = proc_tree(pid)
  local fds = {}
  for _, p in ipairs(pids) do
    fds[p] = uv.fs_open("/proc/" .. tostring(p) .. "/stat", "r", 0)
  end
  local status = {
    job = job,
    pid = pid,
    cpu_pct = 0,
    last_activity_ms = nil,
    sample_count = 0,
    sample_cost_ms_total = 0,
    sample_cpu_ms_total = 0,
    last_event_hr = nil,
    last_sample_hr = uv.hrtime(),
    last_ticks = tree_ticks(pid),
    hz = clock_ticks_per_second(),
    pids = pids,
    stat_fds = fds,
    stat_buf = ffi_ok and ffi.new("char[4096]") or nil,
  }
  job_status[job] = status
  local timer = uv.new_timer()
  status.timer = timer
  timer:start(sample_interval_ms, sample_interval_ms, vim.schedule_wrap(function()
    log.guard("yana.agent cpu sampler", function()
      if not job_status[job] then
        return
      end
      local t0 = uv.hrtime()
      if status.sample_count > 0 and status.sample_count % 30 == 0 then
        status.pids = proc_tree(pid)
      end
      local now = uv.hrtime()
      local ticks, live_pids = ticks_for_status(status)
      status.pids = (#live_pids > 0) and live_pids or { pid }
      local dt_ms = (now - status.last_sample_hr) / 1e6
      local dt_ticks = ticks - status.last_ticks
      if dt_ms > 0 and dt_ticks >= 0 then
        status.cpu_pct = (dt_ticks / status.hz) / (dt_ms / 1000) * 100
      end
      status.last_sample_hr = now
      status.last_ticks = ticks
      status.sample_count = status.sample_count + 1
      status.sample_cpu_ms_total = status.sample_cpu_ms_total + ((uv.hrtime() - t0) / 1e6)
      status.sample_cost_ms_total = status.sample_cost_ms_total + ((uv.hrtime() - t0) / 1e6)
    end)
  end))
end

local function stop_cpu_sampler(job)
  local status = job_status[job]
  if status and status.timer then
    status.timer:stop()
    if not status.timer:is_closing() then
      status.timer:close()
    end
    status.timer = nil
  end
  for _, fd in pairs(status and status.stat_fds or {}) do
    pcall(uv.fs_close, fd)
  end
  if status then
    status.stat_fds = nil
  end
end

-- Return the job's cpu/pid/sample status snapshot, or nil if untracked.
function M.status(job)
  local status = job and job_status[job] or nil
  if not status then
    return nil
  end
  return {
    job = status.job,
    pid = status.pid,
    cpu_pct = status.cpu_pct or 0,
    sample_count = status.sample_count or 0,
    sample_cost_ms_total = status.sample_cost_ms_total or 0,
    sample_cpu_ms_total = status.sample_cpu_ms_total or 0,
    sample_cost_ms_avg = (status.sample_count or 0) > 0
      and ((status.sample_cost_ms_total or 0) / status.sample_count)
      or 0,
  }
end

function M.set_sample_interval_ms(ms)
  sample_interval_ms = (type(ms) == "number" and ms > 0) and ms or 2000
end

function M.force_status(job, status)
  job_status[job] = status
end

M.start = start_cpu_sampler
M.stop = stop_cpu_sampler
M.stderr_tail = stderr_tail

-- OS pid for a job, for signal escalation beyond jobstop()'s SIGTERM.
-- Returns the pid (number) or nil (job invalid / already gone).
function M.pid(job)
  local ok, pid = pcall(vim.fn.jobpid, job)
  if ok and type(pid) == "number" and pid > 0 then
    return pid
  end
  return nil
end

return M
