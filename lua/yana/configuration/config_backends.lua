-- yana: backend zoo validation / normalize (facade: yana.config).
local M = {}

function M.new(deps)
  local defaults = deps.defaults
  local home_dir = deps.home_dir
  local get_options = deps.get_options

  -- Tokens Yana itself places at a fixed point via `resume_flag`/
  -- `select_model_flag`. No OTHER capability list may contain them -- an
  -- entry that tried would let its own "ask" or "allow_edits" or
  -- "list_models" spelling silently add a second, entry-controlled --resume
  -- or --model that could disagree with the one Yana placed. This is the
  -- "cross-field collision" check named in the schema's own doc comment.
  local RESERVED_TOKENS = { ["--resume"] = true, ["--model"] = true }

  local function check_no_reserved_tokens(list, backend_name, field)
    for _, tok in ipairs(list) do
      if RESERVED_TOKENS[tok] then
        error(
          "yana: backends." .. backend_name .. "." .. field .. " contains " .. tok
            .. " -- that token is placed by Yana itself (resume_flag/select_model_flag), "
            .. "never by another capability list",
          0
        )
      end
    end
  end

  -- REQUIRED list-of-strings capability. `nil` is always a setup refusal here
  -- (unlike the OPTIONAL capabilities below) -- every field this validates is
  -- one build_cmd cannot safely omit (see the schema's governing-rule doc
  -- comment). An empty list `{}` is legal: it says "this vendor needs no
  -- extra token for this capability", which is different from not declaring
  -- the capability at all.
  local function require_arglist(value, backend_name, field)
    if value == nil then
      error(
        "yana: backends." .. backend_name .. "." .. field .. " is required (Yana needs it to know how to spell "
          .. "this capability for this vendor) -- refused at setup, not discovered at turn time",
        0
      )
    end
    if type(value) ~= "table" then
      error("yana: backends." .. backend_name .. "." .. field .. " must be a list of strings", 0)
    end
    local out = {}
    for i, v in ipairs(value) do
      if type(v) ~= "string" or v == "" then
        error("yana: backends." .. backend_name .. "." .. field .. "[" .. i .. "] must be a non-empty string", 0)
      end
      out[#out + 1] = v
    end
    return out
  end

  -- OPTIONAL list-of-strings capability. `nil` is a legitimate, permanent
  -- answer ("this vendor has no such capability"), never a gap to patch --
  -- build_cmd omits the corresponding argv entirely when it sees nil.
  local function optional_arglist(value, backend_name, field)
    if value == nil then
      return nil
    end
    return require_arglist(value, backend_name, field)
  end

  -- OPTIONAL single-flag capability (`select_model_flag`, `resume_flag`):
  -- exactly one token, because both are always "flag followed by one value"
  -- shaped for both shipped vendors -- unlike the multi-token capabilities
  -- above, there is nothing here for a vendor to spell with more than one
  -- token, so this stays a plain string rather than a list.
  local function optional_flag(value, backend_name, field)
    if value == nil then
      return nil
    end
    if type(value) ~= "string" or value == "" then
      error("yana: backends." .. backend_name .. "." .. field .. " must be a non-empty string, or nil", 0)
    end
    return value
  end

  -- REQUIRED single-flag capability (`noninteractive_flag`): every vendor
  -- must have some way to say "don't wait for an interactive answer", or a
  -- headless turn against it will hang with nobody to notice why.
  local function require_flag(value, backend_name, field)
    if value == nil or value == "" or type(value) ~= "string" then
      error(
        "yana: backends." .. backend_name .. "." .. field .. " is required and must be a non-empty string "
          .. "(Yana needs to know how this vendor spells \"run non-interactively\")",
        0
      )
    end
    return value
  end

  -- Work order VENDORS -- the closed set of event protocols Yana's stream
  -- reader actually implements. `stream_protocol` SELECTS from this set; it
  -- never supplies behaviour (the governing rule, see the schema doc comment).
  local STREAM_PROTOCOLS = { cursor = true, claude = true, codex = true }

  -- Work order VENDORS -- the literal request token VALIDATED inside `stream_json_args`
  -- for each protocol.
  local PROTOCOL_STREAM_TOKEN = { cursor = "stream-json", claude = "stream-json", codex = "json" }

  -- Work order VENDORS -- the closed set of `list_models_args` output shapes
  -- M.list_models (agent.lua) knows how to parse.
  local LIST_MODELS_FORMATS = { lines = true, json_models = true }
  local STEER_CHANNELS = { ["stream-json"] = true, ["app-server"] = true }
  local MODE_SWITCHES = { per_turn = true, two_seat = true }
  local REQUIRED_SEATS = {
    ask = { "ask" },
    edit = { "inline", "agentic" },
  }
  local SANDBOX_LEVELS = { "full", "workspace", "read-only", "vendor-default" }

  -- Vendor sandbox levels: missing translation is
  -- a setup refusal, never a silent fallback to another level.
  local function require_sandbox_args(value, backend_name)
    if type(value) ~= "table" then
      error("yana: backends." .. backend_name .. ".sandbox_args is required and must map every Yana sandbox level", 0)
    end
    local out = {}
    local known = {}
    for _, level in ipairs(SANDBOX_LEVELS) do
      known[level] = true
      out[level] = require_arglist(value[level], backend_name, "sandbox_args." .. level)
      check_no_reserved_tokens(out[level], backend_name, "sandbox_args." .. level)
    end
    for level in pairs(value) do
      if not known[level] then
        error("yana: backends." .. backend_name .. ".sandbox_args." .. tostring(level) .. " is not a Yana sandbox level", 0)
      end
    end
    return out
  end

  local function require_sandbox_stamps(value, backend_name, sandbox_args)
    local has_tokens = false
    for _, level in ipairs(SANDBOX_LEVELS) do
      has_tokens = has_tokens or #sandbox_args[level] > 0
    end
    if not has_tokens and value == nil then
      return {}
    end
    if value == nil then
      for _, level in ipairs(SANDBOX_LEVELS) do
        if #sandbox_args[level] > 0 then
          error(
            "yana: backends." .. backend_name .. ".sandbox_args_stamps." .. level
              .. " is required because that level declares vendor tokens",
            0
          )
        end
      end
    end
    if type(value) ~= "table" then
      error("yana: backends." .. backend_name .. ".sandbox_args_stamps must be a table", 0)
    end
    if not has_tokens and next(value) == nil then
      return {}
    end
    local out = {}
    for _, level in ipairs(SANDBOX_LEVELS) do
      local stamp = value[level]
      if type(stamp) ~= "table"
        or type(stamp.measured_on) ~= "string"
        or not stamp.measured_on:match("^%d%d%d%d%-%d%d%-%d%d$")
        or type(stamp.vendor_version) ~= "string"
        or stamp.vendor_version == ""
      then
        error(
          "yana: backends." .. backend_name .. ".sandbox_args_stamps." .. level
            .. " must contain measured_on=YYYY-MM-DD and a non-empty vendor_version",
          0
        )
      end
      out[level] = { measured_on = stamp.measured_on, vendor_version = stamp.vendor_version }
    end
    return out
  end

  -- OPTIONAL declared sub-model catalogue (`models`): a vendor with no
  -- listing surface at all (claude) still needs SOME way to offer choices in
  -- the picker. A non-table entry or an empty id is refused at setup, not
  -- discovered as a blank picker entry at turn time.
  local function optional_model_list(value, backend_name)
    if value == nil then
      return nil
    end
    if type(value) ~= "table" then
      error("yana: backends." .. backend_name .. ".models must be a list of {id=..., label=...} tables, or nil", 0)
    end
    local out = {}
    for i, m in ipairs(value) do
      if type(m) ~= "table" or type(m.id) ~= "string" or m.id == "" then
        error(
          "yana: backends." .. backend_name .. ".models[" .. i .. "] must be a table with a non-empty string id",
          0
        )
      end
      local label = m.label
      if type(label) ~= "string" or label == "" then
        label = m.id
      end
      out[#out + 1] = { id = m.id, label = label }
    end
    return out
  end

  -- OPTIONAL auth-probe output discriminator (`auth_output_patterns`): the vendor whose
  -- exit code cannot be trusted at all (cursor-agent `status` exits 0 either way) still
  -- needs a way to judge signed-in vs signed-out from captured output, without a
  -- per-vendor branch in health.lua. At least one of signed_in/signed_out must be
  -- declared; each, when declared, must compile as a Lua pattern -- caught here, at
  -- setup, rather than as a silent "unknown" the first time an operator runs
  local function optional_output_patterns(value, backend_name, field)
    if value == nil then
      return nil
    end
    if type(value) ~= "table" then
      error(
        "yana: backends." .. backend_name .. "." .. field .. " must be a table "
          .. '{ signed_in = "<lua pattern>", signed_out = "<lua pattern>" } (at least one key), or nil',
        0
      )
    end
    if value.signed_in == nil and value.signed_out == nil then
      error(
        "yana: backends." .. backend_name .. "." .. field .. " must declare at least one of signed_in/signed_out "
          .. "-- a discriminator with neither key can never distinguish anything",
        0
      )
    end
    local out = {}
    for _, key in ipairs({ "signed_in", "signed_out" }) do
      local v = value[key]
      if v ~= nil then
        if type(v) ~= "string" or v == "" then
          error(
            "yana: backends." .. backend_name .. "." .. field .. "." .. key
              .. " must be a non-empty string (a Lua pattern), or absent",
            0
          )
        end
        local compiles = pcall(string.find, "", v)
        if not compiles then
          error(
            "yana: backends." .. backend_name .. "." .. field .. "." .. key
              .. " is not a valid Lua pattern: " .. v,
            0
          )
        end
        out[key] = v
      end
    end
    return out
  end

  --- The "zoo" table. Merges `value` onto the shipped
  --- defaults with `vim.tbl_deep_extend("force", ...)` -- an operator entry with a name
  --- already shipped here (e.g. overriding just `claude.cmd`) extends that entry
  --- field-by-field; a genuinely new name (their own vendor) is added whole.
  ---
  --- Every capability is validated for SHAPE here (right type, non-empty, contains what
  --- Yana's own parser/placement logic depends on).
  local function normalize_backends(value)
    local base = vim.deepcopy(defaults.backends)
    local out = base
    if type(value) == "table" then
      out = vim.tbl_deep_extend("force", base, value)
    elseif value ~= nil then
      error("yana: backends must be a table of named entries", 0)
    end
    for name, entry in pairs(out) do
      if type(name) ~= "string" or name == "" then
        error("yana: backends table keys must be non-empty backend names", 0)
      end
      if type(entry) ~= "table" then
        error("yana: backends." .. name .. " must be a table", 0)
      end
      if entry.cmd ~= nil then
        if type(entry.cmd) ~= "string" or entry.cmd == "" then
          error("yana: backends." .. name .. ".cmd must be a non-empty string, or nil", 0)
        end
        if entry.cmd:find("/", 1, true) or entry.cmd:sub(1, 1) == "~" then
          local resolved = vim.fn.expand(entry.cmd)
          if vim.fn.executable(resolved) ~= 1 then
            error("yana: backends." .. name .. ".cmd is not executable: " .. resolved, 0)
          end
          entry.cmd = resolved
        end
      elseif name ~= "cursor" then
        error(
          'yana: backends.' .. name .. '.cmd must be set (only the built-in "cursor" backend may omit it, '
            .. "to keep the pre-backends cmd/cmd_env/PATH chain)",
          0
        )
      end
      if entry.cmd_env ~= nil and (type(entry.cmd_env) ~= "string" or entry.cmd_env == "") then
        error("yana: backends." .. name .. ".cmd_env must be a non-empty environment variable name, or nil", 0)
      end

      -- Work order VENDORS: `subcommand` is validated BEFORE
      -- `noninteractive_flag` because a `false` noninteractive_flag's own
      -- legality depends on whether a non-empty subcommand was declared.
      entry.subcommand = optional_arglist(entry.subcommand, name, "subcommand")

      if entry.noninteractive_flag == false then
        if not entry.subcommand or #entry.subcommand == 0 then
          error(
            "yana: backends." .. name .. ".noninteractive_flag = false requires a non-empty subcommand "
              .. "(false means \"this vendor's subcommand IS its non-interactive mode\") -- refused at "
              .. "setup: without one, a turn would run interactively and hang with nobody there to answer it",
            0
          )
        end
      else
        entry.noninteractive_flag = require_flag(entry.noninteractive_flag, name, "noninteractive_flag")
      end

      if entry.stream_protocol == nil then
        entry.stream_protocol = "cursor"
      elseif type(entry.stream_protocol) ~= "string" or not STREAM_PROTOCOLS[entry.stream_protocol] then
        local names = {}
        for known in pairs(STREAM_PROTOCOLS) do
          names[#names + 1] = known
        end
        table.sort(names)
        error(
          "yana: backends." .. name .. ".stream_protocol " .. vim.inspect(entry.stream_protocol)
            .. " is not a protocol Yana implements -- must be one of: " .. table.concat(names, ", "),
          0
        )
      end

      entry.stream_json_args = require_arglist(entry.stream_json_args, name, "stream_json_args")
      local want_token = PROTOCOL_STREAM_TOKEN[entry.stream_protocol]
      local has_token = false
      for _, tok in ipairs(entry.stream_json_args) do
        -- want_token.
        if tok == want_token or tok == ("--" .. want_token) then
          has_token = true
        end
      end
      if not has_token then
        error(
          "yana: backends." .. name .. ".stream_json_args must contain the token \"" .. want_token
            .. "\" -- that is the " .. entry.stream_protocol .. " protocol's own request token, and an "
            .. "entry requesting a different one would leave every turn producing no visible output",
          0
        )
      end

      if type(entry.mode_switch) ~= "string" or not MODE_SWITCHES[entry.mode_switch] then
        error(
          "yana: backends." .. name .. ".mode_switch " .. vim.inspect(entry.mode_switch)
            .. " is required and must be one of: per_turn, two_seat -- refused at setup",
          0
        )
      end
      if entry.mode_switch == "per_turn" then
        if entry.seats ~= nil then
          error(
            "yana: backends." .. name .. ".seats is forbidden when mode_switch is \"per_turn\" -- refused at setup",
            0
          )
        end
      else
        if type(entry.seats) ~= "table" then
          error(
            "yana: backends." .. name .. ".seats is required when mode_switch is \"two_seat\" -- refused at setup",
            0
          )
        end
        for seat, modes in pairs(REQUIRED_SEATS) do
          if type(entry.seats[seat]) ~= "table" then
            error(
              "yana: backends." .. name .. ".seats." .. seat
                .. " must list the modes assigned to that seat -- refused at setup",
              0
            )
          end
          for i, mode in ipairs(modes) do
            if entry.seats[seat][i] ~= mode then
              error(
                "yana: backends." .. name .. ".seats." .. seat .. " must contain mode \"" .. mode
                  .. "\" at position " .. i .. " -- refused at setup",
                0
              )
            end
          end
        end
      end

      entry.allow_edits_args = require_arglist(entry.allow_edits_args, name, "allow_edits_args")
      check_no_reserved_tokens(entry.allow_edits_args, name, "allow_edits_args")

      entry.sandbox_args = require_sandbox_args(entry.sandbox_args, name)
      entry.sandbox_args_stamps = require_sandbox_stamps(entry.sandbox_args_stamps, name, entry.sandbox_args)

      entry.ask_args = optional_arglist(entry.ask_args, name, "ask_args")
      if entry.ask_args then
        check_no_reserved_tokens(entry.ask_args, name, "ask_args")
      end

      -- `false` and `nil` are the same answer ("unsupported"); normalize the
      -- sentinel form to nil so every other consumer only has one falsy shape
      -- to check (M.resolve_cmd's own `getenv` helper follows the same rule).
      if entry.list_models_args == false then
        entry.list_models_args = nil
      end
      entry.list_models_args = optional_arglist(entry.list_models_args, name, "list_models_args")
      if entry.list_models_args then
        check_no_reserved_tokens(entry.list_models_args, name, "list_models_args")
      end

      if entry.list_models_format == nil then
        entry.list_models_format = "lines"
      elseif type(entry.list_models_format) ~= "string" or not LIST_MODELS_FORMATS[entry.list_models_format] then
        local names = {}
        for known in pairs(LIST_MODELS_FORMATS) do
          names[#names + 1] = known
        end
        table.sort(names)
        error(
          "yana: backends." .. name .. ".list_models_format " .. vim.inspect(entry.list_models_format)
            .. " is not a format Yana implements -- must be one of: " .. table.concat(names, ", "),
          0
        )
      end

      -- `false` and `nil` are the same answer ("no cheap auth probe"),
      -- normalized to nil the same way list_models_args is above.
      if entry.whoami_args == false then
        entry.whoami_args = nil
      end
      entry.whoami_args = optional_arglist(entry.whoami_args, name, "whoami_args")
      if entry.whoami_args then
        check_no_reserved_tokens(entry.whoami_args, name, "whoami_args")
      end
      entry.auth_login_hint = optional_flag(entry.auth_login_hint, name, "auth_login_hint")
      entry.install_hint = optional_flag(entry.install_hint, name, "install_hint")
      entry.auth_output_patterns = optional_output_patterns(entry.auth_output_patterns, name, "auth_output_patterns")

      entry.models = optional_model_list(entry.models, name)

      -- Accepted steering transports.
      if entry.steer_channel ~= nil then
        if type(entry.steer_channel) ~= "string" or not STEER_CHANNELS[entry.steer_channel] then
          error(
            "yana: backends." .. name .. ".steer_channel " .. vim.inspect(entry.steer_channel)
              .. ' is not a channel Yana implements -- must be nil, "stream-json", or "app-server"',
            0
          )
        end
      end

      entry.select_model_flag = optional_flag(entry.select_model_flag, name, "select_model_flag")
      entry.resume_flag = optional_flag(entry.resume_flag, name, "resume_flag")
      entry.image_flag = optional_flag(entry.image_flag, name, "image_flag")
      entry.resume_subcommand = optional_arglist(entry.resume_subcommand, name, "resume_subcommand")
      if entry.resume_flag and entry.resume_subcommand then
        error(
          "yana: backends." .. name .. " declares both resume_flag and resume_subcommand -- resume is "
            .. "either a flag or a subcommand for one vendor, never both",
          0
        )
      end

      if entry.close_stdin == nil then
        entry.close_stdin = false
      elseif type(entry.close_stdin) ~= "boolean" then
        error("yana: backends." .. name .. ".close_stdin must be a boolean, or nil", 0)
      end

      -- Validate state_dirs: the paths this backend's vendor CLI writes at startup,
      -- bind-mounted read-write inside the overlay sandbox at their REAL host path (see
      -- the isolation module's own doc, section "Backend state directories"). Paths
      -- outside $HOME, and paths under ~/.ssh, ~/.gnupg or ~/.aws, are refused HERE, at
      -- setup, by name -- so the writable set is fixed before any turn runs and nothing
      -- a turn produces can widen it.
      --
      -- Entries name directories; the launcher creates a missing one. An entry
      -- that must be a FILE (the shipped `claude` entry's ~/.claude.json) is
      -- supported, but is created as an empty file only when its basename
      -- carries an extension -- so a missing ~/.claude.json does not become a
      -- directory where claude expects its config.
      entry.state_dirs = optional_arglist(entry.state_dirs, name, "state_dirs")
      if entry.state_dirs then
        local home = home_dir()
        local protected_prefixes = { "~/.ssh", "~/.gnupg", "~/.aws" }
        for i, dir in ipairs(entry.state_dirs) do
          if type(dir) ~= "string" or dir == "" then
            error("yana: backends." .. name .. ".state_dirs[" .. i .. "] must be a non-empty string", 0)
          end
          local expanded = vim.fn.expand(dir)
          -- Check if path is outside $HOME
          if expanded:sub(1, 1) == "/" and (not home or home == "" or expanded:sub(1, #home) ~= home) then
            error(
              "yana: backends." .. name .. ".state_dirs[" .. i .. "] = " .. vim.inspect(dir)
                .. " is outside $HOME (expanded to " .. expanded .. ") -- refused",
              0
            )
          end
          -- Check if path is under protected directories
          for _, protected in ipairs(protected_prefixes) do
            local protected_expanded = vim.fn.expand(protected)
            if expanded == protected_expanded or expanded:sub(1, #protected_expanded + 1) == protected_expanded .. "/" then
              error(
                "yana: backends." .. name .. ".state_dirs[" .. i .. "] = " .. vim.inspect(dir)
                  .. " is under protected directory " .. protected .. " -- refused",
                0
              )
            end
          end
        end
      end
    end
    return out
  end

  --- The active backend name (layer 1). Must name an entry present in
  --- `backends` -- an unknown name is refused AT SETUP, by name, never at
  --- turn time (mirrors M.normalize_mode's refusal shape).
  local function normalize_backend(value, backends)
    if value == nil or value == "" then
      return defaults.backend
    end
    if type(value) ~= "string" or backends[value] == nil then
      local names = {}
      for name in pairs(backends) do
        names[#names + 1] = name
      end
      table.sort(names)
      error(
        "yana: invalid config.backend "
          .. vim.inspect(value)
          .. " — must name an entry in config.backends: "
          .. table.concat(names, ", "),
        0
      )
    end
    return value
  end

  --- The active backend's descriptor table (already normalized by
  --- M.normalize_backends at setup time). Every consumer that needs to know
  --- HOW to talk to the current backend (agent.lua's build_cmd/list_models)
  --- asks this, never `options.backends[name]` directly, so there is one
  --- place a missing/renamed entry is handled consistently.
  local function backend_descriptor(name)
    local options = get_options()
    name = name or options.backend
    return options.backends and options.backends[name] or nil
  end

  return {
    normalize_backends = normalize_backends,
    normalize_backend = normalize_backend,
    backend_descriptor = backend_descriptor,
  }
end

return M
