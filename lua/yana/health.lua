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

  -- The probe file must be removed on EVERY path out of this function, even
  -- when `stat` itself errors rather than merely returning a non-zero shell
  -- exit -- e.g. an interrupted headless run, where vim.fn.system() can
  -- throw instead of returning. The old code only reached
  -- `pcall(os.remove, path)` AFTER vim.fn.system() had already returned, so
  -- a throw there skipped cleanup entirely and left the dotfile behind (two
  -- such `.yana-birthcheck-*` files were found stray in this repo).
  -- Wrapping the stat call itself in a pcall means the removal below always
  -- runs immediately after, regardless of whether the stat succeeded.
  local stat_ok, out = pcall(vim.fn.system, { "stat", "-c", "%w", path })
  local shell_err = vim.v.shell_error
  pcall(os.remove, path)

  if not stat_ok then
    return nil, "`stat -c %w` failed on " .. dir .. ": " .. tostring(out)
  end
  if shell_err ~= 0 or type(out) ~= "string" then
    return nil, "`stat -c %w` failed on " .. dir
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
-- Neovim's own bundled runtime Lua (its default keymaps among them, defined
-- in runtime/lua/vim/_core/defaults.lua) loads under a virtual "@vim/..."
-- module-style debug source; a user's init.lua or an installed plugin's Lua
-- file always shows a real filesystem path instead ("@/home/.../init.lua",
-- "@/.../lazy/<plugin>/lua/..."). Verified live against Neovim 0.12's stock
-- `<C-s>` default: debug.getinfo(callback, "S").source is exactly
-- "@vim/_core/defaults" (ruling: packets/ADJUDICATIONS-20260820.md #6).
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

-- Only config.options.keymaps (buffer-local panel keymaps, config.lua:134)
-- is checked here: it is the table that ships with real defaults out of the
-- box (e.g. toggle_mode = "<M-t>", terminal-dependent on some setups), so it
-- is the one that can collide with something the user's config or another
-- plugin already bound. config.options.global_keymaps ships nil by default
-- and, when set, is applied globally by require("yana").setup() before this
-- check ever runs — checking it here would flag yana's OWN mapping as a
-- false collision with itself.
--
-- Severity split (ruling #6): EVERY entry here is buffer-local by
-- construction -- ui.lua's apply_panel_keymaps() funnels all of them through
-- its local map() helper, which always passes { buffer = buf } to
-- vim.keymap.set (ui.lua:~3798) -- verified by reading that function, not
-- assumed. Buffer-local always wins inside yana's own buffers and never
-- touches anything outside them, so shadowing a Neovim BUILT-IN there is
-- scoped and harmless: INFO, naming the built-in, not WARN. A GLOBAL
-- user/plugin mapping on the same lhs is a real, visible behavior change
-- the moment the user is inside yana's buffer, so that stays WARN.
local function keymap_collision_row()
  local km = config.options.keymaps or {}
  local names = {}
  for name in pairs(km) do
    names[#names + 1] = name
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
            "keymaps.%s (%s) shadows Neovim's built-in %s inside yana's own buffers only (buffer-local); unaffected elsewhere",
            name,
            lhs,
            describe_foreign_map(map_info)
          )
        else
          collisions[#collisions + 1] =
            string.format("keymaps.%s (%s) is already mapped to %s", name, lhs, describe_foreign_map(map_info))
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
      { "rebind the colliding entries with require('yana').setup({ keymaps = { ... } }), or change the foreign mapping" }
    )
  elseif #shadows == 0 then
    ok("no panel keymap collisions detected (" .. checked .. " configured keymaps checked)")
  end
end

-- PORT-13 (packets/env-portability-adversarial-20260820.md): yana ships no
-- completion PROVIDER of its own -- keymaps.completion_menu's callback
-- (ui.lua) does nothing but `pcall(require, "blink.cmp") and blink.show()`;
-- scoping the resulting menu to yana's two sources (yana_commands,
-- yana_mentions) for the prompt buffer only (vim.b.yana_prompt) is entirely
-- the user's own blink.cmp config's job (config.lua's completion_menu
-- comment). A plugin cannot ship someone else's completion config for them,
-- so this is docs + an INFO row naming exactly what degrades without that
-- private setup, never a shipped default.
local function completion_menu_row()
  local lhs = config.options.keymaps and config.options.keymaps.completion_menu
  if not lhs or lhs == false then
    return
  end
  local found = pcall(require, "blink.cmp")
  if not found then
    info(
      "blink.cmp not found: keymaps.completion_menu ('"
        .. tostring(lhs)
        .. "') opens nothing (harmless no-op) — yana ships no completion UI of its own, so slash-command "
        .. "and @mention completion popups are unavailable without blink.cmp installed"
    )
    return
  end
  info(
    "blink.cmp found, but yana ships no completion source/provider registration of its own — it relies on "
      .. "YOUR blink.cmp config to scope suggestions to yana's prompt buffer (vim.b.yana_prompt). Without a "
      .. "b:yana_prompt-aware provider config, keymaps.completion_menu ('"
      .. tostring(lhs)
      .. "') may open blink's default (unrelated) providers, and blink's own InsertEnter autocmd may "
      .. "re-claim the same chord for its default action."
  )
end

-- Cheapest honest check for whether THIS terminal can tell <C-CR> (Ctrl+
-- Enter) apart from plain <CR>: Neovim has no portable way to positively
-- query the running terminal's keyboard-encoding capability from Lua (that
-- would need an async CSI-u/Kitty-protocol query-and-response with a
-- timeout), so this recognizes a short allow-list of terminals/multiplexer
-- endpoints known to speak the Kitty keyboard protocol or an equivalent
-- extended-key encoding by default. Absence of a known-good signal is NOT
-- proof the terminal lacks the capability (tmux, for one, can be configured
-- to pass it through) -- so the caller below treats "not on the allow-list"
-- as "cannot confirm", not "definitely broken", and words the row that way.
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

