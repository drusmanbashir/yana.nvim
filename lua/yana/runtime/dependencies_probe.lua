-- Host capabilities used by the MCP launcher and dependency preflight.
local M = {}

local function row(id, level, message, remedy, resolved)
  return { id = id, level = level, message = message, remedy = remedy, resolved = resolved }
end

-- Missing executables use these package names in installation advice.
local EXEC_PACKAGE = {
  python3 = { apt = "python3", dnf = "python3", pacman = "python" },
  rg = { apt = "ripgrep", dnf = "ripgrep", pacman = "ripgrep" },
  ["systemd-run"] = { apt = "systemd", dnf = "systemd", pacman = "systemd" },
  awk = { apt = "mawk", dnf = "gawk", pacman = "gawk" },
}

for _, name in ipairs({ "realpath", "sha256sum", "stat", "id", "mkdir", "rmdir", "readlink", "dirname" }) do
  EXEC_PACKAGE[name] = { apt = "coreutils", dnf = "coreutils", pacman = "coreutils" }
end

local function package_name(name, pkg_manager)
  local entry = EXEC_PACKAGE[name]
  if entry and pkg_manager and entry[pkg_manager] then
    return entry[pkg_manager]
  end
  return name
end

local function package_hint(name)
  local entry = EXEC_PACKAGE[name]
  if not entry then
    return "the '" .. name .. "' package"
  end
  if entry.apt == entry.dnf and entry.dnf == entry.pacman then
    return "the '" .. entry.apt .. "' package"
  end
  return "the package providing "
    .. name
    .. " -- '"
    .. entry.apt
    .. "' on Debian/Ubuntu, '"
    .. entry.dnf
    .. "' on Fedora, '"
    .. entry.pacman
    .. "' on Arch"
end

-- Detects the host's package manager: /etc/os-release's ID/ID_LIKE first,
-- confirmed against which package-manager binary is actually on PATH, then
-- falling back to whichever of those binaries resolves at all when
-- os-release is missing, unreadable, or names a manager not on PATH.
-- Returns "apt", "dnf", "pacman", or "unknown".
local function detect_pkg_manager()
  local id, id_like = "", ""
  if vim.fn.filereadable("/etc/os-release") == 1 then
    for _, line in ipairs(vim.fn.readfile("/etc/os-release")) do
      local key, value = line:match("^([%w_]+)=(.*)$")
      if key then
        value = value:gsub('^"(.*)"$', "%1")
        if key == "ID" then
          id = value
        elseif key == "ID_LIKE" then
          id_like = value
        end
      end
    end
  end
  local hay = " " .. id .. " " .. id_like .. " "
  local guess
  if hay:find(" debian ", 1, true) or hay:find(" ubuntu ", 1, true) then
    guess = "apt"
  elseif hay:find(" fedora ", 1, true) or hay:find(" rhel ", 1, true) then
    guess = "dnf"
  elseif hay:find(" arch ", 1, true) then
    guess = "pacman"
  end
  local function has(exe)
    return vim.fn.executable(exe) == 1
  end
  if guess == "apt" and has("apt-get") then
    return "apt"
  elseif guess == "dnf" and has("dnf") then
    return "dnf"
  elseif guess == "pacman" and has("pacman") then
    return "pacman"
  end
  if has("apt-get") then
    return "apt"
  elseif has("dnf") then
    return "dnf"
  elseif has("pacman") then
    return "pacman"
  end
  return "unknown"
end

-- The exact copy-paste install command for THIS machine.
local function install_command(name)
  local pkg_manager = detect_pkg_manager()
  local pkg = package_name(name, pkg_manager)
  if pkg_manager == "apt" then
    return "sudo apt-get install -y " .. pkg
  elseif pkg_manager == "dnf" then
    return "sudo dnf install -y " .. pkg
  elseif pkg_manager == "pacman" then
    return "sudo pacman -S --needed " .. pkg
  end
  return "install the package providing '" .. name .. "' with your distro's package manager"
end

local function executable_row(name, required)
  local resolved = vim.fn.exepath(name)
  if resolved ~= "" then
    return row("exec:" .. name, "ok", name .. " found: " .. resolved, nil, resolved)
  end
  local level = required and "error" or "warn"
  local remedy
  if required then
    remedy = "install " .. package_hint(name) .. " and restart Neovim: " .. install_command(name)
  else
    remedy = "install " .. package_hint(name) .. " to enable this optional feature: " .. install_command(name)
  end
  return row("exec:" .. name, level, name .. " not found on PATH", remedy)
end

-- Runs `cmd` and returns (true, systemobj_result) on completion, or (false,
-- nil, detail) when the probe itself could not be carried out at all --
-- spawn failure, a wait() error, or a forced kill on timeout. That third
-- case is deliberately never folded into "the feature is absent": a probe
-- that could not run has proved nothing, so callers must render it as
-- FAILED-to-probe rather than defaulting either direction.
local function probe(cmd, timeout_ms)
  -- Resolved executable safety: a dependency or
  -- health query is never permission to raise a desktop window. Copy the
  -- current environment for this child only, remove both display sockets,
  -- and force Electron launchers onto their Node entry point. clear_env is
  -- required because an env table otherwise MERGES and cannot remove a key.
  local child_env = vim.fn.environ()
  child_env.DISPLAY = nil
  child_env.WAYLAND_DISPLAY = nil
  child_env.ELECTRON_RUN_AS_NODE = "1"
  local ok_call, obj = pcall(vim.system, cmd, {
    text = true,
    env = child_env,
    clear_env = true,
  })
  if not ok_call then
    return false, nil, "FAILED-to-probe: " .. tostring(obj)
  end
  local ok_wait, result = pcall(function()
    return obj:wait(timeout_ms)
  end)
  if not ok_wait then
    return false, nil, "FAILED-to-probe: " .. tostring(result)
  end
  -- A probe that produced no record proved nothing: FAILED-to-probe.
  if result == nil then
    return false, nil, "FAILED-to-probe: wait() returned no result"
  end
  if result.code == 124 and result.signal == 9 then
    return false, nil, "FAILED-to-probe: timed out after " .. timeout_ms .. "ms"
  end
  return true, result
