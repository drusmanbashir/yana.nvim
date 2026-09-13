# Configuration

Every option below has a default, so `opts = {}` (or no `opts` at all) is a
valid setup. This page documents what each option is and what it defaults to.
Where the code and a comment in the source disagree, the behavior described
here follows the code.

## Recommended `opts`

```lua
opts = {
  backend = "cursor",
  modes = { "inline", "agentic", "ask" },
  mappings = {
    toggle = "<leader>cc",
    ask = "<leader>ca",
    inline_edit = "<C-k>",
  },
}
```

That's enough to open the panel, ask a question, and select text and
Ctrl-K it. Everything past this point is optional tuning. See
[Installation](installation.md) for environment variables and per-machine
paths, and [How it works](how-it-works.md) for what `mode` and the backend
picker actually do at runtime.

## Agent and backend

```lua
opts = {
  cmd = nil,
  cmd_env = "YANA_AGENT_BIN",
  model = nil,
  backend = "cursor",
  trust = true,
  approve_mcps = false,
  backends = { --[[ see below ]] },
}
```

- **`cmd`** (default `nil`) — explicit path or name of the agent binary.
  Only the built-in `cursor` backend may leave this `nil`; any other backend
  needs its own `cmd` (each ships one, e.g. `"claude"`, `"codex"`).
- **`cmd_env`** (default `"YANA_AGENT_BIN"`) — legacy Cursor-only environment
  override, checked after `cmd` and before searching `$PATH`. Point it at
  another variable your shell already exports, or set it to `false` to skip it.
- **`model`** (default `nil`) — model id passed to the backend. `nil` lets
  the backend choose (shown as "auto").
- **`backend`** (default `"cursor"`) — which entry of `backends` is active:
  which binary runs, which account is billed. Switching backend always
  resets `model`, because a model id from one vendor means nothing to
  another.
- **`trust`** (default `true`) — passes `--trust` so the workspace is
  trusted without an interactive prompt. This only applies to the `cursor`
  backend; other backends ignore it.
- **`approve_mcps`** (default `false`) — passes `--approve-mcps` (also
  `cursor`-only) so configured MCP servers don't block on interactive
  consent.
- **`backends`** (default: three built-in entries, see below) — the zoo of
  agent CLIs Yana knows about. Add your own entry, or override one field of
  an existing entry (e.g. just `backends.claude.cmd`); everything else for
  that backend keeps its shipped default.

Yana normally finds the built-in command names through Neovim's `PATH`, with
no environment setup. Custom installations may set `YANA_CURSOR_BIN`,
`YANA_CLAUDE_BIN`, or `YANA_CODEX_BIN`; only variables that exist and are
non-empty are used. An explicit top-level `cmd` remains the first choice for
Cursor, and an explicitly overridden `backends.<name>.cmd` remains first for
that backend. Each backend descriptor's `cmd_env` field names its environment
variable and may be changed when a built-in backend uses another local naming
convention.

```lua
opts = {
  backends = {
    claude = { cmd_env = "MY_CLAUDE_BIN" },
  },
}
```

Picking a different backend or model from the panel picker (`<C-g>`, the
agent CLI and then its model) is remembered across restarts and overrides whatever `backend` /
`model` your `setup()` call passed next time Neovim starts — the picker
choice, not your `setup()` table, is the last word once you've picked
something.

### Backend descriptors

Each entry in `backends` is a table of vendor-specific tokens; Yana's own
code decides *when* to use them and never branches on the backend's name.
Fields that matter when reading or overriding an entry:

- `cmd` — the binary to spawn (`nil` only valid for `cursor`).
- `cmd_env` — optional environment-variable name for a custom executable
  location; when the variable exists and is non-empty, its value replaces the
  backend's shipped bare command name.
- `noninteractive_flag` / `subcommand` — how this vendor's CLI is told not
  to prompt (a flag for `cursor`/`claude`, the `exec` subcommand for
  `codex`).
