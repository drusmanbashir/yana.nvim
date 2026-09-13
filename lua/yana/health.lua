-- yana: :checkhealth yana
local config = require("yana.config")
local dependencies = require("yana.dependencies")

local M = {}

local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local err = health.error or health.report_error
-- No legacy report_info equivalent existed in the old vimscript health API,
-- so a Neovim old enough to lack vim.health.info degrades this to ok()
-- rather than erroring.
local info = health.info or ok

-- Probes whether `dir`'s filesystem reports a usable inode birth time, the
-- same signal bin/yana-sandbox's path_identity() keys workspace-root approval
-- on. A fresh, uniquely-named file is created directly inside `dir` (not
-- TMPDIR: the point is to measure the CURRENT workspace's filesystem, not
-- wherever temp files happen to land) and removed again before returning,
-- success or failure.
--
-- Returns (true, birth_string) when supported, (false, birth_string) when
-- the filesystem reports no usable birth time, or (nil, reason) when the
-- probe itself could not run (e.g. `dir` is not writable).
local function probe_birth_time_support(dir)
  local name = string.format(".yana-birthcheck-%d-%d", vim.fn.getpid(), math.random(100000, 999999))
  local path = dir .. "/" .. name
  local f, open_err = io.open(path, "w")
  if not f then
    return nil, "could not create a probe file in " .. dir .. ": " .. tostring(open_err)
  end
  f:write("yana birth-time probe\n")
  f:close()

  -- The probe file must be removed on EVERY path out of this function, even when `stat`
  -- itself errors rather than merely returning a non-zero shell exit -- e.g. an
  -- interrupted headless run, where vim.fn.system() can throw instead of returning. The
  -- old code only reached `pcall(os.remove, path)` AFTER vim.fn.system() had already
  -- returned, so a throw there skipped cleanup entirely and left the dotfile behind
  -- (two such `.yana-birthcheck-*` files were found stray in this repo).
  local uname = (vim.uv or vim.loop).os_uname()
  local stat_argv
  local stat_label
  if uname.sysname == "Darwin" then
    stat_argv = { "stat", "-f", "%B", path }
    stat_label = "`stat -f %B`"
  else
    stat_argv = { "stat", "-c", "%w", path }
    stat_label = "`stat -c %w`"
  end
  local stat_ok, out = pcall(vim.fn.system, stat_argv)
  local shell_err = vim.v.shell_error
  pcall(os.remove, path)

  if not stat_ok then
    return nil, stat_label .. " failed on " .. dir .. ": " .. tostring(out)
  end
  if shell_err ~= 0 or type(out) ~= "string" then
    return nil, stat_label .. " failed on " .. dir
  end

  local birth = vim.trim(out)
  -- Same "unusable birth time" test as bin/yana-sandbox's path_identity():
  -- empty, "-", "?" or a value starting with "0" all mean the filesystem does
  -- not carry a real birth time. That refuses there, fail-closed, rather
  -- than falling back to a weaker (dev, ino) identity — this row exists so
  -- the user learns that BEFORE a turn hits the refusal.
  local supported = birth ~= "" and birth ~= "-" and birth ~= "?" and birth:sub(1, 1) ~= "0"
  return supported, birth
end

-- Workspace-root approval (bin/yana-sandbox) only runs for confined modes
-- (ask, inline); direct `agentic` mode never sandboxes, so it never needs the
-- birth-time identity and the probe is skipped there.
local function birth_time_row()
  if config.options.mode == "agentic" then
    return
  end
  local cwd = vim.fn.getcwd()
  local supported, detail = probe_birth_time_support(cwd)
  if supported == nil then
    warn("workspace filesystem birth-time: could not probe (" .. tostring(detail) .. ")")
    return
  end
  if supported then
    ok("workspace filesystem birth-time: supported (" .. cwd .. ")")
  else
    warn(
      "workspace filesystem birth-time: NOT supported (" .. cwd .. ", stat %w=" .. (detail == "" and "empty" or detail) .. "). "
        .. "Confined-mode workspace approval (ask, inline) requires a usable inode birth time and refuses turns "
        .. "here rather than falling back to a weaker check; this is common on some network filesystems (e.g. NFS) "
        .. "and layered/overlay filesystems.",
      { "move the workspace to a filesystem that reports inode birth time (e.g. ext4, xfs, btrfs)" }
    )
  end
