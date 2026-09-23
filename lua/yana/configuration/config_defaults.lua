-- yana: configuration defaults table (facade: yana.config).

local defaults = {
  -- WHERE cursor-agent IS RESOLVED FROM. Nothing below bakes in a username or absolute
  -- path. Resolution is decided ONCE,
  -- by M.resolve_cmd() below, and every consumer (agent spawn, model list,
  -- health/dependency rows) asks it -- never reads config.options.cmd directly to spawn
  -- or probe.
  cmd = nil,

  -- Name of the environment variable read for step 2 above. Point this at
  -- whatever your shell profile already exports -- e.g.
  -- cmd_env = "CURSOR_CLI_BIN" if that is the name you already use -- yana
  -- reads it lazily (never baked into a default value). Set to false to skip
  -- this legacy step and go
  -- straight from explicit `cmd` to the PATH fallback.
  cmd_env = "YANA_AGENT_BIN",

  -- Model to use. nil/"" => let cursor-agent pick (Auto). e.g. "claude-opus-5".
  model = nil,

  -- Closed set error|warn|info|debug maps onto vim.log.levels. A record writes iff its
  -- severity >= this floor (debug shows everything; error only errors). Lifecycle rows
  -- are DEBUG-severity messages, not a special category — they appear when the floor is
  -- debug (or when harness YANA_LIFECYCLE_LOG forces them).
  log_level = "info",

  -- WHICH BUILD OF YANA THIS SESSION IS. `factory` is the product; it is the
  -- default and it is what every user, every gate and every release runs.
  -- `debugger` is the SAME product with one or more diagnostic modules attached
  -- on top of it, named in `debug_modules`.
  --
  -- The engine -- hunks, ledger, ownership, colours -- is the invariant and no
  -- profile touches it. A debug module may only add an observation; it may not
  -- replace a component, add an option or change what the editor does, because
  -- the further a debug build sits from the factory one the less its evidence
  -- says about the factory one.
  --
  --   require("yana").setup({ profile = "debugger", debug_modules = { "keys" } })
  --
  -- Each name is loaded as `yana.debug_<name>` and gets one `attach(log)` call.
  -- A name that does not resolve, and a name listed twice, are setup errors. A
  -- `factory` profile never loads any of them -- it does not even read the list
  -- -- and `tests/yana_debug_profile_gate.sh` proves it.
  profile = "factory",
  debug_modules = {},

  backends = require("yana.configuration.config_defaults_backends"),

  -- The active backend (layer 1). Session-scoped at runtime exactly like
  -- `model` (config.options.backend is the sole authority once Neovim is
  -- running; see ui.lua's pick_backend) -- this default is only the value a
  -- fresh Neovim session starts with. "cursor" + every backends.cursor
  -- field above being the pre-existing behaviour is what makes an operator
  -- who sets nothing see no change at all.
  backend = "cursor",

  -- The modes this session may enter. The first entry is the starting mode, the
  -- list order is the toggle_mode cycle, and a mode missing here cannot be
  -- entered. "ask" reads and answers; "inline" turns edits into reviewed hunks;
  -- "agentic" writes the real workspace with no overlay or review. The legacy
  -- `mode` and `enable_agentic` keys translate onto this list at setup.
  modes = { "inline", "agentic", "ask" },

  -- Optional open capture. `auto` may choose the kernel fast backend after the
  -- launcher's topology plan proves it safe, then the optional FUSE backend
  -- when its own preflight succeeds. It always refuses when unavailable; it
  -- never changes an inline turn into direct execution.
  open_capture = {
    mode = "auto",
    on_unavailable = "refuse",
  },

  -- Vendor sandbox levels: Yana owns this
  -- vocabulary; each backend descriptor owns its argv translation.
  -- Inline's host boundary is Yana's overlay. The vendor therefore inherits
  -- its system-wide sandbox configuration instead of receiving a second,
  -- narrower workspace boundary that cannot see declared write_roots.
  sandbox = { inline = "vendor-default", agentic = "full" },

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

  -- Extra directories that a turn may write. Turn start takes the union of the
  -- opened workspace and these roots, then keeps only the maximal canonical
  -- paths; an ancestor entry absorbs the opened workspace and becomes root 1.
  --
  -- THE SET IS OPERATOR-DECLARED AND NOTHING ELSE MAY WIDEN IT. CORE's cardinal
  -- principle is that nothing agent-influenced selects confinement scope, so these come
  -- from setup()/config or an explicit operator command and from nowhere else: not from
  -- agent output, not from a path found in the workspace, not from an env var a turn
  -- could set. A write into a directory that is not the workspace and not listed here
  -- stays EROFS, and the refusal names the `write_roots` line that would declare it.
  --
  -- Entries are absolute (a leading `~` is expanded here); everything else --
  -- existence and resolving inside yana's own state root -- is checked at TURN
  -- START, where a bad entry refuses by name before the agent is launched.
  -- Overlap never refuses: the maximal root absorbs contained roots before any
  -- claim or mount exists.
  write_roots = {},

  single_file = {
    enabled = false,
    max_entries = 0,
  },

  -- Everything beneath it is writable inside the jail and every write lands in the
  -- turn's private upper layer -- the opened repository, a sibling repository, a
  -- directory that did not exist when the turn started. Everything outside it stays the
  -- plain read-only host bind.
  --
  -- `nil` means "choose it from filesystem position", which is the default and the
  -- cardinal principle applied to breadth: `$HOME/code` when it is an ancestor of the
  -- resolved workspace, else `$HOME`, else the workspace itself. Set it to NARROW that
  -- choice (one monorepo instead of all of `~/code`) or to widen it deliberately. It is
  -- an OPERATOR setting and nothing a turn produces may reach it: not agent output, not
  -- a path found in the workspace, not an env var a turn could set.
  --
  -- Validated at TURN START, where a bad value refuses the turn by name: it
  -- must exist, must be an ancestor of (or equal to) the resolved workspace,
  -- and must not contain yana's own state root -- the overlay may never cover
  -- the layers it is written into.
  capture_root = nil,

  -- Ordered broad-root candidates used when capture_root is nil
  -- (external-roots.md, capture-set ruling). EMPTY by default: nothing wider
  -- than the resolved workspace is captured until an operator names a root
  -- here, because no directory layout can be assumed. Entries are tried in
  -- order; missing, non-ancestor, and state-root-containing entries are normal
  -- misses, and the workspace itself is the final outcome when none qualify
  -- (as with an empty list). Widening breadth here does not change write_roots.
  capture_root_candidates = {},

  -- Workspace resolution asks, in order: the nearest `.git` root at or above the open
  -- file; then the entry here that contains it; then the file's own folder. A
  -- repository always wins, because the repository is the unit a claim is taken on.
  --
  -- Same provenance rule as every other scope setting: operator-declared,
  -- absolute (a leading `~` is expanded), never derived from a turn.
  workspace_roots = {},

  review = {
    -- Multi-file reviews (2+ files) open one tab per file and may offer to
    -- close only the tabs they opened when the turn resolves.
    tabs = true,

    -- WHO AUTHORISES AN AGENT-PROPOSED FILE PERMISSION CHANGE (R9).
    -- "ask" raises one question for one exact proposal, on the first real user
    -- visit to that file, before anything is written; "allow" authorises every
    -- proposal without asking; "deny" keeps the original mode without asking.
    -- Nothing else is accepted: an unknown value is refused at setup.
    -- The Turn snapshots this into `review_opts.permissions` at turn start, so
    -- a mid-turn setup() cannot change the policy a live review runs under.
    permissions = "ask",

    -- PATHS THE OPERATOR NEVER WANTS TO REVIEW. Gitignore syntax, matched on the
    -- workspace-relative path.
    --
    -- A matching path is written through to the real workspace untouched at
    -- turn end, never offered, and disclosed in one turn-summary line plus one
    -- `review.ignored` lifecycle row. Control-plane paths (`.git/`, `.hg/`,
    -- `.svn/`) are refused by invariant and no pattern reaches them.
    --
    -- Merged with the per-machine list at `<state_root>/ignore`, which
    -- `:YanaIgnore <pattern>` appends to and `:YanaIgnore` lists.
    ignore = {},
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

  -- Prepended to agent-mode prompts. Read from prompt.txt at the plugin root;
  -- empty (and therefore disabled) when that file is missing.
  agent_instructions = (function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h:h")
    local f = io.open(root .. "/prompt.txt", "r")
    if not f then
      return ""
    end
    local text = f:read("*a")
    f:close()
    return text
  end)(),

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

  ui = {
    -- Sidebar width. <= 1 is treated as a fraction of total columns,
    -- > 1 is an absolute column count.
    width = 0.40,
    -- Height (in rows) of the prompt input area at the bottom.
    prompt_height = 6,
    -- Review button strip (between conversation and prompt while a turn is live).
    review_buttons = {
      -- Cap on strip height in rows (8 = one row per button when the column is narrow).
      max_height = 8,
      min_height = 1,
      -- Relative steal weights across the sidebar column's horizontal splits at
      -- open (one weight per pane, top-to-bottom). Nil/empty = equal shares.
      steal_ratio = nil,
    },
    -- "right" or "left".
    position = "right",
    -- Multi-chat layout inside the sidebar: "split" (default) stacks every
    -- open chat vertically (conversation over its own prompt) in one column;
    -- "rotate" shows one chat page at a time.
    multi_panel_layout = "split",
    wrap = true,
    -- Show token usage / duration after each answer.
    show_usage = true,
    -- Render the model's "thinking" content (if any).
    show_thinking = false,
    -- Spinner frames shown in the winbar while the agent is responding.
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  },

  -- One flat table of keys; each binds where its action applies. false or ""
  -- disables a key, except a review key, which cannot be disabled: false and ""
  -- both restore its default.
  -- Legacy diff_keymaps / keymaps / global_keymaps, mappings.{diff,panel,global}
  -- and inline_edit.keymaps translate onto these names (config_mappings.lua).
  mappings = {
    -- Review buffer, normal and visual mode, while a review is open.
    accept_hunk = "ca",
    reject_hunk = "cr",
    accept_file = "cf",
    reject_file = "cx",
    accept_all = "cA",
    next_hunk = "]x",
    prev_hunk = "[x",
    -- Prompt: the panel prompt (normal and insert) and the inline-edit float.
    -- stop also binds in the conversation window (normal) and closes the float
    -- from insert mode.
    submit = "<C-s>",
    stop = "<C-c>",
    -- Panel.
    model = "<C-g>", -- one picker: the agent CLI, then its model
    new_chat = "<C-n>",
    toggle_mode = "<M-t>", -- Alt+t: cycle `modes` (avoid <C-t> -- Vim tag pop / E73)
    resend = "<M-r>", -- prefix: then r (here), n (new chat), a (new agent chat)
    review = "<C-y>",
    reject = "<C-x>",
    focus_prompt = "i", -- conversation window only
    close = "q", -- normal mode, both panel windows; also closes the float
    next_panel = "<M-.>",
    prev_panel = "<M-,>",
    -- Insert mode, prompt only. blink.cmp re-applies its own buffer-local
    -- <C-Space> on every InsertEnter, so blink may claim this chord back.
    completion_menu = "<C-Space>",
    -- Advanced.
    new_panel = "<M-n>",
    queue = "<M-q>",
    -- Many terminals cannot tell <C-CR> from <CR> without the Kitty keyboard
    -- protocol; rebind (e.g. "<M-CR>") if steer never fires.
    steer = "<C-CR>",
    history_prev = "<C-p>", -- inline-edit float only
    history_next = "<C-n>", -- inline-edit float only
    -- Global, set from any normal-mode buffer when setup() runs.
    toggle = "<C-a>",
    ask = false,
    inline_edit = false, -- visual mode only
  },

  -- Roots to scan for skills (each a directory whose entries are skill-directories
  -- containing a SKILL.md). Preference-shaped — WHICH roots to look in is configurable
  -- here; the scanning LOGIC that reads them stays in lua/yana/commands.lua.
  -- Project-local `<git-root-or-cwd>/.cursor/skills` is always scanned too, ahead of
  -- this list, the same way project `.cursor/commands` outranks `~/.cursor/commands` —
  -- it is not listed here because "project root" is a runtime value, not a preference.
  skill_dirs = {
    "~/.cursor/skills",
    "~/.cursor/skills-cursor",
    "~/.claude/skills",
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

	-- Session registry + transcripts (lua/yana/runtime/sessions.lua). An empty table: `dir` unset
	-- means stdpath("data")/yana.
	-- Session registry + transcripts (lua/yana/runtime/sessions.lua). `dir` unset means
	-- stdpath("data")/yana, resolved in sessions.lua because it is a runtime path.
	sessions = {
		chats_dir = "~/.cursor/chats",
		max = 50,
	},
}


return defaults
