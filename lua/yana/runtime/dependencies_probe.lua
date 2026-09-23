-- System/toolchain-level dependency probes, split out of lua/yana/runtime/dependencies.lua
--. This module holds the
-- checks that are self-contained -- no config.lua dependency: binary-presence rows, the
-- shared timeout-guarded subprocess probe, GNU coreutils vs BusyBox feature probes
-- (stat/find/date), the bwrap user-namespace probe, and kernel feature rows
-- (namespaces, overlayfs, cgroup v2). The agent-binary resolution rows
local M = {}

local function row(id, level, message, remedy, resolved)
  return { id = id, level = level, message = message, remedy = remedy, resolved = resolved }
end

-- Package name for each dependency on each of the three package managers
-- yana's remedies target. A missing distro key means the executable's own
-- name is also its package name there -- true for most of
-- dependencies.lua's confined_executables (sed, python3, id, mkdir, ...);
-- only the entries below differ. One table backs both the distro-agnostic
-- prose (package_hint) and the exact copy-paste command (install_command)
-- below, so the two can never drift apart from each other.
local EXEC_PACKAGE = {
  bwrap = { apt = "bubblewrap", dnf = "bubblewrap", pacman = "bubblewrap" },
  ["fuse-overlayfs"] = { apt = "fuse-overlayfs", dnf = "fuse-overlayfs", pacman = "fuse-overlayfs" },
  newuidmap = { apt = "uidmap", dnf = "shadow-utils", pacman = "shadow" },
  newgidmap = { apt = "uidmap", dnf = "shadow-utils", pacman = "shadow" },
  unshare = { apt = "util-linux", dnf = "util-linux", pacman = "util-linux" },
  capsh = { apt = "libcap2-bin", dnf = "libcap", pacman = "libcap" },
  flock = { apt = "util-linux", dnf = "util-linux", pacman = "util-linux" },
  mount = { apt = "util-linux", dnf = "util-linux", pacman = "util-linux" },
  umount = { apt = "util-linux", dnf = "util-linux", pacman = "util-linux" },
  find = { apt = "findutils", dnf = "findutils", pacman = "findutils" },
  awk = { apt = "gawk", dnf = "gawk", pacman = "gawk" },
  getent = { apt = "libc-bin", dnf = "glibc-common", pacman = "glibc" },
}

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

-- Detects the host's package manager the same way the retired
-- scripts/install-deps.sh used to: /etc/os-release's ID/ID_LIKE first,
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

-- The exact copy-paste install command for THIS machine -- the one-liner
-- users now get instead of the retired scripts/install-deps.sh.
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

