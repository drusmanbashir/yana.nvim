-- yana: vendor presets (slice of config defaults).

----------------------------------------------------------------------
-- BACKENDS -- tested presets. Only the vendors named in setup({ backends }) are
-- enabled (plus the default's preset); each listed field replaces the preset's
-- field, and a name with no preset declares a vendor in full.
--
-- Row 58: model switching has TWO layers.
-- `model` above is layer 2 (which model inside a backend). This is layer
-- 1 (which binary, which account, which bill). `--model claude-4-sonnet`
-- picked INSIDE cursor-agent is Cursor's resale of Claude on Cursor's
-- meter; selecting the `claude` backend here runs the operator's own
-- Anthropic account instead. Two different products; never conflated.
--
-- Every field below is a vendor's TOKEN for a capability YANA decided the turn needs --
-- never a free-form argv list an entry can use to change WHAT the turn is allowed to do
-- or HOW Yana parses it. Concretely, what an entry CANNOT influence, and what enforces
-- each: * that a turn runs non-interactively -- Yana always places
-- `noninteractive_flag` itself, at a fixed position (build_cmd); an entry cannot omit
-- or relocate it, only spell it. * which vendor sandbox/permission posture a turn
--
-- What an entry DOES decide, because it genuinely varies per vendor: the binary; the
-- exact tokens THIS vendor uses to ask for non-interactive mode, stream-json output,
-- edit permission, a named model, a resumed session, ask-mode, and model listing.
--
-- Fields: cmd the binary to spawn. cmd_env names an optional environment override;
-- when it is set and non-empty, its value replaces the shipped bare command name.
-- A path containing "/" or a leading "~" in cmd IS an
-- explicit location and IS checked at setup: the operator wrote a specific file down,
-- and a typo there deserves a named refusal before the first turn. nil is legal ONLY
-- for the built-in "cursor" entry and means "keep using the cmd/cmd_env/PATH chain
-- above unchanged" -- so the default resolution does not depend on the backends table.
--
-- Tokens placed IMMEDIATELY after `cmd`, before every flag Yana adds (build_cmd).
-- `false` with an empty/absent `subcommand` is refused BY NAME at setup -- that
-- combination would run interactively and hang forever with nobody there to answer it.
-- stream_protocol OPTIONAL string, default "cursor".
local backends = {
  cursor = {
    cmd = nil,
    cmd_env = "YANA_CURSOR_BIN",
    noninteractive_flag = "-p",
    stream_json_args = { "--output-format", "stream-json", "--stream-partial-output" },
    mode_switch = "two_seat",
    seats = { ask = { "ask" }, edit = { "inline", "agentic" } },
    sandbox_args = {
      full = { "--force" },
      workspace = { "--force" },
      ["read-only"] = { "--mode", "ask" },
      ["vendor-default"] = {},
    },
    allow_edits_args = {},
    select_model_flag = "--model",
    resume_flag = "--resume",
    ask_args = {},
    list_models_args = { "--list-models" },
    -- VENDOR-AUTH-PROBES.md (verified locally, real HOME + empty-HOME simulation):
    -- `cursor-agent status` is real, fast, non-interactive, no-browser -- but exits 0
    -- in BOTH the signed-in and signed-out state. Judged by exit code alone this probe
    -- cannot distinguish them at all, which is why cursor had no auth row until
    -- auth_output_patterns existed: `--list-models` is the only exit-code-honest
    -- signal, but it is a real network round-trip (disqualified by the "no network
    whoami_args = { "status" },
    auth_login_hint = "cursor-agent login",
    login_args = { "login" },
    auth_env = { "CURSOR_API_KEY" },
    -- README.md and doc/yana.txt carry the same line by hand (docs are not generated
    -- from this table), so keep the three in sync when a vendor changes its installer.
    install_hint = "curl https://cursor.com/install -fsS | bash",
    auth_output_patterns = {
      signed_in = "Logged in as",
      signed_out = "Not logged in",
    },
    -- Directories the backend writes to at startup. These paths are
    -- bind-mounted read-write inside the overlay sandbox; everything else
    -- under $HOME stays read-only. Paths outside $HOME or equal to/under
    -- ~/.ssh, ~/.gnupg, ~/.aws are refused at setup(). Defaults are from
    -- vendor documentation.
    state_dirs = { "~/.cursor", "~/.config/cursor" },
  },
  -- That shim was the PROBE that established these facts; it is not the shipping
  -- mechanism -- this table is.
  claude = {
    cmd = "claude",
    cmd_env = "YANA_CLAUDE_BIN",
    noninteractive_flag = "-p",
    stream_protocol = "claude",
    stream_json_args = { "--output-format", "stream-json", "--verbose" },
    -- inline_mcp: the vendor's spelling of the MCP inline route. args are argv
    -- tokens ("{config}" becomes the generated config path, "{tools}" the mode's list); config is the
    -- document the writer puts the Yana server into. home_env names a private
    -- per-run config home; auth says how a login reaches it: only "none" (a fake
    -- CLI) is implemented, so an undecided backend keeps the overlay route.
    -- read_tools names the read tools in the inline prompt.
    inline_mcp = {
      read_tools = "Yana's read, grep and list_files",
      tools = {
        inline = { "mcp__yana__open_buffer", "mcp__yana__edit_buffer", "mcp__yana__replace_text",
          "mcp__yana__delete_file", "mcp__yana__rename_file", "mcp__yana__read", "mcp__yana__grep", "mcp__yana__list_files" },
        ask = { "mcp__yana__read", "mcp__yana__grep", "mcp__yana__list_files" },
      },
      args = {
        "--restricted", "--strict-mcp-config", "--no-chrome", "--disable-slash-commands",
        "--agents", "{}", "--permission-mode", "dontAsk", "--permission-prompts", "none",
        "--tools", "", "--mcp-config", "{config}",
        "--allowedTools", "{tools}",
      },
      config = { format = "json", servers_key = "mcpServers" },
    },
    mode_switch = "two_seat",
    seats = { protected = { "ask", "inline" }, agentic = { "agentic" } },
    steer_channel = "stream-json",
    sandbox_args = {
      full = { "--permission-mode", "bypassPermissions" },
      workspace = { "--permission-mode", "acceptEdits" },
      ["read-only"] = { "--permission-mode", "plan" },
      ["vendor-default"] = {},
    },
    allow_edits_args = {},
    select_model_flag = "--model",
    -- Hierarchy mode tokens: Claude Code 2.1.251 `claude --help` prints
    -- `--effort <level> … (low, medium, high, xhigh, max)`. Declared once here;
    -- argv builder emits `--effort <level>` only when a level is selected.
    -- No speed/tier flag exists in that help text.
    mode_tokens = {
      effort = {
        kind = "flag",
        flag = "--effort",
        values = { "low", "medium", "high", "xhigh", "max" },
      },
    },
    resume_flag = "--resume",
    -- VENDOR-AUTH-PROBES.md (verified locally, real env + empty-HOME and
    -- unset CLAUDE_CONFIG_DIR): `claude auth status` exits 0 when signed
    -- in, 1 when not -- the exit-code default is honest here, no output
    -- pattern needed.
    whoami_args = { "auth", "status" },
    auth_login_hint = "claude auth login",
    login_args = { "auth", "login" },
    auth_json_field = "loggedIn",
    auth_env = { "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY" },
    -- See the cursor entry's install_hint comment for who consumes this field.
    install_hint = "curl -fsSL https://claude.ai/install.sh | bash",
    -- Probe p6_claude_per_turn.sh, turn c3, verified that -p --resume <id>
    -- --permission-mode plan completes headlessly, refuses workspace writes, and does
    -- not prompt.
    ask_args = {},
    list_models_args = false, -- claude has no --list-models; the picker
                               -- uses the static `models` catalogue below. Static declared
                               -- catalogue (no `claude models` listing).
    models = {
      { id = "auto", label = "let claude choose" },
      { id = "fable", label = "fable" },
      { id = "opus", label = "opus" },
      { id = "sonnet", label = "sonnet" },
      { id = "haiku", label = "haiku" },
    },
    close_stdin = true, -- row 66: a claude turn pays a fixed 3s wait for
                        -- stdin data Yana never sends ("Warning: no stdin data received
                        -- in 3s, proceeding without it"); closing stdin at spawn skips
                        -- that wait outright. Paths the backend writes on its own --
                        -- credentials and settings, its cache (MCP logs) and its lock
                        -- files. They stay writable on the host and never enter review;
                        -- the rest of $HOME is captured (CORE writable host exceptions).
    state_dirs = { "~/.claude", "~/.claude.json", "$XDG_CACHE_HOME/claude-cli-nodejs", "$XDG_STATE_HOME/claude" },
  },
  codex = {
    cmd = "codex",
    cmd_env = "YANA_CODEX_BIN",
    subcommand = { "exec" }, -- non-interactive mode is the `exec`
                              -- SUBCOMMAND, never a flag.
    noninteractive_flag = false, -- `exec` IS the non-interactive mode.
    stream_protocol = "codex",
    -- codex 0.170: --ignore-user-config keeps the operator's CODEX_HOME login but
    -- skips its config.toml (servers, plugins, project trust, so no project
    -- .codex layer). CODEX_HOME/hooks.json still loads, hence --disable hooks;
    -- plugins and apps add servers of their own. "cli" config is -c overrides;
    -- approval_policy never refuses an MCP call unless its tools are "approve".
    -- read-only refuses apply_patch. The shell tool is disabled before launch.
    inline_mcp = {
      read_tools = "Yana's read, grep and list_files",
      tools = {
        inline = { "open_buffer", "edit_buffer", "replace_text", "delete_file", "rename_file", "read", "grep", "list_files" },
        ask = { "read", "grep", "list_files" },
      },
      args = { "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
        "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
        "--disable", "shell_tool", "--disable", "shell_snapshot", "--disable", "unified_exec",
        "--disable", "multi_agent", "--disable", "multi_agent_v2", "--disable", "goals",
        "--disable", "request_permissions_tool", "--disable", "view_image",
        "--disable", "default_mode_request_user_input", "{config}" },
      config = {
        format = "cli", flag = "-c", servers_key = "mcp_servers",
        settings = { sandbox_mode = "read-only", approval_policy = "never", web_search = "disabled" },
        server = { env_vars = { "YANA_MCP_SOCKET", "YANA_MCP_WORKSPACE" },
          enabled_tools = "{tools}",
          default_tools_approval_mode = "approve" },
      },
    },
    stream_json_args = { "--json" }, -- codex's JSONL request token is
                                      -- literally "json", never
                                      -- "stream-json".
    mode_switch = "two_seat",
    seats = { protected = { "ask", "inline" }, agentic = { "agentic" } },
    -- SANDBOX LEVEL IS YANA'S KEY, THE ARGV IS THE VENDOR'S DIALECT. The shared builder
    -- (`agent.lua`'s `build_cmd`) never branches on the backend name; it asks this
    -- table for the tokens of the requested LEVEL. Yana respects whatever level the
    -- operator set and adds no level of its own: in `agentic`, where yana promises to
    -- be a plain wrapper (agentic scope statement), pinning the
    -- vendor's tightest sandbox was yana imposing a confinement it does not admit to.
    --
    -- A vendor may rename or drop a flag between releases, and an unparsed argv is a
    -- turn that dies in 0.0s.
    --
    -- These lists are appended on EVERY turn, resumes included, so turn 1 worked and
    -- every follow-up died in 0.0s. `-c sandbox_mode=<mode>` sets the same config key
    -- `--sandbox` sets and both subcommands accept it. Each built resume argv is parsed
    -- by r_codex_sandbox_argv_accepted_by_vendor.lua.
    sandbox_args = {
      full = { "-c", 'sandbox_mode="danger-full-access"' },
      workspace = { "-c", 'sandbox_mode="workspace-write"' },
      ["read-only"] = { "-c", 'sandbox_mode="read-only"' },
      ["vendor-default"] = {},
    },
    allow_edits_args = { "--skip-git-repo-check" },
    select_model_flag = "--model",
    mode_tokens = {
      reasoning = { kind = "config", key = "model_reasoning_effort" },
      speed = { kind = "config", key = "service_tier" },
    },
    image_flag = "-i",
    resume_subcommand = { "resume" }, -- `codex exec resume <id> ...`; the
    ask_args = { "--skip-git-repo-check" },
    list_models_args = { "debug", "models" },
    list_models_format = "json_models",
    whoami_args = { "login", "status" },
    auth_login_hint = "codex login",
    login_args = { "login" },
    auth_output_patterns = { signed_in = "Logged in using", signed_out = "^%s*Not logged in%s*$" },
    auth_env = { "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN" },
    -- See the cursor entry's install_hint comment for who consumes this field.
    install_hint = "npm install -g @openai/codex",
    close_stdin = true, -- piped stdin makes codex wait to read a
                         -- Directories the backend writes to at startup. These paths
                         -- are bind-mounted read-write inside the overlay sandbox;
                         -- everything else under $HOME stays read-only. Paths outside
                         -- $HOME or equal to/under ~/.ssh, ~/.gnupg, ~/.aws are refused
                         -- at setup().
    state_dirs = { "~/.codex" },
  },
  -- grok 1.0.77, measured 2026-11-15: `--output-format streaming-messages-json`
  -- emits Claude Code's stream-json events, so the claude reader parses it.
  -- `--single` is the headless switch and carries the prompt; the joined
  -- `--single=<prompt>` form keeps a prompt that starts with "-" a value.
  -- `--permission-mode plan` made no workspace write; `acceptEdits` also runs
  -- shell commands. `grok models` exits 0 signed in or out, so its first line
  -- decides auth.
  grok = {
    cmd = "grok",
    cmd_env = "YANA_GROK_BIN",
    noninteractive_flag = false,
    prompt_flag = "--single",
    stream_protocol = "claude",
    stream_json_args = { "--output-format", "streaming-messages-json" },
    -- Use a private Grok config with only the Yana server and explicit tools.
    inline_mcp = {
      auth = "linked",
      home_env = "GROK_HOME",
      native_home = "~/.grok",
      home_links = { ["auth.json"] = "read", sessions = "write" },
      read_tools = "Yana's read, grep and list_files",
      tools = {
        inline = {
          "--allow", "MCPTool(yana__open_buffer)", "--allow", "MCPTool(yana__edit_buffer)",
          "--allow", "MCPTool(yana__replace_text)", "--allow", "MCPTool(yana__delete_file)",
          "--allow", "MCPTool(yana__rename_file)", "--allow", "MCPTool(yana__read)",
          "--allow", "MCPTool(yana__grep)", "--allow", "MCPTool(yana__list_files)",
        },
        ask = {
          "--allow", "MCPTool(yana__read)", "--allow", "MCPTool(yana__grep)", "--allow", "MCPTool(yana__list_files)",
        },
      },
      env = { GROK_CLAUDE_MCPS_ENABLED = "0", GROK_CURSOR_MCPS_ENABLED = "0",
        GROK_CLAUDE_HOOKS_ENABLED = "0", GROK_CURSOR_HOOKS_ENABLED = "0", GROK_WORKFLOWS = "0" },
      args = { "--no-leader", "--no-subagents", "--no-auto-update", "--no-memory", "--sandbox", "off",
        "--tools", "search_tool,use_tool", "--permission-mode", "dontAsk", "{tools}" },
      config = {
        format = "toml", file = "requirements.toml", native_file = "config.toml", servers_key = "mcp_servers",
        settings = { allow_managed_mcp_servers_only = true, allow_managed_hooks_only = true,
          enable_all_project_mcp_servers = false,
          allowed_mcp_servers = { { server_name = "yana" } } },
        server = { env = {
          YANA_MCP_SOCKET = "${YANA_MCP_SOCKET}", YANA_MCP_WORKSPACE = "${YANA_MCP_WORKSPACE}",
        } },
      },
    },
    mode_switch = "two_seat",
    seats = { protected = { "ask", "inline" }, agentic = { "agentic" } },
    sandbox_args = {
      full = { "--permission-mode", "bypassPermissions" },
      workspace = { "--permission-mode", "acceptEdits" },
      ["read-only"] = { "--permission-mode", "plan" },
      ["vendor-default"] = {},
    },
    allow_edits_args = {},
    select_model_flag = "--model",
    resume_flag = "--resume",
    ask_args = {},
    list_models_args = { "models" },
    list_models_format = "bullets",
    whoami_args = { "models" },
    auth_output_patterns = { signed_in = "You are logged in", signed_out = "You are not authenticated" },
    auth_login_hint = "grok login",
    login_args = { "login" },
    auth_env = { "XAI_API_KEY" },
    install_hint = "curl -fsSL https://x.ai/cli/install.sh | bash",
    close_stdin = true,
    state_dirs = { "~/.grok" },
  },
}

return backends