- `sandbox_args` — one argv fragment per Yana sandbox level (`full`,
  `workspace`, `read-only`, `vendor-default`); a custom backend must declare
  all four, each stamped with the vendor version it was measured against.
- `select_model_flag`, `resume_flag` / `resume_subcommand` — how to pick a
  model and resume a session.
- `list_models_args` — how to list models; `false` (as on `claude`) means
  there's no live listing and a static `models` table is used instead.
- `whoami_args`, `auth_login_hint`, `auth_output_patterns` — how
  `:checkhealth yana` and the login flow detect whether you're signed in.
- `install_hint` — the one-line install command shown by health checks.
- `state_dirs` — paths under `$HOME` this backend needs to write at
  startup (its own config/session state); everything else under `$HOME`
  stays read-only inside the sandbox.

Yana ships `cursor`, `claude`, and `codex`. See
[How it works](how-it-works.md) for a full custom-backend example (modeled
on the `codex` entry, which differs from the other two in nearly every
field).

## Modes and sandbox

```lua
opts = {
  modes = { "inline", "agentic", "ask" },
  sandbox = { inline = "vendor-default", agentic = "full" },
  inline_exec_allowlist = nil,
  single_file = { enabled = true, max_entries = 2000 },
}
```

- **`modes`** (default `{ "inline", "agentic", "ask" }`) — the modes a chat
  may enter. `"ask"` reads and answers, proposing no edits; `"inline"` turns
  edits into reviewable hunks in your real buffers; `"agentic"` lets the agent
  write your real files directly, with no review. The first entry is the
  starting mode, `<M-t>` (`mappings.toggle_mode`) cycles the list in order,
  and a mode missing from the list cannot be entered. `"ask"` always runs at
  the `read-only` sandbox level regardless of the `sandbox` setting below.
  The old keys still work: `mode = X` moves X to the front of the default
  list, `enable_agentic` set to anything but `true` removes `"agentic"`, and
  `modes` wins when both old and new keys are given.
- **`sandbox`** (default `{ inline = "vendor-default", agentic = "full" }`)
  — which of the four vendor-neutral sandbox levels (`full`, `workspace`,
  `read-only`, `vendor-default`) `inline` and `agentic` turns ask the
  backend for. `inline`'s own write boundary is Yana's overlay, so its
  default asks the vendor for nothing extra.
- **`inline_exec_allowlist`** (default `nil`, alpha) — a list of executable
  basenames/paths; when set, it narrows which executables `inline` mode may
  launch. `nil` keeps historical (unrestricted) behavior. `ask` and
  `agentic` never receive this rule.
- **`single_file`** — behavior when you open a loose file or a huge
  directory instead of a git project:
  - `enabled` (default `true`) — whether single-file mode is offered at
    all.
  - `max_entries` (default `2000`) — above this many directory entries,
    Yana falls back to single-file mode instead of trying to capture the
    whole tree.

**Confinement note:** the sandbox and `write_roots` (below) protect your
files from being *written*. They do not stop the agent process from
*reading* anything your own user account can read — masking secret stores
like `~/.ssh` is the one exception, done explicitly per backend via
`state_dirs`/vendor mount rules, not a general read boundary.

## Where turns write

```lua
opts = {
  write_roots = {},
  capture_root = nil,
  capture_root_candidates = { "~/code", "~" },
  workspace_roots = {},
  artifact_dir_prefixes = {},
}
```

- **`write_roots`** (default `{}`) — extra absolute directories (beyond the
  workspace you opened) a turn may write. Entries are operator-declared
  only — never something the agent's own output, a path found in the
  workspace, or an env var can add. Validated at turn start; overlapping
  roots are merged rather than refused.
- **`capture_root`** (default `nil`) — the directory whose entire subtree
  is writable inside the sandbox's overlay. `nil` means "choose it from
  filesystem position": `$HOME/code` if it's an ancestor of the resolved
  workspace, else `$HOME`, else the workspace itself. Set it to narrow that
  choice (e.g. one monorepo instead of all of `~/code`) or to widen it
  deliberately.