end

local function gnu_stat_row()
  local ok_probe, result, detail = probe({ "stat", "-fc", "%T", "." }, 1000)
  if ok_probe and result.code == 0 and vim.trim(result.stdout or "") ~= "" then
    ok_probe, result, detail = probe({ "stat", "-c", "%u", "." }, 1000)
    if ok_probe and result.code == 0 and vim.trim(result.stdout or ""):match("^%d+$") then
      return row("stat:gnu", "ok", "stat reports filesystem type and directory owner")
    end
  end
  return row("stat:gnu", "error", "stat cannot report filesystem type or directory owner: "
    .. (detail or result.stderr or ""), "install GNU coreutils")
end

local function cgroup_context()
  local uv = vim.uv or vim.loop
  local uid = uv.getuid()
  local own = "/sys/fs/cgroup/user.slice/user-" .. uid .. ".slice/user@" .. uid .. ".service"
  local current = ""
  if vim.fn.filereadable("/proc/self/cgroup") == 1 then
    for _, line in ipairs(vim.fn.readfile("/proc/self/cgroup")) do
      if line:sub(1, 3) == "0::" then current = "/sys/fs/cgroup" .. line:sub(4); break end
    end
  end
  local user_scope = uv.fs_access(own, "W") and current ~= own and current:sub(1, #own + 1) ~= own .. "/"
  return user_scope, own, current
end

function M.cgroup_needs_user_scope()
  local needed = cgroup_context()
  return needed
end

local function kernel_rows(rows)
  local uname = (vim.uv or vim.loop).os_uname()
  local darwin = uname.sysname == "Darwin"
  -- Confined modes stay Linux-only (S-24). On Darwin, name the operator
  -- choice — explicit agentic, or Linux — never "mount procfs".
  local mac_confined_remedy = "ask and inline require Linux and Bubblewrap; on macOS select agentic explicitly"
  if uname.sysname == "Linux" then
    rows[#rows + 1] = row("kernel:linux", "ok", "Linux kernel: " .. tostring(uname.release))
  else
    rows[#rows + 1] = row(
      "kernel:linux",
      "error",
      "confined modes require Linux (found " .. tostring(uname.sysname) .. ")",
      darwin and mac_confined_remedy or "run Yana on Linux; it never falls back to direct writes"
    )
  end

  if vim.fn.filereadable("/proc/self/status") == 1 then
    rows[#rows + 1] = row("kernel:proc", "ok", "/proc is available")
  else
    rows[#rows + 1] = row(
      "kernel:proc",
      "error",
      "/proc is unavailable",
      darwin and mac_confined_remedy or "mount procfs before starting Neovim"
    )
  end

  if vim.fn.filereadable("/sys/fs/cgroup/cgroup.controllers") == 1 then
    rows[#rows + 1] = row("kernel:cgroup2", "ok", "cgroup v2 is available")
    local uv = vim.uv or vim.loop
    local uid = uv.getuid()
    local needs_scope, own, current = cgroup_context()
    if needs_scope then
      local runtime = vim.env.XDG_RUNTIME_DIR or ("/run/user/" .. uid)
      local dir, bus, private = uv.fs_stat(runtime), uv.fs_stat(runtime .. "/bus"), uv.fs_stat(runtime .. "/systemd/private")
      local manager_socket = (private and private.type == "socket") or (bus and bus.type == "socket")
      if vim.fn.executable("systemd-run") == 1 and dir and dir.uid == uid and manager_socket then
        rows[#rows + 1] = row("cgroup:delegation", "ok", "launcher will enter the delegated systemd user scope")
      else
        rows[#rows + 1] = row("cgroup:delegation", "error", "launcher is outside the delegated user cgroup and cannot reach its user manager",
          "install systemd-run and log in through a systemd user session; see docs/installation.md#troubleshooting")
      end
    elseif (uv.fs_access(own, "W") and (current == own or current:sub(1, #own + 1) == own .. "/"))
        or (current ~= "" and uv.fs_access(current, "W")) then
      rows[#rows + 1] = row("cgroup:delegation", "ok", "current user cgroup is delegated")
    else
      rows[#rows + 1] = row("cgroup:delegation", "error", "no writable delegated user cgroup is available",
        "log in through a systemd user session or delegate the container's cgroup v2 hierarchy")
    end
  else
    rows[#rows + 1] = row(
      "kernel:cgroup2",
      "warn",
      "cgroup v2 controllers are unavailable; automatic dead-turn reclaim may refuse",
      darwin and mac_confined_remedy
        or "enable a delegated cgroup v2 hierarchy for the user session"
    )
  end
end

M.row = row
M.probe = probe
M.executable_row = executable_row
M.gnu_stat_row = gnu_stat_row
M.kernel_rows = kernel_rows
-- Exposed for tests/release/install_remedy_smoke.lua: proves the exact
-- one-liner a distro actually gets, without needing to fake /etc/os-release
-- or PATH on the test host itself.
M.detect_pkg_manager = detect_pkg_manager
M.install_command = install_command

return M
