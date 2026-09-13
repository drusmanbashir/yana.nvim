-- yana: mode dial + cmd resolution (facade: yana.config).
local M = {}

function M.new(deps)
  local defaults = deps.defaults
  local get_options = deps.get_options
  local backend_descriptor = deps.backend_descriptor

  ----------------------------------------------------------------------
  -- THE MODE DIAL
  --
  -- Nothing below is configurable, because each of these was a way for two settings to
  -- disagree.
  ----------------------------------------------------------------------

  local MODES = { ask = true, inline = true, agentic = true }

  --- Highlight group names for the winbar mode chip (one per named mode).
  local mode_hl_groups = {
    ask = "YanaModeAsk",
    inline = "YanaModeInline",
    agentic = "YanaModeAgentic",
  }
  local model_hl_group = "YanaModel"

  local MODE_HELP = ' — one of "ask" (read and answer), "inline" (hunks you review), "agentic" (the agent edits files itself)'

  -- One mode name, checked against the known modes and the enabled list.
  local function normalize_mode(value, modes)
    modes = modes or get_options().modes or defaults.modes
    if value == nil then
      return modes[1]
    end
    if type(value) ~= "string" or MODES[value] == nil then
      error("yana: invalid config.mode " .. vim.inspect(value) .. MODE_HELP, 0)
    end
    if not vim.tbl_contains(modes, value) then
      if value == "agentic" then
        error(
          'yana: config.mode = "agentic" requires enable_agentic = true (or "agentic" in config.modes) because it writes the real workspace without confinement or review',
          0
        )
      end
      error("yana: config.mode " .. vim.inspect(value) .. " is not in config.modes", 0)
    end
    return value
  end

  --- config.modes from the caller's raw opts. `modes` wins outright; otherwise
  --- the legacy keys translate onto the shipped list: enable_agentic ~= true
  --- drops "agentic", and mode = X moves X to the front.
  local function normalize_modes(opts)
    local list = opts.modes
    if list == nil then
      list = vim.deepcopy(defaults.modes)
      if opts.enable_agentic ~= nil and opts.enable_agentic ~= true then
        list = vim.tbl_filter(function(m)
          return m ~= "agentic"
        end, list)
      end
      if opts.mode ~= nil then
        local first = normalize_mode(opts.mode, list)
        list = vim.tbl_filter(function(m)
          return m ~= first
        end, list)
        table.insert(list, 1, first)
      end
      return list
    end
    if type(list) ~= "table" or not vim.islist(list) or #list == 0 then
      error("yana: config.modes must be a non-empty list of modes, got " .. vim.inspect(list), 0)
    end
    local out, seen = {}, {}
    for _, m in ipairs(list) do
      if type(m) ~= "string" or MODES[m] == nil then
        error("yana: invalid config.modes entry " .. vim.inspect(m) .. MODE_HELP, 0)
      end
      if seen[m] then
        error("yana: config.modes lists " .. vim.inspect(m) .. " twice", 0)
      end
      seen[m] = true
      out[#out + 1] = m
    end
    return out
  end

  --- Whether `mode` may be entered: true when listed in config.modes, false for
  --- a known mode that is not listed, nil for a name that is not a mode.
  local function mode_enabled(mode)
    local m = ({ plan = "ask", review = "inline" })[mode] or mode
    if type(m) ~= "string" or MODES[m] == nil then
      return nil
    end
    return vim.tbl_contains(get_options().modes or defaults.modes, m)
  end

  --- WHERE THE AGENT RUNS. True for every mode that starts the agent under the
  --- harness -- `ask` and `inline` -- and false only for `agentic`, which is the
  --- direct surface that the public safety contract places outside containment.
  ---
  --- This answered `inline` only until that date, so an `ask` turn ran the agent
  --- against the real tree with `--mode ask` on the argv as its only barrier.
  --- Confinement costs a read-only turn nothing, so the exception was closed rather
  --- than documented.
  local function resolve_mode(mode)
    local options = get_options()
		local m = mode
		if m == nil or m == "" then
			m = options.mode
		end
		-- No remaining caller anywhere in the tree passes the literal string "agent" into
		-- resolve_mode/set_mode (verified: `git grep -n 'set_mode([^,]*, *"agent")'`), so the
		-- alias has nothing legitimate left to serve.
		if m == "agent" then
			error(
				'yana: "agent" is not a yana mode ("ask"/"inline"/"agentic") -- it was removed as an alias for '
					.. '"agentic" because it let a UI view (:YanaEdit) silently flip config.options.mode instead of '
					.. "reading it. If you meant the confinement dial, pass \"agentic\" explicitly; if you meant "
					.. "cursor-agent's own --mode value, see agent_permission_mode; if you meant \"a panel that can "
					.. 'produce an edit", see M.panel_write_capable (ui.lua).',
				0
			)
		elseif m == "plan" then
			m = "ask"
		elseif m == "review" then
			m = "inline"
		end
		if MODES[m] ~= nil then
			if m == "agentic" and not vim.tbl_contains(options.modes or defaults.modes, "agentic") then
				return "inline"
			end
			return m
		end
		return options.mode
  end

  -- True when resolved mode is ask/inline (agent runs under the overlay).
  local function overlay_mode(mode)
		local m = resolve_mode(mode)
		return m == "inline" or m == "ask"
  end

  --- WHO WRITES. Does this mode open hunk reviews and accept through the
  --- journaled applier? `inline` only.
  ---
  --- Welding them together is what made confinement conditional on there being
  --- something to review.
  local function review_mode_active(mode)
		return resolve_mode(mode) == "inline"
  end

  --- The cursor-agent permission mode. An internal consequence of the dial, never
  --- a user-facing option.
  local function agent_permission_mode(mode)
		if resolve_mode(mode) == "ask" then
			return "ask"
		end
		return "agent"
  end

  --- Whether this turn's argv carries the vendor permission-bypass flag.
  ---
  --- THIS FUNCTION IS THE ENTIRE DECISION. The boundary is the overlay the agent is
  --- confined in plus the hunk review gating every real-tree write -- neither is
  --- affected by this flag. Dropping it would surrender all editing (non-force tool
  --- calls need an approval a headless `-p` turn has nobody to answer) and buy no
  --- security.
  ---
  --- Revisit trigger: the capsule shipping, or a pinned cursor-agent release
  --- demonstrating a non-interactive non-force edit -- whichever comes first.
  --- When that lands, this returns false and nothing else changes. Every caller
  --- asks this function rather than reading a flag, precisely so the reversal is
  --- one line here.
  local function agent_needs_permission_flag(mode)
		return resolve_mode(mode) ~= "ask"
  end



  --- `cmd_env` is either a non-empty string (the env var name) or `false`
  --- (step 2 disabled). Anything else falls back to the shipped default name
  --- rather than silently disabling env indirection on a typo.
  local function normalize_cmd_env(value)
    if value == false then
      return false
    end
    if type(value) == "string" and value ~= "" then
      return value
    end
    return defaults.cmd_env
  end

  --- Read an environment variable the way `resolve_cmd` needs to: Neovim's
  --- `getenv()` answers an unset variable with `vim.NIL` (or plain `nil`,
  --- depending on version) rather than Lua `nil`, so callers that only check
  --- `~= nil` get fooled. Every other case (unset, set-but-empty) is folded to
  --- Lua `nil` here so callers have exactly one falsy shape to handle.
  local function getenv(name)
    local v = vim.fn.getenv(name)
    if v == nil or v == vim.NIL or v == "" then
      return nil
    end
    return v
  end

  --- THE machine-specific resolution contract for the agent binary (avante.nvim's
  --- `api_key_name` indirection, applied to a binary path instead of a secret --
  --- see the `cmd`/`cmd_env` comments in defaults above for the citation).
  --- Every consumer that needs to spawn or probe cursor-agent asks THIS
  --- function -- never `config.options.cmd` directly -- so there is exactly one
  --- place precedence is decided and exactly one place `~` gets expanded.
  ---
  --- Precedence, first match wins: an explicit cursor `cmd` or overridden backend
  --- command; the environment variable named by backends.<name>.cmd_env; the shipped
  --- backend command; the legacy cursor cmd_env; then cursor-agent on PATH.
  ---
  --- Returns a table: step "config" | "backend_cmd_env" | "backend" |
  --- "backend_bundled" | "cmd_env" | "path" -- which step resolved. value
  --- the resolved command string to spawn or probe. candidates every step considered,
  --- in order, for diagnostics (health rows, error messages): each entry is { step,
  --- tried = bool, raw?, expanded?, env_name?, note?
  local function plugin_root()
    return debug.getinfo(1, "S").source:sub(2):gsub("/lua/yana/[^/]+%.lua$", "")
  end

  local function bundled_bin(bare_name)
    if type(bare_name) ~= "string" or bare_name == "" or bare_name:find("/", 1, true) then
      return nil
    end
    local candidate = plugin_root() .. "/bin/" .. bare_name
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
    return nil
  end

  local function resolve_backend_cmd(active, entry, candidates)
    local expanded = vim.fn.expand(entry.cmd)
    if not expanded:find("/", 1, true) then
      local bundled = bundled_bin(expanded)
      if bundled then
        candidates[#candidates + 1] = {
          step = "backend_bundled",
          backend = active,
          tried = true,
          raw = entry.cmd,
          expanded = bundled,
        }
        return { step = "backend_bundled", value = bundled, backend = active, candidates = candidates }
      end
    end
    candidates[#candidates + 1] =
      { step = "backend", backend = active, tried = true, raw = entry.cmd, expanded = expanded }
    return { step = "backend", value = expanded, backend = active, candidates = candidates }
  end

  --- Resolve the spawn binary for `backend_name` (default: the active backend).
  --- Prefetch / list_models for a non-active vendor MUST pass that vendor's
  --- name — otherwise argv would mix one binary with another's list flags.
  local function resolve_cmd(backend_name)
    local options = get_options()
    local candidates = {}
    local active = backend_name or options.backend or defaults.backend
    local entry = backend_descriptor(active) or {}

    -- Preserve the original cursor-only explicit override as the strongest choice.
    -- Other shipped backends carry their command in the descriptor below.
    if entry.cmd == nil then
      local explicit = options.cmd
      if type(explicit) == "string" and explicit ~= "" then
        local expanded = vim.fn.expand(explicit)
        candidates[#candidates + 1] = { step = "config", tried = true, raw = explicit, expanded = expanded }
        return { step = "config", value = expanded, backend = active, candidates = candidates }
      end
      candidates[#candidates + 1] = { step = "config", tried = false, note = "cmd not set in setup()" }
    end

    local shipped_entry = defaults.backends and defaults.backends[active] or nil
    local cmd_is_override = type(entry.cmd) == "string"
      and entry.cmd ~= ""
      and (shipped_entry == nil or entry.cmd ~= shipped_entry.cmd)
    if cmd_is_override then
      return resolve_backend_cmd(active, entry, candidates)
    end

    local backend_env_name = entry.cmd_env
    if type(backend_env_name) == "string" and backend_env_name ~= "" then
      local backend_env_value = getenv(backend_env_name)
      if backend_env_value then
        local expanded = vim.fn.expand(backend_env_value)
        candidates[#candidates + 1] = {
          step = "backend_cmd_env",
          backend = active,
          tried = true,
          env_name = backend_env_name,
          raw = backend_env_value,
          expanded = expanded,
        }
        return { step = "backend_cmd_env", value = expanded, backend = active, candidates = candidates }
      end
      candidates[#candidates + 1] = {
        step = "backend_cmd_env",
        backend = active,
        tried = false,
        env_name = backend_env_name,
        note = "$" .. backend_env_name .. " is not set",
      }
    end

    -- A backend whose entry names a `cmd` (every shipped entry except "cursor", and
    -- any operator override of it) follows its optional environment override -- already
    -- validated executable (or PATH-deferred, see the defaults.backends doc comment) at
    -- setup, so there is nothing left to try. Only "cursor" with `cmd = nil` falls
    -- through to the historical config/cmd_env/PATH chain below, which is what keeps
    -- the default byte-identical to pre-backends Yana.
    if type(entry.cmd) == "string" and entry.cmd ~= "" then
      return resolve_backend_cmd(active, entry, candidates)
    end
    candidates[#candidates + 1] =
      { step = "backend", backend = active, tried = false, note = "backends." .. active .. ".cmd not set; using the cmd/cmd_env/PATH chain" }

    local env_name = options.cmd_env
    if env_name == false then
      candidates[#candidates + 1] = { step = "cmd_env", tried = false, note = "cmd_env disabled (set to false)" }
    elseif type(env_name) == "string" and env_name ~= "" then
      local env_val = getenv(env_name)
      if env_val then
        local expanded = vim.fn.expand(env_val)
        candidates[#candidates + 1] =
          { step = "cmd_env", tried = true, env_name = env_name, raw = env_val, expanded = expanded }
        return { step = "cmd_env", value = expanded, backend = active, candidates = candidates }
      end
      candidates[#candidates + 1] =
        { step = "cmd_env", tried = false, env_name = env_name, note = "$" .. env_name .. " is not set" }
    else
      candidates[#candidates + 1] = { step = "cmd_env", tried = false, note = "cmd_env disabled" }
    end

    candidates[#candidates + 1] = { step = "path", tried = true, raw = "cursor-agent", expanded = "cursor-agent" }
    return { step = "path", value = "cursor-agent", backend = active, candidates = candidates }
  end

  --- Convenience for hot paths that only need the resolved string (agent spawn,
  --- --list-models). Diagnostics that need to explain THEMSELVES (health rows,
  --- refusal messages) call resolve_cmd() directly for the full candidate
  --- list.
  local function cmd(backend_name)
    return resolve_cmd(backend_name).value
  end

  return {
    normalize_mode = normalize_mode,
    normalize_modes = normalize_modes,
    mode_enabled = mode_enabled,
    resolve_mode = resolve_mode,
    overlay_mode = overlay_mode,
    review_mode_active = review_mode_active,
    agent_permission_mode = agent_permission_mode,
    agent_needs_permission_flag = agent_needs_permission_flag,
    normalize_cmd_env = normalize_cmd_env,
    resolve_cmd = resolve_cmd,
    cmd = cmd,
    mode_hl_groups = mode_hl_groups,
    model_hl_group = model_hl_group,
  }
end

return M