-- Ruling #6 (packets/ADJUDICATIONS-20260820.md): a keymap-shaped collision is
-- surfaced via health and documented, never used to change a shipped
-- default. keymaps.steer's default ("<C-CR>") is indistinguishable from
-- plain <CR> on many terminals without the Kitty keyboard protocol or an
-- equivalent (config.lua's steer comment; PORT-15). Only fires while the
-- default is still in place — a user who already rebound steer has already
-- solved this themselves.
local function steer_key_row()
  local lhs = config.options.keymaps and config.options.keymaps.steer
  if type(lhs) ~= "string" or lhs:lower() ~= "<c-cr>" then
    return
  end
  if terminal_may_support_extended_keys() then
    return
  end
  info(
    "keymaps.steer's default ('"
      .. lhs
      .. "') may not be distinguishable from <CR> in this terminal (TERM="
      .. tostring(vim.env.TERM)
      .. "); interrupt-and-steer would then never fire and ordinary submit would run instead. If <C-CR> "
      .. "does not steer for you, rebind it, e.g. require('yana').setup({ keymaps = { steer = '<M-CR>' } })"
  )
end

function M.check()
  start("yana")

  for _, item in ipairs(dependencies.check(config.options.mode)) do
    local message = string.format("[%s] %s", item.id, item.message)
    if item.id == "exec:sqlite3" and item.level ~= "ok" then
      -- dependencies.lua correctly treats sqlite3 as optional (warn, not
      -- error), but a silent optional-dependency miss is exactly how this
      -- degradation went unnoticed: name what is actually lost.
      message = message .. " — external Cursor session titles unavailable without it"
    end
    if item.level == "ok" then
      ok(message)
    elseif item.level == "warn" then
      warn(message, item.remedy and { item.remedy } or nil)
    else
      err(message, item.remedy and { item.remedy } or nil)
    end
  end

  birth_time_row()
  keymap_collision_row()
  completion_menu_row()
  steer_key_row()

  local mode = config.options.mode
  if mode == "agentic" then
    warn("mode = 'agentic': explicit enable_agentic opt-in is active. The agent writes files directly; there is no overlay, review, or diary.")
  elseif mode == "inline" and config.agent_needs_permission_flag() then
    warn(
      "mode = 'inline': the agent runs confined in the overlay and every change is reviewed before it reaches disk, "
        .. "but its argv carries the vendor permission-bypass flag. "
        .. "Your protection is Yana's host-enforced overlay plus review, not the vendor's prompts. See :help yana-security."
    )
  else
    ok("default mode: " .. tostring(mode))
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