- **`capture_root_candidates`** (default `{ "~/code", "~" }`) — the ordered
  list `capture_root` picks from when it's `nil`. Each candidate is
  filtered at turn start: an entry that doesn't exist, isn't an ancestor of
  the workspace, or would contain Yana's own state root is skipped (not an
  error); if none qualify, the workspace itself is the capture root.
  Replace this list if your projects live somewhere other than `~/code`.
- **`workspace_roots`** (default `{}`) — extra directories workspace
  resolution considers when looking for the project root that contains the
  file you opened (checked after the nearest `.git` root, before the file's
  own folder).
- **`artifact_dir_prefixes`** (default `{}`) — extra directory-name
  components/globs that affect how generated files are grouped and
  retained; this never grants write access by itself.

## Review

```lua
opts = {
  review = {
    tabs = true,
    ignore = {},
  },
}
```

- **`review.tabs`** (default `true`) — a multi-file turn (2+ files) opens
  one tab per file, and may offer to close only the tabs it opened once the
  turn resolves. Set `false` to keep single-tab review navigation instead.
- **`review.ignore`** (default `{}`) — gitignore-syntax patterns, matched
  against the workspace-relative path, for changes you never want offered
  for review. A matching create/modify of a regular file is written
  straight through to your workspace at turn end and reported in one
  summary line instead of opened. This is empty by default — every path a
  turn writes is reviewed until you say otherwise — and it can never match
  `.git/`, `.hg/`, or `.svn/`, which are refused regardless. It's merged
  with a per-machine list at `<state_root>/ignore`, which `:YanaIgnore
  <pattern>` appends to.

## UI and highlights

```lua
opts = {
  ui = {
    width = 0.40,
    prompt_height = 6,
    position = "right",
    multi_panel_layout = "split",
    wrap = true,
    show_usage = true,
    show_thinking = false,
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    review_buttons = { max_height = 8, min_height = 1, steal_ratio = nil },
  },
  diff_highlights = {
    incoming = { link = "DiffAdd" },
    deleted = { link = "DiffDelete" },
    hint = { link = "Comment" },
  },
  mode_highlights = {
    ask = { link = "Special" },
    inline = { link = "Special" },
    agentic = { link = "WarningMsg" },
  },
  model_highlight = { link = "Identifier" },
}
```

- **`ui.width`** (default `0.40`) — sidebar width; `<= 1` is a fraction of
  total columns, `> 1` an absolute column count.
- **`ui.prompt_height`** (default `6`) — rows given to the prompt input
  area at the bottom of the panel.
- **`ui.position`** (default `"right"`) — which side the panel opens on
  (`"right"` or `"left"`).
- **`ui.multi_panel_layout`** (default `"split"`) — how multiple open chats
  share the sidebar column: `"split"` stacks every chat vertically;
  `"rotate"` shows one chat page at a time.
- **`ui.wrap`** (default `true`) — soft-wrap the conversation window.
- **`ui.show_usage`** (default `true`) — show token usage/duration after
  each answer.
- **`ui.show_thinking`** (default `false`) — render the model's "thinking"
  content, when the backend sends any.
- **`ui.spinner`** (default the braille frames above) — spinner frames
  shown in the winbar while the agent is responding.
- **`ui.review_buttons`** — the button strip shown between the
  conversation and the prompt while a turn is live: `max_height` (default
  `8`) caps its height in rows; `min_height` (default `1`) is its floor;
  `steal_ratio` (default `nil`, meaning equal shares) sets relative
  weights across the sidebar's horizontal splits at open.
- **`diff_highlights`** — highlight groups for inline hunks: `incoming`
  (added text, default links to `DiffAdd`), `deleted` (default
  `DiffDelete`), `hint` (default `Comment`).
- **`mode_highlights`** — highlight group per mode for the winbar's mode
  chip. `agentic` defaults to `WarningMsg` (a standout warning color)
  because it writes your real files with no review; `ask`/`inline` default
  to `Special`.
