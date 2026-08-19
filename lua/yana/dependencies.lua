local config = require("yana.config")

local M = {}

M.minimum_neovim = "0.10.4"

local confined_executables = {
  "bash",
  "bwrap",
  "python3",
  "realpath",
  "sha256sum",
  "flock",
  "mount",
  "umount",
  "find",
  "stat",
  "awk",
  "sed",
  "grep",
  "sort",
  "cut",
  "tr",
  "date",
  "hostname",
  "getent",
  "id",
  "mkdir",
  "mktemp",
  "rmdir",
  "chmod",
  "cp",
  "mv",
  "rm",
  "cat",
  "touch",
  "readlink",
  "dirname",
  "basename",
}

function M.required_executables(mode)
  if mode == "agentic" then
    return {}
  end
  return vim.deepcopy(confined_executables)
end

local function row(id, level, message, remedy, resolved)
  return { id = id, level = level, message = message, remedy = remedy, resolved = resolved }
end

local function executable_row(name, required)
  local resolved = vim.fn.exepath(name)
  if resolved ~= "" then
    return row("exec:" .. name, "ok", name .. " found: " .. resolved, nil, resolved)
  end
  local level = required and "error" or "warn"
  return row(
    "exec:" .. name,
    level,
    name .. " not found on PATH",
    required and ("install " .. name .. " and restart Neovim") or ("install " .. name .. " to enable this optional feature")
  )
end

local function configured_agent_row()
  local command = config.options.cmd or "cursor-agent"
  local resolved = vim.fn.exepath(command)
  if resolved ~= "" then
    return row("exec:cursor-agent", "ok", "cursor-agent found: " .. resolved, nil, resolved)
  end
  return row(
    "exec:cursor-agent",
    "error",
    "cursor-agent not found for configured cmd '" .. tostring(command) .. "'",
    "install and sign in to cursor-agent, or set require('yana').setup({ cmd = '/absolute/path/to/cursor-agent' })"
  )
end

local function kernel_rows(rows)
  local uname = (vim.uv or vim.loop).os_uname()
  if uname.sysname == "Linux" then
    rows[#rows + 1] = row("kernel:linux", "ok", "Linux kernel: " .. tostring(uname.release))
  else
    rows[#rows + 1] = row(
      "kernel:linux",
      "error",
      "confined modes require Linux (found " .. tostring(uname.sysname) .. ")",
      "run Yana on Linux; it never falls back to direct writes"
    )
  end

  if vim.fn.filereadable("/proc/self/status") == 1 then
    rows[#rows + 1] = row("kernel:proc", "ok", "/proc is available")
  else
    rows[#rows + 1] = row("kernel:proc", "error", "/proc is unavailable", "mount procfs before starting Neovim")
  end

  local filesystems = ""
  if vim.fn.filereadable("/proc/filesystems") == 1 then
    filesystems = table.concat(vim.fn.readfile("/proc/filesystems"), "\n")
  end
  if filesystems:match("[%s]overlay[%s]*$") or filesystems:match("[%s]overlay\n") then
    rows[#rows + 1] = row("kernel:overlayfs", "ok", "overlayfs is available")
  else
    rows[#rows + 1] = row(
      "kernel:overlayfs",
      "error",
      "overlayfs is not listed by /proc/filesystems",
      "load or enable the Linux overlay filesystem"
    )
  end

  if vim.fn.filereadable("/sys/fs/cgroup/cgroup.controllers") == 1 then
    rows[#rows + 1] = row("kernel:cgroup2", "ok", "cgroup v2 is available")
  else
    rows[#rows + 1] = row(
      "kernel:cgroup2",
      "warn",
      "cgroup v2 controllers are unavailable; automatic dead-turn reclaim may refuse",
      "enable a delegated cgroup v2 hierarchy for the user session"
    )
  end
end

local function neovim_version()
  local version = vim.version()
  return string.format("%d.%d.%d", version.major, version.minor, version.patch)
end

function M.check(mode)
  mode = mode or config.options.mode
  local rows = {}

  if vim.fn.has("nvim-" .. M.minimum_neovim) == 1 then
    rows[#rows + 1] = row("nvim:min", "ok", "Neovim " .. neovim_version())
  else
    rows[#rows + 1] = row(
      "nvim:min",
      "error",
      "Neovim " .. M.minimum_neovim .. "+ is required",
      "upgrade Neovim before loading Yana"
    )
  end

  rows[#rows + 1] = configured_agent_row()

  if mode ~= "agentic" then
    kernel_rows(rows)
    for _, name in ipairs(M.required_executables(mode)) do
      rows[#rows + 1] = executable_row(name, true)
    end
  end

  rows[#rows + 1] = executable_row("sqlite3", false)
  if vim.fn.executable("md5sum") == 1 or vim.fn.executable("md5") == 1 then
    rows[#rows + 1] = row("exec:md5", "ok", "md5sum or md5 found for external-session discovery")
  else
    rows[#rows + 1] = row(
      "exec:md5",
      "warn",
      "md5sum/md5 not found; only sessions started from Neovim can be listed",
      "install md5sum or md5 to enable external-session discovery"
    )
  end

  return rows
end

function M.preflight(mode)
  for _, item in ipairs(M.check(mode)) do
    if item.level == "error" then
      return false, string.format("[%s] %s - %s", item.id, item.message, item.remedy)
    end
  end
  return true
end

return M