end

-- Best-effort human name for whatever already owns a foreign-mapped lhs, so
-- the WARN/INFO below can name both sides of the collision.
local function describe_foreign_map(map_info)
  if type(map_info) ~= "table" then
    return "an existing mapping"
  end
  if type(map_info.desc) == "string" and map_info.desc ~= "" then
    return '"' .. map_info.desc .. '"'
  end
  if map_info.callback then
    return "a Lua callback"
  end
  if type(map_info.rhs) == "string" and map_info.rhs ~= "" then
    return map_info.rhs
  end
  return "an existing mapping"
end

-- True when `map_info` (a vim.fn.maparg(..., true) dict for an EXISTING
-- foreign mapping) is a genuine Neovim BUILT-IN default -- e.g. the stock
-- insert/select-mode `<C-s>` -> vim.lsp.buf.signature_help() shipped since
-- Neovim 0.11 -- rather than something the user's own config or a
-- plugin set up.
--
-- Neovim's own bundled runtime Lua (its default keymaps among them, defined in
-- runtime/lua/vim/_core/defaults.lua) loads under a virtual "@vim/..." module-style
-- debug source; a user's init.lua or an installed plugin's Lua file always shows a real
-- filesystem path instead ("@/home/.../init.lua", "@/.../lazy/<plugin>/lua/...").
--
-- Only Lua-callback mappings can be identified as built-ins this way; a
-- foreign mapping with no callback (plain rhs, legacy :map) is never
-- treated as one -- an unresolvable case fails toward the more visible
-- WARN below, not toward INFO.
local function is_builtin_mapping(map_info)
  if type(map_info) ~= "table" or not map_info.callback then
    return false
  end
  local resolved, src = pcall(function()
    local di = debug.getinfo(map_info.callback, "S")
    return di and di.source
  end)
  return resolved and type(src) == "string" and src:match("^@vim/") ~= nil
end