- **`model_highlight`** (default links to `Identifier`) — highlight for the
  winbar's model chip (reads `model: auto` unless you've picked one).

## Keymaps

Every key lives in one flat `mappings` table. Each key binds where its action
applies, so the table needs no groups:

```lua
opts = {
  mappings = {
    -- Review buffer (normal and visual mode, while a review is open)
    accept_hunk = "ca", reject_hunk = "cr", accept_file = "cf", reject_file = "cx",
    accept_all = "cA", next_hunk = "]x", prev_hunk = "[x",
    -- Prompt: the panel prompt and the inline-edit float
    submit = "<C-s>", stop = "<C-c>",
    -- Panel
    model = "<C-g>", new_chat = "<C-n>", toggle_mode = "<M-t>", resend = "<M-r>",
    review = "<C-y>", accept = "<C-a>", reject = "<C-x>", focus_prompt = "i",
    close = "q", next_panel = "<M-.>", prev_panel = "<M-,>", completion_menu = "<C-Space>",
    -- Advanced
    new_panel = "<M-n>", queue = "<M-q>", steer = "<C-CR>",
    history_prev = "<C-p>", history_next = "<C-n>",
    -- Global, off by default
    toggle = false, ask = false, inline_edit = false,
  },
}
```

- **Review keys** bind buffer-local in each reviewed buffer, normal and visual
  mode, while its review is open. They cannot be disabled: `false` and `""` both restore the default key. `cR` (abort the review), `cU` (reset the turn) and `u` /
  `U` / `<C-r>` are fixed.
- **`submit`** sends the prompt: in the panel prompt (normal and insert mode)
  and in the inline-edit float (normal and insert mode). Insert-mode `<CR>`
  inserts a newline; there is no normal-mode `<CR>` submit.
- **`stop`** stops the running response: in the panel prompt (normal and
  insert mode) and in the conversation window (normal mode). In the
  inline-edit float it closes the float from insert mode; `close` closes it
  from normal mode. There is no `<Esc>` stop.
- **`model`** (`<C-g>`) opens one picker: the agent CLI (backend), then its
  model. With one backend installed it goes straight to the model list.
  `:YanaBackend` and `:YanaModel` still pick one layer each.
- **Panel keys** bind buffer-local in the panel's prompt and conversation
  windows (`focus_prompt` in the conversation window only; `completion_menu`
  and `steer` in the prompt only). `history_prev` / `history_next` bind in the
  inline-edit float only.
- **Global keys** (`toggle`, `ask`, `inline_edit`) bind from any buffer when
  `setup()` runs, and are off by default. `inline_edit` binds visual mode only.
- `false` or `""` disables any key except a review key (see above). `nil` in your opts does
  not override a default (the deep merge ignores nil), so use `false`.

Old spellings still work and translate onto the flat names at setup:
`mappings.diff` / `mappings.panel` / `mappings.global`, `diff_keymaps`,
`keymaps`, `global_keymaps`, `inline_edit.keymaps` (its `cancel` becomes
`stop`) and `diff.both` (becomes `reject_file`, with a one-time warning), and
the old review names `theirs`, `ours`, `all_theirs`, `all_changes`, `next`,
`prev`. When one key is given in several places, the flat name wins, then
`mappings.diff` / `panel` / `global`, then `diff_keymaps` / `keymaps` /
`global_keymaps`, then `inline_edit.keymaps`. The removed names
`submit_normal`, `stop_normal`, `backend`, the panel `diff` alias,
`cancel_normal` and `inline_edit_normal` are ignored. `setup()` never writes
into the table you pass, and calling it twice with the same table gives the
same result. `require("yana.config").options.keymaps`, `.diff_keymaps` and
`.global_keymaps` stay available as read-only mirrors of `mappings`.

Two more keyed settings live outside `mappings`:

- **`inline_edit`** — the small floating prompt for editing exactly the
  selected lines: `enable` (default `true`), `width` (default `0.5`, same
  fraction/absolute rule as `ui.width`), `max_height` (default `6`) and
  `history` (default `20`, how many past instructions `history_prev` /
  `history_next` can recall; `0` disables). Its keys are `submit`, `stop`,
  `close`, `history_prev` and `history_next` in `mappings`.
- **`image_paste`** — pasting an image, image file, or plain text from the
  system clipboard into the prompt: `enable` (default `true`), `key`
  (default `{ "<C-v>", "<C-V>" }`, insert mode, prompt buffer only), `keep`
  (default `20`, how many pasted images are retained on disk).

## Prompt and context

```lua
opts = {
  agent_instructions = "…(see defaults; edits become reviewable hunks)…",
  selection_scope = {
    enforce = "reject",
    unstructured = "warn",
    cell_markers = { "# %%", "#%%" },
    min_zone_lines = 1,
    rejection_cap = 3,
  },
  context = {
    include_file = true,
    max_selection_lines = 600,
  },
}
```

- **`agent_instructions`** (default: a paragraph of edit-behavior guidance)
  — text prepended to the prompt. Set to `nil` to disable it entirely. It's
  only added in **`inline` mode** — `agentic` turns never receive it, since
  the shipped text specifically tells the agent to expect hunk-by-hunk
  review, which doesn't apply there.
- **`selection_scope`** — how strictly an edit is held to the
  function/class/cell/selection you actually asked about:
  - `enforce` (default `"reject"`) — `"reject"` hard-blocks out-of-zone
    edits, `"warn"` keeps them reviewable with a note, `"off"` disables the
    check.
  - `unstructured` (default `"warn"`) — level used instead when no
    function/class/cell resolves around a bare selection.
  - `cell_markers` (default `{ "# %%", "#%%" }`) — markers that delimit a
    notebook-style cell.
  - `min_zone_lines` (default `1`) — smallest edit zone considered
    structured.
  - `rejection_cap` (default `3`) — out-of-zone rejections allowed per path
    in one turn before the turn is cancelled outright.
- **`context.include_file`** (default `true`) — when there's no visual
  selection, tell the agent which file/line the cursor is on so it can open
  the file itself.
- **`context.max_selection_lines`** (default `600`) — hard cap on how many
  selected lines are embedded into the prompt.

## Queue and redirect

```lua
opts = {
  queue = { pause_on_error = false },
  redirect = {
    confirm_exit_timeout_ms = 3000,
    kill_grace_ms = 1500,
    marker = "[redirect — previous turn interrupted]",
  },
}
```

- **`queue.pause_on_error`** (default `false`) — when a turn ends with an
  agent-level error, hold any queued follow-ups instead of auto-firing the
  next one, and notify you so you can decide via the queue picker/keymap.
- **`redirect.confirm_exit_timeout_ms`** (default `3000`) — after
  cancelling a turn, how long to wait for the process to exit before
  escalating to `SIGKILL`.
- **`redirect.kill_grace_ms`** (default `1500`) — how long to wait after
  `SIGKILL` before giving up (the redirect is aborted, text returned to the
  prompt, rather than ever running two processes at once).
- **`redirect.marker`** (default `"[redirect — previous turn
  interrupted]"`) — one-line prefix telling the model the previous turn was
  cut short.

## Sessions and skills

```lua
opts = {
  sessions = {},
  skill_dirs = {
    "~/.cursor/skills",
    "~/.cursor/skills-cursor",
    "~/.claude/skills",
  },
}
```

- **`sessions`** (default `{}`) — session registry and transcript storage.
  Leaving it `{}` means: `dir` falls back to `stdpath("data") .. "/yana"`,
  `chats_dir` falls back to `~/.cursor/chats` (used to discover sessions
  created outside Neovim), and `max` falls back to `50` (registry entries
  kept). Set any of the three to override just that path/limit.
