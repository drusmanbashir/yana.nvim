local config = require("yana.config")

local M = {}

M.minimum_neovim = "0.10.4"

local confined_executables = {
  "bash",
  "bwrap",
  -- bin/yana-overlay-inner's final step, run inside the bwrap namespace, execs
  -- `capsh --drop=all --caps=` (bin/yana-overlay-inner:31) to drop capabilities
  -- before the agent starts. This is not optional hardening: it is the last
  -- command in the chain, so its absence lets the overlay mount cleanly and
  -- then the agent never runs at all -- name-only presence checks above
  -- (bwrap, mount) would still report the machine ready.
  "capsh",
  -- python3 is NOT here. It is a hard dependency only when
  -- `inline_exec_allowlist` is configured (bin/yana-overlay-inner execs into
  -- it to set up the Landlock ruleset -- see apply_exec_allowlist there);
  -- every confined turn without that option never spawns python3 at all.
  -- M.required_executables() below appends it conditionally, and M.check()
  -- reports it as an optional (warn) row the rest of the time, matching
  -- sqlite3/md5 below.
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
  local list = vim.deepcopy(confined_executables)
  if type(config.options.inline_exec_allowlist) == "table" then
    list[#list + 1] = "python3"
  end
  return list
end

local function row(id, level, message, remedy, resolved)
  return { id = id, level = level, message = message, remedy = remedy, resolved = resolved }
end

-- Real distro package names for required executables whose literal exec
-- name is NOT itself an installable apt/dnf/pacman package -- validated
-- against live Ubuntu 24.04 (apt) and Fedora (dnf) containers by
-- packets/freshdep-audit-20260820.md Part 1b (the pacman column follows
-- that packet's Part 3 proposal but was not tested against a live Arch
-- machine). scripts/install-deps.sh carries its own copy of this same
-- mapping, since it must run before Neovim or this file is ever loaded --
-- keep the two in sync when either changes.
local EXEC_PACKAGE_HINT = {
  bwrap = "the 'bubblewrap' package",
  capsh = "the package providing capsh -- 'libcap2-bin' on Debian/Ubuntu, 'libcap' on Fedora/Arch",
  flock = "the 'util-linux' package (provides flock/mount/umount)",
  mount = "the 'util-linux' package (provides flock/mount/umount)",
  umount = "the 'util-linux' package (provides flock/mount/umount)",
  find = "the 'findutils' package",
  awk = "the 'gawk' package",
  getent = "the package providing getent -- 'libc-bin' on Debian/Ubuntu, 'glibc-common' on Fedora",
}

local function package_hint(name)
  return EXEC_PACKAGE_HINT[name] or ("the '" .. name .. "' package")
end

local function executable_row(name, required)
  local resolved = vim.fn.exepath(name)
  if resolved ~= "" then
    return row("exec:" .. name, "ok", name .. " found: " .. resolved, nil, resolved)
  end
  local level = required and "error" or "warn"
  local remedy
  if required then
    remedy = "install "
      .. package_hint(name)
      .. " and restart Neovim (run scripts/install-deps.sh for the exact command for your distro)"
  else
    remedy = "install "
      .. package_hint(name)
      .. " to enable this optional feature (run scripts/install-deps.sh for the exact command)"
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
  local ok_call, obj = pcall(vim.system, cmd, { text = true })
  if not ok_call then
    return false, nil, "FAILED-to-probe: " .. tostring(obj)
  end
  local ok_wait, result = pcall(function()
    return obj:wait(timeout_ms)
  end)
  if not ok_wait then
    return false, nil, "FAILED-to-probe: " .. tostring(result)
  end
  if result.code == 124 and result.signal == 9 then
    return false, nil, "FAILED-to-probe: timed out after " .. timeout_ms .. "ms"
  end
  return true, result
end

-- bwrap on PATH proves nothing about whether THIS kernel will let it create
-- an unprivileged user namespace: kernel.apparmor_restrict_unprivileged_userns=1
-- (Ubuntu 24 default-ish) or a denied userns_clone passes every presence
-- check and then fails bin/yana-overlay's `--unshare-user` at run_overlay(),
-- after the workspace claim is already taken. Mirrors run_overlay()'s
-- userns + bind + proc/dev shape (the flags a kernel policy denial trips)
-- without the workspace-specific binds that shape does not need to fail the
-- same way, so the probe stays a fixed, argument-free command and cheap
-- (measured ~15ms on a passing host, well under the 200ms budget).
local function bwrap_userns_row()
  local bwrap = vim.fn.exepath("bwrap")
  if bwrap == "" then
    return row(
      "bwrap:userns",
      "error",
      "cannot probe unprivileged user namespaces: bwrap not found on PATH",
      "install the 'bubblewrap' package and restart Neovim (run scripts/install-deps.sh for the exact command for your distro)"
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
    "--uid",
    "0",
    "--gid",
    "0",
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

-- Human-readable label for a resolve_cmd() step, so the health row can say
-- exactly WHY the value it is about to check came from where it did — a
-- fresh user with no cursor-agent on PATH needs to see whether nothing was
-- configured, an env var was checked and missed, or an env var answered.
local function step_label(step, candidates)
  if step == "config" then
    return "explicit setup({ cmd = ... })"
  end
  if step == "cmd_env" then
    local env_name = "?"
    for _, c in ipairs(candidates) do
      if c.step == "cmd_env" and c.env_name then
        env_name = c.env_name
      end
    end
    return "the $" .. env_name .. " environment variable (cmd_env)"
  end
  return "cursor-agent on PATH (no cmd or cmd_env match)"
end

-- One clause per candidate the resolver considered, in precedence order, so
-- the row shows not just what won but what was tried before it — exactly
-- the "configured/env/PATH candidates listed" a fresh user needs to debug a
-- miss.
local function describe_candidates(candidates)
  local parts = {}
  for _, c in ipairs(candidates) do
    if c.step == "config" then
      parts[#parts + 1] = c.tried and ("cmd=" .. tostring(c.raw)) or "cmd unset"
    elseif c.step == "cmd_env" then
      if c.tried then
        parts[#parts + 1] = string.format("$%s=%s", c.env_name, tostring(c.raw))
      elseif c.env_name then
        parts[#parts + 1] = string.format("$%s unset", c.env_name)
      else
        parts[#parts + 1] = "cmd_env disabled"
      end
    else
      parts[#parts + 1] = "PATH lookup of 'cursor-agent'"
    end
  end
  return table.concat(parts, "; ")
end

local function configured_agent_row()
  local resolution = config.resolve_cmd()
  local resolved = vim.fn.exepath(resolution.value)
  local why = string.format(
    "resolved via %s; candidates tried in order: %s",
    step_label(resolution.step, resolution.candidates),
    describe_candidates(resolution.candidates)
  )
  if resolved ~= "" then
    return row("exec:cursor-agent", "ok", "cursor-agent found: " .. resolved .. " (" .. why .. ")", nil, resolved)
  end
  return row(
    "exec:cursor-agent",
    "error",
    "cursor-agent not found for '" .. tostring(resolution.value) .. "' (" .. why .. ")",
    "install and sign in to cursor-agent (run scripts/install-deps.sh --run, which prints the official installer "
      .. "command and asks before running it), or set require('yana').setup({ cmd = '/absolute/path/to/cursor-agent' }), "
      .. "or export the environment variable named by cmd_env (default YANA_AGENT_BIN)"
  )
end

-- configured_agent_row() above proves a file exists at the resolved path; it
-- proves nothing about whether THAT binary understands what a turn actually
-- sends it: -p, --output-format stream-json, --stream-partial-output,
-- --trust, --mode ask, --force, --model, --resume (lua/yana/agent.lua's
-- build_cmd()), or the --list-models format M.list_models() parses. No
-- supported Cursor Agent version range is pinned by the public compatibility
-- policy, so there is nothing to gate against yet -- this row is
-- report-only: it names the resolved binary's own --version string so a
-- mismatch between what the operator has installed and what a turn actually
-- needs is visible at :checkhealth time, without yana silently guessing a
-- compatibility range it cannot prove. Reuses probe() (dependencies.lua's
-- shared fail-closed spawn helper), same as bwrap_userns_row/bash_nameref_row
-- above, rather than a second ad hoc vim.system call.
--
-- Never "error": a working install that merely answers --version oddly (or
-- not at all) must not be blocked on a heuristic this file cannot prove is
-- meaningful. exec:cursor-agent (configured_agent_row) already owns the hard
-- presence gate.
local function agent_version_row()
  local resolution = config.resolve_cmd()
  local resolved = vim.fn.exepath(resolution.value)
  if resolved == "" then
    -- configured_agent_row() already reports this as an error; nothing to
    -- version-probe.
    return nil
  end
  local ok_probe, result, probe_err = probe({ resolved, "--version" }, 1500)
  if not ok_probe then
    return row(
      "exec:cursor-agent-version",
      "warn",
      "could not determine cursor-agent version: " .. probe_err,
      "run '" .. resolved .. " --version' manually to confirm the binary works"
    )
  end
  if result.code ~= 0 then
    local detail = (result.stderr or ""):gsub("%s+$", "")
    return row(
      "exec:cursor-agent-version",
      "warn",
      "cursor-agent --version exited " .. result.code .. (detail ~= "" and (": " .. detail) or ""),
      "run '" .. resolved .. " --version' manually to confirm the binary works"
    )
  end
  local version = vim.trim((result.stdout or ""):match("^[^\n]*") or "")
  if version == "" then
    return row(
      "exec:cursor-agent-version",
      "warn",
      "cursor-agent --version produced no output",
      "run '" .. resolved .. " --version' manually to confirm the binary works"
    )
  end
  return row("exec:cursor-agent-version", "ok", "cursor-agent version: " .. version)
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

-- Cursor/Claude skill-directory scan (config.options.skill_dirs, defaulted
-- in config.lua to ~/.cursor/skills, ~/.cursor/skills-cursor and
-- ~/.claude/skills). Each entry is already best-effort -- commands.lua's
-- scan_skill_dir() silently skips a directory that does not exist -- and
-- already configurable via setup({ skill_dirs = {...} }). What was missing
-- was visibility: a fresh machine with none of these roots learned nothing
-- about it until a skill picker came up empty. Always "ok": an absent
-- optional root is the expected case on most machines, not a fault.
local function skill_dirs_row()
  local dirs = config.options.skill_dirs or {}
  if #dirs == 0 then
    return nil
  end
  local found, skipped = {}, {}
  for _, dir in ipairs(dirs) do
    if vim.fn.isdirectory(dir) == 1 then
      found[#found + 1] = dir
    else
      skipped[#skipped + 1] = dir
    end
  end
  local msg = "skill_dirs: found " .. (#found > 0 and table.concat(found, ", ") or "none")
  if #skipped > 0 then
    msg = msg .. "; skipped (not present): " .. table.concat(skipped, ", ")
  end
  return row("config:skill_dirs", "ok", msg)
end

-- External-session discovery root (config.options.sessions.chats_dir,
-- config.lua: nil => ~/.cursor/chats). Already best-effort -- sessions.lua's
-- M.discover() returns {} when the directory is absent -- and already
-- configurable. Same visibility gap as skill_dirs above: nothing said
-- whether this machine even had the directory cursor-agent's own CLI writes
-- to. Always "ok": absence just means no externally-started sessions show
-- up in the picker, not a broken install.
local function chats_dir_row()
  local configured = config.options.sessions and config.options.sessions.chats_dir
  local resolved = vim.fn.expand((configured and configured ~= "") and configured or "~/.cursor/chats")
  if vim.fn.isdirectory(resolved) == 1 then
    return row("config:chats_dir", "ok", "cursor-agent chats directory found: " .. resolved)
  end
  return row(
    "config:chats_dir",
    "ok",
    "cursor-agent chats directory not found (external session discovery skipped): " .. resolved
  )
end

-- `opts.probe_agent_version` (default true) gates agent_version_row() only.
-- That row spawns the RESOLVED AGENT BINARY ITSELF ("<cmd> --version"),
-- unconfined -- no jail wrap, no cwd isolation -- and, per its own comment,
-- is "Never error": a preflight refusal can never come from it. M.preflight()
-- below was passing every M.check() row through its error-only filter, so
-- this row's spawn bought preflight nothing while paying for it on every
-- single turn submit. Worse than wasted cost: with the headless suite's
-- `tests/fake-cursor-agent` standing in for the agent binary, ANY argv other
-- than `--list-models` falls through to that fixture's default behaviour --
-- replay the configured stream and, if YANA_FAKE_APPLY_DIR is set, copy its
-- tree onto the CURRENT (unconfined) cwd. Preflight's own `--version` probe
-- therefore replayed the turn's own fixture directly onto the real
-- workspace, BEFORE the real, properly confined turn ever spawned -- so the
-- confined turn's overlay upper layer came up identical to its (already
-- mutated) lower layer and every downstream review saw "no changes". Confined
-- to preflight callers; M.preflight() below is the only caller that passes
-- `probe_agent_version = false` -- :checkhealth (health.lua) and this
-- module's own smoke test call M.check() directly and still get the row.
function M.check(mode, opts)
  mode = mode or config.options.mode
  opts = opts or {}
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
  if opts.probe_agent_version ~= false then
    local version_row = agent_version_row()
    if version_row then
      rows[#rows + 1] = version_row
    end
  end
  local skill_row = skill_dirs_row()
  if skill_row then
    rows[#rows + 1] = skill_row
  end
  rows[#rows + 1] = chats_dir_row()

  if mode ~= "agentic" then
    kernel_rows(rows)
    local required_now = M.required_executables(mode)
    local python3_required = false
    for _, name in ipairs(required_now) do
      rows[#rows + 1] = executable_row(name, true)
      python3_required = python3_required or name == "python3"
    end
    if not python3_required then
      -- inline_exec_allowlist is unset, so bin/yana-overlay-inner never
      -- execs python3 for this turn -- report it the same way sqlite3/md5
      -- are reported below: present-if-found, optional either way.
      rows[#rows + 1] = executable_row("python3", false)
    end
    -- Presence checks above prove a name resolves; these prove the resolved
    -- binary can do what the confined launchers actually need from it.
    rows[#rows + 1] = bwrap_userns_row()
    rows[#rows + 1] = bash_nameref_row()
    rows[#rows + 1] = gnu_stat_row()
    rows[#rows + 1] = gnu_find_row()
    rows[#rows + 1] = gnu_date_row()
  end

  rows[#rows + 1] = executable_row("sqlite3", false)
  if vim.fn.executable("md5sum") == 1 or vim.fn.executable("md5") == 1 then
    rows[#rows + 1] = row("exec:md5", "ok", "md5sum or md5 found for external-session discovery")
  else
    rows[#rows + 1] = row(
      "exec:md5",
      "warn",
      "md5sum/md5 not found; only sessions started from Neovim can be listed",
      "install the 'coreutils' package (provides md5sum) to enable external-session discovery "
        .. "(run scripts/install-deps.sh for the exact command)"
    )
  end

  return rows
end

function M.preflight(mode)
  -- No live agent-binary probe on the hot per-submit path -- see M.check()'s
  -- comment: agent_version_row() can never be "error" (report-only by
  -- design), so skipping it here changes nothing about whether a turn is
  -- refused, only removes an unconfined spawn of the agent binary this gate
  -- never needed.
  --
  -- Collect EVERY error-level row, not just the first: a fresh machine
  -- missing cursor-agent used to see only "[exec:cursor-agent] ..." on every
  -- retry, because this loop returned on the first hit -- the confined-mode
  -- executables behind it (bwrap, capsh, python3, ...) stayed invisible
  -- until cursor-agent was installed and the user retried again, one
  -- restart per dependency (packets/freshdep-audit-20260820.md Part 1). One
  -- refusal now names all of them, and points at the one-command installer.
  local errors = {}
  for _, item in ipairs(M.check(mode, { probe_agent_version = false })) do
    if item.level == "error" then
      errors[#errors + 1] = string.format("[%s] %s - %s", item.id, item.message, item.remedy)
    end
  end
  if #errors == 0 then
    return true
  end
  return false,
    table.concat(errors, "\n") .. "\nrun scripts/install-deps.sh to install what it can, and see the remedies above."
end

return M
