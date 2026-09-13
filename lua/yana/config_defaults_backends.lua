-- yana: default backends zoo (slice of config defaults).
-- Extracted from yana.config; schema comments travel with the table.

----------------------------------------------------------------------
-- BACKENDS -- the "zoo" the operator stocks (avante.nvim's `providers` table, applied
-- to a CLI agent instead of an HTTP provider: a named entry per vendor, plus a
-- top-level selector). The operator can add their OWN entry in their own setup({}) call
-- and select it immediately -- no plugin change needed -- because M.setup merges
-- `opts.backends` onto these defaults with `vim.tbl_deep_extend("force", ...)`: a new
-- name is added whole, an existing name (e.g. overriding just `claude.cmd`) is extended
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
-- above unchanged" -- this is what makes the default byte-identical to pre-backends
-- Yana.
--
-- Tokens placed IMMEDIATELY after `cmd`, before every flag Yana adds (build_cmd).
-- `false` with an empty/absent `subcommand` is refused BY NAME at setup -- that
-- combination would run interactively and hang forever with nobody there to answer it.
-- stream_protocol OPTIONAL string, default "cursor".
local function sandbox_stamps(vendor_version)
  local function stamp()
    return { measured_on = "2026-08-31", vendor_version = vendor_version }
  end
  return {
    full = stamp(),
    workspace = stamp(),
    ["read-only"] = stamp(),
    ["vendor-default"] = stamp(),
  }
end

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
    sandbox_args_stamps = sandbox_stamps("2026.08.25-3e8eec8"),
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
    mode_switch = "per_turn",
    steer_channel = "stream-json",
    sandbox_args = {
      full = { "--permission-mode", "bypassPermissions" },
      workspace = { "--permission-mode", "acceptEdits" },
      ["read-only"] = { "--permission-mode", "plan" },
      ["vendor-default"] = {},
    },
    sandbox_args_stamps = sandbox_stamps("2.1.251 (Claude Code)"),
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
                        -- that wait outright. Directories the backend writes to at
                        -- startup. These paths are bind-mounted read-write inside the
                        -- overlay sandbox; everything else under $HOME stays read-only.
    state_dirs = { "~/.claude", "~/.claude.json" },
  },
  codex = {
    cmd = "codex",
    cmd_env = "YANA_CODEX_BIN",
    subcommand = { "exec" }, -- non-interactive mode is the `exec`
                              -- SUBCOMMAND, never a flag.
    noninteractive_flag = false, -- `exec` IS the non-interactive mode.
    stream_protocol = "codex",
    stream_json_args = { "--json" }, -- codex's JSONL request token is
                                      -- literally "json", never
                                      -- "stream-json".
    mode_switch = "per_turn",
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
    sandbox_args_stamps = sandbox_stamps("codex-cli 0.151.0"),
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
}

return backends