- **`skill_dirs`** (default the three paths above) — directories scanned
  for skills (each a directory of skill-directories containing a
  `SKILL.md`). Yana reads `~/.cursor/skills`, `~/.cursor/skills-cursor`,
  and `~/.claude/skills`; any of the three that doesn't exist is simply
  skipped, not an error. The project-local `<git-root-or-cwd>/.cursor/skills`
  is always scanned too, ahead of this list, and isn't part of it since
  "project root" is resolved at runtime, not configured.

## Diagnostics

```lua
opts = {
  log_level = "info",
  profile = "factory",
  debug_modules = {},
  debug_record = false,
}
```

- **`log_level`** (default `"info"`) — floor for what gets logged
  (`"error"`, `"warn"`, `"info"`, `"debug"`); a record is written only when
  its severity is at or above this floor.
- **`profile`** (default `"factory"`) — `"factory"` is the shipped product
  with no diagnostic modules attached; `"debugger"` is the same product
  with the modules named in `debug_modules` layered on top, purely as
  observers (they cannot change engine behavior).
- **`debug_modules`** (default `{}`) — module names to attach when
  `profile = "debugger"`; each is loaded as `yana.debug_<name>` (currently
  `"keys"` ships). Ignored entirely under the `factory` profile. A name
  that doesn't resolve, or is listed twice, is a setup error.
- **`debug_record`** (default `false`) — when `true`, every raw agent
  stdout line is teed verbatim to a per-turn recording file (plus a
  `meta.json` sidecar), letting a turn be replayed later. Off by default
  because it's per-event disk I/O; a clean turn's log is unaffected either
  way.

## Advanced settings

Every live setting that the README's default block leaves out, with its
default. Set only what you want to change.

