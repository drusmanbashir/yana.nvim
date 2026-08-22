-- yana: configuration defaults and merge logic.
local M = {}

M.defaults = {
  -- WHERE cursor-agent IS RESOLVED FROM. Nothing below bakes in a username,
  -- an absolute path, or an env var this product invented for itself.
  -- Resolution is decided ONCE, by M.resolve_cmd() below, and every consumer
  -- (agent spawn, model list, health/dependency rows) asks it -- never reads
  -- config.options.cmd directly to spawn or probe. Precedence:
  --   1. This value, if you set it: setup({ cmd = "/path/to/cursor-agent" }).
  --   2. The environment variable NAMED by `cmd_env` below, read lazily at
  --      resolve time -- the same indirection avante.nvim uses for provider
  --      API keys (lua/avante/config.lua's `api_key_name` field; read by
  --      lua/avante/providers/init.lua's E.parse_envvar): you name the env
  --      var your shell already exports, yana reads it lazily, and no
  --      secret or machine-specific value is ever a default.
  --   3. `cursor-agent` resolved on PATH.
  -- `~` is expanded (vim.fn.expand) on whichever candidate wins.
  -- nil here (the default) means "not set in setup()", which is exactly what
  -- lets step 2 run at all -- setting a string always wins outright.
  cmd = nil,

  -- Name of the environment variable read for step 2 above. Point this at
  -- whatever your shell profile already exports -- e.g.
  -- cmd_env = "CURSOR_CLI_BIN" if that is the name you already use -- yana
  -- ships no opinion beyond this default name and reads it lazily (never
  -- baked into a default value). Set to false to skip step 2 and go
  -- straight from explicit `cmd` to the PATH fallback.
  cmd_env = "YANA_AGENT_BIN",

  -- Model to use. nil/"" => let cursor-agent pick (Auto). e.g. "claude-opus-5".
  model = nil,

  ----------------------------------------------------------------------
  -- BACKENDS -- the "zoo" the operator stocks (avante.nvim's `providers`
  -- table, applied to a CLI agent instead of an HTTP provider: a named
  -- entry per vendor, plus a top-level selector). The operator can add
  -- their OWN entry in their own setup({}) call and select it immediately
  -- -- no plugin change needed -- because M.setup merges `opts.backends`
  -- onto these defaults with `vim.tbl_deep_extend("force", ...)`: a new
  -- name is added whole, an existing name (e.g. overriding just
  -- `claude.cmd`) is extended field-by-field, not forced to restate the
  -- entire entry.
  --
  -- Row 58: model switching has TWO layers.
  -- `model` above is layer 2 (which model inside a backend). This is layer
  -- 1 (which binary, which account, which bill). `--model claude-4-sonnet`
  -- picked INSIDE cursor-agent is Cursor's resale of Claude on Cursor's
  -- meter; selecting the `claude` backend here runs the operator's own
  -- Anthropic account instead. Two different products; never conflated.
  --
  -- THE GOVERNING RULE (operator ruling, 2026-08-21, echoing "if any of
  -- those args are central to design they shouldn't be args"): AN ENTRY
  -- DECLARES SPELLINGS, NEVER POLICY. Every field below is a vendor's TOKEN
  -- for a capability YANA decided the turn needs -- never a free-form argv
  -- list an entry can use to change WHAT the turn is allowed to do or HOW
  -- Yana parses it. Concretely, what an entry CANNOT influence, and what
  -- enforces each:
  --   * that a turn runs non-interactively            -- Yana always
  --     places `noninteractive_flag` itself, at a fixed position
  --     (build_cmd); an entry cannot omit or relocate it, only spell it.
  --   * that a turn requests the JSON event stream     -- `stream_json_args`
  --     is REQUIRED and VALIDATED at setup to literally contain the token
  --     "stream-json" (M.normalize_backends); an entry that requests a
  --     different format is refused by name before the first turn, not
  --     discovered as "the panel shows nothing" on the first real turn.
  --   * whether an inline/agentic turn may edit          -- `allow_edits_args`
  --     is REQUIRED (non-nil; may be an empty list `{}` when a vendor needs
  --     no extra token, but never absent) and VALIDATED at setup; a mode
  --     that needs edit permission always gets it appended (build_cmd) --
  --     an entry cannot make a turn silently unable to write.
  --   * whether "let the vendor choose the model" sends a literal token
  --                                                    -- it never does;
  --     nil/""/"auto" always just OMITS `select_model_flag` (build_cmd),
  --     regardless of what an entry supplies -- an entry cannot invent a
  --     literal "auto" model id.
  --   * where the prompt lands, or that a resumed session id is the one
  --     Yana was given                                -- both are placed by
  --     build_cmd itself, never by entry content.
  --   * cross-field collision                          -- `allow_edits_args`,
  --     `ask_args` and `list_models_args` may not contain the literal
  --     tokens "--resume" or "--model" (M.normalize_backends), which are
  --     Yana's own placement for `resume_flag`/`select_model_flag`; an
  --     entry that tries is refused at setup, naming the offending token.
  --
  -- What an entry DOES decide, because it genuinely varies per vendor: the
  -- binary; the exact tokens THIS vendor uses to ask for non-interactive
  -- mode, stream-json output, edit permission, a named model, a resumed
  -- session, ask-mode, and model listing. `--trust`/`--approve-mcps` are
  -- deliberately NOT a field here at all (see build_cmd): they are cursor's
  -- own words for cursor's own ideas (a workspace-trust prompt, MCP-server
  -- consent) that most vendors have no concept of, so they stay inline in
  -- build_cmd's cursor-specific branch rather than becoming a schema field
  -- every future vendor is asked to fill in with nil.
  --
  -- Fields:
  --   cmd                  the binary to spawn. A bare name (no "/", no
  --                        leading "~") resolves on PATH lazily at spawn
  --                        time and is NOT checked at setup -- exactly like
  --                        this product's own historical "cursor-agent on
  --                        PATH" fallback below, which has never been
  --                        eagerly checked either, because PATH can
  --                        legitimately be populated after Neovim starts.
  --                        A path containing "/" or a leading "~" IS an
  --                        explicit location and IS checked at setup: the
  --                        operator wrote a specific file down, and a typo
  --                        there deserves a named refusal before the first
  --                        turn. nil is legal ONLY for the built-in
  --                        "cursor" entry and means "keep using the
  --                        cmd/cmd_env/PATH chain above unchanged" -- this
  --                        is what makes the default byte-identical to
  --                        pre-backends Yana.
  --   noninteractive_flag  REQUIRED. Single token this vendor needs to run
  --                        headless/non-interactive (cursor and claude both
  --                        spell it "-p"). Refused at setup if missing.
  --   stream_json_args     REQUIRED. Tokens requesting per-line JSON event
  --                        output. VALIDATED to contain the literal token
  --                        "stream-json" -- agent.lua's parser depends on
  --                        exactly that format, so an entry cannot swap it.
  --   allow_edits_args      REQUIRED (may be `{}`). Tokens granting
  --                        non-interactive edit permission
  --                        (config.agent_needs_permission_flag()).
  --   select_model_flag     OPTIONAL. Flag preceding a model id; nil => this
  --                        vendor has no model-selection surface (layer 2
  --                        does not exist for it).
  --   resume_flag           OPTIONAL. Flag preceding a session id for
  --                        `--resume`-style continuation. Session ids are
  --                        VENDOR-SPECIFIC (row 58's sharp edge) -- ui.lua
  --                        never hands one backend's id to another (see
  --                        M.resume's refusal and pick_backend's
  --                        session-drop).
  --   ask_args              OPTIONAL. Tokens for Yana's own `ask`/`plan`
  --                        mode; nil => this vendor has no non-interactive
  --                        equivalent (a real, documented gap -- see
  --                        build_cmd's comment).
  --   list_models_args      OPTIONAL. Tokens appended to `{cmd}` to list
  --                        models; false/nil => unsupported, so the picker
  --                        degrades honestly instead of reusing the
  --                        PREVIOUS backend's list under the new backend's
  --                        name -- exactly the confusion row 58 is about.
  --
  -- Work order VENDORS (2026-08-21), fields added for codex and every future
  -- non-cursor vendor whose CLI genuinely differs in KIND, not just spelling:
  --   subcommand            OPTIONAL arglist. Tokens placed IMMEDIATELY after
  --                        `cmd`, before every flag Yana adds (build_cmd).
  --                        codex: `{"exec"}` -- non-interactive mode is a
  --                        SUBCOMMAND for codex, not a flag.
  --   noninteractive_flag  now also accepts the literal `false`, meaning
  --                        "this vendor's `subcommand` IS its non-interactive
  --                        mode" (codex: `exec` itself). `false` with an
  --                        empty/absent `subcommand` is refused BY NAME at
  --                        setup -- that combination would run interactively
  --                        and hang forever with nobody there to answer it.
  --   stream_protocol       OPTIONAL string, default "cursor". Names the
  --                        event protocol this vendor speaks; the value must
  --                        be one Yana's stream reader actually implements
  --                        (`cursor`, `claude`, `codex` -- a closed set
  --                        enumerated in the refusal message). An entry
  --                        SELECTS from this set; it cannot invent a new one.
  --   stream_json_args      unchanged in shape, but the token VALIDATED at
  --                        setup now comes from `stream_protocol`, not a
  --                        single hard-coded literal: cursor/claude must
  --                        contain "stream-json", codex must contain "json".
  --   resume_subcommand     OPTIONAL arglist, mutually exclusive with
  --                        `resume_flag` (declaring both is refused at
  --                        setup). Resume-as-subcommand vendors (codex:
  --                        `{"resume"}`) take a POSITIONAL session id
  --                        straight after `subcommand`+`resume_subcommand`,
  --                        not a flag+value pair -- see build_cmd's comment
  --                        for the exact placement.
  --   models                OPTIONAL list of `{id=..., label=...}` tables:
  --                        a declared sub-model catalogue for a vendor with
  --                        no `--list-models`-equivalent surface at all
  --                        (e.g. claude). A non-table entry or an empty id
  --                        is refused at setup.
  --   list_models_format     OPTIONAL string, default "lines" (cursor's
  --                        `id - label` per line). "json_models" parses
  --                        codex's `debug models` shape
  --                        (`{"models":[{slug,display_name,visibility}]}`),
  --                        keeping only `visibility == "list"` entries and
  --                        NEVER reading the `model_messages` field it also
  --                        carries. Unknown values are refused at setup.
  --   close_stdin            OPTIONAL boolean, default false. Declares that
  --                        this vendor's child process must have its stdin
  --                        closed immediately after spawn (codex: piped
  --                        stdin makes it wait to read a `<stdin>` block,
  --                        which can block a turn forever; row 66 measured
  --                        the same 3s fixed wait for claude). Schema-
  --                        validated here; agent.lua's spawn path (jobstart
  --                        `stdin = "null"`) honours it for every backend
  --                        that declares it true.
  backends = {
    cursor = {
      cmd = nil,
      noninteractive_flag = "-p",
      stream_json_args = { "--output-format", "stream-json", "--stream-partial-output" },
      allow_edits_args = { "--force" },
      select_model_flag = "--model",
      resume_flag = "--resume",
      ask_args = { "--mode", "ask" },
      list_models_args = { "--list-models" },
    },
    -- Measured translation table: tests/bin/agent-shim-claude
    -- (branch cp/claude-backend), lifted into declarative form here. That
    -- shim was the PROBE that established these facts; it is not the
    -- shipping mechanism -- this table is.
    claude = {
      cmd = "claude",
      noninteractive_flag = "-p",
      stream_json_args = { "--output-format", "stream-json", "--verbose" },
      allow_edits_args = { "--permission-mode", "acceptEdits" },
      select_model_flag = "--model",
      resume_flag = "--resume",
      ask_args = nil, -- UNMAPPED, documented gap: claude's closest analogues
                       -- (--permission-mode plan|manual) block on an
                       -- interactive answer a headless -p turn has nobody to
                       -- give, so ask mode is not requested at all rather
                       -- than mistranslated into a hang.
      list_models_args = false, -- claude has no --list-models; the picker
                                 -- says so rather than showing cursor's
                                 -- stale list.
      -- No listing surface exists to probe (`claude --help` gives only
      -- illustrative alias examples -- "fable", "opus", "sonnet" -- in its
      -- --model flag text, never an accepted-ids catalogue; there is no
      -- `claude models` or equivalent command). Work order VENDORS ruling:
      -- ship the single honest fallback rather than invent a catalogue from
      -- example text.
      models = { { id = "auto", label = "let claude choose" } },
      close_stdin = true, -- row 66: a claude turn pays a fixed 3s wait for
                          -- stdin data Yana never sends ("Warning: no stdin
                          -- data received in 3s, proceeding without it");
                          -- closing stdin at spawn skips that wait outright.
    },
    -- Measured 2026-08-21 against the operator's own codex CLI 0.148.0
    -- (`codex --help`, `codex exec --help`, `codex exec resume --help`,
    -- `codex debug models`); evidence at
    -- /s/agent_rw/tmp/yana-vendor-probe/. Non-error event shapes beyond the
    -- envelope are UNVERIFIED (quota-refused before any tool call) -- that
    -- is lane V2's concern (vendor_stream.lua), not this schema.
    codex = {
      cmd = "codex",
      subcommand = { "exec" }, -- non-interactive mode is the `exec`
                                -- SUBCOMMAND, never a flag.
      noninteractive_flag = false, -- `exec` IS the non-interactive mode.
      stream_protocol = "codex",
      stream_json_args = { "--json" }, -- codex's JSONL request token is
                                        -- literally "json", never
                                        -- "stream-json".
      allow_edits_args = { "--sandbox", "workspace-write", "--skip-git-repo-check" },
      select_model_flag = "--model",
      resume_subcommand = { "resume" }, -- `codex exec resume <id> ...`; the
                                         -- session id is POSITIONAL, not a
                                         -- flag+value pair (verified against
                                         -- `codex exec resume --help`).
      ask_args = { "--sandbox", "read-only", "--skip-git-repo-check" },
      -- `codex debug models` is NOT a subcommand of `exec` -- it replaces
      -- `subcommand` entirely rather than nesting under it. M.list_models
      -- builds `{cmd} ++ list_models_args` directly and MUST NOT prepend
      -- `bd.subcommand`, or this would try (and fail) to run
      -- `codex exec debug models`.
      list_models_args = { "debug", "models" },
      list_models_format = "json_models",
      close_stdin = true, -- piped stdin makes codex wait to read a
                           -- `<stdin>` block; a codex turn must be spawned
                           -- with stdin closed/empty.
    },
  },

  -- The active backend (layer 1). Session-scoped at runtime exactly like
  -- `model` (config.options.backend is the sole authority once Neovim is
  -- running; see ui.lua's pick_backend) -- this default is only the value a
  -- fresh Neovim session starts with. "cursor" + every backends.cursor
  -- field above being the pre-existing behaviour is what makes an operator
  -- who sets nothing see no change at all.
  backend = "cursor",

  -- THE dial. One setting, three results, named for what you get
  -- rather than for the machinery underneath (the mode contract):
  --
  --   "ask"      the agent reads the workspace and answers. Proposes no edits,
  --              opens no review, writes nothing.
  --   "inline"   DEFAULT. The cursor-IDE clone: the agent works confined in the
  --              overlay, every change is offered as reviewable hunks, and the
  --              journaled applier writes the real tree only after acceptance.
  --   "agentic"  a plain wrapper around the full cursor agent. It edits files
  --              itself. No overlay, no change set, no review, no diary.
  mode = "inline",

  -- Direct mode lets cursor-agent write the real workspace without Yana's
  -- overlay or review path. It must be enabled separately from selecting it.
  enable_agentic = false,

  -- Pass --trust so the workspace is trusted in headless mode (no prompt).
  trust = true,


  -- Pass --approve-mcps so MCP servers do not block on interactive consent.
  approve_mcps = false,

  -- Additional artifact directory component names/globs. These affect
  -- grouping and retention strength only; they never grant safety.
  artifact_dir_prefixes = {},

  -- ALPHA: nil keeps historical inline behaviour. A list narrows inline-mode
  -- executable launch to these executable basenames/paths by kernel rule.
  -- Ask and agentic modes do not receive the rule.
  inline_exec_allowlist = nil,

  -- Directories OUTSIDE the opened workspace that a turn may write, each one
  -- confined, claimed and reviewed exactly like the workspace itself (see the
  -- external-roots module doc). The opened workspace is always root 1
  -- and is never listed here.
  --
  -- THE SET IS OPERATOR-DECLARED AND NOTHING ELSE MAY WIDEN IT. CORE's
  -- cardinal principle is that nothing agent-influenced selects confinement
  -- scope, so these come from setup()/config or an explicit operator command
  -- and from nowhere else: not from agent output, not from a path found in the
  -- workspace, not from an env var a turn could set. A write into a directory
  -- that is not the workspace and not listed here stays EROFS, and the refusal
  -- names the `write_roots` line that would declare it.
  --
  -- Entries are absolute (a leading `~` is expanded here); everything else --
  -- existence, overlap with the workspace or with each other, resolving inside
  -- yana's own state root -- is checked at TURN START, where a bad entry
  -- refuses the turn by name before the agent is launched. Each declared root
  -- costs one more overlay mount and one more claim per turn (measured ~181 ms
  -- per root on the reference box).
  write_roots = {},

  -- THE BROAD ROOT: the ONE directory the turn's single overlay is mounted at
  -- (PLAN-R1-capture.md §1). Everything beneath it is writable inside the jail
  -- and every write lands in the turn's private upper layer -- the opened
  -- repository, a sibling repository, a directory that did not exist when the
  -- turn started. Everything outside it stays the plain read-only host bind.
  --
  -- `nil` means "choose it from filesystem position", which is the default and
  -- the cardinal principle applied to breadth: `$HOME/code` when it is an
  -- ancestor of the resolved workspace, else `$HOME`, else the workspace
  -- itself. Set it to NARROW that choice (one monorepo instead of all of
  -- `~/code`) or to widen it deliberately. It is an OPERATOR setting and
  -- nothing a turn produces may reach it: not agent output, not a path found
  -- in the workspace, not an env var a turn could set.
  --
  -- Validated at TURN START, where a bad value refuses the turn by name: it
  -- must exist, must be an ancestor of (or equal to) the resolved workspace,
  -- and must not contain yana's own state root -- the overlay may never cover
  -- the layers it is written into.
  capture_root = nil,

  -- Directories that are a WORKSPACE even though they hold no `.git`
  -- (PLAN-R1-capture.md §8 row 3). Workspace resolution asks, in order: the
  -- nearest `.git` root at or above the open file; then the entry here that
  -- contains it; then the file's own folder. A repository always wins, because
  -- the repository is the unit a claim is taken on.
  --
  -- Same provenance rule as every other scope setting: operator-declared,
  -- absolute (a leading `~` is expanded), never derived from a turn.
  workspace_roots = {},

  -- Buffer-local keys during inline hunk review (Avante replace_in_file parity).
  diff_keymaps = {
    ours = "co",
    theirs = "ct",
    all_theirs = "ca",
    all_changes = "cA",
    both = "cb",
    next = "]x",
    prev = "[x",
  },

  -- Inline diff: standard git colors via colorscheme DiffAdd/DiffDelete.
  diff_highlights = {
    incoming = { link = "DiffAdd" },
    deleted = { link = "DiffDelete" },
    hint = { link = "Comment" },
  },

  -- Winbar mode chip. The active mode is the one thing on the bar the operator
  -- must read at a glance, so it carries the standout colour. `agentic` keeps a
  -- warning colour of its own because it writes the real workspace with no
  -- review. Each mode maps to a YanaMode* group applied in the panel winbar.
  mode_highlights = {
    ask = { link = "Special" },
    inline = { link = "Special" },
    agentic = { link = "WarningMsg" },
  },

  -- Winbar model chip (`model: auto` or the chosen model id). It reads "auto"
  -- unless the operator picked a model, so it steps back to a blue hue and
  -- leaves the standout colour to the mode chip.
  model_highlight = { link = "Identifier" },

  -- Prepended to agent-mode prompts. Nil disables.
  --
  -- Prompt layer only (packets/DESIGN-multiroot-inline-speed-20260820.md,
  -- Defect B, design step 1 of 2). This is compliance-by-request, not
  -- enforcement: a vendor model can honor it or ignore it, and a hostile or
  -- careless agent binary is not bound by it at all. The jail layer (design
  -- step 2 -- the overlay's shell surface refusing execution-class argv in
  -- inline mode) is the enforcement that holds regardless of what the model
  -- does with this text, and does not exist yet.
  agent_instructions = [[
{{YANA_WRITABLE_BOUNDARY}}
Agent mode: when the user asks to populate, add, change, or give an example in a file, EDIT that file with the Edit File tool immediately — do not only reply in chat or ask whether to paste. Use minimal diffs at the referenced line numbers. When a visual selection is attached, prefer edits inside the stated edit zone; out-of-zone edits may be rejected or flagged before review. The user reviews each edit as inline hunks in the open file (co/ct/ca) before it is final. Propose edits only — never run compilers, test suites, or import/smoke checks; the user's hunk-by-hunk review is the validation step here, not a shell command. If validation like that is actually needed, say so and let the user switch to agentic mode, where it belongs.
]],

  selection_scope = {
    -- "reject" hard-blocks out-of-zone edits; "warn" keeps them reviewable with a note; "off" disables.
    enforce = "reject",
    -- When no function/class/cell resolves, bare selection uses this level instead of a 1-line jail.
    unstructured = "warn",
    cell_markers = { "# %%", "#%%" },
    min_zone_lines = 1,
    -- Out-of-zone rejections per path in one turn before cancel_inflight.
    rejection_cap = 3,
  },

  queue = {
    -- When a turn finishes with an agent-level error, hold any queued
    -- follow-ups (do not auto-fire the next one) and notify instead — the
    -- user decides whether to still send them via the queue picker/keymap.
    pause_on_error = false,
  },

  redirect = {
    -- After cancelling, wait this long for the process's exit to be observed
    -- before escalating to SIGKILL.
    confirm_exit_timeout_ms = 3000,
    -- After SIGKILL, wait this long more; if the process still won't die the
    -- redirect is aborted (text returned to the prompt) — never two processes.
    kill_grace_ms = 1500,
    -- One-line prefix telling the model the previous turn was cut.
    marker = "[redirect — previous turn interrupted]",
  },

  context = {
    -- When no visual selection is given, tell the agent which file/line the
    -- cursor is on so it can open the file itself.
    include_file = true,
    -- Hard cap on selection lines embedded into the prompt.
    max_selection_lines = 600,
  },

  sessions = {
    -- Where yana stores its session registry and transcripts.
    -- nil => stdpath("data") .. "/yana".
    dir = nil,
    -- Where the cursor-agent CLI stores its chats (for discovering sessions
    -- started outside Neovim). nil => ~/.cursor/chats.
    chats_dir = nil,
    -- Maximum number of sessions shown in the picker.
    max = 50,
  },

  ui = {
    -- Sidebar width. <= 1 is treated as a fraction of total columns,
    -- > 1 is an absolute column count.
    width = 0.40,
    -- Height (in rows) of the prompt input area at the bottom.
    prompt_height = 6,
    -- "right" or "left".
    position = "right",
    wrap = true,
    -- Show token usage / duration after each answer.
    show_usage = true,
    -- Render the model's "thinking" content (if any).
    show_thinking = false,
    -- Spinner frames shown in the winbar while the agent is responding.
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  },

  -- Buffer-local keymaps inside the panel. Set any to false/nil to disable.
  keymaps = {
    submit = "<C-s>",        -- submit prompt (insert + normal mode)
    submit_normal = "<CR>",  -- submit prompt (normal mode only)
    new_chat = "<C-n>",      -- start a fresh chat (clears session)
    toggle_mode = "<M-t>",   -- Alt+t: cycle mode (avoid <C-t> — Vim tag pop / E73)
    -- Alt+r: resend-last-prompt PREFIX. Three leaves, each with a `desc`
    -- (shown by :map and by which-key if you use it):
    --   <M-r>r  here  — same chat, same session, same mode
    --   <M-r>n  new   — new chat (fresh session), this chat's mode
    --   <M-r>a  agent — new chat forced to agent mode (ask -> "now do it")
    resend = "<M-r>",
    model = "<C-g>",         -- open the model picker (layer 2: within the active backend)
    -- Layer 1: open the BACKEND picker (which binary/account/bill). Deliberately
    -- a DIFFERENT key from `model` (row 58) --
    -- switching the model and switching the backend have different
    -- consequences (one changes which model answers; the other changes which
    -- account is billed and resets the model), so a mis-press must never
    -- change the wrong dial.
    backend = "<C-b>",
    review = "<C-y>",        -- open inline review for a pending change
    accept = "<C-a>",        -- accept a pending change (keep agent edit)
    reject = "<C-x>",        -- reject a pending change (revert file)
    diff = "<C-y>",          -- alias for review (deprecated name)
    focus_prompt = "i",      -- from the conversation window, jump to prompt
    close = "q",             -- close the panel (from either window, normal mode)
    stop = "<C-c>",          -- stop an in-flight response
    sessions = "<M-s>",      -- Alt+s: pick a session to view/resume
    new_panel = "<M-n>",     -- Alt+n: open an additional panel (parallel session)
    queue = "<M-q>",         -- Alt+q: view/edit/delete/reorder queued follow-ups
    -- Interrupt the in-flight response and immediately resend the prompt
    -- buffer as a new turn (session context preserved via --resume). Insert
    -- + normal mode, prompt buffer only. NOTE: many terminals cannot tell
    -- <C-CR> apart from plain <CR> without the Kitty keyboard protocol (or
    -- equivalent) enabled — if that's the case for you, rebind to something
    -- your terminal reports distinctly (e.g. "<M-CR>" or a leader-prefixed key).
    steer = "<C-CR>",
    -- Manually open the completion menu (slash-commands / @mentions) from an
    -- empty prompt line or mid-sentence, without a trigger character.
    -- Insert mode, prompt buffer only.
    --
    -- Coexistence constraint with blink.cmp, if installed: blink re-applies
    -- its OWN buffer-local <C-Space> -> cmp.show() on every InsertEnter
    -- (blink.cmp/lua/blink/cmp/keymap/init.lua keymap.setup's InsertEnter
    -- autocmd calls apply.keymap_to_current_buffer unconditionally whenever
    -- config.enabled() is true for the buffer). So yana's own buffer-local
    -- <C-Space> mapping (apply_panel_keymaps, set once at panel-open time) is
    -- only ever live until blink's next InsertEnter overwrites it — kept as a
    -- same-behavior fallback for when blink.cmp is absent or disabled, not as
    -- a competing keymap. If your blink.cmp config scopes providers for
    -- yana's prompt buffer (check `vim.b.yana_prompt == true` and return
    -- yana's sources), blink's own <C-Space> opens the yana-scoped menu and
    -- the two mappings perform the SAME action; without that scoping, blink
    -- opens its default providers instead (:checkhealth yana reports this).
    completion_menu = "<C-Space>",
  },

  -- Roots to scan for skills (each a directory whose entries are
  -- skill-directories containing a SKILL.md). Preference-shaped — WHICH
  -- roots to look in is configurable here; the scanning LOGIC that reads
  -- them stays in lua/yana/commands.lua. Project-local
  -- `<git-root-or-cwd>/.cursor/skills` is always scanned too, ahead of this
  -- list, the same way project `.cursor/commands` outranks
  -- `~/.cursor/commands` — it is not listed here because "project root"
  -- is a runtime value, not a preference.
  skill_dirs = {
    vim.fn.expand("~/.cursor/skills"),
    vim.fn.expand("~/.cursor/skills-cursor"),
    vim.fn.expand("~/.claude/skills"),
  },

  -- Inline edit ("Ctrl-K"): select lines, state an instruction in a small float
  -- over the selection, and have the agent rewrite exactly those lines. The
  -- result is NOT special-cased — it becomes a normal agent turn whose changes
  -- land in the ordinary inline hunk review, so CORE's containment and
  -- accept/reject contract applies unchanged. The only thing this adds is an
  -- entry path that does not require visiting the panel.
  inline_edit = {
    enable = true,
    -- Float geometry. width <= 1 is a fraction of total columns, > 1 absolute.
    width = 0.5,
    -- Extra prompt rows beyond the first; the float grows up to this as you type.
    max_height = 6,
    -- How many past instructions <C-p>/<C-n> can cycle through. 0 disables.
    history = 20,
    -- Float keymaps. submit sends; cancel closes without sending.
    keymaps = {
      submit = "<C-s>",      -- insert + normal
      submit_normal = "<CR>",-- normal only (insert <CR> inserts a newline)
      cancel = "<Esc>",      -- insert + normal
      cancel_normal = "q",   -- normal only
      history_prev = "<C-p>",
      history_next = "<C-n>",
    },
  },

  -- Optional GLOBAL keymaps. Only applied when require("yana").setup{} is
  -- called. Each maps to a command; set to false/nil to skip.
  global_keymaps = {
    toggle = nil,            -- e.g. "<leader>cc" — opens/closes panel from any buffer
    ask = nil,               -- e.g. "<leader>ca" (works in normal + visual)
    -- Inline edit. VISUAL mode only by default, which is what makes "<C-k>" a
    -- safe suggestion despite being heavily used elsewhere: <C-k> is commonly
    -- bound in normal mode (window navigation), insert mode (digraphs) and
    -- inside completion menus, but visual-mode <C-k> is almost always free.
    -- Setting inline_edit_normal too takes the CURRENT LINE as the selection,
    -- and is nil by default precisely because normal-mode <C-k> usually is not
    -- free. e.g. inline_edit = "<C-k>", inline_edit_normal = "<leader>ck"
    inline_edit = nil,
    inline_edit_normal = nil,
  },

	-- Paste an image (or an image file, or plain text) from the system
	-- clipboard into the prompt buffer. See lua/yana/clipboard.lua.
	image_paste = {
		enable = true,
		-- Insert-mode, prompt buffer only. String or list. <C-v> and <C-V> are the
		-- same physical key to Vim (control-chord notation is case-insensitive), so
		-- listing both is purely so either spelling in user config works; add a
		-- genuinely different key here (e.g. "<C-S-v>") to bind more.
		key = { "<C-v>", "<C-V>" },
		keep = 20,          -- pasted images retained in the cache dir
	},


	-- Diagnostic recording, OFF by default. When true, every raw cursor-agent
	-- stdout line is teed verbatim to `<turn_dir>/private/stream.ndjson` and a
	-- `meta.json` sidecar (argv, cwd, mode, model, timestamps, exit code,
	-- stderr) is written at exit, so the turn can be replayed through the real
	-- pipeline by `tests/fake-cursor-agent`.
	--
	-- It is off by default because it is PER-EVENT disk I/O, and the default
	-- configuration owes CTL-CLEAN: a clean turn leaves `yana.log`
	-- byte-identical. The tee writes its own files and never the log, so even
	-- with this on the log stays untouched — the flag only decides whether the
	-- recording files exist at all. See lua/yana/record.lua.
	debug_record = false,
}

M.options = vim.deepcopy(M.defaults)

----------------------------------------------------------------------
-- THE MODE DIAL
--
-- Every question the rest of the product used to ask five options is answered
-- here, from one value. Nothing below is configurable, because each of these
-- was a way for two settings to disagree.
----------------------------------------------------------------------

local MODES = { ask = true, inline = true, agentic = true }

--- Highlight group names for the winbar mode chip (one per named mode).
M.mode_hl_groups = {
  ask = "YanaModeAsk",
  inline = "YanaModeInline",
  agentic = "YanaModeAgentic",
}
M.model_hl_group = "YanaModel"

function M.normalize_mode(value, enable_agentic)
	if value == nil then
		return M.defaults.mode
	end
	if type(value) ~= "string" or MODES[value] == nil then
		error(
			"yana: invalid config.mode "
				.. vim.inspect(value)
				.. ' — one of "ask" (read and answer), "inline" (hunks you review, the default), "agentic" (the agent edits files itself)',
			0
		)
	end
	if value == "agentic" and enable_agentic ~= true then
		error(
			'yana: config.mode = "agentic" requires enable_agentic = true because it writes the real workspace without confinement or review',
			0
		)
	end
	return value
end

--- WHERE THE AGENT RUNS. True for every mode that starts the agent under the
--- harness -- `ask` and `inline` -- and false only for `agentic`, which is the
--- direct surface that the public safety contract places outside containment.
---
--- Ruling R-3, 2026-08-18 (the mode contract section 2). This answered `inline`
--- only until that date, so an `ask` turn ran the agent against the real tree
--- with `--mode ask` on the argv as its only barrier. A vendor flag is a
--- request, not a boundary: the cardinal principle requires the guarantee to
--- hold when cursor-agent is replaced by a hostile executable that ignores the
--- flag, and such an executable does not stop writing because the mode it was
--- launched under is called `ask`. Confinement costs a read-only turn nothing,
--- so the exception was closed rather than documented.
function M.resolve_mode(mode)
	local m = mode
	if m == nil or m == "" then
		m = M.options.mode
	end
	if m == "agent" then
		m = "agentic"
	elseif m == "plan" then
		m = "ask"
	elseif m == "review" then
		m = "inline"
	end
	if MODES[m] ~= nil then
		if m == "agentic" and M.options.enable_agentic ~= true then
			return "inline"
		end
		return m
	end
	return M.options.mode
end

function M.overlay_mode(mode)
	local m = M.resolve_mode(mode)
	return m == "inline" or m == "ask"
end

--- WHO WRITES. Does this mode open hunk reviews and accept through the
--- journaled applier? `inline` only.
---
--- The two predicates are deliberately separate and, since R-3, they no longer
--- give the same answer: `ask` runs confined (overlay_mode) and proposes
--- nothing (no review). Welding them together is what made confinement
--- conditional on there being something to review.
function M.review_mode_active(mode)
	return M.resolve_mode(mode) == "inline"
end

--- The cursor-agent permission mode. An internal consequence of the dial, never
--- a user-facing option.
function M.agent_permission_mode(mode)
	if M.resolve_mode(mode) == "ask" then
		return "ask"
	end
	return "agent"
end

--- Whether this turn's argv carries the vendor permission-bypass flag.
---
--- THIS FUNCTION IS THE ENTIRE DECISION. Adjudicated 2026-08-17 and recorded in
--- the mode contract as a KNOWN EXPOSURE, not a resolution: `--force`
--- governs Cursor's OWN permission prompts, and this product's threat model
--- assumes a hostile agent binary that ignores the vendor permission layer
--- entirely. The boundary is the overlay the agent is confined in plus the hunk
--- review gating every real-tree write -- neither is affected by this flag.
--- Dropping it would surrender all editing (non-force tool calls need an
--- approval a headless `-p` turn has nobody to answer) and buy no security.
---
--- Revisit trigger: the capsule shipping, or a pinned cursor-agent release
--- demonstrating a non-interactive non-force edit -- whichever comes first.
--- When that lands, this returns false and nothing else changes. Every caller
--- asks this function rather than reading a flag, precisely so the reversal is
--- one line here.
function M.agent_needs_permission_flag(mode)
	return M.resolve_mode(mode) ~= "ask"
end

local ENFORCE_MODES = { reject = true, warn = true, off = true }

local function normalize_enforce(value, fallback)
  if type(value) == "string" and ENFORCE_MODES[value] then
    return value
  end
  return fallback
end

function M.normalize_selection_scope(scope)
  local base = vim.deepcopy(M.defaults.selection_scope)
  if type(scope) ~= "table" then
    return base
  end
  local out = vim.tbl_deep_extend("force", base, scope)
  out.enforce = normalize_enforce(out.enforce, base.enforce)
  out.unstructured = normalize_enforce(out.unstructured, base.unstructured)
  if type(out.cell_markers) ~= "table" or #out.cell_markers == 0 then
    out.cell_markers = vim.deepcopy(base.cell_markers)
  else
    local markers = {}
    for _, marker in ipairs(out.cell_markers) do
      if type(marker) == "string" and marker ~= "" then
        markers[#markers + 1] = marker
      end
    end
    if #markers == 0 then
      out.cell_markers = vim.deepcopy(base.cell_markers)
    else
      out.cell_markers = markers
    end
  end
  if type(out.min_zone_lines) ~= "number" or out.min_zone_lines < 1 then
    out.min_zone_lines = base.min_zone_lines
  end
  if type(out.rejection_cap) ~= "number" or out.rejection_cap < 1 then
    out.rejection_cap = base.rejection_cap
  end
  return out
end

function M.normalize_image_paste(ip)
  local base = vim.deepcopy(M.defaults.image_paste)
  if type(ip) ~= "table" then
    return base
  end
  local out = vim.tbl_deep_extend("force", base, ip)
  if type(out.enable) ~= "boolean" then
    out.enable = base.enable
  end
  -- Accept a bare string or a list; always hand callers a list so the keymap
  -- site never has to branch on the type.
  local keys = {}
  if type(out.key) == "string" then
    if out.key ~= "" then
      keys[1] = out.key
    end
  elseif type(out.key) == "table" then
    for _, k in ipairs(out.key) do
      if type(k) == "string" and k ~= "" then
        keys[#keys + 1] = k
      end
    end
  end
  if #keys == 0 then
    keys = vim.deepcopy(base.key)
  end
  out.key = keys
  if type(out.keep) ~= "number" or out.keep < 1 then
    out.keep = base.keep
  end
  return out
end

function M.normalize_redirect(r)
  local base = vim.deepcopy(M.defaults.redirect)
  if type(r) ~= "table" then
    return base
  end
  local out = vim.tbl_deep_extend("force", base, r)
  if type(out.confirm_exit_timeout_ms) ~= "number" or out.confirm_exit_timeout_ms < 50 then
    out.confirm_exit_timeout_ms = base.confirm_exit_timeout_ms
  end
  if type(out.kill_grace_ms) ~= "number" or out.kill_grace_ms < 50 then
    out.kill_grace_ms = base.kill_grace_ms
  end
  if type(out.marker) ~= "string" then
    out.marker = base.marker
  end
  return out
end

function M.normalize_inline_edit(ie)
  local base = vim.deepcopy(M.defaults.inline_edit)
  if type(ie) ~= "table" then
    return base
  end
  local out = vim.tbl_deep_extend("force", base, ie)
  if type(out.enable) ~= "boolean" then
    out.enable = base.enable
  end
  -- width follows the ui.width convention: <= 1 is a fraction, > 1 absolute.
  -- Anything else (0, negative, non-number) falls back rather than producing a
  -- zero-width float the user cannot type into.
  if type(out.width) ~= "number" or out.width <= 0 then
    out.width = base.width
  end
  if type(out.max_height) ~= "number" or out.max_height < 1 then
    out.max_height = base.max_height
  end
  if type(out.history) ~= "number" or out.history < 0 then
    out.history = base.history
  end
  if type(out.keymaps) ~= "table" then
    out.keymaps = vim.deepcopy(base.keymaps)
  else
    -- A key set to false/nil is "unbound", which is legitimate; a non-string is
    -- not, and would throw inside vim.keymap.set at float-open time instead of
    -- at setup time where the mistake is.
    for name, key in pairs(out.keymaps) do
      if key ~= false and key ~= nil and type(key) ~= "string" then
        out.keymaps[name] = base.keymaps[name]
      end
    end
  end
  return out
end

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

-- Work order VENDORS -- the literal request token VALIDATED inside
-- `stream_json_args` for each protocol. cursor and claude both ask for
-- "stream-json"; codex's JSON event flag is spelled "--json" and the token
-- itself is literally "json".
local PROTOCOL_STREAM_TOKEN = { cursor = "stream-json", claude = "stream-json", codex = "json" }

-- Work order VENDORS -- the closed set of `list_models_args` output shapes
-- M.list_models (agent.lua) knows how to parse.
local LIST_MODELS_FORMATS = { lines = true, json_models = true }

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

--- The "zoo" table (avante.nvim's `providers` shape). Merges `value` onto
--- the shipped defaults with `vim.tbl_deep_extend("force", ...)` -- an
--- operator entry with a name already shipped here (e.g. overriding just
--- `claude.cmd`) extends that entry field-by-field; a genuinely new name
--- (their own vendor) is added whole. Every entry, shipped or operator-
--- added, is validated the same way and by the same rules -- there is no
--- privileged path for the built-ins besides "cursor" being allowed a nil
--- `cmd` (see the M.defaults.backends doc comment for why).
---
--- Every capability is validated for SHAPE here (right type, non-empty,
--- contains what Yana's own parser/placement logic depends on). This is
--- "at minimum" validation, not a live probe of the binary: spawning an
--- arbitrary operator-named executable during setup() -- on every Neovim
--- start, even for a backend never selected -- would add real latency and
--- a side-effecting process spawn to a call that today is pure data
--- validation, and cannot be done hermetically in this product's own test
--- suite without shipping a fake binary for every vendor. Static shape
--- validation catches the practical failure mode this feature exists to
--- prevent (an entry whose `stream_json_args` requests a format Yana's
--- parser cannot read) without that cost; a live probe would catch more
--- (a real vendor CLI silently renaming a flag) and is a genuine
--- possible follow-up, not something this build does.
function M.normalize_backends(value)
  local base = vim.deepcopy(M.defaults.backends)
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
      -- Exact match against the bare token OR its "--"-flag spelling:
      -- cursor/claude's "stream-json" is always its own standalone argv
      -- element (a value following "--output-format"), matched bare; codex's
      -- is a single boolean flag ("--json") with no separate value token,
      -- matched as "--" .. want_token. A plain substring match would be too
      -- loose here -- "stream-json" itself contains "json" as a substring,
      -- which would let a cursor-shaped stream_json_args satisfy codex's
      -- token by accident.
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

    entry.allow_edits_args = require_arglist(entry.allow_edits_args, name, "allow_edits_args")
    check_no_reserved_tokens(entry.allow_edits_args, name, "allow_edits_args")

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

    entry.models = optional_model_list(entry.models, name)

    entry.select_model_flag = optional_flag(entry.select_model_flag, name, "select_model_flag")
    entry.resume_flag = optional_flag(entry.resume_flag, name, "resume_flag")
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
  end
  return out
end

--- The active backend name (layer 1). Must name an entry present in
--- `backends` -- an unknown name is refused AT SETUP, by name, never at
--- turn time (mirrors M.normalize_mode's refusal shape).
function M.normalize_backend(value, backends)
  if value == nil or value == "" then
    return M.defaults.backend
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
--- asks this, never `M.options.backends[name]` directly, so there is one
--- place a missing/renamed entry is handled consistently.
function M.backend_descriptor(name)
  name = name or M.options.backend
  return M.options.backends and M.options.backends[name] or nil
end

--- `cmd_env` is either a non-empty string (the env var name) or `false`
--- (step 2 disabled). Anything else falls back to the shipped default name
--- rather than silently disabling env indirection on a typo.
function M.normalize_cmd_env(value)
  if value == false then
    return false
  end
  if type(value) == "string" and value ~= "" then
    return value
  end
  return M.defaults.cmd_env
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
--- see the `cmd`/`cmd_env` comments in M.defaults above for the citation).
--- Every consumer that needs to spawn or probe cursor-agent asks THIS
--- function -- never `config.options.cmd` directly -- so there is exactly one
--- place precedence is decided and exactly one place `~` gets expanded.
---
--- Precedence, first match wins:
---   "config"  -- config.options.cmd, when set (explicit setup({ cmd = .. })).
---   "cmd_env" -- the environment variable NAMED by config.options.cmd_env
---               (default "YANA_AGENT_BIN"; false disables this step), when
---               that variable is itself set and non-empty.
---   "path"    -- the bare name "cursor-agent", left for the caller (jobstart,
---               vim.fn.exepath, ...) to resolve on PATH.
--- `~` is expanded (vim.fn.expand) on whichever string wins; the PATH
--- fallback is a bare command name and is never expanded (there is nothing
--- to expand).
---
--- Returns a table:
---   step        "config" | "cmd_env" | "path" -- which step resolved.
---   value       the resolved command string to spawn or probe.
---   candidates  every step considered, in order, for diagnostics (health
---               rows, error messages): each entry is
---               { step, tried = bool, raw?, expanded?, env_name?, note? }.
---               `tried = true` means this step produced a candidate (raw is
---               the pre-expansion string); `tried = false` means it was
---               skipped or empty, and `note` says why.
--- Resolve the spawn binary for `backend_name` (default: the active backend).
--- Prefetch / list_models for a non-active vendor MUST pass that vendor's
--- name — otherwise argv would mix one binary with another's list flags.
function M.resolve_cmd(backend_name)
  local candidates = {}
  local active = backend_name or M.options.backend or M.defaults.backend
  local entry = M.backend_descriptor(active) or {}

  -- Layer 1 first: a backend whose entry names an explicit `cmd` (every
  -- shipped entry except "cursor", and any operator override of it) wins
  -- outright -- already validated executable (or PATH-deferred, see the
  -- M.defaults.backends doc comment) at setup, so there is nothing left to
  -- try. Only "cursor" with `cmd = nil` falls through to the historical
  -- config/cmd_env/PATH chain below, which is what keeps the default
  -- byte-identical to pre-backends Yana.
  if type(entry.cmd) == "string" and entry.cmd ~= "" then
    local expanded = vim.fn.expand(entry.cmd)
    candidates[#candidates + 1] =
      { step = "backend", backend = active, tried = true, raw = entry.cmd, expanded = expanded }
    return { step = "backend", value = expanded, backend = active, candidates = candidates }
  end
  candidates[#candidates + 1] =
    { step = "backend", backend = active, tried = false, note = "backends." .. active .. ".cmd not set; using the cmd/cmd_env/PATH chain" }

  local explicit = M.options.cmd
  if type(explicit) == "string" and explicit ~= "" then
    local expanded = vim.fn.expand(explicit)
    candidates[#candidates + 1] = { step = "config", tried = true, raw = explicit, expanded = expanded }
    return { step = "config", value = expanded, backend = active, candidates = candidates }
  end
  candidates[#candidates + 1] = { step = "config", tried = false, note = "cmd not set in setup()" }

  local env_name = M.options.cmd_env
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
--- refusal messages) call M.resolve_cmd() directly for the full candidate
--- list.
function M.cmd(backend_name)
  return M.resolve_cmd(backend_name).value
end

function M.normalize_skill_dirs(dirs)
  local base = vim.deepcopy(M.defaults.skill_dirs)
  if type(dirs) ~= "table" then
    return base
  end
  local out = {}
  for _, d in ipairs(dirs) do
    if type(d) == "string" and d ~= "" then
      out[#out + 1] = vim.fn.expand(d)
    end
  end
  if #out == 0 then
    return base
  end
  return out
end

--- Shape only. A `write_roots` entry that does not exist, overlaps another
--- root or lands inside the state root is a TURN-START refusal naming the root
--- (`shadow/preview.lua`'s resolve_roots), not a setup error: the directory may
--- legitimately appear after the editor started, and a refusal that names the
--- offending root at the moment a turn needs it is the actionable one.
---
--- Entries are sorted here, which is also the ACQUISITION order: claims are
--- taken in canonical-path order so two editors racing for overlapping root
--- sets attempt them in the same sequence and neither ends up holding half.
function M.normalize_write_roots(roots)
  if roots == nil then
    return {}
  end
  if type(roots) ~= "table" then
    error("write_roots must be a list of absolute directory paths")
  end
  local out, seen = {}, {}
  for _, entry in ipairs(roots) do
    if type(entry) ~= "string" or entry == "" then
      error("write_roots entries must be non-empty absolute directory paths")
    end
    local expanded = vim.fn.expand(entry)
    if type(expanded) ~= "string" or expanded == "" then
      error("write_roots entry could not be expanded: " .. entry)
    end
    if expanded:sub(1, 1) ~= "/" then
      error("write_roots entries must be absolute paths (a leading ~ is expanded): " .. entry)
    end
    expanded = expanded:gsub("/+$", "")
    if expanded == "" then
      error("write_roots may not declare the filesystem root")
    end
    if not seen[expanded] then
      seen[expanded] = true
      out[#out + 1] = expanded
    end
  end
  table.sort(out)
  return out
end

--- Shape only, exactly like `normalize_write_roots`: existence and the
--- ancestor/state-root questions are TURN-START refusals naming the directory
--- (`shadow/preview.lua`'s `workspace_for_turn`/`broad_root_for`), because the
--- directory may legitimately appear after the editor started.
function M.normalize_workspace_roots(roots)
  if roots == nil then
    return {}
  end
  if type(roots) ~= "table" then
    error("workspace_roots must be a list of absolute directory paths")
  end
  local out, seen = {}, {}
  for _, entry in ipairs(roots) do
    if type(entry) ~= "string" or entry == "" then
      error("workspace_roots entries must be non-empty absolute directory paths")
    end
    local expanded = vim.fn.expand(entry)
    if type(expanded) ~= "string" or expanded == "" then
      error("workspace_roots entry could not be expanded: " .. entry)
    end
    if expanded:sub(1, 1) ~= "/" then
      error("workspace_roots entries must be absolute paths (a leading ~ is expanded): " .. entry)
    end
    expanded = expanded:gsub("/+$", "")
    if expanded == "" then
      error("workspace_roots may not declare the filesystem root")
    end
    if not seen[expanded] then
      seen[expanded] = true
      out[#out + 1] = expanded
    end
  end
  -- Longest first: the NEAREST configured root wins when two of them nest,
  -- which is the same "nearest wins" rule the `.git` walk already uses.
  table.sort(out, function(a, b)
    if #a == #b then
      return a < b
    end
    return #a > #b
  end)
  return out
end

--- Shape only. One absolute directory or nil; everything else is a TURN-START
--- refusal naming it.
function M.normalize_capture_root(root)
  if root == nil or root == "" then
    return nil
  end
  if type(root) ~= "string" then
    error("capture_root must be an absolute directory path, or nil")
  end
  local expanded = vim.fn.expand(root)
  if type(expanded) ~= "string" or expanded == "" then
    error("capture_root could not be expanded: " .. root)
  end
  if expanded:sub(1, 1) ~= "/" then
    error("capture_root must be an absolute path (a leading ~ is expanded): " .. root)
  end
  expanded = expanded:gsub("/+$", "")
  if expanded == "" then
    error("capture_root may not be the filesystem root")
  end
  return expanded
end

function M.normalize_artifact_dir_prefixes(prefixes)
  if prefixes == nil then
    return {}
  end
  if type(prefixes) ~= "table" then
    error("artifact_dir_prefixes must be a list of directory component names or globs")
  end
  local out, seen = {}, {}
  for _, name in ipairs(prefixes) do
    if type(name) ~= "string"
      or name == ""
      or name == "."
      or name == ".."
      or name:find("/", 1, true)
      or name:find("\\", 1, true)
      or name:find("\0", 1, true)
    then
      error("artifact_dir_prefixes entries must be single directory component names or globs")
    end
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

function M.normalize_inline_exec_allowlist(list)
  if list == nil then
    return nil
  end
  if type(list) ~= "table" then
    error("inline_exec_allowlist must be nil or a list of executable basenames/paths")
  end
  local out, seen = {}, {}
  for _, entry in ipairs(list) do
    if type(entry) ~= "string" or entry == "" or entry:find("\0", 1, true) then
      error("inline_exec_allowlist entries must be non-empty executable basenames/paths")
    end
    local resolved
    if entry:sub(1, 1) == "/" or entry:sub(1, 1) == "~" then
      resolved = vim.fn.expand(entry)
    else
      resolved = vim.fn.exepath(entry)
      if resolved == "" then
        error("inline_exec_allowlist entry is not executable on PATH: " .. entry)
      end
    end
    resolved = vim.loop.fs_realpath(resolved) or vim.fn.fnamemodify(resolved, ":p")
    if vim.fn.executable(resolved) ~= 1 then
      error("inline_exec_allowlist entry is not executable: " .. resolved)
    end
    if not seen[resolved] then
      seen[resolved] = true
      out[#out + 1] = resolved
    end
  end
  table.sort(out)
  return out
end

--- Install configuration ATOMICALLY: nothing becomes effective until every
--- validator has accepted.
---
--- The order here is the whole point. A validator that refuses a value raises,
--- and it raises while the candidate is still a LOCAL table — so the raise
--- leaves `M.options` exactly as it was before the call. The alternative, which
--- this replaced, published the merged table first and validated after, so a
--- refused `mode` errored loudly AND stayed effective: `overlay_mode()` false,
--- `review_mode_active()` false, `--force` on the argv. A rejected
--- configuration produced the least confined state the product has.
---
--- FIRST-CALL CASE: `M.options` is seeded with the defaults at module load
--- (above), so there is no window in which the product is unconfigured. A
--- setup that fails on the very first call therefore leaves the DEFAULTS
--- effective — mode "inline", which is the overlay-confined, review-gated,
--- fail-closed state. "Unconfigured" was never an option worth having: it
--- would mean a turn could run with no mode at all, which is the same defect
--- wearing a different hat.
---
--- The error is re-raised unchanged (it simply propagates), so the user
--- still sees which key was wrong and what the accepted values are.
function M.setup(opts)
  opts = opts or {}
  local next_options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Replace (do not deep-merge) each highlight role so a custom bg/fg does not
  -- keep a leftover defaults.link (e.g. DiffAdd) that would win at apply time.
  if opts.diff_highlights then
    next_options.diff_highlights = vim.deepcopy(M.defaults.diff_highlights)
    for role, spec in pairs(opts.diff_highlights) do
      next_options.diff_highlights[role] = vim.deepcopy(spec)
    end
  end
  if opts.mode_highlights then
    next_options.mode_highlights = vim.deepcopy(M.defaults.mode_highlights)
    for role, spec in pairs(opts.mode_highlights) do
      next_options.mode_highlights[role] = vim.deepcopy(spec)
    end
  end
  if opts.model_highlight then
    next_options.model_highlight = vim.deepcopy(opts.model_highlight)
  end
  -- Every validator runs against the candidate. Any of them may raise; none of
  -- them can leave a half-installed configuration behind.
  next_options.selection_scope = M.normalize_selection_scope(next_options.selection_scope)
  next_options.image_paste = M.normalize_image_paste(next_options.image_paste)
  next_options.redirect = M.normalize_redirect(next_options.redirect)
  next_options.inline_edit = M.normalize_inline_edit(next_options.inline_edit)
  next_options.skill_dirs = M.normalize_skill_dirs(next_options.skill_dirs)
  next_options.artifact_dir_prefixes = M.normalize_artifact_dir_prefixes(next_options.artifact_dir_prefixes)
  next_options.write_roots = M.normalize_write_roots(next_options.write_roots)
  next_options.workspace_roots = M.normalize_workspace_roots(next_options.workspace_roots)
  next_options.capture_root = M.normalize_capture_root(next_options.capture_root)
  next_options.inline_exec_allowlist = M.normalize_inline_exec_allowlist(next_options.inline_exec_allowlist)
  next_options.cmd_env = M.normalize_cmd_env(next_options.cmd_env)
  next_options.backends = M.normalize_backends(next_options.backends)
  next_options.backend = M.normalize_backend(next_options.backend, next_options.backends)
  next_options.enable_agentic = next_options.enable_agentic == true
  next_options.mode = M.normalize_mode(next_options.mode, next_options.enable_agentic)
  -- Only now does anything become effective.
  M.options = next_options
  M.apply_mode_highlights()
  return M.options
end

--- Apply winbar chip highlights from `mode_highlights` and `model_highlight`.
function M.apply_mode_highlights()
  local h = M.options.mode_highlights or M.defaults.mode_highlights
  for mode, group in pairs(M.mode_hl_groups) do
    local spec = h[mode] or {}
    if spec.link and not spec.bg and not spec.fg then
      vim.api.nvim_set_hl(0, group, { link = spec.link, default = true, force = true })
    else
      local hl = vim.tbl_extend("force", spec, { force = true })
      hl.link = nil
      vim.api.nvim_set_hl(0, group, hl)
    end
  end
  local ms = M.options.model_highlight or M.defaults.model_highlight or {}
  if ms.link and not ms.bg and not ms.fg then
    vim.api.nvim_set_hl(0, M.model_hl_group, { link = ms.link, default = true, force = true })
  else
    local hl = vim.tbl_extend("force", ms, { force = true })
    hl.link = nil
    vim.api.nvim_set_hl(0, M.model_hl_group, hl)
  end
end

-- The cursor-agent permission mode for this turn. The panel argument is kept so
-- every existing call site still compiles, but it is no longer authoritative:
-- mode is a product-level dial, not a per-panel one, which is what stopped two
-- panels from disagreeing about what a turn was allowed to do.
function M.panel_mode(panel_mode)
  return M.resolve_mode(panel_mode)
end

return M
