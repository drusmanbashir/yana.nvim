local config = require("yana.config")
local dependencies_probe = require("yana.dependencies_probe")

local M = {}

-- Split out of this file: self-contained system/toolchain
-- probes with no config.lua dependency. Aliased under their original local
-- names so every call site below is unchanged.
local row = dependencies_probe.row
local probe = dependencies_probe.probe
local executable_row = dependencies_probe.executable_row
local bwrap_userns_row = dependencies_probe.bwrap_userns_row
local bash_nameref_row = dependencies_probe.bash_nameref_row
local gnu_stat_row = dependencies_probe.gnu_stat_row
local gnu_find_row = dependencies_probe.gnu_find_row
local gnu_date_row = dependencies_probe.gnu_date_row
local kernel_rows = dependencies_probe.kernel_rows

M.minimum_neovim = "0.11.2"

local function clipboard_row()
  if not config.options.image_paste or not config.options.image_paste.enable then
    return nil
  end
  local xclip = vim.fn.executable("xclip") == 1
  local wl_paste = vim.fn.executable("wl-paste") == 1
  if xclip or wl_paste then
    return row("exec:clipboard", "ok", "xclip or wl-paste found for image/text paste")
  end
  return row(
    "exec:clipboard",
    "warn",
    "no clipboard reader found for image/text paste",
    "install xclip (X11) or wl-clipboard (Wayland, wl-paste)"
  )
end

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
  -- bin/yana-overlay-inner re-execs itself under `unshare --mount` before it
  -- mounts anything: the agent now runs as the invoking user, and at a
  -- non-zero sandbox uid the mount namespace bwrap made is owned by an
  -- ancestor user namespace, so every mount into it is EPERM. Absent, the
  -- overlay never mounts and the turn refuses pre-agent -- so, like capsh,
  -- presence of bwrap and mount alone would report a ready machine wrongly.
  "unshare",
  -- python3 is NOT here. It is a hard dependency only when
  -- `inline_exec_allowlist` is configured (bin/yana-overlay-inner execs into
  -- it to set up the Landlock ruleset -- see apply_exec_allowlist there);
  -- every confined turn without that option never spawns python3 at all.
  -- M.required_executables() below appends it conditionally, and M.check()
  -- reports it as an optional (warn) row the rest of the time.
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

-- Return executables required for mode; adds python3 if allowlist is set.
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

-- Exposed for health.lua's generic per-backend auth probe (whoami_args):
-- the same fail-closed spawn-with-timeout helper every probe in this file
-- already uses, so the auth row gets the same "a probe that could not run
-- proves nothing" guarantee rather than a second ad hoc vim.system call.
M.probe = probe

local function executable_identity(command)
  local resolved = vim.fn.exepath(command)
  if resolved == "" then
    return nil, nil
  end
  local uv = vim.uv or vim.loop
  return resolved, uv.fs_realpath(resolved) or resolved
end

local function desktop_cursor_markers(path)
  if vim.fn.fnamemodify(path, ":t") ~= "cursor" then
    return false
  end
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  local prefix = f:read(65536) or ""
  f:close()
  return prefix:find("ELECTRON_RUN_AS_NODE", 1, true) ~= nil
    and prefix:find("resources/app/out/cli.js", 1, true) ~= nil
end