--- Named open-capture dependency rows. FUSE is optional for `auto`: missing
--- tools are health warnings and never block the fast backend.
local function open_capture_rows(mode, include_optional)
  if mode == "off" then return {} end
  if mode == "auto" and include_optional == false then return {} end
  local required = mode == "fuse-compat"
  local level = required and "error" or "warn"
  local rows = {}
  local function exe(id, name)
    local resolved = vim.fn.exepath(name)
    if resolved ~= "" then return row(id, "ok", name .. " found: " .. resolved, nil, resolved) end
    return row(id, level, name .. " not found on PATH", "install " .. package_hint(name) .. ": " .. install_command(name))
  end
  rows[#rows + 1] = exe("open_capture_dep_fuse_overlayfs", "fuse-overlayfs")
  local stat = (vim.uv or vim.loop).fs_stat("/dev/fuse")
  rows[#rows + 1] = stat and stat.type == "char"
    and row("open_capture_dep_dev_fuse", "ok", "/dev/fuse is available")
    or row("open_capture_dep_dev_fuse", level, "/dev/fuse is unavailable", "load the FUSE device and allow it in the turn namespace")
  rows[#rows + 1] = exe("open_capture_dep_newuidmap", "newuidmap")
  rows[#rows + 1] = exe("open_capture_dep_newgidmap", "newgidmap")
  local subgid, user = "/etc/subgid", vim.fn.expand("$USER")
  local uid = tostring((vim.uv or vim.loop).getuid())
  local covered = false
  if vim.fn.filereadable(subgid) == 1 then
    for _, line in ipairs(vim.fn.readfile(subgid)) do
      local owner, _, count = line:match("^([^:]+):(%d+):(%d+)%s*$")
      if owner and (owner == user or owner == uid) and tonumber(count) and tonumber(count) > 0 then covered = true end
    end
  end
  rows[#rows + 1] = covered
    and row("open_capture_dep_subordinate_gids", "ok", "subordinate gid coverage found in " .. subgid)
    or row("open_capture_dep_subordinate_gids", level, "no subordinate gid range covers the invoking user", "add a subordinate gid range in /etc/subgid")
  local status, caps = vim.fn.filereadable("/proc/self/status") == 1 and vim.fn.readfile("/proc/self/status") or {}, false
  for _, line in ipairs(status) do
    local effective = line:match("^CapEff:%s*([%da-fA-F]+)")
    if effective and effective ~= "0" and effective ~= "0000000000000000" then caps = effective end
  end
  rows[#rows + 1] = caps
    and row("open_capture_capabilities", level, "effective capabilities retained: " .. caps, "drop write-bypassing capabilities before launch")
    or row("open_capture_capabilities", "ok", "no effective host capabilities retained")
  local root = vim.env.YANA_STATE_ROOT
  if not root or root == "" then root = vim.fn.stdpath("state") .. "/yana" end
  local parent = vim.fn.fnamemodify(root, ":h")
  local storage_ok = vim.fn.isdirectory(root) == 1
    or (vim.fn.isdirectory(parent) == 1 and vim.fn.getfperm(parent):find("w", 1, true) ~= nil)
  rows[#rows + 1] = storage_ok
    and row("open_capture_storage", "ok", "open-capture state root is available: " .. root, nil, root)
    or row("open_capture_storage", level, "open-capture state root is unavailable: " .. root, "create a writable state root outside the project")
  return rows
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

-- bwrap on PATH proves nothing about whether THIS kernel will let it create an
-- unprivileged user namespace: kernel.apparmor_restrict_unprivileged_userns=1 (Ubuntu
-- 24 default-ish) or a denied userns_clone passes every presence check and then fails
-- bin/yana-overlay's `--unshare-user` at run_overlay(), after the workspace claim is
-- already taken.
local function bwrap_userns_row()
  local bwrap = vim.fn.exepath("bwrap")
  if bwrap == "" then
    return row(
      "bwrap:userns",
      "error",
      "cannot probe unprivileged user namespaces: bwrap not found on PATH",
      "install the 'bubblewrap' package and restart Neovim: " .. install_command("bwrap")
    )
  end
  local ok_probe, result, probe_err = probe({
    bwrap,
    "--unshare-user",
    "--unshare-pid",
    "--die-with-parent",
    "--ro-bind",
    "/",
    "/",
    "--dev",
    "/dev",
    "--proc",
    "/proc",
    -- The production uid, not 0: bin/yana-overlay runs the agent as the
    -- invoking user, and bwrap reaches a non-zero sandbox uid through an
    -- INTERMEDIATE user namespace -- a different kernel path from `--uid 0`,
    -- and one a policy can deny on its own. A probe that still asked for
    -- uid 0 would pass on a host where every real turn refuses.
    "--uid",
    tostring(vim.loop.getuid()),
    "--gid",
    tostring(vim.loop.getgid()),
    "--",
    "true",
  }, 1500)
  if not ok_probe then
    return row(
      "bwrap:userns",
      "error",
      "bwrap user-namespace probe " .. probe_err,
      "retry; a probe that will not complete cannot be treated as passing"
    )
  end
  if result.code == 0 then
    return row("bwrap:userns", "ok", "bwrap can create an unprivileged user namespace with bind/proc/dev mounts")
  end
  local detail = (result.stderr or ""):gsub("%s+$", "")
  if detail == "" then
    detail = string.format("bwrap exited %d", result.code)
  end
  return row(
    "bwrap:userns",
    "error",
    "bwrap cannot create an unprivileged user namespace: " .. detail,
    "allow unprivileged user namespaces: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 "
      .. "(Ubuntu) or kernel.unprivileged_userns_clone=1 (Debian/others), or grant bwrap an AppArmor "
      .. "exception, then restart Neovim"
  )
end

-- The runtime shells out to bash 4.3+ nameref (bin/yana-sandbox
-- build_bwrap_args' `local -n`) and to associative arrays, both of which a
-- name-only check for "bash" cannot distinguish from bash 3.x (macOS
-- default) or a POSIX-only /bin/sh symlinked to `bash`. Namereference is the
-- stricter of the two floors, so one probe covers both.
local function bash_nameref_row()
  local bash = vim.fn.exepath("bash")
  if bash == "" then
    return row(
      "bash:nameref",
      "error",
      "cannot probe bash: bash not found on PATH",
      "install bash 4.3 or newer and restart Neovim"
    )
  end
  local ok_probe, result, probe_err = probe({ bash, "-c", "declare -n x=y" }, 1000)
  if not ok_probe then
    return row("bash:nameref", "error", "bash nameref probe " .. probe_err, "install bash 4.3 or newer")
  end
  if result.code == 0 then
    return row("bash:nameref", "ok", "bash supports 'declare -n' (nameref, bash 4.3+)")
  end
  return row(
    "bash:nameref",
    "error",
    "bash lacks 'declare -n' (nameref); the sandbox launcher requires bash 4.3+",
    "install GNU bash 4.3 or newer and ensure it resolves first on PATH"
  )
end

-- bin/yana-sandbox's root-identity check reads inode birth time with
-- `stat -c %w` (isolation.md's same-second delete/recreate close). BusyBox
-- `stat` answers to the same name with no `-c` support at all: usage banner
-- to stderr, non-zero exit. A name-only check cannot tell them apart.
local function gnu_stat_row()
  local stat = vim.fn.exepath("stat")
  if stat == "" then
    return row(
      "stat:gnu",
      "error",
      "cannot probe stat: stat not found on PATH",
      "install GNU coreutils and restart Neovim"
    )
  end
  local ok_probe, result, probe_err = probe({ stat, "-c", "%w", "." }, 1000)
  if not ok_probe then
    return row("stat:gnu", "error", "GNU stat probe " .. probe_err, "install GNU coreutils")
  end
  if result.code == 0 then
    return row("stat:gnu", "ok", "stat is GNU coreutils stat (-c supported)")
  end
  return row(
    "stat:gnu",
    "error",
    "stat is not GNU coreutils stat (-c unsupported); root-identity tracking requires it",
    "install GNU coreutils (the 'coreutils' package) and ensure it resolves first on PATH"
  )
end

-- bin/yana-sandbox's root-size walk reads type and size with
-- `find -printf`. BusyBox find has no -printf.
local function gnu_find_row()
  local find = vim.fn.exepath("find")
  if find == "" then
    return row(
      "find:gnu",
      "error",
      "cannot probe find: find not found on PATH",
      "install GNU findutils and restart Neovim"
    )
  end
  local ok_probe, result, probe_err = probe({ find, ".", "-maxdepth", "0", "-printf", "" }, 1000)
  if not ok_probe then
    return row("find:gnu", "error", "GNU find probe " .. probe_err, "install GNU findutils")
  end
  if result.code == 0 then
    return row("find:gnu", "ok", "find is GNU findutils (-printf supported)")
  end
  return row(
    "find:gnu",
    "error",
    "find is not GNU findutils (-printf unsupported); the root-size walk requires it",
    "install GNU findutils (the 'findutils' package) and ensure it resolves first on PATH"
  )
end

-- bin/yana-sandbox normalises inode birth time with `date -d @<epoch>
-- +%s%N`. BusyBox/mawk-era `date -d` sets the clock instead of parsing one,
-- so the check also pins the parsed output, not only the exit code.
local function gnu_date_row()
  local date = vim.fn.exepath("date")
  if date == "" then
    return row(
      "date:gnu",
      "error",
      "cannot probe date: date not found on PATH",
      "install GNU coreutils and restart Neovim"
    )
  end
  local ok_probe, result, probe_err = probe({ date, "-d", "@0", "+%s" }, 1000)
  if not ok_probe then
    return row("date:gnu", "error", "GNU date probe " .. probe_err, "install GNU coreutils")
  end
  if result.code == 0 and (result.stdout or ""):gsub("%s+$", "") == "0" then
    return row("date:gnu", "ok", "date is GNU coreutils date (-d supported)")
  end
  return row(
    "date:gnu",
    "error",
    "date is not GNU coreutils date (-d unsupported); birth-time normalisation requires it",
    "install GNU coreutils (the 'coreutils' package) and ensure it resolves first on PATH"
  )
end

local function kernel_rows(rows)
  local uname = (vim.uv or vim.loop).os_uname()
  local darwin = uname.sysname == "Darwin"
  -- Confined modes stay Linux-only (S-24). On Darwin, name the operator
  -- choice — explicit agentic, or Linux — never "mount procfs".
  local mac_confined_remedy = "ask/inline need Linux overlayfs+bwrap; on macOS set enable_agentic=true and mode='agentic' (no overlay, no review), or run Yana on Linux. Yana never falls back to agentic by itself"
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
      darwin and mac_confined_remedy or "load or enable the Linux overlay filesystem"
    )
  end

  if vim.fn.filereadable("/sys/fs/cgroup/cgroup.controllers") == 1 then
    rows[#rows + 1] = row("kernel:cgroup2", "ok", "cgroup v2 is available")
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
M.bwrap_userns_row = bwrap_userns_row
M.bash_nameref_row = bash_nameref_row
M.gnu_stat_row = gnu_stat_row
M.gnu_find_row = gnu_find_row
M.gnu_date_row = gnu_date_row
M.kernel_rows = kernel_rows
M.open_capture_rows = open_capture_rows
-- Exposed for tests/release/install_remedy_smoke.lua: proves the exact
-- one-liner a distro actually gets, without needing to fake /etc/os-release
-- or PATH on the test host itself.
M.detect_pkg_manager = detect_pkg_manager
M.install_command = install_command

return M
