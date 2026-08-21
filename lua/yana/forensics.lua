local M = {}

local uv = vim.uv or vim.loop
local log = require("yana.log")

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function write_file(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "wb")
  if not f then
    return false
  end
  f:write(data or "")
  f:close()
  return true
end

local function append(out, line)
  out[#out + 1] = line
end

local function proc_children(pid)
  local out = {}
  for _, path in ipairs(vim.fn.glob("/proc/" .. tostring(pid) .. "/task/*/children", false, true) or {}) do
    for child in (read_file(path) or ""):gmatch("%d+") do
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
  table.sort(out)
  return out
end

local function shell_capture(argv)
  local ok, out = pcall(vim.fn.system, argv)
  return ok and out or ""
end

local function md5(s)
  local out = shell_capture({ "python3", "-c", "import hashlib,sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest())", s or "" })
  return out:match("^(%x+)") or vim.fn.sha256(s):sub(1, 32)
end

local function copy_tree(src, dst)
  if type(src) ~= "string" or src == "" or vim.fn.isdirectory(src) ~= 1 then
    vim.fn.mkdir(dst, "p")
    return false
  end
  vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
  local ok = pcall(vim.fn.system, { "cp", "-a", src, dst })
  return ok and vim.v.shell_error == 0
end

local function vendor_candidates(cwd)
  local out, seen = {}, {}
  local home = vim.env.HOME
  if not home or home == "" then
    return out
  end
  local chats = home .. "/.cursor/chats"
  local function add(path)
    if path and path ~= "" and not seen[path] then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  if cwd and cwd ~= "" then
    add(chats .. "/" .. md5(cwd))
  end
  return out
end

local function count_pattern(text, pat)
  local n = 0
  for _ in tostring(text or ""):gmatch(pat) do
    n = n + 1
  end
  return n
end

local function slurp_tree(dir, max_files)
  local parts = {}
  local n = 0
  if vim.fn.isdirectory(dir) ~= 1 then
    return ""
  end
  for _, path in ipairs(vim.fn.glob(dir .. "/**/*", false, true) or {}) do
    if n >= (max_files or 200) then
      break
    end
    if vim.fn.filereadable(path) == 1 then
      n = n + 1
      parts[#parts + 1] = read_file(path) or ""
    end
  end
  return table.concat(parts, "\n")
end

function M.classify(bundle)
  bundle = bundle or {}
  local dir = bundle.dir or bundle.path
  local text = bundle.text or ""
  if dir then
    text = text
      .. "\n" .. (read_file(dir .. "/stream.ndjson") or "")
      .. "\n" .. (read_file(dir .. "/proc-wchan.txt") or "")
      .. "\n" .. (read_file(dir .. "/sockets.txt") or "")
      .. "\n" .. slurp_tree(dir .. "/vendor-store")
  end
  local cpu = tonumber(bundle.cpu_pct or bundle.cpu_pct_at_stop) or 0
  local last_event = tostring(bundle.last_event_label or bundle.last_event or "")
  local erofs = count_pattern(text, "Read%-only file system") + count_pattern(text, "EROFS")
  local evidence = {}

  if erofs > 0 then
    evidence[#evidence + 1] = string.format('vendor store: %d x "Read-only file system"/EROFS', erofs)
    return { code = "S1", cause = "refusal-spin", erofs_count = erofs, evidence = evidence }
  end
  if cpu > 0.1 and text:find("sub%-agent", 1, false) then
    evidence[#evidence + 1] = string.format("CPU moving: %.2f%%", cpu)
    evidence[#evidence + 1] = "vendor sub-agent evidence present"
    return { code = "S2", cause = "silent-work", erofs_count = 0, evidence = evidence }
  end
  if cpu <= 0.1 and text:lower():find("approval", 1, true) then
    evidence[#evidence + 1] = "pending approval/permission evidence present"
    evidence[#evidence + 1] = "last event: " .. last_event
    return { code = "S3", cause = "approval-wait", erofs_count = 0, evidence = evidence }
  end
  if text:find("pipe_write", 1, true) then
    evidence[#evidence + 1] = "/proc wchan contains pipe_write"
    return { code = "S4", cause = "pipe-backpressure", erofs_count = 0, evidence = evidence }
  end
  if cpu <= 0.1 and (text:find("ESTABLISHED", 1, true) or text:find("SYN_SENT", 1, true)) then
    evidence[#evidence + 1] = "open network socket present"
    return { code = "S5", cause = "network-wait", erofs_count = 0, evidence = evidence }
  end
  if cpu > 0.1 then
    evidence[#evidence + 1] = string.format("CPU moving: %.2f%%", cpu)
    return { code = "S7", cause = "long-legit", erofs_count = erofs, evidence = evidence }
  end
  evidence[#evidence + 1] = "missing refusal, sub-agent, approval, pipe, socket, and CPU evidence"
  return { code = "S6", cause = "vendor-hang", erofs_count = erofs, evidence = evidence }
end

function M.snapshot(opts)
  opts = opts or {}
  local private = opts.private_dir
  if type(private) ~= "string" or private == "" then
    return nil, "missing private_dir"
  end
  local dir = private .. "/forensics"
  vim.fn.mkdir(dir, "p")
  local pids = proc_tree(opts.pid)
  write_file(dir .. "/ps-tree.txt", shell_capture({ "ps", "-o", "pid,ppid,stat,pcpu,comm,args", "-p", table.concat(pids, ",") }))
  local statuses, wchans, fds = {}, {}, {}
  for _, pid in ipairs(pids) do
    append(statuses, "### pid " .. pid)
    append(statuses, read_file("/proc/" .. pid .. "/status") or "missing")
    append(wchans, tostring(pid) .. "\t" .. tostring(read_file("/proc/" .. pid .. "/wchan") or "missing"))
    append(fds, "### pid " .. pid)
    append(fds, shell_capture({ "sh", "-c", "ls -l /proc/" .. tostring(pid) .. "/fd 2>/dev/null || true" }))
  end
  write_file(dir .. "/proc-status.txt", table.concat(statuses, "\n"))
  write_file(dir .. "/proc-wchan.txt", table.concat(wchans, "\n"))
  write_file(dir .. "/fds.txt", table.concat(fds, "\n"))
  write_file(dir .. "/sockets.txt", shell_capture({ "ss", "-tanp" }))
  local vendor_dir = dir .. "/vendor-store"
  vim.fn.mkdir(vendor_dir, "p")
  for i, cand in ipairs(vendor_candidates(opts.cwd)) do
    if vim.fn.isdirectory(cand) == 1 then
      copy_tree(cand, vendor_dir .. "/store-" .. tostring(i))
    end
  end
  local last = opts.last_event
  local label = type(last) == "table" and (last.label or last.description or last.type) or tostring(last or "")
  local verdict = M.classify({
    dir = dir,
    cpu_pct = opts.cpu_pct_at_stop,
    last_event_label = label,
  })
  local lines = {
    "cause=" .. verdict.code .. " " .. verdict.cause,
    "turn_id=" .. tostring(opts.turn_id or ""),
    "duration_ms=" .. tostring(opts.duration_ms or ""),
    "last_event=" .. tostring(label or ""),
    "cpu_pct_at_stop=" .. string.format("%.3f", tonumber(opts.cpu_pct_at_stop) or 0),
    "erofs_count=" .. tostring(verdict.erofs_count or 0),
  }
  for _, line in ipairs(verdict.evidence or {}) do
    lines[#lines + 1] = line
  end
  write_file(dir .. "/summary.txt", table.concat(lines, "\n") .. "\n")
  log.write("WARN", string.format(
    "yana: turn %s stalled (cause=%s) -- forensics at %s",
    tostring(opts.turn_id or "?"),
    verdict.code,
    dir
  ))
  return dir, verdict
end

return M