-- Only the prompt and panel keys of config.options.mappings are checked
-- here: it is the table that ships with real defaults out of the box (e.g. toggle_mode
-- = "<M-t>", terminal-dependent on some setups), so it is the one that can collide with
-- something the user's config or another plugin already bound.
--
-- Buffer-local always wins inside yana's own buffers and never touches anything outside
-- them, so shadowing a Neovim BUILT-IN there is scoped and harmless: INFO, naming the
-- built-in, not WARN. A GLOBAL user/plugin mapping on the same lhs is a real, visible
-- behavior change the moment the user is inside yana's buffer, so that stays WARN.
local function keymap_collision_row()
  local km = config.options.mappings
  local names = {}
  for _, context in ipairs({ "prompt", "panel" }) do
    for _, name in ipairs(require("yana.config_mappings").CONTEXTS[context]) do
      names[#names + 1] = name
    end
  end
  table.sort(names)

  local collisions, shadows, checked = {}, {}, 0
  for _, name in ipairs(names) do
    local lhs = km[name]
    if type(lhs) == "string" and lhs ~= "" then
      checked = checked + 1
      -- mode "" sweeps Normal, Visual, Select and Operator-pending, where
      -- foreign global mappings are most likely to live.
      local map_info = vim.fn.maparg(lhs, "", false, true)
      if type(map_info) == "table" and next(map_info) ~= nil then
        if is_builtin_mapping(map_info) then
          shadows[#shadows + 1] = string.format(
            "mappings.%s (%s) shadows Neovim's built-in %s inside yana's own buffers only (buffer-local); unaffected elsewhere",
            name,
            lhs,
            describe_foreign_map(map_info)
          )
        else
          collisions[#collisions + 1] =
            string.format("mappings.%s (%s) is already mapped to %s", name, lhs, describe_foreign_map(map_info))
        end
      end
    end
  end

  for _, message in ipairs(shadows) do
    info(message)
  end

  if #collisions > 0 then
    warn(
      "panel keymap collision: " .. table.concat(collisions, "; "),
      { "rebind the colliding entries with require('yana').setup({ mappings = { ... } }), or change the foreign mapping" }
    )
  elseif #shadows == 0 then
    ok("no panel keymap collisions detected (" .. checked .. " configured keymaps checked)")
  end
end

-- A plugin cannot ship someone else's completion config for them, so this is docs + an
-- INFO row naming exactly what degrades without that private setup, never a shipped
-- default.
local function completion_menu_row()
  local lhs = config.options.mappings.completion_menu
  if not lhs or lhs == false then
    return
  end
  local found = pcall(require, "blink.cmp")
  if not found then
    info(
      "blink.cmp not found: mappings.completion_menu ('"
        .. tostring(lhs)
        .. "') opens nothing (harmless no-op) — yana ships no completion UI of its own, so slash-command "
        .. "and @mention completion popups are unavailable without blink.cmp installed"
    )
    return
  end
  info(
    "blink.cmp found, but yana ships no completion source/provider registration of its own — it relies on "
      .. "YOUR blink.cmp config to scope suggestions to yana's prompt buffer (vim.b.yana_prompt). Without a "
      .. "b:yana_prompt-aware provider config, mappings.completion_menu ('"
      .. tostring(lhs)
      .. "') may open blink's default (unrelated) providers, and blink's own InsertEnter autocmd may "
      .. "re-claim the same chord for its default action."
  )
end

-- Absence of a known-good signal is NOT proof the terminal lacks the capability (tmux,
-- for one, can be configured to pass it through) -- so the caller below treats "not on
-- the allow-list" as "cannot confirm", not "definitely broken", and words the row that
-- way.
local function terminal_may_support_extended_keys()
  if vim.env.TERM == "xterm-kitty" or vim.env.KITTY_WINDOW_ID then
    return true -- kitty
  end
  if vim.env.TERM == "foot" then
    return true -- foot
  end
  if vim.env.TERM_PROGRAM == "WezTerm" or vim.env.WEZTERM_PANE then
    return true -- WezTerm
  end
  if vim.env.TERM_PROGRAM == "ghostty" or vim.env.TERM == "xterm-ghostty" then
    return true -- Ghostty
  end
  return false
end

-- mappings.steer's default ("<C-CR>") is indistinguishable from plain <CR> on many
-- terminals without the Kitty keyboard protocol or an equivalent (config.lua's steer
-- comment; PORT-15). Only fires while the default is still in place — a user who
-- already rebound steer has already solved this themselves.
local function steer_key_row()
  local lhs = config.options.mappings.steer
  if type(lhs) ~= "string" or lhs:lower() ~= "<c-cr>" then
    return
  end
  if terminal_may_support_extended_keys() then
    return
  end
  info(
    "mappings.steer's default ('"
      .. lhs
      .. "') may not be distinguishable from <CR> in this terminal (TERM="
      .. tostring(vim.env.TERM)
      .. "); interrupt-and-steer would then never fire and ordinary submit would run instead. If <C-CR> "
      .. "does not steer for you, rebind it, e.g. require('yana').setup({ keymaps = { steer = '<M-CR>' } })"
  )
end

-- Row 117 (release-audit first-run-experience gap): dependencies.lua's
-- exec:<name> rows and configured_agent_row() only prove a CLI BINARY
-- resolves; they prove nothing about whether the operator is actually
-- SIGNED IN to it. The commonest first-run failure -- binary installed,
-- never authenticated -- produced no :checkhealth row at all and degraded
-- into whatever the vendor CLI happened to print mid-turn.
--
-- Generic over config.options.backends (config.lua's descriptor table) by
-- construction: this function is called once per configured backend name
-- and reads that entry's OPTIONAL `whoami_args`/`auth_login_hint` fields --
-- there is no per-vendor if-chain here, and none is needed for a future
-- vendor to get a row: it declares its probe in data.
--
-- Cheap and non-interactive by construction: `whoami_args` is validated at
-- setup (config.lua's normalize_backends) to be a plain arglist, so the
-- probe below is always exactly `{resolved binary} ++ whoami_args`, run
-- once through dependencies.probe()'s fixed 2s timeout -- never a network
-- turn, never a prompt, never something that can hang :checkhealth.
--
-- Two ways to JUDGE a completed probe, chosen per backend by its
-- (optional) `auth_output_patterns` descriptor -- config.lua's
-- `optional_output_patterns`, generic here too: no per-vendor branch.
--
--
local function backend_auth_row(name, entry)
  local resolution = config.resolve_cmd(name)
  local resolved = vim.fn.exepath(resolution.value)
  if resolved == "" then
    -- PRERELEASE-0.1.0-alpha.5-README-audit.md defect 3: names the vendor's
    -- own install line here too, from the SAME `install_hint` field
    -- dependencies.lua's configured_agent_row() reads for the panel's
    -- missing-binary error -- one remedy table, two consumers, never a
    -- second copy that can drift from the first.
    local install_hint = entry.install_hint
    local remedy = install_hint and ("install " .. name .. " (" .. install_hint .. ")")
      or ("install " .. name .. " (see its own docs -- Yana ships no install_hint for this backend)")
    info(
      "auth (" .. name .. "): unknown — " .. tostring(resolution.value) .. " not found on PATH — " .. remedy
    )
    return
  end
  if not entry.whoami_args then
    info(
      "auth ("
        .. name
        .. "): unknown — this backend declares no auth check (whoami_args), so there is no cheap way to "
        .. "tell whether "
        .. resolved
        .. " is signed in without a real turn"
    )
    return
  end

  local cmd = { resolved }
  vim.list_extend(cmd, entry.whoami_args)
  local args_str = table.concat(entry.whoami_args, " ")
  local ok_probe, result, probe_err = dependencies.probe(cmd, 2000)
  if not ok_probe then
    info("auth (" .. name .. "): unknown — auth probe " .. tostring(probe_err))
    return
  end

  local hint = entry.auth_login_hint
  if type(hint) ~= "string" or hint == "" then
    hint = "run " .. resolved .. "'s own login/auth command (see its --help or docs)"
  end

  local patterns = entry.auth_output_patterns
  if patterns then
    -- Exit code is not trusted at all for this backend (that is exactly
    -- why it declared this field -- e.g. cursor-agent's `status` exits 0
    -- regardless of auth state): judge captured output only.
    local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
    local matched_in = patterns.signed_in ~= nil and output:find(patterns.signed_in) ~= nil
    local matched_out = patterns.signed_out ~= nil and output:find(patterns.signed_out) ~= nil
    if matched_in and not matched_out then
      ok("auth (" .. name .. "): signed in (" .. resolved .. " " .. args_str .. ", output matched signed-in pattern)")
      return
    elseif matched_out and not matched_in then
      warn(
        "auth ("
          .. name
          .. "): NOT signed in ("
          .. resolved
          .. " "
          .. args_str
          .. ", output matched signed-out pattern)",
        { hint }
      )
      return
    end
    local reason = (matched_in and matched_out) and "matched BOTH declared patterns" or "matched NEITHER declared pattern"
    info(
      "auth ("
        .. name
        .. "): unknown — "
        .. resolved
        .. " "
        .. args_str
        .. " output "
        .. reason
        .. " (declared auth_output_patterns); ambiguous output is never guessed"
    )
    return
  end

  if result.code == 0 then
    ok("auth (" .. name .. "): signed in (" .. resolved .. " " .. args_str .. ")")
    return
  end
  warn(
    "auth ("
      .. name
      .. "): NOT signed in ("
      .. resolved
      .. " "
      .. args_str
      .. " exited "
      .. tostring(result.code)
      .. ")",
    { hint }
  )
end

-- One row per configured backend name, sorted so the output order is
-- deterministic across runs regardless of Lua table iteration order.
local function backend_auth_rows()
  local names = {}
  for backend_name in pairs(config.options.backends or {}) do
    names[#names + 1] = backend_name
  end
  table.sort(names)
  for _, backend_name in ipairs(names) do
    backend_auth_row(backend_name, config.options.backends[backend_name])
  end
end

-- yana_ui (public repo drusmanbashir/yana-ui) is a hard dependency:
-- lua/yana/ui_grid.lua is "return require('yana_ui.grid')" with no
-- fallback, so its absence makes parts of the review UI raise rather than
-- merely degrade. That makes it an ERROR row, unlike the optional-plugin
-- rows above (completion_menu_row et al.), which only ever info/warn.
local function yana_ui_row()
  if pcall(require, "yana_ui") then
    ok("yana_ui found: UI grid dependency satisfied")
    return
  end
  err(
    "yana_ui not found — parts of yana's UI (lua/yana/ui_grid.lua) require it and will raise without it",
    { "add 'drusmanbashir/yana-ui' as a plugin dependency" }
  )
end

-- Run :checkhealth yana: deps, auth, keymaps, mode, log, and env checks.
function M.check()
  start("yana")

  yana_ui_row()

  for _, item in ipairs(dependencies.check(config.options.mode)) do
    local body = item.message
    if item.id == "exec:sqlite3" and item.level == "warn" then
      body = tostring(item.message) .. " — external Cursor session titles unavailable"
    end
    local message = string.format("[%s] %s", item.id, body)
    if item.level == "ok" then
      ok(message)
    elseif item.level == "warn" then
      warn(message, item.remedy and { item.remedy } or nil)
    else
      err(message, item.remedy and { item.remedy } or nil)
    end
  end

  backend_auth_rows()
  birth_time_row()
  keymap_collision_row()
  completion_menu_row()
  steer_key_row()

  local mode = config.options.mode
  if mode == "agentic" then
    warn("mode = 'agentic' is active: the agent writes files directly; there is no overlay, review, or diary.")
  elseif mode == "inline" and config.agent_needs_permission_flag() then
    warn(
      "mode = 'inline': the agent runs confined in the overlay and every change is reviewed before it reaches disk, "
        .. "but its argv carries the vendor permission-bypass flag. "
        .. "Your protection is Yana's host-enforced overlay plus review, not the vendor's prompts. See :help yana-security."
    )
  else
    ok("default mode: " .. tostring(mode))
  end
  if mode == "inline" and config.options.sandbox.inline == "vendor-default" then
    local backend = tostring(config.options.backend)
    warn(
      "inline vendor sandbox (" .. backend .. ") inherits its system-wide configuration through sandbox.inline = 'vendor-default'; "
        .. "that vendor configuration may silently narrow Yana's declared write_roots.",
      {
        "Check the " .. backend .. " vendor configuration if a declared root is refused.",
        "Or set sandbox.inline to an explicit vendor-neutral level in require('yana').setup().",
      }
    )
  end
  if config.options.approve_mcps then
    warn("approve_mcps = true: MCP servers are auto-approved (--approve-mcps).")
  end

  local log = require("yana.log")
  if log.durable_healthy() then
    ok("durable log: healthy (" .. log.path .. ")")
  else
    err("durable log: unhealthy — " .. tostring(log.durable_unhealthy_reason() or "unknown"))
  end
end

return M