--- Refuse the desktop Cursor application at the resolved-backend boundary.
--- This is static identity inspection only: executing a candidate to discover
--- whether it opens a GUI would reproduce the operator-facing defect.
function M.desktop_cursor_refusal(command, backend_name)
  local resolved, canonical = executable_identity(command)
  if not resolved then
    return nil
  end
  local desktop_root = "/usr/share/cursor"
  local under_desktop_root = canonical == desktop_root
    or canonical:sub(1, #desktop_root + 1) == desktop_root .. "/"
  if not under_desktop_root and not desktop_cursor_markers(resolved) then
    return nil
  end
  return "yana: refused to start desktop Cursor CLI '"
    .. tostring(command)
    .. "' (resolved to '"
    .. canonical
    .. "') for backend '"
    .. tostring(backend_name or "cursor")
    .. "' — desktop Cursor cannot answer a headless turn; set backends.cursor.cmd, cmd, or cmd_env to cursor-agent or a headless wrapper"
end

-- Fixed for both label functions in the same pass, since both read the same
-- `candidates` shape and shared the same gap.
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
  if step == "backend_cmd_env" then
    local backend_name, env_name = "?", "?"
    for _, c in ipairs(candidates) do
      if c.step == "backend_cmd_env" and c.tried then
        backend_name = c.backend or backend_name
        env_name = c.env_name or env_name
      end
    end
    return "the $" .. env_name .. " environment variable for backend " .. backend_name
  end
  if step == "backend" or step == "backend_bundled" then
    local backend_name, raw = "?", "?"
    for _, c in ipairs(candidates) do
      if (c.step == "backend" or c.step == "backend_bundled") and c.tried then
        backend_name = c.backend or backend_name
        raw = c.raw or raw
      end
    end
    return "backends." .. backend_name .. ".cmd (" .. tostring(raw) .. ")"
  end
  -- step == "path": resolve_cmd() only ever produces this candidate as the
  -- literal bare name "cursor-agent" (config.lua's own comment: only the
  -- built-in "cursor" entry may leave `cmd` unset, which is what reaches
  -- this fallback at all), so naming it explicitly here is correct for
  -- every backend that can reach it, not just "cursor".
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
    elseif c.step == "backend_cmd_env" then
      if c.tried then
        parts[#parts + 1] = string.format("$%s=%s", c.env_name, tostring(c.raw))
      else
        parts[#parts + 1] = string.format("$%s unset", c.env_name)
      end
    elseif c.step == "backend" or c.step == "backend_bundled" then
      if c.tried then
        parts[#parts + 1] = string.format("backends.%s.cmd=%s", tostring(c.backend), tostring(c.raw))
      else
        parts[#parts + 1] = string.format("backends.%s.cmd not set", tostring(c.backend))
      end
    else
      parts[#parts + 1] = "PATH lookup of 'cursor-agent'"
    end
  end
  return table.concat(parts, "; ")
end

local function configured_agent_row()
  local backend_name = config.options.backend or config.defaults.backend
  local resolution = config.resolve_cmd()
  local resolved = vim.fn.exepath(resolution.value)
  local why = string.format(
    "resolved via %s; candidates tried in order: %s",
    step_label(resolution.step, resolution.candidates),
    describe_candidates(resolution.candidates)
  )
  if backend_name == "cursor" then
    if resolved ~= "" then
      return row("exec:cursor-agent", "ok", "cursor-agent found: " .. resolved .. " (" .. why .. ")", nil, resolved)
    end
    local cursor_install_hint = (config.backend_descriptor("cursor") or {}).install_hint
    return row(
      "exec:cursor-agent",
      "error",
      "cursor-agent not found for '" .. tostring(resolution.value) .. "' (" .. why .. ")",
      "install and sign in to cursor-agent: "
        .. tostring(cursor_install_hint)
        .. ", or set require('yana').setup({ cmd = '/absolute/path/to/cursor-agent' }), "
        .. "or export YANA_CURSOR_BIN (legacy: the variable named by cmd_env, default YANA_AGENT_BIN), "
        .. "then run :checkhealth yana to confirm"
    )
  end

  local id = "exec:" .. backend_name
  if resolved ~= "" then
    return row(id, "ok", backend_name .. " found: " .. resolved .. " (" .. why .. ")", nil, resolved)
  end
  local entry = config.backend_descriptor(backend_name) or {}
  local backend_env = entry.cmd_env
  local install_hint = entry.install_hint
  local install_clause = install_hint and ("install " .. backend_name .. " (" .. install_hint .. ")")
    or ("install " .. backend_name .. " (see its own docs -- Yana ships no install_hint for this backend)")
  return row(
    id,
    "error",
    backend_name .. " not found for '" .. tostring(resolution.value) .. "' (" .. why .. ")",
    install_clause
      .. (backend_env and (", or export " .. backend_env .. "=/absolute/path/to/" .. backend_name) or "")
      .. ", then run :checkhealth yana to confirm, or set require('yana').setup({ backends = { "
      .. backend_name
      .. " = { cmd = '/absolute/path/to/"
      .. backend_name
      .. "' } } })"
  )
end

-- configured_agent_row() above proves a file exists at the resolved path; it proves
-- nothing about whether THAT binary understands what a turn actually sends it: -p,
-- --output-format stream-json, --stream-partial-output, --trust, --mode ask, --force,
-- --model, --resume (lua/yana/agent.lua's build_cmd()), or the --list-models format
-- M.list_models() parses. Reuses probe() (dependencies.lua's shared fail-closed spawn
-- helper), same as bwrap_userns_row/bash_nameref_row above, rather than a second ad hoc
--
-- Never "error": a working install that merely answers --version oddly (or not at all)
-- must not be blocked on a heuristic this file cannot prove is meaningful.
-- exec:cursor-agent (configured_agent_row) already owns the hard presence gate. Exit
-- code 0 is why `agent_version_row` above cannot use this as an error: the binary
-- "succeeds" while silently doing nothing on a real turn, so the only place this is
-- visible at all is stray text on stderr.
local WRAPPER_WARNING_NEEDLE = "not in the list of known options"

--- Report-only, gated with `agent_version_row` (same probe_agent_version guard, same
--- unconfined spawn -- see M.check below): warns when the resolved binary's own output
--- carries the known-options warning, naming both the resolved path (`cmd`) and the fix
--- (a wrapper script in the `~/scripts/bin/cursor-cli` shape). Never "error": the raw
--- binary still exits 0 and answers --version fine, so this is exactly the class of
--- silent-degradation this row exists to surface, not to block on.
local function wrapper_warning_row(resolved, result)
  local haystack = (result.stdout or "") .. "\n" .. (result.stderr or "")
  if not haystack:find(WRAPPER_WARNING_NEEDLE, 1, true) then
    return nil
  end
  return row(
    "exec:cursor-agent-wrapper",
    "warn",
    "cmd "
      .. resolved
      .. " answers with '"
      .. WRAPPER_WARNING_NEEDLE
      .. "' -- this is the raw, unwrapped binary (Electron/Chromium rejecting yana's own flags); "
      .. "a real turn will exit 0 and produce zero events",
    "point cmd (or $YANA_AGENT_BIN / cmd_env) at a wrapper script in the ~/scripts/bin/cursor-cli shape "
      .. "(exec's `node --use-system-ca index.js <real-install>` instead of the packaged binary directly) "
      .. "rather than the bare resolved path"
  )
end

-- Returns (version_row, wrapper_row) -- wrapper_row is nil unless the probe
-- ran and its output carried WRAPPER_WARNING_NEEDLE.
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
  local wrapper_row = wrapper_warning_row(resolved, result)
  if result.code ~= 0 then
    local detail = (result.stderr or ""):gsub("%s+$", "")
    return row(
      "exec:cursor-agent-version",
      "warn",
      "cursor-agent --version exited " .. result.code .. (detail ~= "" and (": " .. detail) or ""),
      "run '" .. resolved .. " --version' manually to confirm the binary works"
    ), wrapper_row
  end
  local version = vim.trim((result.stdout or ""):match("^[^\n]*") or "")
  if version == "" then
    return row(
      "exec:cursor-agent-version",
      "warn",
      "cursor-agent --version produced no output",
      "run '" .. resolved .. " --version' manually to confirm the binary works"
    ), wrapper_row
  end
  return row("exec:cursor-agent-version", "ok", "cursor-agent version: " .. version), wrapper_row
end

local function neovim_version()
  local version = vim.version()
  return string.format("%d.%d.%d", version.major, version.minor, version.patch)
end

-- Cursor/Claude skill-directory scan (config.options.skill_dirs, defaulted in
-- config.lua to ~/.cursor/skills, ~/.cursor/skills-cursor and ~/.claude/skills). Each
-- entry is already best-effort -- commands.lua's scan_skill_dir() silently skips a
-- directory that does not exist -- and already configurable via setup({ skill_dirs =
-- {...} }). What was missing was visibility: a fresh machine with none of these roots
-- learned nothing about it until a skill picker came up empty.
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

-- `opts.probe_agent_version` (default true) gates agent_version_row() only. That row
-- spawns the RESOLVED AGENT BINARY ITSELF ("<cmd> --version"), unconfined -- no jail
-- wrap, no cwd isolation -- and, per its own comment, is "Never error": a preflight
-- refusal can never come from it. M.preflight() below was passing every M.check() row
-- through its error-only filter, so this row's spawn bought preflight nothing while
-- paying for it on every single turn submit.
function M.check(mode, opts)
  mode = mode or config.options.mode
  opts = opts or {}
  local rows = {}

  if vim.fn.has("nvim-" .. M.minimum_neovim) == 1 then
    rows[#rows + 1] = row("nvim:min", "ok", "Neovim " .. neovim_version())
  else
    -- PRERELEASE-0.1.0-alpha.5-README-audit.md defect 4: name the version
    -- ACTUALLY FOUND (a fresh-user audit hit this on Ubuntu 24.04's `apt`
    -- package -- 0.9.5, silently below the 0.11.2 floor, with no warning
    -- anywhere until this check), the floor itself, and the documented
    -- install path -- not just "upgrade Neovim" with nothing to act on.
    rows[#rows + 1] = row(
      "nvim:min",
      "error",
      "Neovim " .. neovim_version() .. " found; " .. M.minimum_neovim .. "+ is required",
      "apt on Ubuntu 24.04 and older ships a Neovim below this floor with no warning of its own -- see "
        .. "README.md's 'System requirements' section (or :help yana-requirements) for the documented "
        .. "AppImage / neovim-ppa/unstable install path (Neovim's own install docs: "
        .. "https://neovim.io/doc/install/)"
    )
  end

  rows[#rows + 1] = configured_agent_row()
  if opts.probe_agent_version ~= false then
    local version_row, wrapper_row = agent_version_row()
    if version_row then
      rows[#rows + 1] = version_row
    end
    if wrapper_row then
      rows[#rows + 1] = wrapper_row
    end
  end
  local skill_row = skill_dirs_row()
  if skill_row then
    rows[#rows + 1] = skill_row
  end
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
      -- execs python3 for this turn; report it as present-if-found, optional
      -- either way.
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

  local clipboard = clipboard_row()
  if clipboard then
    rows[#rows + 1] = clipboard
  end
  return rows
end

-- Return true, or false plus every error-level row from M.check joined.
function M.preflight(mode)
  -- No live agent-binary probe on the hot per-submit path -- see M.check()'s
  -- comment: agent_version_row() can never be "error" (report-only by
  -- design), so skipping it here changes nothing about whether a turn is
  -- refused, only removes an unconfined spawn of the agent binary this gate
  -- never needed.
  --
  -- One refusal now names all of them, each with its own exact install command.
  local errors = {}
  for _, item in ipairs(M.check(mode, { probe_agent_version = false })) do
    if item.level == "error" then
      errors[#errors + 1] = string.format("[%s] %s - %s", item.id, item.message, item.remedy)
    end
  end
  if #errors == 0 then
    return true
  end
  return false, table.concat(errors, "\n")
end

return M