```lua
opts = {
  -- Agent and backend
  cmd = nil, -- the cursor program: a full path or a bare name looked up on PATH; nil skips this step
  cmd_env = "YANA_AGENT_BIN", -- the NAME of a variable whose value is the cursor program's path; false skips this step
  model = nil, -- model id passed to the active backend's CLI as --model <id>; nil, "" or "auto" lets that CLI choose
  backends = {}, -- per-backend overrides deep-merged onto the shipped descriptors; see Backend descriptors above
  sandbox = { inline = "vendor-default", agentic = "full" }, -- sandbox level per mode: "full", "workspace", "read-only" or "vendor-default"
  approve_mcps = false, -- cursor only: true passes --approve-mcps, auto-approving MCP servers (:checkhealth warns)

  -- Where turns write (absolute paths; a leading "~" is expanded)
  inline_exec_allowlist = nil, -- alpha. nil: inline turns may run any program; a list limits inline turns to those
  write_roots = {}, -- directories a turn may write besides the opened workspace; roots saved with :YanaRoots are merged in
  workspace_roots = {}, -- when a file has no .git root above it, the listed directory containing it becomes the workspace
  single_file = {
    enabled = true, -- false never switches to single-file mode (for a loose file or a huge directory)
    max_entries = 2000, -- a directory with more entries than this opens in single-file mode; number >= 0
  },

  review = {
    tabs = true, -- a turn that changes 2+ files opens one tab per file; false reviews without extra tabs
  },
  selection_scope = { -- how edits are held to the code you selected
    enforce = "reject", -- out-of-zone edits: "reject" (blocked), "warn" (kept with a note) or "off"
    unstructured = "warn", -- level used when no function, class or cell encloses the selection
    cell_markers = { "# %%", "#%%" }, -- markers that delimit notebook-style cells; an empty list restores these
    rejection_cap = 3, -- out-of-zone rejections per file in one turn before the turn is cancelled (>= 1)
  },
  context = {
    include_file = true, -- with no selection, tell the agent the current file and cursor line
    max_selection_lines = 600, -- a longer selection is cut to this many lines in the prompt
  },
  queue = {
    pause_on_error = false, -- true: when a turn ends in an agent error, hold queued prompts instead of sending the next
  },
  redirect = { -- interrupting a running turn to send a new prompt (steer)
    confirm_exit_timeout_ms = 3000, -- ms to wait for the cancelled agent to exit before SIGKILL; below 50 uses the default
    kill_grace_ms = 1500, -- ms to wait after SIGKILL before the redirect is dropped; below 50 uses the default
    marker = "[redirect — previous turn interrupted]", -- line put before the new prompt; "" adds none
  },

  ui = {
    review_buttons = { -- button strip between conversation and prompt while a turn is live
      max_height = 8, -- tallest strip, in rows
      min_height = 1, -- shortest strip, in rows (values below 1 act as 1)
      steal_ratio = nil, -- nil = equal shares; a list of weights, one per sidebar pane top to bottom
    },
    wrap = true, -- soft-wrap panel text (sets wrap and linebreak)
    show_usage = true, -- show token usage and duration after each answer
    show_thinking = false, -- show the model's thinking text when the backend sends it
  },
  mode_highlights = { -- winbar mode chip, one nvim_set_hl() table per mode
    ask = { link = "Special" },
    inline = { link = "Special" },
    agentic = { link = "WarningMsg" },
  },
  model_highlight = { link = "Identifier" }, -- winbar model chip

  mappings = {
    new_panel = "<M-n>", -- open another chat
    queue = "<M-q>", -- view, edit, reorder or delete queued prompts
    steer = "<C-CR>", -- interrupt and resend the prompt as a new turn; many terminals cannot tell <C-CR> from <CR>
    history_prev = "<C-p>", -- previous instruction (inline-edit float, normal and insert)
    history_next = "<C-n>", -- next instruction (inline-edit float, normal and insert)
    toggle = false, -- global, normal mode: open or close the panel, e.g. "<leader>cc"
    ask = false, -- global: open the panel (normal) or ask about the selection (visual), e.g. "<leader>ca"
    inline_edit = false, -- global, visual mode: inline-edit the selection, e.g. "<C-k>"
  },
  inline_edit = { -- small float that rewrites exactly the selected lines
    enable = true, -- false turns the feature off
    width = 0.5, -- float width: <= 1 is a fraction of the screen, > 1 a column count; must be > 0
    max_height = 6, -- extra prompt rows the float may grow to (>= 1)
    history = 20, -- past instructions recallable with history_prev/history_next; 0 disables
  },
  image_paste = { -- paste an image, image file or text from the clipboard into the prompt
    enable = true, -- false removes the key and the :YanaPasteImage command
    key = { "<C-v>", "<C-V>" }, -- insert-mode key(s) in the prompt: a string or a list
    keep = 20, -- pasted images kept in the cache directory (>= 1); older ones are pruned
  },

  profile = "factory", -- "factory" (normal) or "debugger" (also loads debug_modules); other values are refused
  debug_modules = {}, -- with profile = "debugger" only: names loaded as yana.debug_<name>; ships "keys" (logs keypresses)
  debug_record = false, -- true saves each turn's raw agent output and a meta.json for replay (disk I/O per event)
  -- Text put before every inline-mode prompt; {{YANA_WRITABLE_BOUNDARY}} names the writable directory; false or "" disables it.
  agent_instructions = [[
{{YANA_WRITABLE_BOUNDARY}}
Agent mode: when the user asks to populate, add, change, or give an example in a file, EDIT that file with the Edit File tool immediately — do not only reply in chat or ask whether to paste. Use minimal diffs at the referenced line numbers. When a visual selection is attached, prefer edits inside the stated edit zone; out-of-zone edits may be rejected or flagged before review. The user reviews each edit as inline hunks in the open file (cr/ca/cf) before it is final. Propose edits only — never run compilers, test suites, or import/smoke checks; the user's hunk-by-hunk review is the validation step here, not a shell command. If validation like that is actually needed, say so and let the user switch to agentic mode, where it belongs.
]],
}
```

## Full reference

This page covers every option and its default. For the authoritative,
version-matched reference inside Neovim (including machine-specific
resolution and security details), run:

```vim
:help yana-configuration
```
